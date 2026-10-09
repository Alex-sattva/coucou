import SwiftUI

// The need cards of the assistant panel. Each one is bound to the session it was built for:
// a button acts on THAT session id, never on "whatever is main at click time".

private enum PanelColor {
    static let text = Color(hex: "#F5F6F8")
    static let dim = Color(hex: "#8E939C")
    static let faint = Color(hex: "#6B7079")
    static let amberText = Color(hex: "#FBD38D")
    static let amberFill = Color(hex: "#1A1408")
    static let amberLine = Color(hex: "#3A2A0A")
    static let red = Color(hex: "#F87171")
    static let green = Color(hex: "#34D399")
}

// MARK: - Approval

struct AssistantApprovalCard: View {
    let session: AgentSession
    let info: ApprovalInfo
    @ObservedObject var model: AssistantModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let n = session.steps.count
            Text("✓ \(n) \(n == 1 ? "step" : "steps") done")
                .font(.system(size: 12.5))
                .foregroundColor(PanelColor.faint)

            VStack(alignment: .leading, spacing: 8) {
                // The whole command, wrapped: what is approved must be readable, never cut.
                // A very long one scrolls inside the box.
                ScrollView(.vertical, showsIndicators: true) {
                    question
                        .font(.system(size: 13.5))
                        .foregroundColor(PanelColor.amberText)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 66)
                HStack(spacing: 10) {
                Spacer(minLength: 0)
                SecondaryButton("Deny") { decide("deny") }
                // Codex rejects updatedPermissions, so "Always" is not offered (same rule as ApprovalView).
                if info.pillId != "agent_codex" {
                    SecondaryButton("Always") { decide("always") }
                }
                // ⏎ works only while this card is on screen and the island panel is the key window
                // (a SwiftUI default action fires nowhere else), so nothing approves blind.
                PrimaryButton("Allow", kbd: "⏎") { decide("allow") }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(PanelColor.amberFill)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(PanelColor.amberLine))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private var question: Text {
        let command = info.command.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        if command.isEmpty {
            return Text("Can I use ") + Text(info.tool).font(.system(size: 12, design: .monospaced)).foregroundColor(.white) + Text("?")
        }
        return Text("Can I run ") + Text(command).font(.system(size: 12, design: .monospaced)).foregroundColor(.white) + Text("?")
    }

    private func decide(_ decision: String) {
        // The card was built for `info.sessionId`; act on it only while it is still main and open.
        guard model.isOpen, model.mainApproval?.sessionId == info.sessionId else { return }
        HookServer.shared.sendApprovalDecision(decision, sessionId: info.sessionId)
    }
}

// MARK: - Question

struct AssistantQuestionCard: View {
    let pending: PendingQuestion
    @ObservedObject var model: AssistantModel

    @State private var index = 0
    @State private var selections: [[String]]
    @State private var otherTexts: [String]
    @State private var showOther: [Bool]
    @FocusState private var otherFocused: Bool

    init(pending: PendingQuestion, model: AssistantModel) {
        self.pending = pending
        self.model = model
        let n = pending.question.questions.count
        _selections = State(initialValue: Array(repeating: [], count: n))
        _otherTexts = State(initialValue: Array(repeating: "", count: n))
        _showOther = State(initialValue: Array(repeating: false, count: n))
    }

    private var questions: [AskQuestionItem] { pending.question.questions }

    var body: some View {
        if questions.isEmpty {
            EmptyView()
        } else {
            let qi = min(index, questions.count - 1)
            let item = questions[qi]
            let isLast = qi == questions.count - 1
            let other = showOther[qi]
            let chosen = !selections[qi].isEmpty || (other && !otherTexts[qi].isEmpty)

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Text(item.header.isEmpty ? "Question" : item.header)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(PanelColor.faint)
                    Spacer(minLength: 4)
                    if questions.count > 1 {
                        Text("\(qi + 1)/\(questions.count)")
                            .font(.system(size: 10.5))
                            .foregroundColor(PanelColor.faint)
                    }
                    Button {
                        HookServer.shared.sendQuestionAsk(sessionId: pending.sessionId)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "terminal").font(.system(size: 10))
                            Text("Reply in terminal")
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5))
                    .foregroundColor(PanelColor.faint)
                }
                .frame(height: 14)

                // Question and descriptions wrap in full, never cut; when they don't fit the
                // island, they scroll (with a visible scroll bar so the rest can be found).
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(item.question)
                            .font(.system(size: 13.5, weight: .semibold))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
                            .padding(.bottom, 8)
                        ForEach(Array(item.options.enumerated()), id: \.offset) { idx, opt in
                            optionRow(opt, idx: idx, qi: qi, item: item, isLast: isLast)
                        }
                    }
                    .padding(.trailing, 10)   // room for the scroll bar
                }
                .frame(maxHeight: .infinity)

                otherRow(qi: qi, item: item, isLast: isLast, chosen: chosen)
            }
        }
    }

    private func optionRow(_ opt: AskQuestionOption, idx: Int, qi: Int, item: AskQuestionItem, isLast: Bool) -> some View {
        let selected = selections[qi].contains(opt.label)
        return Button {
            if item.multiSelect { toggle(qi: qi, label: opt.label) }
            else { select(qi: qi, label: opt.label, isLast: isLast) }
        } label: {
            HStack(spacing: 8) {
                Text("\(idx + 1)")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(PanelColor.faint)
                    .frame(width: 14)
                // Label on top, its description under it: side by side, the description was cut off.
                VStack(alignment: .leading, spacing: 1) {
                    Text(opt.label)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundColor(selected ? Color(hex: "#67E8F9") : PanelColor.text)
                        .fixedSize(horizontal: false, vertical: true)
                    if !opt.description.isEmpty {
                        Text(opt.description)
                            .font(.system(size: 11))
                            .foregroundColor(PanelColor.faint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 5)
            .frame(minHeight: AssistantMetrics.questionRow - 2)
            .padding(.horizontal, 8)
            .background(selected ? Color(hex: "#22D3EE").opacity(0.16) : Color.white.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .padding(.vertical, 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(KeyEquivalent(Character(String(idx + 1))), modifiers: [])
    }

    @ViewBuilder
    private func otherRow(qi: Int, item: AskQuestionItem, isLast: Bool, chosen: Bool) -> some View {
        HStack(spacing: 8) {
            if showOther[qi] {
                TextField("Your answer…", text: $otherTexts[qi])
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .focused($otherFocused)
                    .onAppear { otherFocused = true }
                    .onSubmit { commitOther(qi: qi, isLast: isLast) }
                    .onExitCommand { showOther[qi] = false }
                    .padding(.horizontal, 8)
                    .frame(height: AssistantMetrics.questionRow - 2)
                    .background(Color.white.opacity(0.07))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
            } else {
                Button { showOther[qi] = true } label: {
                    Text("Other…")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundColor(PanelColor.dim)
                        .padding(.leading, 30)   // lines up with the option labels
                        .padding(.trailing, 8)
                        .frame(height: AssistantMetrics.questionRow)
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
            if showOther[qi] {
                PrimaryButton(isLast ? "Send" : "Next") { commitOther(qi: qi, isLast: isLast) }
                    .disabled(otherTexts[qi].isEmpty)
                    .opacity(otherTexts[qi].isEmpty ? 0.4 : 1)
            } else if item.multiSelect {
                PrimaryButton(isLast ? "Send" : "Next") { advance(qi: qi, isLast: isLast) }
                    .disabled(!chosen)
                    .opacity(chosen ? 1 : 0.4)
            }
        }
        .frame(height: AssistantMetrics.questionRow)
    }

    // MARK: Answer building (AskQuestion.buildAnswers is the shared logic)

    private func toggle(qi: Int, label: String) {
        if let i = selections[qi].firstIndex(of: label) { selections[qi].remove(at: i) }
        else { selections[qi].append(label) }
    }

    private func select(qi: Int, label: String, isLast: Bool) {
        selections[qi] = [label]
        advance(qi: qi, isLast: isLast)
    }

    private func commitOther(qi: Int, isLast: Bool) {
        let text = otherTexts[qi]
        guard !text.isEmpty else { return }
        selections[qi] = [text]
        showOther[qi] = false
        advance(qi: qi, isLast: isLast)
    }

    private func advance(qi: Int, isLast: Bool) {
        if isLast { send() } else { index = qi + 1 }
    }

    private func send() {
        // Send only to the session that still owns exactly this question.
        guard model.isOpen, let current = model.mainQuestion,
              current.sessionId == pending.sessionId, current.question == pending.question else { return }
        let answers = AskQuestion.buildAnswers(questions: questions, selections: selections)
        HookServer.shared.sendQuestionAnswers(answers, sessionId: pending.sessionId)
    }
}

// MARK: - Blocked

struct AssistantBlockedCard: View {
    let session: AgentSession
    @ObservedObject var model: AssistantModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(session.failure?.headline ?? SessionFailure().headline)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(PanelColor.red)

            ScrollView(.vertical, showsIndicators: true) {
                Text(detail)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Color(hex: "#E8E9EC"))
                    .fixedSize(horizontal: false, vertical: true)   // the full error, scrolling if long
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 64)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(Color.white.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.06)))
                .clipShape(RoundedRectangle(cornerRadius: 10))

            #if !APPSTORE
            HStack {
                // Claude Code cannot be resumed from here, so there is no "Try again".
                PrimaryButton("Open in terminal") {
                    TerminalJump.activate()
                    model.dismiss()
                }
            }
            #endif
        }
    }

    /// What the agent said about the failure, else the last failed step, else the final line,
    /// else the last thing it did.
    private var detail: String {
        if let message = session.failure?.message, !message.isEmpty { return message }
        if let failed = session.steps.last(where: { $0.hasPrefix("⚠") }) { return failed }
        if let text = session.reply, !text.isEmpty { return DiffEngine.toOneLine(text) }
        return session.steps.last(where: { !$0.isDiffStep }) ?? "No details were reported."
    }
}

// MARK: - Finished

struct AssistantFinishedCard: View {
    let session: AgentSession
    @ObservedObject var model: AssistantModel

    var body: some View {
        let actions = model.mochiActions(for: session)
        VStack(alignment: .leading, spacing: 6) {
            // One line in Mochi's own words; the whole report is one click away (Open session).
            // Changed files and diffs are not shown here: they belong in the session itself.
            Text(headline)
                .font(.system(size: 15, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)   // wraps in full, never cut
                .textSelection(.enabled)

            if !actions.isEmpty {
                // Next steps the session suggested for Mochi (`MochiAware`); each runs on click only.
                HStack(spacing: 6) {
                    ForEach(actions) { action in
                        MochiActionChip(action: action) { model.perform(action, in: session) }
                    }
                }
                .frame(height: AssistantMetrics.actionRow - 4, alignment: .leading)
            }

            HStack(spacing: 8) {
                if model.canViewSession(session) {
                    SecondaryButton("Open session") { model.viewSession(session) }
                }
                PrimaryButton("Got it") { model.markSeen(session.id) }
            }
            .padding(.top, 2)
        }
    }

    private var headline: String {
        model.headline(for: session)
    }
}

/// One suggested next step: an icon for what the click does, the label, and the full target
/// (link, path, message) on hover so the user can check it before clicking.
struct MochiActionChip: View {
    let action: MochiAction
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10.5, weight: .semibold))
                Text(action.label).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.white.opacity(0.09))
            .foregroundColor(Color(hex: "#F1F2F4"))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(detail)
    }

    private var icon: String {
        switch action.kind {
        case .openURL: return "safari"
        case .openFile: return "doc"
        case .reveal: return "folder"
        case .reply: return "arrow.turn.down.right"
        case .copy: return "doc.on.doc"
        case .focus: return "arrow.right.circle"
        }
    }

    private var detail: String {
        switch action.kind {
        case .openURL(let s): return "Open \(s)"
        case .openFile(let s): return "Open \(s)"
        case .reveal(let s): return "Show \(s) in Finder"
        case .reply(let s): return "Send to the session: \(s)"
        case .copy(let s): return "Copy: \(s)"
        case .focus: return "Show this session\u{2019}s card"
        }
    }
}

// MARK: - Launch

/// "Start Claude Code in Bapoojee-production": shown after "work on <project>", nothing opens
/// until the click. The other button switches the CLI for this launch only.
struct AssistantLaunchCard: View {
    let launch: PendingLaunch
    @ObservedObject var model: AssistantModel
    @ObservedObject private var state = AppState.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            (Text("Start ") + Text(launch.cli.displayName).foregroundColor(.white)
                + Text(" in ") + Text(launch.project.name).foregroundColor(.white))
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(PanelColor.dim)
                .fixedSize(horizontal: false, vertical: true)

            if let prompt = launch.prompt {
                // Shown in full: this is exactly what the new session receives first.
                Text(prompt)
                    .font(.system(size: 12.5))
                    .foregroundColor(Color(hex: "#E8E9EC"))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            Text("\(displayPath) \u{00B7} opens in \(terminalName)")
                .font(.system(size: 11.5))
                .foregroundColor(PanelColor.faint)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                PrimaryButton(launch.prompt == nil ? "Start" : "Start and send") { model.confirmLaunch() }
                    .keyboardShortcut(.defaultAction)
                SecondaryButton("Use \(other.displayName) instead") { model.switchLaunchCLI() }
            }
            .padding(.top, 2)
        }
    }

    private var other: ProjectCLI { launch.cli == .claudeCode ? .openCode : .claudeCode }

    private var displayPath: String {
        let home = NSHomeDirectory()
        let p = launch.project.path
        return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
    }

    private var terminalName: String {
        let t = TerminalApp(rawValue: state.terminalApp) ?? .terminal
        return (t.appURL != nil ? t : .terminal).displayName
    }
}

// MARK: - Clarify

/// The router could not tell which project or session was meant. Rows look like the question
/// card's options; everything wraps, nothing is cut off. 1–4 pick, Esc closes the panel.
struct AssistantClarifyCard: View {
    let clarify: PendingClarify
    @ObservedObject var model: AssistantModel

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                Text(clarify.question)
                    .font(.system(size: 13.5, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                    .padding(.bottom, 8)
                ForEach(Array(clarify.choices.enumerated()), id: \.offset) { idx, choice in
                    AssistantChoiceRow(number: idx + 1, label: choice.label) { model.pickClarify(idx) }
                }
            }
            .padding(.trailing, 10)
        }
        .frame(maxHeight: .infinity)
    }
}

/// One numbered, clickable row with a label that wraps in full.
struct AssistantChoiceRow: View {
    let number: Int
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text("\(number)")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(PanelColor.faint)
                    .frame(width: 14)
                Text(label)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundColor(PanelColor.text)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 5)
            .frame(minHeight: AssistantMetrics.questionRow - 2)
            .padding(.horizontal, 8)
            .background(Color.white.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .padding(.vertical, 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: [])
    }
}
