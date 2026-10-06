import Foundation

@main
enum OptionHoldLogicTests {
    nonisolated(unsafe) static var failures = 0

    static func checkEq<T: Equatable>(_ label: String, _ got: T, _ expected: T) {
        if got == expected { print("  ✓ \(label)") }
        else { print("  ✗ \(label)  got: \(got)  expected: \(expected)"); failures += 1 }
    }

    typealias M = OptionHoldMods
    static let opt: M = [.option]

    static func main() {
        print("OptionHoldMachine")
        do {
            var m = OptionHoldMachine()
            checkEq("option alone -> timer", m.handle(.modifiers(opt)), [.scheduleTimer])
            checkEq("pending", m.phase, .pending)
            checkEq("timer fired -> listening", m.handle(.timerFired), [.startListening])
            checkEq("release -> send", m.handle(.modifiers([])), [.stopAndSend])
            checkEq("idle again", m.phase, .idle)
        }
        do {
            var m = OptionHoldMachine()
            _ = m.handle(.modifiers(opt))
            checkEq("release before 300 ms cancels timer", m.handle(.modifiers([])), [.cancelTimer])
            checkEq("idle", m.phase, .idle)
            checkEq("late timer ignored", m.handle(.timerFired), [])
        }
        do {
            var m = OptionHoldMachine()
            _ = m.handle(.modifiers(opt))
            checkEq("keyDown during hold cancels", m.handle(.keyDown(keyCode: 0)), [.cancelTimer])
            checkEq("blocked", m.phase, .blocked)
            checkEq("late timer ignored", m.handle(.timerFired), [])
            checkEq("still blocked when option released but shift held", m.handle(.modifiers([.shift])), [])
            checkEq("blocked", m.phase, .blocked)
            checkEq("all released -> idle", m.handle(.modifiers([])), [])
            checkEq("idle", m.phase, .idle)
        }
        do {
            var m = OptionHoldMachine()
            _ = m.handle(.modifiers(opt))
            checkEq("second modifier cancels", m.handle(.modifiers([.option, .control])), [.cancelTimer])
            checkEq("blocked", m.phase, .blocked)
            checkEq("control released, option alone does not arm", m.handle(.modifiers(opt)), [])
            checkEq("still blocked", m.phase, .blocked)
        }
        do {
            var m = OptionHoldMachine()
            checkEq("command first, then option: no arm", m.handle(.modifiers([.command])), [])
            checkEq("blocked", m.phase, .blocked)
            checkEq("cmd+opt: no arm", m.handle(.modifiers([.command, .option])), [])
            checkEq("release all", m.handle(.modifiers([])), [])
            checkEq("then option alone arms", m.handle(.modifiers(opt)), [.scheduleTimer])
        }
        do {
            var m = OptionHoldMachine()
            _ = m.handle(.modifiers(opt)); _ = m.handle(.timerFired)
            checkEq("typing while listening is ignored", m.handle(.keyDown(keyCode: 0)), [])
            checkEq("still listening", m.phase, .listening)
            checkEq("shift added while listening keeps listening", m.handle(.modifiers([.option, .shift])), [])
            checkEq("Esc cancels", m.handle(.keyDown(keyCode: 53)), [.cancelListening])
            checkEq("option still held -> blocked", m.phase, .blocked)
            checkEq("release after Esc sends nothing", m.handle(.modifiers([])), [])
            checkEq("idle", m.phase, .idle)
        }
        do {
            var m = OptionHoldMachine()
            _ = m.handle(.modifiers(opt)); _ = m.handle(.timerFired)
            checkEq("option released with shift still down sends", m.handle(.modifiers([.shift])), [.stopAndSend])
            checkEq("blocked until all up", m.phase, .blocked)
        }
        do {
            var m = OptionHoldMachine()
            _ = m.handle(.modifiers(opt)); _ = m.handle(.timerFired)
            checkEq("voice ended by itself while ⌥ held", m.handle(.voiceEnded), [])
            checkEq("blocked (no restart while still held)", m.phase, .blocked)
            checkEq("release sends nothing", m.handle(.modifiers([])), [])
            checkEq("idle", m.phase, .idle)
        }
        do {
            var m = OptionHoldMachine()
            _ = m.handle(.modifiers(opt)); _ = m.handle(.timerFired)
            _ = m.handle(.modifiers([]))
            checkEq("voiceEnded when idle is a no-op", m.handle(.voiceEnded), [])
            checkEq("idle", m.phase, .idle)
        }
        do {
            var m = OptionHoldMachine()
            _ = m.handle(.modifiers(opt))
            checkEq("reset while pending", m.reset(), [.cancelTimer])
            _ = m.handle(.modifiers(opt)); _ = m.handle(.timerFired)
            checkEq("reset while listening", m.reset(), [.cancelListening])
            checkEq("reset -> idle", m.phase, .idle)
            checkEq("reset when idle", m.reset(), [])
        }
        do {
            var m = OptionHoldMachine()
            checkEq("keyDown while idle ignored", m.handle(.keyDown(keyCode: 53)), [])
            checkEq("hold delay is 300 ms", OptionHoldMachine.holdDelay, 0.3)
        }

        if failures > 0 { print("\(failures) FAILED"); exit(1) }
        print("All option-hold tests passed")
    }
}
