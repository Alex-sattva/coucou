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
    @Published private(set) var dismissedSignature: String?
    @Published private(set) var isOpen = false
    /// The card the panel shows for the main session. Decides the panel height.
    @Published private(set) var panelContent: AssistantPanelContent = .bar
    /// Sessions that need the user (approval / question / blocked, then finished-and-unseen).
    @Published private(set) var queue: [AgentSession] = []
    /// The finished card shows its diff in place instead of the file list.
    @Published private(set) var showsDiff = false

    private let state = AppState.shared
    private var contextWorkspace: String?
    // Latest pending requests, as emitted (the @Published properties are still the old value then).
    private var approvals: [String: ApprovalInfo] = [:]
    private var questions: [String: PendingQuestion] = [:]
    private var cancellables = Set<AnyCancellable>()
    private var wasExpanded = false

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
        summoned = false
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
    var holdsIslandOpen: Bool { isOpen && !queue.isEmpty }

    /// Whether the assistant panel draws `view` right now (`AssistantRouting`).
    func routesToPanel(_ view: IslandView) -> Bool {
        AssistantRouting.usesPanel(isOverview: view == .overview, isAlertView: view.isAlertView,
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
        let finishedFiles = main.map { changedFiles(for: $0.id).count } ?? 0
        if showsDiff && !(main?.phase == .finished && main?.finishedSeen == false && finishedFiles > 0) {
            showsDiff = false
        }
        let open = AssistantOpenRules.isOpen(summoned: summoned, selectedId: selectedId, queue: queue,
                                             dismissedSignature: dismissedSignature)
        if open != isOpen { isOpen = open }
        let question = main.flatMap { questions[$0.id] }
        let content = AssistantPanelContent.resolve(
            main: main,
            hasApproval: main.map { approvals[$0.id] != nil } ?? false,
            questionRows: question.map { q in
                (q.question.questions.map(\.options.count).max() ?? 0) + 1   // + the "Other..." row
            },
            finishedFiles: finishedFiles, showsDiff: showsDiff)
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
