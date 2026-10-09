import Foundation

/// Where Mochi's brain thinks: one of Chat's providers (an API key, a local server or OpenCode), or the
/// user's own Claude Code login. Brain only: Chat's `ChatProvider` does not know the second case, so
/// Chat's settings are untouched. Stored as text under `mochiBrainProvider`: a `ChatProvider` raw value
/// as before, or `claude-login`.
enum BrainProvider: Hashable {
    case chat(ChatProvider)
    case claudeLogin

    static let claudeLoginStorage = "claude-login"

    /// Every choice in the picker: Chat's providers in Chat's order, then the Claude Code login.
    static var all: [BrainProvider] { ChatProvider.allCases.map { .chat($0) } + [.claudeLogin] }

    init?(storage: String) {
        if storage == Self.claudeLoginStorage { self = .claudeLogin }
        else if let p = ChatProvider(rawValue: storage) { self = .chat(p) }
        else { return nil }
    }

    var storage: String {
        switch self {
        case .chat(let p): p.rawValue
        case .claudeLogin: Self.claudeLoginStorage
        }
    }

    var displayName: String {
        switch self {
        case .chat(.anthropic): "Anthropic API (key)"
        case .chat(let p): p.displayName
        case .claudeLogin: "Claude subscription (Claude Code login)"
        }
    }

    /// The model used when none is picked. Anthropic and the Claude login share the brain's own default
    /// (Chat's defaults are not changed).
    var defaultModel: String {
        switch self {
        case .chat(.anthropic), .claudeLogin: BrainModels.defaultAnthropic
        // No fixed Go default: the user picks one from the Go list (Chat's default is a Zen model).
        case .chat(.opencode): ""
        case .chat(let p): p.defaultModel
        }
    }

    /// The fixed Anthropic list applies to both Anthropic providers.
    var fixedModels: [(id: String, label: String)]? {
        switch self {
        case .chat(.anthropic), .claudeLogin: BrainModels.anthropic
        default: nil
        }
    }
}
