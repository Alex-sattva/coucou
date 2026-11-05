import Foundation

@main
@MainActor
enum AgentSessionTests {

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

    static func send(_ store: inout AgentSessionStore, _ e: SessionEvent, id: String = "s1",
                     cwd: String = "/code/alpha", kind: AgentKind = .claudeCode,
                     color: String = "#112233", now: Date = t0) {
        store.apply(e, sessionId: id, kind: kind, cwd: cwd, colorHex: color, now: now)
    }

    static func main() {
        print("start / unknown sessions")
        do {
            var s = AgentSessionStore()
            send(&s, .start)
            let a = s.sessions["s1"]
            checkEq("start creates an idle session", a?.phase, .idle)
            checkEq("workspace is the folder name", a?.workspace, "alpha")
            checkEq("colour and kind stored", a?.colorHex, "#112233")
            checkTrue("no attention stamp", a?.attentionAt == nil)

            var u = AgentSessionStore()
            send(&u, .toolStart(step: "Read x"), id: "mid")
            checkEq("event for unknown id creates it, then applies", u.sessions["mid"]?.phase, .working)
            checkEq("its step is recorded", u.sessions["mid"]?.steps, ["Read x"])
        }

        print("prompt")
        do {
            var s = AgentSessionStore()
            send(&s, .toolStart(step: "old"))
            send(&s, .stop(reply: "done"))
            send(&s, .prompt("fix the bug"), now: at(5))
            let a = s.sessions["s1"]!
            checkEq("prompt -> thinking", a.phase, .thinking)
            checkEq("lastPrompt stored", a.lastPrompt, "fix the bug")
            checkTrue("reply cleared", a.reply == nil)
            checkTrue("finishedSeen reset", a.finishedSeen == false)
            checkTrue("attention cleared when leaving finished", a.attentionAt == nil)
            checkTrue("steps restart for the new turn", a.steps.isEmpty)
        }

        print("tools")
        do {
            var s = AgentSessionStore()
            send(&s, .prompt("go"))
            send(&s, .toolStart(step: "Edit a.swift"))
            checkEq("toolStart -> working", s.sessions["s1"]?.phase, .working)
            send(&s, .toolFailed(step: "Bash swift build"))
            checkEq("toolFailed -> working", s.sessions["s1"]?.phase, .working)
            checkEq("failed step is prefixed", s.sessions["s1"]?.steps.last, "⚠ Bash swift build")
            send(&s, .toolEnd)
            checkEq("toolEnd keeps working", s.sessions["s1"]?.phase, .working)

            var cap = AgentSessionStore()
            for i in 0..<55 { send(&cap, .toolStart(step: "step \(i)")) }
            checkEq("steps capped at 40", cap.sessions["s1"]?.steps.count, 40)
            checkEq("oldest steps dropped", cap.sessions["s1"]?.steps.first, "step 15")
            checkEq("newest step kept", cap.sessions["s1"]?.steps.last, "step 54")
        }

        print("approval / question / attention stamps")
        do {
            var s = AgentSessionStore()
            send(&s, .toolStart(step: "Bash"), now: at(0))
            send(&s, .approvalRequested, now: at(10))
            checkEq("approvalRequested -> approval", s.sessions["s1"]?.phase, .approval)
            checkEq("attentionAt stamped on entry", s.sessions["s1"]?.attentionAt, at(10))
            send(&s, .notification("still waiting"), now: at(20))
            checkEq("repeat in same phase keeps the stamp", s.sessions["s1"]?.attentionAt, at(10))
            send(&s, .toolEnd, now: at(30))
            checkEq("PostToolUse clears the approval", s.sessions["s1"]?.phase, .working)
            checkTrue("leaving approval clears attentionAt", s.sessions["s1"]?.attentionAt == nil)
            send(&s, .questionAsked, now: at(40))
            checkEq("questionAsked -> question", s.sessions["s1"]?.phase, .question)
            checkEq("question stamped", s.sessions["s1"]?.attentionAt, at(40))
        }

        print("notification")
        do {
            var s = AgentSessionStore()
            send(&s, .toolStart(step: "x"))
            send(&s, .notification("Claude AI usage limit: Rate Limit reached"), now: at(1))
            checkEq("rate limit (any case) -> blocked", s.sessions["s1"]?.phase, .blocked)
            checkEq("blocked is stamped", s.sessions["s1"]?.attentionAt, at(1))

            var q = AgentSessionStore()
            send(&q, .toolStart(step: "x"))
            send(&q, .notification("Which file should I edit?"), now: at(2))
            checkEq("trailing ? -> question", q.sessions["s1"]?.phase, .question)

            var n = AgentSessionStore()
            send(&n, .toolStart(step: "x"))
            send(&n, .notification("Claude is waiting for your input"), now: at(3))
            checkEq("other notification leaves the phase alone", n.sessions["s1"]?.phase, .working)
            checkEq("but refreshes lastEventAt", n.sessions["s1"]?.lastEventAt, at(3))
        }

        print("stop / stopFailure / interrupt / end")
        do {
            var s = AgentSessionStore()
            send(&s, .prompt("go"))
            send(&s, .stop(reply: "All done"), now: at(7))
            var a = s.sessions["s1"]!
            checkEq("stop -> finished", a.phase, .finished)
            checkEq("reply stored", a.reply, "All done")
            checkEq("finished stamps attention", a.attentionAt, at(7))
            checkTrue("unseen", a.finishedSeen == false)
            s.markSeen("s1")
            checkTrue("markSeen flips finishedSeen", s.sessions["s1"]?.finishedSeen == true)
            s.markSeen("nope") // no crash on unknown id
            send(&s, .stop(reply: nil), now: at(9))
            a = s.sessions["s1"]!
            checkTrue("stop without a line -> reply nil (OpenCode idle)", a.reply == nil)
            checkTrue("a new stop makes it unseen again", a.finishedSeen == false)

            var f = AgentSessionStore()
            send(&f, .toolStart(step: "x"))
            send(&f, .stopFailure(kind: "rate_limit", message: "You\u{2019}ve hit your session limit"), now: at(2))
            checkEq("stopFailure -> blocked", f.sessions["s1"]?.phase, .blocked)
            checkEq("blocked stamped", f.sessions["s1"]?.attentionAt, at(2))
            checkEq("failure kept", f.sessions["s1"]?.failure,
                    SessionFailure(kind: "rate_limit", message: "You\u{2019}ve hit your session limit"))
            checkTrue("usage limit says the session stopped",
                      f.sessions["s1"]?.failure?.headline.contains("usage limit") == true
                      && f.sessions["s1"]?.failure?.headline.contains("session stopped") == true)
            checkEq("unknown kind keeps the old line", SessionFailure(kind: "unknown").headline,
                    "I hit an error I can\u{2019}t get past on my own.")
            send(&f, .prompt("again"), now: at(3))
            checkTrue("a new prompt clears the failure", f.sessions["s1"]?.failure == nil)

            var i = AgentSessionStore()
            send(&i, .approvalRequested, now: at(1))
            send(&i, .interrupt, now: at(2))
            checkEq("interrupt -> idle", i.sessions["s1"]?.phase, .idle)
            checkTrue("interrupt clears attention", i.sessions["s1"]?.attentionAt == nil)

            var e = AgentSessionStore()
            send(&e, .start)
            send(&e, .end)
            checkTrue("end removes the session", e.sessions.isEmpty)
        }

        print("account for")
        do {
            var s = AgentSessionStore()
            send(&s, .prompt("a"), id: "one", cwd: "/code/same")
            send(&s, .prompt("b"), id: "two", cwd: "/code/same")
            send(&s, .stop(reply: "x"), id: "one")
            checkEq("two sessions in one folder stay separate", s.sessions.count, 2)
            checkEq("events hit only their own session", s.sessions["two"]?.phase, .thinking)
            checkEq("and the other one finished", s.sessions["one"]?.phase, .finished)

            var e = AgentSessionStore()
            send(&e, .end, id: "ghost")
            checkTrue("end on an unknown session is a no-op", e.sessions.isEmpty)
            let before = s
            send(&s, .end, id: "ghost")
            checkTrue("end on an unknown id leaves other sessions untouched", s == before)

            var p = AgentSessionStore()
            send(&p, .approvalRequested, id: "held", now: t0)
            send(&p, .questionAsked, id: "asking", now: t0)
            send(&p, .toolStart(step: "x"), id: "busy", now: t0)
            send(&p, .stop(reply: nil), id: "done", now: t0)
            send(&p, .stopFailure(), id: "blocked", now: t0)
            send(&p, .toolStart(step: "x"), id: "fresh", now: at(890))
            p.prune(now: at(900), idleFor: 900)
            checkTrue("prune keeps a held approval", p.sessions["held"] != nil)
            checkTrue("prune keeps a held question", p.sessions["asking"] != nil)
            checkTrue("prune removes an idle working session", p.sessions["busy"] == nil)
            checkTrue("prune removes an idle finished session", p.sessions["done"] == nil)
            checkTrue("prune removes an idle blocked session", p.sessions["blocked"] == nil)
            checkTrue("prune keeps a recently active session", p.sessions["fresh"] != nil)
        }

        print("")
        print("worker reports")
        do {
            var s = AgentSessionStore()
            send(&s, .prompt("do it"))
            send(&s, .toolStart(step: "Read x"))
            let note = MochiNote(line: "Server is up.", actions: [MochiAction(label: "Open", kind: .openURL("http://localhost:8123"))])
            send(&s, .mochiReport(note))
            checkEq("the report sets the note", s.sessions["s1"]?.mochi, note)
            checkEq("and keeps the phase", s.sessions["s1"]?.phase, .working)
            send(&s, .stop(reply: "All done.", mochi: nil))
            checkEq("a stop without a note keeps the report", s.sessions["s1"]?.mochi, note)
            checkEq("the stop finishes the session", s.sessions["s1"]?.phase, .finished)
            checkEq("with the reply", s.sessions["s1"]?.reply, "All done.")
            let newer = MochiNote(line: "Second.", actions: [])
            send(&s, .mochiReport(newer))
            checkEq("two reports in a turn: the last wins", s.sessions["s1"]?.mochi, newer)
            send(&s, .prompt("next"))
            checkTrue("a new prompt clears the note", s.sessions["s1"]?.mochi == nil)
            send(&s, .stop(reply: "x", mochi: newer))
            checkEq("a stop that carries a note sets it", s.sessions["s1"]?.mochi, newer)
        }

        print("")
        print("missed approvals")
        do {
            var s = AgentSessionStore()
            send(&s, .prompt("do it"))
            send(&s, .approvalRequested)
            send(&s, .approvalMissed(command: "npm install"))
            checkEq("the missed request is kept", s.sessions["s1"]?.missedApprovals, ["npm install"])
            checkTrue("and shows as a step", s.sessions["s1"]?.steps.last?.contains("Skipped: npm install") == true)
            checkTrue("the step reads as a warning", s.sessions["s1"]?.steps.last?.hasPrefix("\u{26A0}") == true)
            send(&s, .stop(reply: "x", mochi: nil))
            checkEq("it survives the stop", s.sessions["s1"]?.missedApprovals.count, 1)
            send(&s, .prompt("next"))
            checkEq("a new turn clears it", s.sessions["s1"]?.missedApprovals, [])
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
