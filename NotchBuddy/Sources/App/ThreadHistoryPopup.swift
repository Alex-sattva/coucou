import SwiftUI

// MARK: - Thread history popup

/// The harness's thread history, opened from the left card's clock button.
///
/// Visual source of truth: `design/prototype/harness-main-voice.html` — `.histpop`
/// (line 169-173), `.hlist` / `.hitem` / `.hdot` / `.rew` (lines 174-182),
/// `@keyframes pop` (line 182), the markup at lines 259-263 and `renderHist()`
/// (line 446):
///
///     <div class="histpop" id="histpop">
///       <div class="hp"><b>◷ Threads</b><span id="hpCount"></span></div>
///       <input id="histq" placeholder="Search threads…">
///       <div class="hlist" id="hlist"></div>
///     </div>
///
/// The prototype's `.hp b` is the literal "◷ Threads" and its `#hpCount` is
/// `workspace · count`; here the clock is an SF Symbol and the count keeps the
/// caller's `title` as its context prefix.
///
/// The popup is a *zero-footprint* overlay: `Color.clear` fills whatever box the
/// caller gives it (620 × 98 in the harness) and the card fills that same box, top-trailing.
/// The prototype's island is 912 × ~600 and its `.histpop` is a ~292 pt panel hanging off
/// the corner; the island clips its content to `IslandShape`, so here the panel is sized to
/// the surface instead — see `HarnessMetrics.historyPopupWidth` / `historyPopupMaxHeight`.
struct ThreadHistoryPopup: View {

    /// The workspace's threads. Drawn newest first on `order`, whatever order they arrive in.
    let rows: [HarnessThread]
    /// The workspace's name, shown beside the count (the prototype's `#hpCount`).
    let title: String
    let onRewind: (HarnessThread) -> Void
    let onClose: () -> Void

    init(
        rows: [HarnessThread],
        title: String,
        onRewind: @escaping (HarnessThread) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.rows = rows
        self.title = title
        self.onRewind = onRewind
        self.onClose = onClose
    }

    /// The search field's query. Local on purpose: the popup filters the rows it was
    /// handed and never reaches into the store.
    @State private var query = ""
    /// `pop` runs once, when the popup opens.
    @State private var entered = false

    var body: some View {
        // The invisible anchor fills the caller's box but never takes a click: only the
        // card does, so the surface under the popup stays live.
        Color.clear
            .allowsHitTesting(false)
            .overlay(alignment: .topTrailing) {
                card
                    // `@keyframes pop{from{opacity:0;transform:scale(.97)}}` at .28 s `--spr`.
                    .opacity(entered ? 1 : 0)
                    .scaleEffect(entered ? 1 : Self.popScale)
                    .offset(x: -HarnessMetrics.historyPopupRight, y: HarnessMetrics.historyPopupTop)
            }
            .onAppear {
                withAnimation(HarnessMotion.springFast) { entered = true }
            }
    }

    // MARK: Card

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            list
        }
        .frame(width: HarnessMetrics.historyPopupWidth)
        .frame(maxHeight: HarnessMetrics.historyPopupMaxHeight)
        .background(
            RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
                .fill(Color(hex: Self.panelHex))
        )
        .clipShape(RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
                .strokeBorder(Color.white.opacity(Self.borderOpacity), lineWidth: 1)
        )
        // `.histpop{box-shadow:0 26px 60px rgba(0,0,0,.7)}`.
        .shadow(color: Color.black.opacity(0.7), radius: 30, x: 0, y: 26)
    }

    private var header: some View {
        HStack(spacing: Self.headerGap) {
            Image(systemName: "clock")
                .font(.system(size: Self.clockSize, weight: .semibold))
                .foregroundColor(Color(hex: Self.mutHex))
            Text("Threads")
                .font(.system(size: Self.headerSize, weight: .semibold))
                .foregroundColor(Color(hex: Self.inkHex))
            Text(countLabel)
                .font(.system(size: Self.countSize))
                .foregroundColor(Color(hex: Self.dimHex))
                .lineLimit(1)
            Spacer(minLength: Self.headerGap)
            searchField
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: Self.closeGlyphSize, weight: .semibold))
                    .foregroundColor(Color(hex: Self.mutHex))
                    .frame(width: Self.closeButtonSize, height: Self.closeButtonSize)
                    .background(Circle().fill(Color.white.opacity(0.06)))
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(.horizontal, Self.headerPadding)
        .padding(.vertical, Self.headerPaddingVertical)
        .overlay(alignment: .bottom) { hairline(Self.lineOpacity) }
    }

    /// The prototype's `input`, folded onto the header line.
    ///
    /// The prototype stacks header + search + list in a ~292 pt panel. The harness gets
    /// 98 pt, and a stacked search would leave less than one thread row visible, so the
    /// search rides the header as a capsule field and the list keeps the rest.
    private var searchField: some View {
        TextField("Search threads…", text: $query)
            .textFieldStyle(.plain)
            .font(.system(size: Self.searchSize))
            .foregroundColor(.white)
            .padding(.horizontal, Self.searchPaddingHorizontal)
            .padding(.vertical, Self.searchPaddingVertical)
            .frame(maxWidth: Self.searchMaxWidth)
            .background(Capsule().fill(Color.white.opacity(Self.searchFillOpacity)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(Self.lineOpacity), lineWidth: 1))
    }

    @ViewBuilder
    private var list: some View {
        if rows.isEmpty {
            emptyState(Self.emptyWorkspaceText)
        } else if filtered.isEmpty {
            emptyState(Self.emptyFilterText)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filtered) { thread in
                        HistoryRow(thread: thread, onRewind: onRewind)
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func emptyState(_ message: String) -> some View {
        Text(message)
            .font(.system(size: Self.emptySize))
            .foregroundColor(Color(hex: Self.dimHex))
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Self.headerPadding)
            .padding(.vertical, Self.emptyPaddingVertical)
    }

    private func hairline(_ opacity: Double) -> some View {
        Rectangle()
            .fill(Color.white.opacity(opacity))
            .frame(height: 1)
    }

    // MARK: Filtering

    /// The workspace's threads, newest first, narrowed by the search field.
    private var filtered: [HarnessThread] {
        let ordered = rows.sorted { $0.order > $1.order }
        let needle = Self.normalize(query)
        guard !needle.isEmpty else { return ordered }
        return ordered.filter { Self.normalize($0.title).contains(needle) }
    }

    /// Case- and diacritic-insensitive comparison key. Deliberately local: this file
    /// stands alone and does not depend on `KeywordRouter.normalize(_:)`.
    private static func normalize(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The prototype's `#hpCount`: `workspace · count`, or just the count when the
    /// caller has no name for the workspace.
    private var countLabel: String {
        let count = rows.count
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "\(count)" : "\(name) · \(count)"
    }

    // MARK: One row

    /// `.hitem`: busy dot, title, chip, right-aligned age. Tapping anywhere on the row
    /// rewinds — but only for threads that actually have a snapshot to restore.
    private struct HistoryRow: View {
        let thread: HarnessThread
        let onRewind: (HarnessThread) -> Void

        @State private var hovering = false

        var body: some View {
            Button {
                guard thread.hasSnapshot else { return }
                onRewind(thread)
            } label: {
                HStack(spacing: Self.rowGap) {
                    dot
                    Text(thread.title)
                        .font(.system(size: Self.rowSize))
                        .foregroundColor(Color(hex: Self.titleHex))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    chip
                    Spacer(minLength: Self.rowGap)
                    Text(thread.age())
                        .font(.system(size: Self.ageSize))
                        .foregroundColor(Color(hex: Self.dimHex))
                        .lineLimit(1)
                        .layoutPriority(1)
                }
                .padding(.horizontal, Self.rowPaddingHorizontal)
                .padding(.vertical, Self.rowPaddingVertical)
                .background(hovering ? Color.white.opacity(Self.hoverOpacity) : Color.clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.white.opacity(Self.separatorOpacity))
                    .frame(height: 1)
            }
        }

        /// `.hdot` — 7 pt; `.hdot.busy` swaps to `--blue` and adds a 3 px halo.
        private var dot: some View {
            ZStack {
                if thread.isBusy {
                    Circle()
                        .fill(Color(hex: Self.busyHex).opacity(Self.haloOpacity))
                        .frame(width: Self.haloSize, height: Self.haloSize)
                }
                Circle()
                    .fill(Color(hex: thread.isBusy ? Self.busyHex : Self.dimHex))
                    .frame(width: Self.dotSize, height: Self.dotSize)
            }
            .frame(width: Self.haloSize, height: Self.haloSize)
        }

        /// `.rew` — `working` while the thread runs, `↩ rewind` when there is a
        /// snapshot to restore, and nothing at all otherwise.
        @ViewBuilder
        private var chip: some View {
            if thread.isBusy {
                chipLabel("working")
            } else if thread.hasSnapshot {
                chipLabel("↩ rewind")
            }
        }

        private func chipLabel(_ value: String) -> some View {
            Text(value)
                .font(.system(size: Self.chipSize))
                .foregroundColor(Color(hex: Self.chipHex))
                .padding(.horizontal, Self.chipPaddingHorizontal)
                .padding(.vertical, Self.chipPaddingVertical)
                .overlay(
                    Capsule().strokeBorder(Color.white.opacity(Self.chipBorderOpacity), lineWidth: 1)
                )
                .fixedSize()
        }

        // `.hitem` / `.hdot` / `.hitem .rew` (design/prototype/harness-main-voice.html:174-182).

        private static let rowSize: CGFloat = 12.5         // .hitem font-size
        private static let ageSize: CGFloat = 10.5         // .hitem .t
        private static let chipSize: CGFloat = 10          // .hitem .rew
        private static let dotSize: CGFloat = 7            // .hdot
        private static let haloSize: CGFloat = 13          // 7 + 2 × the 3 px busy ring
        private static let rowGap: CGFloat = 9             // .hitem gap
        private static let rowPaddingHorizontal: CGFloat = 12  // .hitem padding 9px 12px
        // 9 px in the prototype; tightened so two whole rows clear inside the 98 pt surface.
        private static let rowPaddingVertical: CGFloat = 5
        private static let chipPaddingHorizontal: CGFloat = 7
        private static let chipPaddingVertical: CGFloat = 1
        private static let hoverOpacity: Double = 0.06     // .hitem:hover
        private static let separatorOpacity: Double = 0.04 // .hitem border-bottom
        private static let haloOpacity: Double = 0.25      // .hdot.busy ring
        private static let chipBorderOpacity: Double = 0.12 // --line2
        private static let busyHex = "#3B9EFF"             // --blue
        private static let dimHex = "#6B7079"              // --dim
        private static let titleHex = "#C9CCD2"            // .hitem color
        private static let chipHex = "#8E939C"             // .hitem .rew color
    }

    // MARK: Prototype measurements
    //
    // `HarnessMetrics` supplies the popup's box (width / top / right); the colours,
    // radii and type sizes below come from the prototype's `.histpop` / `.hitem` rules.

    private static let popScale: CGFloat = 0.97        // @keyframes pop
    private static let corner: CGFloat = 16            // .histpop border-radius
    private static let borderOpacity: Double = 0.10    // asked to be 1 pt white at 10 %
    private static let headerGap: CGFloat = 6
    private static let headerPadding: CGFloat = 12     // .histpop .hp padding 10px 12px
    // The prototype's `.hp` padding is 10 px and its `input` is a full row of its own.
    // At 98 pt those two alone eat 74 pt and leave no visible thread row, so the search
    // moved onto the header line and both paddings tightened.
    private static let headerPaddingVertical: CGFloat = 6
    private static let searchPaddingHorizontal: CGFloat = 8
    private static let searchPaddingVertical: CGFloat = 3
    private static let searchMaxWidth: CGFloat = 200
    private static let searchFillOpacity: Double = 0.05
    private static let headerSize: CGFloat = 12        // .hp b
    private static let countSize: CGFloat = 10.5       // .hp span
    private static let searchSize: CGFloat = 12.5      // .histpop input
    private static let emptySize: CGFloat = 11.5
    private static let emptyPaddingVertical: CGFloat = 12
    private static let clockSize: CGFloat = 12
    private static let closeGlyphSize: CGFloat = 9
    private static let closeButtonSize: CGFloat = 20
    private static let lineOpacity: Double = 0.07      // --line

    private static let panelHex = "#1C1E22"            // .histpop background (--card2)
    private static let inkHex = "#F5F6F8"              // --ink
    private static let mutHex = "#8E939C"              // --mut
    private static let dimHex = "#6B7079"              // --dim

    private static let emptyWorkspaceText = "No threads in this workspace yet."
    private static let emptyFilterText = "No thread matches that."
}
