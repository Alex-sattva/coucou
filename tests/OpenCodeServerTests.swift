import Foundation

final class Collected<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    func add(_ x: T) { lock.lock(); items.append(x); lock.unlock() }
    var all: [T] { lock.lock(); defer { lock.unlock() }; return items }
}

@main
@MainActor
enum OpenCodeServerTests {
    static var failures = 0
    static func checkTrue(_ label: String, _ value: Bool) {
        if value { print("  ✓ \(label)") } else { print("  ✗ \(label)"); failures += 1 }
    }
    static func checkEq<T: Equatable>(_ label: String, _ got: T, _ expected: T) {
        if got == expected { print("  ✓ \(label)") } else { print("  ✗ \(label)  got: \(got)  expected: \(expected)"); failures += 1 }
    }

    static func env(_ extra: [String: String] = [:]) -> [String: String] {
        var e = ProcessInfo.processInfo.environment
        for (k, v) in extra { e[k] = v }
        return e
    }

    static func logLines() -> [[String: Any]] {
        let path = ProcessInfo.processInfo.environment["FAKE_OPENCODE_LOG"] ?? ""
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
    }

    static func main() async {
        let cli = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FAKE_OPENCODE_CLI"] ?? "")
        let cwd = NSTemporaryDirectory()

        print("start-up")
        var server: OpenCodeServerProcess?
        do {
            server = try await OpenCodeServerLauncher.launch(cli: cli, cwd: cwd, environment: env())
            checkTrue("server started and printed its password", server != nil)
            checkTrue("a real port was chosen", (server?.port ?? 0) > 1024)
            checkTrue("basic auth header is opencode:<password>",
                      server?.authorization == "Basic " + Data("opencode:s3cret-pw".utf8).base64EncodedString())
        } catch { checkTrue("server started (\(error))", false) }
        guard let server else { exit(1) }
        let client = server.client()

        print("requests")
        do {
            let id = try await client.createSession(directory: "/proj", model: ModelRef(providerID: "openai", id: "gpt-5"))
            checkEq("session id returned", id, "ses_fake")
            let create = logLines().last
            let body = create?["body"] as? [String: Any]
            checkEq("create path", create?["path"] as? String, "/api/session")
            checkEq("create sends the folder", (body?["location"] as? [String: Any])?["directory"] as? String, "/proj")
            checkEq("create sends the model", (body?["model"] as? [String: Any])?["providerID"] as? String, "openai")
            checkTrue("create never sends permission rules", body?["permissions"] == nil && body?["permission"] == nil)
            _ = try await client.createSession(directory: "/proj", model: nil)
            checkTrue("no model when none given", (logLines().last?["body"] as? [String: Any])?["model"] == nil)

            try await client.interrupt(session: "ses_fake")
            checkEq("interrupt path", logLines().last?["path"] as? String, "/api/session/ses_fake/interrupt")
            try await client.setModel(session: "ses_fake", model: ModelRef(providerID: "anthropic", id: "claude-x"))
            checkEq("model switch path", logLines().last?["path"] as? String, "/api/session/ses_fake/model")
            checkEq("model switch body", ((logLines().last?["body"] as? [String: Any])?["model"] as? [String: Any])?["id"] as? String, "claude-x")
            try await client.replyPermission(session: "ses_fake", request: "per_1", decision: "once")
            checkEq("permission reply path", logLines().last?["path"] as? String, "/api/session/ses_fake/permission/per_1/reply")
            checkEq("permission reply body", (logLines().last?["body"] as? [String: Any])?["decision"] as? String, "once")
            try await client.replyForm(session: "ses_fake", form: "frm_1", answer: ["q0": "Red"])
            checkEq("form reply path", logLines().last?["path"] as? String, "/api/session/ses_fake/form/frm_1/reply")
            checkEq("form reply body", ((logLines().last?["body"] as? [String: Any])?["answer"] as? [String: Any])?["q0"] as? String, "Red")
            try await client.cancelForm(session: "ses_fake", form: "frm_1")
            checkEq("form cancel is a DELETE", logLines().last?["method"] as? String, "DELETE")
            let active = try await client.activeSessions()
            checkEq("active sessions", active, ["ses_fake"])
            do { try await client.prompt(session: "ses_x", text: "bad"); checkTrue("a 404 throws", false) }
            catch let e as OpenCodeClientError { checkEq("OpenCode's own message comes through", e, .http(status: 404, message: "Session not found")) }
            catch { checkTrue("a 404 throws OpenCodeClientError", false) }
        } catch { checkTrue("requests worked (\(error))", false) }

        print("wrong password")
        do {
            let wrong = OpenCodeClient(baseURL: server.baseURL, authorization: "Basic " + Data("opencode:nope".utf8).base64EncodedString())
            do { try await wrong.interrupt(session: "ses_fake"); checkTrue("401 throws", false) }
            catch let e as OpenCodeClientError { checkEq("401 is reported", e, .http(status: 401, message: "Unauthorized")) }
            catch { checkTrue("401 throws OpenCodeClientError", false) }
        }

        print("events")
        do {
            let seen = Collected<String>()
            let task = Task {
                do { for try await ev in client.events() { if let t = ev["type"] as? String { seen.add(t) } } } catch {}
            }
            var ok = false
            for _ in 0..<100 { if seen.all.contains("server.connected") { ok = true; break }; try? await Task.sleep(for: .milliseconds(50)) }
            checkTrue("stream connects and yields server.connected", ok)
            try? await client.prompt(session: "ses_fake", text: "go", queue: true)
            checkEq("prompt can be queued", (logLines().last?["body"] as? [String: Any])?["delivery"] as? String, "queue")
            ok = false
            for _ in 0..<100 { if seen.all.contains("session.execution.succeeded") { ok = true; break }; try? await Task.sleep(for: .milliseconds(50)) }
            checkTrue("prompt makes the fixture's events arrive", ok)
            checkTrue("the permission event came through", seen.all.contains("permission.asked"))
            task.cancel()
        }

        print("reconnect delays")
        checkEq("1 s first", OpenCodeReconnect.delay(attempt: 0), 1)
        checkEq("then 2, 4, 8", [1, 2, 3].map { OpenCodeReconnect.delay(attempt: $0) }, [2, 4, 8])
        checkEq("capped at 30 s", OpenCodeReconnect.delay(attempt: 9), 30)
        checkEq("and stays there", OpenCodeReconnect.delay(attempt: 500), 30)

        print("stop")
        server.terminate()
        var stopped = false
        for _ in 0..<60 { if !server.isRunning { stopped = true; break }; try? await Task.sleep(for: .milliseconds(50)) }
        checkTrue("terminate stops the server", stopped)

        print("start-up failures")
        do {
            _ = try await OpenCodeServerLauncher.launch(cli: cli, cwd: "/definitely/not/here", environment: env())
            checkTrue("missing folder throws", false)
        } catch OpenCodeServerLauncher.LaunchError.folderMissing { checkTrue("missing folder throws folderMissing", true) }
        catch { checkTrue("missing folder throws folderMissing (\(error))", false) }
        do {
            _ = try await OpenCodeServerLauncher.launch(cli: cli, cwd: cwd, environment: env(["FAKE_OPENCODE_MODE": "exit"]))
            checkTrue("a server that dies throws", false)
        } catch OpenCodeServerLauncher.LaunchError.exited(let status) { checkEq("a server that dies throws exited(3)", status, 3) }
        catch { checkTrue("a server that dies throws exited (\(error))", false) }
        do {
            _ = try await OpenCodeServerLauncher.launch(cli: cli, cwd: cwd, environment: env(["FAKE_OPENCODE_MODE": "nopassword"]), timeout: 1.0)
            checkTrue("a silent server times out", false)
        } catch OpenCodeServerLauncher.LaunchError.noPassword { checkTrue("a silent server throws noPassword", true) }
        catch { checkTrue("a silent server throws noPassword (\(error))", false) }

        print("")
        if failures == 0 { print("All tests passed.") } else { print("\(failures) test(s) failed."); exit(1) }
    }
}
