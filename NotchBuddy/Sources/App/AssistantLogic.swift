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
