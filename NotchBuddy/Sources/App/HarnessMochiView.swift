import SwiftUI

/// The big Mochi at the heart of the voice harness.
///
/// The shipping `BotCanvasView` owns its engine privately and derives both its colour
/// and its state from `AppState.focusTask` (`BotCanvasView.swift:13`, `:39-46`, `:95`),
/// so it can neither express the harness's `listening`/`speaking` moods nor be told to
/// hop. This view follows the injected-engine precedent instead
/// (`DesktopMochi.swift:23-27`, `:183-186`): it owns a `BotEngine`, points `bodyColor`
/// at the workspace's colour, drives `setState` from `HarnessMochiState`, and layers the
/// harness motions and the workspace-coloured ring on top.
///
/// Every duration and amplitude comes from `HarnessMotion` — nothing here invents a
/// curve, so the surface cannot drift from the prototype.
struct HarnessMochiView: View {

    let hex: String
    let state: HarnessMochiState
    let diameter: CGFloat
    /// Bumped by the model on every focus change; a new value plays the hop.
    let hopToken: Int
    /// Stops the 60 Hz timeline while the island is hidden or another view has the floor.
    /// CLAUDE.md's budget is 0 % CPU when hidden; a `TimelineView(.animation)` left running
    /// behind an `opacity(0)` is the classic way to break that.
    let isPaused: Bool
    /// False in the compact strip: no halo and no ring, just the Mochi (the prototype's quiet strip).
    let showsDecor: Bool

    @StateObject private var engine = BotEngine()
    @State private var hopStart: Double = 0

    /// Keys this wrapper drives itself. Foreign locks (an in-flight roll, a badge
    /// tween) are left alone.
    private static let ownedKeys: Set<String> = ["sx", "sy", "oy", "ox", "tilt"]

    init(hex: String,
         state: HarnessMochiState,
         diameter: CGFloat = HarnessMetrics.bigMochi,
         hopToken: Int = 0,
         isPaused: Bool = false,
         showsDecor: Bool = true) {
        self.hex = hex
        self.state = state
        self.diameter = diameter
        self.hopToken = hopToken
        self.isPaused = isPaused
        self.showsDecor = showsDecor
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: isPaused)) { timeline in
            let now = timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                if showsDecor { halo }
                Canvas { context, size in
                    engine.update(dt: 1.0 / 60.0)
                    applyMotion(now: now)
                    engine.draw(context: context, size: size)
                }
                .frame(width: diameter, height: diameter)
                if showsDecor { ring(now: now) }
            }
            .frame(width: diameter, height: diameter)
        }
        // `Date`'s reference interval, NOT `CACurrentMediaTime()` — the two bases differ by
        // ~10^9 s, which would make the hop read as already finished (or never started).
        .onChange(of: hopToken) { _, _ in hopStart = Date().timeIntervalSinceReferenceDate }
        .onAppear {
            engine.bodyColor = cgColorFromHex(hex)
            engine.setState(state.botState, force: true)
        }
        .onChange(of: hex) { _, newValue in
            engine.bodyColor = cgColorFromHex(newValue)
        }
        .onChange(of: state) { _, newValue in
            engine.setState(newValue.botState)
        }
    }

    // MARK: - Halo

    private var halo: some View {
        Circle()
            .fill(
                RadialGradient(
                    gradient: Gradient(stops: [
                        .init(color: Color(hex: state.accentHex).opacity(0.55), location: 0),
                        .init(color: Color(hex: state.accentHex).opacity(0.0), location: 0.64)
                    ]),
                    center: .center,
                    startRadius: 0,
                    endRadius: diameter * 0.5
                )
            )
            .frame(width: diameter * 1.6, height: diameter * 1.6)
            .blur(radius: 10)
            .opacity(0.42)
            .animation(HarnessMotion.wash, value: state)
    }

    // MARK: - Ring

    @ViewBuilder
    private func ring(now: Double) -> some View {
        let accent = Color(hex: state.accentHex)
        ZStack {
            if state.spinsRing {
                // The prototype's `border-top-color` spinner: a short bright arc
                // travelling around the circle at `workingRingSpin` per revolution.
                Circle()
                    .trim(from: 0, to: 0.75)
                    .stroke(accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(now.truncatingRemainder(dividingBy: HarnessMotion.workingRingSpin)
                                             / HarnessMotion.workingRingSpin * 360))
                    .shadow(color: accent.opacity(0.85), radius: 7)
            }
            if state.pingsRing {
                // `@keyframes ping`: scale .9 → 1.28 while fading out, forever.
                let p = now.truncatingRemainder(dividingBy: HarnessMotion.listeningRingPing) / HarnessMotion.listeningRingPing
                Circle()
                    .stroke(accent, lineWidth: 2)
                    .scaleEffect(HarnessMotion.listeningRingFrom
                                 + (HarnessMotion.listeningRingTo - HarnessMotion.listeningRingFrom) * CGFloat(p))
                    .opacity(0.9 * (1 - p))
            }
        }
        .padding(diameter * 0.06)
        .opacity(state.spinsRing || state.pingsRing ? 1 : 0)
        .animation(HarnessMotion.wash, value: state)
    }

    // MARK: - Motion

    /// Applies the harness's own per-frame posture on top of the engine's state
    /// machine. Locks only the keys the current posture actually writes, so
    /// `BotEngine.update(dt:)` cannot smooth them away — and, just as important, a key a
    /// posture does NOT write stays unlocked and eases back to neutral instead of freezing
    /// at the previous state's value (e.g. `.error`'s `ox` shake or `.question`'s tilt).
    @MainActor
    private func applyMotion(now: Double) {
        var locked: Set<String> = []
        let t = CGFloat(now)

        switch state {
        case .idle, .finished:
            // `.finished` rides the engine's own 950 ms roll and squash celebration;
            // `.idle` is the engine's breathe, so nothing is locked here.
            break

        case .listening:
            let breathe = sin(t * CGFloat(HarnessMotion.listeningBreatheRate))
            engine.sy = 1 + breathe * HarnessMotion.listeningBreatheY
            engine.sx = 1 - breathe * HarnessMotion.listeningBreatheX
            locked.formUnion(["sx", "sy"])

        case .speaking:
            let chomp = sin(t * 2 * .pi / CGFloat(HarnessMotion.speakingChomp))
            engine.sy = 1 + chomp * HarnessMotion.speakingChompAmplitude
            locked.insert("sy")

        case .working, .thinking:
            engine.tilt = sin(t * CGFloat(HarnessMotion.workingTiltRate)) * HarnessMotion.workingTiltAmplitude
            engine.oy = -abs(sin(t * CGFloat(HarnessMotion.workingBobRate))) * HarnessMotion.workingBobAmplitude
            locked.formUnion(["tilt", "oy"])

        case .approval:
            engine.oy = -abs(sin(t * CGFloat(HarnessMotion.approvalBounceRate))) * HarnessMotion.approvalBounceAmplitude
            engine.tilt = sin(t * CGFloat(HarnessMotion.approvalTiltRate)) * HarnessMotion.approvalTiltAmplitude
            locked.formUnion(["oy", "tilt"])

        case .question:
            engine.tilt = HarnessMotion.questionTilt
            locked.insert("tilt")

        case .error:
            engine.ox = sin(t * CGFloat(HarnessMotion.errorShakeRate)) * HarnessMotion.errorShakeAmplitude
            locked.insert("ox")

        case .sleeping:
            let breathe = sin(t * CGFloat(HarnessMotion.sleepingBreatheRate))
            engine.sy = 1 + breathe * HarnessMotion.sleepingBreatheAmplitude
            locked.insert("sy")
        }

        // The hop wins over the resting pose: the prototype's squash-stretch table
        // plus a small lift, over `hopDuration`.
        if hopStart > 0 {
            let progress = (now - hopStart) / HarnessMotion.hopDuration
            if progress >= 0, progress < 1 {
                let e = CGFloat(progress)
                let pose = HarnessMotion.hopPose(at: e)
                engine.sx = pose.sx
                engine.sy = pose.sy
                // `hopLift(at:)` already carries the sign and `hopLiftAmplitude`.
                engine.oy = HarnessMotion.hopLift(at: e)
                locked.formUnion(["sx", "sy", "oy"])
            }
        }

        engine.locks.subtract(Self.ownedKeys)
        engine.locks.formUnion(locked)
    }
}
