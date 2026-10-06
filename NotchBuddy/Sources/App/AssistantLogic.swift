import Foundation

// Pure decision logic for the assistant layer: who is the main Mochi, who needs the user,
// and where each small Mochi sits. Foundation only (tested by `scripts/test-assistant-logic.sh`).

enum MainAgentPicker {
    /// The main spot goes, in order, to: the agent the user clicked (if still alive) ->
    /// the oldest agent that needs the user (`AttentionQueue`) -> the most recently active
    /// session of the workspace the user is working in -> the previous main if still alive ->
    /// the most recently active session. Returns nil when there are no sessions.
    static func pick(sessions: [AgentSession], selectedId: String?, contextWorkspace: String?,
                     previousMainId: String?) -> String? {
        guard !sessions.isEmpty else { return nil }
        let ids = Set(sessions.map(\.id))

        if let selectedId, ids.contains(selectedId) { return selectedId }

        if let needy = AttentionQueue.order(sessions).first { return needy.id }

        if let contextWorkspace,
           let inContext = mostRecent(sessions.filter { $0.workspace == contextWorkspace }) {
            return inContext.id
        }

        if let previousMainId, ids.contains(previousMainId) { return previousMainId }

        return mostRecent(sessions)?.id
    }

    /// Latest `lastEventAt`; ties break on id so the result never depends on dictionary order.
    private static func mostRecent(_ sessions: [AgentSession]) -> AgentSession? {
        sessions.min { a, b in
            if a.lastEventAt != b.lastEventAt { return a.lastEventAt > b.lastEventAt }
            return a.id < b.id
        }
    }
}

enum AttentionQueue {
    /// approval/question/blocked first (oldest attentionAt first), then finished && !finishedSeen.
    /// Ties on `attentionAt` go to the session whose last event is older, then to the id.
    static func order(_ sessions: [AgentSession]) -> [AgentSession] {
        let blocking = sessions.filter {
            $0.phase == .approval || $0.phase == .question || $0.phase == .blocked
        }
        let done = sessions.filter { $0.phase == .finished && !$0.finishedSeen }
        return sorted(blocking) + sorted(done)
    }

    private static func sorted(_ list: [AgentSession]) -> [AgentSession] {
        list.sorted { a, b in
            let ta = a.attentionAt ?? .distantFuture
            let tb = b.attentionAt ?? .distantFuture
            if ta != tb { return ta < tb }
            if a.lastEventAt != b.lastEventAt { return a.lastEventAt < b.lastEventAt }
            return a.id < b.id
        }
    }
}

enum SubSlotOrder {
    /// Keeps every surviving sub in its slot. When `newMain` was a sub and `oldMain` is still alive,
    /// `oldMain` takes `newMain`'s slot and that index is returned (the slot to recolour after landing).
    static func update(order: [String], alive: [String], oldMain: String?, newMain: String?)
        -> (order: [String], recolourIndex: Int?) {
        let aliveSet = Set(alive)
        let oldMainAlive: String? = {
            guard let oldMain, oldMain != newMain, aliveSet.contains(oldMain) else { return nil }
            return oldMain
        }()

        var slots = order
        var swapped: String? = nil   // the id that took the clicked sub's slot

        if let newMain, let i = slots.firstIndex(of: newMain), let old = oldMainAlive,
           !slots.contains(old) {
            slots[i] = old
            swapped = old
        }

        // Drop dead ids and the new main (when it was not swapped out above, its slot closes).
        slots = slots.filter { aliveSet.contains($0) && $0 != newMain }

        // The old main joins the subs when it was not already placed by the swap.
        if let old = oldMainAlive, !slots.contains(old) { slots.append(old) }

        // Any alive id that is neither main nor present gets a new slot at the end.
        for id in alive where id != newMain && !slots.contains(id) { slots.append(id) }

        let recolour = swapped.flatMap { slots.firstIndex(of: $0) }
        return (slots, recolour)
    }
}

/// Geometry of the quiet strip (compact island), in island coordinates (origin top-left).
/// Values come from `design/prototype/assistant-multi-agent-prototype.html` (variant E).
/// `restingDiameter` is `IslandRestingLayout.botDiameter`.
struct AssistantStripGeometry: Equatable {
    static let maxVisibleSubs = 5
    static let subSpacing: CGFloat = 26
    static let subFirstOffset: CGFloat = 22     // first sub centre, outside the notch's right edge
    static let mainOffset: CGFloat = 30         // main centre, outside the notch's left edge
    static let minSide: CGFloat = 56            // minimum width each side of the notch
    static let subRatio: CGFloat = 0.68

    let islandWidth: CGFloat
    let islandHeight: CGFloat
    let notchWidth: CGFloat
    let restingDiameter: CGFloat

    /// Slots drawn right of the notch: up to 5 subs, plus one slot for the "+N" count on overflow.
    static func slotCount(subs: Int) -> Int {
        min(max(0, subs), maxVisibleSubs) + (subs > maxVisibleSubs ? 1 : 0)
    }

    /// Compact island width = notch + 2 x max(56, slots x 26 + 26): symmetric, so the camera stays centred.
    static func compactWidth(notchWidth: CGFloat, subs: Int) -> CGFloat {
        notchWidth + 2 * max(minSide, CGFloat(slotCount(subs: subs)) * subSpacing + subSpacing)
    }

    /// Resting diameter x 1.25, capped at notch height - 4.
    var mainDiameter: CGFloat { max(0, min(restingDiameter * 1.25, islandHeight - 4)) }
    var subDiameter: CGFloat { mainDiameter * Self.subRatio }
    var centreY: CGFloat { islandHeight / 2 }
    var mainCentreX: CGFloat { islandWidth / 2 - notchWidth / 2 - Self.mainOffset }
    func subCentreX(_ index: Int) -> CGFloat {
        islandWidth / 2 + notchWidth / 2 + Self.subFirstOffset + CGFloat(index) * Self.subSpacing
    }
}

extension AgentSession {
    /// Colour of the small status dot next to a Mochi: amber = approval/question, red = blocked,
    /// green = finished and not yet seen. nil = no dot.
    var statusDotHex: String? {
        switch phase {
        case .approval, .question: return "#F5A524"
        case .blocked: return "#F87171"
        case .finished: return finishedSeen ? nil : "#34D399"
        case .thinking, .working, .idle: return nil
        }
    }
}

// MARK: - Panel: open rule and content

/// When the assistant panel is open. Pure, so the state machine is tested without the UI.
///
/// open = summoned || selectedId != nil || (queue not empty && queue signature != dismissed signature)
enum AssistantOpenRules {
    /// Changes whenever a need appears, changes phase, or is answered. Includes `attentionAt`, so
    /// the same session asking twice gives two different signatures. Empty queue -> "".
    static func signature(queue: [AgentSession]) -> String {
        queue.map { "\($0.id)|\($0.phase.rawValue)|\($0.attentionAt?.timeIntervalSince1970 ?? 0)" }
            .joined(separator: ",")
    }

    static func isOpen(summoned: Bool, selectedId: String?, queue: [AgentSession],
                       dismissedSignature: String?) -> Bool {
        if summoned || selectedId != nil { return true }
        guard !queue.isEmpty else { return false }
        return signature(queue: queue) != dismissedSignature
    }
}

/// What the panel shows under the top row. Decides the panel height.
enum AssistantPanelContent: Equatable, Sendable {
    case bar                       // summoned with nothing pending: the bar row only
    case approval
    case question(rows: Int)       // rows = option buttons + the "Other..." row
    case blocked
    case finished(files: Int)
    case diff                      // the finished card's diff, opened in place

    /// The card for the main session. `hasApproval` / `questionRows` say whether the held request
    /// for THAT session still exists (a timed-out request has no card, whatever the phase says).
    static func resolve(main: AgentSession?, hasApproval: Bool, questionRows: Int?,
                        finishedFiles: Int, showsDiff: Bool) -> AssistantPanelContent {
        guard let main else { return .bar }
        switch main.phase {
        case .approval where hasApproval: return .approval
        case .question:
            if let rows = questionRows { return .question(rows: rows) }
            return .bar
        case .blocked: return .blocked
        case .finished where !main.finishedSeen:
            return showsDiff && finishedFiles > 0 ? .diff : .finished(files: finishedFiles)
        default: return .bar
        }
    }
}

/// Panel heights in points. The prototype (variant D) values are the starting point; the
/// finished card grows by one file row (21 pt) per changed file, up to 3, and the question card
/// by 34 pt per option row.
enum AssistantMetrics {
    static let bar: CGFloat = 112
    static let approval: CGFloat = 236
    static let blocked: CGFloat = 262
    static let finishedBase: CGFloat = 206
    static let fileRow: CGFloat = 21
    static let maxFileRows = 3
    static let questionBase: CGFloat = 120
    static let questionRow: CGFloat = 34
    static let diff: CGFloat = 300
    /// The island window is 320 pt tall.
    static let maxHeight: CGFloat = 320

    static func height(for content: AssistantPanelContent) -> CGFloat {
        let h: CGFloat
        switch content {
        case .bar: h = bar
        case .approval: h = approval
        case .blocked: h = blocked
        case .question(let rows): h = questionBase + CGFloat(max(1, rows)) * questionRow
        case .finished(let files): h = finishedBase + CGFloat(min(files, maxFileRows)) * fileRow
        case .diff: h = diff
        }
        return min(h, maxHeight)
    }
}
