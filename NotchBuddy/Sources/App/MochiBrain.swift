import Foundation

#if !APPSTORE

/// Mochi's own small tool-calling loop, with its own model (Settings → Mochi assistant), independent
/// of Chat. It works only through six tools; project work is handed to an agent running in that
/// project (a Mochi worker). The user sees the brain as one more small Mochi named "Mochi": its
/// finished card shows the line it ends every turn with. Network calls go only to the provider the
/// user picked. GitHub build only (`WorkerManager.isAvailable`).
@MainActor
final class MochiBrain {
    static let shared = MochiBrain()
    static let sessionId = MochiDigest.brainSessionId
    /// A folder-less name for the session: its last path component is the workspace shown ("Mochi").
    private static let cwd = "/Mochi"
    static let maxSteps = 8

    private let state = AppState.shared
    private var history: [BrainMessage] = []
    private var loaded = false
    private var running: Task<Void, Never>?
    private var queued: [String] = []
    private var question: BrainAnswerBox?
    /// The `report` of the turn in flight (Claude login: it is the card's line).
    private var turnReport: MochiNote?

    private init() {}

    // MARK: - Availability

    /// On, and the picked provider has a key (or a local server address).
    /// With the Claude Code login: on, and the `claude` CLI found (Coucou's hooks are not needed).
    var isAvailable: Bool {
        guard WorkerManager.isAvailable, state.mochiBrainEnabled else { return false }
        if case .claudeLogin = state.mochiBrainProvider { return ClaudeBrainSession.cliAvailable }
        return makeClient() != nil
    }

    /// Why the assistant can or cannot run, in one line (Settings shows it; the bar says it when it is on but not ready).
    var status: (text: String, ok: Bool) {
        let kind: BrainReadiness.Kind
        var name = state.mochiBrainProvider.displayName
        var hasKey = false, address = false, zen = false
        switch state.mochiBrainProvider {
        case .claudeLogin: kind = .claudeLogin
        case .chat(let p):
            name = p.displayName
            switch p {
            case .ollama, .lmstudio:
                kind = .local
                address = !LocalChat.normaliseURL(p == .ollama ? state.ollamaServerURL : state.lmstudioServerURL).isEmpty
            case .opencode: kind = .opencode; zen = OpenCodeChat.zenAPIKey() != nil
            case .anthropic, .openai, .google:
                kind = p == .anthropic ? .anthropicAPI : .apiKey
                hasKey = KeychainStore.shared.get(p.keychainKey)?.isEmpty == false
            }
        }
        return BrainReadiness.status(enabled: state.mochiBrainEnabled, kind: kind, providerName: name, hasKey: hasKey,
                                     localAddressSet: address, zenSignedIn: zen, cliFound: ClaudeBrainSession.cliAvailable)
    }

    /// On but not usable: the reason. nil when off or ready.
    var unavailableReason: String? {
        guard state.mochiBrainEnabled, !isAvailable else { return nil }
        let s = status
        return s.ok ? "Mochi\u{2019}s assistant isn\u{2019}t available in this build." : s.text
    }

    private func makeClient() -> ModelClient? {
        guard case .chat(let provider) = state.mochiBrainProvider else { return nil }
        let model = state.mochiBrainEffectiveModel
        func key(_ name: String) -> String? {
            guard let k = KeychainStore.shared.get(name)?.trimmingCharacters(in: .whitespacesAndNewlines), !k.isEmpty else { return nil }
            return k
        }
        switch provider {
        case .anthropic:
            return key(provider.keychainKey).map { AnthropicModelClient(apiKey: $0, model: model) }
        case .openai:
            return key(provider.keychainKey).map { OpenAICompatibleModelClient(baseURL: ProviderEndpoints.openAI, apiKey: $0, model: model) }
        case .google:
            return key(provider.keychainKey).map { OpenAICompatibleModelClient(baseURL: ProviderEndpoints.google, apiKey: $0, model: model) }
        case .ollama, .lmstudio:
            // The same rule Chat uses (`LocalChat.openAIBase`): <address>/v1/chat/completions.
            let base = LocalChat.openAIBase(provider == .ollama ? state.ollamaServerURL : state.lmstudioServerURL)
            return base.isEmpty ? nil : OpenAICompatibleModelClient(baseURL: base, apiKey: nil, model: model)
        case .opencode:
            // OpenCode Go models only: the gateway takes the bare model name, not the catalog's "opencode-go/…".
            guard BrainModels.isOpenCodeGo(model), let route = BrainModels.openCodeRoute(model) else { return nil }
            // OpenCode Go routes and caches by a stable id per conversation (opencode.ai/docs/go).
            let session = Self.conversationId
            return OpenCodeChat.zenAPIKey().map {
                OpenAICompatibleModelClient(baseURL: route.baseURL, apiKey: $0, model: route.model,
                                            extraHeaders: ["x-opencode-session": session])
            }
        }
    }

    // MARK: - Public

    /// One message from the user. A message that arrives mid-loop waits its turn.
    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if running != nil { queued.append(trimmed); return }
        start(trimmed)
    }

    /// Forgets the conversation: memory, file, and the Mochi in the strip.
    func reset() {
        running?.cancel()
        running = nil
        queued.removeAll()
        question?.resolve(BrainAnswerBox.dismissed)
        question = nil
        HookServer.shared.dismissWorkerQuestion(sessionId: Self.sessionId)
        ClaudeBrainSession.shared.reset()
        UserDefaults.standard.removeObject(forKey: Self.conversationIdKey)
        history.removeAll()
        loaded = true
        try? FileManager.default.removeItem(at: Self.historyURL)
        feed(.end)
    }

    /// One id per conversation, kept across launches, new after "Clear Mochi's conversation".
    private static let conversationIdKey = "mochiBrainConversationId"
    static var conversationId: String {
        if let id = UserDefaults.standard.string(forKey: conversationIdKey), !id.isEmpty { return id }
        let id = "mochi-" + UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: conversationIdKey)
        return id
    }

    // MARK: - The loop

    private func start(_ text: String) {
        running = Task { [weak self] in
            await self?.run(text)
            guard let self else { return }
            self.running = nil
            if !self.queued.isEmpty { self.start(self.queued.removeFirst()) }
        }
    }

    private func run(_ text: String) async {
        if case .claudeLogin = state.mochiBrainProvider { await runClaude(text); return }
        loadHistoryIfNeeded()
        guard let client = makeClient() else {
            AssistantModel.shared.reportBrainFailure("Pick a model for Mochi in Settings \u{2192} Mochi assistant.", restoring: text)
            return
        }
        // The loop works on a copy: if the model fails, nothing it said is kept and a retry starts here.
        var work = history
        work.append(.user(text))
        feed(.prompt(text))
        do {
            let outcome = try await BrainLoop.run(
                client: client, system: MochiTools.brainPrompt, tools: MochiTools.brainTools(), history: &work,
                maxSteps: Self.maxSteps,
                execute: { [self] call in await execute(call) },
                onGiveUp: { [self] note in feed(.mochiReport(note)) })
            guard !Task.isCancelled else { return }
            history = work
            if outcome.finished {
                feed(.stop(reply: outcome.finalText.isEmpty ? outcome.report?.line : outcome.finalText, mochi: nil))
            } else {
                feed(.stop(reply: "I ran out of steps before finishing. Try again, or ask for something smaller.", mochi: nil))
            }
            saveHistory()
        } catch is CancellationError {
            return
        } catch {
            feed(.end)
            AssistantModel.shared.reportBrainFailure(error.localizedDescription, restoring: text)
        }
    }

    /// One turn on the Claude Code login: the conversation lives in that session, the tools come back
    /// over MCP (`MochiMCP`, role brain) into `executeTool`. The turn ends on the stream's `result`.
    private func runClaude(_ text: String) async {
        guard ClaudeBrainSession.cliAvailable else {
            AssistantModel.shared.reportBrainFailure("Claude Code not found.", restoring: text)
            return
        }
        turnReport = nil
        feed(.prompt(text))
        do {
            let r = try await ClaudeBrainSession.shared.ask(text, model: state.mochiBrainEffectiveModel)
            guard !Task.isCancelled else { return }
            if r.isError {
                abandonQuestion()
                feed(.end)
                AssistantModel.shared.reportBrainFailure(r.text.isEmpty ? (r.firstError ?? "Claude Code failed.") : r.text, restoring: text)
                return
            }
            let line = turnReport?.line ?? (r.text.isEmpty ? nil : MochiTools.firstSentence(r.text))
            feed(.stop(reply: line, mochi: nil))
        } catch is CancellationError {
            return
        } catch {
            abandonQuestion()
            feed(.end)
            AssistantModel.shared.reportBrainFailure(error.localizedDescription, restoring: text)
        }
    }

    private func abandonQuestion() {
        question?.resolve(BrainAnswerBox.dismissed)
        question = nil
        HookServer.shared.dismissWorkerQuestion(sessionId: Self.sessionId)
    }

    /// A tool call from the Claude-login brain's MCP client. Refused unless that provider is the one on.
    func executeMCPTool(name: String, argumentsJSON: String) async -> (text: String, isError: Bool) {
        guard state.mochiBrainEnabled, case .claudeLogin = state.mochiBrainProvider else {
            return ("Mochi is not set to think with the Claude Code login.", true)
        }
        let call = BrainToolCall(id: UUID().uuidString, name: name, argumentsJSON: argumentsJSON)
        let r = await execute(call)
        return (r.text, r.isError)
    }

    // MARK: - Tools

    /// Runs one tool. The one implementation behind both the API-key loop and the Claude-login MCP calls.
    private func execute(_ call: BrainToolCall) async -> BrainToolResult {
        guard MochiTools.brainToolNames.contains(call.name) else {
            return BrainToolResult(text: "Unknown tool \u{201C}\(call.name)\u{201D}. Use one of: \(MochiTools.brainToolNames.joined(separator: ", ")).", isError: true)
        }
        guard call.argumentsAreValid else { return BrainToolResult(text: "The arguments were not a JSON object.", isError: true) }
        let args = call.arguments
        func fail(_ text: String) -> BrainToolResult { BrainToolResult(text: text, isError: true) }
        switch call.name {
        case "list_projects": return BrainToolResult(text: await listProjects())
        case "project_status": return BrainToolResult(text: await projectStatus(project: args["project"] as? String))
        case "start_project_work":
            guard let project = args["project"] as? String, let task = args["task"] as? String,
                  !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return fail("start_project_work needs `project` and `task`.")
            }
            let r = await startWork(project: project, task: task, runtime: BrainToolArgs.runtime(from: args["runtime"]),
                                    model: args["model"] as? String)
            return BrainToolResult(text: r.text, isError: r.isError)
        case "send_to_project":
            guard let project = args["project"] as? String, let message = args["message"] as? String,
                  !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return fail("send_to_project needs `project` and `message`.")
            }
            let r = await sendToProject(project: project, message: message)
            return BrainToolResult(text: r.text, isError: r.isError)
        case "ask_user":
            guard let q = BrainToolArgs.question(from: args) else { return fail("ask_user needs a `question` and 2 to 4 `choices`.") }
            return BrainToolResult(text: await ask(q))
        case "report":
            guard let note = MochiTools.parseReport(args) else { return fail("report needs a non-empty `line`.") }
            turnReport = note
            feed(.mochiReport(note))
            if state.speakMochiUpdates, let line = note.line { MochiSpeech.shared.say(line) }
            return BrainToolResult(text: "Shown to the user.", note: note)
        case "open_app":
            guard let name = MacActionLogic.appName(from: args) else { return fail("open_app needs an app `name` (a name, not a path).") }
            let r = await MacActions.openApp(name)
            return BrainToolResult(text: r.text, isError: r.isError)
        case "open_url":
            guard let req = MacActionLogic.urlRequest(from: args) else { return fail("open_url needs an http or https `url`.") }
            let r = await MacActions.openURL(req.url, in: req.app)
            return BrainToolResult(text: r.text, isError: r.isError)
        case "open_file":
            guard let req = MacActionLogic.fileRequest(from: args) else { return fail("open_file needs an absolute `path` (or one starting with ~).") }
            let r = MacActions.openFile(req.path, reveal: req.reveal)
            return BrainToolResult(text: r.text, isError: r.isError)
        default:
            return fail("Unknown tool.")
        }
    }

    private func projects() async -> [KnownProject] { await AssistantModel.shared.projectsForBrain() }

    private func listProjects() async -> String {
        let list = await projects().prefix(40)
        guard !list.isEmpty else { return "No projects found in the user's Claude Code or OpenCode history." }
        let iso = ISO8601DateFormatter()
        let rows: [[String: Any]] = list.map { p in
            var row: [String: Any] = ["name": p.name, "path": p.path, "agent": usualRuntime(for: p).displayName]
            if let used = p.lastUsed { row["lastUsed"] = iso.string(from: used) }
            return row
        }
        return json(rows)
    }

    private func usualRuntime(for p: KnownProject) -> ProjectCLI {
        ProjectLaunchLogic.cli(override: nil, setting: AssistantModel.shared.cliSetting(for: p.path), project: p,
                               fallback: ProjectCLI(rawValue: state.defaultCLI) ?? .claudeCode)
    }

    private func projectStatus(project: String?) async -> String {
        var sessions = state.sessionStore.sessions.values.filter { $0.id != Self.sessionId }
        if let project, !project.trimmingCharacters(in: .whitespaces).isEmpty {
            let known = await projects()
            let paths = Set(ProjectLaunchLogic.candidates(for: project, in: known).map(\.path))
            let q = ProjectLaunchLogic.normalize(project)
            sessions = sessions.filter { paths.contains($0.cwd) || (q.count >= 3 && ProjectLaunchLogic.normalize($0.workspace).contains(q)) }
        }
        guard !sessions.isEmpty else { return "No sessions are running." }
        let rows: [[String: Any]] = sessions.sorted { $0.lastEventAt > $1.lastEventAt }.prefix(20).map { s in
            var row: [String: Any] = ["project": s.workspace, "agent": s.kind.displayName, "phase": s.phase.rawValue,
                                      "mochiWorker": WorkerManager.shared.isWorker(s.id)]
            if let p = s.lastPrompt { row["lastRequest"] = String(p.prefix(200)) }
            if let line = s.mochi?.line { row["lastReport"] = line }
            return row
        }
        return json(rows)
    }

    private enum Resolved { case one(KnownProject), error(String) }

    private func resolve(_ name: String) async -> Resolved {
        let known = await projects()
        let hits = ProjectLaunchLogic.candidates(for: name, in: known)
        switch hits.count {
        case 1: return .one(hits[0])
        case 0:
            let names = known.prefix(8).map(\.name).joined(separator: ", ")
            return .error("No project called \u{201C}\(name)\u{201D}. Known projects: \(names.isEmpty ? "none" : names).")
        default:
            return .error("Several projects fit \u{201C}\(name)\u{201D}: \(hits.prefix(6).map(\.name).joined(separator: ", ")). Ask the user which one with ask_user.")
        }
    }

    private func startWork(project: String, task: String, runtime: ProjectCLI?, model: String?) async -> (text: String, isError: Bool) {
        let target: KnownProject
        switch await resolve(project) {
        case .one(let p): target = p
        case .error(let e): return (e, true)
        }
        return await start(in: target, task: task, runtime: runtime, model: model)
    }

    private func start(in target: KnownProject, task: String, runtime: ProjectCLI?, model: String?) async -> (text: String, isError: Bool) {
        let chosen = runtime ?? usualRuntime(for: target)
        var ref: ModelRef?
        if let model, !model.trimmingCharacters(in: .whitespaces).isEmpty {
            switch chosen {
            case .openCode:
                guard let r = ModelRef.openCode(catalogId: model) else {
                    return ("OpenCode models are written provider/model, like openai/gpt-5.", true)
                }
                ref = r
            case .claudeCode:
                ref = ModelRef.claude(model)
            }
        }
        do {
            _ = try await WorkerManager.shared.start(projectPath: target.path, runtime: chosen, model: ref, prompt: task)
            let used = ref?.label ?? state.defaultWorkerModel(for: chosen)?.label ?? "default model"
            return ("Started in \(target.name) with \(chosen.displayName)/\(used).", false)
        } catch {
            return ("Could not start \(chosen.displayName) in \(target.name): \(WorkerManager.message(for: error))", true)
        }
    }

    private func sendToProject(project: String, message: String) async -> (text: String, isError: Bool) {
        let target: KnownProject
        switch await resolve(project) {
        case .one(let p): target = p
        case .error(let e): return (e, true)
        }
        let workers = state.sessionStore.sessions.values
            .filter { $0.cwd == target.path && WorkerManager.shared.isWorker($0.id) }
            .sorted { $0.lastEventAt > $1.lastEventAt }
        guard let worker = workers.first else {
            return await start(in: target, task: message, runtime: nil, model: nil)
        }
        if worker.phase == .approval || worker.phase == .question {
            return ("The agent in \(target.name) is waiting for the user to answer a card. Tell the user; do not send now.", true)
        }
        guard await WorkerManager.shared.send(message, toSession: worker.id) else {
            return await start(in: target, task: message, runtime: nil, model: nil)
        }
        return ("Sent to \(target.name).", false)
    }

    /// Opens the existing question card and waits for the user, however long it takes.
    private func ask(_ q: AskQuestion) async -> String {
        question?.resolve(BrainAnswerBox.dismissed)
        let box = BrainAnswerBox()
        question = box
        feed(.questionAsked)
        HookServer.shared.presentQuestion(sessionId: Self.sessionId, cwd: Self.cwd, question: q,
                                          responder: .brain(box), agent: "mochi-brain")
        let answer = await box.wait()
        if question === box { question = nil }
        return answer
    }

    // MARK: - Session and history

    private func feed(_ event: SessionEvent) {
        HookServer.shared.feed(event, sessionId: Self.sessionId, cwd: Self.cwd, agent: "mochi-brain")
    }

    private func json(_ rows: [[String: Any]]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }

    /// The last 40 messages, on disk beside the app's other support files. No keys: only the words
    /// exchanged, project names and statuses.
    private static var historyURL: URL { HookServer.supportDir.appendingPathComponent("mochi-brain.json") }

    private func loadHistoryIfNeeded() {
        guard !loaded else { return }
        loaded = true
        if let data = try? Data(contentsOf: Self.historyURL),
           let saved = try? JSONDecoder().decode([BrainMessage].self, from: data) { history = BrainHistory.trimmed(saved) }
    }

    private func saveHistory() {
        history = BrainHistory.trimmed(history)
        guard let data = try? JSONEncoder().encode(history) else { return }
        try? FileManager.default.createDirectory(at: HookServer.supportDir, withIntermediateDirectories: true)
        try? data.write(to: Self.historyURL, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.historyURL.path)
    }
}
#else

/// App Store build: Mochi runs no agents and has no assistant. The same calls compile to nothing.
@MainActor
final class MochiBrain {
    static let shared = MochiBrain()
    static let sessionId = MochiDigest.brainSessionId
    var isAvailable: Bool { false }
    var unavailableReason: String? { nil }
    func send(_ text: String) {}
    func reset() {}
}
#endif
