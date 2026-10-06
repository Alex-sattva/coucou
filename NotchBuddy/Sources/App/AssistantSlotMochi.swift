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

    @StateObject private var engine: BotEngine

    init(hex: String, state: BotState, canvasSize: CGFloat, isPaused: Bool) {
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
                engine.update(dt: 1.0 / 30.0)
                engine.draw(context: context, size: size)
            }
        }
        .frame(width: canvasSize, height: canvasSize)
        .onAppear { engine.setState(state, force: true) }
        .onChange(of: hex) { _, newValue in engine.bodyColor = cgColorFromHex(newValue) }
        .onChange(of: state) { _, newValue in engine.setState(newValue) }
    }
}
