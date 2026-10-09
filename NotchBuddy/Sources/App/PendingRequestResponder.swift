import Foundation

/// What the user chose on an approval or question card, before it is translated for the source
/// of the request. One vocabulary for every source, so the cards never know where a request came from.
enum RequestOutcome: @unchecked Sendable {
    case allow
    case always          // only sent when the user clicks the card's "always"
    case deny
    case ask             // "ask me in the terminal" / dismissed without an answer
    case answered([String: Any])   // a question's answers
}

/// A held hook connection: the open `nb-hook` socket and the read source watching it for EOF.
/// The source's cancel handler closes the fd, so nothing else may close it.
struct HookConnection: @unchecked Sendable {
    let fd: Int32
    let source: any DispatchSourceRead
}

#if !APPSTORE
/// Where an OpenCode request is answered: the runtime that owns the server, and which request on it.
struct OpenCodeReplyTarget: @unchecked Sendable {
    enum Kind: @unchecked Sendable {
        /// `apiSession`: the session OpenCode asked in (a subagent's own); the card belongs to `sessionId`.
        case permission(requestId: String, apiSession: String)
        case form(formId: String, apiSession: String, map: OpenCodeFormMap)
    }
    let runtime: OpenCodeRuntime
    let sessionId: String
    let kind: Kind

    /// Sends the outcome to OpenCode. `.always` only ever arrives from the card's own "Always" button.
    func deliver(_ outcome: RequestOutcome) {
        let runtime = runtime, sessionId = sessionId, kind = kind
        Task { @MainActor in await runtime.deliver(outcome, session: sessionId, kind: kind) }
    }
}

#endif

/// The answer a brain tool call (`ask_user`) is waiting for. Resolves once; a later call does nothing.
final class BrainAnswerBox: @unchecked Sendable {
    static let dismissed = "The user dismissed the question"

    private let lock = NSLock()
    private var result: String?
    private var waiter: CheckedContinuation<String, Never>?

    func resolve(_ text: String) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = text
        let w = waiter
        waiter = nil
        lock.unlock()
        w?.resume(returning: text)
    }

    /// Waits for the user, with no timeout: the card stays up until it is answered or dismissed.
    func wait() async -> String {
        await withCheckedContinuation { cont in
            lock.lock()
            if let result { lock.unlock(); cont.resume(returning: result); return }
            waiter = cont
            lock.unlock()
        }
    }
}

/// How a pending approval or question is answered. The same cards resolve every case:
/// `.hook` writes to the `nb-hook` connection a Claude Code (or Codex) hook is waiting on.
enum PendingRequestResponder: @unchecked Sendable {
    case hook(HookConnection)
    #if !APPSTORE
    case openCode(OpenCodeReplyTarget)
    #endif
    /// Mochi's own `ask_user`: the brain is waiting on the answer.
    case brain(BrainAnswerBox)
}
