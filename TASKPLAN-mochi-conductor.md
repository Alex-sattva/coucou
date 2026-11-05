# TASKPLAN — Mochi as conductor: any model, any agent, notch-sized output

**Repo:** `/Users/kepla/Desktop/code/coucou` · **Branch:** `feature/voice-harness` · **Platform:** macOS app (`NotchBuddy/`), **GitHub build only** (`#if !APPSTORE` around every new call site). `windows/` is out.
**Builds on:** the uncommitted "Mochi-aware sessions" work on this branch (`MochiAware`, `MochiNote`, `MochiAction`, `MochiActionSafety`, `AppState.mochiSessionIds`, the finished card's suggestion row). This plan replaces its `<mochi>` text tags with a typed tool.

This is an implementation spec. It pins what you cannot recover from the code. Local naming, line-by-line shapes and ordering inside a step are yours. If you see a better path from inside the repo, take it and **report the deviation**.

---

## 0. Read before writing any code

- `CLAUDE.md` (repo root). The rules that bite here: Swift 6, **no third-party dependencies**, secrets only in the Keychain, **never block Claude Code**, **never approve a permission without an explicit click**, **0 % CPU when the island is hidden**, **never restyle what already ships**, pill IDs never renamed, `~/.claude/settings.json` never overwritten, network calls only to services the user configured.
- `HookServer.swift`: the Unix-socket server (`nb.sock`), the embedded `nb-hook` Python relay (search `#!/usr/bin/env python3`), and the held-connection pattern for `PermissionRequest` and AskUserQuestion (`--ask`). The approval and question cards answer through those held connections today.
- `AssistantModel.swift`: `submitTask` → router → `execute(_:)` → `sendToSession` / `proposeLaunch` / `confirmLaunch`. `launchClaudeReply` is the per-turn `claude -p --resume` this plan retires for Mochi-owned sessions.
- `ClaudeCodeRun.swift`: `cliURL()`, the PATH fix-up and `PipeBuffer` draining. Reuse them.
- `OpenCodeChat.swift`: `cliURL()`, Zen key handling (`zenAPIKey()`), and the private `opencode serve` start-up (it reads `server password …` from stdout and uses basic auth `opencode:<password>`). Reuse that start-up code; do not write a second one.
- `ClaudeService.swift` + `IslandTypes.swift` (`ChatProvider`): the six providers Chat already supports and where each key / server URL lives. The brain's model clients reuse these.
- `OpencodePluginSource.swift`: the OpenCode plugin that feeds hook events from OpenCode. It still fires inside Mochi's own `opencode serve` processes (see Step 3 gotchas).
- Build without Xcode: `scripts/build-cli.sh` (or `--typecheck`). After adding Swift files, run `.tmp/xcodegen/xcodegen/bin/xcodegen` in `NotchBuddy/` and commit the regenerated project.

## Product decisions (locked with the owner — do not reopen)

1. **Mochi stays the small notch.** No chat window, no transcript view, no new text surface. Everything the user sees uses the notch's **existing vocabulary**: the strip of small Mochis, the finished card (one line + up to 3 suggestion buttons + changed files), the question card, the approval card, the launch card, the bar. Full conversations stay in each agent ("Open session" hands off to the terminal).
2. **Nothing depends on one vendor.** Two plug points:
   - **Worker runtime**: the coding agent doing project work. First version: **OpenCode** (any model OpenCode supports: OpenAI, Anthropic, Google, OpenRouter, local…) and **Claude Code** (Claude models, the user's Claude login). Codex and Gemini CLI come later behind the same contract.
   - **Brain model**: the model Mochi thinks with. Mochi's **own** small tool-calling loop in Swift, with its **own model picker** in Settings (provider + model), independent of Chat. Providers: Anthropic, OpenAI, Google, Ollama, LM Studio, OpenCode Zen.
3. **Routing:** when the panel's main session is a Mochi worker, bar text goes **straight to that worker**, unchanged. Otherwise it goes to the **brain**. When the brain is off or has no usable model, the existing router path runs exactly as today.
4. **Mochi owns its workers.** No terminal opens for Mochi-started work. "Open session" on a worker stops it first, then opens that agent's own resume command in the terminal. Sessions the user starts themselves keep working exactly as today.
5. **The brain may start or continue project work without a confirm card.** Safety stays where it is: every tool approval of every worker goes to the notch approval card. Nothing is approved without a click.
6. **When things pile up, Mochi says so in one line.** When three or more sessions need you at once, Mochi shows a digest card ("bapoojee needs you, coucou is done, docs is still working") with buttons to jump to each. It's built from the session store, with no model call, so it's instant and works with any model or with the assistant off.
7. **Text only by default.** A new setting, **"Read Mochi's updates aloud"** (default **off**), speaks Mochi's lines. The existing `spokenRepliesEnabled` is unchanged.

---

## Architecture — one chosen approach

```
                      ┌──────────── brain (Mochi's own loop) ────────────┐
user ─bar/⌥─▶ AssistantModel ─┤  ModelClient: Anthropic | OpenAI-compatible       │
                      │  tools in-process: list_projects, project_status, │
                      │  start_project_work, send_to_project, ask_user,   │
                      │  report                                           │
                      └──────────────┬────────────────────────────────────┘
       main is a worker ─────────────┤ (direct)
                                     ▼
                         WorkerManager ── AgentRuntime ──┬─ ClaudeCodeRuntime (claude -p stream-json, 1 process / session)
                                                         └─ OpenCodeRuntime   (opencode serve, 1 server / project folder, HTTP + SSE)
   worker's `report` tool:  agent ──MCP stdio──▶ nb-hook --mcp ──▶ nb.sock ──▶ MochiMCP ──▶ session store
   Claude hooks / OpenCode plugin ─▶ nb-hook ─▶ HookServer ─▶ session store, strip, cards   (unchanged)
   OpenCode approvals / questions ─▶ OpenCodeRuntime (SSE) ─▶ same approval / question cards (new responder)
```

**The normalised layer already exists:** `AgentSessionStore` + `SessionEvent` (`AgentSession.swift`). Every runtime and the brain feed it. The strip and every card read only from it. Do not build a second session model.

**Approvals and questions get one responder abstraction.** Today a card resolves by writing to a held hook fd. Introduce `PendingRequestResponder` (an enum: `.hook(fd)`, `.openCode(server, sessionID, requestID)`, `.brain(continuation)`) so the **same** approval card and question card resolve any source. The card's look and keys don't change.

**MCP transport for `report`:** the existing `nb-hook` script gains a `--mcp` mode, a stdio MCP server that relays each JSON-RPC line to `nb.sock` as `{"coucou_kind":"mcp","coucou_role":"worker","coucou_runtime":"<claude|opencode>","coucou_owner":"<owner>","rpc":<message>}` and prints the app's reply line. MCP protocol version `2025-06-18`. Server name **`coucou`**.
- Claude Code: `--mcp-config <json>` per process. `owner` = that session's id (env `COUCOU_OWNER`).
- OpenCode: `OPENCODE_CONFIG_CONTENT` on that project's `opencode serve`, adding an `mcp.coucou` local server. `owner` = the project folder path (env `COUCOU_OWNER`). A report goes to that project's Mochi worker session that is currently busy (else the most recently prompted one).

### Cross-module contracts (exact)

| Symbol | File | Signature |
|---|---|---|
| `AgentRuntime` | `Sources/App/AgentRuntime.swift` (new) | `@MainActor protocol AgentRuntime: AnyObject` · `var kind: ProjectCLI { get }` · `func start(projectPath: String, model: ModelRef?, prompt: String?) async throws -> String /* sessionId */` · `func send(_ text: String, session: String) async throws` · `func interrupt(session: String) async` · `func stop(session: String) async` · `func handOffToTerminal(session: String) async` · `func stopAll() async` · `func owns(_ session: String) -> Bool` |
| `ModelRef` | `Sources/App/AgentSession.swift` | `struct ModelRef: Equatable, Sendable, Codable { var providerID: String?; var id: String }`. Claude: `providerID == nil`, `id` = alias or full id. OpenCode: both set. |
| `ClaudeStreamProcess` | `Sources/App/ClaudeStreamProcess.swift` (new) | `final class ClaudeStreamProcess: @unchecked Sendable` · `init(cwd: String, arguments: [String], environment: [String: String], onEvent: @escaping @Sendable ([String: Any]) -> Void, onExit: @escaping @Sendable (Int32) -> Void)` · `func start() throws` · `func send(userText: String)` · `func interrupt()` · `func stop()` · `var isRunning: Bool` |
| `ClaudeCodeRuntime` | `Sources/App/ClaudeCodeRuntime.swift` (new) | conforms to `AgentRuntime` |
| `OpenCodeRuntime` | `Sources/App/OpenCodeRuntime.swift` (new) | conforms to `AgentRuntime`. Also `func reply(permission requestID: String, session: String, decision: String /* once|always|reject */) async` and `func reply(form formID: String, session: String, answer: [String: Any]) async` |
| `WorkerManager` | `Sources/App/WorkerManager.swift` (new) | `@MainActor final class WorkerManager` · `static let shared` · `func start(projectPath: String, runtime: ProjectCLI, model: ModelRef?, prompt: String?) async throws -> String` · `func send(_ text: String, toSession id: String) async -> Bool` · `func isWorker(_ id: String) -> Bool` · `func handOffToTerminal(sessionId: String) async` · `func stopAll() async` · `func runtime(for session: String) -> AgentRuntime?` |
| `ModelClient` | `Sources/App/ModelClient.swift` (new) | `protocol ModelClient: Sendable` · `func complete(system: String, messages: [BrainMessage], tools: [BrainTool]) async throws -> BrainTurn` · impls `AnthropicModelClient`, `OpenAICompatibleModelClient` |
| `BrainMessage` / `BrainTool` / `BrainTurn` | `Sources/App/AssistantLogic.swift` (pure) | `BrainMessage` = role (`user` / `assistant` / `tool`), text, tool calls, tool-call id. `BrainTool` = name, description, JSON schema. `BrainTurn` = text + `[BrainToolCall(id, name, arguments: [String: Any])]`. Plus pure encoders/decoders: `static func anthropicBody(…) -> [String: Any]`, `static func openAIBody(…) -> [String: Any]`, `static func parseAnthropic(_:) -> BrainTurn?`, `static func parseOpenAI(_:) -> BrainTurn?` |
| `MochiBrain` | `Sources/App/MochiBrain.swift` (new) | `@MainActor final class MochiBrain` · `static let shared` · `static let sessionId = "mochi-brain"` · `var isAvailable: Bool` · `func send(_ text: String)` · `func reset()` |
| `MochiMCP` | `Sources/App/MochiMCP.swift` (new) | `@MainActor enum MochiMCP` · `static func handle(rpc: [String: Any], runtime: String, owner: String) async -> [String: Any]?` (nil = notification) |
| `MochiDigest` | `Sources/App/AssistantLogic.swift` (pure) | `enum MochiDigest` · `static let threshold = 3` · `static let cooldown: TimeInterval = 60` · `static func needsDigest(sessions: [AgentSession], lastPostedAt: Date?, wasBelowThreshold: Bool, now: Date) -> Bool` · `static func note(sessions: [AgentSession], titles: [String: String]) -> MochiNote` |
| `MochiTools` | `Sources/App/AssistantLogic.swift` (pure) | `static func workerToolList() -> [[String: Any]]` · `static func brainTools() -> [BrainTool]` · `static func parseReport(_ args: [String: Any]) -> MochiNote?` · `static func claudeWorkerArguments(sessionId: String, resume: Bool, model: ModelRef?, mcpConfig: String) -> [String]` · `static func claudeMCPConfig(hookPath: String, owner: String) -> String` · `static func openCodeConfigContent(hookPath: String, owner: String) -> String` · `static let workerNote: String` · `static let brainPrompt: String` |

Everything marked "pure" is Foundation only and must compile inside `scripts/test-assistant-logic.sh` (`AgentSession.swift` + `AssistantLogic.swift` + the test).

---

## Step 0 — "Read Mochi's updates aloud" (text by default)

**Do:** add `AppState.speakMochiUpdates` (UserDefaults key `speakMochiUpdates`, default `false`). In `HookServer.processEvent`'s `Stop` case, speak `mochiLine` only when it's on. Keep the recorded-clip skip and `MochiSpeech`'s open-mic guard. Add a toggle labelled "Read Mochi's updates aloud", next to the spoken-replies toggle in the same style.

**Accept:** `scripts/build-cli.sh --typecheck` → `Typecheck OK`. Manual: with the toggle off, a Mochi-session finish shows the line silently. With it on, the line is spoken.

## Step 1 — The runtime contract, the responder, and the Claude Code runtime

**Do:**
- `AgentRuntime`, `ModelRef`, `WorkerManager` as in the contract table. `WorkerManager.start` remembers the session id in `AppState.mochiSessionIds` and records `session → runtime` (persisted in UserDefaults key `mochiWorkerRuntimes`, `[sessionId: ProjectCLI.rawValue]`, capped with the same 100 limit).
- `PendingRequestResponder` (see Architecture). Move the existing approval and question resolution onto it **without changing any card's look or keys**. `.hook(fd)` is today's behaviour, byte for byte.
- `ClaudeStreamProcess`: start `claude` with `ClaudeCodeRun.cliURL()` and its PATH fix-up. `send` writes `{"type":"user","message":{"role":"user","content":"<text>"}}` built with `JSONSerialization`. Read stdout lines → `onEvent`. Drain stderr into a 4 KB ring for error text. `interrupt()` writes `{"type":"control_request","request_id":"<uuid>","request":{"subtype":"interrupt"}}`. `stop()` closes stdin, then SIGTERM after 2 s.
- `ClaudeCodeRuntime`: one `ClaudeStreamProcess` per session. Arguments from `MochiTools.claudeWorkerArguments`: `-p --input-format stream-json --output-format stream-json --verbose`, `--session-id <id>` (or `--resume <id>`), `--append-system-prompt <MochiTools.workerNote>`, `--mcp-config <json>`, `--allowedTools mcp__coucou__report`, and `--model <id>` when a model is given. Progress, approvals, questions and the final reply keep arriving through the **existing hooks**. The runtime only reports a `result` with `is_error` through `reportRunFailure`. Hand-off = `stop`, wait for exit (max 3 s), `ClaudeCodeRun.openInTerminal`.
- `AssistantModel`: `confirmLaunch()` for `.claudeCode` → `WorkerManager.start(…, runtime: .claudeCode, …)` instead of `TerminalLauncher.run`. `launchClaudeReply` → `WorkerManager.send` first, today's `ClaudeCodeRun.resume` only when it returns false. `viewSession` on a worker → `handOffToTerminal`. App quit → `WorkerManager.shared.stopAll()`.

**Gotchas:** stdin writes happen on a private serial queue, never on the main actor. Reading is event-driven (no polling: 0 % CPU when idle). A worker whose session is in `.approval` or `.question` never receives bar text. A Mochi-owned session whose process died (app restart) is restarted with `resume: true` on the next `send`.

**Account for:** CLI missing → `ClaudeCodeRun.RunError.cliNotFound` shown with `reportRunFailure`. Two sends during one turn (stream-json queues them; allow it). Quit with workers running (no orphan processes). A deleted project folder.

**Accept:**
- New `scripts/test-stream-process.sh`: compiles `ClaudeStreamProcess.swift` + `ClaudeCodeRun.swift` + a test driving a **fake `claude`** (a Python script on a temp PATH that prints `system/init`, then one `result` per stdin line). Prints `All tests passed.` Covers init, two sends → two results, interrupt line is valid JSON, stop ends the process.
- `bash scripts/test-assistant-logic.sh` → `All tests passed.`, with cases for `claudeWorkerArguments` (new vs resume, `--model` only when given, always the stream-json trio and `--mcp-config`).
- Manual, real CLI: confirm a Claude launch card ("list the files here"). No terminal opens. The finished card appears. Reply "now count them" from the bar: same session id, and `pgrep -fl "input-format stream-json"` shows one process. Approve a tool from the notch card. "Open session" stops it and opens Terminal on the same conversation.

## Step 2 — The OpenCode runtime (any model)

**Do:**
- One `opencode serve --hostname 127.0.0.1 --port <free port>` **per project folder**, started on first use with `cwd` = the folder. Reuse `OpenCodeChat`'s start-up (password from stdout, basic auth `opencode:<password>`). Env: the user's own data (no sandbox store, like `userStore: true`), plus `OPENCODE_CONFIG_CONTENT = MochiTools.openCodeConfigContent(hookPath:owner:)`, which adds the `coucou` MCP server and an `instructions`/agent prompt carrying `MochiTools.workerNote`. Keep `OPENCODE_API_KEY` handling exactly as `OpenCodeChat.run` does.
- API (OpenCode v2, verified against `GET /openapi.json` of `opencode` 2.0.16):
  - start: `POST /api/session` `{"location":{"directory":"<path>"},"model":{"providerID":…,"id":…}}` → session id (`ses…`), then `POST /api/session/{id}/prompt` `{"text":"<prompt>"}`.
  - send: `POST /api/session/{id}/prompt` `{"text":…}`.
  - interrupt: `POST /api/session/{id}/interrupt`.
  - model switch: `POST /api/session/{id}/model` `{"model":{"providerID":…,"id":…}}`.
  - events: one `GET /api/event` SSE stream per server (`text/event-stream`, fields `id`, `event`, `data`).
  - approvals: reply `POST /api/session/{id}/permission/{requestID}/reply` `{"decision":"once"|"always"|"reject"}`.
  - questions: reply `POST /api/session/{id}/form/{formID}/reply` `{"answer":{…}}`.
- Translate SSE events into `SessionEvent`s for the store (`prompt`, `toolStart`, `toolEnd`, `approvalRequested`, `questionAsked`, `stop(reply:)`, `stopFailure`). Pending permissions and forms open the **existing** approval and question cards through `.openCode(...)` responders.
- **First task of this step:** run one real session against a scratch folder and save the raw SSE lines to `tests/fixtures/opencode-events.txt` (trim to ≤ 200 lines, remove anything personal). The translation is written and unit-tested against that fixture, not against guessed event names.
- Hand-off: stop the session's work (interrupt), then `TerminalLauncher.run("opencode --session <id>", in: path)`. When the project has no other running worker, stop its server.
- `confirmLaunch()` for `.openCode` → `WorkerManager.start(…, runtime: .openCode, …)` instead of the terminal. Bar replies to an OpenCode **worker** go through `WorkerManager.send`. Today's `OpenCodeChat.run` paths stay for non-worker sessions.
- Settings → Agents: per runtime, a **default worker model**. OpenCode: a picker filled from the existing model catalog (`OpenCodeChat.fetchModels`). Claude Code: a small fixed list of aliases (`sonnet`, `opus`, `haiku`, plus "Claude Code default"). Stored in UserDefaults (`workerModelOpenCode`, `workerModelClaude`). The existing per-project CLI choice (`projectCLIs`, `defaultCLI`) decides the runtime.

**Gotchas:** the OpenCode plugin (`OpencodePluginSource`) also runs inside these servers and sends its own hook events, including permission asks. For a session owned by an OpenCode worker, **the runtime is the only source of truth**: `HookServer` must ignore plugin events whose session id is a live OpenCode worker, so no approval is shown or answered twice. One SSE stream per server, opened once, reconnected with backoff (1, 2, 4… max 30 s) only while that server has live sessions. No stream and no server when no worker runs in that folder (0 % CPU rule). Basic-auth passwords live in memory only.

**Account for:** the `opencode` CLI is missing (show `OpenCodeChat`'s existing "not found" copy). The port is taken (pick another). The server dies (sessions marked failed, restarted on the next send). A model the user's OpenCode has no credentials for (OpenCode's error text goes to `reportRunFailure`). Several workers in one folder share one server.

**Accept:**
- `bash scripts/test-assistant-logic.sh` → `All tests passed.`, with a pure SSE-to-`SessionEvent` translator tested against `tests/fixtures/opencode-events.txt` (start → working → approval → finished), and `openCodeConfigContent` producing valid JSON with `mcp.coucou` pointing at `/bin/sh <hookPath> --mcp` and env `COUCOU_RUNTIME=opencode`, `COUCOU_OWNER=<path>`.
- Manual, real CLI, with an **OpenAI** model selected (proves "any model"): confirm an OpenCode launch ("add a hello.txt"). No terminal. The project's Mochi works, the approval card for the write appears and is answered from the notch, and the finished card appears. Switch the default model to another provider: the next launch uses it. `pgrep -fl "opencode serve"` shows one server per active folder and none after quitting.

## Step 3 — Worker `report` tool over MCP (replaces `<mochi>` tags)

**Do:**
- `nb-hook --mcp`: loop over stdin lines. Wrap each JSON-RPC message (Architecture) and send it over a new `nb.sock` connection. Requests (they have an `id`) wait for one reply line and print it. Notifications print nothing. Socket unreachable → JSON-RPC error `-32000` "Coucou is not running". Timeout 30 s for `tools/call`, 5 s otherwise.
- `HookServer`: `coucou_kind == "mcp"` → `Task { @MainActor in … MochiMCP.handle … sendLine; close }`, holding the fd like the permission path.
- `MochiMCP`: `initialize`, `notifications/initialized`, `tools/list` → `MochiTools.workerToolList()` = **`report`** only: `report({ line: string (required, ≤ 20 words), actions?: [{ label, open?, reveal?, reply?, copy? }] (≤ 3) })`. `tools/call report` → `MochiTools.parseReport` (reuse `MochiAware.action`'s validation from a dictionary) → new `SessionEvent.mochiReport(MochiNote)` on the owning session (Claude: owner = session id. OpenCode: owner = folder → busy worker in it). Reply `{"content":[{"type":"text","text":"Shown to the user."}]}`.
- `MochiTools.workerNote`: "You were started from Mochi, the user's assistant in the Mac notch. The user sees only what you send with the `report` tool. When you finish a turn, call `report` once with one short plain sentence and up to 3 one-click next steps." Remove the `<mochi>` instructions. Remove the tag extraction from `HookServer.processEvent` and its tests. The pill's `finalLine` and the card headline read the session's `MochiNote`.

**Gotchas:** `report` arrives **before** the turn ends. `.prompt` clears `session.mochi`. `.stop` with a nil note **keeps** an existing note (change the store accordingly). A turn without a report falls back to today's headline (`MochiVoice` line, else first sentence).

**Account for:** malformed `report` → result with `isError: true` and a short reason. An owner with no live worker → error result. Two reports in a turn → last wins. The OpenCode MCP server is started by OpenCode, so `COUCOU_OWNER` must come from the config env, never from the model.

**Accept:**
- `bash scripts/test-assistant-logic.sh` → `All tests passed.`: `workerToolList` (exactly `report`, `required == ["line"]`), `parseReport` (valid / missing line → nil / 4 actions → 3 / `file://` dropped), `claudeMCPConfig` (valid JSON, server `coucou`, `--mcp`, env role and owner).
- `bash scripts/test-agent-session.sh` → `All tests passed.`: `.mochiReport` sets the note and keeps the phase, `.stop(nil)` keeps it, `.prompt` clears it.
- Manual on **both** runtimes: "start a static server on port 8123 for this folder" ends with Claude's/OpenCode's one-line report and an "Open in browser" button for `http://localhost:8123`. `grep -rn "<mochi" NotchBuddy/Sources` → nothing.

## Step 4 — The brain: Mochi's own loop with its own model picker

**Do:**
- `ModelClient` impls:
  - `AnthropicModelClient`: `POST https://api.anthropic.com/v1/messages` with `tools`. Key from the Keychain item Chat already uses.
  - `OpenAICompatibleModelClient`: `POST <baseURL>/chat/completions` with `tools` (function calling). Base URL and key per provider, **taken from where Chat already reads them** (`ClaudeService.chatOpenAICompatible`): OpenAI, Google's OpenAI-compatible endpoint, Ollama and LM Studio server URLs. OpenCode Zen: the Zen key `OpenCodeChat.zenAPIKey()` already reads, against Zen's OpenAI-compatible endpoint. **Verify the Zen base URL with one real call before using it, and write it in the hand-off report.**
  - Both: 60 s timeout, no retries except one on HTTP 429/5xx after 2 s.
- Settings → **"Mochi assistant"** section (existing row style): on/off (`mochiBrainEnabled`, default on), provider picker (the six `ChatProvider`s), model field/picker (`mochiBrainProvider`, `mochiBrainModel`). Keys are never stored outside the Keychain. `isAvailable` = on + provider has a key or a reachable local server.
- `MochiBrain` loop, per user message: append it to the history, call `complete(system: MochiTools.brainPrompt, messages:, tools: MochiTools.brainTools())`, run the tool calls in order, append their results, repeat until a turn has no tool calls or **8 steps** have run. History: in memory plus `HookServer.supportDir/mochi-brain.json` (last 40 messages, no secrets), cleared by `reset()`.
- The brain appears as a session in the store: id `MochiBrain.sessionId`, kind `.other`, workspace **"Mochi"**, fed with `prompt` → `thinking`, then `stop(reply:)` when the loop ends. Its finished card shows its `report`.
- Brain tools (in-process, no MCP):
  - `list_projects()` → known projects (name, path, runtime, last used), newest first, max 40.
  - `project_status({ project? })` → each live session (or the named project's): workspace, runtime, phase, last prompt (≤ 200 chars), latest `MochiNote.line`, whether it's a Mochi worker.
  - `start_project_work({ project, task, runtime?, model? })` → `ProjectLaunchLogic.match`. Exactly one match → `WorkerManager.start` with the runtime/model given, else the project's setting, else the defaults → "Started in <name> with <runtime>/<model>". No match or several → error text listing candidates.
  - `send_to_project({ project, message })` → newest Mochi worker session there, `WorkerManager.send`. None → `start_project_work` with `message` as the task.
  - `ask_user({ question, choices[] (2–4) })` → opens the **existing question card** via a `.brain(continuation)` responder and awaits the answer (no timeout while the card is up. "Dismiss" returns "The user dismissed the question").
  - `report({ line, actions? })` → `mochiReport` on the brain session.
- `MochiTools.brainPrompt`: Mochi is the user's personal assistant in the Mac notch. It works only through its tools. It hands any work inside a project to that project (`start_project_work` / `send_to_project`), passing the user's words faithfully plus needed context, and never claims to have done project work itself. It answers general questions directly. When it needs the user, it uses `ask_user`. It ends every turn with `report`: one short sentence, optional buttons. The user sees only that.
- `AssistantModel.submitTask`: main session is a Mochi worker and finished/idle → `WorkerManager.send` (Decision 3). Else `MochiBrain.shared.isAvailable` → `MochiBrain.shared.send(text)` with the existing "sent" state, copy "Sent to Mochi". Else → today's router, unchanged.

**Gotchas:** the brain never gets file, shell or network tools beyond what's listed. Small local models are weak at tool calling: when a turn's tool call can't be parsed, end the loop with a `report` "I couldn't work that out — try saying it another way" instead of retrying blindly. Network calls go only to the provider the user picked.

**Account for:** no key / server down → `reportRunFailure("Mochi", …)` and the bar keeps the text. A tool call naming an unknown tool → error result fed back to the model (counts toward the 8 steps). The user sends again while the brain is mid-loop → queue it and run after. `ask_user` while another question card is up → the main-spot rules decide what shows, and the brain waits.

**Accept:**
- `bash scripts/test-assistant-logic.sh` → `All tests passed.`: `anthropicBody` / `openAIBody` round-trip a two-tool conversation, `parseAnthropic` / `parseOpenAI` read text + tool calls from recorded sample responses (put them in `tests/fixtures/`), `brainTools()` names exactly the six tools.
- Manual (all must hold), once with an **Anthropic** brain and once with an **OpenAI** brain:
  1. Nothing in focus: "what's the capital of Kenya" → the "Mochi" session's card answers in one line. No worker starts.
  2. "In \<project\>, add a README section about setup" → a worker starts there with the project's runtime (its Mochi appears in the strip). The brain's card says it started. No terminal, no confirm card.
  3. "Do the same in \<other project\> with OpenCode and \<an OpenAI model\>" → a second worker runs at the same time, on that runtime and model.
  4. While both run, "what's going on?" → one line covering both.
  5. An ambiguous project name → the question card asks which one. Picking one continues.
  6. With "Mochi assistant" off, bar text takes today's router path exactly as before.

## Step 4b — Pile-up digest

**Do:**
- Add `MochiAction.Kind.focus(sessionId: String)` in `AgentSession.swift`. In `AssistantModel.perform`, `.focus` selects that session as the main spot (the same path as clicking its small Mochi). It is never produced from model output: `MochiAware.action(fromJSON:)` and `MochiTools.parseReport` must not accept it.
- `MochiDigest.needsDigest`: true when the number of sessions that **need you** (`phase.needsAttention`, unseen finished included) is **≥ 3**, the count was below 3 at the previous check (`wasBelowThreshold`), and either nothing was posted yet or `cooldown` (60 s) has passed. That means one digest per pile-up, not one per new event.
- `MochiDigest.note`: one line, ordered **needs you** (approval, question, blocked; oldest `attentionAt` first) → **done** (finished, unseen) → **still working**. It names up to 4 sessions by workspace (or title when two share a workspace), then "+N more". Wording: "<name> needs you", "<name> is done", "<name> is still working", joined with commas. Actions: `.focus` buttons for the first **3 sessions that need you** (label = workspace name, ≤ 28 chars). It never names the brain's own session.
- `AssistantModel.recompute(sessions:)` (it already runs on every store change) evaluates `needsDigest`. On true, it feeds the store a `stop(reply: <line>, mochi: <note>)` for `MochiBrain.sessionId` (workspace "Mochi"), then selects that session as the main spot so the digest shows **before** the individual cards. Picking a button focuses that session's own card. "Got it" on the digest marks it seen and the normal main-spot order takes over.
- Works with the assistant **on or off**: no model call, no network.

**Gotchas:** `recompute` runs often, so `needsDigest` must be cheap (one pass over the sessions) and must never post twice for one pile-up (keep `lastPostedAt` and `wasBelowThreshold` on `AssistantModel`). Selecting the digest must not steal focus while the user is typing in the bar or the mic is open: in that case, post the digest without selecting it, and it shows when the user is done. The digest goes through `speakMochiUpdates` like any Mochi line (silent by default).

**Account for:** sessions resolving while the digest is up (`.focus` on a session that's gone or no longer needs you is a harmless no-op). The count dropping to 2 and back to 3 within the cooldown (no second digest). Two sessions with the same workspace name (use titles). Only the brain's own session needing you (it's excluded from the count).

**Accept:**
- `bash scripts/test-assistant-logic.sh` → `All tests passed.`, with cases for: below 3 → no digest; 2 → 3 → digest; still 3 on the next check → no digest; 3 → 2 → 3 inside 60 s → no digest, after 60 s → digest; order (approval older than question → approval named first; done after needs-you; working last); "+N more" past 4 names; at most 3 `.focus` actions, all for needs-you sessions; the brain's session never named; `parseReport` rejects a `focus` action.
- `bash scripts/test-agent-session.sh` → `All tests passed.`
- Manual: start three workers on tasks that each need an approval ("create a file named a.txt" etc.). When the third one asks, the notch shows Mochi's digest naming all three, with three buttons. Each button opens that project's approval card. Answer them all, then start the pile again within a minute: no second digest. Repeat with the assistant switched off: same digest.

## Step 5 — Cleanup, review, docs

**Do:** remove now-unused tag code and tests. Run `/code-review high` on the whole diff (it touches the permission path, spawns processes and sends data to model providers). Update `docs/SPEC.md` (French) with a "Mochi conducteur" section (brain, runtimes, `report`, settings). Update `docs/privacy.html`: the brain sends your messages, project names and session statuses to **the provider you picked** (or nowhere, with a local model). Workers use each agent's own login.

**Accept:** `scripts/build-cli.sh` builds `.tmp/build/Coucou.app`. Every `scripts/test-*.sh` prints `All tests passed.`

---

## Out of scope / Do NOT

- Do **not** build any chat window, transcript view or new text surface. Do not grow the island past 320 pt. Do not change the look of any existing view.
- Do **not** auto-approve anything: no `--permission-mode`, `bypassPermissions`, `--dangerously-skip-permissions`, OpenCode `"always"` replies, or permission rulesets sent on session creation. `"always"` is sent only when the user clicks the card's "always" option.
- Do **not** give the brain shell, file or extra network tools. Do not add a "run shell command" action anywhere. Do not let model output create `.focus` actions.
- Do **not** use a model call for the digest.
- Do **not** add Codex, Gemini CLI or other runtimes (the contract must allow them; the code must not include them).
- Do **not** write to `~/.claude/settings.json`, the user's OpenCode config files, or install new hooks. Per-process config only (`--mcp-config`, `OPENCODE_CONFIG_CONTENT`).
- Do **not** store keys or server passwords anywhere but the Keychain (keys) and memory (passwords).
- Do **not** speak anything new unless "Read Mochi's updates aloud" is on.
- Do **not** add third-party dependencies, a TCP listener of Coucou's own, or polling timers.
- Do **not** touch the App Store build or `windows/`.

## Definition of Done

- [ ] Steps 0–5 (including 4b) accepted, each committed on its own (one logical change per commit).
- [ ] `scripts/build-cli.sh` builds. Every `scripts/test-*.sh` passes, including `test-stream-process.sh` and the fixture-based tests.
- [ ] Every manual check above was run on the real CLIs and providers, and the results (including the verified Zen base URL) are written in the hand-off report.
- [ ] Three sessions needing the user at once produced exactly one digest card, with working buttons, with the assistant on and off.
- [ ] Two projects ran at the same time on **different runtimes and different vendors' models**, and each was driven to a finished card from the notch alone.
- [ ] With "Mochi assistant" off and no Mochi workers, the app behaves exactly as before (bar, launch card, terminal launches, replies, approvals).
- [ ] Quitting Coucou leaves no `claude -p --input-format stream-json` and no Mochi-started `opencode serve` running.
- [ ] Hidden island, idle workers: Coucou at 0 % CPU in Activity Monitor.
- [ ] Every item in "Out of scope / Do NOT" is still true. The hand-off report lists any deviation, with the reason.
