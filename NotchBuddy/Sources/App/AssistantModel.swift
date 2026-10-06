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
    /// Set when the user clicks a small Mochi; cleared when the island leaves the expanded mode.
    @Published private(set) var selectedId: String?
    @Published private(set) var sessions: [String: AgentSession] = [:]

    private let state = AppState.shared
    private var contextWorkspace: String?
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
        state.$mode
            .sink { [weak self] mode in
                MainActor.assumeIsolated { self?.modeChanged(mode) }
            }
            .store(in: &cancellables)
    }

    var mainSession: AgentSession? { mainId.flatMap { sessions[$0] } }

    /// Small Mochis in slot order (only live sessions).
    var subs: [AgentSession] { subOrder.compactMap { sessions[$0] } }

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

    // MARK: - Private

    private func modeChanged(_ mode: IslandMode) {
        let expanded = mode == .expanded
        defer { wasExpanded = expanded }
        // The selection lasts while the panel is open; folding the island drops it.
        if wasExpanded && !expanded { clearSelection() }
    }

    private func recompute(sessions new: [String: AgentSession]) {
        sessions = new
        if let selectedId, new[selectedId] == nil { self.selectedId = nil }

        let list = new.values.sorted { $0.id < $1.id }
        let newMain = MainAgentPicker.pick(sessions: list, selectedId: selectedId,
                                           contextWorkspace: contextWorkspace, previousMainId: mainId)
        let update = SubSlotOrder.update(order: subOrder, alive: list.map(\.id),
                                         oldMain: mainId, newMain: newMain)
        if newMain != mainId { mainId = newMain }
        if update.order != subOrder { subOrder = update.order }
        recolourIndex = update.recolourIndex
    }
}
