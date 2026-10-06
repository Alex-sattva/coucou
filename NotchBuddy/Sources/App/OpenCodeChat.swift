import Foundation

// MARK: - Run result

/// Totals reported by one `opencode run` invocation.
struct OpenCodeRunResult: Sendable {
    var text: String
    var inputTokens: Int?
    var outputTokens: Int?
    var costUsd: Double?
}

// MARK: - In-flight run registry

/// Tracks the in-flight `opencode run` child so the harness can stop it.
@MainActor
final class OpenCodeRunRegistry {
    static let shared = OpenCodeRunRegistry()
    private init() {}
    private var procs: [UUID: Process] = [:]
    /// Runs whose SIGTERM came from `stop`/`stopAll` (not from the watchdog).
    private var stopped: Set<UUID> = []
    var isRunning: Bool { !procs.isEmpty }

    func register(_ id: UUID, _ p: Process) {
        // A child that already exited must never be tracked: its termination
        // handler may have unregistered before this MainActor hop got a turn.
        guard p.isRunning else { return }
        procs[id] = p
    }

    func unregister(_ id: UUID) {
        procs[id] = nil
    }

    /// SIGTERM the child. Returns false when nothing matches (nothing running, or it already exited).
    @discardableResult func stop(_ id: UUID) -> Bool {
        guard let p = procs[id], p.isRunning else { return false }
        stopped.insert(id)
        p.terminate()
        return true
    }

    /// SIGTERM every in-flight child. Returns false when none were running.
    @discardableResult func stopAll() -> Bool {
        var any = false
        for (id, p) in procs where p.isRunning {
            stopped.insert(id)
            p.terminate()
            any = true
        }
        return any
    }

    /// True (once) when this run was deliberately stopped through the registry.
    func consumeStop(_ id: UUID) -> Bool { stopped.remove(id) != nil }
}

// MARK: - OpenCode headless chat engine (CLI `opencode run --format json`)

// Drives the island chat through the user's own OpenCode CLI so the island can
// answer with OpenCode (auth/model config stay in OpenCode, not in Coucou).
// Fire-and-forget watch path (opencode/coucou.ts plugin) stays untouched.
enum OpenCodeChat {

    // MARK: Errors (user-facing copy)

    enum ChatError: Error {
        case cliNotFound
        case timedOut
        case cancelled
        case workingDirectoryUnavailable(String)
        case failed(String)

        var message: String {
            switch self {
            case .cliNotFound:
                return "OpenCode CLI not found. Install it, then ask again."
            case .timedOut:
                return "OpenCode took too long. Try a shorter question."
            case .cancelled:
                return "OpenCode run stopped."
            case .workingDirectoryUnavailable:
                return "That folder is no longer available. Pick another one."
            case .failed(let s) where !s.isEmpty:
                return s
            case .failed:
                return "OpenCode returned no answer."
            }
        }
    }

    // MARK: CLI discovery

    /// Resolves the `opencode` binary: PATH first, then the well-known
    /// Homebrew / user-local fallbacks.
    static func cliURL() -> URL? {
        for dir in ["/opt/homebrew/bin", "/usr/local/bin",
                    "\(NSHomeDirectory())/.opencode/bin",
                    "\(NSHomeDirectory())/.local/bin"] {
            let url = URL(fileURLWithPath: "\(dir)/opencode")
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        // Last resort: whatever `PATH` resolves.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        proc.arguments = ["opencode"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        guard (try? proc.run()) != nil else { return nil }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        let found = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                           encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !found.isEmpty,
              FileManager.default.isExecutableFile(atPath: found) else { return nil }
        return URL(fileURLWithPath: found)
    }

    // MARK: Prompt shaping

    /// Prefixes window/file context on the first turn only (mirrors the
    /// OpenAI-compatible path in ClaudeService).
    static func promptText(query: String, context: PromptContext?,
                           isFirstTurn: Bool) -> String {
        guard isFirstTurn, let ctx = context else { return query }
        switch ctx {
        case .window(let app, let title, let url):
            var prefix = "Context — App: \(app), Window: \(title)"
            if let u = url { prefix += ", URL: \(u)" }
            return prefix + "\n\n" + query
        case .file(let name, let fileURL):
            if let fileURL = fileURL,
               let text = try? String(contentsOf: fileURL, encoding: .utf8),
               !text.isEmpty {
                let truncated = text.count > 24_000
                    ? String(text.prefix(24_000)) + "\n[truncated]"
                    : text
                return "File: \(name)\n\n\(truncated)\n\n" + query
            }
            return "File: \(name)\n\n" + query
        }
    }

    // MARK: Sandbox auth

    /// The island runs the CLI with a sandboxed XDG_DATA_HOME (/tmp/…) so the
    /// provenance-locked real log dir can never crash the call. That sandbox
    /// hides the real auth.json, so seed it before every CLI call that needs
    /// Zen gateway auth (chat + live model catalog).
    static func ensureSandboxAuth() {
        let fm = FileManager.default
        let realAuth = "\(NSHomeDirectory())/.local/share/opencode/auth.json"
        let sandboxDir = "/tmp/opencode-data/opencode"
        let sandboxAuth = "\(sandboxDir)/auth.json"
        try? fm.createDirectory(atPath: sandboxDir, withIntermediateDirectories: true)
        guard let realData = try? Data(contentsOf: URL(fileURLWithPath: realAuth)),
              var obj = try? JSONSerialization.jsonObject(with: realData) as? [String: Any] else { return }
        // The stored opencode-go key can be revoked (401 Invalid credential)
        // while the opencode (Zen) key still authorizes both gateways
        // (verified: Zen key lists + chats on /zen/go/v1). Mirror it so
        // opencode-go/* models resolve instead of provider.no-route.
        if var go = obj["opencode-go"] as? [String: Any],
           let zen = obj["opencode"] as? [String: Any],
           let zenKey = zen["key"] as? String, !zenKey.isEmpty,
           (go["key"] as? String) != zenKey {
            go["key"] = zenKey
            obj["opencode-go"] = go
        }
        guard let patched = try? JSONSerialization.data(withJSONObject: obj) else { return }
        if (try? Data(contentsOf: URL(fileURLWithPath: sandboxAuth))) != patched {
            try? patched.write(to: URL(fileURLWithPath: sandboxAuth))
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sandboxAuth)
        }
    }

    /// Zen key that authorizes both gateways (env override for Go models).
    static func zenAPIKey() -> String? {
        let realAuth = "\(NSHomeDirectory())/.local/share/opencode/auth.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: realAuth)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let zen = obj["opencode"] as? [String: Any],
              let key = zen["key"] as? String, !key.isEmpty else { return nil }
        return key
    }

    // MARK: JSON extraction (`opencode run --format json`)

    /// Extracts assistant text from `opencode run --format json` output, which
    /// is JSONL: one object per line, e.g. `{"type":"step_start",…}` followed
    /// by `{"type":"text",…,"part":{"text":"…"}}`. Errors arrive the same way
    /// (`{"type":"error","error":{"message":"…"}}`) with exit code 0, so they
    /// must be detected here — otherwise the island shows raw JSON or hangs.
    /// Falls back to trimmed raw stdout when the output is not JSON at all
    /// (plain-text format). Throws ChatError.failed on error lines or when
    /// JSON parses but carries no text.
    static func extractText(from data: Data) throws -> String {
        try parseRun(from: data).text
    }

    /// Single pass over the JSONL: the assistant text plus whatever token/cost
    /// totals the CLI reported (each of them may stay nil). Missing usage is
    /// never an error — the throw conditions are `extractText`'s, unchanged.
    private static func parseRun(from data: Data) throws -> OpenCodeRunResult {
        let raw = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else { throw ChatError.failed("") }
        // Plain text (not JSON): return as-is.
        guard raw.hasPrefix("{") else { return OpenCodeRunResult(text: raw) }
        var result = OpenCodeRunResult(text: "")
        var texts: [String] = []
        var errorMessage: String? = nil
        var parsedAny = false
        for line in raw.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let lineData = trimmed.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }
            parsedAny = true
            collectUsage(from: json, into: &result)
            if let err = json["error"] as? [String: Any],
               let msg = err["message"] as? String, !msg.isEmpty {
                errorMessage = msg
                continue
            }
            if let type = json["type"] as? String, type == "error" {
                if let msg = json["message"] as? String, !msg.isEmpty { errorMessage = msg }
                continue
            }
            // Canonical shape: { type: text, part: { text } }.
            if let part = json["part"] as? [String: Any],
               let t = part["text"] as? String, !t.isEmpty {
                texts.append(t)
                continue
            }
            // Legacy single-object shapes (kept for back-compat).
            if let s = json["text"] as? String, !s.isEmpty { texts.append(s); continue }
            if let s = json["response"] as? String, !s.isEmpty { texts.append(s); continue }
            if let s = json["message"] as? String, !s.isEmpty { texts.append(s); continue }
            if let s = json["result"] as? String, !s.isEmpty { texts.append(s); continue }
            if let s = json["output"] as? String, !s.isEmpty { texts.append(s); continue }
            if let parts = json["parts"] as? [[String: Any]] {
                let joined = parts.compactMap { part -> String? in
                    guard (part["type"] as? String) == "text",
                          let t = part["text"] as? String, !t.isEmpty else { return nil }
                    return t
                }.joined(separator: "\n")
                if !joined.isEmpty { texts.append(joined); continue }
            }
            if let choices = json["choices"] as? [[String: Any]],
               let message = choices.first?["message"] as? [String: Any],
               let content = message["content"] as? String, !content.isEmpty {
                texts.append(content)
            }
        }
        if !texts.isEmpty {
            result.text = texts.joined(separator: "\n")
            return result
        }
        if let msg = errorMessage, !msg.isEmpty { throw ChatError.failed(msg) }
        // JSON but unknown shape: don't show raw JSON in the island.
        if parsedAny { throw ChatError.failed("") }
        result.text = raw
        return result
    }

    // MARK: Usage totals (same pass as the text)

    // TODO(stream): emit incremental token totals while the run is still live.

    /// Adds one JSONL line's token/cost fields to `result`. `--format json`
    /// emits one `step_finish` per agent step and the spellings drift between
    /// versions, so several shapes are accepted and values are summed. Anything
    /// unreadable is ignored: a total the CLI never reported stays nil.
    private static func collectUsage(from json: [String: Any],
                                     into result: inout OpenCodeRunResult) {
        let part = json["part"] as? [String: Any]
        let usage = (json["usage"] as? [String: Any])
            ?? (json["tokens"] as? [String: Any])
            ?? (part?["usage"] as? [String: Any])
            ?? (part?["tokens"] as? [String: Any])
            ?? json
        if let n = firstInt(usage, ["input_tokens", "prompt_tokens", "input", "prompt"]) {
            result.inputTokens = (result.inputTokens ?? 0) + n
        }
        if let n = firstInt(usage, ["output_tokens", "completion_tokens", "output", "completion"]) {
            result.outputTokens = (result.outputTokens ?? 0) + n
        }
        if let c = firstCost([usage, part, json]) {
            result.costUsd = (result.costUsd ?? 0) + c
        }
    }

    private static func firstInt(_ obj: [String: Any], _ keys: [String]) -> Int? {
        for key in keys { if let v = intValue(obj[key]) { return v } }
        return nil
    }

    /// First cost found, in container order. A nested `{ total: … }` shape is
    /// accepted as well as a bare number.
    private static func firstCost(_ objects: [[String: Any]?]) -> Double? {
        for case let obj? in objects {
            for key in ["cost", "total_cost_usd", "cost_usd", "total_cost", "totalCost", "costUSD"] {
                if let d = doubleValue(obj[key]) { return d }
                if let sub = obj[key] as? [String: Any] {
                    let nested = doubleValue(sub["total"])
                        ?? doubleValue(sub["total_cost_usd"])
                        ?? doubleValue(sub["cost_usd"])
                    if let nested { return nested }
                }
            }
        }
        return nil
    }

    private static func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let d = any as? Double { return Int(d) }
        if let s = any as? String, let d = Double(s) { return Int(d) }
        return nil
    }

    private static func doubleValue(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let s = any as? String, let d = Double(s) { return d }
        return nil
    }

    // MARK: One-shot run

    /// Runs `opencode run --format json --standalone --model <model> <prompt>`.
    /// - Timeout: 120s (kills the child on expiry).
    /// - Env: sandboxed TMPDIR/XDG_DATA_HOME so the provenance-locked default
    ///   log dir can never crash the call. Sandbox auth is seeded first so Zen
    ///   gateway models can authenticate.
    /// - `--standalone`: never touches the shared managed background service
    ///   (port 49374), which otherwise wedges `run` with "Timed out waiting
    ///   for the background service to start" and leaves the island on "…".
    /// - `cwd`: per-folder working directory; nil keeps the historical `$HOME`
    ///   behaviour, a non-nil URL must exist and be a directory.
    /// - The live child is registered in `OpenCodeRunRegistry` so the harness
    ///   can SIGTERM it through `stop(runId)` / `stopAll()`.
    @discardableResult
    static func run(prompt: String, model: String, cwd: URL? = nil,
                    runId: UUID = UUID()) async throws -> OpenCodeRunResult {
        guard let cli = cliURL() else { throw ChatError.cliNotFound }
        if let cwd = cwd {
            var isDir: ObjCBool = false
            let ok = FileManager.default.fileExists(atPath: cwd.path, isDirectory: &isDir)
            guard ok && isDir.boolValue else {
                throw ChatError.workingDirectoryUnavailable(cwd.path)
            }
        }
        ensureSandboxAuth()
        return try await withCheckedThrowingContinuation { cont in
            let proc = Process()
            proc.executableURL = cli
            proc.arguments = ["run", "--format", "json", "--standalone", "--model", model, prompt]
            var env = ProcessInfo.processInfo.environment
            env["TMPDIR"] = "/tmp"
            env["XDG_DATA_HOME"] = "/tmp/opencode-data"
            env["XDG_STATE_HOME"] = "/tmp/opencode-state"
            // OPENCODE_API_KEY env overrides per-provider auth; the Zen key
            // authorizes both gateways, the stored Go key is revoked (401).
            if let zenKey = zenAPIKey(), !zenKey.isEmpty {
                env["OPENCODE_API_KEY"] = zenKey
            }
            proc.environment = env
            proc.currentDirectoryURL = cwd ?? URL(fileURLWithPath: NSHomeDirectory())
            let outPipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe
            proc.standardInput = FileHandle.nullDevice
            do { try proc.run() } catch {
                cont.resume(throwing: ChatError.failed(error.localizedDescription))
                return
            }
            // Registry is MainActor-owned, hence the hop. It refuses a child
            // that already exited, so a late hop can never leak an entry.
            Task { @MainActor in OpenCodeRunRegistry.shared.register(runId, proc) }
            // Watchdog: kill after 120s. A DispatchSourceTimer IS Sendable, so
            // it can be captured by the @Sendable termination handler cleanly.
            let watchdog = DispatchSource.makeTimerSource(queue: .global())
            watchdog.schedule(deadline: .now() + 120)
            watchdog.setEventHandler { if proc.isRunning { proc.terminate() } }
            watchdog.resume()
            proc.terminationHandler = { _ in
                watchdog.cancel()
                let status = proc.terminationStatus
                let out = outPipe.fileHandleForReading.readDataToEndOfFile()
                // Parse on the background thread; only the stop verdict needs
                // the MainActor registry.
                let outcome: Result<OpenCodeRunResult, Error>
                if status == 0 {
                    do {
                        var parsed = try parseRun(from: out)
                        parsed.text = parsed.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        outcome = parsed.text.isEmpty
                            ? .failure(ChatError.failed(""))
                            : .success(parsed)
                    } catch {
                        outcome = .failure(error)
                    }
                } else if status == 15 {  // SIGTERM from the watchdog or a deliberate stop
                    outcome = .failure(ChatError.timedOut)
                } else {
                    // opencode writes JSONL errors to stdout even on exit 1
                    // (e.g. {"type":"error","error":{"message":"Model unavailable: …"}}),
                    // with stderr empty — parse stdout first to surface the real cause.
                    let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                                     encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    var stdoutMsg: String? = nil
                    do { _ = try extractText(from: out) } catch let e as ChatError {
                        if case .failed(let s) = e, !s.isEmpty { stdoutMsg = s }
                    } catch {}
                    outcome = .failure(ChatError.failed(
                        stdoutMsg ?? (err.isEmpty ? "OpenCode exited with code \(status)." : err)))
                }
                // Unregister and read the deliberate-stop flag in the same hop:
                // a stop makes terminationStatus 15 too, so only the registry
                // can tell it apart from the watchdog's timeout.
                Task { @MainActor in
                    let wasStopped = OpenCodeRunRegistry.shared.consumeStop(runId)
                    OpenCodeRunRegistry.shared.unregister(runId)
                    if status == 15, wasStopped {
                        cont.resume(throwing: ChatError.cancelled)
                    } else {
                        cont.resume(with: outcome)
                    }
                }
            }
        }
    }

    // MARK: Model catalog (private `opencode serve` + GET /api/model)

    /// Fetches the live model catalog: private `opencode serve` /api/model
    /// first (respects enabled state), falling back to OpenCode's own disk
    /// cache (~/.cache/opencode/models.json, providers `opencode` +
    /// `opencode-go`) so the picker still populates when the live call is
    /// empty. Returns [(id: "provider/model", label: "Display name")].
    static func fetchModels() async throws -> [(id: String, label: String)] {
        if let live = try? await fetchLiveModels(), !live.isEmpty { return live }
        if let cached = readCachedModels(), !cached.isEmpty { return cached }
        // Retry live once with the error surfaced so Settings shows copy.
        return try await fetchLiveModels()
    }

    /// Reads OpenCode's own model cache written by the CLI after auth.
    /// Only the two authed Zen gateway providers are listed — the other 220+
    /// cached providers need third-party keys Coucou doesn't hold.
    static func readCachedModels() -> [(id: String, label: String)]? {
        let cacheURL = URL(fileURLWithPath: "\(NSHomeDirectory())/.cache/opencode/models.json")
        guard let data = try? Data(contentsOf: cacheURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        var out: [(id: String, label: String)] = []
        for providerID in ["opencode", "opencode-go"] {
            guard let provider = root[providerID] as? [String: Any],
                  let models = provider["models"] as? [String: Any] else { continue }
            for (modelID, meta) in models {
                guard !modelID.isEmpty else { continue }
                let name = (meta as? [String: Any])?["name"] as? String
                let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let id = "\(providerID)/\(modelID)"
                out.append((id: id, label: trimmed.isEmpty ? id : trimmed))
            }
        }
        guard !out.isEmpty else { return nil }
        return out.sorted { $0.id < $1.id }
    }

    /// Live catalog from a private OpenCode server.
    static func fetchLiveModels() async throws -> [(id: String, label: String)] {
        guard let cli = cliURL() else { throw ChatError.cliNotFound }
        ensureSandboxAuth()
        let port = Int.random(in: 18000..<19000)
        let proc = Process()
        proc.executableURL = cli
        proc.arguments = ["serve", "--port", "\(port)", "--hostname", "127.0.0.1"]
        var env = ProcessInfo.processInfo.environment
        env["TMPDIR"] = "/tmp"
        env["XDG_DATA_HOME"] = "/tmp/opencode-data"
        env["XDG_STATE_HOME"] = "/tmp/opencode-state"
        proc.environment = env
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = FileHandle.nullDevice
        proc.standardInput = FileHandle.nullDevice
        do { try proc.run() } catch {
            throw ChatError.failed(error.localizedDescription)
        }
        defer { if proc.isRunning { proc.terminate() } }

        // Wait up to 10s for the "server listening … / server password …" lines.
        let deadline = Date().addingTimeInterval(10)
        var output = ""
        var password: String? = nil
        let handle = outPipe.fileHandleForReading
        while Date() < deadline {
            if let chunk = try? handle.availableData, !chunk.isEmpty,
               let s = String(data: chunk, encoding: .utf8) {
                output += s
            }
            if output.contains("server listening on"),
               let range = output.range(of: "server password ") {
                let tail = String(output[range.upperBound...])
                password = tail.split(whereSeparator: \.isWhitespace).first.map(String.init)
                if password != nil { break }
            }
            if !proc.isRunning { break }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        // Drain any remaining buffered stdout (password may arrive with listening line).
        if password == nil, let rest = try? handle.availableData,
           let s = String(data: rest, encoding: .utf8), !s.isEmpty {
            output += s
            if let range = output.range(of: "server password ") {
                let tail = String(output[range.upperBound...])
                password = tail.split(whereSeparator: \.isWhitespace).first.map(String.init)
            }
        }
        guard let password else {
            throw ChatError.failed("OpenCode server did not start (no password in output).")
        }

        // GET /api/model with basic auth opencode:<password>, 10s cap.
        guard let url = URL(string: "http://127.0.0.1:\(port)/api/model") else {
            throw ChatError.failed("Bad model URL.")
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        let creds = "opencode:\(password)"
        if let data = creds.data(using: .utf8) {
            req.setValue("Basic \(data.base64EncodedString())", forHTTPHeaderField: "Authorization")
        }
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(for: req)
        } catch {
            throw ChatError.failed("Could not reach the OpenCode model API.")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ChatError.failed("OpenCode returned an unreadable model list.")
        }
        let raw: [[String: Any]]
        if let arr = json["data"] as? [[String: Any]] { raw = arr }
        else if let arr = json["models"] as? [[String: Any]] { raw = arr }
        else { throw ChatError.failed("OpenCode returned an unreadable model list.") }
        let models: [(id: String, label: String)] = raw.compactMap { m in
            guard let provider = m["providerID"] as? String,
                  let modelID = m["modelID"] as? String, !modelID.isEmpty else { return nil }
            let name = (m["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let id = "\(provider)/\(modelID)"
            return (id: id, label: (name?.isEmpty == false) ? name! : id)
        }
        guard !models.isEmpty else {
            throw ChatError.failed("OpenCode reported no models.")
        }
        return models.sorted { $0.id < $1.id }
    }

    // MARK: Island entry point

    /// Answers one island turn via the OpenCode CLI. Mirrors the placeholder +
    /// happy-emote flow of the other engines so the island behaves identically.
    /// Called off the main actor (from ClaudeService); all AppState touches go
    /// through MainActor.run because AppState is @MainActor.
    static func chat(query: String, context: PromptContext?, state: AppState) async {
        let model: String = await MainActor.run {
            let m = state.opencodeChatModel.trimmingCharacters(in: .whitespacesAndNewlines)
            return m.isEmpty ? ChatProvider.opencode.defaultModel : m
        }
        let isFirstTurn: Bool = await MainActor.run { state.chatHistory.isEmpty }
        let prompt = promptText(query: query, context: context, isFirstTurn: isFirstTurn)

        let msgId: UUID = await MainActor.run {
            let placeholder = ChatMessage(role: .assistant, content: "")
            state.chatHistory.append(placeholder)
            state.stateOverride = .thinking
            return placeholder.id
        }
        do {
            let answer = try await run(prompt: prompt, model: model).text
            await MainActor.run {
                if let idx = state.chatHistory.firstIndex(where: { $0.id == msgId }) {
                    state.chatHistory[idx].content = answer
                }
                state.stateOverride = nil
                state.view = .prompt
            }
            NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.happy)
        } catch let e as ChatError {
            await MainActor.run {
                state.chatHistory.removeAll { $0.id == msgId }
                state.stateOverride = nil
                state.noteMessage = e.message
                state.view = .note
            }
        } catch {
            await MainActor.run {
                state.chatHistory.removeAll { $0.id == msgId }
                state.stateOverride = nil
                state.noteMessage = error.localizedDescription
                state.view = .note
            }
        }
    }
}
