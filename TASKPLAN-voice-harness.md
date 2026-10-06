# TASKPLAN — Voice-first harness (replace the island)

**Repo:** `/Users/kepla/Desktop/code/coucou`
**Base:** branch off `main` (the App Store build).
**Manager decisions (locked):** macOS SwiftUI only — `windows/` (Tauri) is OUT. "Replacing the island" means the island's **default/home surface** becomes the voice harness; Settings, Upload, Greeting and every other view stay exactly as they ship.

This is an implementation spec. It pins what the implementer cannot recover from the code; it leaves local naming and line-by-line shapes open. If a better path exists from inside the repo, prefer it and surface the deviation in your report.

---

## 0. Read before writing any code

- `NotchBuddy/CLAUDE.md` — the rules that bind every step below.
- **Visual truth:** `design/prototype/harness-main-voice.html`. Open it and drive the ▶ Demo tour. The Mochi states, composer, suggestion, approval riser, done summary, roster, Main-lurk and motion are all specified there.
- `docs/SPEC.md` and `docs/INTEGRATIONS.md` (behaviour, views, integrations — French).
- The **Out of scope / Do NOT** block at the end of this file.

---

## Architecture — one chosen approach

The notch window, panel, shape, mode machinery and the Mochi renderer already exist. **Keep all of them.** Replace only the island's default content.

- **New surface:** `HarnessVoiceView` replaces `OverviewView` as the `.home` body dispatched from `IslandViewContent.swift:5`.
- **Reused verbatim (do not re-implement):** `IslandWindowController` (panel, `islandSize(mode:view:)` `:1143`, `setMode/expand/collapse`), `IslandShape` (`IslandRootView.swift:179`), `IslandHeader` (`:465`), `BotCanvasView` (`:5`) for the big Mochi, `MiniBotCanvasView` (`:187`) for workspace Mochis, `TickerView` (`IslandViewContent.swift:3434`) for the tool trail, `ApprovalView` (`:296`) for the approval strip, `BotState` (`IslandTypes.swift:19`) + `BotEngine` (`:171`), `AgentTask` (`IslandTypes.swift:49`) as the per-workspace session record, `PillCatalog` (`:48`) for pill identity.
- **New presentation state:** `VoiceHarnessModel: ObservableObject` (`@MainActor`) owns *presentation* only — focused workspace id, composer text, active suggestion, done-summary visibility, roster order. It **reads** `AgentTask`/`HookServer`; it does not duplicate them.
- **Routing:** `WorkspaceRouter` maps an utterance → workspace id behind a `WorkspaceRouting` protocol (jev is not in Swift today; ship a deterministic `KeywordRouter` first, add a `JevRouter` shell-out later). Pure logic, tested.
- **Motion is a contract.** Reproduce the prototype's timings exactly. Map them once in `HarnessMotion.swift` and use those constants everywhere:

| Token | Value (from the prototype) | Where |
|---|---|---|
| `spring` | `cubic-bezier(.32,1.22,.42,1)` | every UI swap |
| `agentSwap` | blur(8px)+scale(.97) out → blur-in; thread swap-out right, swap-in cascades left with stagger | focus change |
| `mochiHop` | `scale(1.25,.72)` → `scale(.88,1.15)` → settle, + ring spinner in workspace color | focus change |
| `pillFlight` | tapped `.pd` dot clones → `translate(dx,dy)` into Mochi, 950 ms, then 14-dot radial burst | handoff |
| `wash` | radial tint of the left card per workspace color (`--wash`) | focus change |
| `states` | listening breathe 1.6 s · speaking chomp .5 s · working tilt-bounce 1.2 s; shimmer text sweep | bot states |

Map these onto the existing engines: `IslandRootView.swift:32 openSpring` / `:33 closeEase`, the per-view spring at `:442`, and the bespoke tween engine in `BotEngine.swift` (`Ease` `:7`, `Tween` `:22`, `anim` `:1511`, `squash` `:338`, `gulp` `:354`, `greet` `:523`).

---

## Steps

Each step builds and is independently committable. New files live in `NotchBuddy/Sources/App/` (XcodeGen globs the folder — **re-run `xcodegen` after adding files**).

### Step 1 — Surface skeleton behind a flag
Add `HarnessMotion.swift` (constants above) and `HarnessVoiceView.swift` (renders `IslandHeader` + a placeholder body). Route the `.home` case to it only when `AppState.useVoiceHarness == true` (default **false**).
- **Account for:** XcodeGen must be re-run; keep bundle id `fr.louisraille.NotchBuddy`; with the flag off the island must be byte-for-byte the shipping look.
- **Acceptance:** `cd NotchBuddy && xcodegen && xcodebuild -project NotchBuddy.xcodeproj -scheme NotchBuddy -configuration Debug build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO` → builds. Manual: flag off = unchanged island; flag on = labelled empty surface.

### Step 2 — Per-workspace model + routing (pure logic, tested)
Add `VoiceHarnessModel.swift`, `WorkspaceRouting.swift` (protocol + `KeywordRouter`). Roster derives from `PillCatalog.all` joined to `AgentTask` by pill id; folder comes from `AgentTask.sessionCwd` (`IslandTypes.swift:61`).
- **Pin:** `protocol WorkspaceRouting { func route(_ utterance: String, candidates: [WorkspaceRef]) -> RouteResult }`; `struct RouteResult { let workspaceId: String; let confidence: Double }`.
- **Add the repo's test pattern:** `tests/WorkspaceRoutingTests.swift` + `scripts/test-workspace-routing.sh` (compile the two sources with `swiftc` and run, exactly like `scripts/test-diff-engine.sh`); wire it into `.github/workflows/build.yml`.
- **Account for:** empty candidate list, ties, unknown folder, case/diacritics in French tool names.
- **Acceptance:** `bash scripts/test-workspace-routing.sh` → exit 0. Build passes.

### Step 3 — Static composition (cards + roster)
`HarnessVoiceView` lays out the left card (big Mochi · agent line · tool trail) and the right card (2×2 mini-Mochi workspace pills), matching the prototype's proportions.
- **Reuse:** `BotCanvasView`, `MiniBotCanvasView` (fill body with workspace color), `TickerView`, `CardBackground` (`IslandViewContent.swift:4317`) for the wash.
- **Account for:** island height must equal `islandSize(.expanded, .home)` — do not introduce a new size; right card stretches to the left card's height.
- **Acceptance:** build; visual check against the prototype at 720×320.

### Step 4 — The voice bar / composer
Add `VoiceBarView.swift`: caption (`agent · voice`), a multiline textarea starting top-left that grows upward to a **3-line cap** then scrolls internally, a greyed **suggestion** placeholder, **Tab or →** to accept it, push-to-talk mic + waveform. Suggestion logic lives in `VoiceHarnessModel` (`suggestion: String?`, `acceptSuggestion()`).
- **Pin:** while a riser (approval/plan) is shown, the caption hides so the strip fits without resizing the card (this is the fix for the clipping bug in the prototype's history).
- **Account for:** Enter sends / Shift+Enter newline; blur with empty text collapses; IME composition; empty submit is a no-op.
- **Acceptance:** extend Step 2's test script with `acceptSuggestion` cases; build; manual: grow-up, cap at 3 lines, Tab accepts, typing keeps the field empty.

### Step 5 — Route + run
On submit (typed or push-to-talk), `WorkspaceRouter.route` picks the workspace, `VoiceHarnessModel` focuses it, then `OpenCodeChat.run(prompt:model:cwd:)` runs it.
- **Blast radius — shared symbol:** `OpenCodeChat.run` (`OpenCodeChat.swift:207`) gains `cwd: URL?` and sets `proc.currentDirectoryURL` (today it hardcodes the home dir at `:224`). Enumerate and update **every** caller first: `OpenCodeChat.chat` (`:410`) and the `.opencode` route in `ClaudeService.swift:272`.
- **Account for:** folder missing / not a git repo; classifier confidence below threshold → ask instead of guessing; a run already in flight.
- **Acceptance:** build; manual: a run in a scratch folder writes only inside that folder's cwd.

### Step 6 — Inline approval
Place `ApprovalView` in-flow just above the composer; wire decisions to the existing `sendApprovalDecision(_:)` (`HookServer.swift:737`). Do not add a second decision path.
- **Account for:** approval arriving while the composer is expanded (the 296 px card constraint — the caption-hide rule from Step 4); a second approval queued; decision after the socket closed.
- **Acceptance:** build; manual: strip renders fully with no clipping; ✓/✗ sends the decision (exercise the existing hook test script).

### Step 7 — Done summary · clock/history · plus · Main-lurk
Add `SessionSummaryView.swift`, `ThreadHistoryPopup.swift`, `ThreadStore.swift` (in-memory, per workspace — there is **no** thread/checkpoint type in Swift today). The clock opens the popup; plus starts a new session (guard: only on a workspace, never on Main); the Main chip returns to the last workspace.
- **Account for:** empty history; new-session while Main is focused; rewind breadth — pin it to "restore the workspace's most recent thread snapshot"; deep checkpoint/restore is OUT.
- **Acceptance:** build; manual: clock lists threads, plus adds one, Main chip returns.

### Step 8 — Stop / interrupt · cost-ctx meter · model chip
Add a stop control that SIGTERMs the running `OpenCodeChat` child (add a process handle to `run`), a cost/context meter fed from the run stream, and a model chip reading `AppState` (`:91`).
- **Account for:** stop with nothing running; child already exited via the 120 s watchdog (`OpenCodeChat.swift:236`); meter at zero / unknown model.
- **Acceptance:** build; manual: stop leaves no child (`pgrep` empty); meter updates during a run.

### Step 9 — Flip the default and clean up
Make `HarnessVoiceView` the `.home` body, delete `OverviewView`, update `CompactMiniGrid`/`IslandHeader` to match the prototype (clock + plus on the agent card, not the top bar), update `docs/SPEC.md`, add the CHANGELOG row.
- **Acceptance — mirror CI locally (this is the gate):**
  1. `cd NotchBuddy && xcodegen`
  2. `bash scripts/test-workspace-routing.sh` (and every `scripts/test-*.sh` you touched)
  3. `xcodebuild -project NotchBuddy/NotchBuddy.xcodeproj -scheme NotchBuddy -configuration Release build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO`
  All three green.

---

## Out of scope / Do NOT

- **Do NOT** touch `windows/` (Tauri) — macOS only this round.
- **Do NOT** change the window geometry: `islandSize(mode:view:)`, `IslandShape`, the panel, or `IslandStateMachine` transitions.
- **Do NOT** rename or edit pill IDs in `PillCatalog.swift` — they are a stable contract (Keychain, UserDefaults, hook routing).
- **Do NOT** restyle Settings, Upload, Greeting, chat or integration cards.
- **Do NOT** add a third-party dependency (no STT SDK, no Rive/Lottie). The character stays drawn in code.
- **Do NOT** store secrets outside the Keychain.
- **Do NOT** implement real speech-to-text or wake word here: the mic is a push-to-talk toggle that feeds the existing text path. Leave a `TODO(STT)` at the boundary, and do not fake a transcript.
- **Do NOT** persist threads/checkpoints to disk yet (`ThreadStore` is in-memory).
- **Do NOT** hand-edit `.xcodeproj` — XcodeGen only.

---

## Gaps to flag to the manager (new build, not assumptions)

These do not exist in Swift today and this plan builds them fresh; call them out rather than assuming:
- **jev routing** — prototype-only (`harness-main-voice.html:317`); shipped routing is pill-id based (`HookServer.swift:336`).
- **Per-folder OpenCode run** — `OpenCodeChat.run` runs in the home dir and parses at process exit (`:137`); no live streaming, no `--cwd`.
- **Thread store / rewind** — no thread or checkpoint type exists.
- **Stop / interrupt UI** — only the 120 s watchdog exists.
- **Cost/context meter, MCP config, wake word, background multi-run** — prototype-only.

---

## Definition of Done

- [ ] CI sequence from Step 9 runs green locally.
- [ ] Island default = harness; with `useVoiceHarness == false` the shipping look is unchanged.
- [ ] Every prototype interaction reproduced: Mochi states, composer + suggestion, Tab/→ accept, 3-line cap, inline approval, done summary, clock/plus, Main-lurk, stop, meter.
- [ ] Motion tokens used from `HarnessMotion.swift` only — no ad-hoc springs.
- [ ] New pure logic covered by `scripts/test-*.sh` wired into CI.
- [ ] Nothing in the **Out of scope / Do NOT** block was violated.
- [ ] After merge: `/review <base-commit>` and `/code-review high` run on the diff (the plan is the rubric).
