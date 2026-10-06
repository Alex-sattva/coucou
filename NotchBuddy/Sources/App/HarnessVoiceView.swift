import SwiftUI

// MARK: - Voice harness (the island's home surface)

/// The voice harness — the island's default surface.
///
/// Visual source of truth: `design/prototype/harness-main-voice.html`. The prototype is
/// 912 × 352 with a 404 pt left card; the shipping home island is 640 × 160 and a non-tall
/// view is given a hard 98 pt content box (`IslandRootView.swift:446`). Window geometry is
/// contract (CLAUDE.md), so this keeps the prototype's *language* — big Mochi on the left
/// with the agent line, tool trail and voice bar, a 2×2 grid of mini-Mochi workspaces on the
/// right — at `HarnessMetrics`' compressed measurements. Every curve and duration comes from
/// `HarnessMotion`; nothing here invents its own spring.
struct HarnessVoiceView: View {
    @ObservedObject var state: AppState
    /// The case this instance renders. `IslandRootView` keeps ONE body per `IslandView` case
    /// alive simultaneously, so `overview` and `approval` each mount a harness; without this
    /// the instance that is *not* on screen would still believe it is live and keep every
    /// timeline ticking behind `opacity(0)`.
    let view: IslandView
    @StateObject private var model = VoiceHarnessModel.shared
    @State private var flight: Flight?
    /// The diff step whose card is open, opened by ⌘E or by the origin view's diff tap.
    /// `OverviewView` owned this before the harness took the home surface; if the harness
    /// did not adopt it, ⌘E — which still ships — would publish `.islandToggleDiff` into a
    /// notification nobody observes, i.e. a dead shortcut.
    @State private var activeDiffId: Int?
    /// The `IntegrationCardView`'s own `showingDetail` flag. It does NOT mean "the card is
    /// open" — it is the card's internal expansion of its activity section. Keeping the two
    /// apart matters: the card's own "Show details" buttons write this binding, and if it also
    /// gated presentation the card would vanish the moment it was asked to expand.
    @State private var showingIntegrationDetail = false
    /// Whether the focused pill's shipped `IntegrationCardView` is presented. The old home
    /// rendered it automatically for an integration task, in the left card (`OverviewView` at
    /// HEAD); the harness's left card is shared with the composer, the trail and the riser, so
    /// it opens on demand from the agent card's expand button — in the left card, where the
    /// origin view had it, which leaves the roster live so tapping another workspace is the
    /// natural way out. Without this the ~480-line integration panel would be unreachable.
    @State private var integrationCardOpen = false

    /// The pill-flight overlay: a clone dot leaves the tapped workspace pill, lands on the
    /// big Mochi, and bursts into `HarnessMotion.pillBurstDots` shards.
    private struct Flight: Equatable {
        let pillId: String
        let color: String
        /// `Date.timeIntervalSinceReferenceDate` — the same base `TimelineView` reports, NOT
        /// `CACurrentMediaTime()` (mixing the two is a pre-existing bug in `BotCanvasView`).
        let start: Double
    }

    /// True only while THIS instance is the one on screen. Every harness animation hangs off
    /// it so the island costs 0 % CPU while hidden (CLAUDE.md) and while another view — or the
    /// other harness case — has the floor: an `opacity(0)` view left animating is invisible
    /// waste. `approval` and `overview` share this body, so the match is on `state.view ==
    /// view`, not on `state.view.isHarnessSurface`.
    private var isLive: Bool { state.mode == .expanded && state.view == view }

    var body: some View {
        HStack(alignment: .top, spacing: HarnessMetrics.cardGap) {
            leftCard
            rightCard
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // The diff card / plan detail are attached to the root so they are not clipped by the
        // left card; the integration panel is attached to the left card itself.
        .overlay { detailOverlay }
        .overlay(alignment: .topTrailing) {
            if isLive, model.isThreadPopupOpen, !model.hasRiser {
                ThreadHistoryPopup(rows: model.threadRows(),
                                   title: model.currentThreadTitle ?? "",
                                   onRewind: { thread in model.rewind(thread) },
                                   onClose: { model.closeThreads() })
            }
        }
        .overlayPreferenceValue(HarnessAnchorKey.self) { anchors in
            GeometryReader { proxy in
                if isLive,
                   let flight,
                   let from = anchors[flight.pillId],
                   let to = anchors[HarnessAnchorKey.mochi] {
                    HarnessPillFlightView(from: proxy[from],
                                          to: proxy[to],
                                          color: flight.color,
                                          start: flight.start)
                }
            }
            .allowsHitTesting(false)
        }
        .onAppear { model.refresh() }
        .onChange(of: state.tasks) { _, _ in model.refresh() }
        .onChange(of: model.hasRiser) { _, isUp in
            // The thread list fills the surface, so it would hide the one strip that can
            // answer a waiting permission. Close it rather than leave it invisibly open.
            if isUp { model.closeThreads() }
        }
        .onChange(of: state.mode) { _, mode in
            // Transient detail: it does not survive the island closing.
            if mode != .expanded { resetTransientDetail() }
            // Kept from the origin view: expanding with the GitHub pill focused refreshes it.
            if mode == .expanded, model.focusedId == "integration_github" {
                GithubPoller.shared.refreshIfStale()
            }
        }
        .onChange(of: state.view) { _, newView in
            // Per instance: each mounted harness clears only when the floor moved AWAY from its
            // own case. The origin view did this too; without it, leaving the home while still
            // expanded left `showingPlanDetail` true, and `BotCanvasView` reads that
            // view-independently — the ship bot kept the plan-gauge tint on every other surface
            // and the plan card reopened on return.
            guard newView != view else { return }
            resetTransientDetail()
        }
        .onChange(of: model.focusedId) { _, id in
            // Transient detail belongs to the workspace it was opened for.
            resetTransientDetail()
            // Kept from the origin view: focusing the GitHub pill refreshes its poller.
            if id == "integration_github" { GithubPoller.shared.refreshIfStale() }
        }
        // The shipping keyboard routes — ⌘←/⌘→, ⌘1–9, `cyclePill(by:)` — move `AppState.focusId`
        // without going through the model, and the model now mirrors its own focus into
        // `AppState` too. Watching it as well is what stops a card opened for one task from
        // surviving a focus change to another, whichever route moved the focus.
        .onChange(of: state.focusId) { _, id in
            resetTransientDetail()
            // …and follow the focus itself. The shipping routes (⌘←/⌘→, ⌘1–9, ⌃⌥] / ⌃⌥[,
            // `cyclePill`, the Settings picker) write `AppState.focusId` and nothing else, so
            // without this the card — and therefore the next run's `cwd` and the trail shown —
            // would stay on the previous workspace while the pill, the ship bot and the app's
            // own idea of the focus all moved on.
            if let id, id != model.focusedId, model.workspaces.contains(where: { $0.id == id }) {
                model.focus(id)
            }
            if id == "integration_github" { GithubPoller.shared.refreshIfStale() }
        }
        // ⌘E — the shipping shortcut to the focused task's newest diff, unchanged.
        .onReceive(NotificationCenter.default.publisher(for: .islandToggleDiff)) { _ in
            // Nothing to toggle while the harness is off the floor, or while a permission's riser
            // has the surface (it is the only way to answer, so it outranks any detail card).
            guard isLive, !model.hasRiser else { return }
            if activeDiffId != nil {
                withAnimation(HarnessMotion.detailSwap) { activeDiffId = nil }
            } else if let task = model.focused?.task,
                      let last = state.sessionDiffs[task.id]?.last {
                withAnimation(HarnessMotion.detailSwap) { activeDiffId = last.id }
            }
        }
    }

    /// Drops every transient detail the surface can be showing: the diff card, the integration
    /// panel and the plan card. Called whenever the floor moves, the island collapses or the
    /// focused workspace changes — the origin view reset exactly these on the same three events.
    private func resetTransientDetail() {
        activeDiffId = nil
        closeIntegrationCard()
        #if !APPSTORE
        state.showingPlanDetail = false
        #endif
    }

    /// Closes the integration panel and forgets the card's own inner "activity expanded" flag, so
    /// reopening it always starts from the collapsed state instead of resuming a stale expansion.
    private func closeIntegrationCard() {
        integrationCardOpen = false
        showingIntegrationDetail = false
    }

    /// The focused workspace's diff for `activeDiffId`, if it is still in the session log.
    private var activeDiff: FileDiff? {
        guard let id = activeDiffId, let task = model.focused?.task else { return nil }
        return state.sessionDiffs[task.id]?.first { $0.id == id }
    }

    /// True while something else is drawn over the bar and must own the keyboard: a detail card,
    /// the thread popup (a second full-surface opaque card), or the harness being off the floor.
    /// A permission's riser is NOT one of these — it sits *in* the card, above the composer, and
    /// is the only way to answer, so it must leave the bar usable.
    private var composerObscured: Bool {
        guard isLive else { return true }
        guard !model.hasRiser else { return false }
        return model.isThreadPopupOpen || activeDiff != nil || planDetailOpen
            || (integrationCardOpen && integrationTask != nil)
    }

    /// The located workspace's shipped integration panel, if the focused pill is one.
    private var integrationTask: AgentTask? {
        guard let task = model.focused?.task, task.isIntegration else { return nil }
        return task
    }

    /// `#if !APPSTORE`-gated because the plan gauge is not part of the App Store build.
    private var planDetailOpen: Bool {
        #if !APPSTORE
        return state.showingPlanDetail
        #else
        return false
        #endif
    }

    /// The surface-covering detail cards, in priority order: a diff (⌘E or an integration
    /// card's step tap), then the plan gauge. The cards themselves are the shipping ones, drawn
    /// with their own plate and unmodified — only their placement differs from the origin view,
    /// which laid them inside the card's slot area: each is ~100 pt tall and that slot is ~30 pt
    /// here, so a slot-sized detail card would be unreadable. A waiting permission outranks them
    /// — the riser is the only way to answer, so nothing may cover it.
    @ViewBuilder
    private var detailOverlay: some View {
        if isLive, !model.hasRiser {
            if let diff = activeDiff {
                CardBackground(wash: nil)
                DiffCardView(diff: diff, onDismiss: { activeDiffId = nil })
                    .transition(.opacity)
            } else if planDetailOpen {
                CardBackground(wash: nil)
                ClaudePlanCardView(usage: state.claudePlanUsage)
                    .transition(.opacity)
            }
        }
    }

    /// The focused pill's shipped integration panel, in the left card where the origin view
    /// put it — so the roster stays live and tapping another workspace is a natural way out.
    /// It needs an explicit dismiss: unlike the diff card (its chevron) and the plan card (the
    /// header pill toggles it), `IntegrationCardView` never closes itself.
    @ViewBuilder
    private var integrationDetailCard: some View {
        if isLive, !model.hasRiser, integrationCardOpen, let task = integrationTask {
            // The plate is load-bearing. `IntegrationCardView` paints no background of its own —
            // no `CardBackground`, no fill, in any of its branches — so overlaying it directly
            // let the live agent row, trail and composer render THROUGH its text. The origin
            // view stacked the same plate under this same card.
            ZStack(alignment: .topLeading) {
                CardBackground(wash: nil)
                IntegrationCardView(task: task,
                                    showingDetail: $showingIntegrationDetail,
                                    onDiffTap: { diffId in
                                        closeIntegrationCard()
                                        withAnimation(HarnessMotion.detailSwap) { activeDiffId = diffId }
                                    })
                    .onExitCommand { closeIntegrationCard() }
            }
            .transition(.opacity)
        }
    }

    // MARK: - Left card (big Mochi · agent line · trail · voice bar)

    private var focusedColor: String {
        model.focused?.color ?? VoiceHarnessModel.mainColor
    }

    private var leftCard: some View {
        VStack(alignment: .leading, spacing: 3) {
            agentRow
            slot
            VoiceBarView(model: model,
                         focusedHex: focusedColor,
                         isRiserUp: model.hasRiser,
                         isPaused: !isLive,
                         isObscured: composerObscured,
                         onSubmit: { Task { await model.submit() } })
        }
        .padding(HarnessMetrics.cardPadding)
        .frame(width: HarnessMetrics.leftCardWidth, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(CardSurface(washHex: focusedColor, corner: HarnessMetrics.cardCorner))
        // The overlay comes before the clip so the integration panel cannot spill past the
        // card's rounded corners.
        .overlay { integrationDetailCard }
        .clipShape(RoundedRectangle(cornerRadius: HarnessMetrics.cardCorner, style: .continuous))
    }

    private var agentRow: some View {
        HStack(spacing: 6) {
            HarnessMochiView(hex: focusedColor,
                             state: model.mochiState,
                             diameter: HarnessMetrics.bigMochi,
                             hopToken: model.hopToken,
                             isPaused: !isLive)
                .frame(width: HarnessMetrics.mochiColumnWidth, height: HarnessMetrics.agentLineHeight)
                .anchorPreference(key: HarnessAnchorKey.self, value: .bounds) {
                    [HarnessAnchorKey.mochi: $0]
                }

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(Color(hex: focusedColor))
                        .frame(width: 7, height: 7)
                        .shadow(color: Color(hex: focusedColor).opacity(0.7), radius: 4)
                    Text(model.focused?.name ?? VoiceHarnessModel.mainName)
                        .font(.system(size: HarnessMetrics.agentNameSize, weight: .semibold))
                        .foregroundColor(Color(hex: "#F5F6F8"))
                        .lineLimit(1)
                    Text(model.focused?.tool ?? (model.isMainFocused ? "orchestrator" : "idle"))
                        .font(.system(size: HarnessMetrics.agentToolSize))
                        .foregroundColor(Color(hex: "#8E939C"))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                HStack(spacing: 6) {
                    Text(stepCounter)
                        .font(.system(size: HarnessMetrics.agentToolSize, design: .monospaced))
                        .foregroundColor(Color(hex: "#6B7079"))
                    Spacer(minLength: 0)
                    if integrationTask != nil {
                        iconButton("arrow.up.left.and.arrow.down.right",
                                   active: integrationCardOpen,
                                   dashed: false) {
                            withAnimation(HarnessMotion.detailSwap) {
                                if integrationCardOpen {
                                    closeIntegrationCard()
                                } else {
                                    integrationCardOpen = true
                                }
                            }
                        }
                        .help("Show this integration's card · Esc to close")
                    }
                    iconButton("clock", active: model.isThreadPopupOpen) { model.toggleThreads() }
                    iconButton("plus", dashed: model.canStartNewSession) { model.startNewSession() }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: HarnessMetrics.agentLineHeight)
    }

    private var stepCounter: String {
        guard let workspace = model.focused, !workspace.isMain, workspace.stepCount > 0 else {
            return model.isMainFocused ? "main" : "—"
        }
        return "\(min(workspace.stepIndex + 1, workspace.stepCount))/\(workspace.stepCount)"
    }

    /// The agent card's controls: the integration expand, clock and plus. The prototype puts
    /// them on the agent card, not in the shared `IslandHeader` — which is shipping chrome
    /// (`IslandRootView.swift:465`) and is therefore left exactly as it ships.
    private func iconButton(_ symbol: String, active: Bool = false, dashed: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(active ? Color(hex: "#F5F6F8") : Color(hex: "#8E939C"))
                .frame(width: 16, height: 16)
                .background(
                    Circle().fill(active ? Color.white.opacity(0.12) : Color.clear)
                )
                .overlay(
                    Circle().stroke(Color.white.opacity(dashed ? 0.18 : 0.10),
                                    style: StrokeStyle(lineWidth: 1, dash: dashed ? [2, 2] : []))
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    /// The ticker's slot. One slot, three occupants — the riser wins while an agent is blocked,
    /// then the done summary, then the live tool trail. At 98 pt the card cannot hold a riser
    /// and a trail at once, so the riser genuinely replaces the trail (the prototype's
    /// `.slot.done` / `.riser-on` swaps) rather than stacking.
    private var slot: some View {
        Group {
            if model.hasRiser {
                HarnessRiserStrip(model: model)
                    .transition(.opacity)
            } else if model.showsSummary, let summary = model.lastSummary, let workspace = model.focused ?? model.target {
                SessionSummaryView(title: "\(workspace.name) · done",
                                   text: summary,
                                   when: "now",
                                   accentHex: workspace.color)
                    .transition(.opacity)
            } else {
                HarnessTickerView(lines: model.tickerLines, isPaused: !isLive)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .clipped()
        .animation(HarnessMotion.riserOpacity, value: model.hasRiser)
        .animation(HarnessMotion.summaryIn, value: model.showsSummary)
    }

    // MARK: - Right card (2×2 workspace pills + Main lurker)

    private var rightCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("WORKSPACES")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.8)
                    .foregroundColor(Color(hex: "#6B7079"))
                Spacer(minLength: 0)
                mainChip
            }
            .frame(height: HarnessMetrics.pillsHeaderHeight)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: HarnessMetrics.pillGap),
                                GridItem(.flexible(), spacing: HarnessMetrics.pillGap)],
                      spacing: HarnessMetrics.pillGap) {
                ForEach(model.realWorkspaces.prefix(4)) { workspace in
                    HarnessWorkspacePill(workspace: workspace,
                                         isFocused: workspace.id == model.focusedId,
                                         isPaused: !isLive) {
                        tapPill(workspace)
                    }
                    .anchorPreference(key: HarnessAnchorKey.self, value: .bounds) {
                        [workspace.id: $0]
                    }
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 5) {
                Circle()
                    .fill(Color(hex: "#3B9EFF"))
                    .frame(width: 6, height: 6)
                    .opacity(model.realWorkspaces.contains(where: \.isWorking) ? 1 : 0.35)
                Text(model.rosterFooter)
                    .font(.system(size: 8.5))
                    .foregroundColor(Color(hex: "#6B7079"))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(height: HarnessMetrics.pillsFooterHeight)
        }
        .padding(HarnessMetrics.cardPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(CardSurface(washHex: nil, corner: HarnessMetrics.cardCorner))
        .clipShape(RoundedRectangle(cornerRadius: HarnessMetrics.cardCorner, style: .continuous))
    }

    /// The Main lurker. Tapping it gives Main the floor; tapping again while Main has the floor
    /// hands the floor back to the workspace last spoken to.
    private var mainChip: some View {
        Button {
            if model.isMainFocused {
                model.returnFromMain()
            } else {
                model.focus(VoiceHarnessModel.mainId)
            }
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(Color(hex: VoiceHarnessModel.mainColor))
                    .frame(width: 5, height: 5)
                Text(VoiceHarnessModel.mainName)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(model.isMainFocused ? Color(hex: "#0B0C0E") : Color(hex: "#8E939C"))
            }
            .padding(.horizontal, 7)
            .frame(height: HarnessMetrics.pillsHeaderHeight - 2)
            .background(
                Capsule().fill(model.isMainFocused
                               ? Color(hex: VoiceHarnessModel.mainColor)
                               : Color.white.opacity(0.05))
            )
            .overlay(
                Capsule().stroke(Color(hex: VoiceHarnessModel.mainColor).opacity(model.isMainFocused ? 0 : 0.28),
                                 lineWidth: 1)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Main routes to a workspace — tap a small Mochi first.")
    }

    // MARK: - Actions

    private func tapPill(_ workspace: VoiceHarnessModel.Workspace) {
        let started = Date().timeIntervalSinceReferenceDate
        flight = Flight(pillId: workspace.id, color: workspace.color, start: started)
        model.focus(workspace.id)
        // Retire the flight once it has played out. The overlay's `TimelineView` would
        // otherwise keep re-evaluating at 60 Hz for the rest of the expanded session (its
        // Canvas already early-returns past the duration, so the ticks are pure waste).
        // Compare `start`, not `pillId`: re-tapping the SAME pill inside the flight window
        // would otherwise let the older timer retire the newer flight.
        DispatchQueue.main.asyncAfter(deadline: .now() + HarnessMotion.pillFlightDuration + 0.05) {
            if flight?.start == started { flight = nil }
        }
    }
}

// MARK: - Card surface

/// The harness's own card background: the prototype's `.card` fill plus the `.card.left::before`
/// radial wash in the focused workspace's colour. Deliberately not `CardBackground`, whose
/// `Wash` is a fixed enum (`IslandViewContent.swift:4318`) with no arbitrary-hex arm — adding
/// one would touch a shipping type for the harness's benefit.
private struct CardSurface: View {
    let washHex: String?
    let corner: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: corner, style: .continuous)
            .fill(Color(hex: "#141518"))
            .overlay {
                if let washHex {
                    RadialGradient(colors: [Color(hex: washHex).opacity(HarnessMotion.washOpacity), .clear],
                                   center: UnitPoint(x: HarnessMotion.washCenterX, y: HarnessMotion.washCenterY),
                                   startRadius: 0,
                                   endRadius: 240 * HarnessMotion.washRadiusFraction)
                        .animation(HarnessMotion.wash, value: washHex)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
            )
    }
}

// MARK: - Anchor plumbing for the pill flight

private struct HarnessAnchorKey: PreferenceKey {
    /// The big Mochi's reserved anchor slot — no pill id can collide with it.
    static let mochi = "\u{0}mochi"

    static let defaultValue: [String: Anchor<CGRect>] = [:]

    static func reduce(value: inout [String: Anchor<CGRect>],
                       nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { _, new in new }
    }
}

// MARK: - Pill flight

/// `pillFlight` from the motion contract: over `HarnessMotion.pillFlightDuration` the clone dot
/// travels from the pill to the Mochi, then bursts into `pillBurstDots` shards out to
/// `pillBurstRadius`. Drawn in the harness's own coordinate space, so both anchors are used
/// as resolved by the enclosing `GeometryReader`.
private struct HarnessPillFlightView: View {
    let from: CGRect
    let to: CGRect
    let color: String
    let start: Double

    /// Fraction of the flight spent travelling; the remainder is the burst.
    private static let travel: Double = 0.62

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
            Canvas { context, _ in
                let progress = (timeline.date.timeIntervalSinceReferenceDate - start) / HarnessMotion.pillFlightDuration
                guard progress >= 0, progress <= 1 else { return }
                let tint = Color(hex: color)

                let origin = CGPoint(x: from.midX, y: from.midY)
                let target = CGPoint(x: to.midX, y: to.midY)

                if progress < Self.travel {
                    let k = progress / Self.travel
                    let eased = 1 - pow(1 - k, 3)
                    let point = CGPoint(x: origin.x + (target.x - origin.x) * eased,
                                        y: origin.y + (target.y - origin.y) * eased)
                    let diameter = 9 - 5 * eased
                    let rect = CGRect(x: point.x - diameter / 2, y: point.y - diameter / 2,
                                      width: diameter, height: diameter)
                    context.fill(Path(ellipseIn: rect), with: .color(tint))
                    context.fill(Path(ellipseIn: rect.insetBy(dx: -2, dy: -2)),
                                 with: .color(tint.opacity(0.25 * (1 - eased))))
                } else {
                    let k = (progress - Self.travel) / (1 - Self.travel)
                    let radius = k * HarnessMotion.pillBurstRadius
                    for index in 0..<HarnessMotion.pillBurstDots {
                        let angle = Double(index) / Double(HarnessMotion.pillBurstDots) * 2 * .pi
                        let point = CGPoint(x: target.x + cos(angle) * radius,
                                            y: target.y + sin(angle) * radius)
                        let dot = CGRect(x: point.x - 1.6, y: point.y - 1.6, width: 3.2, height: 3.2)
                        context.fill(Path(ellipseIn: dot), with: .color(tint.opacity(1 - k)))
                    }
                }
            }
        }
    }
}
