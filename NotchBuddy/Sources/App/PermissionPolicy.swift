import Foundation

/// Decides which permission requests are sensitive enough to always show a card, when the user
/// picked "Auto" in Settings → Agents → Permissions. When in doubt it says "sensitive":
/// a wrong "sensitive" costs one click, a wrong "safe" can cost data.
enum PermissionPolicy {

    /// Tools that only read or plan.
    private static let readOnlyTools: Set<String> = [
        "Read", "Glob", "Grep", "LS", "WebSearch", "WebFetch", "TodoWrite", "Task", "Agent",
        "NotebookRead", "BashOutput", "ExitPlanMode", "ToolSearch",
    ]

    /// Tools that write a file — safe only when the file is inside the session's project.
    private static let fileWriteTools: Set<String> = ["Edit", "MultiEdit", "Write", "NotebookEdit"]

    /// Shell patterns that always ask. Matched case-insensitively against the whole command.
    private static let sensitiveShellPatterns: [String] = [
        #"(^|[\s;&|(`])(sudo|su|doas)\s"#,
        #"(^|[\s;&|(`])(rm|rmdir|shred|unlink|dd|mkfs\S*|diskutil|chmod|chown|chflags|kill|killall|pkill|launchctl|reboot|shutdown|halt|crontab|defaults\s+write|security|osascript|eval|exec)(\s|$)"#,
        #"(^|[\s;&|(`])mv\s"#,
        #"git\s+(push|reset|clean|rebase|checkout\s+--|checkout\s+\.|restore|stash\s+(drop|clear)|branch\s+-[dD]|tag\s+-d|filter-branch|commit\s+--amend|merge|cherry-pick|revert|rm)\b"#,
        #"\b(npm|pnpm|yarn|bun)\s+(publish|unpublish|install|i|add|remove|uninstall|update|upgrade)\b"#,
        #"\b(npx|bunx|pip3?|pipx|brew|gem|cargo\s+install|go\s+install|apt(-get)?|port)\b"#,
        #"\b(curl|wget)\b.*(\|\s*(ba|z)?sh|-X\s*(POST|PUT|DELETE|PATCH)|--data|\s-d\s|-F\s|--upload|-T\s|-o\s|-O\b)"#,
        #"\b(ssh|scp|rsync|sftp|ftp|nc|ncat|telnet)\b"#,
        #"\b(gh|vercel|netlify|fly|flyctl|heroku|aws|gcloud|az|kubectl|helm|terraform|pulumi|docker|firebase|supabase|wrangler)\b"#,
        #"\b(drop|truncate|delete\s+from|alter\s+table|update\s+\S+\s+set)\b"#,
        #"\b(migrate|deploy|publish|release)\b"#,
        #"\bfind\b.*\s-(delete|exec)\b"#,
        #"\bxargs\b"#,
        #"\b(env|printenv|keychain|\.env\b|id_rsa|\.ssh/|\.aws/|credentials)"#,
        #"(^|[^0-9&])>{1,2}\s*(?!/dev/null|&)"#,   // redirect into a file (2>/dev/null and 2>&1 are fine)
        #"\btee\b"#,
        #"\bsed\b.*\s-i\b"#,
    ]

    private static let sensitiveRegexes: [NSRegularExpression] = sensitiveShellPatterns.compactMap {
        try? NSRegularExpression(pattern: $0, options: [.caseInsensitive])
    }

    static func isSensitive(tool: String, input: [String: Any], cwd: String) -> Bool {
        if readOnlyTools.contains(tool) { return false }
        if fileWriteTools.contains(tool) {
            let path = (input["file_path"] as? String) ?? (input["notebook_path"] as? String) ?? ""
            return !isInsideProject(path, cwd: cwd)
        }
        if tool == "Bash" {
            guard let command = input["command"] as? String else { return true }
            return isSensitiveShell(command)
        }
        // MCP tools, unknown tools and anything new: ask.
        return true
    }

    static func isSensitiveShell(_ command: String) -> Bool {
        let range = NSRange(command.startIndex..., in: command)
        return sensitiveRegexes.contains { $0.firstMatch(in: command, range: range) != nil }
    }

    private static func isInsideProject(_ path: String, cwd: String) -> Bool {
        guard !path.isEmpty, !cwd.isEmpty else { return false }
        let file = URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: cwd)).standardizedFileURL.path
        let root = URL(fileURLWithPath: cwd).standardizedFileURL.path
        guard file.hasPrefix(root + "/") else { return false }
        // Files that hold secrets or wire up git/CI still ask.
        let lower = file.lowercased()
        return !(lower.contains("/.env") || lower.contains("/.git/") || lower.contains("/.github/")
                 || lower.hasSuffix(".pem") || lower.hasSuffix(".key"))
    }
}
