import Foundation

#if !APPSTORE

/// OpenCode as a Mochi worker, with any model OpenCode supports. One private `opencode serve` per
/// project folder (several workers in a folder share it), reached over HTTP and one SSE stream.
/// The runtime is the only source of truth for its sessions: it turns OpenCode's events into
/// session events, and opens Mochi's existing approval and question cards through
/// `PendingRequestResponder.openCode`. Nothing is approved without a click. No server and no stream
/// exist while no worker runs in a folder (0 % CPU).
@MainActor
final class OpenCodeRuntime: AgentRuntime {
    let kind: ProjectCLI = .openCode

    @MainActor private final class Folder {
        let path: String
        let server: OpenCodeServerProcess
        let client: OpenCodeClient
        var streamTask: Task<Void, Never>?
        var eventState = OpenCodeEventState()
        var sessions: Set<String> = []
        var connected = false
        init(path: String, server: OpenCodeServerProcess) {
            self.path = path
            self.server = server
            self.client = server.client()
        }
    }

    private struct QueuedPermission { let request: String; let tool: String; let command: String; let apiSession: String }
    private struct QueuedForm { let form: String; let question: AskQuestion; let map: OpenCodeFormMap; let apiSession: String }

    private var folders: [String: Folder] = [:]
    private var starting: [String: Task<Folder, Error>] = [:]
    private var sessionFolder: [String: String] = [:]
    /// Sessions between a prompt and the end of its turn: a message to one of them is queued.
    private var busy: Set<String> = []
    private var permissions = RequestSlots<QueuedPermission>()
    private var forms = RequestSlots<QueuedForm>()
    private var idleTasks: [String: Task<Void, Never>] = [:]

    /// A session that stays idle this long is let go (and its server stopped, when it was the last
    /// in the folder). A later message starts the server again and continues the same session.
    static let idleRelease: Duration = .seconds(15 * 60)

    // MARK: - AgentRuntime

    func start(projectPath: String, model: ModelRef?, prompt: String?) async throws -> String {
        let folder = try await ensureFolder(projectPath)
        let id = try await folder.client.createSession(directory: projectPath, model: model)
        attach(id, to: folder)
        HookServer.shared.feed(.start, sessionId: id, cwd: projectPath, agent: "opencode")
        if let prompt, !prompt.isEmpty {
            busy.insert(id)
            do { try await folder.client.prompt(session: id, text: prompt) } catch {
                busy.remove(id)
                throw error
            }
        }
        return id
    }

    func send(_ text: String, session: String) async throws {
        let path = sessionFolder[session] ?? AppState.shared.sessionStore.sessions[session]?.cwd ?? ""
        guard !path.isEmpty else { throw OpenCodeClientError.http(status: 0, message: "Unknown session folder.") }
        let folder = try await ensureFolder(path)
        attach(session, to: folder)
        let queue = busy.contains(session)
        busy.insert(session)
        do { try await folder.client.prompt(session: session, text: text, queue: queue) } catch {
            busy.remove(session)
            throw error
        }
    }

    func interrupt(session: String) async {
        guard let folder = folder(of: session) else { return }
        try? await folder.client.interrupt(session: session)
    }

    func stop(session: String) async {
        await interrupt(session: session)
        release(session)
    }

    func handOffToTerminal(session: String) async {
        let path = sessionFolder[session] ?? AppState.shared.sessionStore.sessions[session]?.cwd ?? ""
        await stop(session: session)
        guard MochiTools.isOpenCodeSessionId(session), !path.isEmpty else { return }
        TerminalLauncher.run("opencode --session \(session)", in: path)
    }

    func stopAll() async {
        for id in Array(sessionFolder.keys) { release(id) }
    }

    func owns(_ session: String) -> Bool {
        AppState.shared.workerRuntime(for: session) == .openCode
    }

    /// True while this launch runs the session (its server is up). The hook server ignores the
    /// OpenCode plugin's events for such a session.
    func isLive(_ session: String) -> Bool { sessionFolder[session] != nil }

    /// Quit path (synchronous): no `opencode serve` Mochi started may outlive the app.
    func terminateAllNow() {
        for folder in folders.values {
            folder.streamTask?.cancel()
            folder.server.terminate()
        }
        folders.removeAll()
        sessionFolder.removeAll()
    }

    // MARK: - Replies to OpenCode

    /// `apiSession`: the session OpenCode asked in, when it is a subagent's rather than `session` (the worker).
    func reply(permission requestID: String, session: String, decision: String, apiSession: String? = nil) async {
        guard let folder = folder(of: session) else { return }
        do { try await folder.client.replyPermission(session: apiSession ?? session, request: requestID, decision: decision) }
        catch { appendAppLog("nb.log", "opencode: permission reply failed: \(error.localizedDescription)") }
    }

    func reply(form formID: String, session: String, answer: [String: Any], apiSession: String? = nil) async {
        guard let folder = folder(of: session) else { return }
        let bytes = (try? JSONSerialization.data(withJSONObject: answer)) ?? Data("{}".utf8)
        do { try await folder.client.replyForm(session: apiSession ?? session, form: formID, answerJSON: bytes) }
        catch {
            appendAppLog("nb.log", "opencode: form reply failed: \(error.localizedDescription)")
            AssistantModel.shared.reportRunFailure("OpenCode", error.localizedDescription, aloud: false)
        }
    }

    /// The card's outcome for one request. `.always` reaches OpenCode only from the card's own button.
    /// `.ask` ("answer elsewhere", or the card dismissed) has no meaning for a worker, which has no
    /// terminal: nothing is replied, the request stays pending in OpenCode and here, the worker stays
    /// in its needs-you phase, and the card returns, silently, when the user selects the worker
    /// (`resurface`). It never comes back on its own.
    func deliver(_ outcome: RequestOutcome, session: String, kind: OpenCodeReplyTarget.Kind) async {
        switch kind {
        case .permission(let request, let apiSession):
            if case .ask = outcome { permissions.park(owner: session); return }
            permissions.remove(owner: session, id: request)
            let decision: String
            switch outcome {
            case .allow: decision = "once"
            case .always: decision = "always"
            case .deny, .ask, .answered: decision = "reject"
            }
            await reply(permission: request, session: session, decision: decision, apiSession: apiSession)
            presentNextPermission(session)
        case .form(let formId, let apiSession, let map):
            if case .ask = outcome { forms.park(owner: session); return }
            forms.remove(owner: session, id: formId)
            if case .answered(let answers) = outcome {
                await reply(form: formId, session: session, answer: OpenCodeEvents.formAnswer(cardAnswers: answers, map: map),
                            apiSession: apiSession)
            } else if let folder = folder(of: session) {
                try? await folder.client.cancelForm(session: apiSession, form: formId)
            }
            presentNextForm(session)
        }
    }

    /// The user selected this worker: a parked request shows its card again, silently (no sound, no
    /// pinning, no island expansion).
    func resurface(_ session: String) {
        guard sessionFolder[session] != nil else { return }
        presentNextPermission(session, silent: true)
        presentNextForm(session, silent: true)
    }

    // MARK: - Servers

    private func folder(of session: String) -> Folder? {
        sessionFolder[session].flatMap { folders[$0] }
    }

    private func attach(_ session: String, to folder: Folder) {
        folder.sessions.insert(session)
        sessionFolder[session] = folder.path
        idleTasks[session]?.cancel()
        idleTasks[session] = nil
        if folder.streamTask == nil { startStream(folder) }
    }

    private func ensureFolder(_ path: String) async throws -> Folder {
        if let existing = folders[path] {
            if existing.server.isRunning { return existing }
            discard(existing)
        }
        if let pending = starting[path] { return try await pending.value }
        let task = Task { @MainActor [self] () throws -> Folder in
            guard let cli = await Task.detached(operation: { OpenCodeChat.cliURL() }).value else {
                throw OpenCodeChat.ChatError.cliNotFound
            }
            let server = try await OpenCodeServerLauncher.launch(cli: cli, cwd: path, environment: serverEnvironment(for: path))
            let folder = Folder(path: path, server: server)
            folders[path] = folder
            startStream(folder)
            // Events must be flowing before the first prompt, or its first events are lost.
            for _ in 0..<40 where !folder.connected { try? await Task.sleep(for: .milliseconds(50)) }
            return folder
        }
        starting[path] = task
        defer { starting[path] = nil }
        return try await task.value
    }

    /// The user's own OpenCode data and logins (no sandbox store), plus this project's per-process
    /// config: Mochi's MCP server, the worker note, and asks before edits and shell commands.
    private func serverEnvironment(for path: String) -> [String: String] {
        var env = ClaudeCodeRun.processEnvironment()
        env["PATH"] = "\(NSHomeDirectory())/.opencode/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        env["TMPDIR"] = "/tmp"
        // Same as OpenCodeChat.run: the Zen key authorizes both gateways.
        if let zenKey = OpenCodeChat.zenAPIKey(), !zenKey.isEmpty { env["OPENCODE_API_KEY"] = zenKey }
        env["OPENCODE_CONFIG_CONTENT"] = MochiTools.openCodeConfigContent(hookPath: HookServer.hookScriptPath, owner: path)
        return env
    }

    private func discard(_ folder: Folder) {
        folder.streamTask?.cancel()
        folder.streamTask = nil
        folder.server.terminate()
        folders[folder.path] = nil
    }

    /// Lets a session go. The folder's server stops with its last session.
    private func release(_ session: String) {
        idleTasks[session]?.cancel()
        idleTasks[session] = nil
        busy.remove(session)
        clearRequests(session)
        guard let path = sessionFolder.removeValue(forKey: session), let folder = folders[path] else { return }
        folder.sessions.remove(session)
        if folder.sessions.isEmpty { discard(folder) }
    }

    private func scheduleIdleRelease(_ session: String) {
        idleTasks[session]?.cancel()
        idleTasks[session] = Task { [weak self] in
            try? await Task.sleep(for: Self.idleRelease)
            guard !Task.isCancelled, let self, !self.busy.contains(session) else { return }
            self.release(session)
        }
    }

    // MARK: - The event stream

    private func startStream(_ folder: Folder) {
        folder.streamTask = Task { [weak self] in
            var attempt = 0
            while !Task.isCancelled {
                guard let client = self?.client(for: folder) else { return }
                do {
                    for try await event in client.events() {
                        attempt = 0
                        self?.handle(event, in: folder)
                    }
                } catch {
                    appendAppLog("nb.log", "opencode: event stream ended: \(error.localizedDescription)")
                }
                guard !Task.isCancelled, let self else { return }
                // Nobody to tell about: no stream. A dead server: its sessions failed.
                guard !folder.sessions.isEmpty else { folder.streamTask = nil; return }
                guard folder.server.isRunning else { self.serverDied(folder); return }
                folder.connected = false
                try? await Task.sleep(for: .seconds(OpenCodeReconnect.delay(attempt: attempt)))
                attempt += 1
                if Task.isCancelled { return }
                await self.resync(folder)
            }
        }
    }

    private func client(for folder: Folder) -> OpenCodeClient? { folder.client }

    private func handle(_ event: [String: Any], in folder: Folder) {
        if (event["type"] as? String) == "server.connected" { folder.connected = true; return }
        var state = folder.eventState
        let signals = OpenCodeEvents.translate(event, state: &state)
        folder.eventState = state
        for signal in signals { apply(signal, in: folder) }
    }

    private func apply(_ signal: OpenCodeSignal, in folder: Folder) {
        let hook = HookServer.shared
        switch signal {
        case .session(let id, _, let event):
            guard folder.sessions.contains(id) else { return }
            switch event {
            case .prompt:
                busy.insert(id)
                idleTasks[id]?.cancel()
            case .stop, .stopFailure, .interrupt:
                busy.remove(id)
                clearRequests(id)
                scheduleIdleRelease(id)
            case .end:
                hook.feed(event, sessionId: id, cwd: folder.path, agent: "opencode")
                release(id)
                return
            default: break
            }
            hook.feed(event, sessionId: id, cwd: folder.path, agent: "opencode")
            if case .stopFailure(_, let message) = event {
                AssistantModel.shared.reportRunFailure("OpenCode", message ?? "OpenCode failed.", aloud: false)
            }

        case .toolStart(let id, let tool, let input):
            guard folder.sessions.contains(id) else { return }
            hook.feed(.toolStart(step: hook.stepLabel(tool: tool, input: input)), sessionId: id,
                      cwd: folder.path, agent: "opencode")

        case .approval(let id, let request, let tool, let command, let apiSession):
            guard folder.sessions.contains(id) else { return }
            permissions.add(owner: id, id: request, item: QueuedPermission(request: request, tool: tool, command: command, apiSession: apiSession))
            presentNextPermission(id)

        case .approvalSettled(let id, let request):
            if permissions.remove(owner: id, id: request) {
                hook.dismissWorkerApproval(sessionId: id)
                presentNextPermission(id)
            }

        case .question(let id, let formId, let question, let map, let apiSession):
            guard folder.sessions.contains(id) else { return }
            forms.add(owner: id, id: formId, item: QueuedForm(form: formId, question: question, map: map, apiSession: apiSession))
            presentNextForm(id)

        case .questionSettled(let id, let formId):
            if forms.remove(owner: id, id: formId) {
                hook.dismissWorkerQuestion(sessionId: id)
                presentNextForm(id)
            }
        }
    }

    // MARK: - Cards

    private func presentNextPermission(_ session: String, silent: Bool = false) {
        guard let next = permissions.nextToShow(owner: session), let path = sessionFolder[session] else { return }
        permissions.markShown(owner: session, id: next.id)
        let q = next.item
        let target = OpenCodeReplyTarget(runtime: self, sessionId: session, kind: .permission(requestId: q.request, apiSession: q.apiSession))
        HookServer.shared.presentApproval(sessionId: session, cwd: path, tool: q.tool, command: q.command,
                                          responder: .openCode(target), silent: silent)
    }

    private func presentNextForm(_ session: String, silent: Bool = false) {
        guard let next = forms.nextToShow(owner: session), let path = sessionFolder[session] else { return }
        forms.markShown(owner: session, id: next.id)
        let q = next.item
        let target = OpenCodeReplyTarget(runtime: self, sessionId: session, kind: .form(formId: q.form, apiSession: q.apiSession, map: q.map))
        HookServer.shared.presentQuestion(sessionId: session, cwd: path, question: q.question,
                                          responder: .openCode(target), silent: silent)
    }

    /// The turn is over (or the session let go): any request still waiting on it goes away, unanswered.
    private func clearRequests(_ session: String) {
        if permissions.clear(owner: session) { HookServer.shared.dismissWorkerApproval(sessionId: session) }
        if forms.clear(owner: session) { HookServer.shared.dismissWorkerQuestion(sessionId: session) }
    }

    // MARK: - Failures

    private func serverDied(_ folder: Folder) {
        let ids = folder.sessions
        for id in ids {
            clearRequests(id)
            busy.remove(id)
            sessionFolder[id] = nil
            idleTasks[id]?.cancel()
            idleTasks[id] = nil
            HookServer.shared.feed(.stopFailure(kind: nil, message: "OpenCode stopped unexpectedly."),
                                   sessionId: id, cwd: folder.path, agent: "opencode")
        }
        folder.streamTask = nil
        folders[folder.path] = nil
        AssistantModel.shared.reportRunFailure("OpenCode", "OpenCode stopped unexpectedly. Send again to restart it.",
                                               aloud: false)
    }

    /// After a dropped stream came back: a turn that ended meanwhile is reported as finished.
    private func resync(_ folder: Folder) async {
        guard let active = try? await folder.client.activeSessions() else { return }
        for id in folder.sessions where busy.contains(id) && !active.contains(id) {
            busy.remove(id)
            clearRequests(id)
            HookServer.shared.feed(.stop(reply: folder.eventState.lastText[id], mochi: nil),
                                   sessionId: id, cwd: folder.path, agent: "opencode")
            scheduleIdleRelease(id)
        }
    }
}
#else
#endif
