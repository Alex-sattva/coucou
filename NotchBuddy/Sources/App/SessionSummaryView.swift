import SwiftUI

// MARK: - Done summary

/// The agent's done summary, shown in the *same* left-card slot as the step ticker.
///
/// Visual source of truth: `design/prototype/harness-main-voice.html` —
/// `.summary` / `.shead` / `.sdot` / `.swhen` / `.stext` (lines 84-92), the
/// `@keyframes sumIn` entrance (line 87) and the markup at lines 234-237:
///
///     <div class="summary" id="summary">
///       <div class="shead"><span class="sdot"></span>Done · <b>coucou-app</b><span class="swhen">just now</span></div>
///       <div class="stext">Fixed — missing await on signIn(), LoginView.swift:42. Tests pass.</div>
///     </div>
///
/// The prototype swaps the ticker for this card when a run finishes
/// (`finish()` adds `.done` to `#slot`, line 434). It does not size the slot:
/// the view fills whatever box it is given, exactly like the ticker it replaces.
///
/// The summary is deliberately neutral — the only colour in it is the green dot, so
/// `accentHex` (the focused workspace's colour) is kept for callers that need it and
/// is intentionally not drawn here. See the note in `body`.
struct SessionSummaryView: View {

    /// The run's headline — the prototype's `Done · <workspace>` label.
    let title: String
    /// The agent's one-liner (the prototype's `.stext`).
    let text: String
    /// The right-aligned age, e.g. "just now".
    let when: String
    /// The focused workspace's colour. Unused today: the prototype's summary shows no
    /// workspace tint, only the green dot, and the brief asks for restraint.
    let accentHex: String

    init(title: String, text: String, when: String, accentHex: String) {
        self.title = title
        self.text = text
        self.when = when
        self.accentHex = accentHex
    }

    /// `sumIn` runs once, when the summary takes the slot.
    @State private var entered = false

    var body: some View {
        // The height is the slot's, and the slot is not ours to size: measure it and
        // clamp the one-liner to the lines that actually fit (prototype `.stext` is
        // 12.5 pt at a 1.4 line-height, and truncates rather than pushing the card).
        GeometryReader { proxy in
            let lines = Self.bodyLines(for: proxy.size.height)
            let gap = Self.blockGap(for: proxy.size.height)
            VStack(alignment: .leading, spacing: gap) {
                header
                Text(text)
                    .font(.system(size: Self.bodySize))
                    .foregroundColor(Color(hex: Self.bodyHex))
                    .lineSpacing(Self.bodyLineSpacing)
                    .lineLimit(lines)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            // `.summary` is `flex-direction:column; justify-content:center`, so the
            // block sits in the vertical middle of the slot.
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
        }
        // `@keyframes sumIn{from{opacity:0;transform:translateX(-10px)}}` at .5 s `--spr`.
        .opacity(entered ? 1 : 0)
        .offset(x: entered ? 0 : Self.enterOffset)
        .onAppear {
            withAnimation(HarnessMotion.summaryIn) { entered = true }
        }
    }

    // MARK: Header

    /// `.shead`: glowing green dot, headline, right-aligned age.
    private var header: some View {
        HStack(spacing: Self.headerGap) {
            Circle()
                .fill(Color(hex: Self.okHex))
                .frame(width: Self.dotSize, height: Self.dotSize)
                // `.sdot{box-shadow:0 0 9px var(--ok)}` — a 9 px blur is a 4.5 pt radius.
                .shadow(color: Color(hex: Self.okHex).opacity(0.9), radius: Self.dotGlow)
            Text(title)
                .font(.system(size: Self.headerSize, weight: .semibold))
                .foregroundColor(Color(hex: Self.titleHex))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: Self.headerGap)
            Text(when)
                .font(.system(size: Self.headerSize))
                .foregroundColor(Color(hex: Self.dimHex))
                .lineLimit(1)
                .layoutPriority(1)
        }
    }

    // MARK: Measurement

    /// How many 12.5 pt lines fit between the header and the bottom of the slot.
    private static func bodyLines(for height: CGFloat) -> Int {
        let available = height - headerLineHeight - blockGapValue
        return max(1, Int(available / bodyLineHeight))
    }

    /// `.summary{gap:7px}`, relaxed only when the slot is too short for it — a centred
    /// stack that overflows both edges would clip the header first.
    private static func blockGap(for height: CGFloat) -> CGFloat {
        max(minBlockGap, min(blockGapValue, height - headerLineHeight - bodyLineHeight))
    }

    // MARK: Prototype measurements
    //
    // `HarnessMetrics` (HarnessMotion.swift:263) has no summary box, and this file may
    // not touch it, so the font metrics live here, each copied from the prototype.

    private static let dotSize: CGFloat = 7            // .summary .sdot
    private static let dotGlow: CGFloat = 4.5          // .sdot 0 0 9px
    private static let headerSize: CGFloat = 10.5      // .summary .shead
    private static let headerGap: CGFloat = 6          // .shead gap
    private static let blockGapValue: CGFloat = 7      // .summary gap
    private static let bodySize: CGFloat = 12.5        // .summary .stext
    private static let bodyLineHeight: CGFloat = 17.5  // .stext 12.5 × line-height 1.4
    /// A 10.5 pt line box is ~12.6 pt; rounded to 13 for the line budget.
    private static let headerLineHeight: CGFloat = 13
    /// The tightest gap the header and one body line are allowed to be squeezed to.
    private static let minBlockGap: CGFloat = 2
    private static let bodyLineSpacing: CGFloat = 2.5  // 17.5 − the system 12.5 pt line box
    private static let enterOffset: CGFloat = -10      // @keyframes sumIn

    private static let okHex = "#34D399"               // --ok
    private static let titleHex = "#C9CCD2"            // .shead b
    private static let dimHex = "#6B7079"              // --dim
    private static let bodyHex = "#E8E9EC"             // .stext
}
