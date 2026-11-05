import Foundation
import UniformTypeIdentifiers

/// Decides whether opening a path from a model-written suggestion could run code. Those paths
/// are shown in Finder instead of opened: a click on "Open file" must never launch an app, a
/// script or an installer.
enum MochiActionSafety {
    /// Extensions that run something, or point at something that does, when opened.
    private static let launchingExtensions: Set<String> = [
        "app", "command", "tool", "sh", "bash", "zsh", "csh", "ksh", "fish", "py", "rb", "pl", "php",
        "js", "mjs", "jar", "scpt", "scptd", "applescript", "workflow", "action", "terminal",
        "pkg", "mpkg", "dmg", "prefpane", "saver", "kext", "plugin", "bundle", "shortcut",
        "webloc", "inetloc", "fileloc", "url", "osax", "qlgenerator", "mdimporter", "xpc",
    ]

    static func launchesCode(_ path: String) -> Bool {
        let given = URL(fileURLWithPath: path)
        // A Finder alias opens whatever it points at; it is never treated as a plain document.
        if (try? given.resourceValues(forKeys: [.isAliasFileKey]))?.isAliasFile == true { return true }
        // A symlink is judged by its target ("notes" -> Something.app would otherwise pass).
        let url = given.resolvingSymlinksInPath()
        let path = url.path
        let ext = url.pathExtension.lowercased()
        if launchingExtensions.contains(ext) { return true }
        if let type = UTType(filenameExtension: ext),
           [.executable, .application, .script, .shellScript, .package, .bundle]
            .contains(where: { type.conforms(to: $0) }) {
            return true
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return false }
        // A plain folder opens a Finder window, which is fine. A file with the execute bit is not.
        return !isDir.boolValue && FileManager.default.isExecutableFile(atPath: path)
    }
}
