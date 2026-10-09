import Foundation

/// Continues an existing Claude Code session headlessly (`claude -p --resume <id>`), and opens one
/// in Terminal for viewing. The resumed run keeps the same session id and fires the user's hooks,
/// so its progress, approvals and final reply reach the same Mochi through `HookServer`; this file
/// only launches the process and reports failures.
enum ClaudeCodeRun {
    enum RunError: Error {
        case cliNotFound
        case workingDirectoryUnavailable(String)
        case failed(String)
        case timedOut

        var message: String {
            switch self {
            case .cliNotFound: return AssistantBarLogic.claudeCliMissingCopy
            case .workingDirectoryUnavailable(let path): return "Folder not found: \(path)"
            case .failed(let s): return s.isEmpty ? "Claude Code failed." : s
            case .timedOut: return "Claude Code took too long and was stopped."
            }
        }
    }

    /// Set only by tests, to run a fake `claude`. When set, it is the only binary ever used.
    nonisolated(unsafe) static var cliOverrideForTests: URL?

    /// Resolves the `claude` binary: the native installer's location and Homebrew first, then PATH.
    static func cliURL() -> URL? {
        if let forced = cliOverrideForTests {
            return FileManager.default.isExecutableFile(atPath: forced.path) ? forced : nil
        }
        for dir in ["\(NSHomeDirectory())/.local/bin", "\(NSHomeDirectory())/.claude/local",
                    "/opt/homebrew/bin", "/usr/local/bin"] {
            let url = URL(fileURLWithPath: "\(dir)/claude")
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        proc.arguments = ["claude"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        guard (try? proc.run()) != nil else { return nil }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        let found = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !found.isEmpty, FileManager.default.isExecutableFile(atPath: found) else { return nil }
        return URL(fileURLWithPath: found)
    }

    /// The environment a `claude` child runs with: ours, with a PATH a GUI app would otherwise lack.
    static func processEnvironment(adding extra: [String: String] = [:]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        // A GUI app's PATH is minimal; give Claude's tools the usual user locations.
        let dirs = ["\(NSHomeDirectory())/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        env["PATH"] = (dirs + [env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"]).joined(separator: ":")
        for (k, v) in extra { env[k] = v }
        return env
    }

    /// Session ids are UUIDs; anything else is refused before it reaches a command line.
    static func isValidSessionId(_ id: String) -> Bool {
        UUID(uuidString: id) != nil
    }

    /// Sends `prompt` into session `sessionId` and waits for the run to end. Returns Claude's
    /// final text. Throws `RunError` with a one-line, user-readable message.
    @discardableResult
    static func resume(sessionId: String, prompt: String, cwd: String,
                       timeout: TimeInterval) async throws -> String {
        guard isValidSessionId(sessionId) else { throw RunError.failed("Unknown Claude Code session.") }
        guard let cli = cliURL() else { throw RunError.cliNotFound }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue else {
            throw RunError.workingDirectoryUnavailable(cwd)
        }
        return try await withCheckedThrowingContinuation { cont in
            let proc = Process()
            proc.executableURL = cli
            // `--` keeps a prompt that starts with "-" from being read as a flag.
            proc.arguments = ["-p", "--resume", sessionId, "--output-format", "json", "--", prompt]
            proc.environment = processEnvironment()
            proc.currentDirectoryURL = URL(fileURLWithPath: cwd)
            let outPipe = Pipe(), errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe
            // Drain as data arrives so a long run can never fill a pipe buffer and stall.
            let outBuf = PipeBuffer(), errBuf = PipeBuffer()
            outBuf.attach(outPipe)
            errBuf.attach(errPipe)
            proc.standardInput = FileHandle.nullDevice
            do { try proc.run() } catch {
                cont.resume(throwing: RunError.failed(error.localizedDescription))
                return
            }
            // Only the watchdog's own kill is a timeout; any other SIGTERM is a plain failure.
            let timedOut = TimeoutFlag()
            let watchdog = DispatchSource.makeTimerSource(queue: .global())
            watchdog.schedule(deadline: .now() + timeout)
            watchdog.setEventHandler { if proc.isRunning { timedOut.set(); proc.terminate() } }
            watchdog.resume()
            proc.terminationHandler = { _ in
                watchdog.cancel()
                let status = proc.terminationStatus
                let out = outBuf.finish(outPipe)
                let err = String(data: errBuf.finish(errPipe), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if timedOut.isSet { cont.resume(throwing: RunError.timedOut); return }
                // `--output-format json` prints one object; `is_error` covers auth and API failures
                // that still exit 0 or 1 with the reason in `result`.
                let obj = (try? JSONSerialization.jsonObject(with: out)) as? [String: Any]
                let result = (obj?["result"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let isError = (obj?["is_error"] as? Bool) ?? (status != 0)
                if isError || status != 0 {
                    let reason = !result.isEmpty ? result
                        : (!err.isEmpty ? err : "Claude Code exited with code \(status).")
                    cont.resume(throwing: RunError.failed(reason))
                } else {
                    cont.resume(returning: result)
                }
            }
        }
    }
}

/// Set once by the watchdog, read by the termination handler (different queues).
private final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}
