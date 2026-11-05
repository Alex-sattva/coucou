# TASKPLAN — Intent router (Claude now, Jev later)

## Goal

Replace the hand-written phrase rules that decide what Mochi does with what the user says or types
("work on X", "In Bapoojee where is…", a reply to a session) with one decision step: a **router**.
The router gets the utterance plus the current state and returns **one action from a fixed list**.
Coucou's own code carries the action out. The router's brain is swappable: **Rules** (today's
logic, offline) and **Claude** (Messages API) now; **Jev** later as a third backend with no changes
outside its own file.

## Architecture (fixed — no alternatives)

```
bar Enter / voice end
   └─ AssistantModel.submitTask(text)
        └─ RouterInput (utterance + sessions + projects + mainId)          [pure, AssistantLogic.swift]
             └─ IntentRouter backend (Settings: Rules | Claude)
                  ├─ ClaudeRouter  — HTTP, 4 s timeout, any failure → RuleRouter
                  └─ RuleRouter    — today's ProjectLaunchLogic / AssistantBarLogic rules
             └─ RouterDecision.validated(against: input)                   [pure]
        └─ AssistantModel.execute(decision)
             reply   → sendToSession (unchanged path)
             start   → proposeLaunch → existing confirm card (click required)
             open    → viewSession (opens terminal, no confirm: nothing is sent)
             clarify → new AssistantClarifyCard (each choice = a concrete decision)
             none    → bar error "I'm not sure what to do with that"
```

### Types (pure, `NotchBuddy/Sources/App/AssistantLogic.swift`, section `// MARK: - Intent router`)

```swift
struct RouterSession: Equatable, Sendable { let id, agent, workspace, cwd, phase: String; let title: String?; let lastPrompt: String? }
struct RouterProject: Equatable, Sendable { let name, path: String; let lastCLI: ProjectCLI? }
struct RouterInput: Equatable, Sendable { let utterance: String; let sessions: [RouterSession]; let projects: [RouterProject]; let mainSessionId: String? }

enum RouterAction: Equatable, Sendable {
    case reply(sessionId: String, text: String)
    case start(projectPath: String, cli: ProjectCLI?, prompt: String?)
    case open(sessionId: String)
    case clarify(question: String, choices: [RouterChoice])   // 2–4 choices
    case none
}
struct RouterChoice: Equatable, Sendable { let label: String; let action: RouterAction }  // action is never .clarify
struct RouterDecision: Equatable, Sendable { let action: RouterAction; let source: String }  // "rules" | "claude"

extension RouterDecision {
    /// Drops anything that doesn't point at a real session/project in `input`; a clarify with < 2 valid
    /// choices becomes its single choice or .none. Unknown ids never reach execution.
    func validated(against input: RouterInput) -> RouterDecision
}
```

`RouterAction` is recursive through `RouterChoice` only one level deep; enforce in `validated`.

### Backends

- `protocol IntentRouter: Sendable { func route(_ input: RouterInput) async throws -> RouterDecision }`
  in a new file `NotchBuddy/Sources/App/IntentRouter.swift`, together with `RuleRouter` and `ClaudeRouter`.
- `RuleRouter` is a **pure** `static func decide(_ input: RouterInput) -> RouterDecision` in
  `AssistantLogic.swift` (tested), wrapped by a trivial `IntentRouter` conformance. It reproduces
  today's behaviour exactly: trigger phrase at the start → start; project named in a bare utterance →
  start with prompt; otherwise reply to the main session; no main session and no project → none.
- `ClaudeRouter` posts to `https://api.anthropic.com/v1/messages` with `URLSession`, headers
  `x-api-key` (Keychain `anthropic-api-key`, the key ClaudeService already uses) and
  `anthropic-version: 2023-06-01`.
  - Model `claude-opus-5-5`, `output_config: {effort: "low", format: {type: "json_schema", schema: …}}`,
    `max_tokens: 1024`, no `thinking` field (thinking can't be disabled on this model; effort is the lever),
    no `tool_choice` (forced tool choice is a 400 on this model — structured output replaces it).
  - Model id is one constant `ClaudeRouter.model`; changing it is the only edit needed to try another model.
  - **Schema is fixed** (no per-request enums of ids/paths — a schema change costs a compile each time).
    Shape: `{ "action": "reply"|"start"|"open"|"clarify"|"none", "session_id": string|null,
    "project_path": string|null, "cli": "claude"|"opencode"|null, "text": string|null,
    "question": string|null, "choices": [ {label, action, session_id, project_path, cli, text} ] }`,
    every object `additionalProperties: false`, all keys `required` (nullable instead of optional).
  - System prompt (stable, first): what Coucou is, the five actions and when to use each, "prefer
    clarify over guessing when two projects or two sessions fit", "the text sent to a session or as a
    first prompt is the user's own words — don't rewrite them", "ids and paths must be copied exactly
    from the lists". State as a JSON user message after it.
  - Check `stop_reason` before parsing: `refusal` or `max_tokens` → throw.
  - A pure `ClaudeRouterParsing.decision(fromJSON: Data) throws -> RouterAction` in `AssistantLogic.swift`
    (tested with fixture strings); the HTTP part stays in `IntentRouter.swift`.
- Fallback: no key, Settings = Rules, timeout (4 s), network error, HTTP ≠ 200, parse error → `RuleRouter`.
  Log one line to `nb.log` on fallback (`"router: claude failed (<reason>), used rules"`), never the utterance.

### What is sent to Claude (privacy)

Only: the utterance; per running session `id, agent kind, workspace name, cwd, phase, title,
last prompt ≤ 200 chars`; up to 40 known projects `name, path, last CLI`; main session id.
No transcripts, no replies, no file contents.

## Steps

### Step 1 — Pure types, RuleRouter, validation
Files: `AssistantLogic.swift`, `tests/AssistantLogicTests.swift`.
- Add the types above, `RuleRouter.decide`, `RouterDecision.validated`.
- Account for: utterance that is only filler; a project named but also a session running (rules: reply unless the
  utterance starts with a trigger — keep the existing mid-sentence guard); unknown session id in a clarify choice;
  nested clarify; empty choices.
- Acceptance: `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk bash scripts/test-assistant-logic.sh`
  → `All tests passed.` with new cases covering every `RouterAction` case and every `validated` rule.

### Step 2 — Claude response parsing (pure)
Files: `AssistantLogic.swift`, tests.
- `ClaudeRouterParsing.decision(fromJSON:)` maps the schema JSON to `RouterAction`; also builds the request
  JSON body (`requestBody(input:) -> Data`) so the body is testable without network.
- Account for: nulls where a field is required for that action (→ throw), `cli` unknown string (→ nil),
  choices with action `clarify` (→ dropped), non-ASCII text, escaped slashes in paths.
- Acceptance: test script passes; tests include a fixture for each action and three malformed fixtures that throw.

### Step 3 — Backends + model wiring
Files: new `IntentRouter.swift`, `AssistantModel.swift`.
- `ClaudeRouter` (HTTP as specified), `RuleRouter` conformance, `RouterInput` builder in the model
  (`makeRouterInput(text:)`).
- `submitTask(text)` becomes: build input → pick backend from settings → `route` with fallback →
  `validated` → `execute`. Delete the inline rule code now living in `RuleRouter.decide`.
- `execute(.reply)` calls the existing `sendToSession` with the decision's session made the target
  (today only the main session can be replied to — keep that: a reply to a non-main session is converted
  to `select(sessionId)` + send).
- Gotcha: `AssistantModel` is `@MainActor`; the HTTP call runs in a `Task`, results hop back to main.
- Gotcha: never approve permissions or answer question cards from the router (CLAUDE.md rule).
- Acceptance: build compiles (swiftc command in memory/CLAUDE.md); with Settings = Rules, the manual checks
  of Step 5 behave exactly as before this plan.

### Step 4 — Clarify card
Files: `AssistantLogic.swift` (`AssistantPanelContent.clarify(choices: Int)`, `AssistantMetrics`),
`AssistantModel.swift` (`pendingClarify`), `AssistantPanelView.swift`, `AssistantPanelCards.swift` (`AssistantClarifyCard`).
- Card: the question (wraps, never truncated), 2–4 choice rows styled like the question card's option rows
  (label only, wraps), number keys 1–4 pick, Esc dismisses. Picking executes that choice's action
  (start still goes through the confirm card).
- Height: `clarifyBase + choices × questionRow`, capped at `maxHeight`; content scrolls if it overflows.
- Footer hidden on this card (same rule as the question card).
- Acceptance: tests pass incl. a height test; manual check 3 below.

### Step 5 — Settings + privacy
Files: `AppState.swift` (`routerBackend: String`, `"rules"` default, persisted like `defaultCLI`),
`SettingsView.swift` (General → "Understanding" GroupBox: picker Rules / Claude; Claude disabled with
caption "Add an Anthropic key in Chat" when no key), `docs/privacy.html` (one paragraph: with Claude
selected, what is sent — the list above — and to whom).
- Acceptance: build compiles; Settings shows the picker; privacy page renders the paragraph.

## Manual verification (after Step 5, Settings = Claude, key set)

1. No session running: say "In Bapoojee where is the document to send to the CEO" → confirm card for
   Bapoojee-production with the sentence as first message.
2. A coucou session running: type "start the tests" → sent to the coucou session as a reply (not a launch).
3. Say "work on the dashboard" with two matching projects → clarify card listing both; pick one → confirm card.
4. Turn Wi-Fi off → same as Rules, one fallback line in `~/Library/Logs/…/nb.log` (wherever `appendAppLog` writes).
5. Settings = Rules → behaviour identical to before this plan.

## Out of scope / Do NOT

- No overseer behaviour: the router never acts on its own, only on an utterance.
- Never approve a permission, answer a question card, or send an email from a router decision.
- No Jev code (only keep `IntentRouter` free of Claude-specific types so Jev slots in).
- No per-request JSON schema enums; no streaming; no conversation memory between utterances.
- Don't restyle existing cards; the clarify card reuses the question card's row style.
- Don't touch the wake-word or ⌥ voice code beyond what `submitTask` already receives.
- No telemetry; the utterance is never logged.

## Definition of Done

- [ ] All five steps' acceptance checks pass; test script prints `All tests passed.`
- [ ] App builds with the swiftc recipe and runs from /Applications.
- [ ] Manual checks 1–5 behave as written.
- [ ] Settings = Rules reproduces pre-plan behaviour (no regressions in launch / reply / no-folder flows).
- [ ] Nothing in the Do-NOT block was done.
- [ ] Privacy page updated.
