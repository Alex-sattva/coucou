import Combine
import Foundation

// MARK: - Thread

/// One conversation thread with a workspace.
///
/// Coucou has no thread or checkpoint type today — `AgentTask` only ever holds the
/// *current* session (`IslandTypes.swift:49`). The harness keeps its thread history
/// here, **in memory only**: nothing is persisted to disk yet, and rewind restores
/// nothing deeper than the snapshot it took, so it can never resurrect a dead process.
struct HarnessThread: Identifiable, Equatable, Sendable {
    let id: String
    let workspaceId: String
    var title: String
    var startedAt: Date
    /// Monotonic ordering key. The store bumps it whenever a thread is touched, so
    /// "newest first" stays deterministic even for threads started in the same tick.
    var order: Int
    var isBusy: Bool
    /// The agent's one-liner when the run finished — this is what the done summary shows.
    var summary: String?
    /// The step trail captured the last time this thread was live.
    var steps: [String]
    var stepIndex: Int
    /// `true` once a snapshot exists, so rewind has something to restore.
    var hasSnapshot: Bool

    /// "just now" / "12m" / "3h" — the history popup's age column.
    func age(from now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(startedAt))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h" }
        return "\(Int(seconds / 86_400))d"
    }
}

// MARK: - Store

/// In-memory thread history, one list per workspace.
///
/// Presentation and bookkeeping only: it records what the harness has seen of the
/// live `AgentTask` trail and never owns or duplicates the agent's real state.
@MainActor
final class ThreadStore: ObservableObject {
    static let shared = ThreadStore()

    /// How many threads each workspace keeps before the oldest are dropped.
    static let maxThreadsPerWorkspace = 20

    @Published private(set) var threads: [HarnessThread] = []

    private var sequence = 0

    private init() {}

    // MARK: Reading

    /// The workspace's threads, newest first.
    func threads(for workspaceId: String) -> [HarnessThread] {
        threads
            .filter { $0.workspaceId == workspaceId }
            .sorted { $0.order > $1.order }
    }

    /// The thread the workspace is currently on.
    func activeThread(for workspaceId: String) -> HarnessThread? {
        threads(for: workspaceId).first
    }

    /// The history popup's search field. Matches on title, diacritic-insensitively.
    func search(_ query: String, workspaceId: String) -> [HarnessThread] {
        let all = threads(for: workspaceId)
        let needle = KeywordRouter.normalize(query).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return all }
        return all.filter { KeywordRouter.normalize($0.title).contains(needle) }
    }

    func count(for workspaceId: String) -> Int {
        threads.filter { $0.workspaceId == workspaceId }.count
    }

    // MARK: Writing

    /// Starts a new thread for a workspace and makes it active.
    @discardableResult
    func start(workspaceId: String, title: String = "new session", at date: Date = Date()) -> HarnessThread {
        setBusy(false, workspaceId: workspaceId)
        let thread = HarnessThread(
            id: nextId(),
            workspaceId: workspaceId,
            title: title,
            startedAt: date,
            order: nextOrder(),
            isBusy: false,
            summary: nil,
            steps: [],
            stepIndex: 0,
            hasSnapshot: false
        )
        threads.append(thread)
        prune(workspaceId)
        return thread
    }

    /// Renames the active thread — used for the first line of the first prompt.
    func setTitle(_ title: String, workspaceId: String) {
        guard var thread = activeThread(for: workspaceId) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        thread.title = String(trimmed.prefix(60))
        replace(thread)
    }

    /// Records the live step trail. Called while the agent runs.
    func captureSnapshot(workspaceId: String, steps: [String], stepIndex: Int) {
        guard var thread = activeThread(for: workspaceId) else { return }
        thread.steps = steps
        thread.stepIndex = stepIndex
        thread.hasSnapshot = !steps.isEmpty
        replace(thread, bumpOrder: false)
    }

    func setBusy(_ busy: Bool, workspaceId: String) {
        guard var thread = activeThread(for: workspaceId) else { return }
        thread.isBusy = busy
        replace(thread, bumpOrder: false)
    }

    /// The run finished: store the one-liner the done summary shows.
    func finish(workspaceId: String, summary: String?) {
        guard var thread = activeThread(for: workspaceId) else { return }
        thread.isBusy = false
        thread.summary = summary
        replace(thread, bumpOrder: false)
    }

    /// Rewind is pinned to "restore the workspace's most recent thread snapshot":
    /// it promotes that thread back to active and hands back its trail for the UI to
    /// show. Deep checkpoint/restore is deliberately out of scope.
    @discardableResult
    func rewind(workspaceId: String, threadId: String? = nil) -> HarnessThread? {
        let candidates = threads(for: workspaceId).filter { $0.hasSnapshot }
        // The popup draws a rewind chip on EVERY row that has a snapshot, so tapping row three
        // must not silently restore row one. No id means the workspace's most recent snapshot,
        // which is the pinned behaviour and what the `+`/run path uses.
        let match: HarnessThread?
        if let threadId {
            match = candidates.first { $0.id == threadId }
        } else {
            match = candidates.first
        }
        guard let match else { return nil }
        var moved = match
        moved.isBusy = false
        // `replace` bumps `order` itself (it is the default), which is what puts the thread the
        // user just rewound back at the top of the popup's list — a separate bump here would be
        // a dead second one.
        replace(moved)
        return moved
    }

    /// Forgets everything. In-memory by design, so this is the only teardown there is.
    func removeAll() {
        threads.removeAll()
        sequence = 0
    }

    // MARK: Internals

    private func nextId() -> String {
        sequence += 1
        return "thread-\(sequence)"
    }

    private func nextOrder() -> Int {
        sequence += 1
        return sequence
    }

    private func replace(_ thread: HarnessThread, bumpOrder: Bool = true) {
        guard let index = threads.firstIndex(where: { $0.id == thread.id }) else { return }
        var updated = thread
        if bumpOrder { updated.order = nextOrder() }
        threads[index] = updated
    }

    private func prune(_ workspaceId: String) {
        let mine = threads(for: workspaceId)
        guard mine.count > Self.maxThreadsPerWorkspace else { return }
        let doomed = Set(mine.dropFirst(Self.maxThreadsPerWorkspace).map(\.id))
        threads.removeAll { doomed.contains($0.id) }
    }
}
