import Foundation

/// Maps a front-window title to one of the live workspaces. Pure (Foundation only).
///
/// A workspace matches when its folder name, its full cwd, or its `~`-abbreviated cwd appears in
/// the title as a whole token: the characters right before and right after the match must not be
/// part of a name (letters, digits, `-`, `_`). So "app" does not match "app-web" or "happy", but
/// does match "~/code/app", "app — zsh" and "working on app today". Longest match wins.
enum WorkspaceTitleMatcher {

    static func match(title: String, workspaces: [(name: String, cwd: String)]) -> String? {
        let haystack = title.lowercased()
        guard !haystack.isEmpty, !workspaces.isEmpty else { return nil }
        let home = NSHomeDirectory().lowercased()

        var best: (name: String, score: Int)?
        for ws in workspaces {
            for candidate in candidates(for: ws, home: home) {
                guard candidate.count > (best?.score ?? 0) else { continue }
                if containsAsToken(haystack, candidate) { best = (ws.name, candidate.count) }
            }
        }
        return best?.name
    }

    // MARK: - Private

    private static func candidates(for ws: (name: String, cwd: String), home: String) -> [String] {
        var out: [String] = []
        let name = ws.name.lowercased()
        if !name.isEmpty { out.append(name) }
        var cwd = ws.cwd.lowercased()
        while cwd.count > 1, cwd.hasSuffix("/") { cwd.removeLast() }
        if cwd.count > 1 {
            let last = URL(fileURLWithPath: cwd).lastPathComponent
            if !last.isEmpty { out.append(last) }
            out.append(cwd)
            if home.count > 1, cwd == home || cwd.hasPrefix(home + "/") {
                out.append("~" + cwd.dropFirst(home.count))
            }
        }
        return out
    }

    private static func isNameChar(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "-" || c == "_"
    }

    private static func containsAsToken(_ haystack: String, _ needle: String) -> Bool {
        var searchStart = haystack.startIndex
        while let r = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
            let beforeOK: Bool = {
                guard r.lowerBound > haystack.startIndex else { return true }
                let c = haystack[haystack.index(before: r.lowerBound)]
                return !isNameChar(c) && c != "."
            }()
            let afterOK: Bool = {
                guard r.upperBound < haystack.endIndex else { return true }
                let c = haystack[r.upperBound]
                if isNameChar(c) { return false }
                // "app.js" is a file, "app." at the end of a sentence is not.
                if c == "." {
                    let next = haystack.index(after: r.upperBound)
                    return next >= haystack.endIndex || !(haystack[next].isLetter || haystack[next].isNumber)
                }
                return true
            }()
            if beforeOK && afterOK { return true }
            searchStart = haystack.index(after: r.lowerBound)
        }
        return false
    }
}
