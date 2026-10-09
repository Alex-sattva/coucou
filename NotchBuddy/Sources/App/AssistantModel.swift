import AppKit
import Combine
import Foundation

/// Presentation state of the assistant layer: who holds the main spot, which small Mochi sits in
/// which slot, and which small Mochi the user clicked. The decisions themselves live in the pure
/// `AssistantLogic.swift`; this class only feeds them from `AppState` and publishes the result.
@MainActor
final class AssistantModel: ObservableObject {
    static let shared = AssistantModel()

    /// Session that holds the main spot (left of the camera), nil when there are no sessions.
    @Published private(set) var mainId: String?
    /// Small Mochis, in slot order. A slot never moves while its agent lives (`SubSlotOrder`).
    @Published private(set) var subOrder: [String] = []
    /// Slot that takes the previous main's colour after a hand-off lands (used by the Step 8 motion).
    @Published private(set) var recolourIndex: Int?

    // MARK: Hand-off (Step 8)
    //
    // When `mainId` changes the plan (`HandoffPlanner`) is decided in the same `recompute` that
    // changes `mainId` / `subOrder`, so the strip never renders a frame with the new occupant:
    // `slotHolds` already makes the slot keep showing the old one until the dot has landed.

    /// New slot occupant -> the agent that slot keeps showing until landing.
    @Published private(set) var slotHolds: [String: String] = [:]
    /// The flight in the air. nil when idle: the overlay (and its timeline) is not mounted.
    @Published private(set) var flight: AssistantFlight?
    /// Mochi's one-line take per session id, and the reply each line was written for.
    @Published private var mochiLines: [String: String] = [:]
    private var mochiLineSource: [String: String] = [:]
    private var handsFreeTask: Task<Void, Never>?
    /// Session titles as the agent's own app shows them (Claude sidebar, OpenCode), by session id.
    @Published private var titles: [String: String] = [:]
    /// When each session's title was last read, and the event it was read for.
    private var titleReadFor: [String: Date] = [:]
    /// Bumped at landing (or at once without a flight): the main Mochi hops.
    @Published private(set) var hopToken = 0
    /// Per-frame lerp rate of the main Mochi's body colour for the latest change of main.
    @Published private(set) var colorBlendRate: Double = HandoffPlanner.quickBlendRate
    private var handoffTask: Task<Void, Never>?
    private var flightCounter = 0

    /// Set when the user clicks a small Mochi; cleared when the island leaves the expanded mode.
    @Published private(set) var selectedId: String?
    @Published private(set) var sessions: [String: AgentSession] = [:]

    // MARK: Panel open / dismiss
    //
    // open = summoned || selectedId != nil || (queue not empty && queue signature != dismissed signature)
    // States: closed -> open (a need appears, the user summons, or the user clicks a small Mochi);
    // open -> closed (Esc / the island folds: `dismiss()` stores the queue signature, clears summon and
    // selection). A new need changes the signature and reopens. The rule itself is pure:
    // `AssistantOpenRules` in AssistantLogic.swift.

    /// The user asked for the panel (click on the notch, shortcut). Cleared by `dismiss()`.
    @Published private(set) var summoned = false
    /// Set by voice and by a launch: the bar is in use even with no folder behind it.
    @Published private(set) var barInUse = false
    /// The router asked which one; waiting for the user's pick.
    @Published private(set) var pendingClarify: PendingClarify?
    /// A new session waiting for the confirm card's click.
    @Published private(set) var pendingLaunch: PendingLaunch?
    /// Folders from Claude Code's and OpenCode's history, newest first (`ProjectScanner`).
    @Published private(set) var knownProjects: [KnownProject] = []
    @Published private(set) var dismissedSignature: String?
    @Published private(set) var isOpen = false
    /// The card the panel shows for the main session. Decides the panel height.
    @Published private(set) var panelContent: AssistantPanelContent = .bar
    /// Sessions that need the user (approval / question / blocked, then finished-and-unseen).
    @Published private(set) var queue: [AgentSession] = []
    /// The finished card shows its diff in place instead of the file list.
    @Published private(set) var showsDiff = false

    /// One-line error shown in the bar (nothing launched, or a run that failed while the panel is open).
    @Published private(set) var barError: String?
    /// Words that did not reach Mochi's brain (it failed): the panel puts them back in the bar.
    @Published private(set) var restoredBarText: String?

    /// "Thinking…" while the words are routed, then where they were sent until the panel closes.
    @Published private(set) var barStatus: AssistantBarLogic.Status?
    /// The request being handled was spoken: Mochi answers out loud (`MochiSpeech`).
    private var answerAloud = false
    private var sentCloseTask: Task<Void, Never>?

    private let state = AppState.shared
    private var contextWorkspace: String?
    // Latest pending requests, as emitted (the @Published properties are still the old value then).
    private var approvals: [String: ApprovalInfo] = [:]
    private var questions: [String: PendingQuestion] = [:]
    private var cancellables = Set<AnyCancellable>()
    private var wasExpanded = false
    /// The current voice session opened the panel itself (so it closes it again when nothing is sent).
    private var voiceOpenedPanel = false

    private init() {
        // @Published emits on willSet: use the emitted values, never read the property back.
        state.$sessionStore
            .sink { [weak self] store in
                MainActor.assumeIsolated { self?.recompute(sessions: store.sessions) }
            }
            .store(in: &cancellables)
        state.$contextWorkspace
            .sink { [weak self] ws in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.contextWorkspace = ws
                    self.recompute(sessions: self.sessions)
                }
            }
            .store(in: &cancellables)
        state.$pendingApprovals
            .sink { [weak self] value in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.approvals = value
                    self.recompute(sessions: self.sessions)
                }
            }
            .store(in: &cancellables)
        state.$pendingQuestions
            .sink { [weak self] value in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.questions = value
                    self.recompute(sessions: self.sessions)
                }
            }
            .store(in: &cancellables)
        // A voice error (permission off, recogniser unavailable) shows in the bar like any other.
        VoiceInput.shared.$error
            .compactMap { $0 }
            .sink { [weak self] message in
                MainActor.assumeIsolated { self?.barError = message }
            }
            .store(in: &cancellables)
        // The microphone closing releases a digest that waited for the user to finish talking.
        VoiceInput.shared.$phase
            .sink { [weak self] phase in
                MainActor.assumeIsolated { if phase == .idle { self?.selectPendingDigest(voiceActive: false) } }
            }
            .store(in: &cancellables)
        state.$mode
            .sink { [weak self] mode in
                MainActor.assumeIsolated { self?.modeChanged(mode) }
            }
            .store(in: &cancellables)
    }

    var mainSession: AgentSession? { mainId.flatMap { sessions[$0] } }

    /// Small Mochis in slot order (only live sessions).
    var subs: [AgentSession] { subOrder.compactMap { sessions[$0] } }

    /// What the strip draws: like `subs`, but a slot in a hand-off still shows its old occupant.
    var displaySubs: [AgentSession] {
        let shown = SlotDisplay.ids(order: subOrder, holds: slotHolds)
        return zip(subOrder, shown).compactMap { sessions[$1] ?? sessions[$0] }
    }

    /// A small Mochi was clicked: it takes the main spot until the island folds back.
    func select(_ id: String) {
        guard sessions[id] != nil else { return }
        selectedId = id
        // A worker request whose card was dismissed unanswered shows again now, silently.
        if WorkerManager.shared.isWorker(id) { WorkerManager.shared.resurfaceRequests(for: id) }
        recompute(sessions: sessions)
    }

    func clearSelection() {
        guard selectedId != nil else { return }
        selectedId = nil
        recompute(sessions: sessions)
    }

    /// Open the panel on purpose (click on the notch, shortcut).
    func summon() {
        guard !summoned else { return }
        summoned = true
        recompute(sessions: sessions)
    }

    /// Esc, or the island folded while the panel was open. Remembers the current needs so the
    /// panel stays shut until something new needs the user.
    func dismiss() {
        VoiceInput.shared.cancel()   // a closed panel never keeps the microphone open
        sentCloseTask?.cancel()
        sentCloseTask = nil
        barStatus = nil
        summoned = false
        barInUse = false
        pendingLaunch = nil
        pendingClarify = nil
        selectedId = nil
        showsDiff = false
        dismissedSignature = queue.isEmpty ? nil : AssistantOpenRules.signature(queue: queue)
        recompute(sessions: sessions)
    }

    func setShowsDiff(_ on: Bool) {
        guard showsDiff != on else { return }
        showsDiff = on
        recompute(sessions: sessions)
    }

    /// "Got it" and the 8 s fold: the finished session is no longer a need.
    func markSeen(_ id: String) {
        var store = state.sessionStore
        store.markSeen(id)
        if store != state.sessionStore { state.sessionStore = store }
    }

    /// The island must not fold on its own while the panel is open on something that needs the user.
    var holdsIslandOpen: Bool {
        isOpen && (!queue.isEmpty || VoiceInput.shared.isActive || barStatus != nil)
    }

    /// Whether the assistant panel draws `view` right now (`AssistantRouting`).
    func routesToPanel(_ view: IslandView) -> Bool {
        // Mochi's brain needs no folder: with it on, the bar always has somewhere to send text.
        AssistantRouting.usesPanel(isOverview: view == .overview,
                                   hasFolder: taskFolder != nil || barInUse || MochiBrain.shared.isAvailable,
                                   isAlertView: view.isAlertView,
                                   hasSessionNeed: !queue.isEmpty)
    }

    /// The head of the queue is blocking (approval / question / blocked), not just a finished card.
    var hasBlockingNeed: Bool {
        guard let head = queue.first else { return false }
        return head.phase != .finished
    }

    /// The pending approval of the main session (the card on screen acts on this session id only).
    var mainApproval: ApprovalInfo? { mainId.flatMap { approvals[$0] } }
    var mainQuestion: PendingQuestion? { mainId.flatMap { questions[$0] } }

    /// Files the main session changed, one row per path (added/removed summed), in first-touched order.
    func changedFiles(for sessionId: String) -> [AssistantChangedFile] {
        AssistantChangedFile.group(state.sessionFileDiffs[sessionId] ?? [])
    }

    // MARK: - Pile-up digest
    //
    // Three or more sessions needing the user at once get one line from Mochi (`MochiDigest`), built
    // from the session store: no model call, so it works with the assistant on or off. One digest per
    // pile-up: it needs the count to have been below 3 at the previous check, and 60 s since the last.

    private var digestState = MochiDigest.State()
    /// Posted but not yet brought to the main spot (the user was typing or talking).
    private var digestSelectPending = false
    /// The bar field has keyboard focus (reported by the panel). The digest never steals the spot then.
    private var barHasFocus = false

    func setBarFocused(_ on: Bool) {
        barHasFocus = on
        if !on { selectPendingDigest() }
    }

    private func evaluateDigest(_ all: [String: AgentSession]) {
        guard WorkerManager.isAvailable else { return }
        let count = MochiDigest.needCount(all.values)      // one pass; nothing else is built unless a digest is due
        // Mochi's own question card up: a digest would talk over it. It is put off, and posted when
        // that card is answered if the pile is still there (`MochiDigest.State`).
        let blocked = all[MochiDigest.brainSessionId]?.phase == .question
        guard digestState.evaluate(count: count, blocked: blocked, now: Date()) else { return }
        let note = MochiDigest.note(sessions: Array(all.values), titles: titles)
        // recompute runs inside the store's own change notification: post on the next turn.
        Task { @MainActor [weak self] in self?.postDigest(note) }
    }

    private func postDigest(_ note: MochiNote) {
        let line = note.line ?? ""
        HookServer.shared.feed(.stop(reply: line, mochi: note), sessionId: MochiDigest.sessionId,
                               cwd: "/Mochi", agent: "mochi-brain")
        if state.speakMochiUpdates { MochiSpeech.shared.say(line) }
        digestSelectPending = true
        selectPendingDigest()
    }

    /// Brings the digest to the main spot, unless the user is typing or the microphone is open: then
    /// it waits and shows when they are done.
    private func selectPendingDigest(voiceActive: Bool? = nil) {
        guard digestSelectPending, !barHasFocus, !(voiceActive ?? VoiceInput.shared.isActive) else { return }
        guard sessions[MochiDigest.sessionId] != nil else { return }
        digestSelectPending = false
        select(MochiDigest.sessionId)
    }

    // MARK: - The bar: OpenCode tasks

    /// Where a task from the bar would run (nil: the bar is disabled).
    var taskFolder: AssistantTaskFolder? {
        AssistantBarLogic.folder(main: mainSession, contextWorkspace: contextWorkspace,
                                 sessions: Array(sessions.values))
    }

    /// Where the bar's text goes right now: the same OpenCode chat, the same Claude Code session,
    /// or a new OpenCode task.
    var barTarget: AssistantBarLogic.Target {
        AssistantBarLogic.target(main: mainSession, isWorker: mainSession.map { WorkerManager.shared.isWorker($0.id) } ?? false)
    }

    /// The bar's text goes to Mochi's assistant, whatever session is shown: it is on with a usable
    /// model, and the main session is not a Mochi worker that takes the words itself (`submitTask`).
    var barGoesToMochi: Bool {
        if let main = mainSession, WorkerManager.shared.isWorker(main.id),
           main.phase != .approval, main.phase != .question { return false }
        return MochiBrain.shared.isAvailable
    }

    func clearBarError() {
        if barError != nil { barError = nil }
    }

    /// Enter in the bar. Continues the main OpenCode chat or Claude Code session when it is done
    /// (`barTarget`), otherwise starts a new `opencode` session in the main session's folder;
    /// closes the panel either way. Never sends into a busy session, nor into Codex.
    /// A failure shows in `barError` and the bar keeps its text.
    func submitTask(_ text: String, spoken: Bool = false) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, barStatus == nil else { return }
        answerAloud = spoken
        barError = nil
        // The words go straight to a Mochi worker in the main spot, unchanged (it is not waiting on a card).
        if let main = mainSession, WorkerManager.shared.isWorker(main.id),
           main.phase != .approval, main.phase != .question {
            sendToSession(trimmed)
            return
        }
        // Otherwise to Mochi's brain, when it is on and has a usable model. Off or unusable: the router
        // below runs exactly as before.
        if MochiBrain.shared.isAvailable {
            MochiBrain.shared.send(trimmed)
            confirmSentToMochi()
            return
        }
        // On but not ready: say why. Falling through to the rules router would look like Mochi ignored the request.
        if let reason = MochiBrain.shared.unavailableReason {
            showBarError(reason)
            return
        }
        barStatus = .thinking
        // Settings → Understanding. Claude needs the Anthropic key (the one Chat uses).
        let key = state.routerBackend == "claude" ? KeychainStore.shared.get("anthropic-api-key") : nil
        Task { [weak self] in
            guard let self else { return }
            // Claude takes a second anyway: re-read history so a project used since the last scan is
            // there. The rules use the cache and re-read only on a miss (below).
            let projects = key?.isEmpty == false ? await self.rescanProjects() : await self.loadProjects()
            var input = self.makeRouterInput(trimmed, projects: projects)
            var decision = RuleRouter.decide(input)
            if let key, !key.isEmpty {
                do {
                    decision = try await ClaudeIntentRouter(apiKey: key).route(input)
                } catch {
                    // Never the user's words: only why Claude was skipped.
                    appendAppLog("nb.log", "router: claude failed (\(error)), used rules")
                }
            } else if decision.action == .none, input.mainSessionId == nil {
                // The rules missed with nothing to reply to: a project used since the last scan?
                input = self.makeRouterInput(trimmed, projects: await self.rescanProjects())
                decision = RuleRouter.decide(input)
            }
            self.barStatus = nil
            self.execute(decision.validated(against: input))
        }
    }

    /// What the router sees: the words, the running sessions (short, no transcripts) and up to 40
    /// projects, newest first.
    private func makeRouterInput(_ text: String, projects: [KnownProject]) -> RouterInput {
        let list = sessions.values.sorted { $0.lastEventAt > $1.lastEventAt }
        return RouterInput(
            utterance: text,
            sessions: list.map {
                RouterSession(id: $0.id, agent: $0.kind.displayName, workspace: $0.workspace, cwd: $0.cwd,
                              phase: $0.phase.rawValue, title: title(for: $0),
                              lastPrompt: $0.lastPrompt.map { String($0.prefix(200)) })
            },
            projects: projects.prefix(40).map {
                RouterProject(name: $0.name, path: $0.path, lastCLI: $0.lastUsedCLI)
            },
            mainSessionId: mainSession?.id)
    }

    /// Carries out a validated decision. Only `reply` sends anything right away, as Enter always
    /// did; a new session waits for the confirm card, a clarify for the user's pick.
    private func execute(_ decision: RouterDecision) {
        switch decision.action {
        case .reply(let id, let text):
            if id != mainId { select(id) }
            sendToSession(text)
        case .start(let path, let cli, let prompt):
            guard let project = knownProjects.first(where: { $0.path == path }) else { return }
            proposeLaunch(project, override: cli, prompt: prompt)
        case .open(let id):
            if let s = sessions[id], canViewSession(s) {
                viewSession(s)
                dismiss()
            } else {
                barError = "That session can\u{2019}t be opened in a terminal"
            }
        case .clarify(let question, let choices):
            barError = nil
            barInUse = true
            pendingClarify = PendingClarify(question: question, choices: choices)
            summoned = true
            recompute(sessions: sessions)
            speak(question)
        case .none:
            showBarError(mainSession == nil ? AssistantBarLogic.whichProjectCopy
                                            : "I\u{2019}m not sure what to do with that")
        }
    }

    /// The clarify card's choice `index`.
    func pickClarify(_ index: Int) {
        guard let pending = pendingClarify, pending.choices.indices.contains(index) else { return }
        pendingClarify = nil
        recompute(sessions: sessions)
        execute(RouterDecision(action: pending.choices[index].action, source: "clarify"))
    }

    private func sendToSession(_ text: String) {
        // Cheap checks first; the CLI lookup can spawn `which`, so it runs off the main actor.
        let folder = taskFolder
        let target = barTarget          // decided at Enter, before the panel changes
        let modelId = state.opencodeChatModel
        // A worker Mochi runs already has its model: the bar's OpenCode model is not needed.
        let workerReply = replyTargetIsWorker(target)
        let pre = AssistantBarLogic.check(text: text, folder: folder, model: modelId, cliAvailable: true,
                                          target: target, modelRequired: !workerReply)
        switch pre {
        case .ignore:
            return
        case .error(let message):
            showBarError(message)
            return
        case .launch(let prompt, let cwd):
            barError = nil
            Task { [weak self] in
                let isClaude: Bool = { if case .claudeReply = target { return true } else { return false } }()
                // A worker that is already running needs no CLI lookup.
                let found = workerReply ? true : await Task.detached {
                    isClaude ? ClaudeCodeRun.cliURL() != nil : OpenCodeChat.cliURL() != nil
                }.value
                guard let self else { return }
                let final = AssistantBarLogic.check(text: prompt, folder: folder, model: modelId,
                                                    cliAvailable: found, target: target, modelRequired: !workerReply)
                guard case .launch = final else {
                    if case .error(let message) = final { self.showBarError(message) }
                    return
                }
                self.launchTask(prompt: prompt, model: modelId, cwd: cwd, target: target)
            }
            return
        }
    }

    // MARK: - The bar: voice

    /// Opens the panel on the bar and starts listening. With no folder the words can still name a
    /// project to start a session in.
    func startVoice() {
        guard !VoiceInput.shared.isActive else { return }
        MochiSpeech.shared.stop()   // never listen to Mochi's own voice
        voiceOpenedPanel = !isOpen
        barError = nil
        barInUse = true
        refreshProjects()
        summon()
        VoiceInput.shared.start()
    }

    /// Stops listening. `send`: the transcript goes through `submitTask` (same as Enter);
    /// otherwise it is dropped.
    func finishVoice(send: Bool) {
        let voice = VoiceInput.shared
        guard voice.isActive else { return }
        let closeAfter = voiceOpenedPanel
        guard send else {
            voice.cancel()
            if closeAfter { dismiss() }
            return
        }
        Task { [weak self] in
            let text = await voice.finish()
            guard let self else { return }
            if text.isEmpty {
                if closeAfter { self.dismiss() }
            } else {
                self.submitTask(text, spoken: true)
            }
        }
    }

    /// After "Hey Mochi": the same voice input as ⌥, but nothing is held, so it ends by itself —
    /// it sends once the user pauses, and gives up quietly if nothing is said (`HandsFreeEnd`).
    func startHandsFreeVoice() {
        startVoice()
        handsFreeTask?.cancel()
        handsFreeTask = Task { [weak self] in
            let voice = VoiceInput.shared
            let start = Date()
            var last = voice.transcript, changedAt = start
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard voice.isActive, let self else { return }
                guard voice.isListening else { continue }      // still asking for access / opening
                if voice.transcript != last { last = voice.transcript; changedAt = Date() }
                switch HandsFreeEnd.verdict(transcript: last, sinceStart: Date().timeIntervalSince(start),
                                            sinceChange: Date().timeIntervalSince(changedAt)) {
                case .keepListening: continue
                case .send: self.finishVoice(send: true); return
                case .cancel: self.finishVoice(send: false); return
                }
            }
        }
    }

    /// The mic button: click to start; it sends once the user pauses (like "Hey Mochi"), or
    /// right away on a second click.
    func toggleVoice() {
        if VoiceInput.shared.isActive { finishVoice(send: true) } else { startHandsFreeVoice() }
    }

    /// The bar's reply goes to a worker Mochi runs (any runtime), not to a CLI run of its own.
    private func replyTargetIsWorker(_ target: AssistantBarLogic.Target) -> Bool {
        switch target {
        case .claudeReply(let id), .reply(let id): return WorkerManager.shared.isWorker(id)
        case .newTask: return false
        }
    }

    private func launchTask(prompt: String, model: String, cwd: String,
                            target: AssistantBarLogic.Target) {
        if case .claudeReply(let id) = target {
            launchClaudeReply(prompt: prompt, sessionId: id, cwd: cwd)
            return
        }
        if case .reply(let id) = target, WorkerManager.shared.isWorker(id) {
            sendToWorker(prompt: prompt, sessionId: id, target: target, cwd: cwd)
            return
        }
        let sessionId: String? = { if case .reply(let id) = target { return id } else { return nil } }()
        let aloud = answerAloud
        confirmSent(target: target, cwd: cwd)
        Task { [weak self] in
            do {
                // Real work: allow up to an hour instead of chat's 2 minutes.
                try await OpenCodeChat.run(prompt: prompt, model: model,
                                           cwd: URL(fileURLWithPath: cwd),
                                           timeout: AssistantBarLogic.taskTimeout,
                                           // A reply continues that conversation; both kinds run
                                           // in the user's own OpenCode store so they can be
                                           // continued later and show in their history.
                                           sessionId: sessionId,
                                           userStore: true)
            } catch {
                let message = (error as? OpenCodeChat.ChatError)?.message ?? error.localizedDescription
                appendAppLog("nb.log", "assistant bar: OpenCode task failed: \(message)")
                // The panel may have closed after "sent": reopen it so the failure is not silent.
                guard let self else { return }
                self.reportRunFailure("OpenCode", message, aloud: aloud)
            }
        }
    }

    /// `claude -p --resume`: the run's hooks drive the Mochi (progress, approvals in the notch,
    /// the finished card), so only a failure is handled here.
    private func launchClaudeReply(prompt: String, sessionId: String, cwd: String) {
        let aloud = answerAloud
        confirmSent(target: .claudeReply(sessionId: sessionId), cwd: cwd)
        Task { [weak self] in
            // A worker Mochi runs itself takes the text on its open stream; anything else is
            // resumed the way it always was.
            if await WorkerManager.shared.send(prompt, toSession: sessionId) { return }
            do {
                try await ClaudeCodeRun.resume(sessionId: sessionId, prompt: prompt, cwd: cwd,
                                               timeout: AssistantBarLogic.taskTimeout)
            } catch {
                let message = (error as? ClaudeCodeRun.RunError)?.message ?? error.localizedDescription
                appendAppLog("nb.log", "assistant bar: Claude Code reply failed: \(message)")
                // The panel closed after "sent"; reopen it so the failure is not silent.
                guard let self else { return }
                self.reportRunFailure("Claude Code", message, aloud: aloud)
            }
        }
    }

    /// Text for a worker Mochi runs (OpenCode, or Claude Code through `launchClaudeReply`): it takes the
    /// message on its open session; a failure reopens the panel with the reason.
    private func sendToWorker(prompt: String, sessionId: String, target: AssistantBarLogic.Target, cwd: String) {
        confirmSent(target: target, cwd: cwd)
        Task { _ = await WorkerManager.shared.send(prompt, toSession: sessionId) }
    }

    /// "Sent to Mochi": the words went to the brain; the panel closes and its answer card opens later.
    private func confirmSentToMochi() {
        barStatus = .sent(AssistantBarLogic.mochiSentCopy)
        sentCloseTask?.cancel()
        sentCloseTask = Task { [weak self] in
            try? await Task.sleep(for: AssistantBarLogic.sentHold)
            guard !Task.isCancelled, let self, case .sent = self.barStatus else { return }
            self.dismiss()
        }
    }

    /// Says where the text went, holds the panel open on it for a moment, then closes.
    private func confirmSent(target: AssistantBarLogic.Target, cwd: String) {
        let copy = AssistantBarLogic.sentCopy(target: target, workspace: URL(fileURLWithPath: cwd).lastPathComponent)
        barStatus = .sent(copy)
        speak(copy)
        sentCloseTask?.cancel()
        sentCloseTask = Task { [weak self] in
            try? await Task.sleep(for: AssistantBarLogic.sentHold)
            guard !Task.isCancelled, let self, case .sent = self.barStatus else { return }
            self.dismiss()
        }
    }

    /// The brain failed: reopen the panel with the error and the user's own words back in the bar.
    func reportBrainFailure(_ message: String, restoring text: String) {
        reportRunFailure("Mochi", message, aloud: false)
        restoredBarText = text
    }

    func consumeRestoredBarText() { restoredBarText = nil }

    /// A run that failed after the panel closed: the panel comes back with the reason.
    func reportRunFailure(_ agent: String, _ message: String, aloud: Bool) {
        // A fast failure lands while "sent" is still up: keep the panel open on the error.
        sentCloseTask?.cancel()
        sentCloseTask = nil
        barStatus = nil
        barError = Self.oneLine(message)
        barInUse = true
        summon()
        if aloud { MochiSpeech.shared.say("\(agent) couldn\u{2019}t finish that. The reason is in the notch.") }
    }

    /// An error in the bar; said out loud too when the request was spoken.
    private func showBarError(_ message: String) {
        barError = message
        speak(message)
    }

    private func speak(_ line: String) {
        if answerAloud { MochiSpeech.shared.say(line) }
    }

    /// "View session" / "Open session": a Claude Code session in Terminal (`claude --resume`).
    func canViewSession(_ session: AgentSession) -> Bool {
        if session.kind == .openCode {
            // Only a worker Mochi runs: its hand-off knows how to stop it and open `opencode --session`.
            return WorkerManager.shared.isWorker(session.id) && MochiTools.isOpenCodeSessionId(session.id)
        }
        return session.kind == .claudeCode && !session.cwd.isEmpty && ClaudeCodeRun.isValidSessionId(session.id)
    }

    func viewSession(_ session: AgentSession) {
        guard canViewSession(session) else { return }
        // A worker Mochi runs is stopped first, so the terminal never shares a conversation with it.
        if WorkerManager.shared.isWorker(session.id) {
            Task { await WorkerManager.shared.handOffToTerminal(sessionId: session.id) }
            return
        }
        ClaudeCodeRun.openInTerminal(sessionId: session.id, cwd: session.cwd)
    }

    var canViewMainSession: Bool { mainSession.map(canViewSession) ?? false }

    // MARK: - Mochi's suggested next steps

    /// The suggestions the finished card shows: a `reply` step needs a Claude Code session that
    /// can be resumed from here. The panel height uses the same list.
    func mochiActions(for session: AgentSession) -> [MochiAction] {
        (session.mochi?.actions ?? []).filter { action in
            if case .reply = action.kind { return canViewSession(session) }
            return true
        }
    }

    /// One click on a suggestion from a Mochi-started session. Links must be plain web links,
    /// paths must exist, and anything that could launch code is shown in Finder, never opened.
    func perform(_ action: MochiAction, in session: AgentSession) {
        switch action.kind {
        case .openURL(let s):
            guard let url = safeWebURL(s) else { return showBarError("That link can\u{2019}t be opened from here") }
            NSWorkspace.shared.open(url)
        case .openFile(let p):
            let path = MochiAware.resolvePath(p, cwd: session.cwd)
            guard FileManager.default.fileExists(atPath: path) else { return showBarError("File not found: \(p)") }
            if MochiActionSafety.launchesCode(path) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            } else {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            }
        case .reveal(let p):
            let path = MochiAware.resolvePath(p, cwd: session.cwd)
            guard FileManager.default.fileExists(atPath: path) else { return showBarError("File not found: \(p)") }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        case .reply(let text):
            guard canViewSession(session) else { return }
            markSeen(session.id)
            if session.kind == .openCode {
                sendToWorker(prompt: text, sessionId: session.id, target: .reply(sessionId: session.id), cwd: session.cwd)
            } else {
                launchClaudeReply(prompt: text, sessionId: session.id, cwd: session.cwd)
            }
        case .copy(let text):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        case .focus(let id):
            // A session that is gone, or no longer needs the user, is a harmless no-op.
            guard let target = sessions[id], MochiDigest.needsYou(target) else { return }
            markSeen(session.id)    // the digest did its job
            select(id)              // same path as clicking that session's small Mochi
        }
    }

    func viewMainSession() {
        if let main = mainSession { viewSession(main) }
    }

    // MARK: - Project launch

    /// Re-reads the project list in the background (voice start, Settings).
    func refreshProjects() {
        Task { [weak self] in
            let projects = await Task.detached { ProjectScanner.scan() }.value
            self?.knownProjects = projects
        }
    }

    /// The project list for the brain's tools: the cached scan, read again when empty.
    func projectsForBrain() async -> [KnownProject] { await loadProjects() }

    private func loadProjects() async -> [KnownProject] {
        knownProjects.isEmpty ? await rescanProjects() : knownProjects
    }

    private func rescanProjects() async -> [KnownProject] {
        let projects = await Task.detached { ProjectScanner.scan() }.value
        knownProjects = projects
        return projects
    }

    /// The CLI a project is set to in Settings; nil = automatic (last used, then the default).
    func cliSetting(for path: String) -> ProjectCLI? {
        state.projectCLIs[path].flatMap(ProjectCLI.init(rawValue:))
    }

    func setCLISetting(_ cli: ProjectCLI?, for path: String) {
        var map = state.projectCLIs
        map[path] = cli?.rawValue
        state.projectCLIs = map
    }

    private func proposeLaunch(_ project: KnownProject, override: ProjectCLI?, prompt: String? = nil) {
        let fallback = ProjectCLI(rawValue: state.defaultCLI) ?? .claudeCode
        let cli = ProjectLaunchLogic.cli(override: override, setting: cliSetting(for: project.path),
                                         project: project, fallback: fallback)
        barError = nil
        barInUse = true
        pendingClarify = nil
        pendingLaunch = PendingLaunch(project: project, cli: cli, prompt: prompt)
        summoned = true
        recompute(sessions: sessions)
        speak("Start \(cli.displayName) in \(project.name)? Click to confirm.")
    }

    /// The confirm card's main button. With the assistant on (GitHub build), Mochi starts a worker on the
    /// chosen runtime: no terminal opens. Otherwise it opens the terminal in the project, as before.
    func confirmLaunch() {
        guard let launch = pendingLaunch else { return }
        // Mochi runs the agent itself only while the assistant is on; otherwise the terminal opens as it always did.
        if WorkerManager.isAvailable, MochiBrain.shared.isAvailable {
            let aloud = answerAloud
            Task { [weak self] in
                do {
                    _ = try await WorkerManager.shared.start(projectPath: launch.project.path, runtime: launch.cli,
                                                             model: nil, prompt: launch.prompt)
                } catch {
                    let message = WorkerManager.message(for: error)
                    appendAppLog("nb.log", "assistant: \(launch.cli.displayName) worker failed to start: \(message)")
                    self?.reportRunFailure(launch.cli.displayName, message, aloud: aloud)
                }
            }
            dismiss()
            return
        }
        TerminalLauncher.run(ProjectLaunchLogic.command(launch.cli, prompt: launch.prompt), in: launch.project.path)
        dismiss()
    }

    /// The confirm card's other button: the other CLI, this time only.
    func switchLaunchCLI() {
        guard var launch = pendingLaunch else { return }
        launch.cli = launch.cli == .claudeCode ? .openCode : .claudeCode
        pendingLaunch = launch
        recompute(sessions: sessions)
    }

    // MARK: - Session titles

    func title(for session: AgentSession) -> String? { titles[session.id] }

    /// Re-reads a title once per new event of that session (titles appear after the first turn
    /// and can be renamed). The read runs off the main actor; files are only read, never written.
    private func refreshTitle(for session: AgentSession) {
        guard session.kind == .claudeCode || session.kind == .openCode,
              titleReadFor[session.id] != session.lastEventAt else { return }
        titleReadFor[session.id] = session.lastEventAt
        let id = session.id, kind = session.kind, cwd = session.cwd
        Task { [weak self] in
            let title = await Task.detached(priority: .utility) {
                SessionTitleReader.title(kind: kind, sessionId: id, cwd: cwd)
            }.value
            guard let self, let title, self.titles[id] != title else { return }
            self.titles[id] = title
        }
    }

    // MARK: - Mochi's voice

    /// Mochi's one-line take on a finished session's reply, once the on-device model has written
    /// it. nil until then (and when the model is unavailable): the card shows the first sentence.
    /// The finished card's headline: Mochi's line, else the reply's first sentence.
    func headline(for session: AgentSession) -> String {
        let base = session.mochi?.line ?? mochiLine(for: session) ?? AssistantReply.firstSentence(session.reply) ?? "Done."
        return AssistantReply.headline(base, missedApprovals: session.missedApprovals)
    }

    func mochiLine(for session: AgentSession) -> String? {
        guard let reply = session.reply, mochiLineSource[session.id] == reply else { return nil }
        return mochiLines[session.id]
    }

    /// Asks for a line once per reply. Runs off the main path; a newer reply wins.
    private func requestMochiLine(for session: AgentSession) {
        // A Mochi worker already reported its own line.
        guard session.phase == .finished, session.mochi?.line == nil, let reply = session.reply,
              !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              mochiLineSource[session.id] != reply else { return }
        mochiLineSource[session.id] = reply
        mochiLines[session.id] = nil
        let id = session.id, agent = session.kind.displayName
        Task { [weak self] in
            guard let line = await MochiVoice.line(for: reply, agent: agent) else { return }
            guard let self, self.mochiLineSource[id] == reply else { return }
            self.mochiLines[id] = line
            self.recompute(sessions: self.sessions)   // the headline's height may change
        }
    }

    private static func oneLine(_ s: String) -> String {
        s.split(whereSeparator: \.isNewline).first.map(String.init) ?? s
    }

    // MARK: - Private

    /// Plays (or skips) the hand-off for a change of main agent. Called before `mainId` / `subOrder`
    /// change, in the same synchronous pass.
    private func beginHandoff(oldMain: String?, newMain: String?, newOrder: [String],
                              recolourIndex: Int?, colorHex: String?) {
        guard newMain != oldMain else { return }
        // A hand-off in the air is cancelled: its remaining travel and burst never play, and its
        // slot recolour applies now (the new holds below replace the old ones).
        handoffTask?.cancel()
        handoffTask = nil
        guard let plan = HandoffPlanner.plan(
            oldMain: oldMain, newMain: newMain, newOrder: newOrder, recolourIndex: recolourIndex,
            visible: state.mode != .hidden,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) else {
            slotHolds = [:]
            flight = nil
            return
        }
        colorBlendRate = plan.blendRate
        slotHolds = plan.holds
        guard let slot = plan.fromSlot, let colorHex else {
            flight = nil
            if plan.hops { hopToken += 1 }
            return
        }
        flightCounter += 1
        let token = flightCounter
        flight = AssistantFlight(token: token, fromSlot: slot, hex: colorHex,
                                 start: Date().timeIntervalSinceReferenceDate)
        handoffTask = Task { @MainActor [weak self] in
            // Landing: the main Mochi hops and the slot takes the previous main.
            try? await Task.sleep(for: .seconds(HandoffTimeline.landingDelay))
            guard !Task.isCancelled, let self else { return }
            self.hopToken += 1
            self.slotHolds = [:]
            // The burst plays out, then the overlay is unmounted.
            try? await Task.sleep(for: .seconds(HandoffTimeline.burstDuration + 0.05))
            guard !Task.isCancelled else { return }
            if self.flight?.token == token { self.flight = nil }
        }
    }

    private func modeChanged(_ mode: IslandMode) {
        let expanded = mode == .expanded
        defer { wasExpanded = expanded }
        // Folding the island while the panel is open is a dismissal: it must not pop back open for
        // the same needs, and the selection / summon last only while the panel is open.
        if wasExpanded && !expanded && (isOpen || summoned || selectedId != nil) { dismiss() }
    }

    private func recompute(sessions new: [String: AgentSession]) {
        sessions = new
        if let selectedId, new[selectedId] == nil { self.selectedId = nil }
        evaluateDigest(new)

        let list = new.values.sorted { $0.id < $1.id }
        let newMain = MainAgentPicker.pick(sessions: list, selectedId: selectedId,
                                           contextWorkspace: contextWorkspace, previousMainId: mainId)
        let update = SubSlotOrder.update(order: subOrder, alive: list.map(\.id),
                                         oldMain: mainId, newMain: newMain)
        beginHandoff(oldMain: mainId, newMain: newMain, newOrder: update.order,
                     recolourIndex: update.recolourIndex, colorHex: newMain.flatMap { new[$0]?.colorHex })
        if newMain != mainId { mainId = newMain }
        if update.order != subOrder { subOrder = update.order }
        recolourIndex = update.recolourIndex

        queue = AttentionQueue.order(list)
        if queue.isEmpty { dismissedSignature = nil }
        let main = newMain.flatMap { new[$0] }
        mochiLineSource = mochiLineSource.filter { new[$0.key] != nil }
        mochiLines = mochiLines.filter { new[$0.key] != nil }
        titles = titles.filter { new[$0.key] != nil }
        titleReadFor = titleReadFor.filter { new[$0.key] != nil }
        if let main { refreshTitle(for: main) }
        if let main { requestMochiLine(for: main) }
        // The finished card no longer lists changed files or opens diffs, so it reserves no rows for them.
        let finishedFiles = 0
        if showsDiff { showsDiff = false }
        let open = AssistantOpenRules.isOpen(summoned: summoned, selectedId: selectedId, queue: queue,
                                             dismissedSignature: dismissedSignature)
        if open != isOpen { isOpen = open }
        let question = main.flatMap { questions[$0.id] }
        let content = AssistantPanelContent.resolve(
            main: main,
            hasApproval: main.map { approvals[$0.id] != nil } ?? false,
            questionRows: question.map { q in
                // A question or description that wraps (about 90 characters per line at the panel's width)
                // needs more than the row: take the full island height and let the list scroll.
                let wraps = q.question.questions.contains { $0.question.count > 90 || $0.options.contains { $0.description.count > 90 } }
                if wraps { return 99 }
                return (q.question.questions.map(\.options.count).max() ?? 0) + 1   // + the "Other..." row
            },
            finishedFiles: finishedFiles, showsDiff: showsDiff, launchPrompt: pendingLaunch.map { $0.prompt != nil },
            clarifyChoices: pendingClarify?.choices.count,
            headlineLines: main.map { AssistantReply.headlineLines(headline(for: $0)) } ?? 2,
            hasActions: main.map { !mochiActions(for: $0).isEmpty } ?? false)
        if content != panelContent { panelContent = content }
    }
}

/// One row of the finished card: a file the session changed, with its added/removed line counts.
struct AssistantChangedFile: Identifiable, Equatable {
    let path: String
    let name: String
    let added: Int
    let removed: Int
    /// The last diff recorded for this path (what "Open diff" shows).
    let diff: FileDiff
    var id: String { path }

    static func group(_ diffs: [FileDiff]) -> [AssistantChangedFile] {
        var order: [String] = []
        var byPath: [String: AssistantChangedFile] = [:]
        for d in diffs {
            if let existing = byPath[d.path] {
                byPath[d.path] = AssistantChangedFile(path: d.path, name: d.name,
                                                      added: existing.added + d.added,
                                                      removed: existing.removed + d.removed, diff: d)
            } else {
                order.append(d.path)
                byPath[d.path] = AssistantChangedFile(path: d.path, name: d.name, added: d.added,
                                                      removed: d.removed, diff: d)
            }
        }
        return order.compactMap { byPath[$0] }
    }
}

/// The clarify card's content: the router's question and its 2–4 concrete choices.
struct PendingClarify: Equatable, Sendable {
    let question: String
    let choices: [RouterChoice]
}
