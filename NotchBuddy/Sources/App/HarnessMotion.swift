import SwiftUI

// MARK: - Harness Mochi states

/// The harness's presentation state for the big Mochi.
///
/// Ported from the prototype's `STATE` table
/// (`design/prototype/harness-main-voice.html:332-342`).
/// Two cases — `listening` and `speaking` — have no `BotState` equivalent: they are
/// expressed as motion on the harness's own wrapper (see `HarnessMotion`) around a
/// bridged `BotState`, so the shipping renderer is never extended for the harness.
enum HarnessMochiState: String, CaseIterable, Sendable {
    case idle
    case listening
    case speaking
    case working
    case thinking
    case approval
    case question
    case finished
    case error
    case sleeping
}

extension HarnessMochiState {
    /// The halo colour (prototype `STATE[...].c`).
    var accentHex: String {
        switch self {
        case .idle:      return "#E6E9EE"
        case .listening: return "#3B9EFF"
        case .speaking:  return "#34D399"
        case .working:   return "#3B9EFF"
        case .thinking:  return "#8B5CF6"
        case .approval:  return "#F5A524"
        case .question:  return "#22D3EE"
        case .finished:  return "#34D399"
        case .error:     return "#F4505E"
        case .sleeping:  return "#94A3B8"
        }
    }

    /// The shipping renderer state this presentation state draws as.
    /// `listening`/`speaking` ride on `.idle` eyes; their motion is the wrapper's.
    var botState: BotState {
        switch self {
        case .idle, .listening, .speaking: return .idle
        case .working:                     return .working
        case .thinking:                    return .thinking
        case .approval:                    return .approval
        case .question:                    return .question
        case .finished:                    return .finished
        case .error:                       return .error
        case .sleeping:                    return .sleeping
        }
    }

    /// Prototype motion name (`STATE[...].motion`), kept for traceability.
    var motionName: String? {
        switch self {
        case .idle, .finished:      return nil
        case .listening:            return "breathe"
        case .speaking:             return "chomp"
        case .working, .thinking:   return "work"
        case .approval:             return "bounce"
        case .question:             return "tilt"
        case .error:                return "shake"
        case .sleeping:             return "sleep"
        }
    }

    /// `working` and `thinking` spin the workspace-colour ring.
    var spinsRing: Bool { self == .working || self == .thinking }

    /// `listening` pings the ring open instead of spinning it.
    var pingsRing: Bool { self == .listening }
}

// MARK: - Motion contract

/// The Mochi motion contract — the only place the Harness Mochi's animation is defined.
///
/// Visual source of truth: `design/prototype/harness-main-voice.html`.
/// The prototype's `--spr` is `cubic-bezier(.32,1.22,.42,1)`; every number below is
/// copied from its CSS or from its `Mochi` / `hopPose` implementations.
/// Views must not invent their own curves — they read them from here, so the
/// surface and the prototype cannot drift apart.
enum HarnessMotion {

    // MARK: Core curves

    /// The focus swap: `transition: opacity .32s, filter .32s, transform .32s`.
    static var agentSwap: Animation { .easeInOut(duration: agentSwapDuration) }
    /// The left card's wash: `transition: background .5s ease`.
    static var wash: Animation { .easeInOut(duration: washDuration) }

    // MARK: Agent swap (`focusTo`)

    /// Fade + blur + scale the outgoing card before the workspace changes.
    static let agentSwapDuration: Double = 0.32
    static let agentSwapBlur: CGFloat = 8
    static let agentSwapScale: CGFloat = 0.97
    /// `await sleep(300)` between the fade-out and the content swap.
    static let agentSwapSwapDelay: Double = 0.30
    /// `await sleep(800)` before the surface settles back to idle.
    static let agentSwapSettleDelay: Double = 0.80

    // MARK: Mochi hop

    /// One keyframe of the prototype's `hopPose()` table.
    struct HopKey: Sendable {
        let t: CGFloat
        let sx: CGFloat
        let sy: CGFloat
    }

    /// `hopPose()` — 900 ms of squash-stretch. The prototype eases between
    /// consecutive keys with a quadratic in/out.
    static let hopDuration: Double = 0.90
    static let hopKeys: [HopKey] = [
        HopKey(t: 0.00, sx: 1.00, sy: 1.00),
        HopKey(t: 0.25, sx: 1.25, sy: 0.72),
        HopKey(t: 0.50, sx: 0.88, sy: 1.15),
        HopKey(t: 0.75, sx: 1.06, sy: 0.94),
        HopKey(t: 1.00, sx: 1.00, sy: 1.00),
    ]
    /// `-sin(e·π)·.1` — the hop's lift, as a fraction of the body radius.
    static let hopLiftAmplitude: CGFloat = 0.10

    /// `hopPose(e)` for progress `e` in 0…1.
    static func hopPose(at e: CGFloat) -> (sx: CGFloat, sy: CGFloat) {
        let first = hopKeys[0]
        guard e > 0 else { return (first.sx, first.sy) }
        guard e < 1 else { return (1, 1) }
        for i in 0..<(hopKeys.count - 1) {
            let a = hopKeys[i]
            let b = hopKeys[i + 1]
            guard e <= b.t else { continue }
            let u = (e - a.t) / (b.t - a.t)
            let eu = u < 0.5 ? 2 * u * u : 1 - pow(-2 * u + 2, 2) / 2
            return (lerp(a.sx, b.sx, eu), lerp(a.sy, b.sy, eu))
        }
        return (1, 1)
    }

    /// `-sin(e·π)·.1` — the hop's vertical lift at progress `e`.
    static func hopLift(at e: CGFloat) -> CGFloat {
        -sin(e * .pi) * hopLiftAmplitude
    }

    static func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }

    // MARK: State motions (prototype `Mochi.update`)

    /// `sin(t·1.6)` → 3.93 s period, ±.055 on Y and ∓.03 on X.
    static let listeningBreatheRate: Double = 1.6
    static let listeningBreatheY: CGFloat = 0.055
    static let listeningBreatheX: CGFloat = 0.03
    /// CSS `ping 1.6s ease-out infinite` — scale .9 → 1.28, opacity .9 → 0.
    static let listeningRingPing: Double = 1.6
    static let listeningRingFrom: CGFloat = 0.9
    static let listeningRingTo: CGFloat = 1.28

    /// `work`: tilt = sin(t·1.7)·.055, bob = -|sin(t·2.3)|·.035.
    static let workingTiltRate: Double = 1.7
    static let workingTiltAmplitude: CGFloat = 0.055
    static let workingBobRate: Double = 2.3
    static let workingBobAmplitude: CGFloat = 0.035
    /// CSS `spin 1s linear infinite` on the big ring.
    static let workingRingSpin: Double = 1.0

    /// `bounce`: bob = -|sin(t·3.6)|·.06, tilt = sin(t·2)·.045.
    static let approvalBounceRate: Double = 3.6
    static let approvalBounceAmplitude: CGFloat = 0.06
    static let approvalTiltRate: Double = 2.0
    static let approvalTiltAmplitude: CGFloat = 0.045

    /// `tilt`: a held tilt of .17 rad.
    static let questionTilt: CGFloat = 0.17

    /// `sleep`: scale = 1 + sin(t·1.1)·.03.
    static let sleepingBreatheRate: Double = 1.1
    static let sleepingBreatheAmplitude: CGFloat = 0.03

    /// `shake`: offsetX = sin(t·30)·.04 — 4.8 Hz, ±.04 R.
    static let errorShakeRate: Double = 30
    static let errorShakeAmplitude: CGFloat = 0.04

    /// `speaking` — the mouth chomps at this period (plan: "speaking chomp .5 s").
    static let speakingChomp: Double = 0.5
    static let speakingChompAmplitude: CGFloat = 0.06

    /// Blink cadence, copied from `Mochi.update`: 2.2 s + up to 3.2 s of jitter.
    static let blinkBase: Double = 2.2
    static let blinkJitter: Double = 3.2
    static let blinkDuration: Double = 0.09

    // MARK: Pill flight

    /// 950 ms: a clone dot flies into the Mochi, then a 14-dot radial burst.
    static let pillFlightDuration: Double = 0.95
    static let pillBurstDots: Int = 14
    static let pillBurstRadius: CGFloat = 26

    // MARK: Wash

    /// `rgba(color, .22)` at `radial-gradient(130% 100% at 22% 128%)`, fading by 62 %.
    static let washOpacity: Double = 0.22
    static let washDuration: Double = 0.5
    static let washCenterX: CGFloat = 0.22
    static let washCenterY: CGFloat = 1.28
    static let washRadiusFraction: CGFloat = 0.62
}

// MARK: - Metrics

/// Sizes the Harness Mochi needs. Colours, curves and timings live in `HarnessMotion`.
enum HarnessMetrics {
    /// Default diameter of the Harness Mochi when a caller does not pass one.
    static let bigMochi: CGFloat = 26
}
