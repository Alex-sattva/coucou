import Foundation

// Pure rules for "hold ⌥ to talk". Foundation only, so scripts/test-option-hold.sh compiles it
// without AppKit. `OptionHoldMonitor` feeds it key events and carries out the actions it returns.
//
//   idle      nothing held (or a chord that must be released first)
//   pending   ⌥ alone is down; the 300 ms timer runs
//   listening the timer fired and nothing else was pressed: the microphone is open
//   blocked   a chord / another key / Esc used up this hold: ignore everything until all
//             modifiers are released (so ⌃⌥Space, ⌥-characters and "Esc then keep ⌥" never start voice)

/// The four device-independent modifiers that matter. Caps Lock, Fn and the numeric-pad flag are
/// dropped before the machine sees them.
struct OptionHoldMods: OptionSet, Sendable {
    let rawValue: Int
    static let option  = OptionHoldMods(rawValue: 1 << 0)
    static let command = OptionHoldMods(rawValue: 1 << 1)
    static let control = OptionHoldMods(rawValue: 1 << 2)
    static let shift   = OptionHoldMods(rawValue: 1 << 3)
}

enum OptionHoldEvent: Equatable, Sendable {
    /// The full set of modifiers down after a `flagsChanged` event.
    case modifiers(OptionHoldMods)
    case keyDown(keyCode: UInt16)
    /// The 300 ms hold timer ran out.
    case timerFired
    /// Voice stopped for a reason the machine did not cause (mic button, panel closed, error).
    case voiceEnded
}

enum OptionHoldAction: Equatable, Sendable {
    case scheduleTimer
    case cancelTimer
    case startListening
    /// ⌥ released while listening: stop and send the transcript if it is not empty.
    case stopAndSend
    /// Esc while listening: stop, send nothing.
    case cancelListening
}

struct OptionHoldMachine: Equatable, Sendable {
    enum Phase: Equatable, Sendable { case idle, pending, listening, blocked }

    static let holdDelay: TimeInterval = 0.3
    static let escapeKeyCode: UInt16 = 53

    private(set) var phase: Phase = .idle
    private(set) var down: OptionHoldMods = []

    /// Back to the start (the monitors were removed). Returns the actions to undo what is running.
    mutating func reset() -> [OptionHoldAction] {
        let was = phase
        phase = .idle
        down = []
        switch was {
        case .pending:   return [.cancelTimer]
        case .listening: return [.cancelListening]
        default:         return []
        }
    }

    mutating func handle(_ event: OptionHoldEvent) -> [OptionHoldAction] {
        switch event {
        case .modifiers(let mods):
            down = mods
            switch phase {
            case .idle:
                if mods == [.option] { phase = .pending; return [.scheduleTimer] }
                if !mods.isEmpty { phase = .blocked }
                return []
            case .pending:
                if mods == [.option] { return [] }
                phase = mods.isEmpty ? .idle : .blocked
                return [.cancelTimer]
            case .listening:
                guard !mods.contains(.option) else { return [] }
                phase = mods.isEmpty ? .idle : .blocked
                return [.stopAndSend]
            case .blocked:
                if mods.isEmpty { phase = .idle }
                return []
            }

        case .keyDown(let code):
            switch phase {
            case .pending:
                phase = .blocked
                return [.cancelTimer]
            case .listening where code == Self.escapeKeyCode:
                phase = down.isEmpty ? .idle : .blocked
                return [.cancelListening]
            default:
                return []
            }

        case .timerFired:
            guard phase == .pending else { return [] }
            phase = .listening
            return [.startListening]

        case .voiceEnded:
            guard phase == .listening else { return [] }
            phase = down.isEmpty ? .idle : .blocked
            return []
        }
    }
}
