import Foundation

final class Collected<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    func add(_ x: T) { lock.withLock { items.append(x) } }
    var all: [T] { lock.withLock { items } }
}

/// A model that answers from a script, one turn per call, and remembers what it was sent.
final class ScriptedModel: ModelClient, @unchecked Sendable {
    private let lock = NSLock()
    private var turns: [Result<BrainTurn, Error>]
    private(set) var sent: [[BrainMessage]] = []
    init(_ turns: [Result<BrainTurn, Error>]) { self.turns = turns }
    var calls: Int { lock.withLock { sent.count } }
    func complete(system: String, messages: [BrainMessage], tools: [BrainTool]) async throws -> BrainTurn {
        let next: Result<BrainTurn, Error> = lock.withLock {
            sent.append(messages)
            return turns.isEmpty ? .success(BrainTurn(text: "(script over)", toolCalls: [])) : turns.removeFirst()
        }
        return try next.get()
    }
}

func call(_ name: String, _ args: [String: Any] = [:], id: String? = nil) -> BrainToolCall {
    BrainToolCall(id: id ?? "c_\(name)", name: name, arguments: args)
}

@main
@MainActor
enum ModelClientTests {
    static var failures = 0
    static func checkTrue(_ label: String, _ value: Bool) {
        if value { print("  ✓ \(label)") } else { print("  ✗ \(label)"); failures += 1 }
    }
    static func checkEq<T: Equatable>(_ label: String, _ got: T, _ expected: T) {
        if got == expected { print("  ✓ \(label)") } else { print("  ✗ \(label)  got: \(got)  expected: \(expected)"); failures += 1 }
    }

    static func requests() -> [[String: Any]] {
        let path = ProcessInfo.processInfo.environment["FAKE_LLM_LOG"] ?? ""
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
    }

    static func main() async {
        let port = ProcessInfo.processInfo.environment["FAKE_LLM_PORT"] ?? "0"
        let base = "http://127.0.0.1:\(port)"
        let tools = MochiTools.brainTools()
        let fast = Duration.milliseconds(50)

        print("Anthropic")
        do {
            let c = AnthropicModelClient(apiKey: "sk-test", model: "claude-test",
                                         endpoint: URL(string: "\(base)/v1/messages")!, retryDelay: fast)
            let turn = try await c.complete(system: "SYS", messages: [.user("hi")], tools: tools)
            checkEq("tool calls come back", turn.toolCalls.map(\.name), ["list_projects", "start_project_work"])
            let sent = requests().last
            checkEq("posted to /v1/messages", sent?["path"] as? String, "/v1/messages")
            checkEq("key in x-api-key", sent?["key"] as? String, "sk-test")
            checkEq("anthropic-version header", sent?["version"] as? String, "2023-06-01")
            checkEq("body has the nine tools", ((sent?["body"] as? [String: Any])?["tools"] as? [Any])?.count, 9)
            let again = try await c.complete(system: "SYS", messages: [.user("hi"), .assistant(turn),
                                                                         .tool(id: "toolu_01A09q90qw90lq917835lq9", "[]"),
                                                                         .tool(id: "toolu_01B1xyz", "ok")], tools: tools)
            checkEq("the follow-up with tool results gets the text answer", again.text, "Nairobi.")

            let flaky = AnthropicModelClient(apiKey: "k", model: "flaky", endpoint: URL(string: "\(base)/v1/messages")!, retryDelay: fast)
            let before = requests().count
            let t = try await flaky.complete(system: "S", messages: [.user("x")], tools: tools)
            checkTrue("one retry after a 429 works", !t.toolCalls.isEmpty)
            checkEq("and used exactly two requests", requests().count - before, 2)

            let down = AnthropicModelClient(apiKey: "k", model: "down", endpoint: URL(string: "\(base)/v1/messages")!, retryDelay: fast)
            let before2 = requests().count
            do { _ = try await down.complete(system: "S", messages: [.user("x")], tools: tools); checkTrue("503 throws", false) }
            catch let e as ModelClientError { checkEq("503 is reported with the provider's text", e, .http(status: 503, message: "overloaded")) }
            catch { checkTrue("503 throws ModelClientError", false) }
            checkEq("a 5xx is retried once, not more", requests().count - before2, 2)

            let bad = AnthropicModelClient(apiKey: "k", model: "badkey", endpoint: URL(string: "\(base)/v1/messages")!, retryDelay: fast)
            let before3 = requests().count
            do { _ = try await bad.complete(system: "S", messages: [.user("x")], tools: tools); checkTrue("401 throws", false) }
            catch let e as ModelClientError { checkEq("401 reads as a key problem", e.errorDescription, "The provider rejected the key. Check it in Settings.") }
            catch { checkTrue("401 throws ModelClientError", false) }
            checkEq("a 401 is not retried", requests().count - before3, 1)

            let garbage = AnthropicModelClient(apiKey: "k", model: "garbage", endpoint: URL(string: "\(base)/v1/messages")!, retryDelay: fast)
            do { _ = try await garbage.complete(system: "S", messages: [.user("x")], tools: tools); checkTrue("garbage throws", false) }
            catch let e as ModelClientError { checkEq("an unreadable answer", e, .unreadable) }
            catch { checkTrue("garbage throws ModelClientError", false) }
        } catch { checkTrue("anthropic worked (\(error))", false) }

        print("OpenAI-compatible")
        do {
            let c = OpenAICompatibleModelClient(baseURL: base + "/v1/", apiKey: "sk-open", model: "gpt-test", retryDelay: fast)
            let turn = try await c.complete(system: "SYS", messages: [.user("hi")], tools: tools)
            checkEq("tool calls come back", turn.toolCalls.map(\.name), ["list_projects", "start_project_work"])
            let sent = requests().last
            checkEq("posted to <base>/chat/completions (trailing slash handled)", sent?["path"] as? String, "/v1/chat/completions")
            checkEq("bearer key", sent?["auth"] as? String, "Bearer sk-open")
            checkEq("system prompt is the first message", (((sent?["body"] as? [String: Any])?["messages"] as? [[String: Any]])?.first?["role"]) as? String, "system")
            let keyless = OpenAICompatibleModelClient(baseURL: base + "/v1", apiKey: nil, model: "llama3.2", retryDelay: fast)
            _ = try await keyless.complete(system: "S", messages: [.user("x")], tools: tools)
            checkTrue("a local server gets no Authorization header", requests().last?["auth"] is NSNull || requests().last?["auth"] == nil)
            let flaky = OpenAICompatibleModelClient(baseURL: base + "/v1", apiKey: "k", model: "flaky", retryDelay: fast)
            let before = requests().count
            _ = try await flaky.complete(system: "S", messages: [.user("x")], tools: tools)
            checkEq("one retry after a 429", requests().count - before, 2)
            let dead = OpenAICompatibleModelClient(baseURL: "http://127.0.0.1:1/v1", apiKey: nil, model: "m", retryDelay: fast)
            do { _ = try await dead.complete(system: "S", messages: [.user("x")], tools: tools); checkTrue("a server that is down throws", false) }
            catch let e as ModelClientError {
                if case .network = e { checkTrue("a server that is down is a network error", true) } else { checkTrue("network error", false) }
            } catch { checkTrue("network error type", false) }
        } catch { checkTrue("openai worked (\(error))", false) }

        print("Brain loop")
        do {
            // A plain question: one turn, no tools.
            var h1: [BrainMessage] = [.user("capital of Kenya?")]
            let m1 = ScriptedModel([.success(BrainTurn(text: "Nairobi.", toolCalls: []))])
            let o1 = try await BrainLoop.run(client: m1, system: "S", tools: tools, history: &h1, maxSteps: 8,
                                             execute: { _ in BrainToolResult(text: "?", isError: true) }, onGiveUp: { _ in })
            checkEq("a plain answer ends after one call", [m1.calls, o1.steps], [1, 1])
            checkEq("and finishes with the text", [o1.finished, o1.finalText == "Nairobi."], [true, true])
            checkEq("history holds the question and the answer", h1.map(\.role), [.user, .assistant])

            // Tools, then a report: the report is the last word, no extra model call.
            var h2: [BrainMessage] = [.user("add a readme section in coucou")]
            let ran = Collected<String>()
            let m2 = ScriptedModel([
                .success(BrainTurn(text: "", toolCalls: [call("list_projects")])),
                .success(BrainTurn(text: "", toolCalls: [call("start_project_work", ["project": "coucou", "task": "x"]),
                                                          call("report", ["line": "Started in coucou."])])),
                .success(BrainTurn(text: "never asked", toolCalls: [])),
            ])
            let note = MochiNote(line: "Started in coucou.", actions: [])
            let o2 = try await BrainLoop.run(client: m2, system: "S", tools: tools, history: &h2, maxSteps: 8, execute: { c in
                ran.add(c.name)
                return BrainToolResult(text: "ok", note: c.name == "report" ? note : nil)
            }, onGiveUp: { _ in })
            checkEq("tools run in order", ran.all, ["list_projects", "start_project_work", "report"])
            checkEq("two model calls, not three", m2.calls, 2)
            checkEq("the report is returned", o2.report, note)
            checkEq("and the loop is finished", o2.finished, true)
            checkEq("every tool call has its result in history",
                    h2.filter { $0.role == .tool }.map(\.toolCallId), ["c_list_projects", "c_start_project_work", "c_report"])
            checkEq("the second call saw the first tool's result", m2.sent[1].last?.role, .tool)

            // An unknown tool comes back as an error result and counts as a step.
            var h3: [BrainMessage] = [.user("x")]
            let m3 = ScriptedModel([.success(BrainTurn(text: "", toolCalls: [call("rm_rf")])),
                                    .success(BrainTurn(text: "Sorry.", toolCalls: []))])
            let o3 = try await BrainLoop.run(client: m3, system: "S", tools: tools, history: &h3, maxSteps: 8, execute: { c in
                BrainToolResult(text: "Unknown tool \(c.name)", isError: true) }, onGiveUp: { _ in })
            checkEq("the error went back to the model", h3.first { $0.role == .tool }?.isError, true)
            checkEq("two steps used", o3.steps, 2)

            // The step limit.
            var h4: [BrainMessage] = [.user("loop")]
            let m4 = ScriptedModel(Array(repeating: .success(BrainTurn(text: "", toolCalls: [call("list_projects")])), count: 20))
            let o4 = try await BrainLoop.run(client: m4, system: "S", tools: tools, history: &h4, maxSteps: 8,
                                             execute: { _ in BrainToolResult(text: "[]") }, onGiveUp: { _ in })
            checkEq("stops at 8 model calls", m4.calls, 8)
            checkEq("and says it did not finish", o4.finished, false)

            // A tool call that can't be read ends the loop with a plain report.
            var h5: [BrainMessage] = [.user("x")]
            let m5 = ScriptedModel([.success(BrainTurn(text: "", toolCalls: [BrainToolCall(id: "c", name: "report", argumentsJSON: "{line: oops")], unparsable: true)),
                                    .success(BrainTurn(text: "never", toolCalls: []))])
            var gaveUp: MochiNote?
            let o5 = try await BrainLoop.run(client: m5, system: "S", tools: tools, history: &h5, maxSteps: 8,
                                             execute: { _ in BrainToolResult(text: "no") }, onGiveUp: { gaveUp = $0 })
            checkEq("gives up after the first unreadable call, no retry", [m5.calls, o5.gaveUp ? 1 : 0], [1, 1])
            checkEq("with the plain line", gaveUp?.line, BrainLoop.giveUpLine)
            checkEq("the unreadable call is not kept in history", h5.last?.toolCalls.count, 0)

            // A failing model throws; the caller keeps its own history.
            var h6: [BrainMessage] = [.user("x")]
            let m6 = ScriptedModel([.failure(ModelClientError.http(status: 401, message: "bad key"))])
            do {
                _ = try await BrainLoop.run(client: m6, system: "S", tools: tools, history: &h6, maxSteps: 8,
                                            execute: { _ in BrainToolResult(text: "") }, onGiveUp: { _ in })
                checkTrue("a model failure throws", false)
            } catch { checkTrue("a model failure throws", true) }
        } catch { checkTrue("loop tests ran (\(error))", false) }

        print("")
        if failures == 0 { print("All tests passed.") } else { print("\(failures) test(s) failed."); exit(1) }
    }
}
