import SwiftUI

/// One workspace pill in the harness's right card — a 2×2 grid cell about 145 × 32 pt.
///
/// Ported from the prototype's `.pill` rules (`design/prototype/harness-main-voice.html:134-142`):
/// a capsule tinted by the workspace colour (background at 13 %, border at 32 %), the
/// mini Mochi on the left with a spinning ring while its agent works, the workspace name
/// over the line that says what it is doing, and a focused state drawn as a full-colour
/// 1 pt ring plus a soft glow in the same colour.
struct HarnessWorkspacePill: View {
    let workspace: VoiceHarnessModel.Workspace
    let isFocused: Bool
    /// Stops the working ring's timeline while the island is hidden or another view has the floor.
    let isPaused: Bool
    let onTap: () -> Void

    @State private var isHovering = false

    init(workspace: VoiceHarnessModel.Workspace,
         isFocused: Bool,
         isPaused: Bool = false,
         onTap: @escaping () -> Void) {
        self.workspace = workspace
        self.isFocused = isFocused
        self.isPaused = isPaused
        self.onTap = onTap
    }

    /// The few compact measurements `HarnessMetrics` does not carry. Each one is either
    /// the prototype's own value (cited) or derived from a `HarnessMetrics` constant.
    private enum Metrics {
        /// `HarnessMetrics.miniMochi` plus the prototype's `.pring{inset:-3px}`.
        static let ringDiameter = HarnessMetrics.miniMochi + 6
        /// Prototype `.pring{border:2px solid}`.
        static let ringWidth: CGFloat = 2
        /// Prototype `.pill{padding:0 12px 0 6px}` — the leading side.
        static let mochiLead: CGFloat = 6
        /// Prototype `.pill{gap:10px}`, tightened for the compact grid cell.
        static let textGap: CGFloat = 6
        /// Prototype `.pill{padding:0 12px 0 6px}` — the trailing side.
        static let trailingPad: CGFloat = 8
        /// Prototype `.pill.focused{box-shadow:0 0 0 1px var(--c)}`.
        static let focusRingWidth: CGFloat = 1
        /// Prototype `.pill:hover{transform:translateY(-1px)}`.
        static let hoverLift: CGFloat = -1
        /// The 13 % tint asked for by the harness spec (prototype `tintBg`).
        static let fillOpacity: Double = 0.13
        /// The 32 % border asked for by the harness spec (prototype `tintBd`).
        static let borderOpacity: Double = 0.32
        /// The focused glow, softened from the prototype's `0 0 20px -6px`.
        static let glowOpacity: Double = 0.55
        /// Prototype `.pill:hover{filter:brightness(1.12)}`.
        static let hoverBrightness: Double = 0.12
        /// The spec's 10 pt line under the workspace name.
        static let subtitleSize: CGFloat = 10
    }

    private var tint: Color { Color(hex: workspace.color) }

    /// What the workspace is doing: its current tool step, else the folder it runs in,
    /// else its state name. Never empty, so the two-line cell never collapses.
    private var subtitle: String {
        if let tool = workspace.tool, !tool.isEmpty { return tool }
        if let folder = workspace.folder, !folder.isEmpty {
            let name = (folder as NSString).lastPathComponent
            if !name.isEmpty { return name }
        }
        return workspace.state.rawValue
    }

    var body: some View {
        HStack(spacing: 0) {
            mochiColumn
            VStack(alignment: .leading, spacing: 0) {
                Text(workspace.name)
                    .font(.system(size: HarnessMetrics.agentNameSize, weight: .medium))
                    .foregroundColor(Color(hex: "#F5F6F8"))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(subtitle)
                    .font(.system(size: Metrics.subtitleSize))
                    .foregroundColor(Color(hex: "#6B7079"))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.leading, Metrics.textGap)
            Spacer(minLength: 0)
        }
        .padding(.trailing, Metrics.trailingPad)
        .frame(height: HarnessMetrics.pillHeight, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
        .overlay(border)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onHover { isHovering = $0 }
        .offset(y: isHovering ? Metrics.hoverLift : 0)
        .brightness(isHovering ? Metrics.hoverBrightness : 0)
        .animation(HarnessMotion.springFast, value: isFocused)
        .animation(HarnessMotion.springFast, value: isHovering)
    }

    // MARK: - Mochi

    /// The workspace's Mochi, or a plain coloured dot while it has no session yet
    /// (`MiniBotCanvasView` draws nothing sensible without a task).
    ///
    /// The canvas carries its own `TimelineView(.animation)` and has no pause API, so it is
    /// swapped for the dot whenever this instance does not hold the floor — the pill's own ring
    /// takes `isPaused` directly, this keeps the 60 Hz canvas inside it honest too. Nothing is
    /// visible while paused: the roster only ever shows the live harness instance.
    @ViewBuilder
    private var mochi: some View {
        if let task = workspace.task, !isPaused {
            MiniBotCanvasView(task: task)
        } else {
            Circle().fill(tint)
        }
    }

    private var mochiColumn: some View {
        mochi
            .frame(width: HarnessMetrics.miniMochi, height: HarnessMetrics.miniMochi)
            .overlay {
                if workspace.isWorking {
                    workingRing
                        .frame(width: Metrics.ringDiameter, height: Metrics.ringDiameter)
                }
            }
            .padding(.leading, Metrics.mochiLead)
    }

    /// The prototype's `border-top-color` trick, scaled to the compact pill: a dim
    /// three-quarter ring with the leading quarter brightest and glowing, spun once per
    /// `HarnessMotion.pillRingSpin` (the prototype's `spin .9s linear infinite`).
    private var workingRing: some View {
        TimelineView(.animation(paused: isPaused)) { timeline in
            let period = HarnessMotion.pillRingSpin
            let phase = timeline.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: period) / period
            ZStack {
                Circle()
                    .trim(from: 0, to: 0.75)
                    .stroke(Color(hex: "#3B9EFF").opacity(0.25),
                            style: StrokeStyle(lineWidth: Metrics.ringWidth, lineCap: .round))
                Circle()
                    .trim(from: 0, to: 0.25)
                    .stroke(Color(hex: "#3B9EFF"),
                            style: StrokeStyle(lineWidth: Metrics.ringWidth, lineCap: .round))
                    .shadow(color: Color(hex: "#3B9EFF").opacity(0.75), radius: Metrics.ringWidth)
            }
            // `.trim` starts at 3 o'clock; −90 puts the bright arc at the top.
            .rotationEffect(.degrees(-90 + phase * 360))
        }
    }

    // MARK: - Chrome

    private var background: some View {
        RoundedRectangle(cornerRadius: HarnessMetrics.pillCorner, style: .continuous)
            .fill(tint.opacity(Metrics.fillOpacity))
            .shadow(color: tint.opacity(isFocused ? Metrics.glowOpacity : 0),
                    radius: HarnessMetrics.pillCorner / 2)
    }

    private var border: some View {
        RoundedRectangle(cornerRadius: HarnessMetrics.pillCorner, style: .continuous)
            .strokeBorder(tint.opacity(isFocused ? 1 : Metrics.borderOpacity),
                          lineWidth: Metrics.focusRingWidth)
    }
}
