import Combine
import Foundation
import SwiftUI

/// Presentation state for the voice harness.
///
/// It owns the harness's *own* presentation — which workspace has the floor, what the
/// composer says, the current suggestion, whether the done summary is showing, and the
/// roster order. It deliberately does NOT own agent state: every roster row is
/// projected from the live `AppState.tasks` / `HookServer` records, every thread row
/// comes from `ThreadStore`, and every run goes through `OpenCodeChat`. Nothing here
/// is persisted.
///
/// The harness is the island's home surface. It must tolerate being rendered while
/// inactive (every `IslandView` body is built once and kept alive), so every accessor
/// is nil-safe and every collection may be empty.
@MainActor
final class VoiceHarnessModel: ObservableObject {

    /// The one harness model. `overview` and `approval` both render `HarnessVoiceView`, and
    /// `IslandRootView` keeps one body per case alive at once, so two view instances exist.
    /// They must present ONE surface: a per-instance model would lose the composer text the
    /// moment a permission swapped the island to `approval`, then lose the answering
    /// summary on the way back. Presentation state therefore lives here, shared, exactly as
    /// the agents' state lives in `AppState.shared`.
    static let shared = VoiceHarnessModel()

    // MARK: - Types

    /// The synthetic orchestrator. It is not a pill: it owns no folder and no pill id
    /// contract value, it just represents "the harness itself" in the roster.
    static let mainId = "main"
    static let mainName = "Main"
    static let mainColor = "#3B9EFF"

    /// One roster row: a workspace the user can talk to, plus the live facts shown
    /// beside it. `task` is the live `AgentTask` record for that pill (nil when the
    /// pill has no session yet), so the pill can render its own Mochi unchanged.
    struct Workspace: Identifiable, Equatable {
        let id: String
        let name: String
        let color: String
        let folder: String?
        let isMain: Bool
        let task: AgentTask?

        var state: BotState { task?.state ?? .idle }
        var steps: [String] { task?.steps ?? [] }
        var stepIndex: Int { task?.stepIndex ?? 0 }
        var stepCount: Int { task?.steps.count ?? 0 }
        var isWorking: Bool { state == .working || state == .thinking || state == .searching }

        /// The line under the workspace name — its current step, or what it is.
        var tool: String? {
            let steps = task?.steps ?? []
            guard !steps.isEmpty else { return nil }
            let index = min(max(0, task?.stepIndex ?? 0), steps.count - 1)
            let line = steps[index].trimmingCharacters(in: .whitespacesAndNewlines)
            return line.isEmpty ? nil : line
        }

        var ref: WorkspaceRef {
            WorkspaceRef(id: id, name: name, color: color, folder: folder, isMain: isMain)
        }
    }

    // MARK: - Identity

    private let appState = AppState.shared
    private let threads = ThreadStore.shared
    private var cancellables = Set<AnyCancellable>()

    private init() {
        // The model does not republish agent state, it *projects* it. Every computed accessor
        // (`mochiState`, `tickerLines`, `approval`, `meterText`) reads `AppState` live at
        // body-evaluation time, but SwiftUI only re-evaluates a body when one of the objects
        // it observes publishes — so the model has to forward `AppState`'s changes. This is
        // the standard nested-ObservableObject bridge.
        //
        // `refresh()` is deliberately NOT called from this sink: `objectWillChange` fires
        // *before* the mutation, so it would rebuild the roster from stale data. The view
        // calls `refresh()` from `.onChange(of: appState.tasks)`, which fires after.
        appState.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        refresh()
    }

    // MARK: - Roster

    /// Every workspace, in `PillCatalog` order, with Main lurking at the end.
    /// Rebuilt from the live task list; the harness never invents a workspace.
    @Published private(set) var workspaces: [Workspace] = []

    /// Which workspace has the floor.
    @Published private(set) var focusedId: String = VoiceHarnessModel.mainId

    /// The last real workspace, so Main can send you back to it.
    private var lastWorkspaceId: String?

    // MARK: - Composer

    @Published var composerText: String = ""
    @Published private(set) var isListening = false

    // MARK: - Run

    @Published private(set) var isRunning = false
    @Published private(set) var isStopping = false
    @Published private(set) var lastSummary: String?
    @Published private(set) var showsSummary = false
    @Published private(set) var notice: String?
    @Published private(set) var lastError: String?

    private var currentRunId: UUID?
    private var runningWorkspaceId: String?

    // MARK: - Meter

    @Published private(set) var costUsd: Double?
    @Published private(set) var inputTokens: Int?
    @Published private(set) var outputTokens: Int?

    // MARK: - Chrome

    @Published private(set) var isThreadPopupOpen = false
    /// Bumped on every focus change so the view can run the swap animation.
    @Published private(set) var swapToken = 0
    /// Bumped on every hop so the big Mochi can squash-stretch.
    @Published private(set) var hopToken = 0

    // MARK: - Derived

    var focused: Workspace? {
        workspaces.first { $0.id == focusedId }
    }

    /// The workspace that will receive the next utterance: Main routes to the last
    /// workspace you were on.
    var target: Workspace? {
        if focusedId == Self.mainId { return lastWorkspaceId.flatMap { id in workspaces.first { $0.id == id } } ?? firstRealWorkspace }
        return focused
    }

    var firstRealWorkspace: Workspace? {
        workspaces.first { !$0.isMain }
    }

    var isMainFocused: Bool { focusedId == Self.mainId }

    /// Real workspaces only (no Main) — what the right card's pills show.
    var realWorkspaces: [Workspace] {
        workspaces.filter { !$0.isMain }
    }

    var mainChip: Workspace? {
        workspaces.first { $0.isMain }
    }

    /// The caption beside the mic: `agent · voice`. Hidden while a riser is up or
    /// while the composer is expanded, exactly as the prototype pins it.
    var caption: String {
        let name = focused?.name ?? Self.mainName
        return "\(name) · \(isListening ? "listening" : "voice")"
    }

    /// The model the run will use. NOT `activeChatModel`: the half there belongs to the chat
    /// *provider* the user picked (Anthropic ⇒ `claude-sonnet-4-6`), and the harness always runs
    /// the OpenCode CLI, which needs an OpenCode `provider/model` id. `OpenCodeChat.chat` reads
    /// the same `opencodeChatModel` for the same reason (`OpenCodeChat.swift:579`).
    var contextModel: String { appState.opencodeChatModel }

    var hasApproval: Bool { appState.pendingApproval != nil }
    var hasQuestion: Bool { appState.pendingQuestion != nil }
    var hasRiser: Bool { hasApproval || hasQuestion }

    /// The payload the riser strip renders. `AppState` exposes the oldest pending approval and
    /// the oldest pending question; the same `ApprovalView`/`QuestionView` model properties drive
    /// the shipping views, so the strip can never disagree with them.
    var approval: ApprovalInfo? { appState.pendingApproval }
    var question: AskQuestion? { appState.pendingQuestion }

    /// Send an approval decision through the ONE existing path.
    /// `sessionId` is the session of the approval the strip displayed when the button was drawn.
    func resolveApproval(_ decision: String, sessionId: String) {
        HookServer.shared.sendApprovalDecision(decision, sessionId: sessionId)
        approvalDidResolve()
    }

    /// Send question answers through the ONE existing path
    /// (`AskQuestion.buildAnswers` → `HookServer.sendQuestionAnswers`).
    func resolveQuestion(_ selections: [[String]]) {
        // Question and session id come from the same snapshot, so the answers reach the session they were built for.
        guard let pending = appState.oldestPendingQuestion else { return }
        let answers = AskQuestion.buildAnswers(questions: pending.question.questions, selections: selections)
        HookServer.shared.sendQuestionAnswers(answers, sessionId: pending.sessionId)
        approvalDidResolve()
    }

    /// The big Mochi's state, in the prototype's precedence order.
    var mochiState: HarnessMochiState {
        if hasApproval { return .approval }
        if hasQuestion { return .question }
        if isListening { return .listening }
        if isRunning { return .working }
        if lastError != nil { return .error }
        if showsSummary { return .finished }
        if realWorkspaces.isEmpty { return .sleeping }
        return .idle
    }

    /// The focused workspace's trail, condensed for the ticker: previous step, then
    /// the current one last so it sits at the bottom of the slot.
    var tickerLines: [String] {
        guard let workspace = focused ?? target else { return [] }
        let steps = workspace.steps
        guard !steps.isEmpty else { return [] }
        let index = min(max(0, workspace.stepIndex), steps.count - 1)
        let previous = index > 0 ? steps[index - 1] : steps[0]
        return [previous, steps[index]]
    }

    /// The greyed placeholder that teaches the composer. Shown only while the composer
    /// is empty, so any typing replaces it — exactly the prototype's `.has-suggest`.
    var suggestion: String? {
        guard composerText.isEmpty, !isRunning else { return nil }
        guard let workspace = focused ?? target else { return nil }
        if workspace.isMain { return "Ask anything — I'll route it to the right project." }
        if let tool = workspace.tool { return "Ask about: \(tool)" }
        if workspace.stepCount == 0 { return "Ask \(workspace.name) to do something…" }
        return "What next in \(workspace.name)?"
    }

    /// "N agents running · tap a Mochi to make it the main".
    var rosterFooter: String {
        let running = realWorkspaces.filter(\.isWorking).count
        if running == 0 {
            return realWorkspaces.isEmpty
                ? "no agents yet · start one to route to it"
                : "all agents idle · tap a Mochi to make it the main"
        }
        return "\(running) agent\(running == 1 ? "" : "s") running · tap a Mochi to make it the main"
    }

    /// A run needs a real workspace and a free slot.
    var canStartNewSession: Bool {
        !realWorkspaces.isEmpty && !isRunning && !hasRiser
    }

    var currentThreadTitle: String? {
        guard let workspace = focused ?? target else { return nil }
        return threads.activeThread(for: workspace.id)?.title
    }

    // MARK: - Roster sync

    /// Rebuilds the roster from the live records. Called on every change to
    /// `AppState.tasks`; never invents or reorders anything the app doesn't have.
    func refresh() {
        var rebuilt: [Workspace] = []
        for pill in PillCatalog.all {
            guard let task = appState.tasks.first(where: { $0.id == pill.id }) else { continue }
            let name = task.sessionCwd.map { ($0 as NSString).lastPathComponent } ?? pill.name
            rebuilt.append(Workspace(id: pill.id,
                                     name: name,
                                     color: task.color,
                                     folder: task.sessionCwd,
                                     isMain: false,
                                     task: task))
        }
        // A workspace can be live without a catalogue row (an external agent pill).
        for task in appState.tasks where !rebuilt.contains(where: { $0.id == task.id }) {
            let name = task.sessionCwd.map { ($0 as NSString).lastPathComponent } ?? task.name
            rebuilt.append(Workspace(id: task.id,
                                     name: name,
                                     color: task.color,
                                     folder: task.sessionCwd,
                                     isMain: false,
                                     task: task))
        }
        rebuilt.append(Workspace(id: Self.mainId,
                                 name: Self.mainName,
                                 color: Self.mainColor,
                                 folder: nil,
                                 isMain: true,
                                 task: nil))
        workspaces = rebuilt

        if focusedId != Self.mainId,
           !rebuilt.contains(where: { $0.id == focusedId && !$0.isMain }) {
            focusedId = lastWorkspaceId.flatMap { id in
                rebuilt.contains(where: { $0.id == id && !$0.isMain }) ? id : nil
            } ?? rebuilt.first(where: { !$0.isMain })?.id ?? Self.mainId
        }
        if !rebuilt.contains(where: { $0.id == focusedId }) {
            focusedId = Self.mainId
        }
        if let last = lastWorkspaceId, !rebuilt.contains(where: { $0.id == last && !$0.isMain }) {
            lastWorkspaceId = rebuilt.first(where: { !$0.isMain })?.id
        }
        // Deliberately NOT creating a thread here. `refresh()` runs from `.onAppear` and from
        // every `state.tasks` change, so ensuring a thread while rendering fabricates a "new
        // session" merely by tapping between pills, eats the 20-thread cap, and makes the
        // popup's empty state unreachable. Threads are created where a session actually starts
        // (`submit`, `startNewSession`).
    }

    // MARK: - Focus

    /// Gives the floor to a workspace. `hop` is the prototype's focus-change motion:
    /// the Mochi squashes, the ring spins, then the agent swaps.
    func focus(_ id: String, hop: Bool = true) {
        guard id != focusedId else { return }
        guard workspaces.contains(where: { $0.id == id }) else { return }
        if id != Self.mainId { lastWorkspaceId = id }
        showsSummary = false
        notice = nil
        lastError = nil
        // The thread popup belongs to the workspace it was opened on.
        isThreadPopupOpen = false
        withAnimation(HarnessMotion.agentSwap) { focusedId = id }
        // Mirror into `AppState`, which stays the app's own focus: the ship bot's colour, the
        // badge clearing, the GitHub poller and the shipping keyboard routes (⌘←/⌘→, ⌘1–9,
        // `cyclePill`) all read `state.focusId`. Without this the two could name different
        // workspaces. `setFocus` ignores an id that is not a task, so focusing Main is a no-op.
        appState.setFocus(id)
        swapToken += 1
        if hop { hopToken += 1 }
    }

    /// The Main-lurk chip: back to the last workspace you were on.
    func returnFromMain() {
        if let last = lastWorkspaceId, workspaces.contains(where: { $0.id == last && !$0.isMain }) {
            focus(last)
        } else if let first = firstRealWorkspace {
            focus(first.id)
        } else {
            notice = "Nothing to route to yet — start an agent first."
        }
    }

    // MARK: - Composer

    func acceptSuggestion() {
        guard let suggestion, composerText.isEmpty else { return }
        composerText = suggestion
        notice = nil
    }

    /// Push-to-talk. There is no speech-to-text yet, so this toggles the listening
    /// presentation ONLY and hands the user back the text path. It never invents a
    /// transcript.
    ///
    /// TODO(STT): feed a real recogniser here and assign `composerText`.
    func toggleListening() {
        isListening.toggle()
        if isListening {
            showsSummary = false
            notice = "Listening… type or dictate, then Enter." // TODO(STT)
        } else {
            notice = "Heard ✓" // TODO(STT)
        }
    }

    func clearComposer() {
        composerText = ""
    }

    // MARK: - Sessions

    /// The `+` control. Guarded: only ever on a real workspace.
    func startNewSession() {
        guard !isMainFocused else {
            notice = "Pick a workspace first — tap a small Mochi."
            return
        }
        guard let workspace = focused, !workspace.isMain else {
            notice = "Pick a workspace first — tap a small Mochi."
            return
        }
        guard canStartNewSession else {
            notice = isRunning ? "A run is already going in \(workspace.name)." : "Finish the pending request first."
            return
        }
        threads.start(workspaceId: workspace.id, title: "new session")
        composerText = ""
        showsSummary = false
        lastError = nil
        notice = "New session in \(workspace.name)."
        hopToken += 1
    }

    /// The clock control. On Main there is nothing to rewind.
    func toggleThreads() {
        isThreadPopupOpen.toggle()
    }

    func closeThreads() {
        isThreadPopupOpen = false
    }

    /// Rewind restores a thread snapshot — the row you picked in the history popup, or the
    /// workspace's most recent one. Deep checkpoint/restore is deliberately out of scope.
    func rewind(_ thread: HarnessThread? = nil) {
        guard let workspace = focused ?? target, !workspace.isMain else {
            notice = "Main routes to a workspace — tap a small Mochi first."
            return
        }
        guard let restored = threads.rewind(workspaceId: workspace.id, threadId: thread?.id) else {
            notice = "Nothing to rewind in \(workspace.name) yet."
            return
        }
        showsSummary = restored.summary != nil
        lastSummary = restored.summary
        lastError = nil
        // Put the snapshot's trail back on the task, so "rewind" actually rewinds: without
        // this the captured steps would be write-only and the trail would not move.
        if let idx = appState.tasks.firstIndex(where: { $0.id == workspace.id }) {
            appState.tasks[idx].steps = restored.steps
            appState.tasks[idx].stepIndex = restored.stepIndex
            appState.tasks[idx].finalLine = nil
        }
        notice = "Rewound to “\(restored.title)”."
        isThreadPopupOpen = false
        hopToken += 1
    }

    func threadRows() -> [HarnessThread] {
        guard let workspace = focused ?? target else { return [] }
        return threads.threads(for: workspace.id)
    }

    /// Sends a question back to its shipped card.
    ///
    /// The inline strip is one line tall: three option chips, no free-text field. A question
    /// that needs more than that — a fourth option, or an "Other…" — cannot be answered there,
    /// and a blocked agent must never be unanswerable, so the overflow hands the question to
    /// `QuestionView`, which has the room. `IslandTypes.isHarnessSurface` says the same thing
    /// from the other side: `question` keeps its own card.
    func showFullQuestion() {
        guard appState.pendingQuestion != nil else { return }
        notice = nil
        appState.view = .question
    }

    // MARK: - Running

    /// Sends the composer's text. Routing picks the workspace; an unconfident route
    /// asks instead of guessing.
    func submit() async {
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard !isRunning else {
            notice = "Still running — press stop first."
            return
        }

        let router = KeywordRouter()
        let candidates = realWorkspaces.map(\.ref)
        guard !candidates.isEmpty else {
            notice = "No workspace to route to yet — start an agent first."
            return
        }

        let result = router.route(text, candidates: candidates)
        let workspace: Workspace
        if candidates.count == 1, let only = realWorkspaces.first {
            // One workspace is never ambiguous.
            workspace = only
        } else if result.isConfident, let match = realWorkspaces.first(where: { $0.id == result.workspaceId }) {
            workspace = match
        } else {
            notice = "Which workspace? Name one — or tap its Mochi."
            return
        }

        if workspace.id != focusedId { focus(workspace.id) }

        let runId = UUID()
        currentRunId = runId
        runningWorkspaceId = workspace.id
        isRunning = true
        isStopping = false
        showsSummary = false
        lastSummary = nil
        lastError = nil
        notice = nil
        costUsd = nil
        inputTokens = nil
        outputTokens = nil
        composerText = ""
        isListening = false

        threads.setBusy(true, workspaceId: workspace.id)
        if threads.activeThread(for: workspace.id) == nil {
            threads.start(workspaceId: workspace.id, title: firstLine(of: text))
        } else if threads.activeThread(for: workspace.id)?.title == "new session" {
            threads.setTitle(firstLine(of: text), workspaceId: workspace.id)
        }

        let cwd = workspace.folder.map { URL(fileURLWithPath: $0) }
        do {
            let outcome = try await OpenCodeChat.run(prompt: text,
                                                    model: appState.opencodeChatModel,
                                                    cwd: cwd,
                                                    runId: runId)
            finish(workspaceId: workspace.id,
                   summary: summarise(outcome.text),
                   cost: outcome.costUsd,
                   input: outcome.inputTokens,
                   output: outcome.outputTokens)
        } catch let error as OpenCodeChat.ChatError {
            switch error {
            case .cancelled:
                let kept = keptSteps(for: workspace.id)
                finish(workspaceId: workspace.id,
                       summary: "Stopped · kept \(kept)/\(workspace.stepCount) steps",
                       cost: nil, input: nil, output: nil)
            case .timedOut:
                fail(workspace.id, message: "Timed out after 120 s.")
            case .cliNotFound:
                fail(workspace.id, message: "OpenCode CLI not found.")
            case .workingDirectoryUnavailable(let path):
                fail(workspace.id, message: "That folder is gone: \(path)")
            case .failed(let message):
                fail(workspace.id, message: message.isEmpty ? "The run failed." : message)
            }
        } catch {
            fail(workspace.id, message: error.localizedDescription)
        }
    }

    /// The stop control. SIGTERMs the running child; a no-op when nothing runs.
    func stop() {
        guard isRunning, let runId = currentRunId else {
            notice = "Nothing is running."
            return
        }
        isStopping = true
        if OpenCodeRunRegistry.shared.stop(runId) { return }
        // The registry is `@MainActor` and `OpenCodeChat.run` registers the freshly spawned
        // child on a MainActor hop, so a Stop pressed in the same tick as the send finds no
        // entry and would claim the run had already finished — while it is in fact running on.
        // Re-check once before believing that.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: VoiceHarnessModel.stopRegisterRetryDelay)
            guard isRunning, currentRunId == runId else { return }
            if !OpenCodeRunRegistry.shared.stop(runId) {
                isStopping = false
                notice = "That run already finished."
            }
        }
    }

    /// How long to wait for the child's registration hop before concluding the run is over.
    private static let stopRegisterRetryDelay: UInt64 = 150_000_000

    private func finish(workspaceId: String, summary: String, cost: Double?, input: Int?, output: Int?) {
        isRunning = false
        isStopping = false
        currentRunId = nil
        runningWorkspaceId = nil
        lastSummary = summary
        showsSummary = true
        lastError = nil
        costUsd = cost
        inputTokens = input
        outputTokens = output
        threads.setBusy(false, workspaceId: workspaceId)
        threads.finish(workspaceId: workspaceId, summary: summary)
        if let task = appState.tasks.first(where: { $0.id == workspaceId }) {
            threads.captureSnapshot(workspaceId: workspaceId,
                                    steps: task.steps,
                                    stepIndex: task.stepIndex)
        }
        hopToken += 1
    }

    private func fail(_ workspaceId: String, message: String) {
        isRunning = false
        isStopping = false
        currentRunId = nil
        runningWorkspaceId = nil
        showsSummary = false
        lastSummary = nil
        lastError = message
        notice = message
        threads.setBusy(false, workspaceId: workspaceId)
        threads.finish(workspaceId: workspaceId, summary: nil)
    }

    // MARK: - Helpers

    /// How many of the focused task's steps survive a stop. Coucou's trail is capped
    /// at 20 entries and only ever grows, so "kept" is the index of the current step.
    private func keptSteps(for workspaceId: String) -> Int {
        guard let task = appState.tasks.first(where: { $0.id == workspaceId }) else { return 0 }
        return min(task.steps.count, max(0, task.stepIndex + 1))
    }

    private func firstLine(of text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((trimmed.isEmpty ? "new session" : trimmed).prefix(60))
    }

    /// The done summary's one-liner: the agent's last non-empty line, bounded.
    private func summarise(_ text: String) -> String {
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let last = lines.last else { return "Done." }
        return String(last.prefix(220))
    }

    /// Called when the approval strip resolves, so the summary/notice clear.
    func approvalDidResolve() {
        notice = nil
        showsSummary = false
    }

    /// A short, human line for the meter: `$0.0042 · 12.4k in / 3.1k out`.
    var meterText: String {
        var parts: [String] = []
        if let costUsd { parts.append(String(format: "$%.4f", costUsd)) }
        if let inputTokens { parts.append("\(Self.tokens(inputTokens)) in") }
        if let outputTokens { parts.append("\(Self.tokens(outputTokens)) out") }
        if parts.isEmpty { return isRunning ? "measuring…" : "—" }
        return parts.joined(separator: " · ")
    }

    static func tokens(_ value: Int) -> String {
        if value >= 1000 { return String(format: "%.1fk", Double(value) / 1000) }
        return "\(value)"
    }
}
