import SwiftUI

/// Sub slots of the quiet strip, right of the camera: up to 5 small Mochis, then "+N".
/// Slots are keyed by position, not by agent: a slot never moves, and when its agent changes
/// the same view just recolours (the Step 8 hand-off relies on this).
struct AssistantStrip: View {
    @ObservedObject var model: AssistantModel
    let geometry: AssistantStripGeometry
    /// True when the island is not showing the strip (hidden, expanded): timelines stop.
    let isPaused: Bool
    let onSelect: (String) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let subs = model.displaySubs   // a slot in a hand-off still shows its old occupant
        let shown = min(subs.count, AssistantStripGeometry.maxVisibleSubs)
        let d = geometry.subDiameter
        let canvas = d / 0.6

        ZStack(alignment: .topLeading) {
            ForEach(0..<shown, id: \.self) { i in
                let s = subs[i]
                ZStack {
                    AssistantSlotMochi(hex: s.colorHex, state: s.phase.mochiState.botState,
                                       canvasSize: canvas, isPaused: isPaused,
                                       blendRate: reduceMotion ? HandoffPlanner.reducedMotionBlendRate : HandoffPlanner.quickBlendRate)
                    if let dot = s.statusDotHex {
                        AssistantStatusDot(hex: dot, size: 5.5)
                            .offset(x: d * 0.5, y: -d * 0.4)
                    }
                }
                .frame(width: AssistantStripGeometry.subSpacing, height: geometry.islandHeight)
                .assistantAnchor(AssistantAnchorKey.slot(i))
                .contentShape(Rectangle())
                .onTapGesture { onSelect(s.id) }
                .help("\(s.workspace)")
                .position(x: geometry.subCentreX(i), y: geometry.centreY)
                .transition(.opacity)
            }
            if subs.count > shown {
                Text("+\(subs.count - shown)")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundColor(Color.white.opacity(0.55))
                    .position(x: geometry.subCentreX(shown), y: geometry.centreY)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: shown)
        .animation(.easeInOut(duration: 0.2), value: subs.count > shown)
    }
}
