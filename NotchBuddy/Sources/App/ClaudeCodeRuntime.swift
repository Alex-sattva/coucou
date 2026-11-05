import Foundation

#if !APPSTORE

/// Claude Code as a Mochi worker: one `claude -p` stream-json process per session (`ClaudeStreamProcess`).
/// Progress, approvals, questions and the final reply keep arriving through the user's existing
/// hooks into `HookServer`; this class launches, feeds and stops the processes, and reports a run
/// that failed. Nothing here approves anything.
@MainActor
final class ClaudeCodeRuntime: AgentRuntime {
    let kind: ProjectCLI = .claudeCode

    private struct Worker {
        var process: ClaudeStreamProcess?
        var cwd: String
        var model: ModelRef?
        /// We asked for this turn to stop: its `error` result is not a failure.
        var interrupting = false
        /// We are ending this process: its exit is not a failure either.
        var stopping = false
    }

    private var workers: [String: Worker] = [:]
    private var generations = ProcessGenerations()

    func start(projectPath: String, model: ModelRef?, prompt: String?) async throws -> String {
        let id = UUID().uuidString.lowercased()
        try launch(id: id, cwd: projectPath, model: model, resume: false)
        if let prompt, !prompt.isEmpty { workers[id]?.process?.send(userText: prompt) }
        return id
    }

    func send(_ text: String, session: String) async throws {
        var worker = workers[session] ?? Worker(
            process: nil, cwd: AppState.shared.sessionStore.sessions[session]?.cwd ?? "", model: nil)
        if worker.process?.isRunning != true {
            // The process ended (the app restarted, or it died): pick the conversation back up.
            guard !worker.cwd.isEmpty else { throw ClaudeCodeRun.RunError.failed("Unknown session folder.") }
            try launch(id: session, cwd: worker.cwd, model: worker.model, resume: true)
            worker = workers[session] ?? worker
        }
        worker.process?.send(userText: text)
    }

    func interrupt(session: String) async {
        guard workers[session]?.process?.isRunning == true else { return }
        workers[session]?.interrupting = true
        workers[session]?.process?.interrupt()
    }

    func stop(session: String) async {
        guard var worker = workers[session] else { return }
        worker.stopping = true
        workers[session] = worker
        worker.process?.stop()
    }

    func handOffToTerminal(session: String) async {
        let cwd = workers[session]?.cwd ?? AppState.shared.sessionStore.sessions[session]?.cwd ?? ""
        await stop(session: session)
        // The terminal resumes the same conversation: wait (up to 3 s) until this process let go of it.
        for _ in 0..<60 where workers[session]?.process?.isRunning == true {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard !cwd.isEmpty else { return }
        ClaudeCodeRun.openInTerminal(sessionId: session, cwd: cwd)
    }

    func stopAll() async {
        for id in Array(workers.keys) { await stop(session: id) }
    }

    /// Quit path: kills every process at once, without waiting. No orphan may outlive the app.
    func terminateAllNow() {
        for (id, var worker) in workers {
            worker.stopping = true
            workers[id] = worker
            worker.process?.terminateNow()
        }
    }

    func owns(_ session: String) -> Bool {
        AppState.shared.workerRuntime(for: session) == .claudeCode
    }

    // MARK: - Private

    private func launch(id: String, cwd: String, model: ModelRef?, resume: Bool) throws {
        let mcp = MochiTools.claudeMCPConfig(hookPath: HookServer.hookScriptPath, owner: id)
        let args = MochiTools.claudeWorkerArguments(sessionId: id, resume: resume, model: model, mcpConfig: mcp)
        // Callbacks carry their process's generation: after a relaunch the old one is ignored.
        let generation = generations.begin(id)
        let process = ClaudeStreamProcess(
            cwd: cwd, arguments: args, environment: ClaudeCodeRun.processEnvironment(),
            onEvent: { [weak self] event in
                // Only a result matters here; reduce it to plain values before leaving the process queue.
                guard let result = StreamResult(event) else { return }
                Task { @MainActor in self?.handle(result, session: id, generation: generation) }
            },
            onExit: { [weak self] status in Task { @MainActor in self?.exited(session: id, status: status, generation: generation) } })
        try process.start()
        workers[id] = Worker(process: process, cwd: cwd, model: model)
    }

    /// The few fields of a stream-json `result` line that Mochi reads.
    private struct StreamResult: Sendable {
        let isError: Bool
        let terminalReason: String?
        let text: String
        let firstError: String?

        init?(_ event: [String: Any]) {
            guard (event["type"] as? String) == "result" else { return nil }
            isError = (event["is_error"] as? Bool) == true
            terminalReason = event["terminal_reason"] as? String
            text = (event["result"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            firstError = (event["errors"] as? [String])?.first
        }
    }

    /// Only a failed `result` is looked at here; everything else reaches the store through the hooks.
    private func handle(_ result: StreamResult, session: String, generation: Int) {
        guard generations.isCurrent(session, generation) else { return }
        let interrupted = workers[session]?.interrupting == true || result.terminalReason == "aborted_streaming"
        workers[session]?.interrupting = false
        guard result.isError, !interrupted else { return }
        let message = result.text.isEmpty ? (result.firstError ?? "Claude Code failed.") : result.text
        AssistantModel.shared.reportRunFailure("Claude Code", message, aloud: false)
    }

    private func exited(session: String, status: Int32, generation: Int) {
        // An old process finishing after a relaunch must not clear the new one or report a failure.
        guard generations.isCurrent(session, generation), let worker = workers[session] else { return }
        let stderr = worker.process?.stderrTail ?? ""
        workers[session]?.process = nil
        guard status != 0, !worker.stopping else { return }
        let reason = stderr.isEmpty ? "Claude Code exited with code \(status)." : stderr
        AssistantModel.shared.reportRunFailure("Claude Code", reason, aloud: false)
    }
}
#endif

extension ClaudeCodeRun {
    /// Opens the user's terminal (Settings → General) on `claude --resume <id>` in the session's
    /// folder, so the whole conversation is visible and can be continued there.
    @MainActor
    static func openInTerminal(sessionId: String, cwd: String) {
        guard isValidSessionId(sessionId) else { return }
        TerminalLauncher.run("claude --resume \(sessionId)", in: cwd)
    }
}
