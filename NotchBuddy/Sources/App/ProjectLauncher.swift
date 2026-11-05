import AppKit
import Foundation
import SQLite3

/// The terminal app sessions open in (Settings → General). Raw values are stored in UserDefaults.
enum TerminalApp: String, CaseIterable, Sendable {
    case terminal, iterm, ghostty, warp

    var displayName: String {
        switch self {
        case .terminal: return "Terminal"
        case .iterm: return "iTerm"
        case .ghostty: return "Ghostty"
        case .warp: return "Warp"
        }
    }

    var bundleId: String {
        switch self {
        case .terminal: return "com.apple.Terminal"
        case .iterm: return "com.googlecode.iterm2"
        case .ghostty: return "com.mitchellh.ghostty"
        case .warp: return "dev.warp.Warp-Stable"
        }
    }

    var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) }

    /// Terminal is always offered; the others only when installed.
    static var installed: [TerminalApp] { allCases.filter { $0 == .terminal || $0.appURL != nil } }
}

/// Runs a command in a folder in the user's chosen terminal. Each app needs its own way in:
/// Terminal and iTerm open a throwaway `.command` file, Ghostty takes the command as arguments,
/// Warp runs a launch configuration. None of them needs Apple Events permission.
enum TerminalLauncher {
    @MainActor
    static func run(_ command: String, in cwd: String) {
        let stored = TerminalApp(rawValue: AppState.shared.terminalApp) ?? .terminal
        // A terminal that was uninstalled since it was picked falls back to Terminal.
        let app = stored.appURL != nil ? stored : .terminal
        let quoted = shellQuote(cwd)
        switch app {
        case .terminal, .iterm:
            guard let script = writeScript("cd \(quoted) && exec \(command)") else { return }
            if let appURL = app.appURL {
                NSWorkspace.shared.open([script], withApplicationAt: appURL,
                                        configuration: NSWorkspace.OpenConfiguration())
            } else {
                NSWorkspace.shared.open(script)
            }
        case .ghostty:
            guard let appURL = app.appURL,
                  let script = writeScript("cd \(quoted) && exec \(command)") else { return }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = ["-na", appURL.path, "--args", "--working-directory=\(cwd)", "-e", "/bin/zsh", "-l", script.path]
            try? p.run()
        case .warp:
            runInWarp(command, cwd: cwd)
        }
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// A login-shell script, so the user's PATH (where `claude` / `opencode` live) is loaded.
    private static func writeScript(_ body: String) -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("coucou-\(UUID().uuidString.prefix(8)).command")
        do {
            try "#!/bin/zsh -l\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            return url
        } catch {
            appendAppLog("nb.log", "terminal launch: could not write script: \(error.localizedDescription)")
            return nil
        }
    }

    /// Warp runs launch configurations from ~/.warp/launch_configurations. Coucou writes one file
    /// of its own there (overwritten each time) and opens it with the warp:// URL scheme.
    private static func runInWarp(_ command: String, cwd: String) {
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".warp/launch_configurations")
        let name = "coucou-launch.yaml"
        func yaml(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let config = """
            ---
            name: Coucou
            windows:
              - tabs:
                  - title: \(yaml((cwd as NSString).lastPathComponent))
                    layout:
                      cwd: \(yaml(cwd))
                      commands:
                        - exec: \(yaml(command))

            """
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try config.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        } catch {
            appendAppLog("nb.log", "warp launch: could not write config: \(error.localizedDescription)")
            return
        }
        if let url = URL(string: "warp://launch/\(name)") { NSWorkspace.shared.open(url) }
    }
}

/// Finds the folders the user has worked in, from Claude Code's transcripts and OpenCode's
/// store. Read-only, and slow enough (dozens of files) that it never runs on the main thread.
enum ProjectScanner {
    static func scan() -> [KnownProject] {
        let home = NSHomeDirectory()
        let projects = ProjectLaunchLogic.merge(claude: claudeFolders(home: home),
                                                openCode: openCodeFolders(home: home), home: home)
        var isDir: ObjCBool = false
        return projects.filter { FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDir) && isDir.boolValue }
    }

    /// One entry per ~/.claude/projects folder: the `cwd` written in its newest transcript (the
    /// folder name itself turns every "/" and "-" into "-", so it can't be decoded back).
    private static func claudeFolders(home: String) -> [(String, Date)] {
        let root = URL(fileURLWithPath: home).appendingPathComponent(".claude/projects")
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return dirs.compactMap { dir in
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]))?
                .filter { $0.pathExtension == "jsonl" } ?? []
            let dated = files.compactMap { f -> (URL, Date)? in
                guard let d = try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                else { return nil }
                return (f, d)
            }
            guard let newest = dated.max(by: { $0.1 < $1.1 }), let cwd = firstCwd(in: newest.0) else { return nil }
            return (cwd, newest.1)
        }
    }

    private static func firstCwd(in file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 256 * 1024),
              let text = String(data: data, encoding: .utf8),
              let r = text.range(of: "\"cwd\":\"") else { return nil }
        let rest = text[r.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end]).replacingOccurrences(of: "\\/", with: "/")
    }

    private static func openCodeFolders(home: String) -> [(String, Date)] {
        let dir = URL(fileURLWithPath: home).appendingPathComponent(".local/share/opencode")
        var out: [(String, Date)] = []
        for name in ["opencode.db", "opencode-.db"] {
            let path = dir.appendingPathComponent(name).path
            guard FileManager.default.fileExists(atPath: path) else { continue }
            var db: OpaquePointer?
            guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
                sqlite3_close(db)
                continue
            }
            defer { sqlite3_close(db) }
            var stmt: OpaquePointer?
            let sql = "SELECT directory, MAX(time_updated) FROM session GROUP BY directory"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { continue }
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let c = sqlite3_column_text(stmt, 0) else { continue }
                let ms = sqlite3_column_int64(stmt, 1)
                out.append((String(cString: c), Date(timeIntervalSince1970: TimeInterval(ms) / 1000)))
            }
        }
        return out
    }
}
