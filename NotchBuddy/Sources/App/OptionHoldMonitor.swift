import AppKit
import Combine

/// "Hold ⌥ to talk". Feeds global and local key monitors into `OptionHoldMachine` and carries out
/// its actions on `AssistantModel`. The monitors exist only while at least one agent session does
/// (the assistant is active); without sessions they are removed and any running voice is cancelled.
///
/// The global monitor needs Accessibility / Input Monitoring to see keys typed in other apps.
/// Without it the system simply never calls it (no prompt); the mic button still works.
@MainActor
final class OptionHoldMonitor {
    static let shared = OptionHoldMonitor()

    private var machine = OptionHoldMachine()
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var timerTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var started = false

    private init() {}

    /// Call once. Installs / removes the monitors as agent sessions appear and disappear.
    func start() {
        guard !started else { return }
        started = true
        // @Published emits on willSet: use the emitted store.
        AppState.shared.$sessionStore
            .map { !$0.sessions.isEmpty }
            .removeDuplicates()
            .sink { [weak self] active in
                MainActor.assumeIsolated { active ? self?.install() : self?.uninstall() }
            }
            .store(in: &cancellables)
        // Voice ended on its own (mic button, panel closed, recogniser stopped): tell the machine.
        VoiceInput.shared.$phase
            .sink { [weak self] phase in
                MainActor.assumeIsolated {
                    guard let self, phase == .idle || phase == .finishing else { return }
                    _ = self.machine.handle(.voiceEnded)
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Monitors

    private func install() {
        guard globalMonitor == nil, localMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            let input = Self.input(from: event)
            MainActor.assumeIsolated { self?.feed(input) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            let input = Self.input(from: event)
            MainActor.assumeIsolated { self?.feed(input) }
            return event   // never consumed: ⌥-shortcuts and typing keep working
        }
    }

    private func uninstall() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        perform(machine.reset())
    }

    private nonisolated static func input(from event: NSEvent) -> OptionHoldEvent {
        switch event.type {
        case .flagsChanged: return .modifiers(mods(event.modifierFlags))
        default:            return .keyDown(keyCode: event.keyCode)
        }
    }

    private nonisolated static func mods(_ flags: NSEvent.ModifierFlags) -> OptionHoldMods {
        var out: OptionHoldMods = []
        if flags.contains(.option)  { out.insert(.option) }
        if flags.contains(.command) { out.insert(.command) }
        if flags.contains(.control) { out.insert(.control) }
        if flags.contains(.shift)   { out.insert(.shift) }
        return out
    }

    // MARK: - Machine

    private func feed(_ event: OptionHoldEvent) {
        perform(machine.handle(event))
    }

    private func perform(_ actions: [OptionHoldAction]) {
        for action in actions {
            switch action {
            case .scheduleTimer:
                timerTask?.cancel()
                timerTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(OptionHoldMachine.holdDelay))
                    guard !Task.isCancelled else { return }
                    self?.feed(.timerFired)
                }
            case .cancelTimer:
                timerTask?.cancel()
                timerTask = nil
            case .startListening:
                timerTask = nil
                AssistantModel.shared.startVoice()
            case .stopAndSend:
                AssistantModel.shared.finishVoice(send: true)
            case .cancelListening:
                AssistantModel.shared.finishVoice(send: false)
            }
        }
    }
}
