import Foundation

#if !APPSTORE

/// Mochi's brain on the user's Claude Code login: ONE long-lived `claude -p` stream-json process
/// (`ClaudeStreamProcess`) that talks to Coucou only through the six brain tools over MCP. It is
/// isolated from the user's own Claude Code setup (no hooks, CLAUDE.md, plugins, other MCP servers or
/// built-in tools: see `MochiTools.claudeBrainArguments`), so it never shows up as a session of its own.
/// The conversation lives in Claude Code's session (a persisted id, resumed after a restart). Nothing
/// here reads Claude's credentials: the CLI uses its own login. One turn at a time; a turn ends on the
/// stream's `result` line.
@MainActor
final class ClaudeBrainSession {
    static let shared = ClaudeBrainSession()

    /// The stream's `result` line, reduced to plain values.
    struct TurnResult: Sendable {
        let isError: Bool
        let text: String
        let firstError: String?
    }

    enum BrainError: LocalizedError {
        case busy
        case exited(String)
        var errorDescription: String? {
            switch self {
            case .busy: "Mochi is still answering."
            case .exited(let reason): reason
            }
        }
    }

    private static let sessionKey = "mochiBrainClaudeSession"
    private static let startedKey = "mochiBrainClaudeStarted"

    /// A folder of its own, owner-only, empty: Claude Code finds nothing to load from it.
    static var homeURL: URL { HookServer.supportDir.appendingPathComponent("mochi-home", isDirectory: true) }

    private var process: ClaudeStreamProcess?
    private var runningModel: String?
    private var generations = ProcessGenerations()
    private var generation = 0
    private var waiting: CheckedContinuation<TurnResult, Error>?
    private var gotResult = false

    private init() {}

    /// The `claude` CLI is installed.
    static var cliAvailable: Bool { ClaudeCodeRun.cliURL() != nil }

    // MARK: - Public

    /// Sends one user message and waits for the turn's `result`. Starts the process, or restarts it when
    /// it died or the model changed (the conversation resumes). Throws when the process cannot start or
    /// ends mid-turn, and `CancellationError` when `reset()` runs.
    func ask(_ text: String, model: String) async throws -> TurnResult {
        guard waiting == nil else { throw BrainError.busy }
        if let p = process, !p.isRunning || runningModel != model { stopProcess() }
        if process == nil { try launch(model: model) }
        gotResult = false
        return try await withCheckedThrowingContinuation { cont in
            waiting = cont
            process?.send(userText: text)
        }
    }

    /// A fresh conversation: ends the process and the turn in flight, and forgets the session id.
    func reset() {
        stopProcess()
        let ud = UserDefaults.standard
        ud.removeObject(forKey: Self.sessionKey)
        ud.removeObject(forKey: Self.startedKey)
        finishTurn(.failure(CancellationError()))
    }

    /// Quit path: the process must not outlive the app.
    func terminateNow() {
        process?.terminateNow()
        process = nil
    }

    // MARK: - Private

    private var storedSessionId: String {
        let ud = UserDefaults.standard
        if let id = ud.string(forKey: Self.sessionKey), ClaudeCodeRun.isValidSessionId(id) { return id }
        let id = UUID().uuidString.lowercased()
        ud.set(id, forKey: Self.sessionKey)
        ud.set(false, forKey: Self.startedKey)
        return id
    }

    private var started: Bool { UserDefaults.standard.bool(forKey: Self.startedKey) }

    private func launch(model: String) throws {
        let home = Self.homeURL
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.path)
        let id = storedSessionId
        let args = MochiTools.claudeBrainArguments(
            sessionId: id, resume: started, model: model,
            mcpConfig: MochiTools.claudeBrainMCPConfig(hookPath: HookServer.hookScriptPath))
        generation = generations.begin("brain")
        let mine = generation
        let p = ClaudeStreamProcess(
            cwd: home.path, arguments: args,
            environment: ClaudeCodeRun.processEnvironment(adding: MochiTools.claudeBrainEnvironment),
            onEvent: { [weak self] event in
                guard (event["type"] as? String) == "result" else { return }
                let result = TurnResult(
                    isError: (event["is_error"] as? Bool) == true,
                    text: (event["result"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                    firstError: (event["errors"] as? [String])?.first)
                Task { @MainActor in self?.got(result, generation: mine) }
            },
            onExit: { [weak self] status in Task { @MainActor in self?.exited(status: status, generation: mine) } })
        try p.start()
        process = p
        runningModel = model
    }

    private func stopProcess() {
        // The next launch resumes the same session: the old process must be gone first.
        process?.terminateNow()
        process = nil
        runningModel = nil
        _ = generations.begin("brain")
    }

    private func got(_ result: TurnResult, generation: Int) {
        guard generations.isCurrent("brain", generation) else { return }
        gotResult = true
        if !result.isError { UserDefaults.standard.set(true, forKey: Self.startedKey) }
        finishTurn(.success(result))
    }

    private func exited(status: Int32, generation: Int) {
        guard generations.isCurrent("brain", generation) else { return }
        let stderr = process?.stderrTail ?? ""
        process = nil
        runningModel = nil
        // A session that could not be opened (never started, or Claude no longer knows it): next time starts a new one.
        if !gotResult, !started || stderr.localizedCaseInsensitiveContains("conversation")
            || stderr.localizedCaseInsensitiveContains("in use") {
            let ud = UserDefaults.standard
            ud.removeObject(forKey: Self.sessionKey)
            ud.removeObject(forKey: Self.startedKey)
        }
        let reason = stderr.isEmpty ? "Claude Code stopped (code \(status))." : stderr
        finishTurn(.failure(BrainError.exited(reason)))
    }

    private func finishTurn(_ outcome: Result<TurnResult, Error>) {
        guard let cont = waiting else { return }
        waiting = nil
        cont.resume(with: outcome)
    }
}
#else
#endif
