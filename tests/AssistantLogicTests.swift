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
                     colorHex: "#FFFFFF", phase: phase, steps: [], lastPrompt: nil, finalLine: nil,
                     attentionAt: attention.map(at), finishedSeen: seen, lastEventAt: at(last))
    }

    static func ids(_ list: [AgentSession]) -> [String] { list.map(\.id) }

    static func main() {
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
            checkEq("approval 236", AssistantMetrics.height(for: .approval), 236)
            checkEq("blocked 262", AssistantMetrics.height(for: .blocked), 262)
            checkEq("done with 2 files 248", AssistantMetrics.height(for: .finished(files: 2)), 248)
            checkEq("done caps at 3 file rows", AssistantMetrics.height(for: .finished(files: 9)), 269)
            checkEq("question = rows x 28 + 176", AssistantMetrics.height(for: .question(rows: 5)), 316)
            checkTrue("every height fits the 320 pt window",
                      AssistantMetrics.height(for: .question(rows: 40)) <= 320)
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
