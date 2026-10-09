import Foundation

#if !APPSTORE

/// One long-lived `claude -p --input-format stream-json --output-format stream-json` process: a
/// Mochi-owned Claude Code session. Messages go in as JSON lines on stdin, events come out as JSON
/// lines on stdout. Reading is event-driven (no polling), so an idle worker costs no CPU. Writes
/// happen on a private serial queue, never on the main actor. `onEvent` and `onExit` run on that
/// queue: hop to the main actor from them, and never call back into `isRunning` from inside.
final class ClaudeStreamProcess: @unchecked Sendable {
    private let cwd: String
    private let arguments: [String]
    private let environment: [String: String]
    private let onEvent: @Sendable ([String: Any]) -> Void
    private let onExit: @Sendable (Int32) -> Void

    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    /// Serial queue for stdin writes and for everything below that is mutable.
    private let queue = DispatchQueue(label: "coucou.claude-stream")
    private var stdoutBuffer = Data()
    private var stderrRing = Data()
    private var stdinClosed = false
    private var stopRequested = false
    private var started = false
    private var exitStatus: Int32?
    private var stdoutEOF = false
    private var stderrEOF = false
    private var finished = false

    /// stderr is kept as a ring of the last 4 KB, for error text.
    static let stderrLimit = 4_096

    init(cwd: String, arguments: [String], environment: [String: String],
         onEvent: @escaping @Sendable ([String: Any]) -> Void,
         onExit: @escaping @Sendable (Int32) -> Void) {
        self.cwd = cwd
        self.arguments = arguments
        self.environment = environment
        self.onEvent = onEvent
        self.onExit = onExit
    }

    /// Launches the process. Throws `ClaudeCodeRun.RunError` when the CLI or the folder is missing.
    func start() throws {
        guard let cli = ClaudeCodeRun.cliURL() else { throw ClaudeCodeRun.RunError.cliNotFound }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue else {
            throw ClaudeCodeRun.RunError.workingDirectoryUnavailable(cwd)
        }
        process.executableURL = cli
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty {
                handle.readabilityHandler = nil
                self.queue.async { self.stdoutEOF = true; self.finishIfDone() }
            } else {
                self.queue.async { self.consumeStdout(data) }
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty {
                handle.readabilityHandler = nil
                self.queue.async { self.stderrEOF = true; self.finishIfDone() }
            } else {
                self.queue.async { self.consumeStderr(data) }
            }
        }
        process.terminationHandler = { [weak self] proc in
            guard let self else { return }
            let status = proc.terminationStatus
            self.queue.async { self.exitStatus = status; self.finishIfDone() }
            // A grandchild that kept a pipe open (a dev server the agent started) must not hold
            // the exit report back for ever.
            self.queue.asyncAfter(deadline: .now() + 1) { self.stdoutEOF = true; self.stderrEOF = true; self.finishIfDone() }
        }
        try process.run()
        queue.sync { started = true }
    }

    var isRunning: Bool { queue.sync { started && process.isRunning } }

    /// The last 4 KB the process wrote to stderr (error text when it dies).
    var stderrTail: String {
        queue.sync { String(decoding: stderrRing, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// Queues a user message. stream-json queues a second one that arrives mid-turn.
    func send(userText: String) {
        let message: [String: Any] = ["type": "user", "message": ["role": "user", "content": userText]]
        writeLine(message)
    }

    /// Asks Claude to stop the current turn. The process stays alive for the next message.
    func interrupt() {
        let message: [String: Any] = [
            "type": "control_request",
            "request_id": UUID().uuidString.lowercased(),
            "request": ["subtype": "interrupt"],
        ]
        writeLine(message)
    }

    /// Closes stdin (a clean end for Claude), then SIGTERM after 2 s if it is still running.
    func stop() {
        queue.async { [self] in
            guard !stopRequested else { return }
            stopRequested = true
            closeStdin()
        }
        queue.asyncAfter(deadline: .now() + 2) { [self] in
            if started, process.isRunning { process.terminate() }
        }
    }

    /// Kills the process now. For app quit, where nothing is left to wait for.
    func terminateNow() {
        queue.sync {
            stopRequested = true
            closeStdin()
            if started, process.isRunning { process.terminate() }
        }
    }

    // MARK: - Private (queue only)

    private func writeLine(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: .withoutEscapingSlashes) else { return }
        queue.async { [self] in
            guard started, !stdinClosed, process.isRunning else { return }
            do {
                try stdinPipe.fileHandleForWriting.write(contentsOf: data + Data([0x0A]))
            } catch {
                // The process went away between the check and the write: onExit tells the owner.
            }
        }
    }

    /// `onExit` runs once, after the process exited AND both pipes were read to the end, so the
    /// last events (the final `result`) always arrive before it.
    private func finishIfDone() {
        guard !finished, let status = exitStatus, stdoutEOF, stderrEOF else { return }
        finished = true
        flushStdoutRemainder()
        stdinClosed = true
        onExit(status)
    }

    private func closeStdin() {
        guard !stdinClosed else { return }
        stdinClosed = true
        try? stdinPipe.fileHandleForWriting.close()
    }

    private func consumeStdout(_ data: Data) {
        stdoutBuffer.append(data)
        while let newline = stdoutBuffer.firstIndex(of: 0x0A) {
            let line = stdoutBuffer[stdoutBuffer.startIndex..<newline]
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...newline)
            emit(Data(line))
        }
    }

    private func flushStdoutRemainder() {
        guard !stdoutBuffer.isEmpty else { return }
        emit(stdoutBuffer)
        stdoutBuffer.removeAll()
    }

    private func emit(_ line: Data) {
        guard !line.isEmpty,
              let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return }
        onEvent(obj)
    }

    private func consumeStderr(_ data: Data) {
        stderrRing.append(data)
        if stderrRing.count > Self.stderrLimit {
            stderrRing.removeFirst(stderrRing.count - Self.stderrLimit)
        }
    }
}

/// Which process is the current one for a session id. A session can be relaunched (its process died,
/// the next message resumes it); the old process's late events and exit must not touch the new one.
struct ProcessGenerations {
    private var current: [String: Int] = [:]
    private var counter = 0

    /// A new process for `id`: returns its generation, which makes every older one stale.
    mutating func begin(_ id: String) -> Int {
        counter += 1
        current[id] = counter
        return counter
    }

    func isCurrent(_ id: String, _ generation: Int) -> Bool { current[id] == generation }
}
#else
#endif
