import Foundation

#if !APPSTORE

// Foundation only (compiled by scripts/test-model-client.sh against a fake server).
// The model Mochi thinks with: one request per step of its loop, to the one provider the user
// picked. 60 s timeout. One retry, after 2 s, on HTTP 429 or 5xx; nothing else is retried.

protocol ModelClient: Sendable {
    func complete(system: String, messages: [BrainMessage], tools: [BrainTool]) async throws -> BrainTurn
}

enum ModelClientError: Error, LocalizedError, Equatable {
    case http(status: Int, message: String)
    case unreadable
    case network(String)

    var errorDescription: String? {
        switch self {
        case .http(401, _), .http(403, _): return "The provider rejected the key. Check it in Settings."
        case .http(_, let message): return message
        case .unreadable: return "The model sent an answer Mochi could not read."
        case .network(let reason): return "Could not reach the model: \(reason)"
        }
    }
}

/// POST + JSON with the shared timeout and retry rule.
enum ModelHTTP {
    /// "Coucou/0.1.8 (Mochi assistant)".
    static let userAgent: String = {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        return "Coucou/\(v) (Mochi assistant)"
    }()

    static let timeout: TimeInterval = 60
    static let retryDelay: Duration = .seconds(2)

    static func post(url: URL, headers: [String: String], body: [String: Any],
                     retryDelay: Duration = ModelHTTP.retryDelay) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Our own name, not the HTTP library's: OpenCode Go asks clients to identify themselves.
        request.setValue(ModelHTTP.userAgent, forHTTPHeaderField: "User-Agent")
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        var attempt = 0
        while true {
            do {
                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if (200..<300).contains(status) { return data }
                if attempt == 0, status == 429 || (500..<600).contains(status) {
                    attempt += 1
                    try await Task.sleep(for: retryDelay)
                    continue
                }
                throw ModelClientError.http(status: status, message: errorMessage(from: data, status: status))
            } catch let e as ModelClientError {
                throw e
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw ModelClientError.network((error as NSError).localizedDescription)
            }
        }
    }

    /// The provider's own message, from `{"error": {"message": …}}` (both wire formats use it).
    static func errorMessage(from data: Data, status: Int) -> String {
        if let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            if let err = obj["error"] as? [String: Any], let m = err["message"] as? String, !m.isEmpty { return m }
            if let m = obj["error"] as? String, !m.isEmpty { return m }
            if let m = obj["message"] as? String, !m.isEmpty { return m }
        }
        return "The model answered HTTP \(status)."
    }
}

/// Anthropic's Messages API with tools.
struct AnthropicModelClient: ModelClient {
    let apiKey: String
    let model: String
    var endpoint: URL = URL(string: ProviderEndpoints.anthropic)!
    var retryDelay: Duration = ModelHTTP.retryDelay

    func complete(system: String, messages: [BrainMessage], tools: [BrainTool]) async throws -> BrainTurn {
        let body = BrainWire.anthropicBody(model: model, system: system, messages: messages, tools: tools)
        let data = try await ModelHTTP.post(url: endpoint,
                                            headers: ["x-api-key": apiKey, "anthropic-version": "2023-06-01"],
                                            body: body, retryDelay: retryDelay)
        guard let turn = BrainWire.parseAnthropic(data) else { throw ModelClientError.unreadable }
        return turn
    }
}

/// `POST <baseURL>/chat/completions` with function-calling tools: OpenAI, Google's compatible
/// endpoint, Ollama, LM Studio, OpenCode Zen.
struct OpenAICompatibleModelClient: ModelClient {
    let baseURL: String
    let apiKey: String?
    let model: String
    var retryDelay: Duration = ModelHTTP.retryDelay
    /// Sent with every request (OpenCode Go: `x-opencode-session`).
    var extraHeaders: [String: String] = [:]

    func complete(system: String, messages: [BrainMessage], tools: [BrainTool]) async throws -> BrainTurn {
        let trimmed = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard let url = URL(string: "\(trimmed)/chat/completions") else { throw ModelClientError.unreadable }
        var headers = extraHeaders
        if let apiKey, !apiKey.isEmpty { headers["Authorization"] = "Bearer \(apiKey)" }
        let body = BrainWire.openAIBody(model: model, system: system, messages: messages, tools: tools)
        let data = try await ModelHTTP.post(url: url, headers: headers, body: body, retryDelay: retryDelay)
        guard let turn = BrainWire.parseOpenAI(data) else { throw ModelClientError.unreadable }
        return turn
    }
}
#else
#endif
