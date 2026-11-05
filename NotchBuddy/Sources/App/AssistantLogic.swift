import Foundation

// Pure decision logic for the assistant layer: who is the main Mochi, who needs the user,
// and where each small Mochi sits. Foundation only (tested by `scripts/test-assistant-logic.sh`).

enum MainAgentPicker {
    /// The main spot goes, in order, to: the agent the user clicked (if still alive) ->
    /// the oldest agent that needs the user (`AttentionQueue`) -> the most recently active
    /// session of the workspace the user is working in -> the previous main if still alive ->
    /// the most recently active session. Returns nil when there are no sessions.
    static func pick(sessions: [AgentSession], selectedId: String?, contextWorkspace: String?,
                     previousMainId: String?) -> String? {
        guard !sessions.isEmpty else { return nil }
        let ids = Set(sessions.map(\.id))

        if let selectedId, ids.contains(selectedId) { return selectedId }

        if let needy = AttentionQueue.order(sessions).first { return needy.id }

        if let contextWorkspace,
           let inContext = mostRecent(sessions.filter { $0.workspace == contextWorkspace }) {
            return inContext.id
        }

        if let previousMainId, ids.contains(previousMainId) { return previousMainId }

        return mostRecent(sessions)?.id
    }

    /// Latest `lastEventAt`; ties break on id so the result never depends on dictionary order.
    private static func mostRecent(_ sessions: [AgentSession]) -> AgentSession? {
        sessions.min { a, b in
            if a.lastEventAt != b.lastEventAt { return a.lastEventAt > b.lastEventAt }
            return a.id < b.id
        }
    }
}

enum AttentionQueue {
    /// approval/question/blocked first (oldest attentionAt first), then finished && !finishedSeen.
    /// Ties on `attentionAt` go to the session whose last event is older, then to the id.
    static func order(_ sessions: [AgentSession]) -> [AgentSession] {
        let blocking = sessions.filter {
            $0.phase == .approval || $0.phase == .question || $0.phase == .blocked
        }
        let done = sessions.filter { $0.phase == .finished && !$0.finishedSeen }
        return sorted(blocking) + sorted(done)
    }

    private static func sorted(_ list: [AgentSession]) -> [AgentSession] {
        list.sorted { a, b in
            let ta = a.attentionAt ?? .distantFuture
            let tb = b.attentionAt ?? .distantFuture
            if ta != tb { return ta < tb }
            if a.lastEventAt != b.lastEventAt { return a.lastEventAt < b.lastEventAt }
            return a.id < b.id
        }
    }
}

enum SubSlotOrder {
    /// Keeps every surviving sub in its slot. When `newMain` was a sub and `oldMain` is still alive,
    /// `oldMain` takes `newMain`'s slot and that index is returned (the slot to recolour after landing).
    static func update(order: [String], alive: [String], oldMain: String?, newMain: String?)
        -> (order: [String], recolourIndex: Int?) {
        let aliveSet = Set(alive)
        let oldMainAlive: String? = {
            guard let oldMain, oldMain != newMain, aliveSet.contains(oldMain) else { return nil }
            return oldMain
        }()

        var slots = order
        var swapped: String? = nil   // the id that took the clicked sub's slot

        if let newMain, let i = slots.firstIndex(of: newMain), let old = oldMainAlive,
           !slots.contains(old) {
            slots[i] = old
            swapped = old
        }

        // Drop dead ids and the new main (when it was not swapped out above, its slot closes).
        slots = slots.filter { aliveSet.contains($0) && $0 != newMain }

        // The old main joins the subs when it was not already placed by the swap.
        if let old = oldMainAlive, !slots.contains(old) { slots.append(old) }

        // Any alive id that is neither main nor present gets a new slot at the end.
        for id in alive where id != newMain && !slots.contains(id) { slots.append(id) }

        let recolour = swapped.flatMap { slots.firstIndex(of: $0) }
        return (slots, recolour)
    }
}

/// Geometry of the quiet strip (compact island), in island coordinates (origin top-left).
/// Values come from `design/prototype/assistant-multi-agent-prototype.html` (variant E).
/// `restingDiameter` is `IslandRestingLayout.botDiameter`.
struct AssistantStripGeometry: Equatable {
    static let maxVisibleSubs = 5
    static let subSpacing: CGFloat = 26
    static let subFirstOffset: CGFloat = 22     // first sub centre, outside the notch's right edge
    static let mainOffset: CGFloat = 30         // main centre, outside the notch's left edge
    static let minSide: CGFloat = 56            // minimum width each side of the notch
    static let subRatio: CGFloat = 0.68

    let islandWidth: CGFloat
    let islandHeight: CGFloat
    let notchWidth: CGFloat
    let restingDiameter: CGFloat

    /// Slots drawn right of the notch: up to 5 subs, plus one slot for the "+N" count on overflow.
    static func slotCount(subs: Int) -> Int {
        min(max(0, subs), maxVisibleSubs) + (subs > maxVisibleSubs ? 1 : 0)
    }

    /// Compact island width = notch + 2 x max(56, slots x 26 + 26): symmetric, so the camera stays centred.
    static func compactWidth(notchWidth: CGFloat, subs: Int) -> CGFloat {
        notchWidth + 2 * max(minSide, CGFloat(slotCount(subs: subs)) * subSpacing + subSpacing)
    }

    /// Resting diameter x 1.25, capped at notch height - 4.
    var mainDiameter: CGFloat { max(0, min(restingDiameter * 1.25, islandHeight - 4)) }
    var subDiameter: CGFloat { mainDiameter * Self.subRatio }
    var centreY: CGFloat { islandHeight / 2 }
    var mainCentreX: CGFloat { islandWidth / 2 - notchWidth / 2 - Self.mainOffset }
    func subCentreX(_ index: Int) -> CGFloat {
        islandWidth / 2 + notchWidth / 2 + Self.subFirstOffset + CGFloat(index) * Self.subSpacing
    }
}

extension AgentSession {
    /// Colour of the small status dot next to a Mochi: amber = approval/question, red = blocked,
    /// green = finished and not yet seen. nil = no dot.
    var statusDotHex: String? {
        switch phase {
        case .approval, .question: return "#F5A524"
        case .blocked: return "#F87171"
        case .finished: return finishedSeen ? nil : "#34D399"
        case .thinking, .working, .idle: return nil
        }
    }
}

// MARK: - Panel: open rule and content

/// When the assistant panel is open. Pure, so the state machine is tested without the UI.
///
/// open = summoned || selectedId != nil || (queue has a need the user has not dismissed)
///
/// The dismissed signature remembers WHICH needs were on the queue when the user pressed Esc.
/// A need that is not in it (new, changed phase, asked again) reopens the panel; a need that
/// went away (answered in the terminal, timed out) does not.
enum AssistantOpenRules {
    /// One key per need. Includes `attentionAt`, so the same session asking twice gives two keys.
    static func keys(queue: [AgentSession]) -> [String] {
        queue.map { "\($0.id)|\($0.phase.rawValue)|\($0.attentionAt?.timeIntervalSince1970 ?? 0)" }
    }

    /// The queue's keys joined; empty queue -> "".
    static func signature(queue: [AgentSession]) -> String {
        keys(queue: queue).joined(separator: ",")
    }

    static func isOpen(summoned: Bool, selectedId: String?, queue: [AgentSession],
                       dismissedSignature: String?) -> Bool {
        if summoned || selectedId != nil { return true }
        let dismissed = Set((dismissedSignature ?? "").split(separator: ",").map(String.init))
        return keys(queue: queue).contains { !dismissed.contains($0) }
    }
}

/// Which expanded views the assistant panel draws.
///
/// The home (`.overview`) is always the panel. The four alert views (approval, question, error,
/// finished) go to the panel only when an agent session needs the user. An alert with no
/// `AgentSession` behind it (an integration pill, a hook event without a session id) keeps its
/// shipping view and its shipping expansion, exactly as on `main`.
enum AssistantRouting {
    /// `hasFolder`: the bar has somewhere to send text, or the user is using it right now (voice,
    /// a launch card). Otherwise home stays the shipping view instead of an idle empty bar.
    static func usesPanel(isOverview: Bool, hasFolder: Bool, isAlertView: Bool, hasSessionNeed: Bool) -> Bool {
        (isOverview && hasFolder) || (isAlertView && hasSessionNeed)
    }
}

/// What the panel shows under the top row. Decides the panel height.
enum AssistantPanelContent: Equatable, Sendable {
    case bar                       // summoned with nothing pending: the bar row only
    case approval
    case question(rows: Int)       // rows = option buttons + the "Other..." row
    case blocked
    case finished(files: Int, extraLines: Int = 0, actions: Bool = false)   // extraLines: headline lines past the first two; actions: Mochi's suggestion row
    case diff                      // the finished card's diff, opened in place
    case launch(withPrompt: Bool)  // "Start <CLI> in <project>?" waiting for a click
    case clarify(choices: Int)     // the router asks which project / session

    /// The card for the main session. `hasApproval` / `questionRows` say whether the held request
    /// for THAT session still exists (a timed-out request has no card, whatever the phase says).
    static func resolve(main: AgentSession?, hasApproval: Bool, questionRows: Int?,
                        finishedFiles: Int, showsDiff: Bool, launchPrompt: Bool? = nil,
                        clarifyChoices: Int? = nil, headlineLines: Int = 2,
                        hasActions: Bool = false) -> AssistantPanelContent {
        // The user just asked for it: it wins over older cards.
        if let launchPrompt { return .launch(withPrompt: launchPrompt) }
        if let clarifyChoices { return .clarify(choices: clarifyChoices) }
        guard let main else { return .bar }
        switch main.phase {
        case .approval where hasApproval: return .approval
        case .question:
            if let rows = questionRows { return .question(rows: rows) }
            return .bar
        case .blocked: return .blocked
        case .finished where !main.finishedSeen:
            return showsDiff && finishedFiles > 0 ? .diff
                : .finished(files: finishedFiles, extraLines: max(0, headlineLines - 2),
                            actions: hasActions)
        default: return .bar
        }
    }
}

/// Panel heights in points. The prototype (variant D) values are the starting point; the
/// finished card grows by one file row (21 pt) per changed file, up to 3, and the question card
/// by 28 pt per option row (options are a vertical list; the prototype's `rows + 120` did not
/// leave room for the question text and the footer, so the base is 176).
/// The finished card shows one short line, never the agent's whole report ("Open session" has it).
enum AssistantReply {
    /// Two lines of the 15 pt headline hold about 110 characters across the panel.

    /// The fallback line when Mochi's on-device voice is unavailable: the reply's first sentence,
    /// without markdown, cut to the headline. nil for an empty reply.
    static func firstSentence(_ reply: String?) -> String? {
        guard let reply else { return nil }
        let paragraph = reply.components(separatedBy: "\n")
            .map { line -> String in
                var l = line.trimmingCharacters(in: .whitespaces)
                while let f = l.first, "#>-*•".contains(f) { l.removeFirst(); l = l.trimmingCharacters(in: .whitespaces) }
                return l.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            }
            .first { !$0.isEmpty } ?? ""
        guard !paragraph.isEmpty else { return nil }
        // A sentence ends at . ! or ? followed by a space or the end ("2.1.0" is not an end).
        var sentence = paragraph
        var i = paragraph.startIndex
        while i < paragraph.endIndex {
            let next = paragraph.index(after: i)
            if ".!?".contains(paragraph[i]), next == paragraph.endIndex || paragraph[next] == " " {
                sentence = String(paragraph[...i])
                break
            }
            i = next
        }
        return sentence   // never cut: the card wraps it and grows (`headlineLines`)
    }

    /// Roughly how many lines the finished card's headline takes (15 pt semibold, panel width).
    static func headlineLines(_ text: String) -> Int {
        max(1, Int((Double(text.count) / 60).rounded(.up)))
    }

    /// How long the finished card stays before it folds on its own: the headline read at a calm
    /// pace (about 3 words a second) plus 5 s to look up from other work. Never under 10 s, never
    /// over 45 s. Hover, a focused bar or "Got it" still decide before this.
    static func foldSeconds(_ text: String) -> Double {
        let words = text.split(whereSeparator: \.isWhitespace).count
        return min(45, max(10, 5 + Double(words) * 0.35))
    }
}

enum AssistantMetrics {
    static let bar: CGFloat = 112
    static let approval: CGFloat = 270   // the command wraps above the buttons
    static let blocked: CGFloat = 262
    static let finishedBase: CGFloat = 206
    /// The bar row under the finished card (follow-up task).
    static let finishedBar: CGFloat = 34
    static let fileRow: CGFloat = 21
    /// One more line of the finished card's headline (15 pt semibold).
    static let headlineLine: CGFloat = 20
    static let maxFileRows = 3
    /// The row of Mochi's suggested next steps (`MochiAware`) on the finished card.
    static let actionRow: CGFloat = 34
    /// With the suggestion row, one file row fewer so the card still fits the 320 pt window.
    static func fileRows(actions: Bool) -> Int { actions ? maxFileRows - 1 : maxFileRows }
    /// No footer on the question card: the two-line option rows use that height instead.
    static let questionBase: CGFloat = 148
    static let questionRow: CGFloat = 34
    static let diff: CGFloat = 300
    static let launch: CGFloat = 214
    /// The launch card with the user's first message under the title.
    static let launchWithPrompt: CGFloat = 280
    /// Header, top row and question; each choice adds a `questionRow`.
    static let clarifyBase: CGFloat = 148
    /// The island window is 320 pt tall.
    static let maxHeight: CGFloat = 320

    static func height(for content: AssistantPanelContent) -> CGFloat {
        let h: CGFloat
        switch content {
        case .bar: h = bar
        case .approval: h = approval
        case .blocked: h = blocked
        case .question(let rows): h = questionBase + CGFloat(max(1, rows)) * questionRow
        case .finished(let files, let extra, let actions):
            h = finishedBase + finishedBar + CGFloat(min(files, fileRows(actions: actions))) * fileRow
                + CGFloat(extra) * headlineLine + (actions ? actionRow : 0)
        case .diff: h = diff
        case .launch(let withPrompt): h = withPrompt ? launchWithPrompt : launch
        case .clarify(let n): h = clarifyBase + CGFloat(max(2, n)) * questionRow
        }
        return min(h, maxHeight)
    }
}

// MARK: - The bar: OpenCode tasks

/// Where an OpenCode task started from the bar runs.
struct AssistantTaskFolder: Equatable, Sendable {
    let cwd: String
    let workspace: String
}

enum AssistantBarLogic {
    /// The folder: the main session's cwd, else the cwd of the most recent session in the
    /// workspace the user is working in (`contextWorkspace`), else nil (the bar is disabled).
    static func folder(main: AgentSession?, contextWorkspace: String?,
                       sessions: [AgentSession]) -> AssistantTaskFolder? {
        if let main, !main.cwd.isEmpty {
            return AssistantTaskFolder(cwd: main.cwd, workspace: main.workspace)
        }
        guard let contextWorkspace else { return nil }
        let inContext = sessions
            .filter { $0.workspace == contextWorkspace && !$0.cwd.isEmpty }
            .min { a, b in
                if a.lastEventAt != b.lastEventAt { return a.lastEventAt > b.lastEventAt }
                return a.id < b.id
            }
        return inContext.map { AssistantTaskFolder(cwd: $0.cwd, workspace: $0.workspace) }
    }

    /// Where the bar's text goes. Only a session that is done (finished or idle) can be
    /// continued — a busy one would get two prompts at once. A done OpenCode chat continues with
    /// `opencode run --session`, a done Claude Code session with `claude -p --resume`. Everything
    /// else (busy sessions, Codex and the rest) gets a NEW OpenCode task in the same folder.
    enum Target: Equatable, Sendable {
        case reply(sessionId: String)        // `opencode run --session <id>`: same conversation
        case claudeReply(sessionId: String)  // `claude -p --resume <id>`: same Claude session
        case newTask                         // a fresh OpenCode session in the folder
    }

    /// `isWorker`: a session Mochi runs itself keeps an open stream, so it takes the next message
    /// even mid-turn (it is queued), except while it waits on an approval or a question.
    static func target(main: AgentSession?, isWorker: Bool = false) -> Target {
        if isWorker, let main, main.phase != .approval, main.phase != .question, !main.cwd.isEmpty {
            switch main.kind {
            case .openCode: return .reply(sessionId: main.id)
            case .claudeCode: return .claudeReply(sessionId: main.id)
            default: break
            }
        }
        guard let main, main.phase == .finished || main.phase == .idle else { return .newTask }
        switch main.kind {
        case .openCode: return .reply(sessionId: main.id)
        // `claude --resume` finds a session by its folder: without the session's own cwd the
        // run would land in another project and fail.
        case .claudeCode: return main.cwd.isEmpty ? .newTask : .claudeReply(sessionId: main.id)
        default: return .newTask
        }
    }

    /// The bar's placeholder for a target ("Listening…" and the no-folder copy are handled by the view).
    /// `toMochi`: the text goes to Mochi's assistant, whatever session is shown.
    static let askMochiPlaceholder = "Ask Mochi\u{2026}"
    static let toMochiTag = "to Mochi"

    static func placeholder(target: Target, workspace: String, toMochi: Bool = false) -> String {
        if toMochi { return askMochiPlaceholder }
        switch target {
        case .reply: return "Reply in this OpenCode chat…"
        case .claudeReply: return "Reply in this Claude Code session…"
        case .newTask: return "New OpenCode task in \(workspace)…"
        }
    }

    /// The small tag beside the field: says plainly where the text goes. nil when obvious.
    static func tag(target: Target, main: AgentSession?, toMochi: Bool = false) -> String? {
        if toMochi { return toMochiTag }
        switch target {
        case .reply: return "same chat"
        case .claudeReply: return "same Claude Code session"
        case .newTask:
            guard let main, main.kind != .openCode else { return nil }
            return "new OpenCode session · not sent to \(main.kind.displayName)"
        }
    }

    /// What the bar says while a request is on its way: Mochi is working out what it means, or it
    /// was sent and the panel is about to close.
    enum Status: Equatable, Sendable {
        case thinking
        case sent(String)
    }

    static let thinkingCopy = "Thinking\u{2026}"
    static let mochiSentCopy = "Sent to Mochi"
    /// How long the "sent" line stays before the panel closes.
    static let sentHold: Duration = .seconds(2)

    /// Says where the text went, so a closing panel is never the only answer.
    static func sentCopy(target: Target, workspace: String?) -> String {
        switch target {
        case .reply: return "Sent to your OpenCode chat"
        case .claudeReply: return "Sent to your Claude Code session"
        case .newTask:
            guard let workspace, !workspace.isEmpty else { return "Started a new OpenCode task" }
            return "Started a new OpenCode task in \(workspace)"
        }
    }

    enum Check: Equatable, Sendable {
        case ignore                      // empty or whitespace: nothing happens
        case error(String)               // one line shown in the bar, nothing launched
        case launch(prompt: String, cwd: String)
    }

    static let noFolderCopy = "Say or type a project, like \u{201C}work on coucou\u{201D}"
    static let whichProjectCopy = "Which project? Say its name, like \u{201C}work on coucou\u{201D}"
    static func noProjectCopy(_ query: String) -> String { "No project called \u{201C}\(query)\u{201D} in your history" }
    /// Tasks from the bar are real work; chat keeps OpenCodeChat's 120 s default.
    static let taskTimeout: TimeInterval = 60 * 60
    static let noModelCopy = "No OpenCode model set. Pick one in Settings."
    static let cliMissingCopy = "OpenCode CLI not found. Install it, then try again."
    static let claudeCliMissingCopy = "Claude Code CLI not found. Install it, then try again."

    /// Order matters: empty text is a no-op before any error is shown.
    /// `target`: a Claude Code reply needs no OpenCode model, and checks for the `claude` CLI.
    /// `modelRequired: false`: the text goes to a worker Mochi runs, which already has its model.
    static func check(text: String, folder: AssistantTaskFolder?, model: String,
                      cliAvailable: Bool, target: Target = .newTask, modelRequired: Bool = true) -> Check {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return .ignore }
        guard let folder else { return .error(noFolderCopy) }
        if case .claudeReply = target {
            guard cliAvailable else { return .error(claudeCliMissingCopy) }
            return .launch(prompt: prompt, cwd: folder.cwd)
        }
        guard !modelRequired || !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .error(noModelCopy)
        }
        guard cliAvailable else { return .error(cliMissingCopy) }
        return .launch(prompt: prompt, cwd: folder.cwd)
    }
}

/// "Hey Mochi" detection on a live transcript. The recogniser spells a made-up name many ways,
/// so the name side accepts the common misspellings; the greeting must come right before it.
enum WakePhrase {
    static let greetings: Set<String> = ["hey", "hi", "hay", "hei", "ok", "okay"]
    static let names: Set<String> = ["mochi", "mochee", "mochie", "mochy", "moochie", "mochis",
                                     "moji", "mogi", "mocchi", "motchi"]

    /// The word right after each greeting: what the recogniser made of the name (diagnostics).
    static func wordsAfterGreeting(_ transcript: String) -> [String] {
        let words = words(transcript)
        guard words.count >= 2 else { return [] }
        return (1..<words.count).filter { greetings.contains(words[$0 - 1]) }.map { words[$0] }
    }

    private static func words(_ transcript: String) -> [String] {
        transcript.lowercased()
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { !$0.isEmpty }
    }

    /// True when the text contains a greeting immediately followed by the name.
    static func matches(_ transcript: String) -> Bool {
        let words = words(transcript)
        guard words.count >= 2 else { return false }
        for i in 1..<words.count where names.contains(words[i]) && greetings.contains(words[i - 1]) {
            return true
        }
        return false
    }
}

/// Hands-free voice after "Hey Mochi": when to stop listening and what to do with the text.
enum HandsFreeEnd {
    /// Nothing said this long after the wake word: give up quietly.
    static let noSpeechTimeout: TimeInterval = 6
    /// The transcript has not changed this long: the user is done talking.
    static let pause: TimeInterval = 2.0

    enum Verdict: Equatable { case keepListening, send, cancel }

    static func verdict(transcript: String, sinceStart: TimeInterval, sinceChange: TimeInterval) -> Verdict {
        if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return sinceStart >= noSpeechTimeout ? .cancel : .keepListening
        }
        return sinceChange >= pause ? .send : .keepListening
    }
}

/// Session titles as the agents' own apps show them. Pure parsing; `SessionTitleReader` does I/O.
enum SessionTitle {
    /// Claude Code's project folder name for a cwd: every character that is not a letter or digit
    /// becomes "-" ("/Users/me/code/app" → "-Users-me-code-app").
    static func claudeProjectDir(cwd: String) -> String {
        String(cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
    }

    /// The newest title in a Claude Code transcript (JSON lines): a `custom-title` (what the
    /// desktop app and /rename set) wins over an older-style `summary`. nil when there is none.
    static func claudeTitle(transcriptTail text: String) -> String? {
        var summary: String?
        for line in text.split(separator: "\n").reversed() {
            guard line.contains("\"custom-title\"") || line.contains("\"summary\""),
                  let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let type = obj["type"] as? String else { continue }
            if type == "custom-title", let t = clean(obj["customTitle"] as? String) { return t }
            if type == "summary", summary == nil { summary = clean(obj["summary"] as? String) }
        }
        return summary
    }

    /// A title worth showing: trimmed, one line, not empty, not model debris like "<｜…｜ calls>".
    static func clean(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let t = raw.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !t.hasPrefix("<"), t.lowercased() != "new session" else { return nil }
        return t
    }
}

// MARK: - Project launch

/// The coding CLI a new session starts with. Raw values are stored in UserDefaults.
enum ProjectCLI: String, CaseIterable, Sendable {
    case claudeCode = "claude"
    case openCode = "opencode"

    var displayName: String { self == .claudeCode ? "Claude Code" : "OpenCode" }
    /// The command run in the project folder.
    var command: String { rawValue }
}

/// A folder the user has worked in, found in Claude Code's and OpenCode's history.
struct KnownProject: Equatable, Sendable {
    let path: String
    var lastClaude: Date?
    var lastOpenCode: Date?

    var name: String { (path as NSString).lastPathComponent }
    var lastUsed: Date? { [lastClaude, lastOpenCode].compactMap { $0 }.max() }
    /// The CLI used most recently here. nil when neither has a date.
    var lastUsedCLI: ProjectCLI? {
        switch (lastClaude, lastOpenCode) {
        case let (c?, o?): return c >= o ? .claudeCode : .openCode
        case (_?, nil): return .claudeCode
        case (nil, _?): return .openCode
        default: return nil
        }
    }
}

/// A launch waiting for the user's click on the confirm card.
struct PendingLaunch: Equatable, Sendable {
    let project: KnownProject
    var cli: ProjectCLI
    /// What the user said, sent as the new session's first message. nil = just open it.
    var prompt: String? = nil
}

enum ProjectLaunchLogic {
    /// Folders worth listing: inside the home folder, not the home folder itself, not in
    /// ~/Library, not in a hidden folder (~/.hyperframes, Claude worktrees), not node_modules.
    static func isUserProject(path: String, home: String) -> Bool {
        let home = home.hasSuffix("/") ? String(home.dropLast()) : home
        guard path.hasPrefix(home + "/") else { return false }
        let rest = path.dropFirst(home.count + 1)
        let parts = rest.split(separator: "/")
        guard !parts.isEmpty, parts.first != "Library" else { return false }
        return !parts.contains { $0.hasPrefix(".") || $0 == "node_modules" }
    }

    /// One entry per folder, newest first. Each source gives (folder, last used).
    static func merge(claude: [(String, Date)], openCode: [(String, Date)], home: String) -> [KnownProject] {
        var byPath: [String: KnownProject] = [:]
        for (raw, date) in claude {
            let path = standardize(raw)
            guard isUserProject(path: path, home: home) else { continue }
            var p = byPath[path] ?? KnownProject(path: path)
            p.lastClaude = max(p.lastClaude ?? date, date)
            byPath[path] = p
        }
        for (raw, date) in openCode {
            let path = standardize(raw)
            guard isUserProject(path: path, home: home) else { continue }
            var p = byPath[path] ?? KnownProject(path: path)
            p.lastOpenCode = max(p.lastOpenCode ?? date, date)
            byPath[path] = p
        }
        return byPath.values.sorted {
            let a = $0.lastUsed ?? .distantPast, b = $1.lastUsed ?? .distantPast
            return a != b ? a > b : $0.path < $1.path
        }
    }

    private static func standardize(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    /// Lowercase letters and digits only: "Bapoojee-production" → "bapoojeeproduction".
    static func normalize(_ s: String) -> String {
        String(s.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) })
    }

    struct Intent: Equatable, Sendable {
        let query: String
        let cli: ProjectCLI?
    }

    /// Phrases that ask to start working in a project. Longest first, so "work on" is not
    /// found inside "i want to work on" before it.
    static let triggers = ["i want to work on", "i'd like to work on", "let's work on", "lets work on",
                           "work on", "switch to", "open up", "open", "start", "launch", "go to"]
    private static let cliWords: [(String, ProjectCLI)] = [
        ("open code", .openCode), ("opencode", .openCode), ("claude code", .claudeCode), ("claude", .claudeCode),
    ]
    private static let fillers: Set<String> = ["the", "my", "project", "please", "with", "using", "in", "on",
                                               "a", "new", "session", "for", "me"]

    /// What the user asked for. `bare`: with nothing else to talk to, the whole text may be just
    /// the project's name ("bapoojee"). nil when there is no project name left.
    static func intent(from text: String, bare: Bool) -> Intent? {
        var t = " " + text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .map { $0.isLetter || $0.isNumber || $0 == "'" || $0 == "-" ? $0 : " " }
            .reduce(into: "") { $0.append($1) }
            .split(separator: " ").joined(separator: " ") + " "   // one space between words
        var cli: ProjectCLI?
        for (word, kind) in cliWords where t.contains(" \(word) ") {
            if cli == nil { cli = kind }
            t = t.replacingOccurrences(of: " \(word) ", with: " ")
        }
        // Talking to Mochi by name first is fine: "Mochi, work on coucou".
        for lead in [" hey mochi ", " mochi ", " ok ", " okay "] where t.hasPrefix(lead) {
            t = " " + t.dropFirst(lead.count)
        }
        var query: String?
        for trigger in triggers {
            // With a session to talk to, the request must START with the trigger: otherwise a
            // reply like "start the tests for coucou" would turn into a launch.
            if let r = t.range(of: " \(trigger) "), bare || r.lowerBound == t.startIndex {
                query = String(t[r.upperBound...])
                break
            }
        }
        if query == nil, bare { query = t }
        guard let q = query else { return nil }
        let words = q.split(separator: " ").map(String.init).filter { !fillers.contains($0) }
        let joined = words.joined(separator: " ")
        guard !normalize(joined).isEmpty else { return nil }
        return Intent(query: joined, cli: cli)
    }

    /// The project the query names. Exact name first, then a name that starts with the query (or
    /// the other way round), then one containing it, then a close spelling (speech recognition
    /// writes made-up names many ways). Ties go to the most recently used. nil when nothing fits.
    static func match(_ query: String, in projects: [KnownProject], minScore: Int = 1) -> KnownProject? {
        let q = normalize(query)
        guard q.count >= 3 else { return nil }
        var best: (score: Int, project: KnownProject)?
        for p in projects {
            let n = normalize(p.name)
            let score: Int
            if n == q { score = 4 }
            else if n.hasPrefix(q) || q.hasPrefix(n) && n.count >= 3 { score = 3 }
            else if n.contains(q) || q.contains(n) && n.count >= 4 { score = 2 }
            else if q.count >= 5, distance(q, String(n.prefix(q.count))) <= 2 { score = 1 }
            else { continue }
            guard score >= minScore else { continue }
            // `projects` is newest first, so the first one with the best score wins ties.
            if best == nil || score > best!.score { best = (score, p) }
        }
        return best?.project
    }

    /// A known project named anywhere in the text ("In Bapoojee, where is…"). Each word is
    /// compared with the project's name and with its first part ("bapoojee" of
    /// "Bapoojee-production"), allowing one wrong letter in longer names. Newest project wins.
    static func mentioned(in text: String, projects: [KnownProject]) -> KnownProject? {
        let words = text.lowercased()
            .split { !($0.isLetter || $0.isNumber) }
            .map { normalize(String($0)) }
        for p in projects {
            let first = p.name.split { $0 == "-" || $0 == "_" || $0 == "." || $0 == " " }.first.map(String.init) ?? p.name
            let keys = Set([normalize(p.name), normalize(first)]).filter { $0.count >= 4 }
            let hit = words.contains { w in
                keys.contains { k in w == k || (k.count >= 6 && abs(w.count - k.count) <= 1 && distance(w, k) <= 1) }
            }
            if hit { return p }
        }
        return nil
    }

    /// The command run in the project: the CLI alone, or with the first message.
    static func command(_ cli: ProjectCLI, prompt: String?) -> String {
        func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let base = cli.command
        guard let prompt, !prompt.isEmpty else { return base }
        return cli == .claudeCode ? "\(base) \(quote(prompt))" : "opencode --prompt \(quote(prompt))"
    }

    /// Spoken choice, else the project's own setting, else what was used there last, else the default.
    static func cli(override: ProjectCLI?, setting: ProjectCLI?, project: KnownProject,
                    fallback: ProjectCLI) -> ProjectCLI {
        override ?? setting ?? project.lastUsedCLI ?? fallback
    }

    /// Levenshtein distance; the strings here are a few dozen characters at most.
    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[b.count]
    }
}

// MARK: - Intent router

/// A running session as the router sees it. Short and text-only: no transcripts, no replies.
struct RouterSession: Equatable, Sendable {
    let id: String
    let agent: String
    let workspace: String
    let cwd: String
    let phase: String
    let title: String?
    let lastPrompt: String?
}

struct RouterProject: Equatable, Sendable {
    let name: String
    let path: String
    let lastCLI: ProjectCLI?
}

/// Everything a router decides from: what the user said and what is going on.
struct RouterInput: Equatable, Sendable {
    let utterance: String
    let sessions: [RouterSession]
    let projects: [RouterProject]       // newest first
    let mainSessionId: String?
}

indirect enum RouterAction: Equatable, Sendable {
    case reply(sessionId: String, text: String)
    case start(projectPath: String, cli: ProjectCLI?, prompt: String?)
    case open(sessionId: String)
    case clarify(question: String, choices: [RouterChoice])
    case none
}

struct RouterChoice: Equatable, Sendable {
    let label: String
    let action: RouterAction          // never .clarify or .none after `validated`
}

struct RouterDecision: Equatable, Sendable {
    let action: RouterAction
    let source: String                // "rules" | "claude"
}

extension RouterDecision {
    static let maxChoices = 4

    /// Keeps only actions that point at a real session or project in `input`. A clarify keeps its
    /// valid, distinct, non-nested choices (at most 4); one left becomes that action, none left
    /// becomes `.none`. Unknown ids never reach execution.
    func validated(against input: RouterInput) -> RouterDecision {
        RouterDecision(action: Self.valid(action, input: input, allowClarify: true), source: source)
    }

    private static func valid(_ action: RouterAction, input: RouterInput, allowClarify: Bool) -> RouterAction {
        switch action {
        case .reply(let id, let text):
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return input.sessions.contains { $0.id == id } && !t.isEmpty ? .reply(sessionId: id, text: t) : .none
        case .start(let path, let cli, let prompt):
            guard input.projects.contains(where: { $0.path == path }) else { return .none }
            let p = prompt?.trimmingCharacters(in: .whitespacesAndNewlines)
            return .start(projectPath: path, cli: cli, prompt: p?.isEmpty == true ? nil : p)
        case .open(let id):
            return input.sessions.contains { $0.id == id } ? action : .none
        case .clarify(let question, let choices):
            guard allowClarify else { return .none }
            var kept: [RouterChoice] = []
            for c in choices {
                let a = valid(c.action, input: input, allowClarify: false)
                let label = c.label.trimmingCharacters(in: .whitespacesAndNewlines)
                guard a != .none, !label.isEmpty, !kept.contains(where: { $0.action == a }) else { continue }
                kept.append(RouterChoice(label: label, action: a))
                if kept.count == maxChoices { break }
            }
            if kept.isEmpty { return .none }
            if kept.count == 1 { return kept[0].action }
            let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
            return .clarify(question: q.isEmpty ? "Which one?" : q, choices: kept)
        case .none:
            return .none
        }
    }
}

/// Today's phrase rules as a router: offline, instant, and the fallback for every other backend.
enum RuleRouter {
    static func decide(_ input: RouterInput) -> RouterDecision {
        RouterDecision(action: action(input), source: "rules")
    }

    private static func action(_ input: RouterInput) -> RouterAction {
        let text = input.utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .none }
        let main = input.mainSessionId.flatMap { id in input.sessions.contains { $0.id == id } ? id : nil }
        let bare = main == nil
        let reply: RouterAction = main.map { .reply(sessionId: $0, text: text) } ?? .none
        guard let intent = ProjectLaunchLogic.intent(from: text, bare: bare) else { return reply }
        let known = input.projects.map { KnownProject(path: $0.path) }
        // "work on bapoojee" names just the project; "In Bapoojee, where is…" is a first message.
        // With a session to talk to, only a strong name match (exact, or the name starts with what
        // was said) launches: "start the tests for coucou" stays a reply. Fuzzier cases are Claude's.
        if let p = ProjectLaunchLogic.match(intent.query, in: known, minScore: bare ? 1 : 3) {
            return .start(projectPath: p.path, cli: intent.cli, prompt: nil)
        }
        if bare, let p = ProjectLaunchLogic.mentioned(in: text, projects: known) {
            return .start(projectPath: p.path, cli: intent.cli, prompt: text)
        }
        return reply
    }
}

/// The Claude backend's request and response, without the network (tested).
enum ClaudeRouterParsing {
    enum ParseError: Error, Equatable { case notJSON, noText, stopped(String), missing(String), badAction(String) }

    static let instructions = """
        You route what a user says to Mochi, a helper in the MacBook notch that watches the user's \
        coding agent sessions (Claude Code, OpenCode and others). You get the user's words and the \
        current state as JSON. Pick exactly ONE action:
        - reply: the words are for a running session (a follow-up, an answer, an instruction). \
        Usually the main session. text = the user's words, unchanged.
        - start: the user wants to work in a project that has no running session, or names a \
        project for a new task. project_path copied exactly from projects. cli only if the user \
        named one ("with OpenCode", "in Claude"), else null. text = the user's words unchanged \
        when they contain a task or question for the new session, null when they only name the project.
        - open: the user wants to see a running session in the terminal.
        - clarify: two or more projects or sessions fit and you cannot tell which. Ask a short \
        question with 2 to 4 choices; each choice is a reply, start or open action with a short label.
        - none: nothing above fits.
        Rules: copy session_id and project_path exactly from the lists, never invent them. Never \
        rewrite, translate or shorten the user's words. Prefer clarify over guessing. Fields that \
        do not apply to the chosen action are null.
        """

    private static func choiceSchema() -> [String: Any] {
        [
            "type": "object", "additionalProperties": false,
            "required": ["label", "action", "session_id", "project_path", "cli", "text"],
            "properties": [
                "label": ["type": "string"],
                "action": ["type": "string", "enum": ["reply", "start", "open"]],
                "session_id": ["type": ["string", "null"]],
                "project_path": ["type": ["string", "null"]],
                "cli": ["type": ["string", "null"]],   // "claude" | "opencode" | null; anything else → nil
                "text": ["type": ["string", "null"]],
            ],
        ]
    }

    /// Fixed for every request: a changed schema costs a compile on Anthropic's side.
    static func schema() -> [String: Any] {
        [
            "type": "object", "additionalProperties": false,
            "required": ["action", "session_id", "project_path", "cli", "text", "question", "choices"],
            "properties": [
                "action": ["type": "string", "enum": ["reply", "start", "open", "clarify", "none"]],
                "session_id": ["type": ["string", "null"]],
                "project_path": ["type": ["string", "null"]],
                "cli": ["type": ["string", "null"]],   // "claude" | "opencode" | null; anything else → nil
                "text": ["type": ["string", "null"]],
                "question": ["type": ["string", "null"]],
                "choices": ["type": "array", "items": choiceSchema()],
            ],
        ]
    }

    static func stateJSON(_ input: RouterInput) -> String {
        func opt(_ s: String?) -> Any { s ?? NSNull() }
        let state: [String: Any] = [
            "user_said": input.utterance,
            "main_session_id": opt(input.mainSessionId),
            "sessions": input.sessions.map {
                ["id": $0.id, "agent": $0.agent, "workspace": $0.workspace, "cwd": $0.cwd,
                 "phase": $0.phase, "title": opt($0.title), "last_prompt": opt($0.lastPrompt)] as [String: Any]
            },
            "projects": input.projects.map {
                ["name": $0.name, "path": $0.path, "last_cli": opt($0.lastCLI?.rawValue)] as [String: Any]
            },
        ]
        let data = (try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// The Messages API body. Stable parts (system, schema) first so they cache.
    static func requestBody(input: RouterInput, model: String) -> Data {
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "system": instructions,
            "output_config": [
                "effort": "low",
                "format": ["type": "json_schema", "schema": schema()],
            ],
            "messages": [["role": "user", "content": stateJSON(input)]],
        ]
        return (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
    }

    /// The Messages API response → the action. Throws on a refusal, a cut-off answer or bad JSON.
    static func action(fromResponse data: Data) throws -> RouterAction {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ParseError.notJSON }
        let stop = obj["stop_reason"] as? String ?? ""
        guard stop == "end_turn" || stop == "stop_sequence" else { throw ParseError.stopped(stop) }
        let blocks = obj["content"] as? [[String: Any]] ?? []
        guard let text = blocks.first(where: { $0["type"] as? String == "text" })?["text"] as? String
        else { throw ParseError.noText }
        return try action(fromJSON: Data(text.utf8))
    }

    /// The schema JSON → the action.
    static func action(fromJSON data: Data) throws -> RouterAction {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ParseError.notJSON }
        return try action(from: obj, allowClarify: true)
    }

    private static func action(from obj: [String: Any], allowClarify: Bool) throws -> RouterAction {
        func str(_ k: String) -> String? {
            guard let s = obj[k] as? String else { return nil }
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        func need(_ k: String) throws -> String {
            guard let v = str(k) else { throw ParseError.missing(k) }
            return v
        }
        let kind = obj["action"] as? String ?? ""
        switch kind {
        case "reply": return .reply(sessionId: try need("session_id"), text: try need("text"))
        case "start": return .start(projectPath: try need("project_path"),
                                    cli: str("cli").flatMap(ProjectCLI.init(rawValue:)), prompt: str("text"))
        case "open": return .open(sessionId: try need("session_id"))
        case "none": return .none
        case "clarify" where allowClarify:
            let raw = obj["choices"] as? [[String: Any]] ?? []
            let choices = raw.compactMap { c -> RouterChoice? in
                guard let label = c["label"] as? String,
                      let a = try? action(from: c, allowClarify: false), a != .none else { return nil }
                return RouterChoice(label: label, action: a)
            }
            return .clarify(question: str("question") ?? "Which one?", choices: choices)
        default: throw ParseError.badAction(kind)
        }
    }
}

/// What Mochi's workers may ask for with their `report` tool: validation of the suggested next steps
/// (buttons on the finished card), and small helpers for them. Nothing here runs without a click.
enum MochiAware {
    /// Mochi's own sessions, newest last; older ids drop off past this many.
    static let keep = 100
    static let maxLabel = 28

    /// One action from its JSON object; nil when the label or the kind is missing or unusable.
    /// `focus` is not a kind it knows: model output can never produce it.
    static func action(from obj: [String: Any]) -> MochiAction? {
        guard let rawLabel = obj["label"] as? String else { return nil }
        let label = String(rawLabel.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxLabel))
        guard !label.isEmpty else { return nil }
        func value(_ key: String) -> String? {
            guard let v = (obj[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !v.isEmpty, v.count <= 4_000 else { return nil }
            return v
        }
        if let v = value("open") {
            let lower = v.lowercased()
            if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
                return MochiAction(label: label, kind: .openURL(v))
            }
            // Any other scheme (file://, custom app links) could launch something: refused.
            guard !v.contains("://") else { return nil }
            return MochiAction(label: label, kind: .openFile(v))
        }
        if let v = value("reveal"), !v.contains("://") { return MochiAction(label: label, kind: .reveal(v)) }
        if let v = value("reply") { return MochiAction(label: label, kind: .reply(v)) }
        if let v = value("copy") { return MochiAction(label: label, kind: .copy(v)) }
        return nil
    }

    /// A path from an action: `~` expanded, relative paths taken from the session's folder.
    static func resolvePath(_ path: String, cwd: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") || cwd.isEmpty { return (expanded as NSString).standardizingPath }
        return ((cwd as NSString).appendingPathComponent(expanded) as NSString).standardizingPath
    }

    /// `ids` with `id` added last (once), trimmed to `keep`.
    static func remembering(_ id: String, in ids: [String]) -> [String] {
        Array((ids.filter { $0 != id } + [id]).suffix(keep))
    }
}


// MARK: - Mochi as conductor: worker runtimes and the brain

/// Pure helpers for the workers Mochi starts and the tools it works through. Foundation only.
enum MochiTools {
    /// Name of the MCP server a worker sees, so its report tool is `mcp__coucou__report`.
    static let serverName = "coucou"

    /// OpenCode session ids: `ses` then letters, digits or `_`. Checked before one reaches a shell command.
    static func isOpenCodeSessionId(_ id: String) -> Bool {
        id.hasPrefix("ses") && id.count <= 64
            && id.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "_" }
    }
    static let reportToolName = "report"

    /// Appended to a worker's system prompt. The user sees only what the worker sends with `report`.
    static let workerNote = """
        You were started from Mochi, the user's assistant in the Mac notch. The user sees only what \
        you send with the `report` tool (from the `coucou` server). When you finish a turn, call \
        `report` once with one short plain sentence in `line` (under 20 words, no markdown, code or \
        file paths) saying what you did or what you need from the user, and up to 3 one-click next \
        steps in `actions`. Each action has a `label` of 2 to 4 words and exactly one of: `open` (an \
        http(s) URL such as a dev server you started, or a file path to open in its default app), \
        `reveal` (a file or folder path to show in Finder), `reply` (a message sent back to you as \
        the user's next request, such as "Run the tests"), or `copy` (text to copy). Use absolute \
        paths. Only suggest steps that clearly help right now; suggesting none is fine.
        """

    // MARK: The `report` tool (MCP)

    static let protocolVersion = "2025-06-18"
    static let maxReportLine = 240

    /// The tools a worker sees: `report` only.
    static func workerToolList() -> [[String: Any]] {
        let action: [String: Any] = [
            "type": "object",
            "properties": [
                "label": ["type": "string", "description": "2 to 4 words on the button"],
                "open": ["type": "string", "description": "An http(s) URL, or a file path to open"],
                "reveal": ["type": "string", "description": "A file or folder path to show in Finder"],
                "reply": ["type": "string", "description": "A message sent back to you as the user's next request"],
                "copy": ["type": "string", "description": "Text to copy"],
            ],
            "required": ["label"],
        ]
        return [[
            "name": reportToolName,
            "description": "Tell the user, in the Mac notch, how this turn went: one short sentence and up to 3 one-click next steps. Call it once when you finish a turn.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "line": ["type": "string", "description": "One short plain sentence, under 20 words"],
                    "actions": ["type": "array", "maxItems": maxReportActions, "items": action],
                ],
                "required": ["line"],
            ] as [String: Any],
        ]]
    }

    static let maxReportActions = 3

    /// A `report` call's arguments as a note. nil when `line` is missing or empty. Actions that are
    /// not valid are dropped, at most 3 are kept, and `focus` (or any other kind the model invents)
    /// can never come out of here.
    static func parseReport(_ args: [String: Any]) -> MochiNote? {
        guard let raw = args["line"] as? String else { return nil }
        let flat = raw.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !flat.isEmpty else { return nil }
        var actions: [MochiAction] = []
        for item in (args["actions"] as? [[String: Any]] ?? []) {
            guard actions.count < maxReportActions, let a = MochiAware.action(from: item),
                  !actions.contains(where: { $0.label == a.label }) else { continue }
            actions.append(a)
        }
        return MochiNote(line: String(flat.prefix(maxReportLine)), actions: actions)
    }

    /// One JSON-RPC message from a worker's MCP client, answered. nil for a notification (no reply).
    /// `report` is called with a valid note and returns nil on success, or a short reason it failed.
    static func mcpResponse(to rpc: [String: Any], report: (MochiNote) -> String?) -> [String: Any]? {
        guard let id = rpc["id"], let method = rpc["method"] as? String else { return nil }
        func ok(_ result: [String: Any]) -> [String: Any] { ["jsonrpc": "2.0", "id": id, "result": result] }
        func fail(_ code: Int, _ message: String) -> [String: Any] {
            ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
        }
        func text(_ message: String, isError: Bool) -> [String: Any] {
            ok(["content": [["type": "text", "text": message]], "isError": isError])
        }
        switch method {
        case "initialize":
            return ok(["protocolVersion": protocolVersion, "capabilities": ["tools": [String: Any]()],
                       "serverInfo": ["name": serverName, "version": "1"]])
        case "ping":
            return ok([:])
        case "tools/list":
            return ok(["tools": workerToolList()])
        case "tools/call":
            let params = rpc["params"] as? [String: Any] ?? [:]
            guard (params["name"] as? String) == reportToolName else { return fail(-32602, "Unknown tool") }
            guard let note = parseReport(params["arguments"] as? [String: Any] ?? [:]) else {
                return text("report needs a non-empty `line`.", isError: true)
            }
            if let reason = report(note) { return text(reason, isError: true) }
            return text("Shown to the user.", isError: false)
        default:
            return fail(-32601, "Method not found")
        }
    }

    /// The `claude` command line for a Mochi-owned worker: stream-json in and out, one process per
    /// session. Prompts arrive on stdin, never as an argument. Permissions are never loosened:
    /// the only pre-allowed tool is Mochi's own `report`.
    static func claudeWorkerArguments(sessionId: String, resume: Bool, model: ModelRef?,
                                      mcpConfig: String) -> [String] {
        var args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                    resume ? "--resume" : "--session-id", sessionId,
                    "--append-system-prompt", workerNote,
                    "--mcp-config", mcpConfig,
                    "--allowedTools", "mcp__\(serverName)__\(reportToolName)"]
        if let model, !model.id.isEmpty { args += ["--model", model.id] }
        return args
    }

    /// `--mcp-config` JSON: one stdio server, the `nb-hook` relay in MCP mode. The owner comes from
    /// this config's env, never from the model.
    static func claudeMCPConfig(hookPath: String, owner: String) -> String {
        mcpConfigJSON(runtime: "claude", hookPath: hookPath, owner: owner)
    }

    static func mcpServerEnv(runtime: String, owner: String) -> [String: String] {
        ["COUCOU_ROLE": "worker", "COUCOU_RUNTIME": runtime, "COUCOU_OWNER": owner]
    }

    /// File name of the worker note next to `nb-hook`. OpenCode takes instructions as files, not text.
    static let workerNoteFileName = "mochi-worker-note.md"

    /// `OPENCODE_CONFIG_CONTENT` for one project's `opencode serve`. Per process only: the user's own
    /// OpenCode config is never read or changed. Adds Mochi's MCP server (the `report` tool) and the
    /// worker note. Permissions stay the user's own OpenCode settings: whatever OpenCode asks reaches
    /// the notch's approval card (with OpenCode's defaults, edits and commands are not asked).
    static func openCodeConfigContent(hookPath: String, owner: String) -> String {
        let noteFile = ((hookPath as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent(workerNoteFileName)
        let server: [String: Any] = [
            "type": "local",
            "command": ["/bin/sh", hookPath, "--mcp"],
            "environment": mcpServerEnv(runtime: "opencode", owner: owner),
            "enabled": true,
        ]
        let root: [String: Any] = [
            "mcp": [serverName: server],
            "instructions": [noteFile],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func mcpConfigJSON(runtime: String, hookPath: String, owner: String) -> String {
        let server: [String: Any] = [
            "command": "/bin/sh",
            "args": [hookPath, "--mcp"],
            "env": mcpServerEnv(runtime: runtime, owner: owner),
        ]
        let root: [String: Any] = ["mcpServers": [serverName: server]]
        let data = (try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

/// Which of a folder's workers a report belongs to (OpenCode workers share one server per folder).
enum MochiReportTarget {
    /// The one working right now (thinking, working, or waiting on the user); else the most recently active.
    static func pick(from candidates: [AgentSession]) -> String? {
        let busy = candidates.filter { [.thinking, .working, .approval, .question].contains($0.phase) }
        let pool = busy.isEmpty ? candidates : busy
        return pool.max { a, b in
            if a.lastEventAt != b.lastEventAt { return a.lastEventAt < b.lastEventAt }
            return a.id > b.id
        }?.id
    }
}

// MARK: - The brain: Mochi's own tool-calling loop (pure parts)

/// One tool call a model made.
struct BrainToolCall: Equatable, Sendable, Codable {
    let id: String
    let name: String
    /// The arguments exactly as a JSON object in text (what both providers send and expect back).
    let argumentsJSON: String

    var arguments: [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any] ?? [:]
    }
    /// The model sent something that is not a JSON object.
    var argumentsAreValid: Bool {
        (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) is [String: Any]
    }

    init(id: String, name: String, arguments: [String: Any]) {
        self.id = id
        self.name = name
        let data = (try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        self.argumentsJSON = String(data: data, encoding: .utf8) ?? "{}"
    }
    init(id: String, name: String, argumentsJSON: String) {
        self.id = id
        self.name = name
        self.argumentsJSON = argumentsJSON
    }
}

/// One message of the brain's conversation. `tool` messages answer a tool call of the assistant.
struct BrainMessage: Equatable, Sendable, Codable {
    enum Role: String, Codable, Sendable { case user, assistant, tool }
    var role: Role
    var text: String
    var toolCalls: [BrainToolCall] = []
    var toolCallId: String? = nil
    var isError: Bool = false

    static func user(_ text: String) -> BrainMessage { BrainMessage(role: .user, text: text) }
    static func assistant(_ turn: BrainTurn) -> BrainMessage {
        BrainMessage(role: .assistant, text: turn.text, toolCalls: turn.toolCalls)
    }
    static func tool(id: String, _ text: String, isError: Bool = false) -> BrainMessage {
        BrainMessage(role: .tool, text: text, toolCallId: id, isError: isError)
    }
}

/// A tool the brain may call. `schemaJSON` is a JSON Schema object in text.
struct BrainTool: Equatable, Sendable {
    let name: String
    let description: String
    let schemaJSON: String

    init(name: String, description: String, schema: [String: Any]) {
        self.name = name
        self.description = description
        let data = (try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        self.schemaJSON = String(data: data, encoding: .utf8) ?? "{}"
    }
    var schema: [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(schemaJSON.utf8))) as? [String: Any] ?? [:]
    }
}

/// What a model answered: text, and the tools it wants run.
struct BrainTurn: Equatable, Sendable {
    var text: String
    var toolCalls: [BrainToolCall]
    /// A tool call whose arguments could not be read (small local models do this): the loop ends.
    var unparsable: Bool = false
}

/// Request bodies and response readers for the two wire formats the brain speaks.
enum BrainWire {
    static let maxTokens = 1_024

    // MARK: Anthropic Messages API

    static func anthropicBody(model: String, system: String, messages: [BrainMessage], tools: [BrainTool]) -> [String: Any] {
        var out: [[String: Any]] = []
        // Tool results go in one user message with the text that follows them, as the API wants.
        var pendingUser: [[String: Any]] = []
        func flushUser() {
            if !pendingUser.isEmpty { out.append(["role": "user", "content": pendingUser]); pendingUser = [] }
        }
        for m in messages {
            switch m.role {
            case .user:
                pendingUser.append(["type": "text", "text": m.text])
            case .tool:
                var block: [String: Any] = ["type": "tool_result", "tool_use_id": m.toolCallId ?? "", "content": m.text]
                if m.isError { block["is_error"] = true }
                pendingUser.append(block)
            case .assistant:
                flushUser()
                var blocks: [[String: Any]] = []
                if !m.text.isEmpty { blocks.append(["type": "text", "text": m.text]) }
                for c in m.toolCalls { blocks.append(["type": "tool_use", "id": c.id, "name": c.name, "input": c.arguments]) }
                if blocks.isEmpty { blocks.append(["type": "text", "text": "(no answer)"]) }
                out.append(["role": "assistant", "content": blocks])
            }
        }
        flushUser()
        var body: [String: Any] = ["model": model, "max_tokens": maxTokens, "system": system, "messages": out]
        if !tools.isEmpty {
            body["tools"] = tools.map { ["name": $0.name, "description": $0.description, "input_schema": $0.schema] as [String: Any] }
        }
        return body
    }

    /// nil when the response is not a Messages API answer (an error object, or not JSON).
    static func parseAnthropic(_ data: Data) -> BrainTurn? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              obj["type"] as? String != "error", let content = obj["content"] as? [[String: Any]] else { return nil }
        var text = "", calls: [BrainToolCall] = [], unparsable = false
        for block in content {
            switch block["type"] as? String {
            case "text":
                if let t = block["text"] as? String { text += (text.isEmpty ? "" : "\n") + t }
            case "tool_use":
                guard let id = block["id"] as? String, let name = block["name"] as? String,
                      let input = block["input"] as? [String: Any] else { unparsable = true; continue }
                calls.append(BrainToolCall(id: id, name: name, arguments: input))
            default: break
            }
        }
        return BrainTurn(text: text.trimmingCharacters(in: .whitespacesAndNewlines), toolCalls: calls, unparsable: unparsable)
    }

    // MARK: OpenAI-compatible chat completions

    static func openAIBody(model: String, system: String, messages: [BrainMessage], tools: [BrainTool]) -> [String: Any] {
        var out: [[String: Any]] = [["role": "system", "content": system]]
        for m in messages {
            switch m.role {
            case .user:
                out.append(["role": "user", "content": m.text])
            case .tool:
                out.append(["role": "tool", "tool_call_id": m.toolCallId ?? "", "content": m.text])
            case .assistant:
                var msg: [String: Any] = ["role": "assistant", "content": m.text.isEmpty ? NSNull() : m.text as Any]
                if !m.toolCalls.isEmpty {
                    msg["tool_calls"] = m.toolCalls.map { c -> [String: Any] in
                        ["id": c.id, "type": "function", "function": ["name": c.name, "arguments": c.argumentsJSON]]
                    }
                }
                out.append(msg)
            }
        }
        var body: [String: Any] = ["model": model, "messages": out, "max_tokens": maxTokens]
        if !tools.isEmpty {
            body["tools"] = tools.map { t -> [String: Any] in
                ["type": "function", "function": ["name": t.name, "description": t.description, "parameters": t.schema]]
            }
            body["tool_choice"] = "auto"
        }
        return body
    }

    static func parseOpenAI(_ data: Data) -> BrainTurn? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let message = ((obj["choices"] as? [[String: Any]])?.first)?["message"] as? [String: Any] else { return nil }
        var text = ""
        if let s = message["content"] as? String { text = s }
        else if let parts = message["content"] as? [[String: Any]] {
            text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        var calls: [BrainToolCall] = [], unparsable = false
        for raw in (message["tool_calls"] as? [[String: Any]] ?? []) {
            guard let fn = raw["function"] as? [String: Any], let name = fn["name"] as? String, !name.isEmpty else {
                unparsable = true; continue
            }
            let id = (raw["id"] as? String) ?? "call_\(calls.count + 1)"
            // Arguments are text; some servers send an object, a few send nonsense.
            let argText: String
            if let s = fn["arguments"] as? String { argText = s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "{}" : s }
            else if let o = fn["arguments"] as? [String: Any] { argText = BrainToolCall(id: id, name: name, arguments: o).argumentsJSON }
            else { argText = "{}" }
            let call = BrainToolCall(id: id, name: name, argumentsJSON: argText)
            if !call.argumentsAreValid { unparsable = true }
            calls.append(call)
        }
        return BrainTurn(text: text.trimmingCharacters(in: .whitespacesAndNewlines), toolCalls: calls, unparsable: unparsable)
    }
}

/// The brain's conversation memory.
enum BrainHistory {
    static let keep = 40

    /// The last `limit` messages, starting at a user message so a tool result never loses its call.
    static func trimmed(_ messages: [BrainMessage], limit: Int = keep) -> [BrainMessage] {
        guard messages.count > limit else { return messages }
        var tail = Array(messages.suffix(limit))
        while let first = tail.first, first.role != .user { tail.removeFirst() }
        return tail
    }
}

/// Where provider requests go: Chat (`ClaudeService`) and the brain read the same constants, so they
/// cannot drift. One constant per endpoint.
enum ProviderEndpoints {
    static let openAI = "https://api.openai.com/v1"
    static let google = "https://generativelanguage.googleapis.com/v1beta/openai"
    static let anthropic = "https://api.anthropic.com/v1/messages"
    /// OpenCode Zen's OpenAI-compatible chat endpoint (`<base>/chat/completions`). NOT VERIFIED with a
    /// real call (see the hand-off report); change it here only.
    static let zen = "https://opencode.ai/zen/v1"
    /// OpenCode Go's gateway: `opencode-go/*` models. The Zen key authorizes it too (see `OpenCodeChat.zenAPIKey`).
    static let zenGo = "https://opencode.ai/zen/go/v1"
}

/// What the brain's `ask_user` and project tools take, checked before anything runs.
enum BrainToolArgs {
    static let maxChoices = 4
    static let minChoices = 2

    /// The question card for `ask_user`: 2 to 4 choices. nil when the call is not usable.
    static func question(from args: [String: Any]) -> AskQuestion? {
        guard let q = (args["question"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !q.isEmpty,
              let raw = args["choices"] as? [Any] else { return nil }
        var seen = Set<String>()
        let labels = raw.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        guard labels.count >= minChoices else { return nil }
        let options = labels.prefix(maxChoices).map { AskQuestionOption(label: String($0.prefix(60)), description: "") }
        return AskQuestion(questions: [AskQuestionItem(question: String(q.prefix(300)), header: "Mochi",
                                                       options: Array(options), multiSelect: false)])
    }

    /// The runtime a tool call names ("claude", "claude code", "opencode"…). nil: not named.
    static func runtime(from raw: Any?) -> ProjectCLI? {
        guard let s = (raw as? String)?.lowercased().filter({ $0.isLetter }) else { return nil }
        if s.hasPrefix("claude") { return .claudeCode }
        if s.hasPrefix("opencode") { return .openCode }
        return nil
    }
}

extension MochiTools {
    static let brainToolNames = ["list_projects", "project_status", "start_project_work",
                                 "send_to_project", "ask_user", "report",
                                 "open_app", "open_url", "open_file"]

    /// The nine tools the brain works through: six for projects and the user, three to open things on the Mac.
    /// There is no shell, file-reading or network tool.
    static func brainTools() -> [BrainTool] {
        let project: [String: Any] = ["type": "string", "description": "A project's name, as listed by list_projects (a spoken or partial name is fine)"]
        let action: [String: Any] = [
            "type": "object",
            "properties": [
                "label": ["type": "string", "description": "2 to 4 words on the button"],
                "open": ["type": "string"], "reveal": ["type": "string"],
                "reply": ["type": "string"], "copy": ["type": "string"],
            ],
            "required": ["label"],
        ]
        return [
            BrainTool(name: "list_projects",
                      description: "The projects the user has worked in, newest first (name, path, which agent they use, last used).",
                      schema: ["type": "object", "properties": [String: Any]()]),
            BrainTool(name: "project_status",
                      description: "What the agents are doing: every live session, or the named project's. Shows phase, last request and last report.",
                      schema: ["type": "object", "properties": ["project": project]]),
            BrainTool(name: "start_project_work",
                      description: "Start an agent in a project with a task. Pass the user's words faithfully plus any context the agent needs. Does not wait for the work to finish.",
                      schema: ["type": "object",
                               "properties": ["project": project,
                                              "task": ["type": "string", "description": "What the agent should do, in the user's words plus needed context"],
                                              "runtime": ["type": "string", "enum": ["claude", "opencode"], "description": "Which agent. Leave out to use the project's usual one."],
                                              "model": ["type": "string", "description": "Only when the user names a model. OpenCode: provider/model. Claude: sonnet, opus or haiku."]],
                               "required": ["project", "task"]]),
            BrainTool(name: "send_to_project",
                      description: "Send a follow-up message to the agent already working in a project. If none is, starts one with the message as its task.",
                      schema: ["type": "object",
                               "properties": ["project": project, "message": ["type": "string"]],
                               "required": ["project", "message"]]),
            BrainTool(name: "ask_user",
                      description: "Ask the user to pick one of 2 to 4 choices (a card appears). Use it when a name is ambiguous or you need a decision. Returns the choice.",
                      schema: ["type": "object",
                               "properties": ["question": ["type": "string"],
                                              "choices": ["type": "array", "minItems": 2, "maxItems": 4, "items": ["type": "string"]]],
                               "required": ["question", "choices"]]),
            BrainTool(name: "report",
                      description: "Tell the user the outcome: one short sentence and up to 3 optional buttons. End every turn with it. The user sees only this.",
                      schema: ["type": "object",
                               "properties": ["line": ["type": "string", "description": "One short plain sentence, under 20 words"],
                                              "actions": ["type": "array", "maxItems": 3, "items": action]],
                               "required": ["line"]]),
            BrainTool(name: "open_app",
                      description: "Open an app on the Mac by its name (\"Google Chrome\", \"chrome\", \"Notes\"). Opens apps only; it runs no command.",
                      schema: ["type": "object",
                               "properties": ["name": ["type": "string", "description": "The app's name"]],
                               "required": ["name"]]),
            BrainTool(name: "open_url",
                      description: "Open a web link (http or https only) in the default browser, or in the named app.",
                      schema: ["type": "object",
                               "properties": ["url": ["type": "string", "description": "An http(s) link"],
                                              "app": ["type": "string", "description": "Optional app to open it in, such as \"Google Chrome\""]],
                               "required": ["url"]]),
            BrainTool(name: "open_file",
                      description: "Open a file or folder on the Mac by path (absolute or starting with ~). Anything that could run code is shown in Finder instead of opened. reveal: true always shows it in Finder.",
                      schema: ["type": "object",
                               "properties": ["path": ["type": "string"],
                                              "reveal": ["type": "boolean", "description": "Show in Finder instead of opening"]],
                               "required": ["path"]]),
        ]
    }

    static let brainPrompt = """
        You are Mochi, the user's personal assistant, living in the notch of their Mac. You work only \
        through your tools. You have no files, shell or web of your own. You can open apps, web links and \
        files on the user's Mac with open_app, open_url and open_file (app names, http(s) links and file \
        paths only). You never run commands.
        Anything that happens inside a project is done by an agent working in that project: hand it over \
        with start_project_work (a new task) or send_to_project (a follow-up to the agent already there), \
        passing the user's words faithfully plus any context the agent needs. Never say or imply that you \
        did project work yourself. Use list_projects to find the right project, and project_status to see \
        what the agents are doing. If a project name could mean several, or you need a decision, call \
        ask_user with 2 to 4 choices. You may choose the runtime or model only when the user names one.
        Answer general questions directly. Be brief.
        End every turn with the report tool: one short plain sentence (under 20 words) and, only when it \
        clearly helps, up to 3 buttons. The user sees only that sentence.
        """
}

// MARK: - The brain on a Claude Code login (pure parts)

/// The models Mochi's brain can think with on Anthropic (the API key and the Claude Code login share
/// this list), and the small grammar helper for the Settings status line.
enum BrainModels {
    /// Newest first. These are fixed on purpose: no call is made to list them.
    static let anthropic: [(id: String, label: String)] = [
        (id: "claude-opus-5-5", label: "Opus 5.5"),
        (id: "claude-sonnet-5-5", label: "Sonnet 5.5"),
        (id: "claude-haiku-5-5", label: "Haiku 5.5"),
        (id: "claude-fable-5-1", label: "Fable 5.1"),
    ]
    static let defaultAnthropic = "claude-sonnet-5-5"

    /// The brain's OpenCode choice lists and uses OpenCode Go models only.
    static let openCodeGoPrefix = "opencode-go/"
    static func isOpenCodeGo(_ id: String) -> Bool { id.hasPrefix(openCodeGoPrefix) }

    /// Where an OpenCode catalog id is sent, and the bare model name the gateway expects:
    /// `opencode-go/x` → Go gateway, `opencode/x` → Zen. nil for anything else (no gateway serves it).
    static func openCodeRoute(_ id: String) -> (baseURL: String, model: String)? {
        if id.hasPrefix(openCodeGoPrefix), id.count > openCodeGoPrefix.count {
            return (ProviderEndpoints.zenGo, String(id.dropFirst(openCodeGoPrefix.count)))
        }
        if id.hasPrefix("opencode/"), id.count > "opencode/".count {
            return (ProviderEndpoints.zen, String(id.dropFirst("opencode/".count)))
        }
        return nil
    }

    /// "an Anthropic", "a Google": the article that goes before a provider's name.
    static func withArticle(_ name: String) -> String {
        guard let first = name.lowercased().first else { return name }
        return ("aeiou".contains(first) ? "an " : "a ") + name
    }
}

// MARK: - Mac actions for the brain (pure parts)

/// Argument checks, app-name matching and the status line for the brain. The NSWorkspace calls live in `MacActions`.
enum MacActionLogic {
    /// Spoken or short names → the app's real name. Keys are normalised (lowercase, no ".app").
    static let aliases: [String: String] = [
        "chrome": "Google Chrome", "firefox": "Firefox", "edge": "Microsoft Edge",
        "vscode": "Visual Studio Code", "vs code": "Visual Studio Code", "code": "Visual Studio Code",
        "settings": "System Settings", "system preferences": "System Settings",
        "word": "Microsoft Word", "excel": "Microsoft Excel", "powerpoint": "Microsoft PowerPoint",
        "term": "Terminal", "iterm": "iTerm", "whatsapp": "WhatsApp", "vlc": "VLC",
    ]

    /// Lowercase, ".app" dropped, spaces collapsed.
    static func normalize(_ name: String) -> String {
        var n = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if n.hasSuffix(".app") { n = String(n.dropLast(4)) }
        return n.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The installed app (one of `installed`, names without ".app") a name means. Exact first, then the
    /// alias, then a single name that starts with it, then a single name that contains it. nil: none or unclear.
    static func match(_ query: String, in installed: [String]) -> String? {
        let q = normalize(query)
        guard !q.isEmpty else { return nil }
        let wanted = aliases[q].map(normalize) ?? q
        if let hit = installed.first(where: { normalize($0) == wanted }) { return hit }
        for test in [{ (n: String) in n.hasPrefix(wanted) }, { (n: String) in n.contains(wanted) }] {
            let hits = installed.filter { test(normalize($0)) }
            if hits.count == 1 { return hits[0] }
        }
        return nil
    }

    /// Up to `limit` installed names near `query`, for the error message.
    static func closest(_ query: String, in installed: [String], limit: Int = 4) -> [String] {
        let q = aliases[normalize(query)].map(normalize) ?? normalize(query)
        guard !q.isEmpty else { return [] }
        let first = String(q.prefix(3))
        let hits = installed.filter { let n = normalize($0); return n.contains(q) || q.contains(n) || n.hasPrefix(first) }
        return Array(hits.sorted().prefix(limit))
    }

    static func appName(from args: [String: Any]) -> String? {
        guard let n = (args["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty, n.count <= 100,
              !n.contains("/"), !n.contains("\u{0}") else { return nil }   // names only, never a path
        return n
    }

    /// `open_url` arguments: an http(s) link, and an optional app name.
    static func urlRequest(from args: [String: Any]) -> (url: URL, app: String?)? {
        guard let url = safeWebURL(args["url"] as? String) else { return nil }
        let app = (args["app"] as? String).flatMap { appName(from: ["name": $0]) }
        return (url, app)
    }

    /// `open_file` arguments: a path (`~` expanded; it must be absolute after that) and `reveal`.
    static func fileRequest(from args: [String: Any], home: String = NSHomeDirectory()) -> (path: String, reveal: Bool)? {
        guard var p = (args["path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty,
              !p.contains("\u{0}") else { return nil }
        if p == "~" { p = home } else if p.hasPrefix("~/") { p = home + String(p.dropFirst(1)) }
        guard p.hasPrefix("/") else { return nil }
        return ((p as NSString).standardizingPath, (args["reveal"] as? Bool) == true)
    }
}

/// Why Mochi's assistant can or cannot run, in one line. One rule for the Settings box and the bar.
enum BrainReadiness {
    enum Kind: Equatable { case anthropicAPI, apiKey, local, opencode, claudeLogin }

    static func status(enabled: Bool, kind: Kind, providerName: String, hasKey: Bool, localAddressSet: Bool,
                       zenSignedIn: Bool, cliFound: Bool) -> (text: String, ok: Bool) {
        guard enabled else { return ("Off. Nothing is sent to any provider.", false) }
        switch kind {
        case .local:
            return localAddressSet ? ("Ready. Runs on your Mac.", true) : ("Connect \(providerName) in Chat first.", false)
        case .opencode:
            return zenSignedIn ? ("Ready.", true) : ("Sign in to OpenCode first (opencode auth login).", false)
        case .claudeLogin:
            return cliFound ? ("Ready.", true) : ("Claude Code not found.", false)
        case .anthropicAPI, .apiKey:
            if hasKey { return ("Ready.", true) }
            if kind == .anthropicAPI, cliFound {
                return ("No Anthropic API key. To use your Claude subscription, pick \u{201C}Claude subscription\u{201D}.", false)
            }
            return ("Add \(BrainModels.withArticle(providerName)) key in Chat first.", false)
        }
    }
}

extension MochiTools {
    /// Names the brain's tools carry when Claude Code sees them: `mcp__coucou__<tool>`. Exactly nine.
    static var claudeBrainAllowedTools: [String] { brainToolNames.map { "mcp__\(serverName)__\($0)" } }

    static let brainRole = "brain"
    static let brainRuntime = "claude-brain"
    static let brainOwner = "mochi-brain"
    /// How long a brain tool call may wait (`ask_user` waits for the user), in milliseconds.
    static let brainToolTimeoutMS = 3_600_000

    /// Added to the environment of the brain's `claude` process. `MCP_TOOL_TIMEOUT` is Claude Code's hard
    /// per-call limit (default far too short for a question to the user); the idle timeout aborts a
    /// call that stays silent, and 0 turns it off. Both verified in the 2.1.295 binary.
    static var claudeBrainEnvironment: [String: String] {
        ["MCP_TOOL_TIMEOUT": String(brainToolTimeoutMS + 100_000), "CLAUDE_CODE_MCP_TOOL_IDLE_TIMEOUT": "0"]
    }

    /// The `claude` command line for Mochi's brain on the user's Claude Code login. One long-lived
    /// stream-json process. Isolation: `--setting-sources ""` loads no user, project or local settings
    /// (so none of the user's hooks, plugins, CLAUDE.md or permission rules), `--strict-mcp-config` keeps
    /// every MCP server but ours out, `--tools ""` removes every built-in tool, `--disable-slash-commands`
    /// removes skills. Never `--bare` (it would stop using the Claude login). The system prompt replaces
    /// Claude Code's own (`--system-prompt`, never `--append-system-prompt`); `--system-prompt-snapshot off`
    /// lets a new Coucou version's prompt apply to an old conversation.
    static func claudeBrainArguments(sessionId: String, resume: Bool, model: String, mcpConfig: String) -> [String] {
        ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
         resume ? "--resume" : "--session-id", sessionId,
         "--model", model,
         "--system-prompt", brainPrompt,
         "--system-prompt-snapshot", "off",
         "--tools", "",
         "--setting-sources", "",
         "--disable-slash-commands",
         "--strict-mcp-config", "--mcp-config", mcpConfig,
         "--allowedTools", claudeBrainAllowedTools.joined(separator: ",")]
    }

    /// `--mcp-config` JSON for the brain: the `nb-hook --mcp` relay, as the brain role.
    static func claudeBrainMCPConfig(hookPath: String) -> String {
        let server: [String: Any] = [
            "command": "/bin/sh",
            "args": [hookPath, "--mcp"],
            "env": ["COUCOU_ROLE": brainRole, "COUCOU_RUNTIME": brainRuntime, "COUCOU_OWNER": brainOwner],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: ["mcpServers": [serverName: server]],
                                                options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// The brain's six tools in MCP form.
    static func brainMCPToolList() -> [[String: Any]] {
        brainTools().map { ["name": $0.name, "description": $0.description, "inputSchema": $0.schema] }
    }

    /// One JSON-RPC message from the brain's MCP client, answered. `call` runs a tool by name with its arguments as JSON text (the same code the
    /// API-key brain uses). nil for a notification.
    @MainActor
    static func brainMCPResponse(to rpc: [String: Any],
                                 call: (String, String) async -> (text: String, isError: Bool)) async -> [String: Any]? {
        guard let id = rpc["id"], let method = rpc["method"] as? String else { return nil }
        func ok(_ result: [String: Any]) -> [String: Any] { ["jsonrpc": "2.0", "id": id, "result": result] }
        switch method {
        case "initialize":
            return ok(["protocolVersion": protocolVersion, "capabilities": ["tools": [String: Any]()],
                       "serverInfo": ["name": serverName, "version": "1"]])
        case "ping":
            return ok([:])
        case "tools/list":
            return ok(["tools": brainMCPToolList()])
        case "tools/call":
            let params = rpc["params"] as? [String: Any] ?? [:]
            guard let name = params["name"] as? String, brainToolNames.contains(name) else {
                return ["jsonrpc": "2.0", "id": id, "error": ["code": -32602, "message": "Unknown tool"]]
            }
            let args = params["arguments"] as? [String: Any] ?? [:]
            let json = (try? JSONSerialization.data(withJSONObject: args, options: [.sortedKeys, .withoutEscapingSlashes]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            let r = await call(name, json)
            return ok(["content": [["type": "text", "text": r.text]], "isError": r.isError])
        default:
            return ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found"]]
        }
    }

    /// The first sentence of a reply (the card line when the brain never called `report`).
    static func firstSentence(_ text: String, limit: Int = maxReportLine) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        var end = flat.endIndex
        var i = flat.startIndex
        while i < flat.endIndex {
            let c = flat[i]
            if ".!?".contains(c) {
                let next = flat.index(after: i)
                if next == flat.endIndex || flat[next] == " " { end = next; break }
            }
            i = flat.index(after: i)
        }
        return String(flat[flat.startIndex..<end].prefix(limit))
    }
}

extension ProjectLaunchLogic {
    /// Every project that fits `query` equally well at the best score (ties are ambiguity). Empty when
    /// nothing fits. The scoring is `match`'s.
    static func candidates(for query: String, in projects: [KnownProject]) -> [KnownProject] {
        let q = normalize(query)
        guard q.count >= 3 else { return [] }
        var best = 0
        var hits: [KnownProject] = []
        for p in projects {
            let n = normalize(p.name)
            let score: Int
            if n == q { score = 4 }
            else if n.hasPrefix(q) || q.hasPrefix(n) && n.count >= 3 { score = 3 }
            else if n.contains(q) || q.contains(n) && n.count >= 4 { score = 2 }
            else if q.count >= 5, distance(q, String(n.prefix(q.count))) <= 2 { score = 1 }
            else { continue }
            if score > best { best = score; hits = [p] } else if score == best { hits.append(p) }
        }
        return hits
    }
}


// MARK: - Pile-up digest

/// When three or more sessions need the user at once, Mochi says so in one line, built from the
/// session store: no model call, no network, so it works with the assistant on or off.
enum MochiDigest {
    static let threshold = 3
    static let cooldown: TimeInterval = 60
    static let maxNames = 4
    static let maxActions = 3
    static let maxLabel = 28
    /// The digest has its own session ("Mochi"), apart from the brain's, so a digest never lands on
    /// a brain turn that is running and the brain's stop never inherits the digest's note.
    static let sessionId = "mochi-digest"
    static let brainSessionId = "mochi-brain"
    /// Mochi's own sessions: never counted or named.
    static func isInternal(_ id: String) -> Bool { id == sessionId || id == brainSessionId }

    /// Approval, question, blocked, or finished and not yet seen. Never Mochi's own sessions.
    static func needsYou(_ s: AgentSession) -> Bool {
        !isInternal(s.id) && s.phase.needsAttention && !(s.phase == .finished && s.finishedSeen)
    }

    static func needCount<S: Sequence>(_ sessions: S) -> Int where S.Element == AgentSession {
        var n = 0
        for s in sessions where needsYou(s) { n += 1 }
        return n
    }

    /// The rule itself, from the count: reached `threshold` since the previous check was below it,
    /// and nothing posted yet or `cooldown` passed.
    static func shouldPost(count: Int, lastPostedAt: Date?, wasBelowThreshold: Bool, now: Date) -> Bool {
        guard wasBelowThreshold, count >= threshold else { return false }
        if let last = lastPostedAt, now.timeIntervalSince(last) < cooldown { return false }
        return true
    }

    /// True once per pile-up. One pass over the sessions.
    static func needsDigest(sessions: [AgentSession], lastPostedAt: Date?, wasBelowThreshold: Bool, now: Date) -> Bool {
        shouldPost(count: needCount(sessions), lastPostedAt: lastPostedAt, wasBelowThreshold: wasBelowThreshold, now: now)
    }

    /// When to post, across checks: remembers the last count, the last post, and a digest put off
    /// because Mochi's own question card was up (it is posted once that card is answered, if the
    /// pile is still 3 or more).
    struct State: Equatable {
        var wasBelowThreshold = true
        var lastPostedAt: Date?
        var deferred = false

        /// `blocked`: the brain's question card is up, so a digest would talk over it.
        mutating func evaluate(count: Int, blocked: Bool, now: Date) -> Bool {
            let cooledDown = lastPostedAt.map { now.timeIntervalSince($0) >= cooldown } ?? true
            let fresh = shouldPost(count: count, lastPostedAt: lastPostedAt, wasBelowThreshold: wasBelowThreshold, now: now)
            let due = fresh || (deferred && count >= threshold && cooledDown)
            wasBelowThreshold = count < threshold
            if count < threshold { deferred = false }
            guard due else { return false }
            if blocked { deferred = true; return false }
            deferred = false
            lastPostedAt = now
            return true
        }
    }

    private enum Group: Int { case needs, done, working }

    private static func group(of s: AgentSession) -> Group? {
        guard !isInternal(s.id) else { return nil }
        switch s.phase {
        case .approval, .question, .blocked: return .needs
        case .finished: return s.finishedSeen ? nil : .done
        case .thinking, .working: return .working
        case .idle: return nil
        }
    }

    /// "bapoojee needs you, coucou is done, docs is still working", with up to 3 buttons that bring
    /// each session that needs you (see `needsYou`) to the main spot. `titles`: session id to the agent's own title, used
    /// instead of the folder name when two sessions share a folder name.
    static func note(sessions: [AgentSession], titles: [String: String]) -> MochiNote {
        let entries = sessions.compactMap { s -> (group: Group, session: AgentSession)? in
            group(of: s).map { ($0, s) }
        }.sorted { a, b in
            if a.group != b.group { return a.group.rawValue < b.group.rawValue }
            if a.group == .working {
                if a.session.lastEventAt != b.session.lastEventAt { return a.session.lastEventAt > b.session.lastEventAt }
                return a.session.id < b.session.id
            }
            let ta = a.session.attentionAt ?? .distantFuture, tb = b.session.attentionAt ?? .distantFuture
            if ta != tb { return ta < tb }
            if a.session.lastEventAt != b.session.lastEventAt { return a.session.lastEventAt < b.session.lastEventAt }
            return a.session.id < b.session.id
        }
        var counts: [String: Int] = [:]
        for e in entries { counts[e.session.workspace, default: 0] += 1 }
        func name(_ s: AgentSession) -> String {
            let base = s.workspace.isEmpty ? "A session" : s.workspace
            guard (counts[s.workspace] ?? 0) > 1, let title = titles[s.id], !title.isEmpty else { return base }
            return title
        }
        func phrase(_ e: (group: Group, session: AgentSession)) -> String {
            switch e.group {
            case .needs: return "\(name(e.session)) needs you"
            case .done: return "\(name(e.session)) is done"
            case .working: return "\(name(e.session)) is still working"
            }
        }
        var parts = entries.prefix(maxNames).map(phrase)
        if entries.count > maxNames { parts.append("+\(entries.count - maxNames) more") }

        var actions: [MochiAction] = []
        var used = Set<String>()
        // Buttons for what needs the user (waiting, or finished and unseen), never for work still running.
        for e in entries where e.group != .working && actions.count < maxActions {
            var label = String(name(e.session).prefix(maxLabel))
            var n = 2
            while !used.insert(label).inserted { label = String(name(e.session).prefix(maxLabel - 2)) + " \(n)"; n += 1 }
            actions.append(MochiAction(label: label, kind: .focus(sessionId: e.session.id)))
        }
        return MochiNote(line: parts.joined(separator: ", "), actions: actions)
    }
}


/// Is Coucou's Claude Code hook installed? Mochi's Claude workers run headless: without the hook,
/// every permission they need is silently refused, so Mochi will not start one.
enum ClaudeHookCheck {
    static let missingCopy = "Mochi needs its Claude Code hooks to show approvals. Install them in Settings \u{2192} Agents \u{2192} Claude Code Hooks."

    /// `settings` is the parsed `~/.claude/settings.json`. Installed = a PermissionRequest hook whose
    /// command is Coucou's relay (the same test `HookServer.hooksNeedUpdate` uses).
    static func isInstalled(settings: [String: Any]?) -> Bool {
        guard let hooks = settings?["hooks"] as? [String: Any],
              let groups = hooks["PermissionRequest"] as? [[String: Any]] else { return false }
        return groups.contains { group in
            (group["hooks"] as? [[String: Any]] ?? []).contains {
                let cmd = $0["command"] as? String ?? ""
                return cmd.contains("NotchBuddy") || cmd.contains("coucou")
            }
        }
    }
}

extension AssistantReply {
    /// The finished card's line, with what a Mochi worker had to skip (a permission nobody answered in time).
    static func headline(_ base: String, missedApprovals: [String]) -> String {
        guard let first = missedApprovals.first else { return base }
        let command = String(first.split(whereSeparator: \.isNewline).first.map(String.init)?.prefix(60) ?? "")
        let extra = missedApprovals.count > 1 ? " (+\(missedApprovals.count - 1) more)" : ""
        return "\(base) Skipped, no answer in time: \(command)\(extra)."
    }
}
