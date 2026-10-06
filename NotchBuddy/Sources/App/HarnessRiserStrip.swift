import SwiftUI

// MARK: - Riser strip (inline approval / question)

/// The prototype's `.riser` — a compact strip that slides in above the composer inside the
/// left card while an agent is blocked waiting for a human.
///
/// This is deliberately NOT the shipping `ApprovalView` / `QuestionView`: those carry their
/// own `CardBackground` and a hardcoded `.padding(.leading, 116)` that reserves the big bot's
/// column, so neither fits `HarnessMetrics.riserHeight` (26 pt). What is shared with them is
/// the *decision path* — every button here ends at the same
/// `HookServer.shared.sendApprovalDecision(_:sessionId:)` / `HookServer.shared.sendQuestionAnswers(_:sessionId:)`
/// call, via `VoiceHarnessModel.resolveApproval(_:)` / `resolveQuestion(_:)`. There is no
/// second decision path, and the model reads the same `AppState.pendingApproval` /
/// `pendingQuestion` (the oldest pending of each) slots the shipping views read, so the two can never disagree.
struct HarnessRiserStrip: View {
    @ObservedObject var model: VoiceHarnessModel

    @State private var questionIndex = 0
    /// One entry per question, parallel to `question.questions`.
    @State private var selections: [[String]] = []

    private var tint: Color {
        model.hasApproval ? Color(hex: "#F5A524") : Color(hex: "#8B5CF6")
    }

    var body: some View {
        HStack(spacing: 7) {
            if let approval = model.approval {
                approvalRow(approval)
            } else if let question = model.question {
                questionRow(question)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .frame(height: HarnessMetrics.riserHeight)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tint.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(tint.opacity(0.28), lineWidth: 1)
        )
        // `initial: true` matters: the strip mounts at the same instant the question
        // appears, so a change-only observer would never run and `selections` would stay
        // empty, making every option tap a silent no-op.
        .onChange(of: model.question, initial: true) { _, newValue in
            questionIndex = 0
            selections = Array(repeating: [String](), count: newValue?.questions.count ?? 0)
        }
    }

    // MARK: Approval

    @ViewBuilder
    private func approvalRow(_ approval: ApprovalInfo) -> some View {
        Circle()
            .fill(Color(hex: "#F5A524"))
            .frame(width: 6, height: 6)
        Text(approval.tool)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundColor(Color(hex: "#F5A524"))
            .lineLimit(1)
        if !approval.command.isEmpty, approval.command != approval.tool {
            Text(approval.command)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundColor(Color(hex: "#8E939C"))
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(-1)
                // The strip is one line tall, so a long command is truncated. The tooltip
                // keeps the full text reachable — a permission must never be approvable
                // only in a form whose dangerous half the user cannot read.
                .help(approval.command)
        }
        Spacer(minLength: 4)
        RiserButton("Deny", tint: Color(hex: "#8E939C"), filled: false) {
            model.resolveApproval("deny", sessionId: approval.sessionId)
        }
        RiserButton("Allow", tint: Color(hex: "#34D399"), filled: true) {
            model.resolveApproval("allow", sessionId: approval.sessionId)
        }
        // Codex rejects updatedPermissions, so "Always" is not offered — same rule as ApprovalView.
        if approval.pillId != "agent_codex" {
            RiserButton("Always", tint: Color(hex: "#8B5CF6"), filled: false) {
                model.resolveApproval("always", sessionId: approval.sessionId)
            }
        }
    }

    // MARK: Question

    @ViewBuilder
    private func questionRow(_ question: AskQuestion) -> some View {
        let count = question.questions.count
        // Clamp before touching the array: a second question can displace the first while
        // this view's `questionIndex` still points past the end of the new one. `.onChange`
        // does reset it, but only *after* this body has been evaluated, so a stale index
        // would trap here rather than recover.
        let index = min(max(0, questionIndex), max(0, count - 1))

        Circle()
            .fill(Color(hex: "#8B5CF6"))
            .frame(width: 6, height: 6)

        if count > 1 {
            Text("\(index + 1)/\(count)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(Color(hex: "#8B5CF6"))
        }

        if let item = count > 0 ? question.questions[index] : nil {
            Text(item.header.isEmpty ? item.question : item.header)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(Color(hex: "#F5F6F8"))
                .lineLimit(1)
            Text(item.question)
                .font(.system(size: 10.5))
                .foregroundColor(Color(hex: "#8E939C"))
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(-1)

            Spacer(minLength: 4)

            // The strip is one line tall: three chips, no free-text field. When the question
            // offers more than that, the third slot becomes a way out to the shipped card
            // rather than a silently dropped option — a question must always be answerable, and
            // the card is the only surface that can express a fourth choice or an "Other…".
            let shown = Array(item.options.prefix(item.options.count > 3 ? 2 : 3))
            ForEach(shown.indices, id: \.self) { optionIndex in
                let option = shown[optionIndex]
                let isChosen = selections.indices.contains(index)
                    && selections[index].contains(option.label)
                RiserButton(option.label, tint: Color(hex: "#8B5CF6"), filled: isChosen) {
                    choose(option.label, item: item, index: index, count: count)
                }
            }

            if shown.count < item.options.count {
                RiserButton("More…", tint: Color(hex: "#8B5CF6"), filled: false) {
                    model.showFullQuestion()
                }
                .help("This question has \(item.options.count) options — open its full card")
            }

            if item.multiSelect {
                RiserButton("Send", tint: Color(hex: "#34D399"), filled: true) {
                    submit()
                }
            }
        }
    }

    /// Toggles (multi-select) or picks (single-select) a label, advancing or submitting.
    private func choose(_ label: String, item: AskQuestionItem, index: Int, count: Int) {
        guard selections.indices.contains(index) else { return }
        if item.multiSelect {
            if let at = selections[index].firstIndex(of: label) {
                selections[index].remove(at: at)
            } else {
                selections[index].append(label)
            }
            return
        }
        selections[index] = [label]
        if index + 1 < count {
            questionIndex = index + 1
        } else {
            submit()
        }
    }

    private func submit() {
        model.resolveQuestion(selections)
    }
}

// MARK: - Compact button

/// A 20 pt pill sized for the riser strip. The shipping `PrimaryButton`/`SecondaryButton` are
/// 12.5 pt type with their own vertical padding and do not fit a 26 pt strip.
private struct RiserButton: View {
    let title: String
    let tint: Color
    let filled: Bool
    let action: () -> Void

    init(_ title: String, tint: Color, filled: Bool, action: @escaping () -> Void) {
        self.title = title
        self.tint = tint
        self.filled = filled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10.5, weight: .medium))
                .lineLimit(1)
                .foregroundColor(filled ? Color(hex: "#0B0C0E") : tint)
                .padding(.horizontal, 8)
                .frame(height: 20)
                .background(
                    Capsule().fill(filled ? tint : tint.opacity(0.14))
                )
                .overlay(
                    Capsule().stroke(tint.opacity(filled ? 0 : 0.35), lineWidth: 1)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
