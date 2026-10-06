import SwiftUI

extension SessionPhase {
    /// The presentation state the main Mochi draws for a session phase.
    var mochiState: HarnessMochiState {
        switch self {
        case .thinking: return .thinking
        case .working:  return .working
        case .approval: return .approval
        case .question: return .question
        case .blocked:  return .error
        case .finished: return .finished
        case .idle:     return .idle
        }
    }
}

/// The main Mochi: ONE instance, always in the island's view tree, so Step 7 can move it between
/// the strip and the panel without recreating the engine (same technique as `BotPlacement`).
///
/// For now it is visible only in compact mode, left of the camera. In expanded mode it stays in
/// the tree but is hidden and paused: the shipping bot / the old harness card draw the Mochi
/// there until the panel (Step 7) gives it a position.
struct AssistantMainMochi: View {
    @ObservedObject var model: AssistantModel
    @ObservedObject var state: AppState
    let islandW: CGFloat
    let islandH: CGFloat

    var body: some View {
        let session = model.mainSession
        let visible = state.mode == .compact && session != nil
        let geo = AssistantStripGeometry(
            islandWidth: islandW, islandHeight: islandH, notchWidth: state.notchWidth,
            restingDiameter: IslandRestingLayout(width: islandW, height: islandH).botDiameter)
        let canvas = geo.mainDiameter / 0.6   // same body-to-canvas ratio as BotPlacement

        ZStack {
            HarnessMochiView(hex: session?.colorHex ?? "#E6E9EE",
                             state: session?.phase.mochiState ?? .idle,
                             diameter: max(1, canvas),
                             isPaused: !visible,
                             showsDecor: false)
                .frame(width: canvas, height: canvas)
            if let hex = session?.statusDotHex {
                AssistantStatusDot(hex: hex)
                    .offset(x: geo.mainDiameter * 0.5, y: -geo.mainDiameter * 0.38)
            }
        }
        .position(x: geo.mainCentreX, y: geo.centreY)
        // Idle motion stays inside the resting strip, like BotPlacement's compact bot.
        .mask(alignment: .topLeading) { Rectangle().frame(width: islandW, height: islandH) }
        .opacity(visible ? 1 : 0)
        .animation(.easeInOut(duration: 0.2), value: visible)
        .allowsHitTesting(false)
    }
}

/// 6 pt status dot (amber approval/question, red blocked, green finished-unseen).
struct AssistantStatusDot: View {
    let hex: String
    var size: CGFloat = 6

    var body: some View {
        Circle()
            .fill(Color(hex: hex))
            .frame(width: size, height: size)
            .overlay(Circle().stroke(Color.black, lineWidth: 1))
    }
}
