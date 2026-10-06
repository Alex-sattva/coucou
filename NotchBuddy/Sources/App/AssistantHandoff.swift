import SwiftUI

// The particle hand-off, drawn: the flight + burst overlay, the anchors it reads, the panel wash and
// the blur-swap of the panel text. Timing and decisions are pure and live in
// AssistantHandoffLogic.swift (tested); the model (`AssistantModel`) starts and ends the flight.

// MARK: - Anchors

/// Where things are, in the island's coordinate space: one anchor per strip slot and one for the
/// main Mochi. Slots are keyed by index (a slot never moves), the main Mochi has one reserved key.
struct AssistantAnchorKey: PreferenceKey {
    static let main = "main"
    static func slot(_ index: Int) -> String { "slot.\(index)" }

    static let defaultValue: [String: Anchor<CGRect>] = [:]

    static func reduce(value: inout [String: Anchor<CGRect>],
                       nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    /// Publishes this view's bounds under `key` (apply BEFORE `.position`, so the rect is the view's own).
    func assistantAnchor(_ key: String) -> some View {
        anchorPreference(key: AssistantAnchorKey.self, value: .bounds) { [key: $0] }
    }

    /// Draws the hand-off flight above this view. Nothing is mounted while `flight` is nil, so no
    /// timeline runs when idle.
    func assistantHandoffOverlay(flight: AssistantFlight?) -> some View {
        overlayPreferenceValue(AssistantAnchorKey.self) { anchors in
            GeometryReader { proxy in
                if let flight,
                   let from = anchors[AssistantAnchorKey.slot(flight.fromSlot)],
                   let to = anchors[AssistantAnchorKey.main] {
                    AssistantFlightView(from: proxy[from], to: proxy[to], hex: flight.hex, start: flight.start)
                        .id(flight.token)
                }
            }
            .allowsHitTesting(false)
        }
    }
}

// MARK: - Flight

/// Over `HandoffTimeline.duration` a dot leaves the slot and flies to the main Mochi (cubic
/// ease-out, 9 -> 4 pt, fading halo), then bursts into 14 shards out to radius 26.
/// `from` / `to` are resolved live from the anchors, so the dot follows a Mochi that is still moving.
struct AssistantFlightView: View {
    let from: CGRect
    let to: CGRect
    let hex: String
    let start: Double

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
            Canvas { context, _ in
                let elapsed = timeline.date.timeIntervalSinceReferenceDate - start
                let tint = Color(hex: hex)
                let target = CGPoint(x: to.midX, y: to.midY)
                switch HandoffTimeline.frame(elapsed: elapsed) {
                case .finished:
                    return
                case .travel(let eased, let diameter, let halo):
                    let e = CGFloat(eased)
                    let point = CGPoint(x: from.midX + (target.x - from.midX) * e,
                                        y: from.midY + (target.y - from.midY) * e)
                    let d = CGFloat(diameter)
                    let rect = CGRect(x: point.x - d / 2, y: point.y - d / 2, width: d, height: d)
                    context.fill(Path(ellipseIn: rect), with: .color(tint))
                    context.fill(Path(ellipseIn: rect.insetBy(dx: -2, dy: -2)), with: .color(tint.opacity(halo)))
                case .burst(let radius, let opacity):
                    let s = CGFloat(HandoffTimeline.shardDiameter)
                    for index in 0..<HandoffTimeline.burstDots {
                        let angle = Double(index) / Double(HandoffTimeline.burstDots) * 2 * .pi
                        let x = target.x + CGFloat(cos(angle) * radius)
                        let y = target.y + CGFloat(sin(angle) * radius)
                        context.fill(Path(ellipseIn: CGRect(x: x - s / 2, y: y - s / 2, width: s, height: s)),
                                     with: .color(tint.opacity(opacity)))
                    }
                }
            }
        }
    }
}

// MARK: - Wash

/// `radial-gradient(70% 120% at 40px 64px, colour .34, transparent 70%)` behind the panel
/// (prototype `.wash`), centred on the main Mochi. The colour changes over 0.6 s.
struct AssistantWash: View {
    let hex: String

    static let opacity = 0.34
    static let widthFraction: CGFloat = 0.7
    static let heightFraction: CGFloat = 1.2
    static let fadeStop: CGFloat = 0.7
    static let colorDuration = 0.6

    var body: some View {
        GeometryReader { geo in
            Color(hex: hex).opacity(Self.opacity)
                .mask {
                    // A 200 pt circle whose gradient ends at radius 100, stretched to the ellipse.
                    Circle()
                        .fill(RadialGradient(stops: [.init(color: .black, location: 0),
                                                     .init(color: .clear, location: Self.fadeStop)],
                                             center: .center, startRadius: 0, endRadius: 100))
                        .frame(width: 200, height: 200)
                        .scaleEffect(x: geo.size.width * Self.widthFraction / 100,
                                     y: geo.size.height * Self.heightFraction / 100)
                        .position(x: AssistantPanelLayout.mochiCentre.x, y: AssistantPanelLayout.mochiCentre.y)
                }
                .animation(.easeInOut(duration: Self.colorDuration), value: hex)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Blur swap

/// The panel's task line and need card swap with the agent: opacity 0 + blur 8 + scale 0.97, back to
/// normal over `HarnessMotion.agentSwapDuration`. The new content is already in place; it fades in.
/// Reduce Motion: a short fade only.
struct AgentSwapModifier: ViewModifier {
    let key: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hidden = false

    func body(content: Content) -> some View {
        content
            .opacity(hidden ? 0 : 1)
            .blur(radius: hidden && !reduceMotion ? HarnessMotion.agentSwapBlur : 0)
            .scaleEffect(hidden && !reduceMotion ? HarnessMotion.agentSwapScale : 1)
            .onChange(of: key) { _, _ in
                var instant = Transaction()
                instant.disablesAnimations = true
                withTransaction(instant) { hidden = true }
                let duration = reduceMotion ? 0.15 : HarnessMotion.agentSwapDuration
                DispatchQueue.main.async {
                    withAnimation(.easeInOut(duration: duration)) { hidden = false }
                }
            }
    }
}

extension View {
    /// Blur-swaps this view whenever `key` (the main agent's id) changes.
    func agentSwap(key: String?) -> some View { modifier(AgentSwapModifier(key: key)) }
}
