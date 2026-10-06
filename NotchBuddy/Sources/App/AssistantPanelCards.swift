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

            HStack(spacing: 10) {
                question
                    .font(.system(size: 13.5))
                    .foregroundColor(PanelColor.amberText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
                    Button("Reply in terminal") {
                        HookServer.shared.sendQuestionAsk(sessionId: pending.sessionId)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5))
                    .foregroundColor(PanelColor.faint)
                    .underline()
                }
                .frame(height: 14)

                Text(item.question)
                    .font(.system(size: 13.5, weight: .semibold))
                    .lineLimit(2)
                    .frame(height: 34, alignment: .topLeading)

                ForEach(Array(item.options.enumerated()), id: \.offset) { idx, opt in
                    optionRow(opt, idx: idx, qi: qi, item: item, isLast: isLast)
                }

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
                Text(opt.label)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundColor(selected ? Color(hex: "#67E8F9") : PanelColor.text)
                if !opt.description.isEmpty {
                    Text(opt.description)
                        .font(.system(size: 11.5))
                        .foregroundColor(PanelColor.faint)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
            .frame(height: AssistantMetrics.questionRow)
            .padding(.horizontal, 8)
            .background(selected ? Color(hex: "#22D3EE").opacity(0.16) : Color.white.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .padding(.vertical, 1)
            .frame(height: AssistantMetrics.questionRow)
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
                        .padding(.horizontal, 8)
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
            Text("I hit an error I can't get past on my own.")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(PanelColor.red)

            Text(detail)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(Color(hex: "#E8E9EC"))
                .lineLimit(3)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
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

    /// The last failed step, else the final line, else the last thing it did.
    private var detail: String {
        if let failed = session.steps.last(where: { $0.hasPrefix("⚠") }) { return failed }
        if let line = session.finalLine, !line.isEmpty { return line }
        return session.steps.last(where: { !$0.isDiffStep }) ?? "No details were reported."
    }
}

// MARK: - Finished

struct AssistantFinishedCard: View {
    let session: AgentSession
    @ObservedObject var model: AssistantModel
    @State private var diffPath: String?

    var body: some View {
        content
            // ⌘E (shipping shortcut) toggles the diff of the first changed file.
            .onReceive(NotificationCenter.default.publisher(for: .islandToggleDiff)) { _ in
                let files = model.changedFiles(for: session.id)
                guard !files.isEmpty || model.showsDiff else { return }
                if model.showsDiff { model.setShowsDiff(false) }
                else { diffPath = files.first?.path; model.setShowsDiff(true) }
            }
    }

    @ViewBuilder
    private var content: some View {
        let files = model.changedFiles(for: session.id)
        if model.showsDiff, let file = files.first(where: { $0.path == diffPath }) ?? files.first {
            DiffCardView(diff: file.diff, onDismiss: { model.setShowsDiff(false) })
                .padding(.leading, -36)          // DiffCardView reserves 108 pt for the old bot column
                .frame(height: AssistantMetrics.diff - 100 - 30, alignment: .topLeading)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text(headline)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(2)
                    .truncationMode(.tail)

                ForEach(files.prefix(AssistantMetrics.maxFileRows)) { file in
                    Button {
                        diffPath = file.path
                        model.setShowsDiff(true)
                    } label: {
                        HStack(spacing: 8) {
                            Text(file.name)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(Color(hex: "#C5C8CD"))
                                .lineLimit(1)
                            Text("+\(file.added)")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundColor(Color(hex: "#22C55E"))
                            Text("−\(file.removed)")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundColor(Color(hex: "#F4505E"))
                            Spacer(minLength: 0)
                        }
                        .frame(height: AssistantMetrics.fileRow - 3)
                    }
                    .buttonStyle(.plain)
                }
                if files.count > AssistantMetrics.maxFileRows {
                    Text("+\(files.count - AssistantMetrics.maxFileRows) more")
                        .font(.system(size: 11))
                        .foregroundColor(PanelColor.faint)
                }

                HStack(spacing: 8) {
                    if !files.isEmpty {
                        SecondaryButton("Open diff") {
                            diffPath = files.first?.path
                            model.setShowsDiff(true)
                        }
                    }
                    PrimaryButton("Got it") { model.markSeen(session.id) }
                }
                .padding(.top, 2)
            }
        }
    }

    private var headline: String {
        if let line = session.finalLine?.trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty { return line }
        return "Done."
    }
}
