import Foundation
import SQLite3

/// Reads a session's title from the agent's own files, read-only, never on the main thread.
/// Claude Code: the last `custom-title` line of the session transcript (the desktop sidebar name).
/// OpenCode: `session.title` in its SQLite store. Other agents: nil.
enum SessionTitleReader {
    /// Titles are re-written near the end of a transcript, so the tail nearly always has one.
    private static let tailBytes = 512 * 1024
    /// Past this, a transcript with no title in its tail is not read whole.
    private static let fullReadLimit = 16 * 1024 * 1024

    static func title(kind: AgentKind, sessionId: String, cwd: String) -> String? {
        switch kind {
        case .claudeCode: return claudeTitle(sessionId: sessionId, cwd: cwd)
        case .openCode: return openCodeTitle(sessionId: sessionId)
        default: return nil
        }
    }

    // MARK: Claude Code

    private static func claudeTitle(sessionId: String, cwd: String) -> String? {
        guard ClaudeCodeRun.isValidSessionId(sessionId), let url = claudeTranscript(sessionId: sessionId, cwd: cwd),
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: start)
        if let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8),
           let title = SessionTitle.claudeTitle(transcriptTail: text) {
            return title
        }
        guard start > 0, size <= UInt64(fullReadLimit) else { return nil }
        try? handle.seek(toOffset: 0)
        guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) else { return nil }
        return SessionTitle.claudeTitle(transcriptTail: text)
    }

    private static func claudeTranscript(sessionId: String, cwd: String) -> URL? {
        let projects = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects")
        let fm = FileManager.default
        if !cwd.isEmpty {
            let direct = projects.appendingPathComponent(SessionTitle.claudeProjectDir(cwd: cwd))
                .appendingPathComponent("\(sessionId).jsonl")
            if fm.fileExists(atPath: direct.path) { return direct }
        }
        // The folder name rule may differ (symlinks, long paths): look in every project folder.
        let dirs = (try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
        return dirs.lazy.map { $0.appendingPathComponent("\(sessionId).jsonl") }
            .first { fm.fileExists(atPath: $0.path) }
    }

    // MARK: OpenCode

    private static func openCodeTitle(sessionId: String) -> String? {
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/share/opencode")
        for name in ["opencode.db", "opencode-.db"] {
            let path = dir.appendingPathComponent(name).path
            guard FileManager.default.fileExists(atPath: path) else { continue }
            if let title = queryTitle(dbPath: path, sessionId: sessionId) { return title }
        }
        return nil
    }

    private static func queryTitle(dbPath: String, sessionId: String) -> String? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 200)
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT title FROM session WHERE id = ?1", -1, &stmt, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, sessionId, -1, transient)
        guard sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) else { return nil }
        return SessionTitle.clean(String(cString: c))
    }
}
