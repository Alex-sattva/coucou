import Foundation

// Pure logic of the particle hand-off (Step 8): timing of the flight, who the strip shows while a
// dot is in the air, and how the main Mochi's colour blends. No AppKit or SwiftUI here, so the
// test script compiles this file alone. Numbers mirror `HarnessMotion` (pill flight 0.95 s,
// 14 dots, radius 26) and variant E of design/prototype/assistant-multi-agent-prototype.html.

/// A flight in progress: a dot leaves strip slot `fromSlot` and flies to the main Mochi.
struct AssistantFlight: Equatable, Sendable {
    let token: Int
    let fromSlot: Int
    /// Colour of the agent that becomes main (the dot carries it).
    let hex: String
    /// `Date().timeIntervalSinceReferenceDate` at flight start (same base as a `TimelineView`).
    let start: Double
}

enum HandoffTimeline {
    static let duration: Double = 0.95
    static let travelFraction: Double = 0.62
    static let burstDots = 14
    static let burstRadius: Double = 26
    static let startDiameter: Double = 9
    static let endDiameter: Double = 4
    static let haloOpacity: Double = 0.25
    static let shardDiameter: Double = 3.2

    /// When the dot lands (and the main Mochi hops): the end of the travel part.
    static var landingDelay: Double { duration * travelFraction }
    /// How long the burst plays after landing.
    static var burstDuration: Double { duration - landingDelay }

    enum Frame: Equatable {
        /// `eased` is the cubic ease-out position along the path, 0...1.
        case travel(eased: Double, diameter: Double, haloOpacity: Double)
        /// `radius` grows to `burstRadius`; `opacity` fades 1 -> 0.
        case burst(radius: Double, opacity: Double)
        case finished
    }

    static func frame(elapsed: Double) -> Frame {
        let progress = elapsed / duration
        if progress >= 1 { return .finished }
        if progress < travelFraction {
            let k = max(0, progress) / travelFraction
            let eased = 1 - pow(1 - k, 3)
            return .travel(eased: eased,
                           diameter: startDiameter + (endDiameter - startDiameter) * eased,
                           haloOpacity: haloOpacity * (1 - eased))
        }
        let k = (progress - travelFraction) / (1 - travelFraction)
        return .burst(radius: k * burstRadius, opacity: 1 - k)
    }
}

// MARK: - Plan

/// What a change of main agent does. Decided once, when `mainId` changes.
struct HandoffPlan: Equatable, Sendable {
    /// Slot the dot leaves; nil = no flight.
    var fromSlot: Int?
    /// New slot occupant -> the agent the slot keeps showing until the dot has landed.
    var holds: [String: String]
    /// Per-frame (60 fps) lerp rate of the main Mochi's body colour.
    var blendRate: Double
    /// The main Mochi hops when it lands (at once when there is no flight).
    var hops: Bool
}

enum HandoffPlanner {
    static let flightBlendRate = 0.045
    static let quickBlendRate = 0.12
    static let reducedMotionBlendRate = 0.3
    static let instantBlendRate = 1.0

    /// nil when the main agent did not change (or there is none).
    ///
    /// - `newOrder` / `recolourIndex`: from `SubSlotOrder.update`. `recolourIndex` is the slot the new
    ///   main was in; it now holds the previous main.
    /// - `visible`: the island is on screen. Hidden, the end state applies at once.
    static func plan(oldMain: String?, newMain: String?, newOrder: [String], recolourIndex: Int?,
                     visible: Bool, reduceMotion: Bool, maxVisibleSlots: Int = 5) -> HandoffPlan? {
        guard let newMain, newMain != oldMain else { return nil }
        if reduceMotion {
            return HandoffPlan(fromSlot: nil, holds: [:], blendRate: reducedMotionBlendRate, hops: false)
        }
        if !visible {
            return HandoffPlan(fromSlot: nil, holds: [:], blendRate: instantBlendRate, hops: false)
        }
        if oldMain != nil, let i = recolourIndex, i >= 0, i < newOrder.count, i < maxVisibleSlots {
            return HandoffPlan(fromSlot: i, holds: [newOrder[i]: newMain],
                               blendRate: flightBlendRate, hops: true)
        }
        return HandoffPlan(fromSlot: nil, holds: [:], blendRate: quickBlendRate, hops: true)
    }
}

enum SlotDisplay {
    /// The agent each slot shows. During a flight a slot keeps showing its old occupant (`holds`);
    /// after landing it shows the real one.
    static func ids(order: [String], holds: [String: String]) -> [String] {
        order.map { holds[$0] ?? $0 }
    }
}

// MARK: - Colour blend

struct BlendRGB: Equatable, Sendable {
    var r: Double
    var g: Double
    var b: Double
}

enum ColorBlend {
    /// Moves `current` toward `target`. `rate` is the fraction covered per 60 fps frame, so the
    /// result does not depend on the frame rate. Snaps when it is closer than 0.002.
    static func step(_ current: BlendRGB, toward target: BlendRGB, rate: Double, dt: Double) -> BlendRGB {
        let k = rate >= 1 ? 1 : 1 - pow(1 - max(0, rate), max(0, dt) * 60)
        let next = BlendRGB(r: current.r + (target.r - current.r) * k,
                            g: current.g + (target.g - current.g) * k,
                            b: current.b + (target.b - current.b) * k)
        let gap = max(abs(next.r - target.r), abs(next.g - target.g), abs(next.b - target.b))
        return gap < 0.002 ? target : next
    }
}
