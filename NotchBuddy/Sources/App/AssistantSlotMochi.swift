import SwiftUI

/// A small Mochi whose body colour and state can change after init. `MiniBotCanvasView` sets its
/// colour once and runs an unpaused timeline, and it is shared by shipping views, so the strip
/// uses this wrapper around `BotEngine` instead.
struct AssistantSlotMochi: View {
    let hex: String
    let state: BotState
    /// Canvas size; the body is about 0.68 x this.
    let canvasSize: CGFloat
    /// Stops the timeline while the island is hidden or not compact (0 % CPU rule).
    let isPaused: Bool
    /// Fraction of the colour gap covered per 60 fps frame when `hex` changes (0.12 = the normal
    /// fast lerp of a slot taking its agent after a hand-off).
    let blendRate: Double

    @StateObject private var engine: BotEngine
    @State private var blendTarget: BlendRGB?

    init(hex: String, state: BotState, canvasSize: CGFloat, isPaused: Bool, blendRate: Double = 0.12) {
        self.blendRate = blendRate
        self.hex = hex
        self.state = state
        self.canvasSize = canvasSize
        self.isPaused = isPaused
        _engine = StateObject(wrappedValue: {
            let e = BotEngine()
            e.isMini = true
            e.bodyColor = cgColorFromHex(hex)
            return e
        }())
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: isPaused)) { _ in
            Canvas { context, size in
                if let target = blendTarget, let bc = engine.bodyColor, let cur = BlendRGB(cgColor: bc) {
                    engine.bodyColor = ColorBlend.step(cur, toward: target, rate: blendRate, dt: 1.0 / 30.0).cgColor
                }
                engine.update(dt: 1.0 / 30.0)
                engine.draw(context: context, size: size)
            }
        }
        .frame(width: canvasSize, height: canvasSize)
        .onAppear { engine.setState(state, force: true) }
        .onChange(of: hex) { _, newValue in
            if !isPaused, let target = BlendRGB(hex: newValue) {
                blendTarget = target
            } else {
                blendTarget = nil
                engine.bodyColor = cgColorFromHex(newValue)
            }
        }
        .onChange(of: state) { _, newValue in engine.setState(newValue) }
    }
}
