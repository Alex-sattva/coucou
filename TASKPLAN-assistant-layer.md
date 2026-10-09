# TASKPLAN — Assistant layer: main Mochi + subagent crew

**Repo:** `/Users/kepla/Desktop/code/coucou` · **Branch:** `feature/voice-harness` · **Platform:** macOS app only (`NotchBuddy/`). `windows/` (Tauri) is out.
**Supersedes:** `TASKPLAN-voice-harness.md` (the two-card harness). That UI is being replaced; its non-UI pieces are partly reused (listed below).

This is an implementation spec. It pins what you cannot recover from the code. It leaves local naming, line-by-line shapes and ordering inside a step to you. If you find a better path from inside the repo, take it and **report the deviation**.

---

## 0. Read before writing any code

- `CLAUDE.md` (repo root) — every rule there binds this plan. The ones that bite most: Swift 6, no third-party deps, Mochi drawn in code, secrets in Keychain, **never block Claude Code**, **never approve without an explicit click**, **0 % CPU when the island is hidden**, bundle id `fr.louisraille.NotchBuddy` unchanged, pill IDs never renamed.
- **Visual + motion truth:** `design/prototype/assistant-multi-agent-prototype.html` → variant **E**, motion **1 · Particle hand-off** (open the file, use ← → to reach E; it opens on it by default). Press "▶ Start 3 agents", click the three desktop windows, click the small Mochis.
- **Panel states for one agent:** `design/prototype/assistant-layer-prototype.html` → variant **D · Quiet Spotlight** ("▶ Play demo" and "▶ Blocked demo").
- `docs/SPEC.md` (French) for the island's existing behaviour.

## Product decisions (locked with the owner — do not reopen)

1. **Placement:** the new design **replaces the closed (compact) island and the expanded home**. The compact mini-grid becomes the strip of small Mochis; the expanded `.overview` becomes the new panel. The panel also takes over `.approval`, `.question`, `.error`, `.finished`. Every other view ships unchanged: `.settings`, `.upload`, `.uploading`, `.choose`, `.mail`, `.prompt` (chat), `.searching`, `.result`, `.note`, `.greeting`, `.wardrobe`, `.confused`, `.empty`.
2. **One Mochi per agent session**, keyed by the hook payload's `session_id` — including Claude Code in a plain terminal (today ignored). Several approvals may wait at once.
3. **The main spot** goes, in this order, to: the agent the user clicked (until the panel closes) → the oldest agent that **needs you** (approval / question / blocked; then finished-and-unseen) → the agent of **the workspace the user is working in** (front window) → the previous main if still alive → the most recently active session. Everyone else is a small Mochi (subagent).
4. **Quiet by default:** the panel opens on its own **only** when the main agent needs you, is blocked, or is done. While agents work, only the strip is visible. The user can also summon the panel (click the notch or the existing `openChat` shortcut ⌃⌥Space).
5. **Bar:** answers the main agent (question options) and starts **new OpenCode tasks** in the main agent's folder via the existing `OpenCodeChat.run`. Starting Claude Code from the app is out.
6. **Voice:** hold **⌥ alone** to talk, Apple on-device speech recognition; release sends.
7. **Motion = the particle hand-off** (spec in Step 8). Only the main Mochi travels (strip ↔ panel). Small Mochis never move; they recolour.
8. Interface copy is **English**, like the rest of the island.

---

## Architecture — one chosen approach

```
HookServer ──(every event with session_id)──► AgentSessionStore (pure reducer, in AppState)
                                                   │
WorkspaceContextTracker (AXObserver + matcher) ────┤
                                                   ▼
                                    AssistantLogic (pure): MainAgentPicker, AttentionQueue, SubSlotOrder
                                                   │
                                     AssistantModel (@MainActor ObservableObject, presentation only)
                                                   │
                     ┌─────────────────────────────┴──────────────────────────┐
              AssistantStrip (compact)                              AssistantPanelView (expanded)
       main Mochi left of camera + sub slots right          big Mochi, task line, need card, bar
                     └──────── AssistantMainMochi: ONE instance alive across both ────────┘
```

- **Data lives in a new session layer, beside the pill layer.** `AgentTask` (one per pill) and everything that reads it (Settings pills, integrations, `focusTask`) stay as they are. The new UI reads only `AppState.sessions`. This keeps the blast radius off `AgentTask`.
- **Pure logic is in standalone Swift files with no AppKit/SwiftUI imports**, tested with the repo's `swiftc` script pattern (`scripts/test-diff-engine.sh` is the model): `AgentSession.swift`, `AssistantLogic.swift`, `WorkspaceTitleMatcher.swift`.
- **Reuse, don't rebuild:** `BotEngine` + `HarnessMochiView` (owns an engine, `hex` colour, `hopToken`, `isPaused`, hopPose keyframes already implemented), `HarnessMotion` constants (hop, pill flight 0.95 s / 14 dots / r 26), the pill-flight technique in `HarnessVoiceView.swift` (`HarnessAnchorKey` preference + `HarnessPillFlightView`), `IslandShape`, the island's `openSpring` / `closeEase` (`IslandRootView.swift:32-33`), `FileDiff` (`DiffEngine.swift:19`), `AskQuestion` parsing/answers, `OpenCodeChat.run(prompt:model:cwd:runId:)` (`OpenCodeChat.swift:349`), `WindowContextCapture`'s AX title read, `HotKeyCenter` for ⌃⌥Space.

### Files

| New | Purpose |
|---|---|
| `AgentSession.swift` | `AgentKind`, `SessionPhase`, `AgentSession`, `SessionEvent`, `AgentSessionStore` (value-type reducer). Pure. |
| `AssistantLogic.swift` | `MainAgentPicker`, `AttentionQueue`, `SubSlotOrder`. Pure. |
| `WorkspaceTitleMatcher.swift` | Window title → workspace match. Pure. |
| `WorkspaceContextTracker.swift` | AXObserver on the front app; publishes the matched workspace with a 1 s dwell. |
| `AssistantModel.swift` | Presentation state: main id, slot order, panel open/summoned/dismissed, hand-off tokens. |
| `AssistantStrip.swift` | Compact strip: sub slots + anchors. |
| `AssistantMainMochi.swift` | The one main Mochi (wraps `HarnessMochiView`), positioned for compact or expanded. |
| `AssistantPanelView.swift` | Expanded panel: header row, need card (approval / question / blocked / done), bar. |
| `AssistantHandoff.swift` | Flight + burst overlay, colour-blend driver, wash. |
| `VoiceInput.swift` | `SFSpeechRecognizer` (on-device) + `AVAudioEngine`; `OptionHoldMonitor`. |
| `tests/AgentSessionTests.swift`, `tests/AssistantLogicTests.swift`, `tests/WorkspaceTitleMatcherTests.swift` + `scripts/test-agent-session.sh`, `scripts/test-assistant-logic.sh`, `scripts/test-title-matcher.sh` | Tests, wired into `.github/workflows/build.yml`. |

| Removed (Step 9) | |
|---|---|
| `HarnessVoiceView.swift`, `HarnessWorkspacePill.swift`, `HarnessTickerView.swift`, `HarnessRiserStrip.swift`, `VoiceBarView.swift`, `VoiceHarnessModel.swift`, `ThreadStore.swift`, `ThreadHistoryPopup.swift`, `SessionSummaryView.swift`, `WorkspaceRouting.swift`, `tests/ThreadStoreTests.swift`, `tests/WorkspaceRoutingTests.swift`, `scripts/test-thread-store.sh`, `scripts/test-workspace-routing.sh` (+ their CI steps), `TASKPLAN-voice-harness.md/.html` | The rejected two-card UI. Move `HarnessPillFlightView`, `HarnessAnchorKey` and `CardSurface`'s wash idea into `AssistantHandoff.swift` first. |

Kept as is: `HarnessMochiView.swift` (extended in Step 8), `HarnessMotion.swift` (prune groups nothing uses after Step 9), `OpenCodeChat.swift`, `OpencodePluginSource.swift`, `opencode/coucou.ts`, the `mochi_XX.wav` sounds.

### Cross-module signatures (pin exactly)

```swift
// AgentSession.swift — pure
enum AgentKind: String, Sendable { case claudeCode, openCode, codex, gemini, cursor, antigravity, other }
enum SessionPhase: String, Sendable { case thinking, working, approval, question, blocked, finished, idle }
struct AgentSession: Identifiable, Equatable, Sendable {
    let id: String                 // hook session_id
    var kind: AgentKind
    var cwd: String
    var workspace: String          // URL(fileURLWithPath: cwd).lastPathComponent
    var colorHex: String
    var phase: SessionPhase
    var steps: [String]
    var lastPrompt: String?
    var finalLine: String?
    var attentionAt: Date?         // set when phase enters approval/question/blocked/finished
    var finishedSeen: Bool
    var lastEventAt: Date
}
enum SessionEvent: Sendable {
    case start, end, prompt(String), toolStart(step: String), toolEnd, toolFailed(step: String)
    case approvalRequested, questionAsked, notification(String), stop(finalLine: String?), stopFailure
    case interrupt
}
struct AgentSessionStore: Equatable, Sendable {
    private(set) var sessions: [String: AgentSession]
    mutating func apply(_ event: SessionEvent, sessionId: String, kind: AgentKind, cwd: String,
                        colorHex: String, now: Date)
    mutating func markSeen(_ sessionId: String)
    mutating func prune(now: Date, idleFor: TimeInterval)   // removes sessions with no event for `idleFor`
}

// AssistantLogic.swift — pure
enum MainAgentPicker {
    static func pick(sessions: [AgentSession], selectedId: String?, contextWorkspace: String?,
                     previousMainId: String?) -> String?
}
enum AttentionQueue {
    /// approval/question/blocked first (oldest attentionAt first), then finished && !finishedSeen.
    static func order(_ sessions: [AgentSession]) -> [AgentSession]
}
enum SubSlotOrder {
    /// Keeps every surviving sub in its slot. When `newMain` was a sub and `oldMain` is still alive,
    /// `oldMain` takes `newMain`'s slot and that index is returned (the slot to recolour after landing).
    static func update(order: [String], alive: [String], oldMain: String?, newMain: String?)
        -> (order: [String], recolourIndex: Int?)
}

// WorkspaceTitleMatcher.swift — pure
enum WorkspaceTitleMatcher {
    /// Returns the workspace whose folder name or full cwd appears in the title
    /// (case-insensitive, whole path-component match). Longest match wins.
    static func match(title: String, workspaces: [(name: String, cwd: String)]) -> String?
}

// HookServer.swift — changed signatures (Step 4)
func sendApprovalDecision(_ decision: String, sessionId: String)
func sendQuestionAnswers(_ answers: [String: Any], sessionId: String)
```

---

## Steps

Each step builds, passes its acceptance check, and is committed on its own (one logical change per commit). **Build command used below:**
`cd NotchBuddy && xcodegen && xcodebuild -project NotchBuddy.xcodeproj -scheme NotchBuddy -configuration Debug build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO` → `** BUILD SUCCEEDED **`.
Re-run `xcodegen` after adding or removing any Swift file (XcodeGen globs the folder). Never edit the `.xcodeproj` by hand.

### Step 0 — Snapshot the branch as it is
Nothing on `feature/voice-harness` is committed yet. Commit the existing work **as it stands** before changing anything, so the removals in Step 9 stay recoverable. Split into logical commits: (a) Mochi voice sounds `mochi_*.wav` + `SoundEngine`/`BotEngine` greet change; (b) OpenCode integration (`OpenCodeChat`, `OpencodePluginSource`, `opencode/coucou.ts`, PillCatalog `agent_opencode`/`ai_opencode`, AppState OpenCode model settings, `AGENTS.md` section); (c) v1 voice harness UI (Harness*/Voice*/Thread*/Workspace*/SessionSummaryView + IslandViewContent/IslandRootView/IslandTypes/IslandWindowController changes + its tests/scripts/CI + SPEC sections + design prototypes + TASKPLAN-voice-harness); (d) anything left that is clearly separate (`.gitignore`, README, CHANGELOG, Info.plist) — inspect it, don't guess.
- **Account for:** `voice-mochi/` is out of scope — leave it untracked and untouched. If a hunk doesn't fit one group, put it in the group it serves and say so in the report.
- **Acceptance:** `git status --short` shows only `voice-mochi/` (and this plan's two files); build succeeds.

### Step 1 — Session model (pure, tested)
Add `AgentSession.swift` with the pinned types. Reducer rules: `start` creates (phase `.idle`); `prompt` → `.thinking`, stores `lastPrompt`, clears `finalLine`, `finishedSeen=false`; `toolStart` → `.working` + append step (cap 40); `toolFailed` → `.working` + step `"⚠ <step>"`; `approvalRequested` → `.approval`; `questionAsked` → `.question`; `notification(msg)`: contains "rate limit" (case-insensitive) → `.blocked`, ends with "?" → `.question`; `stop(line)` → `.finished`, `finalLine=line`, `finishedSeen=false`; `stopFailure` → `.blocked`; `interrupt` → `.idle`; `end` removes. Entering approval/question/blocked/finished sets `attentionAt=now`; leaving them clears it. An event for an unknown session id creates it first (hooks can start mid-session).
- **Test pattern:** `scripts/test-agent-session.sh` compiles `AgentSession.swift` + `tests/AgentSessionTests.swift` with `swiftc -swift-version 6 -strict-concurrency=complete` exactly like `scripts/test-diff-engine.sh`; add it to `build.yml` after the existing test steps.
- **Account for:** two sessions in the same folder stay separate; unknown session + `end` is a no-op; `prune` never removes a session in approval/question (a held hook).
- **Acceptance:** `bash scripts/test-agent-session.sh` → exit 0.

### Step 2 — Main picker, attention queue, slot order (pure, tested)
Add `AssistantLogic.swift` with the pinned signatures and decision 3's order. `pick` among the context workspace's sessions takes the one with the latest `lastEventAt`. `SubSlotOrder.update`: drop dead ids and `newMain`; if `newMain` was in `order` at index i and `oldMain` is alive and not already present → put `oldMain` at i and return i; if `oldMain` is alive but `newMain` was not a sub → append `oldMain`; append any alive id that is neither main nor present.
- **Account for:** no sessions → nil; selectedId that died → ignored; ties on `attentionAt` → older `lastEventAt` first; main dies → order closes the gap (no recolour index).
- **Acceptance:** `bash scripts/test-assistant-logic.sh` → exit 0 (cases for each rule above, including "clicked sub keeps its slot and becomes old main").

### Step 3 — Feed sessions from HookServer
In `HookServer.processEvent` (`HookServer.swift:325-535`), **before** the pill routing and its early return for unknown terminals (`~:375`), map every event that has a `session_id` to a `SessionEvent` and apply it to `AppState.sessionStore` (new `@Published var sessionStore = AgentSessionStore(...)`) on the main actor. `kind`: from `coucou_agent` (codex/opencode/gemini/antigravity), Cursor bundle id → `.cursor`, else `.claudeCode`. `colorHex`: `IslandConst.colorForProject(workspace)` — the same helper the pills use (`HookServer.swift:556`). Record diffs per session: where `buildFileDiff` (`:1009`) stores into `sessionDiffs[pillId]`, also store into a new `AppState.sessionFileDiffs[sessionId]` (same 50 cap, cleared on `end`). Prune sessions idle for 15 min on a 60 s timer that only runs while `sessions` is non-empty.
- **Blast radius:** `processEvent`'s pill behaviour must not change — VS Code / Cursor / Codex / external pills keep working exactly as today.
- **Account for:** Gemini/Antigravity events arrive already normalised to Claude names (`normalize_event`); OpenCode `session.idle` → Stop with no `last_assistant_message` → `finalLine=nil`; events without `session_id` are ignored by the session layer.
- **Acceptance:** build succeeds. Manual: run `claude` in a plain Terminal in a scratch git folder, send one prompt; with `AppLog` debug on, the log shows one session with phase thinking → working → finished. Open a VS Code Claude session at the same time → two sessions, and the VS Code pill still behaves as before.

### Step 4 — Several approvals and questions at once
Replace the single `pendingApprovalFD` / `pendingQuestionFD` with dictionaries keyed by session id, each with its own 115 s safety timeout (keep today's value and "close without a decision" behaviour). Remove the "second request displaces the first with `ask`" path (`HookServer.swift:~668`). Change the two send functions to the pinned signatures. `AppState.pendingApproval` / `pendingQuestion` become **computed, get-only**, returning the oldest pending item — the compiler will then point at every writer; fix each.
- **Blast radius — do this first:** enumerate every caller of `sendApprovalDecision`, `sendQuestionAnswers`, and every reader/writer of `pendingApproval`, `pendingQuestion`, `pendingApprovalFD`, `pendingQuestionFD`, `focusBeforeApproval` (known: `IslandViewContent.swift:78-86,281`, `VoiceHarnessModel.swift:185,194`, `IslandStateMachine` `isHeldOpen`, `IslandWindowController.swift:205`, the `goToAlert` shortcut). Also check for a twin decision path (there must be exactly one place that writes a decision to a socket).
- **Plain-terminal Claude Code:** its `PermissionRequest` and `AskUserQuestion` are now held and shown (today they are answered immediately). OpenCode/external `PermissionRequest` stays answered `ask` at once (`HookServer.swift:622-630`) — unchanged.
- **Account for:** the editor closing the fd; a matching PostToolUse/Stop clearing that session's card only; the decision arriving after the timeout (no-op, no crash); "never approve without an explicit click" — no keyboard path may approve unless the panel is open and showing that approval.
- **Acceptance:** build. Manual: two plain-Terminal Claude sessions each hit a permission prompt within a few seconds; both stay pending; allowing one leaves the other waiting; letting one sit 2 minutes falls back to the terminal prompt and the other is unaffected.

### Step 5 — What the user is working on
Add `WorkspaceTitleMatcher.swift` (pure, tested: `scripts/test-title-matcher.sh`) and `WorkspaceContextTracker.swift`. The tracker listens to `NSWorkspace.didActivateApplicationNotification` (already observed at `IslandWindowController.swift:752`) and installs an `AXObserver` on the front app for `kAXFocusedWindowChangedNotification` and `kAXTitleChangedNotification`; on each change it reads the focused window title (reuse `WindowContextCapture`'s AX read), runs the matcher over the live sessions' `(workspace, cwd)`, and publishes `contextWorkspace` only after the same value has held for **1.0 s**. No polling.
- **Account for:** Accessibility not granted, or the APPSTORE build (`WindowContextCapture` returns nil there) → `contextWorkspace = nil`, the picker falls through to previous main; the observer is removed when there are no sessions or the island is hidden (0 % CPU rule); Coucou's own windows are ignored; folder names that are substrings of others (`app` vs `app-web`) → whole path-component match, longest wins; terminals whose title is a path like `~/code/coucou` → match on the last component.
- **Acceptance:** `bash scripts/test-title-matcher.sh` → exit 0; build. Manual: two sessions in folders A and B; focusing a Ghostty tab titled with A, then a VS Code window on B, moves `contextWorkspace` A → B about 1 s after each switch.

### Step 6 — The quiet strip (replaces the compact island)
Add `AssistantModel.swift`, `AssistantStrip.swift`, `AssistantMainMochi.swift`. In compact mode, stop drawing `BotPlacement`'s compact Mochi and `CompactMiniGrid` (`IslandRootView.swift:115-123`, `:621`) and draw instead: the **main Mochi left of the camera**, the **sub slots right of the camera**. Geometry (from the prototype, in points): main resting diameter = `IslandRestingLayout`'s resting diameter × 1.25, capped at notch height − 4; centred 30 pt outside the notch's left edge. Subs: diameter ≈ 0.68 × main, spaced 26 pt, first one 22 pt outside the notch's right edge, max **5** visible then a `+N` count. Compact island width = notch width + 2 × max(56, subs × 26 + 26) — symmetric so the camera stays centred. Each sub slot is a small Mochi whose body colour is the slot's agent colour and whose state is that session's phase; a slot shows a 6–8 pt status dot (amber `#F5A524` approval/question, red `#F87171` blocked, green `#34D399` finished-unseen).
- **Island mode rules:** compact whenever ≥ 1 session exists; hidden when none (today's FSM timers stay).
- **The main Mochi is ONE view instance alive across compact and expanded** (same technique as `BotPlacement`, always in the tree). It wraps `HarnessMochiView` (colour = main session `colorHex`, state from phase). Slot Mochis need a colour that can change after init — `MiniBotCanvasView` sets `bodyColor` once (`BotCanvasView.swift:198`); use a small wrapper that updates `bodyColor` on change instead of editing `MiniBotCanvasView` (shared by shipping views).
- **Account for:** every `TimelineView` here takes `paused:` when the island is hidden (`MiniBotCanvasView`'s unpaused timeline is a known offender — do not copy it); no-notch Macs (`IslandScreenGeometry` fallback 80 pt) — same layout around the virtual notch; clicking a sub sets `selectedId` and opens the panel.
- **Acceptance:** build. Manual: start three sessions in three folders → main Mochi left, two subs right; focusing another folder's window swaps who is main within ~1 s (no animation yet); closing all sessions returns the island to hidden.

### Step 7 — The panel (replaces home + approval/question/error/finished)
Add `AssistantPanelView.swift` and route `.overview`, `.approval`, `.question`, `.error`, `.finished` to it in `IslandViewContent.swift:10-17`. Width = `IslandConst.expandedWidth` (640); corner = `IslandConst.expandedCorner`; height chosen per content (pin in an `AssistantMetrics` enum; prototype values: summoned bar 112, approval 236, blocked 262, done 248, question = options rows + 120) and animated with the island's existing open/close curves (same mechanism as `chatPromptHeight`).
Layout (prototype D/E): top row = **main Mochi 48 pt, centred at (40, 64)** · task line (`lastPrompt`, one line, ellipsis) · agent chip (`kind` name + colour dot) · mic button. Under a hairline: the **need card**:
  - **approval:** "N steps done" line, then an amber row "Can I run `<command>`?" with **Deny** and **Allow ⏎** (decision via `sendApprovalDecision(_, sessionId:)`). Keep an "Always" option only if today's `ApprovalView` offers it (`IslandViewContent.swift:86`).
  - **question:** the `AskQuestion` options as buttons + free text if the question allows it; answers via `sendQuestionAnswers(_, sessionId:)`.
  - **blocked:** red line "I hit an error I can't get past on my own." + last failed step / error text in mono + **Open in terminal** (activate the session's app; reuse `jumpToTerminal` logic). Claude Code cannot be resumed from here, so there is no "Try again" button.
  - **finished:** `finalLine` (or "Done." if nil) + changed files from `sessionFileDiffs` as `name +A −R` and **Open diff** (reuse today's diff detail if one exists; otherwise just the list) + **Got it**.
  - **Summoned with nothing pending:** only the bar row.
Footer: key hints (`⏎ allow` / `esc hide` / `/ talk to <workspace>`).
**Open rules (AssistantModel):** open = summoned ∨ selectedId ≠ nil ∨ (queue non-empty ∧ queue signature ≠ dismissed signature). Esc → dismiss (store signature, clear summon/selection). A new need changes the signature and reopens. Finished cards fold away after **8 s** on screen unless hovered or the bar has focus, then `markSeen`. Hover no longer expands the island; click on the notch (or ⌃⌥Space via the existing `openChat` shortcut) summons. Approvals and questions keep the island held open exactly as `fsm.isHeldOpen` does today.
- **Account for:** two needs at once → queue order, the next one slides in after answering; an approval timing out removes its card; ⏎ only acts while the panel is open and showing that approval (never approve blind); the panel never covers more than one card.
- **Acceptance:** build. Manual with two plain-Terminal sessions: (1) permission prompt in A → panel opens on A with Allow/Deny, Allow continues A; (2) B finishes while A waits → B's done card appears only after A is answered; (3) Esc hides; a new need reopens; (4) done card folds after 8 s.

### Step 8 — Motion: the particle hand-off
Add `AssistantHandoff.swift`; move `HarnessPillFlightView` + `HarnessAnchorKey` there (from `HarnessVoiceView.swift`) and generalise the anchors to strip slots + main Mochi. All values from `HarnessMotion` / the prototype — do not invent curves.
When `mainId` changes from X to Y:
  1. If Y was a sub: a dot leaves **Y's slot** and flies to the main Mochi's **current position**: 0.95 s total, 62 % travel with cubic ease-out, diameter 9 → 4 pt, halo `color.opacity(0.25 × (1 − e))`; then 14 dots burst to radius 26 and fade.
  2. **At flight start** (not landing): the main Mochi's body colour starts blending X → Y over the travel (~0.6 s; per-frame lerp ≈ 0.045 at 60 fps) — add a blended `bodyColor` to `HarnessMochiView` (today it switches instantly on `hex` change); the panel wash switches colour (0.6 s ease); the task line and need card blur-swap (opacity 0 + blur 8 + scale 0.97 → 1 over 0.32 s, `HarnessMotion` agent-swap values).
  3. **At landing:** the main Mochi hops in place (`hopToken` → `HarnessMotion.hopPose`, 0.9 s).
  4. **After landing:** Y's slot — which never moved or disappeared — recolours to X (normal 0.12 lerp) and takes X's state and dot. This is `SubSlotOrder.update`'s `recolourIndex`.
  If Y was not a sub (first main, or context switch to a session that was never shown): no flight; colour set, hop.
**Wash:** radial gradient behind the panel, centred on the main Mochi (40, 64), radius ≈ 70 % of the panel width horizontally / 120 % of its height vertically, `colorHex` at opacity **0.34** fading to clear at 70 %; only while expanded.
**Strip ↔ panel:** the main Mochi is the only thing that travels between compact and expanded: position and size with `timingCurve(0.25, 0.8, 0.25, 1, duration: 0.35)`. Subs stay in the strip (same row, right of the camera) when the panel is open; they fade (0.2 s) when the slot list changes, never slide. The island shape keeps `openSpring` / `closeEase`.
New sessions: a new slot fades in where it belongs; a removed session's slot fades out and the slots after it close the gap (0.2 s fade, no slide).
- **Account for:** a second hand-off starting mid-flight (cancel the first flight's remaining burst, retarget colour from the current blended value, keep the slot recolour of the first); hand-off while hidden → skip the flight, apply the end state; the flight overlay is unmounted when idle (no 60 Hz timeline left running).
- **Acceptance:** build. Manual: three sessions; click a sub → dot flies, main colour blends during flight, hop on landing, the clicked slot turns into the previous main's colour after landing, nothing else moves; Accessibility-driven context switch plays the same hand-off; a permission prompt in a sub elevates it with the same hand-off and opens the panel.

### Step 9 — Remove the v1 harness
Delete the files in the "Removed" table, their CI steps in `.github/workflows/build.yml`, and `TASKPLAN-voice-harness.md/.html`. Remove now-unused `HarnessMotion` groups (ticker, riser, thread swap, voice bar). Remove `IslandView.isHarnessSurface` if nothing reads it; otherwise rename its meaning to "assistant panel surface" without renaming pill IDs. Update `docs/SPEC.md` (French): replace the `Voice harness`, `Barre vocale`, `Riser`, `Routage et exécution`, `Threads` sections with one section describing the strip, the panel, the main-spot rule, the hand-off and the bar; update §2 "Modes de l'island" for the new compact.
- **Account for:** grep for every symbol from the deleted files before deleting (`VoiceHarnessModel`, `ThreadStore`, `KeywordRouter`, `WorkspaceRef`, `SessionSummaryView`, `HarnessWorkspacePill`, `VoiceBarView`…) — the build must not depend on them.
- **Acceptance:** build; every remaining `scripts/test-*.sh` listed in CI → exit 0; `grep -rn "VoiceHarnessModel\|ThreadStore\|KeywordRouter" NotchBuddy/Sources tests scripts .github` → no matches.

### Step 10 — The bar: OpenCode tasks
In the panel's bar row (shown when summoned, or when the main need is finished/none): placeholder `New OpenCode task in <workspace>…`. Enter → `OpenCodeChat.run(prompt:model:cwd:)` with `state.opencodeChatModel` and the main session's `cwd`; fire-and-forget (the OpenCode plugin's hooks create the new session, which then appears as a Mochi). Close the panel on send.
- **Account for:** no main session → use `contextWorkspace`'s folder if a session had it, else disable the bar with "Open a project window first"; OpenCode CLI missing (reuse `OpenCodeChat`'s CLI lookup) → inline one-line error, nothing launched; empty text → no-op; the run's 120 s timeout and `OpenCodeRunRegistry` stay as they are; when the main has a pending question, the bar is replaced by the question card (no OpenCode task while a question waits).
- **Acceptance:** build. Manual: summon in a folder with a session, type a task → an `opencode` process runs with that cwd (check `ps -o command= -p <pid>` and `lsof -p <pid> | grep cwd`) and a new Mochi appears.

### Step 11 — Voice: hold ⌥ to talk
Add `VoiceInput.swift`: `SFSpeechRecognizer` with `requiresOnDeviceRecognition = true` (system locale), `AVAudioEngine` tap, partial results streamed into the bar. `OptionHoldMonitor`: global + local `NSEvent` monitors for `.flagsChanged` and `.keyDown`; listening starts when **⌥ alone** has been held **300 ms** with no other key; any other key or modifier during the hold cancels (so ⌥-shortcuts keep working); release stops and **sends** the transcript if non-empty (same path as Enter in Step 10); Esc cancels. Starting to listen summons the panel with the bar showing the live transcript and the mic button in its "on" style.
Add `NSMicrophoneUsageDescription` and `NSSpeechRecognitionUsageDescription` to `project.yml`'s Info properties (next to the existing Accessibility/AppleEvents strings, `project.yml:70-71`) and regenerate; if the app is sandboxed in either build configuration, add `com.apple.security.device.audio-input`. Commit the regenerated `Info.plist`.
- **Account for:** permission denied → one-line notice in the bar ("Microphone or speech access is off — turn it on in System Settings → Privacy"), no retry loop; recogniser unavailable for the locale on-device → same notice; audio engine stopped and tap removed on every exit path (0 % CPU when idle); no audio ever leaves the Mac (on-device only — matches the no-telemetry rule).
- **Acceptance:** build. Manual: hold ⌥ for 1 s, say "add a readme", release → the transcript appears and an OpenCode task starts as in Step 10; ⌥-based shortcuts (e.g. ⌃⌥Space) still work; Activity Monitor shows Coucou at ~0 % CPU 5 s after release.

---

## Out of scope / Do NOT

- Do NOT touch `windows/` (Tauri), `voice-mochi/`, or any view listed as unchanged in decision 1.
- Do NOT rename any pill ID or change the bundle id. Do NOT edit `AgentTask` or `MiniBotCanvasView` signatures (wrap instead).
- Do NOT add third-party dependencies, network calls, or telemetry. Speech stays on-device.
- Do NOT approve, deny or answer anything without an explicit user action on a visible card. No auto-approve, ever.
- Do NOT start Claude Code from the app. Do NOT add OpenCode approval cards (OpenCode `PermissionRequest` stays answered `ask`).
- Do NOT add gestures (swipes/pinches), spoken replies (text-to-speech), thread history, or new Settings screens.
- Do NOT leave any `TimelineView`, timer or AX observer running while the island is hidden.
- Do NOT overwrite `~/.claude/settings.json` (hook installation flow is unchanged).
- Do NOT write a CHANGELOG/README/version bump — this is not a release.

## Definition of Done

- [ ] Steps 0–11 committed, one logical change per commit.
- [ ] Build command → `** BUILD SUCCEEDED **`; every `scripts/test-*.sh` referenced in `build.yml` → exit 0 (including the three new ones).
- [ ] Two plain-Terminal Claude Code sessions + one OpenCode session show as three Mochis; two simultaneous approvals both wait and resolve independently.
- [ ] The panel opens on its own only for approval / question / blocked / finished; Esc hides it until something new; finished folds after 8 s.
- [ ] Main follows the front window within ~1 s; with Accessibility off (or APPSTORE) everything else still works.
- [ ] The hand-off matches the prototype (variant E, motion 1): dot, colour blending during flight, hop on landing, clicked slot recolours to the old main after landing, small Mochis never move.
- [ ] Bar starts an OpenCode task in the main's folder; hold-⌥ voice works and shortcuts with ⌥ still work.
- [ ] Coucou ~0 % CPU when the island is hidden (Activity Monitor, 10 s).
- [ ] Unchanged views (Settings, upload, mail, chat, greeting, wardrobe…) look exactly as on `main`.
- [ ] `docs/SPEC.md` updated; no references to the removed v1 harness remain.
- [ ] Report lists every deviation from this plan and why.
