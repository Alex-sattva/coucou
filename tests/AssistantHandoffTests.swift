import Foundation

@main
@MainActor
enum AssistantHandoffTests {

    static var failures = 0

    static func checkTrue(_ label: String, _ value: Bool) {
        if value { print("  ✓ \(label)") }
        else      { print("  ✗ \(label)"); failures += 1 }
    }

    static func checkEq<T: Equatable>(_ label: String, _ got: T, _ expected: T) {
        if got == expected { print("  ✓ \(label)") }
        else { print("  ✗ \(label)  got: \(got)  expected: \(expected)"); failures += 1 }
    }

    static func near(_ a: Double, _ b: Double, _ eps: Double = 1e-9) -> Bool { abs(a - b) < eps }

    static func main() {
        print("HandoffTimeline")
        do {
            checkTrue("landing at 62 % of 0.95 s", near(HandoffTimeline.landingDelay, 0.589))
            if case .travel(let e, let d, let h) = HandoffTimeline.frame(elapsed: 0) {
                checkTrue("start: eased 0, diameter 9, halo 0.25", near(e, 0) && near(d, 9) && near(h, 0.25))
            } else { checkTrue("start is travel", false) }
            if case .travel(let e, let d, _) = HandoffTimeline.frame(elapsed: 0.589 * 0.5) {
                checkTrue("half travel: cubic ease-out 0.875, diameter 4.625", near(e, 0.875) && near(d, 9 - 5 * 0.875))
            } else { checkTrue("mid is travel", false) }
            if case .travel(let e, let d, let h) = HandoffTimeline.frame(elapsed: 0.5889999) {
                checkTrue("end of travel: eased ~1, diameter ~4, halo ~0", near(e, 1, 1e-6) && near(d, 4, 1e-4) && near(h, 0, 1e-6))
            } else { checkTrue("just before landing is travel", false) }
            if case .burst(let r, let o) = HandoffTimeline.frame(elapsed: 0.589) {
                checkTrue("landing: burst starts at radius 0, opacity 1", near(r, 0, 1e-9) && near(o, 1, 1e-9))
            } else { checkTrue("landing is burst", false) }
            if case .burst(let r, let o) = HandoffTimeline.frame(elapsed: 0.589 + 0.361 / 2) {
                checkTrue("half burst: radius 13, opacity 0.5", near(r, 13, 1e-6) && near(o, 0.5, 1e-6))
            } else { checkTrue("mid burst", false) }
            checkEq("after 0.95 s: finished", HandoffTimeline.frame(elapsed: 0.95), .finished)
            checkEq("long after: finished", HandoffTimeline.frame(elapsed: 5), .finished)
            if case .travel(let e, _, _) = HandoffTimeline.frame(elapsed: -0.1) {
                checkTrue("negative elapsed clamps to the start", near(e, 0))
            } else { checkTrue("negative is travel", false) }
            checkEq("14 dots", HandoffTimeline.burstDots, 14)
        }

        print("HandoffPlanner")
        do {
            // A was main, the user clicked B (slot 1). SubSlotOrder gives order [c, a], recolour index 1.
            let order = ["c", "a"]
            let fly = HandoffPlanner.plan(oldMain: "a", newMain: "b", newOrder: order, recolourIndex: 1,
                                          visible: true, reduceMotion: false)
            checkEq("sub -> main flies from the sub's slot", fly?.fromSlot, 1)
            checkEq("slot holds the new main until landing", fly?.holds, ["a": "b"])
            checkEq("slow blend during the flight", fly?.blendRate, 0.045)
            checkEq("hops on landing", fly?.hops, true)

            let none = HandoffPlanner.plan(oldMain: "a", newMain: "a", newOrder: order, recolourIndex: nil,
                                           visible: true, reduceMotion: false)
            checkTrue("same main -> no plan", none == nil)
            checkTrue("no main -> no plan",
                      HandoffPlanner.plan(oldMain: "a", newMain: nil, newOrder: [], recolourIndex: nil,
                                          visible: true, reduceMotion: false) == nil)

            let first = HandoffPlanner.plan(oldMain: nil, newMain: "a", newOrder: [], recolourIndex: nil,
                                            visible: true, reduceMotion: false)
            checkEq("first main: no flight", first?.fromSlot, nil)
            checkEq("first main: fast colour", first?.blendRate, 0.12)
            checkEq("first main: hops at once", first?.hops, true)
            checkEq("first main: nothing held", first?.holds, [:])

            let ctx = HandoffPlanner.plan(oldMain: "a", newMain: "z", newOrder: ["b", "c"], recolourIndex: nil,
                                          visible: true, reduceMotion: false)
            checkEq("context switch to a never-shown session: no flight", ctx?.fromSlot, nil)
            checkEq("context switch: hops", ctx?.hops, true)

            let hidden = HandoffPlanner.plan(oldMain: "a", newMain: "b", newOrder: order, recolourIndex: 1,
                                             visible: false, reduceMotion: false)
            checkEq("hidden: no flight", hidden?.fromSlot, nil)
            checkEq("hidden: colour switches at once", hidden?.blendRate, 1.0)
            checkEq("hidden: nothing held", hidden?.holds, [:])
            checkEq("hidden: no hop", hidden?.hops, false)

            let reduced = HandoffPlanner.plan(oldMain: "a", newMain: "b", newOrder: order, recolourIndex: 1,
                                              visible: true, reduceMotion: true)
            checkEq("reduce motion: no flight", reduced?.fromSlot, nil)
            checkEq("reduce motion: no hop", reduced?.hops, false)
            checkEq("reduce motion: short crossfade", reduced?.blendRate, 0.3)
            checkEq("reduce motion: nothing held", reduced?.holds, [:])

            let overflow = HandoffPlanner.plan(oldMain: "a", newMain: "b",
                                               newOrder: ["1", "2", "3", "4", "5", "a"], recolourIndex: 5,
                                               visible: true, reduceMotion: false)
            checkEq("slot hidden behind +N: no flight", overflow?.fromSlot, nil)

            let deadOld = HandoffPlanner.plan(oldMain: "a", newMain: "b", newOrder: ["c"], recolourIndex: nil,
                                              visible: true, reduceMotion: false)
            checkEq("old main gone (slot closes): no flight", deadOld?.fromSlot, nil)
        }

        print("SlotDisplay")
        do {
            checkEq("no hold: real occupants", SlotDisplay.ids(order: ["c", "a"], holds: [:]), ["c", "a"])
            checkEq("hold: the slot keeps the old occupant",
                    SlotDisplay.ids(order: ["c", "a"], holds: ["a": "b"]), ["c", "b"])
            checkEq("hold for a gone slot is ignored",
                    SlotDisplay.ids(order: ["c"], holds: ["a": "b"]), ["c"])
            checkEq("only the held slot changes",
                    SlotDisplay.ids(order: ["x", "a", "y"], holds: ["a": "b"]), ["x", "b", "y"])
        }

        print("ColorBlend")
        do {
            let a = BlendRGB(r: 0, g: 0, b: 0), b = BlendRGB(r: 1, g: 0.5, b: 0.25)
            let one = ColorBlend.step(a, toward: b, rate: 0.5, dt: 1.0 / 60)
            checkTrue("one 60 fps frame at rate 0.5 covers half", near(one.r, 0.5) && near(one.g, 0.25))
            var two = ColorBlend.step(a, toward: b, rate: 0.5, dt: 1.0 / 120)
            two = ColorBlend.step(two, toward: b, rate: 0.5, dt: 1.0 / 120)
            checkTrue("two 120 fps frames equal one 60 fps frame", near(two.r, one.r, 1e-9))
            checkEq("rate 1 jumps", ColorBlend.step(a, toward: b, rate: 1, dt: 1.0 / 60), b)
            var c = a
            var frames = 0
            while c != b && frames < 1000 { c = ColorBlend.step(c, toward: b, rate: 0.045, dt: 1.0 / 60); frames += 1 }
            checkTrue("rate 0.045 settles", c == b)
            checkTrue("rate 0.045 takes about a second (60..140 frames)", frames > 60 && frames < 140)
            let tiny = BlendRGB(r: 0.0015, g: 0, b: 0)
            checkEq("snaps when closer than 0.002", ColorBlend.step(a, toward: tiny, rate: 0.01, dt: 1.0 / 60), tiny)
        }

        if failures > 0 { print("\n\(failures) FAILED"); exit(1) }
        print("\nAll passed")
    }
}
