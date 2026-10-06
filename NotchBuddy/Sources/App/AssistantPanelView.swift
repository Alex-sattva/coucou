import SwiftUI

/// The expanded assistant panel. It replaces the home and the approval / question / error /
/// finished cards. Layout (variant D "Quiet Spotlight" of design/prototype/assistant-layer-prototype.html):
///
///   header band (tabs, gear)                      y   8..42   (the shipping IslandHeader, unchanged)
///   top row: [main Mochi at (40, 64)] task line · agent chip · mic      y  42..86
///   hairline                                      y  92
///   need card, one per main-session phase         y 100..
///   footer: key hints                             bottom 12
///
/// The main Mochi is NOT drawn here: it is the one `AssistantMainMochi` instance that lives in
/// `IslandContainer` and moves between the strip and this slot. This view only leaves room for it.
struct AssistantPanelView: View {
    @ObservedObject var model: AssistantModel
    @ObservedObject var state: AppState

    @State private var hovering = false
    @State private var barText = ""
    @FocusState private var barFocused: Bool

    var body: some View {
        let main = model.mainSession
        let content = model.panelContent

        VStack(spacing: 0) {
            IslandHeader(state: state)
                .frame(height: 34)
                .padding(.top, 8)

            AssistantTopRow(session: main, isBar: content == .bar,
                            barText: $barText, barFocused: $barFocused,
                            onSubmit: { model.dismiss() })
                .frame(height: 44)

            if content != .bar {
                Rectangle()
                    .fill(Color.white.opacity(0.09))
                    .frame(height: 1)
                    .padding(.horizontal, 16)
                    .padding(.top, 6)

                card(for: content, main: main)
                    .padding(.top, 7)
                    .padding(.leading, AssistantPanelLayout.contentLeading)
                    .padding(.trailing, 18)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .transition(.opacity)
            }

            Spacer(minLength: 0)
        }
        .frame(width: IslandConst.expandedWidth, alignment: .topLeading)
        .overlay(alignment: .bottomLeading) {
            AssistantFooter(content: content, workspace: main?.workspace)
                .padding(.leading, AssistantPanelLayout.contentLeading)
                .padding(.bottom, 12)
        }
        .foregroundColor(Color(hex: "#F5F6F8"))
        .animation(.easeInOut(duration: 0.2), value: content)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        // The 8 s fold exists only while a finished card is on screen. Hover, a focused bar or an
        // open diff pause it (the key changes, so the wait restarts when they end).
        .task(id: foldKey(content: content, main: main)) {
            guard let key = foldKey(content: content, main: main) else { return }
            try? await Task.sleep(for: .seconds(AssistantPanelLayout.finishedFoldSeconds))
            guard !Task.isCancelled else { return }
            model.markSeen(key.sessionId)
        }
    }

    // MARK: - Cards

    @ViewBuilder
    private func card(for content: AssistantPanelContent, main: AgentSession?) -> some View {
        if let main {
            switch content {
            case .bar:
                EmptyView()
            case .approval:
                if let info = model.mainApproval {
                    AssistantApprovalCard(session: main, info: info, model: model)
                }
            case .question:
                if let pending = model.mainQuestion {
                    AssistantQuestionCard(pending: pending, model: model)
                        .id("\(pending.sessionId)-\(pending.arrivedAt.timeIntervalSince1970)")
                }
            case .blocked:
                AssistantBlockedCard(session: main, model: model)
            case .finished, .diff:
                AssistantFinishedCard(session: main, model: model)
            }
        }
    }

    // MARK: - Fold

    private struct FoldKey: Hashable {
        let sessionId: String
        let attentionAt: Date?
    }

    private func foldKey(content: AssistantPanelContent, main: AgentSession?) -> FoldKey? {
        guard case .finished = content, let main else { return nil }
        if hovering || barFocused { return nil }
        return FoldKey(sessionId: main.id, attentionAt: main.attentionAt)
    }
}

enum AssistantPanelLayout {
    /// Content left edge: clears the main Mochi (centre 40, diameter 48).
    static let contentLeading: CGFloat = 72
    /// Main Mochi centre and diameter inside the panel (island coordinates).
    static let mochiCentre = CGPoint(x: 40, y: 64)
    static let mochiDiameter: CGFloat = 48
    static let finishedFoldSeconds: Double = 8
}

// MARK: - Top row

/// Task line (or the bar), agent chip and mic button.
struct AssistantTopRow: View {
    let session: AgentSession?
    let isBar: Bool
    @Binding var barText: String
    var barFocused: FocusState<Bool>.Binding
    let onSubmit: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if isBar {
                // Step 10 launches the OpenCode task. Until then Enter only closes the panel.
                TextField(placeholder, text: $barText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17))
                    .focused(barFocused)
                    .disabled(session == nil)
                    .onSubmit(onSubmit)
            } else {
                Text(taskLine)
                    .font(.system(size: 15))
                    .foregroundColor(Color(hex: "#C5C8CD"))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let session { AssistantAgentChip(session: session) }
            AssistantMicButton()
        }
        .padding(.leading, AssistantPanelLayout.contentLeading)
        .padding(.trailing, 16)
    }

    private var taskLine: String {
        guard let session else { return "" }
        if let prompt = session.lastPrompt?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty {
            return prompt.replacingOccurrences(of: "\n", with: " ")
        }
        return session.workspace
    }

    private var placeholder: String {
        guard let session else { return "Open a project window first" }
        return "New OpenCode task in \(session.workspace)…"
    }
}

extension AgentKind {
    var displayName: String {
        switch self {
        case .claudeCode:   return "Claude Code"
        case .openCode:     return "OpenCode"
        case .codex:        return "Codex"
        case .gemini:       return "Gemini"
        case .cursor:       return "Cursor"
        case .antigravity:  return "Antigravity"
        case .other:        return "Agent"
        }
    }
}

/// Agent kind name with the session's colour dot.
struct AssistantAgentChip: View {
    let session: AgentSession

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(Color(hex: session.colorHex)).frame(width: 7, height: 7)
            Text(session.kind.displayName)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(Color(hex: "#C5C8CD"))
                .lineLimit(1)
        }
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(Color.white.opacity(0.07))
        .clipShape(Capsule())
        .fixedSize()
    }
}

/// Voice arrives in Step 11; until then the button is drawn but does nothing.
struct AssistantMicButton: View {
    var body: some View {
        Image(systemName: "mic.fill")
            .font(.system(size: 12))
            .foregroundColor(Color(hex: "#8E939C"))
            .frame(width: 28, height: 28)
            .background(Color.white.opacity(0.07))
            .clipShape(Circle())
            .opacity(0.6)
            .allowsHitTesting(false)
            .help("Voice is not available yet")
    }
}

// MARK: - Footer

struct AssistantFooter: View {
    let content: AssistantPanelContent
    let workspace: String?

    var body: some View {
        HStack(spacing: 16) {
            if content == .approval { hint("⏎", "allow") }
            hint("esc", "hide")
            if let workspace { hint("/", "talk to \(workspace)") }
        }
        .font(.system(size: 11.5))
        .foregroundColor(Color(hex: "#6B7079"))
        .lineLimit(1)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text(key)
                .font(.system(size: 10.5, design: .monospaced))
                .padding(.horizontal, 4)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.2)))
            Text(label)
        }
    }
}
