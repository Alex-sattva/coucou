import Foundation

// Pure session model for the assistant layer: one `AgentSession` per hook `session_id`.
// Foundation only, so it compiles in the standalone `scripts/test-agent-session.sh` suite.

enum AgentKind: String, Sendable { case claudeCode, openCode, codex, gemini, cursor, antigravity, other }

enum SessionPhase: String, Sendable { case thinking, working, approval, question, blocked, finished, idle }

extension SessionPhase {
    /// Phases that ask for the user's attention (and stamp `attentionAt`).
    var needsAttention: Bool {
        switch self {
        case .approval, .question, .blocked, .finished: return true
        case .thinking, .working, .idle: return false
        }
    }
}

struct AgentSession: Identifiable, Equatable, Sendable {
    let id: String                 // hook session_id
    var kind: AgentKind
    var cwd: String
    var workspace: String          // URL(fileURLWithPath: cwd).lastPathComponent
    var colorHex: String
    var phase: SessionPhase
    var steps: [String]
    var lastPrompt: String?
    var reply: String?             // the agent's full last message (Stop's last_assistant_message)
    var attentionAt: Date?         // set when phase enters approval/question/blocked/finished
    var finishedSeen: Bool
    var lastEventAt: Date
}

enum SessionEvent: Sendable {
    case start, end, prompt(String), toolStart(step: String), toolEnd, toolFailed(step: String)
    case approvalRequested, questionAsked, notification(String), stop(reply: String?), stopFailure
    case interrupt
}

struct AgentSessionStore: Equatable, Sendable {
    static let maxSteps = 40

    private(set) var sessions: [String: AgentSession]

    init(sessions: [String: AgentSession] = [:]) {
        self.sessions = sessions
    }

    mutating func apply(_ event: SessionEvent, sessionId: String, kind: AgentKind, cwd: String,
                        colorHex: String, now: Date) {
        if case .end = event {
            sessions.removeValue(forKey: sessionId)
            return
        }

        var session = sessions[sessionId] ?? AgentSession(
            id: sessionId, kind: kind, cwd: cwd,
            workspace: Self.workspaceName(cwd), colorHex: colorHex,
            phase: .idle, steps: [], lastPrompt: nil, reply: nil,
            attentionAt: nil, finishedSeen: false, lastEventAt: now)

        // Hooks can start mid-session with an empty cwd; adopt a real one when it shows up.
        if !cwd.isEmpty, cwd != session.cwd {
            session.cwd = cwd
            session.workspace = Self.workspaceName(cwd)
        }
        session.lastEventAt = now

        switch event {
        case .start:
            break
        case .end:
            break // handled above
        case .prompt(let text):
            session.lastPrompt = text
            session.reply = nil
            session.finishedSeen = false
            session.steps = [] // "N steps done" counts the current turn
            Self.setPhase(&session, .thinking, now: now)
        case .toolStart(let step):
            Self.appendStep(&session, step)
            Self.setPhase(&session, .working, now: now)
        case .toolEnd:
            // A finished session stays finished when a late PostToolUse arrives.
            if session.phase != .finished { Self.setPhase(&session, .working, now: now) }
        case .toolFailed(let step):
            Self.appendStep(&session, "⚠ \(step)")
            Self.setPhase(&session, .working, now: now)
        case .approvalRequested:
            Self.setPhase(&session, .approval, now: now)
        case .questionAsked:
            Self.setPhase(&session, .question, now: now)
        case .notification(let message):
            if message.localizedCaseInsensitiveContains("rate limit") {
                Self.setPhase(&session, .blocked, now: now)
            } else if message.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?") {
                Self.setPhase(&session, .question, now: now)
            }
        case .stop(let text):
            session.reply = text
            session.finishedSeen = false
            Self.setPhase(&session, .finished, now: now)
        case .stopFailure:
            Self.setPhase(&session, .blocked, now: now)
        case .interrupt:
            Self.setPhase(&session, .idle, now: now)
        }

        sessions[sessionId] = session
    }

    mutating func markSeen(_ sessionId: String) {
        sessions[sessionId]?.finishedSeen = true
    }

    /// Removes sessions with no event for `idleFor`. A session in approval/question is never
    /// removed: its hook is still held open waiting for the user.
    mutating func prune(now: Date, idleFor: TimeInterval) {
        sessions = sessions.filter { _, s in
            if s.phase == .approval || s.phase == .question { return true }
            return now.timeIntervalSince(s.lastEventAt) < idleFor
        }
    }

    // MARK: - Helpers

    private static func workspaceName(_ cwd: String) -> String {
        URL(fileURLWithPath: cwd).lastPathComponent
    }

    private static func appendStep(_ session: inout AgentSession, _ step: String) {
        session.steps.append(step)
        if session.steps.count > maxSteps {
            session.steps.removeFirst(session.steps.count - maxSteps)
        }
    }

    /// Entering an attention phase stamps `attentionAt`; leaving clears it. Moving between two
    /// attention phases (approval to question) restamps; staying in the same one keeps the
    /// original stamp so a repeated event does not push the session back in the queue.
    private static func setPhase(_ session: inout AgentSession, _ phase: SessionPhase, now: Date) {
        if phase.needsAttention {
            if session.phase != phase || session.attentionAt == nil { session.attentionAt = now }
        } else {
            session.attentionAt = nil
        }
        session.phase = phase
    }
}

extension AgentKind {
    var displayName: String {
        switch self {
        case .claudeCode:   return "Claude Code"
        case .openCode:     return "OpenCode"
        case .codex:        return "Codex"
        case .gemini:       return "Gemini"
        case .cursor:       return "Cursor"
        case .antigravity:  return "Antigravity"
        case .other:        return "Agent"
        }
    }
}
