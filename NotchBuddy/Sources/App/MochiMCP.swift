import Foundation

#if !APPSTORE

/// The MCP server Mochi's workers talk to: one tool, `report` (the brain role gets the six brain tools). The agent's MCP client starts
/// `nb-hook --mcp`, which relays every JSON-RPC line over `nb.sock` (`HookServer`). The protocol
/// lives in `MochiTools.mcpResponse`; this enum only finds the session a report belongs to. The
/// owner comes from the process environment Mochi gave the agent (never from the model).
@MainActor
enum MochiMCP {
    /// Answers one relayed message. nil: a notification, nothing to send back.
    static func handle(rpc: [String: Any], role: String, runtime: String, owner: String) async -> [String: Any]? {
        // Mochi's own brain (Claude Code login): its six tools run in MochiBrain, the same code the API-key brain uses.
        if role == MochiTools.brainRole {
            guard runtime == MochiTools.brainRuntime, owner == MochiTools.brainOwner else {
                guard let id = rpc["id"] else { return nil }
                return ["jsonrpc": "2.0", "id": id, "error": ["code": -32000, "message": "Not the Mochi brain"]]
            }
            return await MochiTools.brainMCPResponse(to: rpc) { name, json in
                await MochiBrain.shared.executeMCPTool(name: name, argumentsJSON: json)
            }
        }
        return MochiTools.mcpResponse(to: rpc) { note in
            guard let sessionId = reportTarget(runtime: runtime, owner: owner) else {
                return "No Mochi worker is running for this report."
            }
            let store = AppState.shared.sessionStore
            let cwd = store.sessions[sessionId]?.cwd ?? (runtime == "opencode" ? owner : "")
            HookServer.shared.feed(.mochiReport(note), sessionId: sessionId, cwd: cwd,
                                   agent: runtime == "opencode" ? "opencode" : "")
            if AppState.shared.speakMochiUpdates, let line = note.line { MochiSpeech.shared.say(line) }
            return nil
        }
    }

    /// The worker session a report is for. Claude Code: the owner is the session id. OpenCode: the
    /// owner is the project folder, and the report goes to that folder's Mochi worker that is busy
    /// right now, else the one that was active most recently.
    static func reportTarget(runtime: String, owner: String) -> String? {
        let sessions = AppState.shared.sessionStore.sessions
        switch runtime {
        case "claude":
            return WorkerManager.shared.isWorker(owner) ? owner : nil
        case "opencode":
            return MochiReportTarget.pick(from: sessions.values.filter {
                $0.kind == .openCode && $0.cwd == owner && WorkerManager.shared.isWorker($0.id)
            })
        default:
            return nil
        }
    }
}
#else
#endif
