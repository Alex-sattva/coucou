import Foundation

/// A coding agent Mochi runs itself as a worker (no terminal). The first two runtimes are
/// OpenCode (any model OpenCode supports) and Claude Code. A runtime owns its processes; it feeds
/// progress, approvals and the final reply into the session store (through the agent's hooks or its
/// own event stream), so the strip and every card read one place.
@MainActor
protocol AgentRuntime: AnyObject {
    var kind: ProjectCLI { get }
    /// Starts a session in `projectPath`, sends `prompt` when given, and returns the session id.
    func start(projectPath: String, model: ModelRef?, prompt: String?) async throws -> String
    /// Sends the user's next message into the session (queued when the agent is mid-turn).
    func send(_ text: String, session: String) async throws
    /// Stops the current turn. The session stays alive.
    func interrupt(session: String) async
    /// Ends the session's process / work.
    func stop(session: String) async
    /// Stops the session, then opens that agent's own resume command in the user's terminal.
    func handOffToTerminal(session: String) async
    func stopAll() async
    /// Whether this runtime runs `session` (a worker it started, now or in an earlier launch).
    func owns(_ session: String) -> Bool
}
