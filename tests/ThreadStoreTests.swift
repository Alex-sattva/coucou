import Foundation

// Tests for the harness's in-memory thread bookkeeping (`ThreadStore.swift`) — the type
// that backs the clock popup, the done summary and rewind. Compiles the real source with
// `swiftc` (see `scripts/test-thread-store.sh`), like every other suite in `tests/`.
//
// The store is a `@MainActor` singleton by design (it mirrors live agent state), so the
// whole runner is main-actor isolated.

@main
@MainActor
enum ThreadStoreTests {

    static var failures = 0

    static func checkTrue(_ label: String, _ value: Bool) {
        if value { print("  ✓ \(label)") }
        else      { print("  ✗ \(label)"); failures += 1 }
    }

    static func checkInt(_ label: String, _ got: Int, _ expected: Int) {
        if got == expected { print("  ✓ \(label)") }
        else { print("  ✗ \(label)  got: \(got)  expected: \(expected)"); failures += 1 }
    }

    static func checkString(_ label: String, _ got: String, _ expected: String) {
        if got == expected { print("  ✓ \(label)") }
        else { print("  ✗ \(label)  got: \"\(got)\"  expected: \"\(expected)\""); failures += 1 }
    }

    static func checkOptionalString(_ label: String, _ got: String?, _ expected: String?) {
        if got == expected { print("  ✓ \(label)") }
        else { print("  ✗ \(label)  got: \(String(describing: got))  expected: \(String(describing: expected))"); failures += 1 }
    }

    static func main() {
        let store = ThreadStore.shared

        // ── age() ───────────────────────────────────────────────────────────────
        print("HarnessThread.age")
        do {
            let now = Date()
            func age(_ ago: TimeInterval) -> String {
                HarnessThread(id: "t", workspaceId: "w", title: "x", startedAt: now.addingTimeInterval(-ago),
                              order: 1, isBusy: false, summary: nil, steps: [], stepIndex: 0,
                              hasSnapshot: false).age(from: now)
            }
            checkString("under a minute is 'just now'", age(0), "just now")
            checkString("59 s is still 'just now'", age(59), "just now")
            checkString("a minute and a half is '1m'", age(90), "1m")
            checkString("59 minutes is '59m'", age(59 * 60), "59m")
            checkString("two hours is '2h'", age(2 * 3600), "2h")
            checkString("three days is '3d'", age(3 * 86_400), "3d")
            // A clock that ran backwards must not render "-1m".
            checkString("a future stamp clamps to 'just now'", age(-500), "just now")
        }

        // ── start / active / per-workspace isolation ───────────────────────────
        print("ThreadStore.start")
        do {
            store.removeAll()
            let a = store.start(workspaceId: "a", title: "first")
            checkInt("one thread recorded", store.count(for: "a"), 1)
            checkString("it is the active one", store.activeThread(for: "a")?.id ?? "—", a.id)
            checkString("its title is kept", store.activeThread(for: "a")?.title ?? "—", "first")
            checkTrue("a new thread starts idle", store.activeThread(for: "a")?.isBusy == false)
            checkTrue("a new thread has no snapshot", store.activeThread(for: "a")?.hasSnapshot == false)
            checkString("the default title is 'new session'", store.start(workspaceId: "a").title, "new session")
            checkTrue("the newest thread is first",
                      store.activeThread(for: "a")?.id == store.threads(for: "a").first?.id)

            store.start(workspaceId: "b", title: "other")
            checkInt("workspace b has its own thread", store.count(for: "b"), 1)
            checkInt("workspace a did not gain one", store.count(for: "a"), 2)
            checkString("b's active thread is b's", store.activeThread(for: "b")?.title ?? "—", "other")
            checkTrue("an unknown workspace has no threads", store.threads(for: "zzz").isEmpty)
            checkTrue("an unknown workspace has no active thread", store.activeThread(for: "zzz") == nil)
            checkInt("an unknown workspace counts zero", store.count(for: "zzz"), 0)
        }

        // ── setTitle ───────────────────────────────────────────────────────────
        print("ThreadStore.setTitle")
        do {
            store.removeAll()
            store.start(workspaceId: "a", title: "before")
            store.setTitle("   répare korus  ", workspaceId: "a")
            checkString("it trims", store.activeThread(for: "a")?.title ?? "—", "répare korus")
            store.setTitle(String(repeating: "x", count: 80), workspaceId: "a")
            checkInt("it caps at 60 characters", store.activeThread(for: "a")?.title.count ?? -1, 60)
            store.setTitle("   ", workspaceId: "a")
            checkString("whitespace-only is ignored", store.activeThread(for: "a")?.title ?? "—",
                        String(repeating: "x", count: 60))
            store.setTitle("ignored", workspaceId: "nobody")
            checkTrue("an unknown workspace is a no-op", store.activeThread(for: "nobody") == nil)
        }

        // ── busy / finish ──────────────────────────────────────────────────────
        print("ThreadStore.setBusy / finish")
        do {
            store.removeAll()
            store.start(workspaceId: "a")
            store.setBusy(true, workspaceId: "a")
            checkTrue("setBusy(true) marks the active thread", store.activeThread(for: "a")?.isBusy == true)
            store.finish(workspaceId: "a", summary: "Ran the tests.")
            checkTrue("finishing clears busy", store.activeThread(for: "a")?.isBusy == false)
            checkOptionalString("finishing stores the summary",
                                store.activeThread(for: "a")?.summary, "Ran the tests.")
            store.setBusy(true, workspaceId: "nobody")
            store.finish(workspaceId: "nobody", summary: "x")
            checkTrue("unknown workspaces are no-ops", store.activeThread(for: "nobody") == nil)
        }

        // ── snapshots ──────────────────────────────────────────────────────────
        print("ThreadStore.captureSnapshot")
        do {
            store.removeAll()
            store.start(workspaceId: "a")
            store.captureSnapshot(workspaceId: "a", steps: [], stepIndex: 0)
            checkTrue("an empty trail is not a snapshot", store.activeThread(for: "a")?.hasSnapshot == false)
            store.captureSnapshot(workspaceId: "a", steps: ["one", "two"], stepIndex: 1)
            checkTrue("a real trail is a snapshot", store.activeThread(for: "a")?.hasSnapshot == true)
            checkInt("the trail is stored", store.activeThread(for: "a")?.steps.count ?? -1, 2)
            checkInt("the index is stored", store.activeThread(for: "a")?.stepIndex ?? -1, 1)
        }

        // ── search ─────────────────────────────────────────────────────────────
        print("ThreadStore.search")
        do {
            store.removeAll()
            store.start(workspaceId: "a", title: "répare korus")
            store.start(workspaceId: "a", title: "fix the island")
            store.start(workspaceId: "b", title: "répare korus")
            checkInt("an empty query returns every thread", store.search("", workspaceId: "a").count, 2)
            checkInt("it matches a title", store.search("island", workspaceId: "a").count, 1)
            checkInt("it is case-insensitive", store.search("ISLAND", workspaceId: "a").count, 1)
            checkInt("it ignores diacritics", store.search("repare", workspaceId: "a").count, 1)
            checkInt("it ignores diacritics the other way", store.search("KORÙS", workspaceId: "a").count, 1)
            checkInt("it is scoped to the workspace", store.search("korus", workspaceId: "b").count, 1)
            checkInt("a miss returns nothing", store.search("zephyr", workspaceId: "a").count, 0)
            checkInt("a whitespace query returns everything", store.search("   ", workspaceId: "a").count, 2)
        }

        // ── rewind ─────────────────────────────────────────────────────────────
        print("ThreadStore.rewind")
        do {
            store.removeAll()
            store.start(workspaceId: "a", title: "no snapshot here")
            checkTrue("rewind with no snapshot returns nil", store.rewind(workspaceId: "a") == nil)

            let old = store.start(workspaceId: "a", title: "with a trail")
            store.captureSnapshot(workspaceId: "a", steps: ["compiled"], stepIndex: 0)
            store.start(workspaceId: "a", title: "newer, no trail")
            checkString("the newer thread is active first",
                        store.activeThread(for: "a")?.title ?? "—", "newer, no trail")
            let restored = store.rewind(workspaceId: "a")
            checkString("rewind hands back the snapshot thread", restored?.id ?? "—", old.id)
            checkString("and promotes it back to active",
                        store.activeThread(for: "a")?.id ?? "—", old.id)
            checkTrue("a restored thread is not busy", store.activeThread(for: "a")?.isBusy == false)
            checkInt("the other thread is still there", store.count(for: "a"), 3)
            checkTrue("rewind ignores other workspaces", store.rewind(workspaceId: "b") == nil)

            // The popup draws a rewind chip on every row that has a snapshot, so picking an
            // older row has to restore THAT row rather than silently jump to the newest one.
            store.removeAll()
            let first = store.start(workspaceId: "a", title: "first")
            store.captureSnapshot(workspaceId: "a", steps: ["one"], stepIndex: 0)
            let second = store.start(workspaceId: "a", title: "second")
            store.captureSnapshot(workspaceId: "a", steps: ["one", "two"], stepIndex: 1)
            checkString("rewind without an id takes the newest snapshot",
                        store.rewind(workspaceId: "a")?.id ?? "—", second.id)
            checkString("rewind with an id takes that row",
                        store.rewind(workspaceId: "a", threadId: first.id)?.id ?? "—", first.id)
            checkString("and promotes the picked row back to active",
                        store.activeThread(for: "a")?.id ?? "—", first.id)
            checkTrue("an unknown row restores nothing",
                      store.rewind(workspaceId: "a", threadId: "thread-999") == nil)
        }

        // ── prune ──────────────────────────────────────────────────────────────
        print("ThreadStore.prune")
        do {
            store.removeAll()
            let cap = ThreadStore.maxThreadsPerWorkspace
            checkInt("the cap is 20", cap, 20)
            for i in 0..<(cap + 5) { store.start(workspaceId: "a", title: "t\(i)") }
            checkInt("it keeps only the cap", store.count(for: "a"), cap)
            checkString("the newest survives", store.activeThread(for: "a")?.title ?? "—", "t\(cap + 4)")
            checkTrue("the oldest is dropped",
                      store.threads(for: "a").contains { $0.title == "t0" } == false)
            checkTrue("the second oldest is dropped too",
                      store.threads(for: "a").contains { $0.title == "t4" } == false)
            checkTrue("the first survivor is kept",
                      store.threads(for: "a").contains { $0.title == "t5" })
            store.start(workspaceId: "b", title: "b0")
            checkInt("pruning one workspace leaves the other alone", store.count(for: "b"), 1)
        }

        // ── removeAll ──────────────────────────────────────────────────────────
        print("ThreadStore.removeAll")
        do {
            store.start(workspaceId: "a")
            store.start(workspaceId: "b")
            store.removeAll()
            checkTrue("everything is forgotten", store.threads.isEmpty)
            checkInt("and the ids restart", store.start(workspaceId: "a").id == "thread-1" ? 1 : 0, 1)
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
