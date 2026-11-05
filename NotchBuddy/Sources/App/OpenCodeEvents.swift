import Foundation

// Pure, Foundation-only (compiled by scripts/test-assistant-logic.sh): what the events of an
// `opencode serve` mean for Mochi. The names below were recorded from a real OpenCode 2.0.16
// server (tests/fixtures/opencode-events.txt), not guessed.

/// One thing Mochi should do after an OpenCode server event.
enum OpenCodeSignal {
    /// A plain session event for the store. `cwd` is known only on `session.created`.
    case session(id: String, cwd: String?, event: SessionEvent)
    /// A tool is about to run. `tool` and `input` use Claude Code's names, so the strip's step
    /// labels (`HookServer`'s step text) work unchanged.
    case toolStart(id: String, tool: String, input: [String: Any])
    /// OpenCode asks for a permission: open the approval card.
    /// `id` is the worker the card belongs to; `apiSession` is the session OpenCode asked in (a
    /// subagent's own session, when a worker's `task` tool started one): replies go there.
    case approval(id: String, requestId: String, tool: String, command: String, apiSession: String)
    case approvalSettled(id: String, requestId: String)
    /// OpenCode asks the user something: open the question card.
    case question(id: String, formId: String, question: AskQuestion, map: OpenCodeFormMap, apiSession: String)
    case questionSettled(id: String, formId: String)
}

/// How the question card's answers map back onto an OpenCode form's fields.
struct OpenCodeFormMap: Equatable, Sendable {
    /// Question text (what the card shows) to the form field's key.
    var keys: [String: String] = [:]
    /// Question text to option label to option value (the value is what OpenCode wants back).
    var values: [String: [String: String]] = [:]
    /// Fields the card cannot show (past the card's 4 questions): answered with an empty string.
    var unshownKeys: [String] = []
    /// Question texts whose field takes several values.
    var multi: Set<String> = []
}

/// What a server stream needs to remember between events.
struct OpenCodeEventState {
    /// Tool call id to tool name (the name only arrives with `session.tool.input.started`).
    var toolNames: [String: String] = [:]
    /// The latest finished assistant text per session: the reply when the session finishes.
    var lastText: [String: String] = [:]
    /// Sessions seen since this stream opened.
    var knownSessions: Set<String> = []
    /// Subagent session to the session that started it (`session.created` carries `parentID`).
    var parents: [String: String] = [:]

    /// The worker a session belongs to: itself, or the top of its parent chain.
    func root(of id: String) -> String {
        var current = id, hops = 0
        while let parent = parents[current], hops < 8 { current = parent; hops += 1 }
        return current
    }
}

enum OpenCodeEvents {
    /// One SSE line (`data: {...}`) as a JSON object. Comments (`: heartbeat`) and blanks: nil.
    static func parseLine(_ line: String) -> [String: Any]? {
        guard line.hasPrefix("data:") else { return nil }
        let body = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard let data = body.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return obj
    }

    /// Translates one server event. Events for sessions Mochi does not know are still translated:
    /// the caller drops what is not its own (one stream carries every session of the folder).
    static func translate(_ event: [String: Any], state: inout OpenCodeEventState) -> [OpenCodeSignal] {
        guard let type = event["type"] as? String else { return [] }
        let data = event["data"] as? [String: Any] ?? [:]
        let sid = (data["sessionID"] as? String) ?? ((data["form"] as? [String: Any])?["sessionID"] as? String) ?? ""
        guard !sid.isEmpty else { return [] }

        // A subagent (the worker's `task` tool) runs in a session of its own. Its permission and
        // question requests belong to the worker's card; its tool steps keep the worker looking busy;
        // everything else about it (prompts, text, finishing) must not touch the worker.
        if type == "session.created", let parent = data["parentID"] as? String, !parent.isEmpty {
            state.parents[sid] = parent
            state.knownSessions.insert(sid)
            return []
        }
        if state.parents[sid] != nil {
            return translateChild(type: type, data: data, child: sid, state: &state)
        }

        switch type {
        case "session.created":
            state.knownSessions.insert(sid)
            let cwd = ((data["location"] as? [String: Any])?["directory"] as? String)
                ?? ((event["location"] as? [String: Any])?["directory"] as? String)
            return [.session(id: sid, cwd: cwd, event: .start)]

        case "session.deleted":
            state.lastText[sid] = nil
            return [.session(id: sid, cwd: nil, event: .end)]

        case "session.inbox.enqueued":
            guard let item = data["item"] as? [String: Any], (item["type"] as? String) == "user" else { return [] }
            let text = ((item["payload"] as? [String: Any])?["text"] as? String) ?? ""
            state.lastText[sid] = nil
            return [.session(id: sid, cwd: nil, event: .prompt(text))]

        case "session.tool.input.started":
            if let id = data["id"] as? String, let name = data["name"] as? String { state.toolNames[id] = name }
            return []

        case "session.tool.called":
            let callId = data["id"] as? String ?? ""
            let name = state.toolNames[callId] ?? "tool"
            let input = data["input"] as? [String: Any] ?? [:]
            let tool = claudeToolName(name)
            return [.toolStart(id: sid, tool: tool, input: normalizedInput(tool: tool, input: input))]

        case "session.tool.success":
            if let callId = data["id"] as? String { state.toolNames[callId] = nil }
            return [.session(id: sid, cwd: nil, event: .toolEnd)]

        case "session.tool.error", "session.tool.failed":
            let callId = data["id"] as? String ?? ""
            let name = state.toolNames[callId] ?? "tool"
            state.toolNames[callId] = nil
            return [.session(id: sid, cwd: nil, event: .toolFailed(step: claudeToolName(name)))]

        case "session.text.ended":
            if let text = data["text"] as? String, !text.isEmpty { state.lastText[sid] = text }
            return []

        case "permission.asked":
            guard let requestId = data["id"] as? String else { return [] }
            let action = data["action"] as? String ?? "tool"
            let resources = (data["resources"] as? [String]) ?? []
            let tool = permissionTool(action)
            let first = resources.first ?? ""
            let command = action == "shell" ? first : (first.isEmpty ? "" : "\(action) \(first)")
            return [.session(id: sid, cwd: nil, event: .approvalRequested),
                    .approval(id: sid, requestId: requestId, tool: tool, command: command, apiSession: sid)]

        case "permission.replied":
            return [.approvalSettled(id: sid, requestId: (data["requestID"] as? String) ?? "")]

        case "form.created":
            guard let form = data["form"] as? [String: Any], let formId = form["id"] as? String,
                  let (question, map) = askQuestion(fromForm: form) else { return [] }
            return [.session(id: sid, cwd: nil, event: .questionAsked),
                    .question(id: sid, formId: formId, question: question, map: map, apiSession: sid)]

        case "form.replied", "form.cancelled", "form.canceled", "form.settled":
            return [.questionSettled(id: sid, formId: (data["id"] as? String) ?? "")]

        case "session.execution.succeeded":
            let reply = state.lastText[sid]
            state.lastText[sid] = nil
            return [.session(id: sid, cwd: nil, event: .stop(reply: reply, mochi: nil))]

        case "session.execution.failed":
            let error = data["error"] as? [String: Any] ?? [:]
            let message = (error["message"] as? String) ?? "OpenCode failed."
            state.lastText[sid] = nil
            return [.session(id: sid, cwd: nil, event: .stopFailure(kind: failureKind(error["type"] as? String),
                                                                    message: message))]

        case "session.execution.interrupted":
            state.lastText[sid] = nil
            return [.session(id: sid, cwd: nil, event: .interrupt)]

        default:
            return []
        }
    }

    /// Events of a subagent session, as the worker's.
    private static func translateChild(type: String, data: [String: Any], child: String,
                                       state: inout OpenCodeEventState) -> [OpenCodeSignal] {
        let owner = state.root(of: child)
        switch type {
        case "session.tool.input.started":
            if let id = data["id"] as? String, let name = data["name"] as? String { state.toolNames[id] = name }
            return []
        case "session.tool.called":
            let name = state.toolNames[data["id"] as? String ?? ""] ?? "tool"
            let tool = claudeToolName(name)
            return [.toolStart(id: owner, tool: tool, input: normalizedInput(tool: tool, input: data["input"] as? [String: Any] ?? [:]))]
        case "session.tool.success":
            return [.session(id: owner, cwd: nil, event: .toolEnd)]
        case "permission.asked":
            guard let requestId = data["id"] as? String else { return [] }
            let action = data["action"] as? String ?? "tool"
            let first = ((data["resources"] as? [String]) ?? []).first ?? ""
            let command = action == "shell" ? first : (first.isEmpty ? "" : "\(action) \(first)")
            return [.session(id: owner, cwd: nil, event: .approvalRequested),
                    .approval(id: owner, requestId: requestId, tool: permissionTool(action), command: command, apiSession: child)]
        case "permission.replied":
            return [.approvalSettled(id: owner, requestId: (data["requestID"] as? String) ?? "")]
        case "form.created":
            guard let form = data["form"] as? [String: Any], let formId = form["id"] as? String,
                  let (question, map) = askQuestion(fromForm: form) else { return [] }
            return [.session(id: owner, cwd: nil, event: .questionAsked),
                    .question(id: owner, formId: formId, question: question, map: map, apiSession: child)]
        case "form.replied", "form.cancelled", "form.canceled", "form.settled":
            return [.questionSettled(id: owner, formId: (data["id"] as? String) ?? "")]
        default:
            return []
        }
    }

    // MARK: Names

    /// OpenCode's tool names in Claude Code's vocabulary (the strip's step labels know those).
    static func claudeToolName(_ name: String) -> String {
        switch name.lowercased() {
        case "shell", "bash": return "Bash"
        case "write": return "Write"
        case "edit", "patch", "apply_patch": return "Edit"
        case "read": return "Read"
        case "glob": return "Glob"
        case "grep": return "Grep"
        case "list", "ls": return "LS"
        case "webfetch": return "WebFetch"
        case "websearch": return "WebSearch"
        case "todowrite": return "TodoWrite"
        case "task": return "Task"
        default: return name
        }
    }

    /// The input keys the step labels read: `path` stays `path` (they read it), nothing else is needed.
    static func normalizedInput(tool: String, input: [String: Any]) -> [String: Any] {
        var out = input
        if out["file_path"] == nil, let p = (input["path"] ?? input["filePath"]) as? String { out["file_path"] = p }
        return out
    }

    private static func permissionTool(_ action: String) -> String {
        switch action {
        case "shell": return "Bash"
        case "edit": return "Edit"
        case "read": return "Read"
        default: return action
        }
    }

    private static func failureKind(_ type: String?) -> String? {
        guard let type = type?.lowercased() else { return nil }
        if type.contains("rate") { return "rate_limit" }
        if type.contains("auth") || type.contains("credential") { return "authentication_failed" }
        if type.contains("no-route") || type.contains("model") { return "model_not_found" }
        return nil
    }

    // MARK: Forms (OpenCode's questions)

    /// The question card's content for a form: one question per field (the card shows up to 4
    /// questions with up to 4 options each, plus its own "Other…" row for anything else).
    static func askQuestion(fromForm form: [String: Any]) -> (AskQuestion, OpenCodeFormMap)? {
        guard let fields = form["fields"] as? [[String: Any]], !fields.isEmpty else { return nil }
        var items: [AskQuestionItem] = []
        var map = OpenCodeFormMap()
        for field in fields {
            guard let key = field["key"] as? String else { continue }
            guard items.count < 4 else { map.unshownKeys.append(key); continue }
            let title = (field["title"] as? String) ?? ""
            let description = (field["description"] as? String) ?? ""
            let text = !description.isEmpty ? description : (!title.isEmpty ? title : key)
            let type = (field["type"] as? String) ?? "string"
            var options: [AskQuestionOption] = []
            var values: [String: String] = [:]
            for opt in (field["options"] as? [[String: Any]] ?? []).prefix(4) {
                let value = (opt["value"] as? String) ?? ""
                let label = (opt["label"] as? String) ?? value
                guard !label.isEmpty else { continue }
                options.append(AskQuestionOption(label: label, description: (opt["description"] as? String) ?? ""))
                values[label] = value.isEmpty ? label : value
            }
            if type == "boolean", options.isEmpty {
                options = [AskQuestionOption(label: "Yes", description: ""), AskQuestionOption(label: "No", description: "")]
                values = ["Yes": "true", "No": "false"]
            }
            let multi = type == "array"
            items.append(AskQuestionItem(question: text, header: String(title.prefix(12)),
                                         options: options, multiSelect: multi))
            map.keys[text] = key
            map.values[text] = values
            if multi { map.multi.insert(text) }
        }
        guard !items.isEmpty else { return nil }
        return (AskQuestion(questions: items), map)
    }

    /// The card's answers (question text to label, or labels) as OpenCode's `answer` object.
    static func formAnswer(cardAnswers: [String: Any], map: OpenCodeFormMap) -> [String: Any] {
        var out: [String: Any] = [:]
        for (text, key) in map.keys {
            let values = map.values[text] ?? [:]
            func convert(_ label: String) -> String { values[label] ?? label }
            if let many = cardAnswers[text] as? [String] {
                out[key] = many.map(convert)
            } else if let one = cardAnswers[text] as? String {
                out[key] = map.multi.contains(text) ? [convert(one)] : convert(one)
            }
        }
        for key in map.unshownKeys where out[key] == nil { out[key] = "" }
        return out
    }
}

/// The requests (approvals or questions) an OpenCode worker has waiting, per worker: at most one is
/// shown at a time, the rest queue. A shown request can be *parked*: its card went away without an
/// answer, but OpenCode is still waiting, so it stays in the queue and is shown again, silently, when
/// the user selects the worker. Nothing here talks to OpenCode.
struct RequestSlots<Item> {
    private var queued: [String: [(id: String, item: Item)]] = [:]
    private var shown: [String: String] = [:]

    mutating func add(owner: String, id: String, item: Item) {
        guard !(queued[owner] ?? []).contains(where: { $0.id == id }) else { return }
        queued[owner, default: []].append((id, item))
    }

    /// The request to show now: the first in line, when none is shown already.
    func nextToShow(owner: String) -> (id: String, item: Item)? {
        guard shown[owner] == nil, let first = queued[owner]?.first else { return nil }
        return first
    }

    mutating func markShown(owner: String, id: String) { shown[owner] = id }

    /// The card went away unanswered: the request stays queued, nothing is shown.
    mutating func park(owner: String) { shown[owner] = nil }

    func isShown(owner: String, id: String) -> Bool { shown[owner] == id }
    func hasWaiting(owner: String) -> Bool { !(queued[owner] ?? []).isEmpty }

    /// Answered, or settled elsewhere. Returns true when it was the one on screen.
    @discardableResult
    mutating func remove(owner: String, id: String) -> Bool {
        queued[owner]?.removeAll { $0.id == id }
        guard shown[owner] == id else { return false }
        shown[owner] = nil
        return true
    }

    /// The turn ended or the worker went away. Returns true when a card was on screen.
    @discardableResult
    mutating func clear(owner: String) -> Bool {
        queued[owner] = nil
        return shown.removeValue(forKey: owner) != nil
    }
}
