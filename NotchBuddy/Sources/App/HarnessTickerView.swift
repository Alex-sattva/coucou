import SwiftUI

/// The agent's step trail, scrolling upward as the current step advances.
///
/// Ported from the prototype's `.ticker` / `.tk-in` / `.ln` rules
/// (`design/prototype/harness-main-voice.html:80-99`): lines are `tickerLineHeight`
/// tall, the previous line is dim at `tickerLineSize` and the current (last) line is
/// brighter, heavier and shimmers; the stack rolls up by one line whenever the last
/// element changes — the prototype does it with
/// `tk.style.transform = translateY(-(max(0,ci-1))*30)` (`harness-main-voice.html:427`),
/// which bottom-pins the stack inside a fixed-height, masked slot exactly as here.
///
/// The parent owns the frame (roughly 280 × 45 pt — two lines' worth). This view fills
/// it, clips, and fades both edges with the prototype's mask. Empty input renders an
/// empty, non-crashing view.
struct HarnessTickerView: View {
    /// Oldest first; the last non-empty element is the current step.
    let lines: [String]
    /// Stops the shimmer timeline while the island is hidden or another view has the floor.
    let isPaused: Bool

    init(lines: [String], isPaused: Bool = false) {
        self.lines = lines
        self.isPaused = isPaused
    }

    /// One rendered row.
    ///
    /// `id` is the line's text (plus an occurrence suffix so duplicate step texts can
    /// never collide in the `ForEach`): when a step is appended, the row that was
    /// current keeps its identity as it slides up into the previous slot, so the roll
    /// is a real movement rather than an insert + remove at the same place.
    private struct Row: Identifiable {
        let id: String
        let text: String
        let isCurrent: Bool
    }

    /// The non-empty lines, oldest first, with the last one marked current.
    private var rows: [Row] {
        let cleaned = lines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var occurrences: [String: Int] = [:]
        return cleaned.enumerated().map { offset, text in
            let occurrence = occurrences[text, default: 0]
            occurrences[text] = occurrence + 1
            return Row(id: "\(occurrence)|\(text)",
                       text: text,
                       isCurrent: offset == cleaned.count - 1)
        }
    }

    var body: some View {
        Group {
            if rows.isEmpty {
                Color.clear
            } else {
                stack
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .clipped()
        // Prototype `.ticker`: mask transparent → opaque at 22 % → transparent, i.e.
        // `linear-gradient(transparent,#000 22%,#000 78%,transparent)`.
        .mask(
            LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: HarnessMotion.tickerMaskInset),
                .init(color: .black, location: 1 - HarnessMotion.tickerMaskInset),
                .init(color: .clear, location: 1),
            ], startPoint: .top, endPoint: .bottom)
        )
        .animation(HarnessMotion.tickerRoll, value: lines)
    }

    /// All lines, laid out top to bottom; the whole stack is bottom-pinned in `body`,
    /// so appending a line shifts every existing line up by one `tickerLineHeight`.
    private var stack: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(rows) { row in
                line(row)
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .move(edge: .top).combined(with: .opacity)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func line(_ row: Row) -> some View {
        if row.isCurrent {
            HarnessTickerShimmerText(text: row.text,
                                     size: HarnessMetrics.tickerCurrentSize,
                                     weight: .medium,
                                     isPaused: isPaused)
                .frame(height: HarnessMetrics.tickerLineHeight, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(row.text)
                .font(.system(size: HarnessMetrics.tickerLineSize))
                .foregroundColor(Color(hex: "#5F646D"))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(height: HarnessMetrics.tickerLineHeight, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Current line shimmer

/// The current ticker line's shimmer.
///
/// This is a private re-declaration of the shipping `TickerShimmerText`
/// (`IslandViewContent.swift:3642`) so the harness neither depends on nor changes that
/// view: same `TimelineView(.animation)`, same phase sweep, same
/// `#7c818a → #F2F3F5 → #7c818a` leading→trailing gradient. Only the period is read
/// from `HarnessMotion.shimmerPeriod` instead of an inline literal.
private struct HarnessTickerShimmerText: View {
    let text: String
    let size: CGFloat
    let weight: Font.Weight
    let isPaused: Bool

    var body: some View {
        TimelineView(.animation(paused: isPaused)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let p = CGFloat(t.truncatingRemainder(dividingBy: HarnessMotion.shimmerPeriod)
                / HarnessMotion.shimmerPeriod)
            // phase sweeps -0.1 → 1.1 so the white peak enters from the left and exits right
            let phase = p * Self.sweepWidth - Self.sweepLead
            Text(text)
                .font(.system(size: size, weight: weight))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(LinearGradient(stops: [
                    .init(color: Color(hex: "#7c818a"), location: max(0, phase - 0.3)),
                    .init(color: Color(hex: "#F2F3F5"), location: max(0, min(1, phase))),
                    .init(color: Color(hex: "#7c818a"), location: min(1, phase + 0.3)),
                ], startPoint: .leading, endPoint: .trailing))
        }
    }

    /// The prototype's `background-size:220% 100%` swept over one element width:
    /// `shimmerPeriod − 1` (2.2 − 1.0 = 1.2).
    private static var sweepWidth: CGFloat { CGFloat(HarnessMotion.shimmerPeriod) - 1 }
    /// The sweep starts one tenth early so the peak enters from the left edge.
    private static var sweepLead: CGFloat { 0.1 }
}
