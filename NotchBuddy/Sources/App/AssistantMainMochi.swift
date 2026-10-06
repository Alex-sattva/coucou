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

/// The main Mochi: ONE instance, always in the island's view tree (same technique as `BotPlacement`),
/// so it travels between the strip and the panel without recreating its engine.
///
/// Compact: left of the camera at the strip's main slot. Expanded on an assistant-panel view:
/// diameter 48 centred at (40, 64) in island coordinates (`AssistantPanelLayout`). The move uses
/// `timingCurve(0.25, 0.8, 0.25, 1, duration: 0.35)`. Any other expanded view (settings, chat,
/// upload...) hides it and pauses its timeline: the shipping bot draws there.
struct AssistantMainMochi: View {
    @ObservedObject var model: AssistantModel
    @ObservedObject var state: AppState
    let islandW: CGFloat
    let islandH: CGFloat

    private static let travel = Animation.timingCurve(0.25, 0.8, 0.25, 1, duration: 0.35)

    var body: some View {
        let session = model.mainSession
        let inPanel = state.mode == .expanded && model.routesToPanel(state.view)
        let inStrip = state.mode == .compact && session != nil
        let visible = inStrip || inPanel
        let geo = AssistantStripGeometry(
            islandWidth: islandW, islandHeight: islandH, notchWidth: state.notchWidth,
            restingDiameter: IslandRestingLayout(width: islandW, height: islandH).botDiameter)
        let diameter = inPanel ? AssistantPanelLayout.mochiDiameter : geo.mainDiameter
        let canvas = diameter / 0.6   // same body-to-canvas ratio as BotPlacement
        let centre = inPanel
            ? AssistantPanelLayout.mochiCentre
            : CGPoint(x: geo.mainCentreX, y: geo.centreY)

        ZStack {
            HarnessMochiView(hex: session?.colorHex ?? "#E6E9EE",
                             state: session?.phase.mochiState ?? .idle,
                             diameter: max(1, canvas),
                             isPaused: !visible,
                             showsDecor: inPanel)
                .frame(width: canvas, height: canvas)
            if !inPanel, let hex = session?.statusDotHex {
                AssistantStatusDot(hex: hex)
                    .offset(x: diameter * 0.5, y: -diameter * 0.38)
            }
        }
        .position(x: centre.x, y: centre.y)
        // Idle motion stays inside the resting strip in compact, like BotPlacement's compact bot;
        // the panel keeps its full height.
        .mask(alignment: .topLeading) {
            Rectangle().frame(width: state.mode == .expanded ? max(islandW, IslandConst.expandedWidth) : islandW,
                              height: state.mode == .expanded ? AssistantMetrics.maxHeight : islandH)
        }
        .opacity(visible ? 1 : 0)
        .animation(.easeInOut(duration: 0.2), value: visible)
        .animation(Self.travel, value: inPanel)
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
