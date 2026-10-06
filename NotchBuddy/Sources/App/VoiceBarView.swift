import AppKit
import SwiftUI

/// The voice bar — the composer at the foot of the harness's left card.
///
/// Visual source of truth: `design/prototype/harness-main-voice.html` — the `.vbar`,
/// `.cap`, `.vrow`, `.typein`, `.shint`, `.wave` and `.mic` rules (`:101-128`), their
/// markup (`:239-248`), and `growInput()` / the `keydown` listener / the mic toggle
/// (`:509-522`). The prototype draws at 912×352; this surface is 620×98
/// (`HarnessMetrics.contentHeight`), so the bar keeps the prototype's *language* and
/// takes every curve and every shared length from `HarnessMotion` / `HarnessMetrics`.
///
/// It is a channel, not a chat (`harness-main-voice.html:292`): it shows the agent's
/// state and the user's own words and never a transcript. The mic is push-to-talk with
/// no speech-to-text behind it — `VoiceHarnessModel.toggleListening()` carries the
/// `TODO(STT)` and this view never invents a transcript to draw.
@MainActor
struct VoiceBarView: View {

    // MARK: - Contract

    @ObservedObject var model: VoiceHarnessModel
    let focusedHex: String
    let isRiserUp: Bool
    /// False while the harness surface is off screen. Every `IslandView` body stays mounted
    /// inside `IslandRootView`, so without this a toggled-on mic would keep its waveform and
    /// ping timelines ticking behind `opacity(0)` — the 0 % CPU rule (CLAUDE.md).
    let isPaused: Bool
    /// True while a detail card covers the bar (a diff, the plan gauge, or a workspace's
    /// integration panel). Those cards are opaque, so without this the composer would keep
    /// focus behind one and quietly swallow keystrokes — including the Return that sends.
    let isObscured: Bool
    let onSubmit: () -> Void

    init(model: VoiceHarnessModel, focusedHex: String, isRiserUp: Bool,
         isPaused: Bool = false, isObscured: Bool = false, onSubmit: @escaping () -> Void) {
        self.model = model
        self.focusedHex = focusedHex
        self.isRiserUp = isRiserUp
        self.isPaused = isPaused
        self.isObscured = isObscured
        self.onSubmit = onSubmit
    }

    @FocusState private var isComposerFocused: Bool

    // MARK: - Bar chrome

    /// The bar's own measurements — the `.vbar` / `.vrow` rules. `HarnessMetrics` sizes
    /// the harness's shared layout and `HarnessMotion` owns its curves; what is left is
    /// this control's own geometry, named here beside the prototype line it comes from so
    /// the bar never carries a bare literal.
    private enum Bar {
        /// `.vbar{border-radius:15px}` — `HarnessMetrics.cardCorner` (20) is the card's.
        static let corner: CGFloat = 15
        /// The compact scale of `.vbar{padding:9px 10px 9px 12px}`: the card is 98 pt
        /// here, not 296, so the chrome is paid for out of `HarnessMetrics.cardPadding`.
        static let paddingTop: CGFloat = HarnessMetrics.cardPadding / 2
        static let paddingLeading: CGFloat = HarnessMetrics.cardPadding
        static let paddingBottom: CGFloat = HarnessMetrics.cardPadding / 2
        static let paddingTrailing: CGFloat = HarnessMetrics.cardPadding
        /// `.vbar{gap:10px}` while resting, `.vbar.typing{gap:7px}` once expanded.
        static let rowGap: CGFloat = 10
        static let columnGap: CGFloat = 7
        /// `.vrow{gap:8px}` — the controls beside the field.
        static let slotGap: CGFloat = 8
        /// `.vbar{background:rgba(255,255,255,.05)}`, `border:1px solid var(--line)`.
        static let restFill: Double = 0.05
        static let hairline: Double = 0.10
        static let hairlineWidth: CGFloat = 1
        /// `.typein{padding:3px 2px}` — the field's own inset inside its row.
        static let fieldInsetX: CGFloat = 2
        static let fieldInsetY: CGFloat = 3
        /// A `TextEditor`'s text container sits a few points inside its own frame; the
        /// greyed suggestion is drawn on the caret's origin, not the frame's.
        static let textOriginInset: CGFloat = 5
        /// `.cap small{margin-bottom:1px}`.
        static let captionGap: CGFloat = 1
        /// `.shint{padding:2px 8px}` — the `⇥ tab` chip.
        static let hintPaddingX: CGFloat = 8
        static let hintPaddingY: CGFloat = 2
    }

    /// `.vbar.live{border-color:rgba(236,72,153,.45);background:rgba(236,72,153,.07)}`
    private enum Live {
        static let hex = "#EC4899"
        static let border: Double = 0.45
        static let fill: Double = 0.07
    }

    /// The dark-only palette the surface pins (prototype `.mic`, `.cap`, `.typein` rules).
    private enum Ink {
        static let primary = "#F5F6F8"
        static let secondary = "#8E939C"
        static let dim = "#6B7079"
        /// `.vbar.has-suggest .typein::placeholder{color:#8A8F98;font-style:italic}`.
        static let suggest = "#8A8F98"
        /// `.mic.live{background:#FF5A4E}`.
        static let micLive = "#FF5A4E"
        static let error = "#F4505E"
        /// `@keyframes pp` opens on `rgba(255,90,78,.5)`.
        static let micPulse: Double = 0.5
        /// A quiet red disc behind the stop glyph — the error colour, one step down.
        static let stopFill: Double = 0.14
    }

    /// The waveform: `.wave` geometry and the `wv` stagger table. `HarnessMotion` has no
    /// wave period (it carries the harness's listening pulse instead), so the prototype's
    /// own `.7 s` and its `.1 /.2 /.32 s` delays are named here with their line.
    private enum Wave {
        static let bars = 9
        /// `.wave i{width:3px}`.
        static let width: CGFloat = 3
        /// `.wave{gap:2.5px;height:20px}`.
        static let gap: CGFloat = 2.5
        static let height: CGFloat = 20
        /// `@keyframes wv{0%,100%{height:4px}50%{height:18px}}` — the bar is drawn at its
        /// rest height and scaled to its peak, so the animation costs no layout pass.
        static let rest: CGFloat = 4
        static let peak: CGFloat = 18
        static let corner: CGFloat = 1.5
        /// `.wave i{opacity:.5}` / `.vbar.live .wave i{opacity:1}`.
        static let idleOpacity: Double = 0.5
        static let liveOpacity: Double = 1
        /// `.wave.live .wave i{animation:wv .7s ease-in-out infinite}`.
        static let period: Double = 0.7

        /// `.wave i:nth-child(2n){animation-delay:.1s}` and its `3n` / `4n` siblings.
        /// Equal-specificity CSS resolves in declaration order, so 4n wins over 3n, which
        /// wins over 2n. `index` is 0-based; `nth-child` is 1-based.
        static func stagger(for index: Int) -> Double {
            let child = index + 1
            if child % 4 == 0 { return 0.32 }
            if child % 3 == 0 { return 0.20 }
            if child % 2 == 0 { return 0.10 }
            return 0
        }
    }

    // MARK: - State, read from the model

    /// The prototype's `.vbar.typing`: the field has the caret and something to send.
    /// A blur with empty text collapses the bar back to one row (`:522`).
    private var isTyping: Bool { isComposerFocused && !model.composerText.isEmpty }

    /// `.card.left.riser-on .vbar.typing .cap{display:none}` (`:117`) — while a riser is
    /// up the caption gives the strip its room, and a live waveform takes its place.
    private var showsCaption: Bool { !isRiserUp && !model.isListening }

    /// Tab and → only mean "accept" while the field is empty and teaches something.
    private var canAcceptSuggestion: Bool {
        model.composerText.isEmpty && model.suggestion != nil
    }

    /// The workspace's accent — the prototype's `--ac`, set from the focused workspace
    /// and spent on the waveform. Falls back to Main's colour so an empty harness never
    /// draws a black bar (`Color(hex:)` resolves an unparsable string to black).
    private var accent: Color {
        Color(hex: focusedHex.isEmpty ? VoiceHarnessModel.mainColor : focusedHex)
    }

    /// The one line the prototype spends on `sayStatus`. An error outranks a notice; both
    /// are a single ellipsised line because the whole surface is `contentHeight` tall.
    private var noticeLine: (text: String, isError: Bool)? {
        if let error = model.lastError, !error.isEmpty { return (error, true) }
        if let notice = model.notice, !notice.isEmpty { return (notice, false) }
        return nil
    }

    // MARK: - Field measurement

    /// The field's line count, derived from the text alone (explicit breaks only): the
    /// card is a fixed 300 pt, and the prototype's own growth is `scrollHeight`-driven.
    private var lineCount: Int {
        guard !model.composerText.isEmpty else { return 1 }
        return model.composerText.reduce(1) { lines, character in
            character == "\n" ? lines + 1 : lines
        }
    }

    /// `.typein{overflow-y:auto}` — past the three-line cap the field scrolls itself.
    private var isAtLineCap: Bool { lineCount >= HarnessMetrics.composerMaxLines }

    /// The plan's three-line cap — and, while a riser is up, the lower cap the card can
    /// afford (`HarnessMetrics.composerLimit(riserUp:)`) — less another line whenever the
    /// status line shares the bar, so the typing state never asks for more than the box.
    private var fieldMaxHeight: CGFloat {
        let budget: CGFloat = noticeLine == nil
            ? HarnessMetrics.composerMaxHeight
            : CGFloat(showsCaption ? 1 : HarnessMetrics.composerMaxLines - 1) * HarnessMetrics.composerLineHeight
        return min(budget, HarnessMetrics.composerLimit(riserUp: isRiserUp))
    }

    /// `growInput()` (`:510`): one composer line per line of text, capped at three.
    private var fieldHeight: CGFloat {
        let lines = CGFloat(min(max(1, lineCount), HarnessMetrics.composerMaxLines))
        let grown = lines * HarnessMetrics.composerLineHeight
        return min(max(grown, HarnessMetrics.composerMinHeight), fieldMaxHeight)
    }

    // MARK: - Body

    var body: some View {
        // `.vbar.typing{flex-direction:column}`: while typing the caption takes the row's
        // place above it, and the row itself keeps every slot where it was — the field
        // never moves through the view tree, so the caret survives the flip.
        VStack(alignment: .leading, spacing: Bar.columnGap) {
            if isTyping, showsCaption { captionLine.transition(captionTransition) }
            controlRow
            noticeRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: Bar.paddingTop,
                            leading: Bar.paddingLeading,
                            bottom: Bar.paddingBottom,
                            trailing: Bar.paddingTrailing))
        .background(RoundedRectangle(cornerRadius: Bar.corner).fill(barFill))
        .overlay(RoundedRectangle(cornerRadius: Bar.corner).stroke(barBorder, lineWidth: Bar.hairlineWidth))
        // The prototype's own transitions: `border-color .3s, background .3s, gap .3s` on
        // the bar, the riser's spring when the caption gives way, and the spr curve for
        // the chip, the field's growth and the run controls.
        .animation(HarnessMotion.voiceBar, value: isTyping)
        .animation(HarnessMotion.voiceBar, value: model.isListening)
        .animation(HarnessMotion.riserAnimation, value: isRiserUp)
        .animation(HarnessMotion.spring, value: canAcceptSuggestion)
        .animation(HarnessMotion.springFast, value: fieldHeight)
        .animation(HarnessMotion.springFast, value: model.isRunning)
        .animation(HarnessMotion.springFast, value: noticeLine != nil)
    }

    /// `.vbar` — the bar's single row, resting or typing.
    ///
    /// A row either way, so the field keeps one position in the tree and one identity
    /// across the flip; the mic leads it while resting (`.vbar{flex-direction:row}`) and
    /// closes it while typing, exactly as the prototype's `.vrow` does (`:243`). The
    /// waveform and the caption trade the slot beside the mic for their own place in the
    /// typing row, and the `⇥ tab` chip sits beside the field whenever the field is empty
    /// and there is something to accept — the prototype scopes it to `.typing`, but the
    /// affordance has to outlive a blur to be teachable before the caret arrives.
    private var controlRow: some View {
        HStack(spacing: isTyping ? Bar.slotGap : Bar.rowGap) {
            if !isTyping { micButton }
            if !isTyping {
                if model.isListening {
                    waveform.transition(.opacity)
                } else if showsCaption {
                    captionLine.transition(captionTransition)
                }
            }
            composerField
            if canAcceptSuggestion { hintChip }
            if isTyping { waveform.transition(.opacity) }
            stopControl
            meterLabel
            if isTyping { micButton }
        }
    }

    /// `.cap` — the dim `agent · voice` sub-label over the harness's own line. Clicking it
    /// opens the composer exactly as the prototype's `#cap` does (`:520`).
    private var captionLine: some View {
        VStack(alignment: .leading, spacing: Bar.captionGap) {
            Text("agent · voice")
                .font(.system(size: HarnessMetrics.agentToolSize))
                .foregroundColor(Color(hex: Ink.dim))
            Text(model.caption)
                .font(.system(size: HarnessMetrics.composerFontSize))
                .foregroundColor(Color(hex: Ink.primary))
        }
        .lineLimit(1)
        .truncationMode(.tail)
        .contentShape(Rectangle())
        .onTapGesture { isComposerFocused = true }
    }

    /// The caption collapses on the riser's own opacity curve while its room opens on the
    /// riser's spring — the two `HarnessMotion` riser members, spent where they are owed.
    private var captionTransition: AnyTransition {
        .opacity.animation(HarnessMotion.riserOpacity).combined(with: .move(edge: .top))
    }

    // MARK: - The field

    /// The multiline field. A `TextEditor`, because the prototype's textarea starts
    /// top-left, grows upward and scrolls internally once it hits the cap.
    private var composerField: some View {
        TextEditor(text: composerBinding)
            .scrollContentBackground(.hidden)
            .background(Color.clear)
            .scrollDisabled(isAtLineCap)
            .font(.system(size: HarnessMetrics.composerFontSize))
            .foregroundColor(Color(hex: Ink.primary))
            .tint(accent)
            .frame(height: fieldHeight, alignment: .topLeading)
            .padding(.horizontal, Bar.fieldInsetX)
            .padding(.vertical, Bar.fieldInsetY)
            .overlay(alignment: .topLeading) { suggestionPlaceholder }
            .focused($isComposerFocused)
            .disabled(model.isRunning || isObscured)
            // A card drawn over the bar owns the keyboard. `.disabled` stops the edits but never
            // resigns the first responder, so the focused `TextEditor` would keep taking keys —
            // including the Return that sends — and `sendAction(cancelOperation:)` would land on
            // it instead of the card, so Escape would never reach the card's own `.onExitCommand`.
            .onChange(of: isObscured) { _, obscured in
                if obscured { isComposerFocused = false }
            }
            // Same reason while a run is live: the field is disabled and the bar is showing the
            // stop control, so it must not keep the keyboard (`cancelOperation:` would land on
            // the field instead of on any card's `.onExitCommand`).
            .onChange(of: model.isRunning) { _, running in
                if running { isComposerFocused = false }
            }
            .onKeyPress(.tab) {
                guard canAcceptSuggestion else { return .ignored }
                model.acceptSuggestion()
                return .handled
            }
            .onKeyPress(.rightArrow) {
                guard canAcceptSuggestion else { return .ignored }
                model.acceptSuggestion()
                return .handled
            }
    }

    /// The field's text, with Enter read as a send.
    ///
    /// `TextEditor` has no `onSubmit`, so the send is taken off the *insertion*: an edit
    /// that adds exactly one line break and changes nothing else is the Enter key, wherever
    /// the caret sits. Reading the insertion rather than intercepting the key keeps the IME
    /// honest — a Return that only commits marked text inserts no newline, so a
    /// half-composed utterance can never be sent (`TASKPLAN-voice-harness.md:68`) — and
    /// Shift+Enter still inserts its line break.
    private var composerBinding: Binding<String> {
        Binding(get: { model.composerText },
                set: { newValue in
                    let previous = model.composerText
                    if Self.insertedOneLineBreak(from: previous, to: newValue),
                       !NSEvent.modifierFlags.contains(.shift) {
                        // The break was the whole edit, so the send takes the text as it
                        // stood before it — Shift+Enter's own breaks stay put.
                        model.composerText = previous
                        submit()
                        return
                    }
                    model.composerText = newValue
                })
    }

    /// True when `newValue` is `previous` plus exactly one line break — one Enter key, not
    /// a paste and not an IME commit. An empty submit stays a no-op downstream.
    private static func insertedOneLineBreak(from previous: String, to newValue: String) -> Bool {
        let before = previous.filter { $0 != "\n" }
        let after = newValue.filter { $0 != "\n" }
        guard before == after else { return false }
        return newValue.filter { $0 == "\n" }.count == previous.filter { $0 == "\n" }.count + 1
    }

    /// Enter sends. An empty utterance is a no-op, and nothing is sent while a run holds
    /// the slot (`VoiceHarnessModel.submit()` guards the same ground).
    private func submit() {
        guard !model.isRunning else { return }
        let text = model.composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        onSubmit()
    }

    /// `.vbar.has-suggest .typein::placeholder{color:#8A8F98;font-style:italic}`. A
    /// `TextEditor` has no placeholder, so the suggestion is drawn on the caret's origin.
    @ViewBuilder private var suggestionPlaceholder: some View {
        if canAcceptSuggestion, let suggestion = model.suggestion {
            Text(suggestion)
                .font(.system(size: HarnessMetrics.composerFontSize).italic())
                .foregroundColor(Color(hex: Ink.suggest))
                .lineLimit(1)
                .truncationMode(.tail)
                .allowsHitTesting(false)
                .padding(.leading, Bar.textOriginInset)
                .padding(.top, Bar.textOriginInset)
        }
    }

    /// `.vbar.typing.has-suggest .shint{display:inline-flex}` — the `⇥ tab` chip that
    /// teaches the accept gesture.
    @ViewBuilder private var hintChip: some View {
        if canAcceptSuggestion {
            Text("⇥ tab")
                .font(.system(size: HarnessMetrics.agentToolSize))
                .foregroundColor(Color(hex: Ink.secondary))
                .lineLimit(1)
                .padding(.horizontal, Bar.hintPaddingX)
                .padding(.vertical, Bar.hintPaddingY)
                .background(Capsule().fill(Color.white.opacity(Bar.restFill)))
                .overlay(Capsule().stroke(Color.white.opacity(Bar.hairline), lineWidth: Bar.hairlineWidth))
                .transition(.opacity)
                .allowsHitTesting(false)
        }
    }

    // MARK: - Waveform

    /// `.wave` — nine bars. They are dim and still while the composer is open; while
    /// listening they come up to full opacity and stagger through `wv`.
    private var waveform: some View {
        Group {
            if model.isListening {
                TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: isPaused)) { timeline in
                    bars(at: timeline.date)
                }
            } else {
                bars(at: nil)
            }
        }
        .frame(height: Wave.height)
        .opacity(model.isListening ? Wave.liveOpacity : Wave.idleOpacity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// `.wave i` — `3px` wide, jumping `4px → 18px` and back on `.7 s ease-in-out`.
    private func bars(at date: Date?) -> some View {
        HStack(alignment: .center, spacing: Wave.gap) {
            ForEach(0..<Wave.bars, id: \.self) { index in
                RoundedRectangle(cornerRadius: Wave.corner)
                    .fill(accent)
                    .frame(width: Wave.width, height: Wave.rest)
                    .scaleEffect(y: Self.barScale(at: date, index: index), anchor: .center)
            }
        }
    }

    /// The `wv` keyframes, staggered: a cosine sweep is the CSS `ease-in-out` (0 at both
    /// ends, 1 at 50 %), so the scale is `1` when the bar is at rest and `peak / rest` at
    /// the top of its travel.
    private static func barScale(at date: Date?, index: Int) -> CGFloat {
        guard let date else { return 1 }
        return 1 + (Wave.peak / Wave.rest - 1) * waveProgress(at: date, index: index)
    }

    /// `wv` progress in 0…1 for one bar at one instant, phase-shifted by its stagger.
    private static func waveProgress(at date: Date, index: Int) -> CGFloat {
        var phase = (date.timeIntervalSinceReferenceDate - Wave.stagger(for: index))
            .truncatingRemainder(dividingBy: Wave.period) / Wave.period
        if phase < 0 { phase += 1 }
        return CGFloat(0.5 - 0.5 * cos(2 * Double.pi * phase))
    }

    // MARK: - Mic

    /// `.mic` — push-to-talk. There is no speech-to-text: it toggles the listening
    /// presentation and hands the user back the text path.
    private var micButton: some View {
        Button(action: { model.toggleListening() }) {
            ZStack {
                Circle().fill(model.isListening ? Color(hex: Ink.micLive) : Color.white.opacity(Bar.restFill))
                Image(systemName: "mic.fill")
                    .imageScale(.small)
                    .foregroundColor(model.isListening ? .white : Color(hex: Ink.secondary))
            }
            .frame(width: HarnessMetrics.micDiameter, height: HarnessMetrics.micDiameter)
            .overlay(Circle().stroke(model.isListening ? Color(hex: Ink.micLive) : Color.white.opacity(Bar.hairline),
                                     lineWidth: Bar.hairlineWidth))
            .overlay { micPulse }
        }
        .buttonStyle(.plain)
        .help(model.isListening ? "Stop listening" : "Push to talk")
        .accessibilityLabel(model.isListening ? "Stop listening" : "Push to talk")
    }

    /// `.mic.live{animation:pp 1.4s infinite}` — the ping ring, on the harness's own
    /// listening pulse (`HarnessMotion.listeningRingPing` / `…From` / `…To`).
    @ViewBuilder private var micPulse: some View {
        if model.isListening {
            TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: isPaused)) { timeline in
                let phase = Self.pulsePhase(at: timeline.date)
                Circle()
                    .stroke(Color(hex: Ink.micLive).opacity(Ink.micPulse), lineWidth: Bar.hairlineWidth)
                    .scaleEffect(HarnessMotion.lerp(HarnessMotion.listeningRingFrom,
                                                    HarnessMotion.listeningRingTo,
                                                    phase))
                    .opacity(1 - phase)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private static func pulsePhase(at date: Date) -> CGFloat {
        var phase = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: HarnessMotion.listeningRingPing) / HarnessMotion.listeningRingPing
        if phase < 0 { phase += 1 }
        return CGFloat(phase)
    }

    // MARK: - Run controls

    /// The stop control, only while a run holds the slot; it spins while the child is
    /// being torn down (`model.isStopping`).
    @ViewBuilder private var stopControl: some View {
        if model.isRunning {
            Button(action: { model.stop() }) {
                ZStack {
                    Circle().fill(Color(hex: Ink.error).opacity(Ink.stopFill))
                    if model.isStopping {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: "stop.fill")
                            .imageScale(.small)
                            .foregroundColor(Color(hex: Ink.error))
                    }
                }
                .frame(width: HarnessMetrics.micDiameter, height: HarnessMetrics.micDiameter)
            }
            .buttonStyle(.plain)
            .disabled(model.isStopping)
            .help("Stop the run")
            .accessibilityLabel("Stop the run")
            .transition(.opacity)
        }
    }

    /// The run meter, small and dim beside the field while a run is live — with the model
    /// that is doing the work, read from `AppState` via `model.contextModel`. The prototype
    /// has no chip of its own, so this rides the meter (visible only during a run) rather
    /// than adding an element to the resting bar that the prototype does specify.
    @ViewBuilder private var meterLabel: some View {
        if model.isRunning {
            HStack(spacing: Bar.slotGap / 2) {
                Text(modelChipName)
                    .font(.system(size: HarnessMetrics.agentToolSize, weight: .medium, design: .monospaced))
                    .foregroundColor(Color(hex: Ink.dim))
                    .lineLimit(1)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.white.opacity(Bar.restFill)))
                    .overlay(Capsule().stroke(Color.white.opacity(Bar.hairline), lineWidth: Bar.hairlineWidth))
                    .help(model.contextModel)
                    .accessibilityLabel("Model \(model.contextModel)")
                Text(model.meterText)
                    .font(.system(size: HarnessMetrics.agentToolSize))
                    .foregroundColor(Color(hex: Ink.dim))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityLabel("Run cost")
            }
            .transition(.opacity)
        }
    }

    /// `"opencode/big-pickle"` reads as `big-pickle` in a 26 pt bar — the vendor prefix is
    /// the provider, which the caption already implies.
    private var modelChipName: String {
        let id = model.contextModel
        guard let last = id.split(separator: "/").last, !last.isEmpty else { return id }
        return String(last)
    }

    // MARK: - Status line

    /// The single dim line left for a notice or a failure.
    @ViewBuilder private var noticeRow: some View {
        if let line = noticeLine {
            Text(line.text)
                .font(.system(size: HarnessMetrics.agentToolSize))
                .foregroundColor(Color(hex: line.isError ? Ink.error : Ink.dim))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity)
        }
    }

    // MARK: - Chrome

    /// `.vbar.live{border-color:rgba(236,72,153,.45)}`.
    private var barBorder: Color {
        model.isListening ? Color(hex: Live.hex).opacity(Live.border) : Color.white.opacity(Bar.hairline)
    }

    /// `.vbar{background:rgba(255,255,255,.05)}` / `.vbar.live{background:rgba(236,72,153,.07)}`.
    private var barFill: Color {
        model.isListening ? Color(hex: Live.hex).opacity(Live.fill) : Color.white.opacity(Bar.restFill)
    }
}
