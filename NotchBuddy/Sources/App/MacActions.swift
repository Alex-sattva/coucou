import AppKit

#if !APPSTORE

/// The three Mac actions Mochi's brain has: open an app, a web link, a file. Names, http(s) links and
/// paths only: nothing here runs a binary, a command or an argument a model wrote. The argument checks
/// and the name matching are pure (`MacActionLogic`).
@MainActor
enum MacActions {
    typealias Outcome = (text: String, isError: Bool)

    private static var searchFolders: [String] {
        ["/Applications", "/System/Applications", "/Applications/Utilities", "/System/Applications/Utilities",
         NSHomeDirectory() + "/Applications"]
    }

    /// Installed apps by name (without ".app") → their location, from the usual folders.
    private static func installedApps() -> [String: URL] {
        var found: [String: URL] = [:]
        for folder in searchFolders {
            let items = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
            for item in items where item.hasSuffix(".app") {
                let name = String(item.dropLast(4))
                if found[name] == nil { found[name] = URL(fileURLWithPath: folder).appendingPathComponent(item) }
            }
        }
        return found
    }

    private enum Resolved { case app(name: String, url: URL), missing(String) }

    private static func resolve(_ query: String) -> Resolved {
        let apps = installedApps()
        if let name = MacActionLogic.match(query, in: Array(apps.keys)), let url = apps[name] { return .app(name: name, url: url) }
        let near = MacActionLogic.closest(query, in: Array(apps.keys))
        let hint = near.isEmpty ? "" : " Close names: \(near.joined(separator: ", "))."
        return .missing("No app called \u{201C}\(query)\u{201D} is installed.\(hint)")
    }

    static func openApp(_ query: String) async -> Outcome {
        switch resolve(query) {
        case .missing(let message): return (message, true)
        case .app(let name, let url):
            do {
                _ = try await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                return ("Opened \(name).", false)
            } catch {
                return ("Could not open \(name): \(error.localizedDescription)", true)
            }
        }
    }

    static func openURL(_ url: URL, in appQuery: String?) async -> Outcome {
        guard let appQuery else {
            return NSWorkspace.shared.open(url) ? ("Opened \(url.absoluteString).", false)
                                                : ("Could not open \(url.absoluteString).", true)
        }
        switch resolve(appQuery) {
        case .missing(let message): return (message, true)
        case .app(let name, let appURL):
            do {
                _ = try await NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
                return ("Opened \(url.absoluteString) in \(name).", false)
            } catch {
                return ("Could not open the link in \(name): \(error.localizedDescription)", true)
            }
        }
    }

    /// Files that could run code (apps, scripts, installers…) are shown in Finder, never opened.
    static func openFile(_ path: String, reveal: Bool) -> Outcome {
        guard FileManager.default.fileExists(atPath: path) else { return ("File not found: \(path)", true) }
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        if reveal || MochiActionSafety.launchesCode(path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return ("Showed \(name) in Finder.", false)
        }
        return NSWorkspace.shared.open(url) ? ("Opened \(name).", false) : ("Could not open \(name).", true)
    }
}
#else
#endif
