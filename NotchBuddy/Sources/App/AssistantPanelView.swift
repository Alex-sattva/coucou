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

    @ObservedObject private var voice = VoiceInput.shared
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

            AssistantTopRow(session: main, isBar: content == .bar, model: model,
                            barText: $barText, barFocused: $barFocused)
                .frame(height: 44)

            if content != .bar {
                Rectangle()
                    .fill(Color.white.opacity(0.09))
                    .frame(height: 1)
                    .padding(.horizontal, 16)
                    .padding(.top, 6)

                card(for: content, main: main)
                    .agentSwap(key: main?.id)
                    .padding(.top, 7)
                    .padding(.leading, AssistantPanelLayout.contentLeading)
                    .padding(.trailing, 18)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .transition(.opacity)
            }

            // Under the finished card the bar stays available for a follow-up task.
            if case .finished = content {
                AssistantBarField(model: model, text: $barText, focused: $barFocused)
                    .padding(.top, 8)
                    .padding(.leading, AssistantPanelLayout.contentLeading)
                    .padding(.trailing, 16)
                    .frame(height: AssistantMetrics.finishedBar - 8, alignment: .top)
            }

            Spacer(minLength: 0)
        }
        .frame(width: IslandConst.expandedWidth, alignment: .topLeading)
        .background(alignment: .topLeading) {
            if let hex = main?.colorHex { AssistantWash(hex: hex) }
        }
        .overlay(alignment: .bottomLeading) {
            // Wherever the bar shows, its key hints only crowd the text under it.
            if content == .bar { EmptyView() } else if case .finished = content { EmptyView() }
            else if case .question = content { EmptyView() }
            else if case .launch = content { EmptyView() }
            else if case .clarify = content { EmptyView() } else {
                AssistantFooter(content: content, workspace: main?.workspace,
                                onViewSession: model.canViewMainSession ? { model.viewMainSession() } : nil)
                    .padding(.leading, AssistantPanelLayout.contentLeading)
                    .padding(.bottom, 12)
            }
        }
        .foregroundColor(Color(hex: "#F5F6F8"))
        .animation(.easeInOut(duration: 0.2), value: content)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        // A closed panel starts clean: the typed text and a stale error go away with it.
        .onChange(of: model.isOpen) { _, open in
            if !open { barText = ""; model.clearBarError() }
        }
        .onChange(of: barText) { _, _ in model.clearBarError() }
        .onChange(of: barFocused) { _, focused in model.setBarFocused(focused) }
        .onChange(of: model.restoredBarText) { _, text in
            guard let text else { return }
            barText = text
            model.consumeRestoredBarText()
        }
        // The bar shows what the recogniser hears, live.
        .onChange(of: voice.transcript) { _, text in barText = text }
        // The fold exists only while a finished card is on screen, and waits as long as the
        // headline takes to read. Hover, a focused bar or an open diff pause it (the key changes,
        // so the wait restarts when they end).
        .task(id: foldKey(content: content, main: main)) {
            guard let key = foldKey(content: content, main: main), let main else { return }
            try? await Task.sleep(for: .seconds(AssistantReply.foldSeconds(model.headline(for: main))))
            guard !Task.isCancelled else { return }
            model.markSeen(key.sessionId)
        }
    }

    // MARK: - Cards

    @ViewBuilder
    private func card(for content: AssistantPanelContent, main: AgentSession?) -> some View {
        if case .launch = content, let launch = model.pendingLaunch {
            AssistantLaunchCard(launch: launch, model: model)
        } else if case .clarify = content, let clarify = model.pendingClarify {
            AssistantClarifyCard(clarify: clarify, model: model)
        } else if let main {
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
            case .launch, .clarify:
                EmptyView()   // drawn above, with or without a main session
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
        if hovering || barFocused || voice.isActive { return nil }
        return FoldKey(sessionId: main.id, attentionAt: main.attentionAt)
    }
}

enum AssistantPanelLayout {
    /// Content left edge: clears the main Mochi (centre 40, diameter 48).
    static let contentLeading: CGFloat = 72
    /// Main Mochi centre and diameter inside the panel (island coordinates).
    static let mochiCentre = CGPoint(x: 40, y: 64)
    static let mochiDiameter: CGFloat = 48
}

// MARK: - Top row

/// Task line (or the bar), agent chip and mic button.
struct AssistantTopRow: View {
    let session: AgentSession?
    let isBar: Bool
    @ObservedObject var model: AssistantModel
    @Binding var barText: String
    var barFocused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 12) {
            if isBar {
                AssistantBarField(model: model, text: $barText, focused: barFocused)
            } else {
                Text(taskLine)
                    .agentSwap(key: session?.id)
                    .font(.system(size: 15))
                    .foregroundColor(Color(hex: "#C5C8CD"))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let session {
                // In the bar the task line is the text field, so the chip says which session gets the reply.
                AssistantAgentChip(session: session,
                                   title: isBar ? chipTitle(session) : nil,
                                   onOpen: model.canViewMainSession ? { model.viewMainSession() } : nil)
            }
            AssistantMicButton(model: model)
        }
        .padding(.leading, AssistantPanelLayout.contentLeading)
        .padding(.trailing, 16)
    }

    /// The session's title (Claude sidebar / OpenCode name), else the last prompt, else the folder.
    private var taskLine: String {
        guard let session else { return "" }
        if let title = model.title(for: session) { return title }
        if let prompt = session.lastPrompt?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty {
            return prompt.replacingOccurrences(of: "\n", with: " ")
        }
        return session.workspace
    }

    /// The session's title, else its folder.
    private func chipTitle(_ session: AgentSession) -> String? {
        if let title = model.title(for: session) { return title }
        return session.workspace.isEmpty ? nil : session.workspace
    }
}

/// Agent kind name with the session's colour dot, and the session's title when given.
struct AssistantAgentChip: View {
    let session: AgentSession
    /// Shown after the kind, cut to 30 characters. nil = the kind alone.
    var title: String? = nil
    /// Opens the session in Terminal (Claude Code main session). nil = a plain label.
    var onOpen: (() -> Void)? = nil

    var body: some View {
        if let onOpen {
            Button(action: onOpen) { label }
                .buttonStyle(.plain)
                .help("Open this session in Terminal")
        } else {
            label
        }
    }

    private var label: some View {
        HStack(spacing: 6) {
            Circle().fill(Color(hex: session.colorHex)).frame(width: 7, height: 7)
            Text(session.kind.displayName)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(Color(hex: "#C5C8CD"))
                .lineLimit(1)
            if let title {
                Text("· \(Self.shortened(title))")
                    .font(.system(size: 11.5))
                    .foregroundColor(Color(hex: "#8C919B"))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(Color.white.opacity(0.07))
        .clipShape(Capsule())
        .fixedSize()
    }

    /// Cut by characters, not width: the chip keeps its natural size and the text field gives way.
    static func shortened(_ title: String, limit: Int = 30) -> String {
        let flat = title.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return flat.count > limit ? String(flat.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…" : flat
    }
}

/// Click to start listening, click again to stop and send. Red while the microphone is open.
struct AssistantMicButton: View {
    @ObservedObject var model: AssistantModel
    @ObservedObject private var voice = VoiceInput.shared

    var body: some View {
        let on = voice.isActive
        Button { model.toggleVoice() } label: {
            Image(systemName: "mic.fill")
                .font(.system(size: 12))
                .foregroundColor(on ? .white : Color(hex: "#8E939C"))
                .frame(width: 28, height: 28)
                .background(on ? Color(hex: "#F87171") : Color.white.opacity(0.07))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .help(on ? "Send now" : "Talk — sends when you pause (or hold ⌥)")
        .accessibilityLabel(on ? "Stop listening and send" : "Start listening")
    }
}

// MARK: - Bar

/// The text field that starts an OpenCode task in the main session's folder, with its one-line
/// error. Disabled when there is no folder to run in.
struct AssistantBarField: View {
    @ObservedObject var model: AssistantModel
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    @ObservedObject private var voice = VoiceInput.shared

    var body: some View {
        let folder = model.taskFolder
        let target = model.barTarget
        let toMochi = model.barGoesToMochi
        let placeholder = voice.isActive
            ? "Listening…"
            : toMochi ? AssistantBarLogic.placeholder(target: target, workspace: "", toMochi: true)
            : folder.map { AssistantBarLogic.placeholder(target: target, workspace: $0.workspace) }
                ?? AssistantBarLogic.noFolderCopy
        let tag = toMochi ? AssistantBarLogic.tag(target: target, main: model.mainSession, toMochi: true)
            : folder == nil ? nil : AssistantBarLogic.tag(target: target, main: model.mainSession)
        VStack(alignment: .leading, spacing: 1) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .focused(focused)
                .disabled(voice.isActive || model.barStatus != nil)   // with no folder the text can still name a project
                .onSubmit { model.submitTask(text) }
            // Only the surprising case gets a line: text going to a new OpenCode session instead
            // of the agent in the chip. "Same session" is already said by the chip and placeholder.
            if let status = model.barStatus {
                AssistantBarStatusLine(status: status)
            } else if let tag, target == .newTask || toMochi, model.barError == nil {
                Text(tag)
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: target == .newTask || toMochi ? "#8C919B" : "#34D399"))
                    .fixedSize(horizontal: false, vertical: true)
            }
            // No-folder is said by the placeholder; with a folder it is stale.
            if let error = model.barError, error != AssistantBarLogic.noFolderCopy {
                Text(error)
                    .font(.system(size: 11.5))
                    .foregroundColor(Color(hex: "#F87171"))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Under the bar while a request is on its way: "Thinking…", then where it was sent.
struct AssistantBarStatusLine: View {
    let status: AssistantBarLogic.Status

    var body: some View {
        switch status {
        case .thinking:
            Text(AssistantBarLogic.thinkingCopy)
                .font(.system(size: 11.5))
                .foregroundColor(Color(hex: "#8C919B"))
        case .sent(let copy):
            HStack(spacing: 4) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                Text(copy)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 11.5))
            .foregroundColor(Color(hex: "#34D399"))
        }
    }
}

// MARK: - Footer

struct AssistantFooter: View {
    let content: AssistantPanelContent
    let workspace: String?
    /// Claude Code main session: opens it in Terminal (`claude --resume`). nil hides the link.
    var onViewSession: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 16) {
            if content == .approval { hint("⏎", "allow") }
            if let onViewSession {
                Button(action: onViewSession) {
                    HStack(spacing: 4) {
                        Image(systemName: "terminal")
                            .font(.system(size: 10.5))
                        Text("view session")
                    }
                }
                .buttonStyle(.plain)
                .help("Open this Claude Code session in Terminal")
            }
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
