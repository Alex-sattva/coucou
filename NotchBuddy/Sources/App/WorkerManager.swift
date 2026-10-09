import Foundation

#if !APPSTORE

/// The workers Mochi runs itself, whatever the agent. Picks the runtime for a session, remembers
/// which sessions are Mochi's (so a restart can pick them up again) and gives the rest of the app
/// one place to start, message and stop them. GitHub build only: the App Store build never
/// launches a worker, and every method says so (`isAvailable`).
@MainActor
final class WorkerManager {
    static let shared = WorkerManager()

    nonisolated static let isAvailable = true

    private let claude = ClaudeCodeRuntime()
    private let openCode = OpenCodeRuntime()
    private var runtimes: [ProjectCLI: any AgentRuntime] = [:]

    private init() {
        runtimes[.claudeCode] = claude
        runtimes[.openCode] = openCode
    }

    enum StartError: Error, LocalizedError {
        case unavailable
        case runtimeMissing(ProjectCLI)
        case claudeHooksMissing
        var errorDescription: String? {
            switch self {
            case .claudeHooksMissing: return ClaudeHookCheck.missingCopy
            case .unavailable: return "Mochi can\u{2019}t run agents itself in this version."
            case .runtimeMissing(let cli): return "\(cli.displayName) isn\u{2019}t supported yet."
            }
        }
    }

    /// Starts a worker in `projectPath`. Returns the new session id.
    func start(projectPath: String, runtime: ProjectCLI, model: ModelRef?, prompt: String?) async throws -> String {
        guard Self.isAvailable else { throw StartError.unavailable }
        guard let rt = runtimes[runtime] else { throw StartError.runtimeMissing(runtime) }
        // A headless Claude has no terminal to ask in: without Coucou's hook its permissions are refused unseen.
        if runtime == .claudeCode, !HookServer.claudeHooksInstalled() { throw StartError.claudeHooksMissing }
        let id = try await rt.start(projectPath: projectPath, model: model ?? AppState.shared.defaultWorkerModel(for: runtime),
                                    prompt: prompt)
        // Same main-actor turn as the start: no hook event for this session has been read yet.
        AppState.shared.rememberMochiWorker(id, runtime: runtime)
        return id
    }

    /// Sends `text` into a Mochi worker. false: not a worker, so the caller uses its old path.
    /// A worker that fails to take the text reports the reason itself and still returns true.
    func send(_ text: String, toSession id: String) async -> Bool {
        guard let rt = runtime(for: id) else { return false }
        do {
            try await rt.send(text, session: id)
        } catch {
            AssistantModel.shared.reportRunFailure(rt.kind.displayName, Self.message(for: error), aloud: false)
        }
        return true
    }

    /// One readable line for whatever a runtime threw.
    static func message(for error: Error) -> String {
        if let e = error as? ClaudeCodeRun.RunError { return e.message }
        if let e = error as? OpenCodeChat.ChatError { return e.message }
        if let e = error as? OpenCodeServerLauncher.LaunchError {
            switch e {
            case .folderMissing(let path): return "Folder not found: \(path)"
            case .noPassword: return "OpenCode did not start in time."
            case .exited(let status): return "OpenCode exited with code \(status) while starting."
            }
        }
        return error.localizedDescription
    }

    func isWorker(_ id: String) -> Bool {
        Self.isAvailable && AppState.shared.workerRuntime(for: id) != nil
    }

    func runtime(for session: String) -> (any AgentRuntime)? {
        guard Self.isAvailable, let kind = AppState.shared.workerRuntime(for: session) else { return nil }
        return runtimes[kind]
    }

    /// Stops the worker, opens its agent's own resume command in the terminal, and gives the session
    /// back to the user: Mochi no longer drives it.
    func handOffToTerminal(sessionId: String) async {
        await runtime(for: sessionId)?.handOffToTerminal(session: sessionId)
        AppState.shared.releaseMochiWorker(sessionId)
    }

    /// An OpenCode session this launch runs: the hook server ignores the plugin's events for it.
    func isLiveOpenCodeWorker(_ id: String) -> Bool { Self.isAvailable && openCode.isLive(id) }

    /// Shows a worker's parked approval or question again (silently). Only OpenCode workers park.
    func resurfaceRequests(for id: String) { openCode.resurface(id) }

    func stopAll() async {
        for rt in runtimes.values { await rt.stopAll() }
    }

    /// Quit path (synchronous): no worker process may outlive the app.
    func stopAllNow() {
        claude.terminateAllNow()
        openCode.terminateAllNow()
        // Mochi's own brain, when it thinks with the Claude Code login.
        ClaudeBrainSession.shared.terminateNow()
    }
}
#else

/// App Store build: Mochi runs no agents. The same calls exist and do nothing, so the callers need no
/// guards of their own; the runtimes, the brain and the MCP server are not compiled in.
@MainActor
final class WorkerManager {
    static let shared = WorkerManager()
    nonisolated static let isAvailable = false
    private init() {}

    enum StartError: Error, LocalizedError {
        case unavailable
        var errorDescription: String? { "Mochi can\u{2019}t run agents itself in this version." }
    }

    func start(projectPath: String, runtime: ProjectCLI, model: ModelRef?, prompt: String?) async throws -> String {
        throw StartError.unavailable
    }
    func send(_ text: String, toSession id: String) async -> Bool { false }
    static func message(for error: Error) -> String { error.localizedDescription }
    func isWorker(_ id: String) -> Bool { false }
    func runtime(for session: String) -> (any AgentRuntime)? { nil }
    func handOffToTerminal(sessionId: String) async {}
    func stopAll() async {}
    func stopAllNow() {}
    func isLiveOpenCodeWorker(_ id: String) -> Bool { false }
    func resurfaceRequests(for id: String) {}
}
#endif
