import Foundation

// Pure, Foundation-only. Compiled standalone by scripts/test-pending-requests.sh — keep AppKit/SwiftUI out.
//
// A keyed container for hook requests that are waiting on the user (permission requests and
// AskUserQuestion). One entry per session id: a decision for session A can only ever reach A's entry,
// so it can never be written to session B's socket. `HookServer` keeps the held file descriptors in
// one of these (`Value` carries the fd); the arrival order decides which request the single-card
// views show ("oldest first").

struct PendingRequests<Value> {
    struct Entry {
        var value: Value
        /// When the request arrived. The oldest request is the one the UI shows first.
        let arrivedAt: Date
        /// Monotonic insertion counter. Breaks ties between equal `arrivedAt` and lets a timer
        /// tell "my entry" from a newer entry that reused the same session id.
        let seq: Int
    }

    private(set) var entries: [String: Entry] = [:]
    private var nextSeq = 0

    var isEmpty: Bool { entries.isEmpty }
    var count: Int { entries.count }

    func contains(sessionId: String) -> Bool { entries[sessionId] != nil }
    func entry(for sessionId: String) -> Entry? { entries[sessionId] }

    /// Adds the request for `sessionId`. When the session already had one, that previous entry is
    /// returned so the caller can close it (a session has one request at a time).
    @discardableResult
    mutating func insert(_ value: Value, sessionId: String, now: Date) -> Entry? {
        let replaced = entries[sessionId]
        entries[sessionId] = Entry(value: value, arrivedAt: now, seq: nextSeq)
        nextSeq += 1
        return replaced
    }

    /// Removes and returns only that session's entry. Unknown session: nil, nothing else changes.
    @discardableResult
    mutating func remove(sessionId: String) -> Entry? {
        entries.removeValue(forKey: sessionId)
    }

    /// The request that has been waiting the longest.
    func oldest() -> (sessionId: String, entry: Entry)? {
        orderedOldestFirst().first
    }

    func orderedOldestFirst() -> [(sessionId: String, entry: Entry)] {
        entries
            .map { (sessionId: $0.key, entry: $0.value) }
            .sorted {
                if $0.entry.arrivedAt != $1.entry.arrivedAt { return $0.entry.arrivedAt < $1.entry.arrivedAt }
                return $0.entry.seq < $1.entry.seq
            }
    }
}

/// "Oldest" for plain dictionaries keyed by session id (what `AppState` publishes).
enum PendingOrder {
    /// The item with the earliest `arrivedAt`; equal times fall back to the smaller session id so
    /// the answer never depends on dictionary ordering.
    static func oldest<T>(_ items: [String: T], arrivedAt: (T) -> Date) -> (sessionId: String, item: T)? {
        var best: (sessionId: String, item: T)? = nil
        for (id, item) in items {
            guard let current = best else { best = (id, item); continue }
            let a = arrivedAt(item), b = arrivedAt(current.item)
            if a < b || (a == b && id < current.sessionId) { best = (id, item) }
        }
        return best
    }
}
