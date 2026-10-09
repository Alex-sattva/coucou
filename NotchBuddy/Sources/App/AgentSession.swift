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
    var failure: SessionFailure? = nil   // why the turn stopped (StopFailure); cleared by a new prompt
    var mochi: MochiNote? = nil          // what a Mochi worker reported with its `report` tool
    var missedApprovals: [String] = []   // requests that timed out unanswered this turn (Mochi workers)
}

/// A model a worker runs with. Claude Code: `providerID == nil`, `id` is an alias (`sonnet`) or a
/// full model id. OpenCode: both set (`openai` / `gpt-5`).
struct ModelRef: Equatable, Sendable, Codable {
    var providerID: String?
    var id: String

    /// An OpenCode catalog id (`provider/model`, split at the first slash). nil when it has no provider.
    static func openCode(catalogId: String) -> ModelRef? {
        let trimmed = catalogId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let slash = trimmed.firstIndex(of: "/") else { return nil }
        let provider = String(trimmed[..<slash]), id = String(trimmed[trimmed.index(after: slash)...])
        guard !provider.isEmpty, !id.isEmpty else { return nil }
        return ModelRef(providerID: provider, id: id)
    }

    /// A Claude Code alias or full id. nil for the empty "Claude Code default".
    static func claude(_ alias: String) -> ModelRef? {
        let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : ModelRef(providerID: nil, id: trimmed)
    }

    /// Display text for logs and the launch line: `provider/model` or the bare id.
    var label: String { providerID.map { "\($0)/\(id)" } ?? id }
}

/// What a Mochi worker reported with its `report` tool: the line Mochi shows (and says, when the
/// owner turned that on), and up to three one-click next steps. Nothing here runs without a click.
struct MochiNote: Equatable, Sendable {
    var line: String?
    var actions: [MochiAction] = []
}

struct MochiAction: Equatable, Sendable, Identifiable {
    enum Kind: Equatable, Sendable {
        case openURL(String)    // http(s) only, checked again at click time
        case openFile(String)   // a path, absolute or relative to the session's folder
        case reveal(String)     // a path shown in Finder
        case reply(String)      // sent to the same session as the user's next message
        case copy(String)       // put on the clipboard
        /// Brings that session's own card to the main spot. Made by Mochi's digest only; model
        /// output can never produce it (`MochiAware.action` does not know it).
        case focus(sessionId: String)
    }
    var label: String
    var kind: Kind
    var id: String { label }
}

/// Why an agent's turn stopped on an error. `kind` is Claude Code's `error` field
/// (`rate_limit`, `billing_error`…); `message` is the text the agent itself showed.
struct SessionFailure: Equatable, Sendable {
    var kind: String?
    var message: String?

    /// The card's first line: says plainly that the session stopped, and why when known.
    var headline: String {
        switch kind {
        case "rate_limit":
            return "You\u{2019}ve hit your usage limit. This session stopped."
        case "billing_error":
            return "A billing problem stopped this session."
        case "authentication_failed", "oauth_org_not_allowed", "cloud_credential_error":
            return "I\u{2019}m signed out, so this session stopped."
        case "account_on_hold":
            return "Your account is on hold, so this session stopped."
        case "overloaded", "server_error":
            return "Claude\u{2019}s servers had a problem. This session stopped."
        case "max_output_tokens":
            return "My reply got too long, so this session stopped."
        case "model_not_found", "invalid_request":
            return "The request was refused, so this session stopped."
        default:
            return "I hit an error I can\u{2019}t get past on my own."
        }
    }
}

enum SessionEvent: Sendable, Equatable {
    case start, end, prompt(String), toolStart(step: String), toolEnd, toolFailed(step: String)
    case approvalRequested, questionAsked, notification(String), stop(reply: String?, mochi: MochiNote? = nil)
    /// A Mochi worker's `report` tool call: its one line and next steps. Arrives before the turn ends;
    /// the phase does not change.
    case mochiReport(MochiNote)
    /// A Mochi worker's permission request timed out unanswered, so the headless agent skipped it.
    case approvalMissed(command: String)
    case stopFailure(kind: String? = nil, message: String? = nil)
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
            session.mochi = nil
            session.missedApprovals = []
            session.failure = nil
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
        case .mochiReport(let note):
            session.mochi = note
        case .approvalMissed(let command):
            session.missedApprovals.append(command)
            Self.appendStep(&session, "\u{26A0} Skipped: \(command) \u{2014} no answer in time")
        case .stop(let text, let mochi):
            session.reply = text
            // The worker's report came before the turn ended: a stop without one keeps it.
            if let mochi { session.mochi = mochi }
            session.finishedSeen = false
            Self.setPhase(&session, .finished, now: now)
        case .stopFailure(let kind, let message):
            session.failure = SessionFailure(kind: kind, message: message)
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
