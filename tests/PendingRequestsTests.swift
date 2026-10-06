import Foundation

// Standalone tests for PendingRequests.swift (see scripts/test-pending-requests.sh).

@main
@MainActor
enum PendingRequestsTests {
    static var failures = 0

    static func check(_ cond: Bool, _ msg: String) {
        if cond { print("  ✓ \(msg)") } else { print("  ✗ \(msg)"); failures += 1 }
    }

    static let t0 = Date(timeIntervalSince1970: 1_000)
    static func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    static func main() {
        // Empty
        do {
            let p = PendingRequests<Int>()
            check(p.isEmpty && p.count == 0, "starts empty")
            check(p.oldest() == nil, "no oldest when empty")
        }

        // Oldest follows arrival, not session id or insertion into the dictionary
        do {
            var p = PendingRequests<String>()
            p.insert("b", sessionId: "B", now: at(1))
            p.insert("a", sessionId: "A", now: at(2))
            p.insert("c", sessionId: "C", now: at(3))
            check(p.oldest()?.sessionId == "B", "oldest is B")
            check(p.orderedOldestFirst().map { $0.sessionId } == ["B", "A", "C"], "arrival order")
        }

        // Equal timestamps: insertion order wins
        do {
            var p = PendingRequests<Int>()
            p.insert(1, sessionId: "Z", now: at(5))
            p.insert(2, sessionId: "A", now: at(5))
            check(p.oldest()?.sessionId == "Z", "tie broken by insertion order")
        }

        // Removing one session leaves the others untouched
        do {
            var p = PendingRequests<Int>()
            p.insert(1, sessionId: "A", now: at(1))
            p.insert(2, sessionId: "B", now: at(2))
            let removed = p.remove(sessionId: "A")
            check(removed?.value == 1, "removed A's value")
            check(!p.contains(sessionId: "A") && p.contains(sessionId: "B"), "only A removed")
            check(p.oldest()?.sessionId == "B", "B is now oldest")
            check(p.remove(sessionId: "A") == nil, "second removal is a no-op")
            check(p.remove(sessionId: "nope") == nil, "unknown session is a no-op")
            check(p.count == 1, "B still held")
        }

        // Routing: each session id maps to its own value (decision for A never reaches B's fd)
        do {
            var p = PendingRequests<Int32>()
            p.insert(10, sessionId: "A", now: at(1))
            p.insert(20, sessionId: "B", now: at(2))
            check(p.entry(for: "A")?.value == 10, "A -> fd 10")
            check(p.entry(for: "B")?.value == 20, "B -> fd 20")
            check(p.remove(sessionId: "B")?.value == 20, "removing B yields B's fd")
            check(p.entry(for: "A")?.value == 10, "A still maps to fd 10")
        }

        // Same session again: previous entry is handed back, new one has a newer seq
        do {
            var p = PendingRequests<Int>()
            p.insert(1, sessionId: "A", now: at(1))
            let firstSeq = p.entry(for: "A")!.seq
            let replaced = p.insert(2, sessionId: "A", now: at(2))
            check(replaced?.value == 1, "replaced entry returned")
            check(p.count == 1 && p.entry(for: "A")?.value == 2, "one entry per session")
            check(p.entry(for: "A")!.seq > firstSeq, "seq grows so stale timers can be told apart")
        }

        // PendingOrder on plain dictionaries
        do {
            let items: [String: Date] = ["B": at(1), "A": at(1), "C": at(0.5)]
            check(PendingOrder.oldest(items, arrivedAt: { $0 })?.sessionId == "C", "earliest date wins")
            let tie: [String: Date] = ["B": at(1), "A": at(1)]
            check(PendingOrder.oldest(tie, arrivedAt: { $0 })?.sessionId == "A", "tie -> smaller id")
            let none: [String: Date] = [:]
            check(PendingOrder.oldest(none, arrivedAt: { $0 }) == nil, "empty -> nil")
        }


        print("")
        if failures == 0 {
            print("All tests passed.")
        } else {
            print("\(failures) test(s) failed.")
            exit(1)
        }
    }
}
