import Foundation

@main
@MainActor
enum AssistantLogicTests {

    static var failures = 0

    static func checkTrue(_ label: String, _ value: Bool) {
        if value { print("  ✓ \(label)") }
        else      { print("  ✗ \(label)"); failures += 1 }
    }

    static func checkEq<T: Equatable>(_ label: String, _ got: T, _ expected: T) {
        if got == expected { print("  ✓ \(label)") }
        else { print("  ✗ \(label)  got: \(got)  expected: \(expected)"); failures += 1 }
    }

    static let t0 = Date(timeIntervalSince1970: 1_000_000)
    static func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    static func sess(_ id: String, workspace: String = "ws", phase: SessionPhase = .working,
                     attention: TimeInterval? = nil, last: TimeInterval = 0,
                     seen: Bool = false) -> AgentSession {
        AgentSession(id: id, kind: .claudeCode, cwd: "/code/\(workspace)", workspace: workspace,
                     colorHex: "#FFFFFF", phase: phase, steps: [], lastPrompt: nil, reply: nil,
                     attentionAt: attention.map(at), finishedSeen: seen, lastEventAt: at(last))
    }

    static func ids(_ list: [AgentSession]) -> [String] { list.map(\.id) }

    /// A Mochi action from JSON text (a worker's `report` arguments arrive as an object).
    static func act(_ json: String) -> MochiAction? {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else { return nil }
        return MochiAware.action(from: obj)
    }

    static func main() async {
        print("Finished card fold")
        do {
            checkEq("short line waits the minimum", AssistantReply.foldSeconds("Done."), 10)
            checkEq("empty waits the minimum", AssistantReply.foldSeconds(""), 10)
            let thirty = Array(repeating: "word", count: 30).joined(separator: " ")
            checkEq("30 words: 5 s + 30 × 0.35 s", AssistantReply.foldSeconds(thirty), 15.5)
            let long = Array(repeating: "word", count: 400).joined(separator: "\n")
            checkEq("a long headline is capped", AssistantReply.foldSeconds(long), 45)
        }
        print("SessionTitle")
        do {
            checkEq("project dir", SessionTitle.claudeProjectDir(cwd: "/Users/kepla/Desktop/code/coucou"),
                    "-Users-kepla-Desktop-code-coucou")
            checkEq("dots and spaces too", SessionTitle.claudeProjectDir(cwd: "/a/my app.v2"), "-a-my-app-v2")
            let tail = """
            {"type":"summary","summary":"Old summary"}
            {"type":"custom-title","customTitle":"First name","sessionId":"x"}
            {"type":"user","message":"hi"}
            {"type":"custom-title","customTitle":"Mochi output piping to Claude","sessionId":"x"}
            {"type":"assistant","message":"a summary of things"}
            """
            checkEq("newest custom title wins", SessionTitle.claudeTitle(transcriptTail: tail), "Mochi output piping to Claude")
            checkEq("summary when no custom title",
                    SessionTitle.claudeTitle(transcriptTail: "{\"type\":\"summary\",\"summary\":\"Fix login\"}"), "Fix login")
            checkTrue("a cut first line is skipped", SessionTitle.claudeTitle(transcriptTail: "tle\":\"x\"}\n") == nil)
            checkTrue("debris is not a title", SessionTitle.clean("<｜｜DSML｜｜ calls>") == nil)
            checkTrue("blank is not a title", SessionTitle.clean("  ") == nil)
            checkEq("trimmed", SessionTitle.clean("  Fix login \n"), "Fix login")
        }

        print("WakePhrase / HandsFreeEnd")
        do {
            checkTrue("hey mochi", WakePhrase.matches("Hey Mochi"))
            checkTrue("inside a sentence, with punctuation", WakePhrase.matches("so, hey, Mochi! run the tests"))
            checkTrue("misspelt name", WakePhrase.matches("hi moji"))
            checkTrue("name alone is not enough", !WakePhrase.matches("mochi ice cream"))
            checkTrue("greeting alone is not enough", !WakePhrase.matches("hey there"))
            checkTrue("words between break it", !WakePhrase.matches("hey you mochi"))
            checkTrue("empty", !WakePhrase.matches(""))
            checkEq("silence, early: keep listening", HandsFreeEnd.verdict(transcript: "", sinceStart: 2, sinceChange: 2), .keepListening)
            checkEq("silence, too long: cancel", HandsFreeEnd.verdict(transcript: " ", sinceStart: 6, sinceChange: 6), .cancel)
            checkEq("talking: keep listening", HandsFreeEnd.verdict(transcript: "run the", sinceStart: 3, sinceChange: 0.4), .keepListening)
            checkEq("pause after words: send", HandsFreeEnd.verdict(transcript: "run the tests", sinceStart: 9, sinceChange: HandsFreeEnd.pause), .send)
            checkEq("short pause mid-sentence: keep listening", HandsFreeEnd.verdict(transcript: "run the", sinceStart: 4, sinceChange: 1.6), .keepListening)
        }

        print("AssistantBarLogic.sentCopy")
        do {
            checkEq("same OpenCode chat", AssistantBarLogic.sentCopy(target: .reply(sessionId: "a"), workspace: "ws"),
                    "Sent to your OpenCode chat")
            checkEq("same Claude Code session", AssistantBarLogic.sentCopy(target: .claudeReply(sessionId: "a"), workspace: "ws"),
                    "Sent to your Claude Code session")
            checkEq("new task names the folder", AssistantBarLogic.sentCopy(target: .newTask, workspace: "coucou"),
                    "Started a new OpenCode task in coucou")
            checkEq("new task, no folder name", AssistantBarLogic.sentCopy(target: .newTask, workspace: ""),
                    "Started a new OpenCode task")
        }

        print("AssistantBarLogic.target / placeholder / tag")
        do {
            func oc(_ phase: SessionPhase) -> AgentSession {
                var s = sess("ses_1", workspace: "ads-video", phase: phase); s.kind = .openCode; return s
            }
            checkEq("no main: new task", AssistantBarLogic.target(main: nil), .newTask)
            checkEq("finished OpenCode: reply in the same chat",
                    AssistantBarLogic.target(main: oc(.finished)), .reply(sessionId: "ses_1"))
            checkEq("idle OpenCode: reply in the same chat",
                    AssistantBarLogic.target(main: oc(.idle)), .reply(sessionId: "ses_1"))
            checkEq("busy OpenCode: new task (no second prompt into a running chat)",
                    AssistantBarLogic.target(main: oc(.working)), .newTask)
            checkEq("OpenCode waiting on a question: new task",
                    AssistantBarLogic.target(main: oc(.question)), .newTask)
            checkEq("finished Claude Code: reply in the same session",
                    AssistantBarLogic.target(main: sess("c", phase: .finished)), .claudeReply(sessionId: "c"))
            checkEq("idle Claude Code: reply in the same session",
                    AssistantBarLogic.target(main: sess("c", phase: .idle)), .claudeReply(sessionId: "c"))
            do {
                var noCwd = sess("c", phase: .finished); noCwd.cwd = ""
                checkEq("Claude Code without a cwd: new task (resume needs its folder)",
                        AssistantBarLogic.target(main: noCwd), .newTask)
            }
            checkEq("busy Claude Code: new task (no second prompt into a running session)",
                    AssistantBarLogic.target(main: sess("c", phase: .working)), .newTask)
            checkEq("Claude Code waiting on approval: new task",
                    AssistantBarLogic.target(main: sess("c", phase: .approval)), .newTask)
            checkEq("Claude reply placeholder",
                    AssistantBarLogic.placeholder(target: .claudeReply(sessionId: "c"), workspace: "w"),
                    "Reply in this Claude Code session…")
            checkEq("Claude reply tag",
                    AssistantBarLogic.tag(target: .claudeReply(sessionId: "c"), main: sess("c", phase: .idle)),
                    "same Claude Code session")
            checkEq("reply placeholder", AssistantBarLogic.placeholder(target: .reply(sessionId: "x"), workspace: "ads-video"),
                    "Reply in this OpenCode chat…")
            checkEq("new task placeholder", AssistantBarLogic.placeholder(target: .newTask, workspace: "ads-video"),
                    "New OpenCode task in ads-video…")
            checkEq("reply tag", AssistantBarLogic.tag(target: .reply(sessionId: "x"), main: oc(.finished)), "same chat")
            checkEq("new task under a busy Claude Code says it is not sent there",
                    AssistantBarLogic.tag(target: .newTask, main: sess("c", phase: .working)),
                    "new OpenCode session · not sent to Claude Code")
            checkTrue("new task under a busy OpenCode chat: no tag",
                      AssistantBarLogic.tag(target: .newTask, main: oc(.working)) == nil)
            checkTrue("no main: no tag", AssistantBarLogic.tag(target: .newTask, main: nil) == nil)
        }

        print("MainAgentPicker")
        do {
            checkTrue("no sessions -> nil",
                      MainAgentPicker.pick(sessions: [], selectedId: "x", contextWorkspace: "a",
                                           previousMainId: "y") == nil)

            let a = sess("a", workspace: "A", last: 1)
            let b = sess("b", workspace: "B", last: 5)
            let c = sess("c", workspace: "C", last: 3)

            checkEq("clicked agent wins over everything",
                    MainAgentPicker.pick(sessions: [a, b, sess("n", phase: .approval, attention: 1)],
                                         selectedId: "a", contextWorkspace: "B", previousMainId: "b"), "a")
            checkEq("a selectedId that died is ignored",
                    MainAgentPicker.pick(sessions: [a, b], selectedId: "gone", contextWorkspace: nil,
                                         previousMainId: nil), "b")

            let needy = sess("needy", workspace: "C", phase: .approval, attention: 10, last: 10)
            checkEq("an agent that needs you beats the context workspace",
                    MainAgentPicker.pick(sessions: [a, b, needy], selectedId: nil, contextWorkspace: "A",
                                         previousMainId: "b"), "needy")
            let older = sess("older", phase: .question, attention: 4)
            checkEq("oldest need first",
                    MainAgentPicker.pick(sessions: [needy, older], selectedId: nil, contextWorkspace: nil,
                                         previousMainId: nil), "older")
            let fin = sess("fin", phase: .finished, attention: 20)
            checkEq("finished-and-unseen counts as a need",
                    MainAgentPicker.pick(sessions: [a, fin], selectedId: nil, contextWorkspace: "A",
                                         previousMainId: "a"), "fin")
            let finSeen = sess("fin", phase: .finished, attention: 20, seen: true)
            checkEq("finished-and-seen does not",
                    MainAgentPicker.pick(sessions: [a, finSeen], selectedId: nil, contextWorkspace: "A",
                                         previousMainId: nil), "a")

            checkEq("context workspace beats previous main",
                    MainAgentPicker.pick(sessions: [a, b, c], selectedId: nil, contextWorkspace: "C",
                                         previousMainId: "b"), "c")
            let a2 = sess("a2", workspace: "A", last: 9)
            checkEq("within the context workspace the latest lastEventAt wins",
                    MainAgentPicker.pick(sessions: [a, a2, b], selectedId: nil, contextWorkspace: "A",
                                         previousMainId: nil), "a2")
            checkEq("context workspace without a session falls through to previous main",
                    MainAgentPicker.pick(sessions: [a, b, c], selectedId: nil, contextWorkspace: "Z",
                                         previousMainId: "c"), "c")
            checkEq("nil context falls through to previous main",
                    MainAgentPicker.pick(sessions: [a, b, c], selectedId: nil, contextWorkspace: nil,
                                         previousMainId: "a"), "a")
            checkEq("dead previous main falls through to the most recent",
                    MainAgentPicker.pick(sessions: [a, b, c], selectedId: nil, contextWorkspace: nil,
                                         previousMainId: "dead"), "b")
            checkEq("no hints -> most recently active",
                    MainAgentPicker.pick(sessions: [a, b, c], selectedId: nil, contextWorkspace: nil,
                                         previousMainId: nil), "b")
            let t1 = sess("t1", last: 7), t2 = sess("t2", last: 7)
            checkEq("exact ties are deterministic",
                    MainAgentPicker.pick(sessions: [t2, t1], selectedId: nil, contextWorkspace: nil,
                                         previousMainId: nil), "t1")
        }

        print("AttentionQueue")
        do {
            checkTrue("empty in, empty out", AttentionQueue.order([]).isEmpty)

            let work = sess("work", phase: .working)
            let appr = sess("appr", phase: .approval, attention: 10)
            let ques = sess("ques", phase: .question, attention: 5)
            let blck = sess("blck", phase: .blocked, attention: 7)
            let fin = sess("fin", phase: .finished, attention: 1)
            let seen = sess("seen", phase: .finished, attention: 2, seen: true)
            let idle = sess("idle", phase: .idle)
            let q = AttentionQueue.order([work, fin, appr, seen, idle, blck, ques])
            checkEq("blocking needs first by oldest attentionAt, finished-unseen last",
                    ids(q), ["ques", "blck", "appr", "fin"])

            let x = sess("x", phase: .approval, attention: 3, last: 9)
            let y = sess("y", phase: .approval, attention: 3, last: 2)
            checkEq("ties on attentionAt -> older lastEventAt first",
                    ids(AttentionQueue.order([x, y])), ["y", "x"])

            let f1 = sess("f1", phase: .finished, attention: 8)
            let f2 = sess("f2", phase: .finished, attention: 4)
            checkEq("finished-unseen are ordered oldest first too",
                    ids(AttentionQueue.order([f1, f2])), ["f2", "f1"])
        }

        print("SubSlotOrder")
        do {
            var r = SubSlotOrder.update(order: ["b", "c"], alive: ["a", "b", "c"], oldMain: "a", newMain: "b")
            checkEq("clicked sub keeps its slot and becomes the old main: order", r.order, ["a", "c"])
            checkEq("clicked sub keeps its slot: recolour index is its slot", r.recolourIndex, 0)

            r = SubSlotOrder.update(order: ["b", "c", "d"], alive: ["a", "b", "c", "d"], oldMain: "a", newMain: "c")
            checkEq("middle slot swap keeps the others in place", r.order, ["b", "a", "d"])
            checkEq("recolour index is 1", r.recolourIndex, 1)

            r = SubSlotOrder.update(order: ["x", "b", "c"], alive: ["a", "b", "c"], oldMain: "a", newMain: "c")
            checkEq("a dead id before the slot is dropped", r.order, ["b", "a"])
            checkEq("recolour index counts in the cleaned order", r.recolourIndex, 1)

            r = SubSlotOrder.update(order: ["b", "c"], alive: ["a", "b", "c", "n"], oldMain: "a", newMain: "n")
            checkEq("new main was not a sub: old main appended, order intact", r.order, ["b", "c", "a"])
            checkTrue("no recolour index when the new main was not a sub", r.recolourIndex == nil)

            r = SubSlotOrder.update(order: ["b", "c"], alive: ["b", "c"], oldMain: nil, newMain: "b")
            checkEq("first main picked from the subs: its slot closes", r.order, ["c"])
            checkTrue("no recolour without an old main", r.recolourIndex == nil)

            r = SubSlotOrder.update(order: ["b", "c", "d"], alive: ["b", "c", "d"], oldMain: "gone", newMain: "c")
            checkEq("main dies: the order closes the gap", r.order, ["b", "d"])
            checkTrue("main dies: no recolour index", r.recolourIndex == nil)

            r = SubSlotOrder.update(order: ["b"], alive: ["a", "b", "c", "d"], oldMain: "a", newMain: "a")
            checkEq("same main: new alive ids append, main never a sub", r.order, ["b", "c", "d"])
            checkTrue("same main: no recolour", r.recolourIndex == nil)

            r = SubSlotOrder.update(order: ["b", "c"], alive: ["a", "b"], oldMain: "a", newMain: "b")
            checkEq("a dead sub is removed", r.order, ["a"])
            checkEq("swap still reports the slot", r.recolourIndex, 0)

            r = SubSlotOrder.update(order: [], alive: [], oldMain: nil, newMain: nil)
            checkTrue("nothing in, nothing out", r.order.isEmpty && r.recolourIndex == nil)

            r = SubSlotOrder.update(order: ["b", "a"], alive: ["a", "b", "c"], oldMain: "a", newMain: "b")
            checkEq("old main already among the subs is not duplicated", r.order, ["a", "c"])
            checkTrue("and nothing to recolour", r.recolourIndex == nil)

            // Surviving subs never change slot across a sequence of swaps.
            var order = ["b", "c"]
            var main = "a"
            for next in ["c", "a", "b"] {
                let u = SubSlotOrder.update(order: order, alive: ["a", "b", "c"], oldMain: main, newMain: next)
                order = u.order; main = next
            }
            checkEq("three hand-offs in a row keep two subs, never the main",
                    Set(order).union([main]), Set(["a", "b", "c"]))
            checkEq("and the slot count stays at two", order.count, 2)
        }

        print("")
        print("AssistantStripGeometry")
        do {
            checkEq("0 subs: 56 each side", AssistantStripGeometry.compactWidth(notchWidth: 184, subs: 0), 296)
            checkEq("1 sub: still 56", AssistantStripGeometry.compactWidth(notchWidth: 184, subs: 1), 296)
            checkEq("3 subs: 3x26+26 = 104", AssistantStripGeometry.compactWidth(notchWidth: 184, subs: 3), 392)
            checkEq("5 subs: 156", AssistantStripGeometry.compactWidth(notchWidth: 184, subs: 5), 496)
            checkEq("7 subs: 5 shown + count slot = 6", AssistantStripGeometry.compactWidth(notchWidth: 184, subs: 7), 548)
            let g = AssistantStripGeometry(islandWidth: 392, islandHeight: 32, notchWidth: 184, restingDiameter: 20)
            checkEq("main diameter 20 x 1.25 = 25 (cap 28)", g.mainDiameter, 25)
            checkEq("main centre 30 pt left of the notch", g.mainCentreX, 196 - 92 - 30)
            checkEq("first sub 22 pt right of the notch", g.subCentreX(0), 196 + 92 + 22)
            checkEq("subs spaced 26", g.subCentreX(2) - g.subCentreX(1), 26)
            checkEq("sub diameter 0.68 x main", g.subDiameter, 25 * 0.68)
            let small = AssistantStripGeometry(islandWidth: 296, islandHeight: 24, notchWidth: 80, restingDiameter: 18)
            checkEq("short bar: capped at height - 4", small.mainDiameter, 20)
        }

        print("")
        print("statusDotHex")
        do {
            checkEq("approval is amber", sess("a", phase: .approval).statusDotHex, "#F5A524")
            checkEq("question is amber", sess("a", phase: .question).statusDotHex, "#F5A524")
            checkEq("blocked is red", sess("a", phase: .blocked).statusDotHex, "#F87171")
            checkEq("finished unseen is green", sess("a", phase: .finished).statusDotHex, "#34D399")
            checkTrue("finished seen has no dot", sess("a", phase: .finished, seen: true).statusDotHex == nil)
            checkTrue("working has no dot", sess("a", phase: .working).statusDotHex == nil)
        }

        print("")
        print("AssistantOpenRules")
        do {
            let ap = sess("a", phase: .approval, attention: 5)
            let fin = sess("f", phase: .finished, attention: 9)
            let work = sess("w", phase: .working)
            let q1 = AttentionQueue.order([ap, work])
            let sig1 = AssistantOpenRules.signature(queue: q1)
            checkEq("empty queue has an empty signature", AssistantOpenRules.signature(queue: []), "")
            checkTrue("nothing pending, nothing summoned: closed",
                      !AssistantOpenRules.isOpen(summoned: false, selectedId: nil, queue: [], dismissedSignature: nil))
            checkTrue("a need opens the panel",
                      AssistantOpenRules.isOpen(summoned: false, selectedId: nil, queue: q1, dismissedSignature: nil))
            checkTrue("dismissing that need keeps it closed",
                      !AssistantOpenRules.isOpen(summoned: false, selectedId: nil, queue: q1, dismissedSignature: sig1))
            let q2 = AttentionQueue.order([ap, fin])
            checkTrue("a new need changes the signature and reopens",
                      AssistantOpenRules.isOpen(summoned: false, selectedId: nil, queue: q2, dismissedSignature: sig1))
            let ap2 = sess("a", phase: .approval, attention: 50)
            checkTrue("the same session asking again reopens",
                      AssistantOpenRules.isOpen(summoned: false, selectedId: nil,
                                                queue: AttentionQueue.order([ap2]), dismissedSignature: sig1))
            let bq = sess("b", phase: .question, attention: 6)
            let two = AttentionQueue.order([ap, bq])
            let sigTwo = AssistantOpenRules.signature(queue: two)
            checkTrue("a need that went away does not reopen the panel",
                      !AssistantOpenRules.isOpen(summoned: false, selectedId: nil,
                                                 queue: AttentionQueue.order([bq]), dismissedSignature: sigTwo))
            checkTrue("one more need on top of the dismissed ones reopens it",
                      AssistantOpenRules.isOpen(summoned: false, selectedId: nil,
                                                queue: AttentionQueue.order([ap, bq, fin]), dismissedSignature: sigTwo))
            checkTrue("summoned opens with an empty queue",
                      AssistantOpenRules.isOpen(summoned: true, selectedId: nil, queue: [], dismissedSignature: nil))
            checkTrue("a clicked agent opens it",
                      AssistantOpenRules.isOpen(summoned: false, selectedId: "w", queue: [], dismissedSignature: nil))
            checkTrue("summon wins over a dismissed signature",
                      AssistantOpenRules.isOpen(summoned: true, selectedId: nil, queue: q1, dismissedSignature: sig1))
        }

        print("")
        print("AssistantRouting")
        do {
            checkTrue("home with a folder to talk to is the panel",
                      AssistantRouting.usesPanel(isOverview: true, hasFolder: true, isAlertView: false, hasSessionNeed: false))
            checkTrue("home with no folder keeps the shipping view",
                      !AssistantRouting.usesPanel(isOverview: true, hasFolder: false, isAlertView: false, hasSessionNeed: false))
            checkTrue("an alert backed by a session need goes to the panel",
                      AssistantRouting.usesPanel(isOverview: false, hasFolder: true, isAlertView: true, hasSessionNeed: true))
            checkTrue("an alert with no session behind it keeps the shipping view",
                      !AssistantRouting.usesPanel(isOverview: false, hasFolder: true, isAlertView: true, hasSessionNeed: false))
            checkTrue("other views are never the panel",
                      !AssistantRouting.usesPanel(isOverview: false, hasFolder: true, isAlertView: false, hasSessionNeed: true))
        }

        print("")
        print("AssistantPanelContent / AssistantMetrics")
        do {
            let ap = sess("a", phase: .approval, attention: 1)
            checkEq("approval with a held request", AssistantPanelContent.resolve(
                main: ap, hasApproval: true, questionRows: nil, finishedFiles: 0, showsDiff: false), .approval)
            checkEq("approval whose request timed out has no card", AssistantPanelContent.resolve(
                main: ap, hasApproval: false, questionRows: nil, finishedFiles: 0, showsDiff: false), .bar)
            checkEq("question card", AssistantPanelContent.resolve(
                main: sess("q", phase: .question, attention: 1), hasApproval: false, questionRows: 4,
                finishedFiles: 0, showsDiff: false), .question(rows: 4))
            checkEq("question without a held request", AssistantPanelContent.resolve(
                main: sess("q", phase: .question, attention: 1), hasApproval: false, questionRows: nil,
                finishedFiles: 0, showsDiff: false), .bar)
            checkEq("blocked", AssistantPanelContent.resolve(
                main: sess("b", phase: .blocked, attention: 1), hasApproval: false, questionRows: nil,
                finishedFiles: 0, showsDiff: false), .blocked)
            checkEq("finished unseen", AssistantPanelContent.resolve(
                main: sess("f", phase: .finished, attention: 1), hasApproval: false, questionRows: nil,
                finishedFiles: 2, showsDiff: false), .finished(files: 2))
            checkEq("finished and seen is just the bar", AssistantPanelContent.resolve(
                main: sess("f", phase: .finished, attention: 1, seen: true), hasApproval: false,
                questionRows: nil, finishedFiles: 2, showsDiff: false), .bar)
            checkEq("diff opens only when there are files", AssistantPanelContent.resolve(
                main: sess("f", phase: .finished, attention: 1), hasApproval: false, questionRows: nil,
                finishedFiles: 0, showsDiff: true), .finished(files: 0))
            checkEq("diff", AssistantPanelContent.resolve(
                main: sess("f", phase: .finished, attention: 1), hasApproval: false, questionRows: nil,
                finishedFiles: 1, showsDiff: true), .diff)
            checkEq("working main: bar", AssistantPanelContent.resolve(
                main: sess("w"), hasApproval: false, questionRows: nil, finishedFiles: 0, showsDiff: false), .bar)
            checkEq("no main: bar", AssistantPanelContent.resolve(
                main: nil, hasApproval: false, questionRows: nil, finishedFiles: 0, showsDiff: false), .bar)

            checkEq("bar 112", AssistantMetrics.height(for: .bar), 112)
            checkEq("approval 270", AssistantMetrics.height(for: .approval), 270)
            checkEq("blocked 262", AssistantMetrics.height(for: .blocked), 262)
            checkEq("done with 2 files 282", AssistantMetrics.height(for: .finished(files: 2)), 282)
            checkEq("done caps at 3 file rows", AssistantMetrics.height(for: .finished(files: 9)), 303)
            checkEq("first sentence", AssistantReply.firstSentence("Done. The build passes."), "Done.")
            checkEq("markdown stripped, first paragraph", AssistantReply.firstSentence("## **Built** it\n\nMore."), "Built it")
            checkEq("version dots are not sentence ends", AssistantReply.firstSentence("Bumped to 2.1.0 today. Next."), "Bumped to 2.1.0 today.")
            checkTrue("nil and blank give nil", AssistantReply.firstSentence(nil) == nil && AssistantReply.firstSentence(" \n ") == nil)
            checkTrue("long sentence is never cut",
                      (AssistantReply.firstSentence(String(repeating: "a", count: 300)) ?? "").count == 300)
            checkEq("headline lines", AssistantReply.headlineLines(String(repeating: "a", count: 130)), 3)
            checkEq("a 3-line headline adds one line", AssistantMetrics.height(for: .finished(files: 0, extraLines: 1)),
                    AssistantMetrics.height(for: .finished(files: 0)) + 20)
            var longMain = sess("f", phase: .finished, attention: 1)
            longMain.reply = "When you type a task and press Enter, it goes nowhere.\n\nMore detail follows."
            checkEq("finished with a long reply: same card", AssistantPanelContent.resolve(
                main: longMain, hasApproval: false, questionRows: nil, finishedFiles: 1, showsDiff: false),
                .finished(files: 1))
            checkEq("question = rows x 34 + 148", AssistantMetrics.height(for: .question(rows: 5)), 318)
            checkTrue("every height fits the 320 pt window",
                      AssistantMetrics.height(for: .question(rows: 40)) <= 320)
        }


        print("AssistantBarLogic")
        do {
            let a = sess("a", workspace: "alpha", last: 1)
            var blank = sess("b", workspace: "beta", last: 9)
            blank.cwd = ""
            let b2 = sess("c", workspace: "beta", last: 5)
            checkEq("folder: main cwd wins", AssistantBarLogic.folder(
                main: a, contextWorkspace: "beta", sessions: [a, b2]),
                AssistantTaskFolder(cwd: "/code/alpha", workspace: "alpha"))
            checkEq("folder: empty main cwd -> context workspace session", AssistantBarLogic.folder(
                main: blank, contextWorkspace: "beta", sessions: [a, blank, b2]),
                AssistantTaskFolder(cwd: "/code/beta", workspace: "beta"))
            checkEq("folder: empty main cwd, no context -> nil", AssistantBarLogic.folder(
                main: blank, contextWorkspace: nil, sessions: [a, blank]), nil)
            checkEq("folder: no sessions -> nil", AssistantBarLogic.folder(
                main: nil, contextWorkspace: "beta", sessions: []), nil)

            let f = AssistantTaskFolder(cwd: "/code/alpha", workspace: "alpha")
            checkEq("whitespace is a no-op", AssistantBarLogic.check(
                text: "  \n ", folder: nil, model: "", cliAvailable: false), .ignore)
            checkEq("no folder", AssistantBarLogic.check(
                text: "x", folder: nil, model: "m", cliAvailable: true), .error(AssistantBarLogic.noFolderCopy))
            checkEq("no model", AssistantBarLogic.check(
                text: "x", folder: f, model: " ", cliAvailable: true), .error(AssistantBarLogic.noModelCopy))
            checkEq("cli missing", AssistantBarLogic.check(
                text: "x", folder: f, model: "m", cliAvailable: false), .error(AssistantBarLogic.cliMissingCopy))
            let cr = AssistantBarLogic.Target.claudeReply(sessionId: "c")
            checkEq("Claude reply needs no OpenCode model", AssistantBarLogic.check(
                text: "x", folder: f, model: "", cliAvailable: true, target: cr),
                .launch(prompt: "x", cwd: "/code/alpha"))
            checkEq("Claude CLI missing", AssistantBarLogic.check(
                text: "x", folder: f, model: "m", cliAvailable: false, target: cr),
                .error(AssistantBarLogic.claudeCliMissingCopy))
            checkEq("launch trims the prompt", AssistantBarLogic.check(
                text: "  add a readme \n", folder: f, model: "m", cliAvailable: true),
                .launch(prompt: "add a readme", cwd: "/code/alpha"))
        }

        print("")
        print("ProjectLaunchLogic")
        do {
            let home = "/Users/me"
            checkTrue("a code folder is a project", ProjectLaunchLogic.isUserProject(path: "/Users/me/code/app", home: home))
            checkTrue("home itself is not", !ProjectLaunchLogic.isUserProject(path: "/Users/me", home: home))
            checkTrue("~/Library is not", !ProjectLaunchLogic.isUserProject(
                path: "/Users/me/Library/Application Support/x", home: home))
            checkTrue("a Claude worktree is not", !ProjectLaunchLogic.isUserProject(
                path: "/Users/me/code/app/.claude/worktrees/x", home: home))
            checkTrue("a temp folder is not", !ProjectLaunchLogic.isUserProject(path: "/private/tmp/x", home: home))

            let d1 = Date(timeIntervalSince1970: 100), d2 = Date(timeIntervalSince1970: 200)
            let merged = ProjectLaunchLogic.merge(
                claude: [("/Users/me/code/Bapoojee-production", d1), ("/private/tmp/x", d2)],
                openCode: [("/Users/me/code/Bapoojee-production/", d2), ("/Users/me/code/coucou", d1)],
                home: home)
            checkEq("merged, filtered, newest first", merged.map(\.name), ["Bapoojee-production", "coucou"])
            checkEq("last CLI is the newer one", merged.first?.lastUsedCLI, .openCode)

            checkEq("work on", ProjectLaunchLogic.intent(from: "I want to work on Bapoojee", bare: false),
                    .init(query: "bapoojee", cli: nil))
            checkEq("spoken CLI wins and is removed",
                    ProjectLaunchLogic.intent(from: "open bapoojee with OpenCode", bare: false),
                    .init(query: "bapoojee", cli: .openCode))
            checkEq("claude code", ProjectLaunchLogic.intent(from: "let's work on coucou in Claude Code.", bare: false),
                    .init(query: "coucou", cli: .claudeCode))
            checkEq("mid-sentence trigger is a reply, not a launch",
                    ProjectLaunchLogic.intent(from: "now start the tests for coucou", bare: false), nil)
            checkEq("name first is fine", ProjectLaunchLogic.intent(from: "Mochi, work on coucou", bare: false),
                    .init(query: "coucou", cli: nil))
            checkEq("no trigger, not bare: nothing", ProjectLaunchLogic.intent(from: "bapoojee", bare: false), nil)
            checkEq("no trigger, bare: the whole text", ProjectLaunchLogic.intent(from: "Bapoojee", bare: true),
                    .init(query: "bapoojee", cli: nil))
            checkEq("only fillers: nothing", ProjectLaunchLogic.intent(from: "work on the project", bare: false), nil)

            let projects = merged
            checkEq("prefix match", ProjectLaunchLogic.match("bapoojee", in: projects)?.name, "Bapoojee-production")
            checkEq("close spelling", ProjectLaunchLogic.match("bapoojie", in: projects)?.name, "Bapoojee-production")
            checkEq("exact", ProjectLaunchLogic.match("coucou", in: projects)?.name, "coucou")
            checkEq("no match", ProjectLaunchLogic.match("next step", in: projects)?.name, nil)
            checkEq("too short", ProjectLaunchLogic.match("co", in: projects)?.name, nil)

            checkEq("project named inside a sentence", ProjectLaunchLogic.mentioned(
                in: "In Bapoojee where is the document to send to the CEO", projects: projects)?.name,
                "Bapoojee-production")
            checkEq("one wrong letter", ProjectLaunchLogic.mentioned(in: "in bapoojie, fix it", projects: projects)?.name,
                    "Bapoojee-production")
            checkEq("no project in the sentence", ProjectLaunchLogic.mentioned(in: "where is the document", projects: projects)?.name, nil)
            checkEq("command alone", ProjectLaunchLogic.command(.claudeCode, prompt: nil), "claude")
            checkEq("claude with a prompt", ProjectLaunchLogic.command(.claudeCode, prompt: "where's the doc"),
                    "claude 'where'\\''s the doc'")
            checkEq("opencode with a prompt", ProjectLaunchLogic.command(.openCode, prompt: "hi"), "opencode --prompt 'hi'")
            checkTrue("the model can never ask for a focus action",
                      MochiAware.action(from: ["label": "Go", "focus": "abc"]) == nil)
            checkEq("a plain action", MochiAware.action(from: ["label": "Open", "open": "http://localhost:5173"])?.kind,
                    .openURL("http://localhost:5173"))
            checkEq("a path opens as a file", MochiAware.action(from: ["label": "Design", "open": "/tmp/design.fig"])?.kind,
                    .openFile("/tmp/design.fig"))
            checkEq("reply kind", MochiAware.action(from: ["label": "Tests", "reply": "Run the tests"])?.kind, .reply("Run the tests"))
            checkEq("copy kind", MochiAware.action(from: ["label": "Copy", "copy": "npm run dev"])?.kind, .copy("npm run dev"))
            checkEq("file:// refused", act(#"{"label":"x","open":"file:///Applications/Calculator.app"}"#), nil)
            checkEq("custom scheme refused", act(#"{"label":"x","open":"vscode://open"}"#), nil)
            checkEq("no label refused", act(#"{"open":"https://a.b"}"#), nil)
            checkEq("unknown kind refused", act(#"{"label":"x","run":"rm -rf /"}"#), nil)
            checkEq("bad JSON refused", act("label: x"), nil)
            checkEq("go model routes to the Go gateway", BrainModels.openCodeRoute("opencode-go/deepseek-v4.1-flash")?.baseURL, ProviderEndpoints.zenGo)
            checkEq("go model sent bare", BrainModels.openCodeRoute("opencode-go/deepseek-v4.1-flash")?.model, "deepseek-v4.1-flash")
            checkEq("zen model routes to Zen", BrainModels.openCodeRoute("opencode/big-pickle")?.baseURL, ProviderEndpoints.zen)
            checkEq("other providers have no gateway", BrainModels.openCodeRoute("openai/gpt-5")?.model, nil)
            checkEq("empty go id refused", BrainModels.openCodeRoute("opencode-go/")?.model, nil)
            checkTrue("go filter", BrainModels.isOpenCodeGo("opencode-go/x") && !BrainModels.isOpenCodeGo("opencode/big-pickle"))
            checkEq("long label cut", act(#"{"label":"\#(String(repeating: "a", count: 50))","copy":"x"}"#)?.label.count,
                    MochiAware.maxLabel)
            checkEq("relative path from the session folder", MochiAware.resolvePath("src/a.ts", cwd: "/code/p"), "/code/p/src/a.ts")
            checkEq("absolute path kept", MochiAware.resolvePath("/x/../y", cwd: "/code/p"), "/y")

            var withNote = sess("n", phase: .finished)
            withNote.mochi = MochiNote(line: "Done", actions: [MochiAction(label: "Copy", kind: .copy("x"))])
            let noteContent = AssistantPanelContent.resolve(main: withNote, hasApproval: false, questionRows: nil,
                                                            finishedFiles: 3, showsDiff: false, hasActions: true)
            checkEq("no performable suggestions: no row", AssistantPanelContent.resolve(main: withNote, hasApproval: false,
                questionRows: nil, finishedFiles: 3, showsDiff: false), .finished(files: 3))
            checkEq("finished card knows about the suggestion row", noteContent, .finished(files: 3, actions: true))
            checkTrue("card with suggestions still fits the window",
                      AssistantMetrics.height(for: noteContent) <= AssistantMetrics.maxHeight
                      && AssistantMetrics.height(for: noteContent) == AssistantMetrics.height(for: .finished(files: 3)) + AssistantMetrics.actionRow - AssistantMetrics.fileRow)
            checkEq("remembered once, newest last", MochiAware.remembering("a", in: ["a", "b"]), ["b", "a"])
            checkEq("list is capped", MochiAware.remembering("z", in: (0..<100).map(String.init)).count, MochiAware.keep)

            let p = merged[0]   // last used: OpenCode
            checkEq("spoken beats all", ProjectLaunchLogic.cli(override: .claudeCode, setting: .openCode,
                                                               project: p, fallback: .openCode), .claudeCode)
            checkEq("setting beats history", ProjectLaunchLogic.cli(override: nil, setting: .claudeCode,
                                                                    project: p, fallback: .openCode), .claudeCode)
            checkEq("history beats default", ProjectLaunchLogic.cli(override: nil, setting: nil,
                                                                    project: p, fallback: .claudeCode), .openCode)
            checkEq("default last", ProjectLaunchLogic.cli(override: nil, setting: nil,
                                                           project: KnownProject(path: "/Users/me/x"),
                                                           fallback: .claudeCode), .claudeCode)
        }

        print("")
        print("Intent router")
        do {
            let s1 = RouterSession(id: "s1", agent: "Claude Code", workspace: "coucou", cwd: "/Users/me/code/coucou",
                                   phase: "idle", title: nil, lastPrompt: nil)
            let bap = RouterProject(name: "Bapoojee-production", path: "/Users/me/code/Bapoojee-production", lastCLI: .claudeCode)
            let cou = RouterProject(name: "coucou", path: "/Users/me/code/coucou", lastCLI: nil)
            func input(_ text: String, main: String? = "s1") -> RouterInput {
                RouterInput(utterance: text, sessions: main == nil ? [] : [s1], projects: [bap, cou], mainSessionId: main)
            }
            // RuleRouter reproduces today's behaviour
            checkEq("rules: reply to main", RuleRouter.decide(input("run the tests")).action,
                    .reply(sessionId: "s1", text: "run the tests"))
            checkEq("rules: mid-sentence start stays a reply", RuleRouter.decide(input("start the tests for coucou")).action,
                    .reply(sessionId: "s1", text: "start the tests for coucou"))
            checkEq("rules: work on X", RuleRouter.decide(input("work on bapoojee")).action,
                    .start(projectPath: bap.path, cli: nil, prompt: nil))
            checkEq("rules: spoken CLI", RuleRouter.decide(input("open coucou with OpenCode")).action,
                    .start(projectPath: cou.path, cli: .openCode, prompt: nil))
            checkEq("rules: nothing running, project inside a sentence",
                    RuleRouter.decide(input("In Bapoojee where is the doc", main: nil)).action,
                    .start(projectPath: bap.path, cli: nil, prompt: "In Bapoojee where is the doc"))
            checkEq("rules: nothing running, no project", RuleRouter.decide(input("hello there", main: nil)).action, .none)
            checkEq("rules: empty", RuleRouter.decide(input("   ")).action, .none)

            // validated
            func v(_ a: RouterAction, _ i: RouterInput = input("x")) -> RouterAction {
                RouterDecision(action: a, source: "t").validated(against: i).action
            }
            checkEq("unknown session reply → none", v(.reply(sessionId: "nope", text: "hi")), .none)
            checkEq("empty reply text → none", v(.reply(sessionId: "s1", text: "  ")), .none)
            checkEq("unknown project → none", v(.start(projectPath: "/x", cli: nil, prompt: nil)), .none)
            checkEq("empty prompt → nil", v(.start(projectPath: cou.path, cli: nil, prompt: " ")),
                    .start(projectPath: cou.path, cli: nil, prompt: nil))
            checkEq("unknown open → none", v(.open(sessionId: "nope")), .none)
            let two = RouterAction.clarify(question: "Which?", choices: [
                RouterChoice(label: "Bapoojee", action: .start(projectPath: bap.path, cli: nil, prompt: nil)),
                RouterChoice(label: "bad", action: .open(sessionId: "nope")),
                RouterChoice(label: "nested", action: .clarify(question: "q", choices: [])),
                RouterChoice(label: "coucou", action: .start(projectPath: cou.path, cli: nil, prompt: nil)),
                RouterChoice(label: "dup", action: .start(projectPath: cou.path, cli: nil, prompt: nil)),
            ])
            checkEq("clarify keeps valid distinct choices", v(two), .clarify(question: "Which?", choices: [
                RouterChoice(label: "Bapoojee", action: .start(projectPath: bap.path, cli: nil, prompt: nil)),
                RouterChoice(label: "coucou", action: .start(projectPath: cou.path, cli: nil, prompt: nil)),
            ]))
            checkEq("clarify with one valid choice becomes it", v(.clarify(question: "q", choices: [
                RouterChoice(label: "a", action: .open(sessionId: "s1")),
                RouterChoice(label: "b", action: .open(sessionId: "nope")),
            ])), .open(sessionId: "s1"))
            checkEq("clarify with none valid → none", v(.clarify(question: "q", choices: [])), .none)

            // Claude parsing
            func parse(_ json: String) -> RouterAction? { try? ClaudeRouterParsing.action(fromJSON: Data(json.utf8)) }
            let nulls = #""session_id":null,"project_path":null,"cli":null,"text":null,"question":null,"choices":[]"#
            checkEq("parse reply", parse(#"{"action":"reply","session_id":"s1","project_path":null,"cli":null,"text":"go","question":null,"choices":[]}"#),
                    .reply(sessionId: "s1", text: "go"))
            checkEq("parse start with escaped slashes and accents",
                    parse(#"{"action":"start","session_id":null,"project_path":"\/Users\/me\/code\/coucou","cli":"opencode","text":"où est le doc","question":null,"choices":[]}"#),
                    .start(projectPath: "/Users/me/code/coucou", cli: .openCode, prompt: "où est le doc"))
            checkEq("parse start, unknown cli → nil",
                    parse(#"{"action":"start","session_id":null,"project_path":"/p","cli":"vim","text":null,"question":null,"choices":[]}"#),
                    .start(projectPath: "/p", cli: nil, prompt: nil))
            checkEq("parse open", parse(#"{"action":"open","session_id":"s1","project_path":null,"cli":null,"text":null,"question":null,"choices":[]}"#),
                    .open(sessionId: "s1"))
            checkEq("parse none", parse("{\"action\":\"none\",\(nulls)}"), RouterAction.none)
            checkEq("parse clarify drops a nested clarify",
                    parse(#"{"action":"clarify","session_id":null,"project_path":null,"cli":null,"text":null,"question":"Which?","choices":[{"label":"A","action":"open","session_id":"s1","project_path":null,"cli":null,"text":null},{"label":"B","action":"clarify","session_id":null,"project_path":null,"cli":null,"text":null}]}"#),
                    .clarify(question: "Which?", choices: [RouterChoice(label: "A", action: .open(sessionId: "s1"))]))
            checkTrue("reply without text throws", parse(#"{"action":"reply","session_id":"s1","project_path":null,"cli":null,"text":null,"question":null,"choices":[]}"#) == nil)
            checkTrue("unknown action throws", parse(#"{"action":"dance"}"#) == nil)
            checkTrue("not JSON throws", parse("hello") == nil)
            let resp = #"{"stop_reason":"end_turn","content":[{"type":"text","text":"{\"action\":\"open\",\"session_id\":\"s1\",\"project_path\":null,\"cli\":null,\"text\":null,\"question\":null,\"choices\":[]}"}]}"#
            checkEq("response envelope", try? ClaudeRouterParsing.action(fromResponse: Data(resp.utf8)), .open(sessionId: "s1"))
            checkTrue("refusal throws", (try? ClaudeRouterParsing.action(fromResponse: Data(#"{"stop_reason":"refusal","content":[]}"#.utf8))) == nil)
            checkEq("clarify height = 148 + choices x 34", AssistantMetrics.height(for: .clarify(choices: 3)), 250)
            checkEq("clarify wins after launch", AssistantPanelContent.resolve(
                main: nil, hasApproval: false, questionRows: nil, finishedFiles: 0, showsDiff: false,
                clarifyChoices: 2), .clarify(choices: 2))
            let body = String(data: ClaudeRouterParsing.requestBody(input: input("hi"), model: "m"), encoding: .utf8) ?? ""
            checkTrue("body has schema format and no thinking/tool_choice",
                      body.contains("\"json_schema\"") && !body.contains("thinking") && !body.contains("tool_choice"))
        }

        print("")
        print("Mochi workers: Claude arguments and MCP config")
        do {
            let mcp = MochiTools.claudeMCPConfig(hookPath: "/hook/nb-hook", owner: "sid-1")
            let fresh = MochiTools.claudeWorkerArguments(sessionId: "sid-1", resume: false, model: nil, mcpConfig: mcp)
            checkEq("stream-json trio, verbose, headless",
                    Array(fresh.prefix(6)), ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose"])
            checkTrue("new session uses --session-id", fresh.contains("--session-id") && !fresh.contains("--resume"))
            checkEq("the id follows the flag", fresh[fresh.firstIndex(of: "--session-id")! + 1], "sid-1")
            checkTrue("--mcp-config carries the config", fresh.firstIndex(of: "--mcp-config").map { fresh[$0 + 1] == mcp } ?? false)
            checkTrue("note appended to the system prompt",
                      fresh.firstIndex(of: "--append-system-prompt").map { fresh[$0 + 1] == MochiTools.workerNote } ?? false)
            checkTrue("no --model without a model", !fresh.contains("--model"))
            checkEq("only Mochi's own report tool is pre-allowed",
                    fresh[fresh.firstIndex(of: "--allowedTools")! + 1], "mcp__coucou__report")
            checkTrue("never loosens permissions",
                      !fresh.contains { $0.contains("permission-mode") || $0.contains("dangerously") || $0.contains("bypass") })
            checkTrue("the prompt is never an argument", !fresh.contains("--"))
            let resumed = MochiTools.claudeWorkerArguments(sessionId: "sid-1", resume: true,
                                                           model: ModelRef(providerID: nil, id: "sonnet"), mcpConfig: mcp)
            checkTrue("resume uses --resume, not --session-id", resumed.contains("--resume") && !resumed.contains("--session-id"))
            checkEq("--model only when given", resumed[resumed.firstIndex(of: "--model")! + 1], "sonnet")
            checkTrue("resume still has the stream-json trio and --mcp-config",
                      resumed.contains("--input-format") && resumed.contains("--output-format") && resumed.contains("--mcp-config"))

            let obj = (try? JSONSerialization.jsonObject(with: Data(mcp.utf8))) as? [String: Any]
            let server = ((obj?["mcpServers"] as? [String: Any])?["coucou"]) as? [String: Any]
            checkTrue("config is valid JSON with a server named coucou", server != nil)
            checkEq("server command", server?["command"] as? String, "/bin/sh")
            checkEq("server args", server?["args"] as? [String], ["/hook/nb-hook", "--mcp"])
            let env = server?["env"] as? [String: String]
            checkEq("env role", env?["COUCOU_ROLE"], "worker")
            checkEq("env runtime", env?["COUCOU_RUNTIME"], "claude")
            checkEq("env owner is the session id", env?["COUCOU_OWNER"], "sid-1")
        }

        print("")
        print("Mochi brain on the Claude Code login: arguments, config, models")
        do {
            let mcp = MochiTools.claudeBrainMCPConfig(hookPath: "/hook/nb-hook")
            let a = MochiTools.claudeBrainArguments(sessionId: "sid-b", resume: false, model: "claude-sonnet-5-5", mcpConfig: mcp)
            func value(_ flag: String) -> String? { a.firstIndex(of: flag).map { a[$0 + 1] } }
            checkEq("stream-json trio, verbose, headless",
                    Array(a.prefix(6)), ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose"])
            checkTrue("new conversation: --session-id, not --resume", value("--session-id") == "sid-b" && !a.contains("--resume"))
            checkEq("model", value("--model"), "claude-sonnet-5-5")
            checkEq("system prompt is the brain prompt", value("--system-prompt"), MochiTools.brainPrompt)
            checkTrue("never appends to Claude Code's own prompt", !a.contains("--append-system-prompt"))
            checkEq("no built-in tools (empty --tools)", value("--tools"), "")
            checkEq("no settings sources (no hooks, CLAUDE.md, plugins, permissions)", value("--setting-sources"), "")
            checkTrue("strict MCP config", a.contains("--strict-mcp-config") && value("--mcp-config") == mcp)
            checkTrue("skills off", a.contains("--disable-slash-commands"))
            checkTrue("not --bare (it would drop the Claude login)", !a.contains("--bare"))
            checkTrue("never loosens permissions",
                      !a.contains { $0.contains("permission-mode") || $0.contains("dangerously") || $0.contains("bypass") })
            let allowed = (value("--allowedTools") ?? "").split(separator: ",").map(String.init)
            checkEq("allowedTools: exactly the nine brain tools", allowed.sorted(),
                    ["list_projects", "project_status", "start_project_work", "send_to_project", "ask_user", "report", "open_app", "open_url", "open_file"]
                        .map { "mcp__coucou__\($0)" }.sorted())
            checkTrue("no web tool: the brain has none on the API either",
                      !allowed.contains { $0.contains("Web") } && !MochiTools.brainTools().contains { $0.name.contains("web") })
            checkTrue("prompt is never an argument beyond its flag", !a.contains("--"))
            let r = MochiTools.claudeBrainArguments(sessionId: "sid-b", resume: true, model: "claude-opus-5-5", mcpConfig: mcp)
            checkTrue("later launches use --resume", r.contains("--resume") && !r.contains("--session-id"))
            checkEq("the id follows --resume", r[r.firstIndex(of: "--resume")! + 1], "sid-b")

            let obj = (try? JSONSerialization.jsonObject(with: Data(mcp.utf8))) as? [String: Any]
            let servers = obj?["mcpServers"] as? [String: Any]
            checkEq("one MCP server", servers?.count, 1)
            let server = servers?["coucou"] as? [String: Any]
            checkEq("server args", server?["args"] as? [String], ["/hook/nb-hook", "--mcp"])
            let env = server?["env"] as? [String: String]
            checkEq("env role brain", env?["COUCOU_ROLE"], "brain")
            checkEq("env runtime", env?["COUCOU_RUNTIME"], "claude-brain")
            checkEq("env owner", env?["COUCOU_OWNER"], "mochi-brain")

            let e = MochiTools.claudeBrainEnvironment
            checkTrue("MCP tool timeout is longer than an hour", (Int(e["MCP_TOOL_TIMEOUT"] ?? "") ?? 0) > 3_600_000)
            checkEq("silent-call timeout off", e["CLAUDE_CODE_MCP_TOOL_IDLE_TIMEOUT"], "0")

            checkEq("Anthropic list, newest first", BrainModels.anthropic.map(\.id),
                    ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5", "claude-fable-5-1"])
            checkEq("brain default model", BrainModels.defaultAnthropic, "claude-sonnet-5-5")
            checkEq("an Anthropic", BrainModels.withArticle("Anthropic"), "an Anthropic")
            checkEq("an OpenAI", BrainModels.withArticle("OpenAI"), "an OpenAI")
            checkEq("a Google", BrainModels.withArticle("Google"), "a Google")
            checkEq("a Mistral", BrainModels.withArticle("Mistral"), "a Mistral")
        }

        print("")
        print("Brain MCP: the nine tools through the relay's JSON-RPC")
        do {
            var ran: [String] = []
            func call(_ name: String, _ args: String) async -> (text: String, isError: Bool) {
                ran.append(name); return (name == "ask_user" ? "The user chose: Yes" : "ok", false)
            }
            let list = await MochiTools.brainMCPResponse(to: ["jsonrpc": "2.0", "id": 1, "method": "tools/list"]) { n, a in await call(n, a) }
            let tools = (list?["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []
            checkEq("tools/list names the nine", tools.compactMap { $0["name"] as? String }, MochiTools.brainToolNames)
            checkTrue("every tool has a schema", tools.allSatisfy { ($0["inputSchema"] as? [String: Any])?["type"] as? String == "object" })
            let init1 = await MochiTools.brainMCPResponse(to: ["jsonrpc": "2.0", "id": 2, "method": "initialize"]) { n, a in await call(n, a) }
            checkEq("initialize answers with the server name",
                    ((init1?["result"] as? [String: Any])?["serverInfo"] as? [String: Any])?["name"] as? String, "coucou")
            let ask = await MochiTools.brainMCPResponse(to: ["jsonrpc": "2.0", "id": 3, "method": "tools/call",
                                                            "params": ["name": "ask_user", "arguments": ["question": "q"]]]) { n, a in await call(n, a) }
            let content = ((ask?["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String
            checkEq("tools/call runs the tool and returns its text", content, "The user chose: Yes")
            checkEq("the tool ran once", ran, ["ask_user"])
            let unknown = await MochiTools.brainMCPResponse(to: ["jsonrpc": "2.0", "id": 4, "method": "tools/call",
                                                                "params": ["name": "Bash", "arguments": [:]]]) { n, a in await call(n, a) }
            checkTrue("an unknown tool is an error and runs nothing", unknown?["error"] != nil && ran == ["ask_user"])
            let note = await MochiTools.brainMCPResponse(to: ["jsonrpc": "2.0", "method": "notifications/initialized"]) { n, a in await call(n, a) }
            checkTrue("a notification gets no answer", note == nil)
        }

        print("")
        print("Mac actions: arguments, app names, readiness")
        do {
            let apps = ["Google Chrome", "Safari", "Notes", "Visual Studio Code", "System Settings", "Google Earth Pro"]
            checkEq("alias chrome", MacActionLogic.match("chrome", in: apps), "Google Chrome")
            checkEq("case and .app ignored", MacActionLogic.match("  SAFARI.app ", in: apps), "Safari")
            checkEq("alias vscode", MacActionLogic.match("vs code", in: apps), "Visual Studio Code")
            checkEq("alias settings", MacActionLogic.match("settings", in: apps), "System Settings")
            checkEq("a single prefix match", MacActionLogic.match("note", in: apps), "Notes")
            checkEq("an ambiguous name matches nothing", MacActionLogic.match("google", in: ["Google Chrome", "Google Earth Pro", "Google Docs"]), nil)
            checkEq("unknown app", MacActionLogic.match("photoshop", in: apps), nil)
            checkTrue("closest names help", MacActionLogic.closest("goog", in: apps).contains("Google Chrome"))
            checkEq("app name from args", MacActionLogic.appName(from: ["name": " Notes "]), "Notes")
            checkEq("a path is not an app name", MacActionLogic.appName(from: ["name": "/bin/sh"]), nil)
            checkEq("empty name refused", MacActionLogic.appName(from: ["name": "  "]), nil)
            checkEq("missing name refused", MacActionLogic.appName(from: [:]), nil)
            checkEq("https url accepted", MacActionLogic.urlRequest(from: ["url": "https://github.com"])?.url.absoluteString, "https://github.com")
            checkEq("with an app", MacActionLogic.urlRequest(from: ["url": "https://github.com", "app": "chrome"])?.app, "chrome")
            checkTrue("file:// refused", MacActionLogic.urlRequest(from: ["url": "file:///etc/passwd"]) == nil)
            checkTrue("custom scheme refused", MacActionLogic.urlRequest(from: ["url": "zoommtg://x"]) == nil)
            checkTrue("a path as app refused", MacActionLogic.urlRequest(from: ["url": "https://a.com", "app": "/bin/sh"])?.app == nil)
            checkEq("~ expands", MacActionLogic.fileRequest(from: ["path": "~/Desktop/a.txt"], home: "/Users/x")?.path, "/Users/x/Desktop/a.txt")
            checkEq("absolute kept, reveal read", MacActionLogic.fileRequest(from: ["path": "/tmp/a", "reveal": true])?.reveal, true)
            checkTrue("relative path refused", MacActionLogic.fileRequest(from: ["path": "a.txt"]) == nil)
            checkTrue("missing path refused", MacActionLogic.fileRequest(from: [:]) == nil)

            func st(_ kind: BrainReadiness.Kind, enabled: Bool = true, name: String = "Anthropic", key: Bool = false,
                    addr: Bool = false, zen: Bool = false, cli: Bool = false) -> (text: String, ok: Bool) {
                BrainReadiness.status(enabled: enabled, kind: kind, providerName: name, hasKey: key, localAddressSet: addr,
                                      zenSignedIn: zen, cliFound: cli)
            }
            checkEq("off", st(.apiKey, enabled: false).text, "Off. Nothing is sent to any provider.")
            checkEq("Anthropic API, no key, no CLI", st(.anthropicAPI).text, "Add an Anthropic key in Chat first.")
            checkTrue("Anthropic API, no key, CLI found: points at the subscription",
                      st(.anthropicAPI, cli: true).text.hasPrefix("No Anthropic API key. To use your Claude subscription") && !st(.anthropicAPI, cli: true).ok)
            checkTrue("Anthropic API with a key", st(.anthropicAPI, key: true) == ("Ready.", true))
            checkEq("OpenAI, no key", st(.apiKey, name: "OpenAI").text, "Add an OpenAI key in Chat first.")
            checkEq("Google, no key, CLI found keeps the plain text", st(.apiKey, name: "Google", cli: true).text, "Add a Google key in Chat first.")
            checkEq("local not connected", st(.local, name: "Ollama").text, "Connect Ollama in Chat first.")
            checkTrue("local connected", st(.local, name: "Ollama", addr: true).ok)
            checkEq("OpenCode signed out", st(.opencode).text, "Sign in to OpenCode first (opencode auth login).")
            checkEq("Claude login without the CLI", st(.claudeLogin).text, "Claude Code not found.")
            checkTrue("Claude login with the CLI", st(.claudeLogin, cli: true) == ("Ready.", true))
        }

        print("")
        print("First sentence of a reply")
        do {
            checkEq("stops at the first full stop", MochiTools.firstSentence("Started it. Then more."), "Started it.")
            checkEq("keeps a decimal point", MochiTools.firstSentence("Version 2.1 is out. Yes."), "Version 2.1 is out.")
            checkEq("no stop: whole text, on one line", MochiTools.firstSentence("one\ntwo"), "one two")
            checkEq("empty stays empty", MochiTools.firstSentence("  "), "")
        }

        print("")
        print("Bar target for a worker")
        do {
            func s(_ phase: SessionPhase, kind: AgentKind = .claudeCode, cwd: String = "/code/a") -> AgentSession {
                var x = sess("w1", phase: phase); x.kind = kind; x.cwd = cwd; return x
            }
            checkEq("busy non-worker gets a new task", AssistantBarLogic.target(main: s(.working)), .newTask)
            checkEq("busy worker takes the text on its stream",
                    AssistantBarLogic.target(main: s(.working), isWorker: true), .claudeReply(sessionId: "w1"))
            checkEq("worker waiting on an approval takes nothing",
                    AssistantBarLogic.target(main: s(.approval), isWorker: true), .newTask)
            checkEq("worker waiting on a question takes nothing",
                    AssistantBarLogic.target(main: s(.question), isWorker: true), .newTask)
            checkEq("finished worker is replied to",
                    AssistantBarLogic.target(main: s(.finished), isWorker: true), .claudeReply(sessionId: "w1"))
            checkEq("OpenCode worker is replied to",
                    AssistantBarLogic.target(main: s(.working, kind: .openCode), isWorker: true), .reply(sessionId: "w1"))
        }

        print("")
        print("OpenCode events (recorded from a real OpenCode 2.0.16 server)")
        do {
            // Scenarios are separated by `: scenario <name>` comment lines.
            let text = (try? String(contentsOfFile: "tests/fixtures/opencode-events.txt", encoding: .utf8)) ?? ""
            checkTrue("fixture is there and short", !text.isEmpty && text.split(separator: "\n").count <= 200)
            checkTrue("fixture holds nothing personal", !text.contains("/Users/k") && !text.lowercased().contains("kepla"))
            var scenarios: [String: [[String: Any]]] = [:]
            var current = ""
            for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
                if line.hasPrefix(": scenario ") { current = String(line.dropFirst(11)); scenarios[current] = [] }
                else if let obj = OpenCodeEvents.parseLine(line) { scenarios[current, default: []].append(obj) }
            }
            checkEq("heartbeat comment is not an event", OpenCodeEvents.parseLine(": heartbeat") == nil, true)
            checkEq("blank line is not an event", OpenCodeEvents.parseLine("") == nil, true)
            checkEq("garbage is not an event", OpenCodeEvents.parseLine("data: nope") == nil, true)
            let step: (String) -> String = { $0 }

            /// Runs a scenario through the translator and a store; returns every signal and the phase after each.
            func run(_ name: String) -> (signals: [OpenCodeSignal], phases: [SessionPhase?], store: AgentSessionStore) {
                var state = OpenCodeEventState()
                var store = AgentSessionStore()
                var all: [OpenCodeSignal] = [], phases: [SessionPhase?] = []
                var sid = ""
                for ev in scenarios.first(where: { $0.key.hasPrefix(name) })?.value ?? [] {
                    for sig in OpenCodeEvents.translate(ev, state: &state) {
                        all.append(sig)
                        var event: SessionEvent?
                        switch sig {
                        case .session(let id, _, let e): sid = id; event = e
                        case .toolStart(let id, let tool, _): sid = id; event = .toolStart(step: step(tool))
                        default: break
                        }
                        if let event {
                            store.apply(event, sessionId: sid, kind: .openCode, cwd: "/Users/me/project",
                                        colorHex: "#fff", now: Date(timeIntervalSince1970: 1_000_000))
                            phases.append(store.sessions[sid]?.phase)
                        }
                    }
                }
                return (all, phases, store)
            }

            let perm = run("permission")
            checkEq("permission scenario: idle, thinking, working, approval, working, finished",
                    perm.phases.compactMap { $0 }.reduce(into: [SessionPhase]()) { if $0.last != $1 { $0.append($1) } },
                    [.idle, .thinking, .working, .approval, .working, .finished])
            var asked: (id: String, req: String, tool: String, command: String)?
            var settled: String?
            for sig in perm.signals {
                if case .approval(let id, let req, let tool, let cmd, _) = sig { asked = (id, req, tool, cmd) }
                if case .approvalSettled(_, let req) = sig { settled = req }
            }
            checkEq("approval: tool is Bash (shell)", asked?.tool, "Bash")
            checkEq("approval: the command", asked?.command, "echo hi > /tmp/coucou-oc-test-3.txt")
            checkTrue("approval: request id kept", asked?.req.hasPrefix("per_") == true)
            checkEq("the settle names the same request", settled, asked?.req)
            checkEq("finished card gets the last text as its reply",
                    perm.store.sessions.values.first?.reply?.isEmpty == false, true)
            checkEq("cwd comes from session.created",
                    perm.signals.compactMap { s -> String? in if case .session(_, let cwd, .start) = s { return cwd } else { return nil } },
                    ["/Users/me/project"])
            checkEq("tool names are Claude's", perm.signals.compactMap { s -> String? in
                if case .toolStart(_, let tool, _) = s { return tool } else { return nil } }, ["Bash"])

            let ask = run("question: a form is asked")
            var formQuestion: AskQuestion?
            var formMap: OpenCodeFormMap?
            for sig in ask.signals { if case .question(_, _, let q, let m, _) = sig { formQuestion = q; formMap = m } }
            checkEq("question: phase is question", ask.store.sessions.values.first?.phase, .question)
            checkEq("question: text", formQuestion?.questions.first?.question, "Which color?")
            checkEq("question: header", formQuestion?.questions.first?.header, "Color")
            checkEq("question: options", formQuestion?.questions.first?.options.map(\.label), ["Red", "Blue"])
            checkEq("question: field key", formMap?.keys["Which color?"], "q0")
            checkEq("card answer maps back to the form's answer",
                    NSDictionary(dictionary: OpenCodeEvents.formAnswer(cardAnswers: ["Which color?": "Red"], map: formMap ?? OpenCodeFormMap())),
                    NSDictionary(dictionary: ["q0": "Red"]))
            checkEq("typed 'Other' text passes through",
                    OpenCodeEvents.formAnswer(cardAnswers: ["Which color?": "Green"], map: formMap ?? OpenCodeFormMap())["q0"] as? String, "Green")
            let answered = run("question: the form is answered")
            checkEq("answered form settles", answered.signals.contains { if case .questionSettled = $0 { return true } else { return false } }, true)
            checkEq("then finishes with the reply", answered.store.sessions.values.first?.reply, "You picked **Red**.")

            let stopped = run("interrupt")
            checkEq("interrupt ends in idle", stopped.store.sessions.values.first?.phase, .idle)
            let failed = run("failure")
            let session = failed.store.sessions.values.first
            checkEq("failure: blocked", session?.phase, .blocked)
            checkEq("failure: OpenCode's own text", session?.failure?.message, "Model unavailable: opencode/not-a-real-model")
            checkEq("failure: kind", session?.failure?.kind, "model_not_found")

            var empty = OpenCodeEventState()
            checkEq("server.connected is ignored", OpenCodeEvents.translate(["type": "server.connected", "data": [String: Any]()], state: &empty).isEmpty, true)
            checkEq("unknown events are ignored", OpenCodeEvents.translate(["type": "integration.updated", "data": ["sessionID": "ses_1"]], state: &empty).isEmpty, true)

            let form: [String: Any] = ["id": "frm_1", "sessionID": "ses_1", "fields": [
                ["key": "a", "title": "A", "description": "Pick several", "type": "array",
                 "options": [["value": "x", "label": "X"], ["value": "y", "label": "Y"]]],
                ["key": "b", "title": "B", "description": "Sure?", "type": "boolean"]]]
            let multi = OpenCodeEvents.askQuestion(fromForm: form)
            checkEq("array field is multi-select", multi?.0.questions.first?.multiSelect, true)
            checkEq("boolean field gets Yes/No", multi?.0.questions.last?.options.map(\.label), ["Yes", "No"])
            checkEq("multi answer maps labels to values",
                    OpenCodeEvents.formAnswer(cardAnswers: ["Pick several": ["X", "Y"], "Sure?": "Yes"], map: multi?.1 ?? OpenCodeFormMap())["a"] as? [String], ["x", "y"])
            checkEq("boolean answer maps to the value", OpenCodeEvents.formAnswer(cardAnswers: ["Sure?": "No"], map: multi?.1 ?? OpenCodeFormMap())["b"] as? String, "false")
            let five = (0..<5).map { ["key": "k\($0)", "title": "T\($0)", "description": "Q\($0)", "type": "string"] as [String: Any] }
            let big = OpenCodeEvents.askQuestion(fromForm: ["id": "f", "sessionID": "s", "fields": five])
            checkEq("the card shows at most 4 questions", big?.0.questions.count, 4)
            checkEq("the fifth field is answered empty, not left out",
                    OpenCodeEvents.formAnswer(cardAnswers: [:], map: big?.1 ?? OpenCodeFormMap())["k4"] as? String, "")
        }

        print("")
        print("OpenCode worker config and models")
        do {
            let json = MochiTools.openCodeConfigContent(hookPath: "/Users/me/Library/Application Support/NotchBuddy/nb-hook",
                                                        owner: "/Users/me/project")
            let obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
            let server = ((obj?["mcp"] as? [String: Any])?["coucou"]) as? [String: Any]
            checkTrue("config is valid JSON with mcp.coucou", server != nil)
            checkEq("server type", server?["type"] as? String, "local")
            checkEq("server command is /bin/sh <hook> --mcp", server?["command"] as? [String],
                    ["/bin/sh", "/Users/me/Library/Application Support/NotchBuddy/nb-hook", "--mcp"])
            let env = server?["environment"] as? [String: String]
            checkEq("env runtime", env?["COUCOU_RUNTIME"], "opencode")
            checkEq("env owner is the project folder", env?["COUCOU_OWNER"], "/Users/me/project")
            checkEq("env role", env?["COUCOU_ROLE"], "worker")
            checkEq("the worker note is a file next to the hook", obj?["instructions"] as? [String],
                    ["/Users/me/Library/Application Support/NotchBuddy/\(MochiTools.workerNoteFileName)"])
            checkTrue("permissions stay the user's own: no permission key at all", obj?["permission"] == nil && !json.contains("\"allow\"") && !json.contains("\"ask\""))
            checkEq("only mcp and instructions are added", Set(obj?.keys.map { $0 } ?? []), ["mcp", "instructions"])
            checkEq("catalog id splits at the first slash", ModelRef.openCode(catalogId: "openrouter/anthropic/claude-x"),
                    ModelRef(providerID: "openrouter", id: "anthropic/claude-x"))
            checkEq("an id with no provider is refused", ModelRef.openCode(catalogId: "gpt-5"), nil)
            checkEq("empty Claude alias means the default", ModelRef.claude("  "), nil)
            checkEq("Claude alias", ModelRef.claude("sonnet"), ModelRef(providerID: nil, id: "sonnet"))
        }

        print("")
        print("Worker report tool (MCP)")
        do {
            let tools = MochiTools.workerToolList()
            checkEq("exactly one tool, report", tools.map { $0["name"] as? String }, ["report"])
            let schema = tools.first?["inputSchema"] as? [String: Any]
            checkEq("only `line` is required", schema?["required"] as? [String], ["line"])
            let props = schema?["properties"] as? [String: Any]
            checkEq("and `actions` is allowed", Set(props?.keys.map { $0 } ?? []), ["line", "actions"])

            checkEq("valid report", MochiTools.parseReport(["line": "Server is up.", "actions": [
                ["label": "Open in browser", "open": "http://localhost:8123"]]]),
                MochiNote(line: "Server is up.", actions: [MochiAction(label: "Open in browser", kind: .openURL("http://localhost:8123"))]))
            checkEq("missing line is nil", MochiTools.parseReport(["actions": []]), nil)
            checkEq("blank line is nil", MochiTools.parseReport(["line": "  \n "]), nil)
            checkEq("newlines flattened", MochiTools.parseReport(["line": "one\ntwo"])?.line, "one two")
            let four = (1...4).map { ["label": "A\($0)", "copy": "x\($0)"] as [String: Any] }
            checkEq("four actions become three", MochiTools.parseReport(["line": "x", "actions": four])?.actions.count, 3)
            checkEq("file:// action is dropped", MochiTools.parseReport(["line": "x", "actions": [
                ["label": "Bad", "open": "file:///Applications/Calculator.app"], ["label": "Ok", "copy": "x"]]])?.actions.map(\.label), ["Ok"])
            checkEq("focus is rejected (digest buttons are never model output)", MochiTools.parseReport(["line": "x", "actions": [
                ["label": "Go", "focus": "some-session"]]])?.actions.count, 0)
            checkEq("duplicate labels collapse", MochiTools.parseReport(["line": "x", "actions": [
                ["label": "A", "copy": "1"], ["label": "A", "copy": "2"]]])?.actions.count, 1)
            checkEq("very long line is cut", MochiTools.parseReport(["line": String(repeating: "w", count: 600)])?.line?.count, MochiTools.maxReportLine)
            checkTrue("the note speaks of the report tool, not tags",
                      MochiTools.workerNote.contains("`report`") && !MochiTools.workerNote.contains("<mochi"))

            // JSON-RPC: what an MCP client sends, and what it must get back.
            var got: MochiNote?
            func call(_ rpc: [String: Any], fail: String? = nil) -> [String: Any]? {
                MochiTools.mcpResponse(to: rpc) { note in got = note; return fail }
            }
            let initialize = call(["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                   "params": ["protocolVersion": "2025-06-18", "capabilities": [String: Any](),
                                              "clientInfo": ["name": "x", "version": "1"]]])
            let result = initialize?["result"] as? [String: Any]
            checkEq("initialize answers with the pinned protocol", result?["protocolVersion"] as? String, "2025-06-18")
            checkEq("initialize names the server coucou", (result?["serverInfo"] as? [String: Any])?["name"] as? String, "coucou")
            checkEq("initialize advertises tools", (result?["capabilities"] as? [String: Any])?.keys.contains("tools"), true)
            checkEq("the id is echoed", initialize?["id"] as? Int, 1)
            checkEq("string ids are echoed too", call(["jsonrpc": "2.0", "id": "a", "method": "ping"])?["id"] as? String, "a")
            checkTrue("a notification gets no answer", call(["jsonrpc": "2.0", "method": "notifications/initialized"]) == nil)
            let list = (call(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])?["result"] as? [String: Any])?["tools"] as? [[String: Any]]
            checkEq("tools/list lists report", list?.map { $0["name"] as? String }, ["report"])
            let ok = call(["jsonrpc": "2.0", "id": 3, "method": "tools/call",
                           "params": ["name": "report", "arguments": ["line": "Done."]]])
            checkEq("report reaches the handler", got?.line, "Done.")
            checkEq("report is answered 'Shown to the user.'",
                    (((ok?["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"]) as? String, "Shown to the user.")
            checkEq("and is not an error", (ok?["result"] as? [String: Any])?["isError"] as? Bool, false)
            got = nil
            let bad = call(["jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": ["name": "report", "arguments": ["line": ""]]])
            checkEq("a malformed report is an error result", (bad?["result"] as? [String: Any])?["isError"] as? Bool, true)
            checkTrue("and never reaches the handler", got == nil)
            let noOwner = call(["jsonrpc": "2.0", "id": 5, "method": "tools/call",
                                "params": ["name": "report", "arguments": ["line": "x"]]], fail: "No Mochi worker is running for this report.")
            checkEq("no live worker: error result with the reason", (((noOwner?["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"]) as? String,
                    "No Mochi worker is running for this report.")
            checkEq("no live worker: isError", (noOwner?["result"] as? [String: Any])?["isError"] as? Bool, true)
            checkEq("unknown tool is a JSON-RPC error", ((call(["jsonrpc": "2.0", "id": 6, "method": "tools/call",
                "params": ["name": "rm_rf", "arguments": [String: Any]()]])?["error"]) as? [String: Any])?["code"] as? Int, -32602)
            checkEq("unknown method is a JSON-RPC error", ((call(["jsonrpc": "2.0", "id": 7, "method": "resources/list"])?["error"]) as? [String: Any])?["code"] as? Int, -32601)

            // OpenCode: a folder's report goes to the busy worker, else the latest one.
            var idle = sess("old", phase: .finished, last: 100); idle.kind = .openCode
            var busyOne = sess("busy", phase: .working, last: 50); busyOne.kind = .openCode
            var newer = sess("newer", phase: .finished, last: 200); newer.kind = .openCode
            checkEq("the busy worker wins", MochiReportTarget.pick(from: [idle, busyOne, newer]), "busy")
            checkEq("else the most recently active", MochiReportTarget.pick(from: [idle, newer]), "newer")
            checkEq("nobody: nil", MochiReportTarget.pick(from: []), nil)
        }

        print("")
        print("Brain: tools, wire formats, history")
        do {
            func fixture(_ name: String) -> Data { (try? Data(contentsOf: URL(fileURLWithPath: "tests/fixtures/\(name)"))) ?? Data() }
            checkEq("exactly the nine tools", MochiTools.brainTools().map(\.name), MochiTools.brainToolNames)
            checkEq("their names", MochiTools.brainToolNames,
                    ["list_projects", "project_status", "start_project_work", "send_to_project", "ask_user", "report", "open_app", "open_url", "open_file"])
            checkTrue("no file, shell or network tool", !MochiTools.brainTools().contains { t in
                ["bash", "shell", "read", "write", "edit", "fetch", "http"].contains { t.name.lowercased().contains($0) } })
            let tools = MochiTools.brainTools()
            checkTrue("every tool has a JSON schema object", tools.allSatisfy { $0.schema["type"] as? String == "object" })
            checkEq("start_project_work requires project and task",
                    (tools.first { $0.name == "start_project_work" }?.schema["required"] as? [String]) ?? [], ["project", "task"])
            checkEq("ask_user takes 2 to 4 choices",
                    ((tools.first { $0.name == "ask_user" }?.schema["properties"] as? [String: Any])?["choices"] as? [String: Any])?["maxItems"] as? Int, 4)
            checkTrue("the prompt hands project work to the project and ends with report",
                      MochiTools.brainPrompt.contains("start_project_work") && MochiTools.brainPrompt.contains("report")
                      && MochiTools.brainPrompt.contains("ask_user"))

            // Anthropic: a recorded-shape response, then the round trip of a two-tool conversation.
            let a = BrainWire.parseAnthropic(fixture("brain-anthropic-response.json"))
            checkEq("anthropic: text", a?.text, "I'll find the project first.")
            checkEq("anthropic: two tool calls", a?.toolCalls.map(\.name), ["list_projects", "start_project_work"])
            checkEq("anthropic: call id kept", a?.toolCalls.first?.id, "toolu_01A09q90qw90lq917835lq9")
            checkEq("anthropic: arguments read", a?.toolCalls.last?.arguments["runtime"] as? String, "claude")
            checkEq("anthropic: plain text answer", BrainWire.parseAnthropic(fixture("brain-anthropic-text.json")),
                    BrainTurn(text: "Nairobi.", toolCalls: []))
            checkTrue("anthropic: an error object is not a turn", BrainWire.parseAnthropic(fixture("brain-anthropic-error.json")) == nil)
            checkTrue("anthropic: garbage is not a turn", BrainWire.parseAnthropic(Data("hi".utf8)) == nil)

            let convo: [BrainMessage] = [
                .user("In coucou, add a README section about setup"),
                .assistant(a ?? BrainTurn(text: "", toolCalls: [])),
                .tool(id: "toolu_01A09q90qw90lq917835lq9", "[{\"name\":\"coucou\"}]"),
                .tool(id: "toolu_01B1xyz", "Started in coucou with Claude Code", isError: false),
                .user("and what is going on now?"),
            ]
            let ab = BrainWire.anthropicBody(model: "claude-sonnet-4-6", system: "SYS", messages: convo, tools: tools)
            checkEq("anthropic body: model and system", [ab["model"] as? String, ab["system"] as? String], ["claude-sonnet-4-6", "SYS"])
            checkEq("anthropic body: nine tools", (ab["tools"] as? [[String: Any]])?.count, 9)
            checkTrue("anthropic body: tools carry input_schema", (ab["tools"] as? [[String: Any]])?.allSatisfy { $0["input_schema"] != nil } == true)
            let am = ab["messages"] as? [[String: Any]] ?? []
            checkEq("anthropic body: roles alternate user, assistant, user", am.map { $0["role"] as? String }, ["user", "assistant", "user"])
            let assistantBlocks = am[1]["content"] as? [[String: Any]] ?? []
            checkEq("anthropic body: assistant keeps text and both tool_use blocks",
                    assistantBlocks.map { $0["type"] as? String }, ["text", "tool_use", "tool_use"])
            let lastUser = am[2]["content"] as? [[String: Any]] ?? []
            checkEq("anthropic body: both tool results and the new text share one user message",
                    lastUser.map { $0["type"] as? String }, ["tool_result", "tool_result", "text"])
            checkEq("anthropic body: tool result points at its call", lastUser[1]["tool_use_id"] as? String, "toolu_01B1xyz")
            // The body must survive being sent: round-trip through JSON.
            checkTrue("anthropic body is valid JSON", JSONSerialization.isValidJSONObject(ab))
            let again = BrainWire.parseAnthropic(try! JSONSerialization.data(withJSONObject: ["content": assistantBlocks]))
            checkEq("anthropic: what we send for an assistant turn reads back the same", again?.toolCalls.map(\.id), a?.toolCalls.map(\.id))

            // OpenAI-compatible
            let o = BrainWire.parseOpenAI(fixture("brain-openai-response.json"))
            checkEq("openai: no text when content is null", o?.text, "")
            checkEq("openai: two tool calls", o?.toolCalls.map(\.name), ["list_projects", "start_project_work"])
            checkEq("openai: arguments are read from the text", o?.toolCalls.last?.arguments["model"] as? String, "openai/gpt-5")
            checkEq("openai: not flagged", o?.unparsable, false)
            checkEq("openai: plain text", BrainWire.parseOpenAI(fixture("brain-openai-text.json")), BrainTurn(text: "Nairobi.", toolCalls: []))
            let bad = BrainWire.parseOpenAI(fixture("brain-openai-malformed.json"))
            checkEq("openai: malformed arguments are flagged", bad?.unparsable, true)
            let ol = BrainWire.parseOpenAI(fixture("brain-ollama-object-args.json"))
            checkEq("openai: arguments sent as an object are accepted", ol?.toolCalls.first?.arguments["line"] as? String, "Done.")
            checkEq("openai: and not flagged", ol?.unparsable, false)
            checkTrue("openai: no choices is not a turn", BrainWire.parseOpenAI(Data(#"{"error":{"message":"x"}}"#.utf8)) == nil)

            let ob = BrainWire.openAIBody(model: "gpt-4o", system: "SYS", messages: [
                .user("hi"), .assistant(o ?? BrainTurn(text: "", toolCalls: [])),
                .tool(id: "call_1", "[]"), .tool(id: "call_2", "ok")], tools: tools)
            let om = ob["messages"] as? [[String: Any]] ?? []
            checkEq("openai body: system, user, assistant, tool, tool", om.map { $0["role"] as? String }, ["system", "user", "assistant", "tool", "tool"])
            let tc = om[2]["tool_calls"] as? [[String: Any]]
            checkEq("openai body: assistant tool calls with function.arguments as text", (tc?.last?["function"] as? [String: Any])?["arguments"] is String, true)
            checkEq("openai body: tool result points at its call", om[4]["tool_call_id"] as? String, "call_2")
            checkEq("openai body: tools are functions", ((ob["tools"] as? [[String: Any]])?.first?["type"] as? String), "function")
            checkTrue("openai body is valid JSON", JSONSerialization.isValidJSONObject(ob))

            // History
            let long = (0..<30).flatMap { i -> [BrainMessage] in
                [.user("q\(i)"), .assistant(BrainTurn(text: "", toolCalls: [BrainToolCall(id: "c\(i)", name: "report", arguments: [:])])),
                 .tool(id: "c\(i)", "ok")] }
            let trimmed = BrainHistory.trimmed(long)
            checkTrue("history is cut to about 40", trimmed.count <= BrainHistory.keep && trimmed.count > BrainHistory.keep - 3)
            checkEq("history starts at a user message", trimmed.first?.role, .user)
            checkEq("short history is untouched", BrainHistory.trimmed([.user("a")]).count, 1)
            let enc = try? JSONEncoder().encode(trimmed)
            checkEq("history survives a round trip to disk", enc.flatMap { try? JSONDecoder().decode([BrainMessage].self, from: $0) }, trimmed)

            // ask_user
            let q = BrainToolArgs.question(from: ["question": "Which one?", "choices": ["coucou", "coucou-web", "coucou"]])
            checkEq("ask_user: duplicates collapse", q?.questions.first?.options.map(\.label), ["coucou", "coucou-web"])
            checkTrue("ask_user: one choice is not enough", BrainToolArgs.question(from: ["question": "x", "choices": ["a"]]) == nil)
            checkEq("ask_user: five choices become four",
                    BrainToolArgs.question(from: ["question": "x", "choices": ["a", "b", "c", "d", "e"]])?.questions.first?.options.count, 4)
            checkTrue("ask_user: needs a question", BrainToolArgs.question(from: ["choices": ["a", "b"]]) == nil)
            checkEq("runtime names", [BrainToolArgs.runtime(from: "claude"), BrainToolArgs.runtime(from: "Claude Code"),
                                       BrainToolArgs.runtime(from: "opencode"), BrainToolArgs.runtime(from: "gemini")],
                    [.claudeCode, .claudeCode, .openCode, nil])

            // Project matching: ties are ambiguity
            let ps = [KnownProject(path: "/Users/me/Bapoojee-production"), KnownProject(path: "/Users/me/Bapoojee-staging"),
                      KnownProject(path: "/Users/me/coucou")]
            checkEq("two projects start with the name: both are candidates",
                    ProjectLaunchLogic.candidates(for: "bapoojee", in: ps).map(\.name), ["Bapoojee-production", "Bapoojee-staging"])
            checkEq("an exact name is alone", ProjectLaunchLogic.candidates(for: "coucou", in: ps).map(\.name), ["coucou"])
            checkEq("the full name picks one", ProjectLaunchLogic.candidates(for: "bapoojee production", in: ps).map(\.name), ["Bapoojee-production"])
            checkEq("nothing fits: empty", ProjectLaunchLogic.candidates(for: "zzzzzz", in: ps).count, 0)
        }

        print("")
        print("Pile-up digest")
        do {
            func need(_ id: String, _ ws: String, _ phase: SessionPhase, at: TimeInterval = 0, last: TimeInterval = 0,
                      seen: Bool = false) -> AgentSession {
                sess(id, workspace: ws, phase: phase, attention: phase.needsAttention ? at : nil, last: last, seen: seen)
            }
            let two = [need("a", "alpha", .approval), need("b", "beta", .question), need("c", "gamma", .working)]
            let three = two + [need("d", "delta", .finished)]
            func due(_ s: [AgentSession], last: Date? = nil, below: Bool = true, now: TimeInterval = 1000) -> Bool {
                MochiDigest.needsDigest(sessions: s, lastPostedAt: last, wasBelowThreshold: below, now: at(now))
            }
            checkEq("threshold is 3 and cooldown 60 s", [MochiDigest.threshold, Int(MochiDigest.cooldown)], [3, 60])
            checkEq("below 3: no digest", due(two), false)
            checkEq("2 then 3: digest", due(three), true)
            checkEq("still 3 on the next check: no second digest", due(three, below: false), false)
            checkEq("3, 2, 3 inside 60 s: no digest", due(three, last: at(980)), false)
            checkEq("3, 2, 3 after 60 s: digest", due(three, last: at(930)), true)
            checkEq("exactly 60 s counts as passed", due(three, last: at(940)), true)
            checkEq("a seen finished session does not count", due(two + [need("d", "delta", .finished, seen: true)]), false)
            checkEq("working and idle sessions do not count", due(two + [need("d", "delta", .working), need("e", "eps", .idle)]), false)
            checkEq("blocked counts as needing you", due(two + [need("d", "delta", .blocked)]), true)
            checkEq("the brain's own session is not counted",
                    due(two + [need(MochiDigest.brainSessionId, "Mochi", .finished)]), false)
            checkEq("the digest's own session is not counted either",
                    due(two + [need(MochiDigest.sessionId, "Mochi", .finished)]), false)
            checkTrue("the digest and the brain have separate sessions", MochiDigest.sessionId != MochiDigest.brainSessionId)
            checkEq("only the brain's session needing you: no digest",
                    due([need(MochiDigest.brainSessionId, "Mochi", .question)]), false)
            checkEq("the count agrees", MochiDigest.needCount(three), 3)

            // The line and its buttons
            let mixed = [need("w", "docs", .working, last: 5),
                         need("q", "bapoojee", .question, at: 20), need("ap", "alpha", .approval, at: 10),
                         need("d", "coucou", .finished, at: 15)]
            let note = MochiDigest.note(sessions: mixed, titles: [:])
            checkEq("needs you first (oldest first), then done, then working", note.line,
                    "alpha needs you, bapoojee needs you, coucou is done, docs is still working")
            checkEq("buttons only for sessions that need you, in that order", note.actions.map(\.label), ["alpha", "bapoojee", "coucou"])
            checkEq("a button focuses its session", note.actions.first?.kind, .focus(sessionId: "ap"))
            checkEq("an approval older than a question is named first",
                    MochiDigest.note(sessions: [need("q", "q-ws", .question, at: 20), need("ap", "ap-ws", .approval, at: 10)], titles: [:]).line,
                    "ap-ws needs you, q-ws needs you")
            checkTrue("done comes after needs-you even when it is older",
                      MochiDigest.note(sessions: [need("d", "done-ws", .finished, at: 1), need("q", "q-ws", .question, at: 99)], titles: [:])
                        .line?.hasPrefix("q-ws needs you") == true)
            checkEq("a finished session that was seen is not named",
                    MochiDigest.note(sessions: [need("a", "alpha", .approval), need("d", "done", .finished, seen: true)], titles: [:]).line,
                    "alpha needs you")

            let many = (1...7).map { need("s\($0)", "p\($0)", .approval, at: TimeInterval($0)) }
            let big = MochiDigest.note(sessions: many, titles: [:])
            checkEq("four names, then +N more", big.line, "p1 needs you, p2 needs you, p3 needs you, p4 needs you, +3 more")
            checkEq("at most three buttons", big.actions.count, 3)
            checkTrue("all of them are focus buttons for sessions that need you", big.actions.allSatisfy {
                if case .focus(let id) = $0.kind { return many.contains { $0.id == id } } else { return false } })
            checkEq("the brain's session is never named",
                    MochiDigest.note(sessions: [need(MochiDigest.brainSessionId, "Mochi", .finished), need(MochiDigest.sessionId, "Mochi", .finished), need("a", "alpha", .approval)], titles: [:]).line,
                    "alpha needs you")
            let same = [need("x1", "app", .approval, at: 1), need("x2", "app", .approval, at: 2)]
            let titled = MochiDigest.note(sessions: same, titles: ["x1": "Fix login", "x2": "Add search"])
            checkEq("two sessions in one folder are told apart by their titles", titled.line, "Fix login needs you, Add search needs you")
            checkEq("and their buttons too", titled.actions.map(\.label), ["Fix login", "Add search"])
            let untitled = MochiDigest.note(sessions: same, titles: [:])
            checkEq("without titles the button labels stay unique", Set(untitled.actions.map(\.label)).count, 2)
            checkEq("a long name is cut for the button",
                    MochiDigest.note(sessions: [need("l", String(repeating: "n", count: 50), .approval)], titles: [:]).actions.first?.label.count, 28)

            // Model output can never make a focus button
            checkEq("report with a focus action: dropped",
                    MochiTools.parseReport(["line": "x", "actions": [["label": "Go", "focus": "a"]]])?.actions.count, 0)
            checkEq("the action validator does not know focus", MochiAware.action(from: ["label": "Go", "focus": "a"]), nil)
            checkEq("not even next to a valid kind", MochiAware.action(from: ["label": "Go", "copy": "x", "focus": "a"])?.kind, .copy("x"))
        }

        print("")
        print("Review fixes: subagents, digest state, bar copy, hooks, missed approvals")
        do {
            // B1: a subagent's request lands on the worker's card, answered in the subagent's session.
            let text = (try? String(contentsOfFile: "tests/fixtures/opencode-events.txt", encoding: .utf8)) ?? ""
            var events: [[String: Any]] = []
            var inScenario = false
            for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
                if line.hasPrefix(": scenario ") { inScenario = line.contains("subagent") }
                else if inScenario, let o = OpenCodeEvents.parseLine(line) { events.append(o) }
            }
            checkTrue("the subagent scenario is in the fixture", events.count > 10)
            var state = OpenCodeEventState()
            var all: [OpenCodeSignal] = []
            for e in events { all += OpenCodeEvents.translate(e, state: &state) }
            checkEq("the child's parent is recorded from session.created", state.parents.count, 1)
            let child = state.parents.keys.first ?? "", parent = state.parents.values.first ?? ""
            checkEq("and resolves to the worker", state.root(of: child), parent)
            var starts = 0, stops = 0, prompts = 0
            var asked: (owner: String, api: String, request: String)?
            var settledOwner: String?
            for sig in all {
                switch sig {
                case .session(_, _, .start): starts += 1
                case .session(_, _, .stop): stops += 1
                case .session(_, _, .prompt): prompts += 1
                case .approval(let id, let req, _, _, let api): asked = (id, api, req)
                case .approvalSettled(let id, _): settledOwner = id
                default: break
                }
            }
            checkEq("only the worker starts, never the subagent", starts, 1)
            checkEq("the subagent's prompt does not become the worker's", prompts, 1)
            checkEq("the subagent finishing does not stop the worker", stops, 0)
            checkEq("the approval belongs to the worker's card", asked?.owner, parent)
            checkEq("but is answered in the subagent's session", asked?.api, child)
            checkEq("the settle goes to the worker's card", settledOwner, parent)
            checkEq("a nested subagent resolves to the top", {
                var s2 = OpenCodeEventState(); s2.parents = ["c2": "c1", "c1": "w"]; return s2.root(of: "c2") }(), "w")

            // B5/B6: the digest state across checks
            var st = MochiDigest.State()
            func eval(_ count: Int, blocked: Bool = false, at t: TimeInterval) -> Bool { st.evaluate(count: count, blocked: blocked, now: at(t)) }
            checkEq("2 then 3 posts", [eval(2, at: 0), eval(3, at: 1)], [false, true])
            checkEq("still 3: no second", eval(3, at: 2), false)
            var blockedState = MochiDigest.State()
            checkEq("a pile-up while Mochi's question is up is put off", blockedState.evaluate(count: 3, blocked: true, now: at(0)), false)
            checkEq("and is not forgotten", blockedState.deferred, true)
            checkEq("still blocked: still waiting", blockedState.evaluate(count: 3, blocked: true, now: at(5)), false)
            checkEq("the question answered, pile still there: posts", blockedState.evaluate(count: 3, blocked: false, now: at(9)), true)
            checkEq("and only once", blockedState.evaluate(count: 3, blocked: false, now: at(10)), false)
            var gone = MochiDigest.State()
            _ = gone.evaluate(count: 3, blocked: true, now: at(0))
            checkEq("the pile cleared meanwhile: nothing to say", gone.evaluate(count: 1, blocked: false, now: at(5)), false)
            checkEq("and the deferral is dropped", gone.deferred, false)
            checkEq("a later new pile-up posts normally", gone.evaluate(count: 3, blocked: false, now: at(70)), true)

            // B8: the bar says where the words go
            checkEq("brain on: placeholder", AssistantBarLogic.placeholder(target: .claudeReply(sessionId: "x"), workspace: "w", toMochi: true), "Ask Mochi…")
            checkEq("brain on: tag", AssistantBarLogic.tag(target: .claudeReply(sessionId: "x"), main: nil, toMochi: true), "to Mochi")
            checkEq("brain off: today's placeholder", AssistantBarLogic.placeholder(target: .claudeReply(sessionId: "x"), workspace: "w"),
                    "Reply in this Claude Code session…")
            checkEq("brain off: today's tag", AssistantBarLogic.tag(target: .claudeReply(sessionId: "x"), main: nil), "same Claude Code session")
            checkEq("brain off, new task: today's placeholder", AssistantBarLogic.placeholder(target: .newTask, workspace: "w"), "New OpenCode task in w…")

            // D4: the hook check
            let installed: [String: Any] = ["hooks": ["PermissionRequest": [["hooks": [["type": "command",
                "command": "/bin/sh /Users/me/Library/Application Support/NotchBuddy/nb-hook", "timeout": 120]]]]]]
            checkEq("Coucou's PermissionRequest hook counts as installed", ClaudeHookCheck.isInstalled(settings: installed), true)
            checkEq("no settings file: not installed", ClaudeHookCheck.isInstalled(settings: nil), false)
            checkEq("someone else's hook: not installed", ClaudeHookCheck.isInstalled(settings: ["hooks": ["PermissionRequest": [["hooks": [["command": "/usr/bin/other"]]]]]]), false)
            checkEq("other events only: not installed", ClaudeHookCheck.isInstalled(settings: ["hooks": ["Stop": [["hooks": [["command": "nb-hook coucou"]]]]]]), false)
            checkTrue("the message points at Settings", ClaudeHookCheck.missingCopy.contains("Settings") && ClaudeHookCheck.missingCopy.contains("hooks"))

            // B4: a skipped approval shows on the finished card
            checkEq("no skipped approvals: the line is unchanged", AssistantReply.headline("Done.", missedApprovals: []), "Done.")
            checkEq("one skipped approval is named", AssistantReply.headline("Done.", missedApprovals: ["rm -rf build"]),
                    "Done. Skipped, no answer in time: rm -rf build.")
            checkTrue("several are counted", AssistantReply.headline("Done.", missedApprovals: ["a", "b", "c"]).hasSuffix("a (+2 more)."))
        }

        print("")
        print("Parked worker requests")
        do {
            var slots = RequestSlots<String>()
            slots.add(owner: "w", id: "r1", item: "first")
            slots.add(owner: "w", id: "r2", item: "second")
            slots.add(owner: "w", id: "r1", item: "dup")
            checkEq("the first in line shows", slots.nextToShow(owner: "w")?.id, "r1")
            slots.markShown(owner: "w", id: "r1")
            checkTrue("nothing else shows while one is on screen", slots.nextToShow(owner: "w") == nil)
            slots.park(owner: "w")      // the card went away unanswered
            checkTrue("a parked request is still waiting", slots.hasWaiting(owner: "w"))
            checkTrue("and no card is shown", !slots.isShown(owner: "w", id: "r1"))
            checkEq("selecting the worker shows the same request again", slots.nextToShow(owner: "w")?.id, "r1")
            checkEq("with the same payload", slots.nextToShow(owner: "w")?.item, "first")
            slots.markShown(owner: "w", id: "r1")
            checkEq("answering removes it and reports it was on screen", slots.remove(owner: "w", id: "r1"), true)
            checkEq("the next one is then next in line", slots.nextToShow(owner: "w")?.id, "r2")
            slots.park(owner: "w")
            checkEq("OpenCode settling a parked request: nothing on screen to dismiss", slots.remove(owner: "w", id: "r2"), false)
            checkTrue("and it is gone", !slots.hasWaiting(owner: "w"))
            slots.add(owner: "w", id: "r3", item: "third"); slots.add(owner: "v", id: "x", item: "other")
            slots.markShown(owner: "w", id: "r3")
            checkEq("the turn ending clears it and reports the card", slots.clear(owner: "w"), true)
            checkTrue("another worker's request is untouched", slots.nextToShow(owner: "v")?.id == "x")
            checkEq("clearing a worker with nothing shown", slots.clear(owner: "v"), false)
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
