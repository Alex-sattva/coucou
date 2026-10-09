import Foundation

/// A lock-protected list the stream process callbacks (any queue) append to.
final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    func add(_ x: T) { lock.lock(); items.append(x); lock.unlock() }
    var all: [T] { lock.lock(); defer { lock.unlock() }; return items }
}

@main
@MainActor
enum StreamProcessTests {
    static var failures = 0

    static func checkTrue(_ label: String, _ value: Bool) {
        if value { print("  ✓ \(label)") } else { print("  ✗ \(label)"); failures += 1 }
    }
    static func checkEq<T: Equatable>(_ label: String, _ got: T, _ expected: T) {
        if got == expected { print("  ✓ \(label)") } else { print("  ✗ \(label)  got: \(got)  expected: \(expected)"); failures += 1 }
    }

    static func waitFor(_ seconds: Double = 5, _ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if cond() { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return cond()
    }

    struct Run {
        let process: ClaudeStreamProcess
        let events: Box<[String: Any]>
        let exits: Box<Int32>
    }

    static func make(cwd: String, args: [String] = ["-p"]) -> Run {
        let events = Box<[String: Any]>()
        let exits = Box<Int32>()
        let p = ClaudeStreamProcess(cwd: cwd, arguments: args, environment: ClaudeCodeRun.processEnvironment(),
                                    onEvent: { events.add($0) }, onExit: { exits.add($0) })
        return Run(process: p, events: events, exits: exits)
    }

    static func results(_ run: Run) -> [String] {
        run.events.all.compactMap { ($0["type"] as? String) == "result" ? $0["result"] as? String : nil }
    }

    static func main() {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? ""
        let fake = URL(fileURLWithPath: home + "/.local/bin/claude")
        ClaudeCodeRun.cliOverrideForTests = fake     // never the real claude
        let cwd = NSTemporaryDirectory()
        let log = ProcessInfo.processInfo.environment["FAKE_CLAUDE_LOG"] ?? ""

        print("start / events")
        do {
            let run = make(cwd: cwd, args: ["-p", "--session-id", "abc"])
            do { try run.process.start() } catch { checkTrue("start does not throw (\(error))", false); exit(1) }
            checkTrue("isRunning after start", run.process.isRunning)
            checkTrue("system/init arrives", waitFor { run.events.all.contains { ($0["subtype"] as? String) == "init" } })
            if let data = FileManager.default.contents(atPath: log + ".args"),
               let args = (try? JSONSerialization.jsonObject(with: data)) as? [String] {
                checkEq("arguments reach the process", args, ["-p", "--session-id", "abc"])
            } else { checkTrue("arguments file written", false) }

            print("two sends, two results")
            run.process.send(userText: "first")
            run.process.send(userText: "second \"quoted\" \\ and\nnewline")
            checkTrue("two results arrive", waitFor { results(run).count == 2 })
            checkEq("results in order", results(run), ["echo: first", "echo: second \"quoted\" \\ and\nnewline"])

            print("interrupt")
            run.process.interrupt()
            checkTrue("a control_response comes back", waitFor {
                run.events.all.contains { ($0["type"] as? String) == "control_response" } })
            let lines = (try? String(contentsOfFile: log, encoding: .utf8))?
                .split(separator: "\n").map(String.init) ?? []
            let last = lines.last.flatMap { $0.data(using: .utf8) }
                .flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
            checkEq("interrupt line type", last?["type"] as? String, "control_request")
            checkEq("interrupt subtype", (last?["request"] as? [String: Any])?["subtype"] as? String, "interrupt")
            checkTrue("interrupt has a request_id", ((last?["request_id"] as? String) ?? "").count > 8)
            let first = lines.first.flatMap { $0.data(using: .utf8) }
                .flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
            let msg = first?["message"] as? [String: Any]
            checkEq("user line shape", first?["type"] as? String, "user")
            checkEq("user line role", msg?["role"] as? String, "user")
            checkEq("user line content", msg?["content"] as? String, "first")

            print("stop")
            run.process.stop()
            checkTrue("stop ends the process", waitFor { !run.exits.all.isEmpty })
            checkEq("clean exit status", run.exits.all.first, 0)
            checkTrue("isRunning false after exit", !run.process.isRunning)
            checkTrue("stderr was kept", run.process.stderrTail.contains("fake claude started"))
            run.process.send(userText: "after exit")   // must not crash
            Thread.sleep(forTimeInterval: 0.1)
            checkEq("exit reported once", run.exits.all.count, 1)
        }

        print("stop escalates to SIGTERM")
        do {
            setenv("FAKE_CLAUDE_STUBBORN", "1", 1)
            let run = make(cwd: cwd)
            try? run.process.start()
            checkTrue("stubborn process started", waitFor { run.events.all.count >= 1 })
            run.process.stop()
            checkTrue("still running right after stop", run.process.isRunning)
            checkTrue("SIGTERM ends it within about 2 s", waitFor(5) { !run.exits.all.isEmpty })
            unsetenv("FAKE_CLAUDE_STUBBORN")
        }

        print("terminateNow")
        do {
            setenv("FAKE_CLAUDE_STUBBORN", "1", 1)
            let run = make(cwd: cwd)
            try? run.process.start()
            _ = waitFor { run.events.all.count >= 1 }
            run.process.terminateNow()
            checkTrue("terminateNow ends it at once", waitFor(2) { !run.exits.all.isEmpty })
            unsetenv("FAKE_CLAUDE_STUBBORN")
        }

        print("brain path: Mochi's own process on the Claude Code login")
        do {
            let dir = NSTemporaryDirectory() + "mochi-home-\(UUID().uuidString)"
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(atPath: dir) }
            let mcp = MochiTools.claudeBrainMCPConfig(hookPath: "/hook/nb-hook")
            let args = MochiTools.claudeBrainArguments(sessionId: "11111111-1111-1111-1111-111111111111", resume: false,
                                                       model: "claude-sonnet-5-5", mcpConfig: mcp)
            let events = Box<[String: Any]>()
            let exits = Box<Int32>()
            let p = ClaudeStreamProcess(
                cwd: dir, arguments: args,
                environment: ClaudeCodeRun.processEnvironment(adding: MochiTools.claudeBrainEnvironment),
                onEvent: { events.add($0) }, onExit: { exits.add($0) })
            do { try p.start() } catch { checkTrue("brain process starts (\(error))", false); exit(1) }
            checkTrue("brain process started", waitFor { events.all.contains { ($0["subtype"] as? String) == "init" } })
            let seen = FileManager.default.contents(atPath: log + ".args")
                .flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String] }
            checkEq("the process gets exactly the brain's arguments", seen ?? [], args)
            checkTrue("isolation flags reached the process",
                      (seen ?? []).contains("--strict-mcp-config") && (seen ?? []).contains("--disable-slash-commands")
                        && (seen ?? []).contains("--setting-sources") && !(seen ?? []).contains("--append-system-prompt"))
            let env = FileManager.default.contents(atPath: log + ".env")
                .flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: String] } ?? [:]
            checkEq("MCP tool timeout reached the process", env["MCP_TOOL_TIMEOUT"], MochiTools.claudeBrainEnvironment["MCP_TOOL_TIMEOUT"])
            checkEq("idle timeout off reached the process", env["CLAUDE_CODE_MCP_TOOL_IDLE_TIMEOUT"], "0")
            p.send(userText: "turn one")
            checkTrue("a turn ends on the result line", waitFor { events.all.contains { ($0["type"] as? String) == "result" } })
            p.send(userText: "turn two")
            checkTrue("the same process answers the next turn", waitFor {
                events.all.filter { ($0["type"] as? String) == "result" }.count == 2 })
            checkTrue("one process for both turns", exits.all.isEmpty && p.isRunning)
            p.stop()
            _ = waitFor { !exits.all.isEmpty }
        }

        print("relaunch: the old process must not touch the new one")
        do {
            var table = ProcessGenerations()
            let first = table.begin("sess")
            let oldRun = make(cwd: cwd)
            try? oldRun.process.start()
            _ = waitFor { oldRun.events.all.count >= 1 }
            // The session's process died and the next message relaunches it.
            let second = table.begin("sess")
            let newRun = make(cwd: cwd)
            try? newRun.process.start()
            checkTrue("a new process gets a new generation", second != first)
            oldRun.process.stop()
            checkTrue("the old process exits after the relaunch", waitFor { !oldRun.exits.all.isEmpty })
            checkTrue("its exit is stale (ignored)", !table.isCurrent("sess", first))
            checkTrue("the new process is current", table.isCurrent("sess", second))
            checkTrue("and still running", newRun.process.isRunning)
            checkTrue("another session's generation is independent", table.begin("other") != second && table.isCurrent("sess", second))
            newRun.process.stop()
            _ = waitFor { !newRun.exits.all.isEmpty }
        }

        print("failures")
        do {
            let missingDir = make(cwd: "/definitely/not/here")
            do { try missingDir.process.start(); checkTrue("missing folder throws", false) }
            catch let e as ClaudeCodeRun.RunError {
                if case .workingDirectoryUnavailable = e { checkTrue("missing folder throws workingDirectoryUnavailable", true) }
                else { checkTrue("missing folder throws workingDirectoryUnavailable", false) }
            } catch { checkTrue("missing folder throws RunError", false) }

            try? FileManager.default.removeItem(at: fake)
            let noCli = make(cwd: cwd)
            do { try noCli.process.start(); checkTrue("missing CLI throws", false) }
            catch let e as ClaudeCodeRun.RunError {
                if case .cliNotFound = e { checkTrue("missing CLI throws cliNotFound", true) }
                else { checkTrue("missing CLI throws cliNotFound", false) }
            } catch { checkTrue("missing CLI throws RunError", false) }
        }

        print("")
        if failures == 0 { print("All tests passed.") } else { print("\(failures) test(s) failed."); exit(1) }
    }
}
