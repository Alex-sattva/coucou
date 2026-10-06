import Foundation

// MARK: - Workspace reference

/// One routable target: a workspace the user can talk to.
///
/// The harness builds this from `PillCatalog.all` joined to the live `AgentTask`
/// roster — `id` is the pill id (the stable contract value), `folder` is the task's
/// `sessionCwd`. `isMain` marks the orchestrator chip, which owns no folder.
struct WorkspaceRef: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let color: String
    let folder: String?
    let isMain: Bool

    init(id: String, name: String, color: String, folder: String? = nil, isMain: Bool = false) {
        self.id = id
        self.name = name
        self.color = color
        self.folder = folder
        self.isMain = isMain
    }
}

// MARK: - Route result

/// The outcome of routing one utterance.
///
/// `confidence` is 0…1. The harness must ask the user to pick rather than act on a
/// result below `RouteResult.askThreshold` — a tie is deliberately clamped below it,
/// so an ambiguous utterance can never silently choose a workspace.
struct RouteResult: Equatable, Sendable {
    let workspaceId: String
    let confidence: Double

    /// Nothing to route to, or nothing matched.
    static let none = RouteResult(workspaceId: "", confidence: 0)

    /// Below this the caller asks instead of guessing.
    static let askThreshold: Double = 0.55

    var isConfident: Bool { !workspaceId.isEmpty && confidence >= RouteResult.askThreshold }
    var shouldAsk: Bool { !isConfident }
}

// MARK: - Routing contract

/// Decides which workspace an utterance is for.
protocol WorkspaceRouting: Sendable {
    func route(_ utterance: String, candidates: [WorkspaceRef]) -> RouteResult
}

// MARK: - Deterministic keyword router

/// The shipping router: deterministic, pure, and unit-tested.
///
/// It scores every candidate on the words the user actually said — the workspace's
/// display name, the names its folder gives it, and an explicit "main" mention — and
/// returns the best score. No network, no model, no guessing: a low score or a tie
/// comes back below `RouteResult.askThreshold` so the harness can ask.
///
/// `JevRouter` (a shell-out to the prototype's `jev` classifier) is deliberately not
/// implemented yet; when it lands it conforms to this same protocol.
struct KeywordRouter: WorkspaceRouting {

    func route(_ utterance: String, candidates: [WorkspaceRef]) -> RouteResult {
        guard !candidates.isEmpty else { return .none }

        let haystack = KeywordRouter.normalize(utterance)
        guard !haystack.isEmpty else { return .none }

        let said = Set(
            haystack.split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
        )
        guard !said.isEmpty else { return .none }

        var bestIndex = 0
        var scores: [Double] = []
        scores.reserveCapacity(candidates.count)
        for (index, ref) in candidates.enumerated() {
            let score = KeywordRouter.score(ref, haystack: haystack, said: said)
            scores.append(score)
            // Strict `>` keeps the first candidate on a tie, so the pick is stable
            // and follows the roster's own order rather than dictionary ordering.
            if score > scores[bestIndex] { bestIndex = index }
        }

        guard scores[bestIndex] > 0 else { return .none }

        let best = scores[bestIndex]
        let isTied = scores.filter { abs($0 - best) < 0.0001 }.count > 1
        let confidence = isTied ? min(best, RouteResult.askThreshold - 0.01) : min(1, best)
        return RouteResult(workspaceId: candidates[bestIndex].id, confidence: confidence)
    }

    // MARK: Scoring

    /// How strongly `ref` is named by the utterance. 0 means "not at all".
    ///
    /// Weights are chosen so that one *distinctive* word is enough to route
    /// ("…in korus" → korus) while one generic short word is not ("fix the app"
    /// must not silently pick `coucou-app`). A name and a folder that spell the same
    /// project count once, not twice.
    static func score(_ ref: WorkspaceRef, haystack: String, said: Set<String>) -> Double {
        var score = 0.0

        let name = normalize(ref.name)
        let folderName = ref.folder.map { normalize(($0 as NSString).lastPathComponent) } ?? ""
        let words = canonical(haystack)

        // 1. The whole name — or the folder's own name — appearing as WORDS, not as an
        //    arbitrary substring. A raw `contains` is wrong here: it lets "finish the
        //    remaining tasks" address `Main` and "wrap the apple" address a folder called
        //    `app`, both at full confidence, so an ambiguous utterance would route
        //    silently instead of asking.
        var verbatim = 0.0
        if name.count >= 3, words.contains(canonical(name)) { verbatim = 0.85 }
        if folderName.count >= 3, words.contains(canonical(folderName)) { verbatim = max(verbatim, 0.80) }
        score += verbatim

        // 2. The words the workspace is known by. Length stands in for how
        //    distinctive a word is; the total is capped so a pile of weak hits
        //    still cannot outrank a real name.
        var tokenScore = 0.0
        for token in Set(tokens(of: ref.name)).union(tokens(of: ref.folder ?? "")) where said.contains(token) {
            tokenScore += tokenWeight(token)
        }
        score += min(0.75, tokenScore)

        // 3. An explicit address ("~/code/x", "./x", a path) is a deliberate reference.
        if ref.folder != nil, haystack.contains("~") || haystack.contains("/") { score += 0.10 }

        // 4. Talking to the orchestrator by name.
        if ref.isMain, said.contains("main") { score += 0.5 }

        return score
    }

    /// How much a single matched word is worth, by how distinctive its length makes it.
    static func tokenWeight(_ token: String) -> Double {
        switch token.count {
        case 6...: return 0.60
        case 5:    return 0.55
        case 4:    return 0.35
        default:   return 0.20
        }
    }

    // MARK: Text normalisation

    /// Lower-cases and strips diacritics, so French ("répare le bug dans korùs")
    /// matches the same workspace as English.
    static func normalize(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .widthInsensitive],
                     locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
    }

    /// The searchable words inside `text`: alphanumerics only, three characters up.
    static func tokens(of text: String) -> [String] {
        normalize(text)
            .split(whereSeparator: { !($0.isLetter || $0.isNumber) })
            .map(String.init)
            .filter { $0.count >= 3 }
    }

    /// The haystack reduced to space-separated words and padded at both ends, so a name can
    /// be tested on whole words: `" remaining tasks "` does **not** contain `" main "`, while
    /// a hyphenated name (`"coucou-app"` → `" coucou app "`) still matches however it was
    /// typed. Both sides go through this, so the comparison is word-for-word.
    static func canonical(_ text: String) -> String {
        let body = normalize(text)
            .split(whereSeparator: { !($0.isLetter || $0.isNumber) })
            .joined(separator: " ")
        return " " + body + " "
    }
}
