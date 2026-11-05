import Foundation

// Foundation only (compiled by scripts/test-opencode-server.sh against a fake `opencode`).
// A private `opencode serve` per project folder, and the small HTTP + SSE client Mochi talks to it with.
// The routes are OpenCode v2's (checked against `GET /openapi.json` of opencode 2.0.16).

// MARK: - The server process

/// A running `opencode serve`. The basic-auth password lives in memory only.
final class OpenCodeServerProcess: @unchecked Sendable {
    let process: Process
    let port: Int
    private let password: String

    init(process: Process, port: Int, password: String) {
        self.process = process
        self.port = port
        self.password = password
    }

    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }
    var isRunning: Bool { process.isRunning }

    /// `Authorization` header value: basic auth `opencode:<password>`.
    var authorization: String {
        "Basic " + Data("opencode:\(password)".utf8).base64EncodedString()
    }

    func client() -> OpenCodeClient { OpenCodeClient(baseURL: baseURL, authorization: authorization) }

    func terminate() {
        if process.isRunning { process.terminate() }
    }
}

enum OpenCodeServerLauncher {
    enum LaunchError: Error, Equatable {
        case folderMissing(String)
        case noPassword          // never printed its address and password in time
        case exited(Int32)       // died during start-up (a taken port, a broken install)
    }

    /// A free TCP port on 127.0.0.1, asked of the system. nil when none could be bound.
    static func freePort() -> Int? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { return nil }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let got = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        guard got == 0 else { return nil }
        return Int(UInt16(bigEndian: addr.sin_port))
    }

    /// Starts `opencode serve --hostname 127.0.0.1 --port <free>` in `cwd` and waits (up to
    /// `timeout`) for it to print `server listening on …` and `server password …`. A start-up
    /// that dies (a port taken between the check and the bind) is retried on another port, up to 3 times.
    static func launch(cli: URL, cwd: String?, environment: [String: String],
                       timeout: TimeInterval = 10) async throws -> OpenCodeServerProcess {
        if let cwd {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue else {
                throw LaunchError.folderMissing(cwd)
            }
        }
        var last: Error = LaunchError.noPassword
        for _ in 0..<3 {
            do {
                return try await launchOnce(cli: cli, cwd: cwd, environment: environment, timeout: timeout)
            } catch LaunchError.exited(let status) {
                last = LaunchError.exited(status)
            }
        }
        throw last
    }

    private static func launchOnce(cli: URL, cwd: String?, environment: [String: String],
                                   timeout: TimeInterval) async throws -> OpenCodeServerProcess {
        let port = freePort() ?? Int.random(in: 18_000..<19_000)
        let proc = Process()
        proc.executableURL = cli
        proc.arguments = ["serve", "--hostname", "127.0.0.1", "--port", "\(port)"]
        proc.environment = environment
        if let cwd { proc.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        proc.standardInput = FileHandle.nullDevice

        let scan = StartupScan()
        // Event-driven. The handler stays attached for the server's whole life so its stdout can
        // never fill a pipe; after the start-up lines the data is dropped.
        out.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { scan.feed(data) }
        }
        proc.terminationHandler = { p in scan.fail(LaunchError.exited(p.terminationStatus)) }
        do { try proc.run() } catch {
            out.fileHandleForReading.readabilityHandler = nil
            throw error
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { scan.fail(LaunchError.noPassword) }
        do {
            let password = try await scan.wait()
            return OpenCodeServerProcess(process: proc, port: port, password: password)
        } catch {
            out.fileHandleForReading.readabilityHandler = nil
            if proc.isRunning { proc.terminate() }
            throw error
        }
    }

    /// Reads the start-up lines: succeeds once the password line is complete.
    final class StartupScan: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = ""
        private var listening = false
        private var result: Result<String, Error>?
        private var waiter: CheckedContinuation<String, Error>?

        func feed(_ data: Data) {
            lock.lock()
            if result != nil { lock.unlock(); return }
            buffer += String(decoding: data, as: UTF8.self)
            if buffer.contains("server listening on") { listening = true }
            // A password counts only once its line is complete, or a split chunk would cut it short.
            var found: String?
            if listening, let r = buffer.range(of: "server password ") {
                let rest = buffer[r.upperBound...]
                if let end = rest.firstIndex(where: \.isNewline) {
                    let token = rest[..<end].trimmingCharacters(in: .whitespaces)
                    if !token.isEmpty { found = token }
                }
            }
            lock.unlock()
            if let found { resolve(.success(found)) }
        }

        func fail(_ error: Error) { resolve(.failure(error)) }

        func wait() async throws -> String {
            try await withCheckedThrowingContinuation { cont in
                lock.lock()
                if let result { lock.unlock(); cont.resume(with: result); return }
                waiter = cont
                lock.unlock()
            }
        }

        private func resolve(_ r: Result<String, Error>) {
            lock.lock()
            guard result == nil else { lock.unlock(); return }
            result = r
            let w = waiter
            waiter = nil
            lock.unlock()
            w?.resume(with: r)
        }
    }
}

// MARK: - The client

enum OpenCodeClientError: Error, LocalizedError, Equatable {
    case http(status: Int, message: String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .http(_, let message): return message
        case .badResponse: return "OpenCode sent an answer Mochi could not read."
        }
    }
}

/// HTTP + SSE against one OpenCode server. Stateless apart from the URL session.
final class OpenCodeClient: Sendable {
    let baseURL: URL
    private let authorization: String
    private let session: URLSession
    private let streamSession: URLSession

    init(baseURL: URL, authorization: String) {
        self.baseURL = baseURL
        self.authorization = authorization
        let normal = URLSessionConfiguration.ephemeral
        normal.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: normal)
        // The event stream is long-lived. OpenCode 2.0.16 sends a `: heartbeat` every 15 s (watched on an idle
        // stream for over 5 minutes), so 90 s of silence is six missed beats: that is a dead connection.
        let stream = URLSessionConfiguration.ephemeral
        stream.timeoutIntervalForRequest = 90
        stream.timeoutIntervalForResource = .infinity
        self.streamSession = URLSession(configuration: stream)
    }

    // MARK: Requests

    /// Sends a JSON request and returns the decoded JSON (nil for an empty body). Throws on non-2xx
    /// with OpenCode's own message.
    @discardableResult
    func request(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> Any? {
        guard let url = URL(string: path, relativeTo: baseURL) else { throw OpenCodeClientError.badResponse }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue(authorization, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw OpenCodeClientError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw OpenCodeClientError.http(status: http.statusCode, message: Self.message(from: data, status: http.statusCode))
        }
        guard !data.isEmpty else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    static func message(from data: Data, status: Int) -> String {
        if let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let message = obj["message"] as? String, !message.isEmpty { return message }
        return "OpenCode answered HTTP \(status)."
    }

    /// `POST /api/session`: a session in `directory`, on `model` when given. Never sends permission rules.
    func createSession(directory: String, model: ModelRef?) async throws -> String {
        var body: [String: Any] = ["location": ["directory": directory]]
        if let model, let provider = model.providerID, !model.id.isEmpty {
            body["model"] = ["providerID": provider, "id": model.id]
        }
        let json = try await request("POST", "/api/session", body: body) as? [String: Any]
        guard let id = (json?["data"] as? [String: Any])?["id"] as? String else { throw OpenCodeClientError.badResponse }
        return id
    }

    /// `POST /api/session/{id}/prompt`. `queue`: wait for the current turn instead of steering it.
    func prompt(session id: String, text: String, queue: Bool = false) async throws {
        var body: [String: Any] = ["text": text]
        if queue { body["delivery"] = "queue" }
        try await request("POST", "/api/session/\(id)/prompt", body: body)
    }

    func interrupt(session id: String) async throws {
        try await request("POST", "/api/session/\(id)/interrupt")
    }

    func setModel(session id: String, model: ModelRef) async throws {
        guard let provider = model.providerID else { return }
        try await request("POST", "/api/session/\(id)/model", body: ["model": ["providerID": provider, "id": model.id]])
    }

    /// `decision`: once, always or reject. `always` is only ever passed after the user clicked it.
    func replyPermission(session id: String, request requestId: String, decision: String) async throws {
        try await request("POST", "/api/session/\(id)/permission/\(requestId)/reply", body: ["decision": decision])
    }

    func replyForm(session id: String, form formId: String, answer: [String: Any]) async throws {
        try await request("POST", "/api/session/\(id)/form/\(formId)/reply", body: ["answer": answer])
    }

    /// Same, with the answer already as JSON bytes (they can cross actors; a dictionary cannot).
    func replyForm(session id: String, form formId: String, answerJSON: Data) async throws {
        let answer = (try? JSONSerialization.jsonObject(with: answerJSON)) as? [String: Any] ?? [:]
        try await replyForm(session: id, form: formId, answer: answer)
    }

    func cancelForm(session id: String, form formId: String) async throws {
        try await request("DELETE", "/api/session/\(id)/form/\(formId)")
    }

    /// Sessions the server is running right now.
    func activeSessions() async throws -> Set<String> {
        let json = try await request("GET", "/api/session/active") as? [String: Any]
        return Set((json?["data"] as? [String: Any])?.keys.map { $0 } ?? [])
    }

    // MARK: Events

    /// The server's SSE stream (`GET /api/event`): every `data:` line, parsed. Ends when the
    /// connection ends; throws when it breaks.
    func events() -> AsyncThrowingStream<[String: Any], Error> {
        let session = streamSession, base = baseURL, auth = authorization
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let url = URL(string: "/api/event", relativeTo: base) else { throw OpenCodeClientError.badResponse }
                    var req = URLRequest(url: url)
                    req.setValue(auth, forHTTPHeaderField: "Authorization")
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    let (bytes, response) = try await session.bytes(for: req)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        throw OpenCodeClientError.http(status: http.statusCode, message: "OpenCode event stream refused (HTTP \(http.statusCode)).")
                    }
                    for try await line in bytes.lines {
                        if let event = OpenCodeEvents.parseLine(line) { continuation.yield(event) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - Reconnect

enum OpenCodeReconnect {
    static let maxDelay: TimeInterval = 30

    /// 1, 2, 4, 8, 16, 30, 30… seconds for attempt 0, 1, 2…
    static func delay(attempt: Int) -> TimeInterval {
        guard attempt >= 0 else { return 1 }
        return min(maxDelay, pow(2, Double(min(attempt, 10))))
    }
}
