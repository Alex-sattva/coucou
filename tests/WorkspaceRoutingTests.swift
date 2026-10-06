import Foundation

@main
@MainActor
enum WorkspaceRoutingTests {

    static var failures = 0

    static func checkTrue(_ label: String, _ value: Bool) {
        if value { print("  ✓ \(label)") }
        else      { print("  ✗ \(label)"); failures += 1 }
    }

    static func checkString(_ label: String, _ got: String, _ expected: String) {
        if got == expected { print("  ✓ \(label)") }
        else { print("  ✗ \(label)  got: \(got)  expected: \(expected)"); failures += 1 }
    }

    static func checkClose(_ label: String, _ got: Double, _ expected: Double, tol: Double = 0.0001) {
        if abs(got - expected) <= tol { print("  ✓ \(label)") }
        else { print("  ✗ \(label)  got: \(got)  expected: \(expected)"); failures += 1 }
    }

    /// A workspace the way the harness builds one: id is the pill id, name is the
    /// folder's last component when there is a folder, else the pill's own name.
    static func ws(_ id: String, _ name: String, folder: String? = nil, main: Bool = false) -> WorkspaceRef {
        WorkspaceRef(id: id, name: name, color: "#FFFFFF", folder: folder, isMain: main)
    }

    static func main() {

        let router = KeywordRouter()

        // ── WorkspaceRef defaults ─────────────────────────────────────────────
        print("WorkspaceRef")
        do {
            let ref = WorkspaceRef(id: "a", name: "Alpha", color: "#FFF")
            checkTrue("folder defaults to nil", ref.folder == nil)
            checkTrue("isMain defaults to false", ref.isMain == false)
            checkTrue("id is the pill id", ref.id == "a")
        }

        // ── RouteResult ───────────────────────────────────────────────────────
        print("RouteResult")
        do {
            checkString(".none has no workspace", RouteResult.none.workspaceId, "")
            checkClose(".none confidence is 0", RouteResult.none.confidence, 0)
            checkTrue(".none should ask", RouteResult.none.shouldAsk)
            checkTrue(".none is not confident", !RouteResult.none.isConfident)

            let exact = RouteResult(workspaceId: "a", confidence: RouteResult.askThreshold)
            checkTrue("exactly at the threshold is confident", exact.isConfident)

            let under = RouteResult(workspaceId: "a", confidence: RouteResult.askThreshold - 0.001)
            checkTrue("just under the threshold asks", under.shouldAsk)

            let empty = RouteResult(workspaceId: "", confidence: 1.0)
            checkTrue("a perfect score with no workspace still asks", empty.shouldAsk)
        }

        // ── normalize ─────────────────────────────────────────────────────────
        print("KeywordRouter.normalize")
        do {
            checkString("diacritics stripped", KeywordRouter.normalize("Korùs-API"), "korus-api")
            checkString("French accents stripped", KeywordRouter.normalize("Réparé"), "repare")
            checkString("case folded", KeywordRouter.normalize("KORUS"), "korus")
            checkString("width folded", KeywordRouter.normalize("ＴＯＫＹＯ"), "tokyo")
            checkString("already normal is unchanged", KeywordRouter.normalize("korus"), "korus")
        }

        // ── tokens ────────────────────────────────────────────────────────────
        print("KeywordRouter.tokens")
        do {
            let t = Set(KeywordRouter.tokens(of: "in coucou-app the login"))
            checkTrue("drops words shorter than three", !t.contains("in"))
            checkTrue("splits on the hyphen", t.contains("coucou") && t.contains("app"))
            checkTrue("keeps three-letter words", t.contains("the"))
            checkTrue("keeps long words", t.contains("login"))
            checkTrue("accented words normalise", Set(KeywordRouter.tokens(of: "Réparé")).contains("repare"))
            checkTrue("punctuation only yields nothing", KeywordRouter.tokens(of: "  ---  ").isEmpty)
        }

        // ── Empty input ───────────────────────────────────────────────────────
        print("route — nothing to route")
        do {
            let r1 = router.route("fix the login bug", candidates: [])
            checkString("no candidates → .none", r1.workspaceId, "")
            checkClose("no candidates → confidence 0", r1.confidence, 0)
            checkTrue("no candidates → should ask", r1.shouldAsk)

            let r2 = router.route("", candidates: [ws("a", "Alpha")])
            checkTrue("empty utterance → .none", r2.workspaceId == "")

            let r3 = router.route("   ...   ", candidates: [ws("a", "Alpha")])
            checkTrue("punctuation-only utterance → .none", r3.workspaceId == "")

            let r4 = router.route("what is the weather", candidates: [ws("a", "korus")])
            checkTrue("no keyword match → .none", r4.workspaceId == "")
        }

        // ── The whole name, verbatim ──────────────────────────────────────────
        print("route — verbatim name")
        do {
            let r = router.route("in coucou-app the login button hangs",
                                 candidates: [ws("coucou", "coucou-app", folder: "/Users/x/code/coucou-app")])
            checkString("picks the named workspace", r.workspaceId, "coucou")
            checkTrue("is confident", r.isConfident)
            checkTrue("confidence never exceeds 1", r.confidence <= 1.0)

            let upper = router.route("KORUS is broken", candidates: [ws("k", "korus")])
            checkString("matching is case-insensitive", upper.workspaceId, "k")
            checkTrue("uppercase name is confident", upper.isConfident)
        }

        // ── One distinctive word is enough ────────────────────────────────────
        print("route — distinctive word")
        do {
            let r = router.route("répare le bug dans korùs",
                                 candidates: [ws("k", "korus-api", folder: "/Users/x/code/korus-api")])
            checkString("French, accented, one word", r.workspaceId, "k")
            checkTrue("a distinctive word routes confidently", r.isConfident)
        }

        // ── One generic word is not ───────────────────────────────────────────
        print("route — generic word asks instead")
        do {
            let r = router.route("fix the app", candidates: [ws("coucou", "coucou-app", folder: "/Users/x/code/coucou-app")])
            checkTrue("a three-letter hit does not route silently", r.shouldAsk)
        }

        // ── Ties ──────────────────────────────────────────────────────────────
        print("route — ties")
        do {
            let candidates = [ws("a", "korus"), ws("b", "vegaa")]
            let r = router.route("compare korus with vegaa", candidates: candidates)
            checkString("a tie names the first candidate (stable roster order)", r.workspaceId, "a")
            checkTrue("a tie never crosses the ask threshold", r.shouldAsk)
            checkTrue("tie confidence sits just below the threshold", r.confidence < RouteResult.askThreshold)

            // Same tie, reversed roster: the pick follows the order it was given.
            let flipped = router.route("compare korus with vegaa", candidates: [ws("b", "vegaa"), ws("a", "korus")])
            checkString("the tie-break follows the caller's order", flipped.workspaceId, "b")

            let both = router.route("compare korus with vegaa", candidates: [ws("a", "korus"), ws("b", "vegaa")])
            checkString("naming both keeps the stable pick", both.workspaceId, "a")
            checkTrue("naming both asks rather than guessing", both.shouldAsk)

            let resolved = router.route("korus is broken, the app too",
                                        candidates: [ws("a", "korus"), ws("b", "coucou-app")])
            checkString("a real name beats a generic word", resolved.workspaceId, "a")
            checkTrue("and that pick is confident", resolved.isConfident)
        }

        // ── The folder ────────────────────────────────────────────────────────
        print("route — folders")
        do {
            let path = router.route("run it in ~/code/korus-api",
                                    candidates: [ws("k", "korus-api", folder: "/Users/x/code/korus-api")])
            checkString("an explicit path routes", path.workspaceId, "k")
            checkTrue("an explicit path is confident", path.isConfident)

            let missing = ws("g", "gone", folder: "/Users/x/code/zzz-missing")
            let byName = router.route("gone is broken", candidates: [missing])
            checkString("a workspace whose folder no longer matches still routes by name", byName.workspaceId, "g")

            let noFolder = router.route("alpha please", candidates: [ws("a", "Alpha")])
            checkString("a workspace with no folder routes by name", noFolder.workspaceId, "a")

            let truncated = router.route("the gamm project", candidates: [ws("g", "gamma", folder: "/Users/x/code/gamma")])
            checkString("a truncated word does not match a workspace", truncated.workspaceId, "")
            checkTrue("and the harness asks instead", truncated.shouldAsk)

            let partial = router.route("maybe gamma?", candidates: [ws("g", "gamma", folder: "/Users/x/code/gamma")])
            checkString("a name mentioned with punctuation still matches", partial.workspaceId, "g")
        }

        // ── Main ──────────────────────────────────────────────────────────────
        print("route — Main")
        do {
            let candidates = [ws("main", "Main", main: true), ws("k", "korus", folder: "/Users/x/code/korus")]
            let m = router.route("main what is the status", candidates: candidates)
            checkString("Main catches a direct address", m.workspaceId, "main")
            checkTrue("Main is confident", m.isConfident)

            let single = router.route("main", candidates: [ws("main", "Main", main: true)])
            checkString("'main' alone routes to Main", single.workspaceId, "main")

            let notMain = router.route("korus is leaking memory", candidates: candidates)
            checkString("a workspace still wins over Main", notMain.workspaceId, "k")

            // Word-boundary matching: a name that merely CONTAINS "main" must not address
            // Main, or "remaining"/"domain" would route silently at full confidence.
            let remaining = router.route("finish the remaining tasks", candidates: candidates)
            checkString("'remaining' does not address Main", remaining.workspaceId, "")
            checkTrue("and the harness asks", remaining.shouldAsk)

            let domain = router.route("the domain logic is broken", candidates: candidates)
            checkString("'domain' does not address Main", domain.workspaceId, "")
            checkTrue("and the harness asks", domain.shouldAsk)

            let maintain = router.route("maintain the wrapper", candidates: candidates)
            checkString("'maintain' does not address Main", maintain.workspaceId, "")
            checkTrue("and the harness asks", maintain.shouldAsk)
        }

        // ── Word boundaries for folder names ─────────────────────────────────
        print("route — folder name boundaries")
        do {
            let app = ws("a", "alpha", folder: "/Users/x/code/app")
            let apple = router.route("wrap the apple", candidates: [app])
            checkString("'apple' does not match a folder called app", apple.workspaceId, "")
            checkTrue("and the harness asks", apple.shouldAsk)

            let wrapped = router.route("the wrapper is fine", candidates: [app])
            checkString("'wrapper' does not match a folder called app", wrapped.workspaceId, "")

            let exact = router.route("rebuild app please", candidates: [app])
            checkString("but the folder's own word still matches", exact.workspaceId, "a")
            checkTrue("and that is confident", exact.isConfident)
        }

        // ── canonical ─────────────────────────────────────────────────────────
        print("KeywordRouter.canonical")
        do {
            checkString("pads and splits", KeywordRouter.canonical("In Coucou-App!"), " in coucou app ")
            checkString("hyphens become spaces", KeywordRouter.canonical("korus-api"), " korus api ")
            checkString("diacritics folded", KeywordRouter.canonical("Korùs"), " korus ")
            checkTrue("'remaining tasks' does not contain ' main '",
                      !KeywordRouter.canonical("remaining tasks").contains(KeywordRouter.canonical("Main")))
            checkTrue("'main issue' does contain ' main '",
                      KeywordRouter.canonical("main issue").contains(KeywordRouter.canonical("Main")))
        }

        // ── Picking between several ───────────────────────────────────────────
        print("route — several candidates")
        do {
            let candidates = [
                ws("coucou", "coucou", folder: "/Users/x/code/coucou"),
                ws("korus", "korus", folder: "/Users/x/code/korus"),
                ws("brief", "morning-ai-brief", folder: "/Users/x/code/morning-ai-brief")
            ]
            let r = router.route("add a test to korus", candidates: candidates)
            checkString("picks the strongest match", r.workspaceId, "korus")
            checkTrue("and is confident about it", r.isConfident)

            let longest = router.route("the morning-ai-brief is stale", candidates: candidates)
            checkString("a hyphenated name matches verbatim", longest.workspaceId, "brief")

            let all = [ws("a", "korus"), ws("b", "vegaa"), ws("c", "zephyr")]
            let unrelated = router.route("something else entirely", candidates: all)
            checkString("an unrelated utterance routes nowhere", unrelated.workspaceId, "")
        }

        // ── score ─────────────────────────────────────────────────────────────
        print("KeywordRouter.score")
        do {
            let said: Set<String> = ["korus"]
            let strong = KeywordRouter.score(ws("k", "korus"), haystack: "korus", said: said)
            checkTrue("a verbatim name scores well above the threshold", strong >= RouteResult.askThreshold)

            let weak = KeywordRouter.score(ws("c", "coucou-app"), haystack: "the app", said: ["app", "the"])
            checkTrue("a short generic hit scores below the threshold", weak < RouteResult.askThreshold)

            let none = KeywordRouter.score(ws("k", "korus"), haystack: "weather", said: ["weather"])
            checkClose("no evidence scores 0", none, 0)
        }

        // ── token weight ordering ─────────────────────────────────────────────
        print("KeywordRouter.tokenWeight")
        do {
            checkTrue("longer words weigh more",
                      KeywordRouter.tokenWeight("zephyr") > KeywordRouter.tokenWeight("korus"))
            checkTrue("korus outweighs a four-letter word",
                      KeywordRouter.tokenWeight("korus") > KeywordRouter.tokenWeight("vega"))
            checkTrue("a four-letter word outweighs a three-letter one",
                      KeywordRouter.tokenWeight("vega") > KeywordRouter.tokenWeight("app"))
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
