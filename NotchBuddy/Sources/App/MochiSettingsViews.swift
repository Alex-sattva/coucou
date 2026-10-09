import SwiftUI

#if !APPSTORE

/// Settings → General → "Mochi assistant": Mochi's own model, independent of Chat. Off until the user
/// turns it on. Same rows and look as the neighbouring boxes.
struct MochiAssistantSettingsBox: View {
    @ObservedObject var state: AppState

    private var status: (text: String, ok: Bool) { MochiBrain.shared.status }

    var body: some View {
        GroupBox("Mochi assistant") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Let Mochi understand, ask and delegate", isOn: $state.mochiBrainEnabled)
                Picker("Mochi thinks with", selection: $state.mochiBrainProvider) {
                    ForEach(BrainProvider.all, id: \.self) { Text($0.displayName).tag($0) }
                }
                .frame(maxWidth: 360)
                BrainModelPicker(state: state)
                let current = status
                Text(current.text)
                    .font(.caption)
                    .foregroundStyle(current.ok ? Color.green : Color.secondary)
                Text("Independent of Chat. Once on, Mochi sends what you say, your project names and what your agents are doing to the provider you pick here (nowhere, with Ollama or LM Studio). It can open apps, links and files on your Mac when you ask, reads none of your files and runs no command: work happens in your agents. With it on, \u{201C}Start\u{201D} on a project runs the agent in the background instead of opening a terminal.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if state.mochiBrainProvider == .claudeLogin {
                    Text("Claude subscription (Claude Code login) runs the Claude Code you already have installed, in a private folder of its own with none of your hooks, tools or settings. Mochi\u{2019}s messages go to Anthropic through your own Claude login and count against your Claude Code usage. Coucou never reads your Claude credentials.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("Clear Mochi\u{2019}s conversation") { MochiBrain.shared.reset() }
                    .buttonStyle(.bordered)
            }
            .padding(6)
        }
    }
}

/// The model row of the Mochi assistant box: a menu of the provider's models with "Other…" last, which
/// shows the text field for a custom id. Anthropic and the Claude Code login use a fixed list. The others
/// reuse Chat's model list (`AppState.fetchModelsIfNeeded`); it is fetched only when the user picks
/// "Load models…" in this menu, never in the background, and stays cached for the session. If that fails
/// the text field shows instead.
struct BrainModelPicker: View {
    @ObservedObject var state: AppState
    @State private var custom = false

    private static let otherTag = "\u{1}other"
    private static let loadTag = "\u{1}load"

    private var provider: BrainProvider { state.mochiBrainProvider }
    private var chatProvider: ChatProvider? { if case .chat(let p) = provider { return p } else { return nil } }

    private var models: [(id: String, label: String)] {
        if let fixed = provider.fixedModels { return fixed }
        guard let p = chatProvider, let list = state.fetchedProviderModels[p] else { return [] }
        // OpenCode: Go models only (the brain sends them to the Go gateway).
        return p == .opencode
            ? list.filter { BrainModels.isOpenCodeGo($0.id) && !state.disabledOpencodeModels.contains($0.id) } : list
    }
    private var loading: Bool { chatProvider.map { state.loadingProviderModels.contains($0) } ?? false }
    private var loadFailed: Bool {
        guard provider.fixedModels == nil, let p = chatProvider else { return false }
        return models.isEmpty && !loading && state.providerModelFetchError[p] != nil
    }

    private var current: String { state.mochiBrainModel.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// A stored id the list does not hold (and that is not the default) is a custom one.
    private var isCustomValue: Bool {
        !current.isEmpty && current != provider.defaultModel && !models.contains { $0.id == current }
    }
    private var showsField: Bool { custom || loadFailed || isCustomValue }
    private var effective: String { current.isEmpty ? provider.defaultModel : current }

    private var selection: Binding<String> {
        Binding(
            get: { showsField ? Self.otherTag : effective },
            set: { value in
                switch value {
                case Self.otherTag: custom = true
                case Self.loadTag: if let p = chatProvider { state.fetchModelsIfNeeded(for: p, clampChat: false) }
                default: custom = false; state.mochiBrainModel = value
                }
            })
    }

    var body: some View {
        Picker("Model", selection: selection) {
            ForEach(models, id: \.id) { m in
                Text(m.label == m.id ? m.id : "\(m.label) (\(m.id))").tag(m.id)
            }
            // The default shows while the list is not loaded, so the menu is never empty.
            if provider.defaultModel.isEmpty {
                // No default (OpenCode Go): a placeholder row until one is picked.
                Text("Choose a model\u{2026}").tag("")
            } else if !models.contains(where: { $0.id == provider.defaultModel }) {
                Text(provider.defaultModel).tag(provider.defaultModel)
            }
            if provider.fixedModels == nil, models.isEmpty {
                Divider()
                if loading { Text("Loading\u{2026}").tag("\u{1}loading").disabled(true) }
                else { Text("Load models\u{2026}").tag(Self.loadTag) }
            }
            Divider()
            Text("Other\u{2026}").tag(Self.otherTag)
        }
        .frame(maxWidth: 360)
        .onChange(of: state.mochiBrainProvider) { _, _ in
            // Another provider: its own default model, and the custom field closed.
            custom = false
            state.mochiBrainModel = ""
        }
        if showsField {
            TextField(provider.defaultModel, text: $state.mochiBrainModel)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 360)
        }
        if loadFailed, let p = chatProvider, let message = state.providerModelFetchError[p] {
            Text("\(message) Type a model id instead.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Settings → Agents → "Worker models": the model each agent works with when Mochi starts it.
/// Empty = the agent's own default.
struct WorkerModelsSettingsBox: View {
    @ObservedObject var state: AppState

    var body: some View {
        GroupBox("Worker models") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Claude Code", selection: $state.workerModelClaude) {
                    Text("Claude Code default").tag("")
                    ForEach(["sonnet", "opus", "haiku"], id: \.self) { Text($0.capitalized).tag($0) }
                }
                .frame(maxWidth: 280)
                if let models = state.fetchedProviderModels[.opencode] {
                    Picker("OpenCode", selection: $state.workerModelOpenCode) {
                        Text("OpenCode default").tag("")
                        if !state.workerModelOpenCode.isEmpty, !models.contains(where: { $0.id == state.workerModelOpenCode }) {
                            Text(state.workerModelOpenCode).tag(state.workerModelOpenCode)
                        }
                        ForEach(models.filter { !state.disabledOpencodeModels.contains($0.id) }, id: \.id) { m in
                            Text(m.label == m.id ? m.id : "\(m.label) (\(m.id))").tag(m.id)
                        }
                    }
                    .frame(maxWidth: 420)
                } else {
                    HStack(spacing: 8) {
                        TextField("OpenCode model (provider/model)", text: $state.workerModelOpenCode)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 280)
                        Button("Load models") { state.fetchModelsIfNeeded(for: .opencode) }
                            .buttonStyle(.bordered)
                    }
                }
                Text("Used when Mochi starts the agent itself, from \u{201C}work on <project>\u{201D}. OpenCode takes any model it supports (OpenAI, Anthropic, Google, OpenRouter, local\u{2026}). Leave empty for the agent\u{2019}s own default.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("OpenCode workers follow your OpenCode permission settings. With OpenCode\u{2019}s defaults they will edit files and run commands without asking.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(6)
        }
    }
}

#endif
