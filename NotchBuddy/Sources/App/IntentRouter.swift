import Foundation

/// Decides what to do with what the user said (`RouterInput` → one `RouterAction`). Backends are
/// interchangeable: the rules (offline, always there) and Claude today; Jev can be added as another
/// conformance without touching anything else.
protocol IntentRouter: Sendable {
    func route(_ input: RouterInput) async throws -> RouterDecision
}

struct RulesIntentRouter: IntentRouter {
    func route(_ input: RouterInput) async throws -> RouterDecision { RuleRouter.decide(input) }
}

/// Claude via the Messages API, with structured JSON output against a fixed schema
/// (`ClaudeRouterParsing`). Any failure throws; the caller falls back to the rules.
struct ClaudeIntentRouter: IntentRouter {
    /// The one place the model is chosen.
    static let model = "claude-opus-5-5"
    /// Past this the rules answer instead. The first request after a schema change is slower
    /// (Anthropic compiles the schema once, then caches it for a day).
    static let timeout: TimeInterval = 6

    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    let apiKey: String

    enum RouterError: Error { case http(Int) }

    func route(_ input: RouterInput) async throws -> RouterDecision {
        var req = URLRequest(url: Self.endpoint, timeoutInterval: Self.timeout)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = ClaudeRouterParsing.requestBody(input: input, model: Self.model)
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw RouterError.http(status) }
        return RouterDecision(action: try ClaudeRouterParsing.action(fromResponse: data), source: "claude")
    }
}
