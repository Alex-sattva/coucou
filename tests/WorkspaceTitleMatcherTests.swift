import Foundation

@main
@MainActor
enum WorkspaceTitleMatcherTests {

    static var failures = 0

    static func checkEq<T: Equatable>(_ label: String, _ got: T, _ expected: T) {
        if got == expected { print("  ✓ \(label)") }
        else { print("  ✗ \(label)  got: \(got)  expected: \(expected)"); failures += 1 }
    }

    static let home = NSHomeDirectory()

    static func m(_ title: String, _ ws: [(name: String, cwd: String)]) -> String? {
        WorkspaceTitleMatcher.match(title: title, workspaces: ws)
    }

    static func main() {
        let coucou = (name: "coucou", cwd: "\(home)/Desktop/code/coucou")
        let api = (name: "api", cwd: "\(home)/code/api")
        let app = (name: "app", cwd: "/work/app")
        let appWeb = (name: "app-web", cwd: "/work/app-web")

        print("terminals")
        checkEq("Ghostty path title", m("~/code/coucou", [coucou, api]), "coucou")
        checkEq("zsh suffix", m("coucou — zsh", [coucou, api]), "coucou")
        checkEq("user@host: path", m("kepla@mac: ~/Desktop/code/coucou", [coucou, api]), "coucou")
        checkEq("full cwd", m("\(home)/Desktop/code/coucou", [coucou, api]), "coucou")
        checkEq("case-insensitive", m("COUCOU — Zsh", [coucou]), "coucou")

        print("editors")
        checkEq("VS Code file — folder", m("SettingsView.swift — coucou", [coucou, api]), "coucou")
        checkEq("VS Code remote", m("coucou [SSH: x]", [coucou, api]), "coucou")
        checkEq("Cursor with dash separator", m("main.ts - api - Cursor", [coucou, api]), "api")
        checkEq("Xcode", m("NotchBuddy — SettingsView.swift", [coucou, api]), nil)
        checkEq("Xcode with project folder", m("coucou — SettingsView.swift", [coucou]), "coucou")

        print("browsers")
        checkEq("folder name in a sentence", m("Pull request for coucou · GitHub — Safari", [coucou, api]), "coucou")
        checkEq("sentence-ending dot", m("I am working on api.", [api]), "api")

        print("whole-token rules")
        checkEq("app does not match app-web", m("app-web — zsh", [app]), nil)
        checkEq("app does not match happy", m("happy birthday", [app]), nil)
        checkEq("app does not match application", m("application", [app]), nil)
        checkEq("app does not match app.js", m("app.js — editor", [app]), nil)
        checkEq("app matches inside a path", m("/work/app", [app]), "app")
        checkEq("longest wins (app-web over app)", m("app-web — zsh", [app, appWeb]), "app-web")
        checkEq("app still matches when alone", m("~ app — zsh", [app, appWeb]), "app")
        checkEq("cwd beats folder name on a longer match",
                m("/work/app/web", [app, (name: "web", cwd: "/work/app/web")]), "web")

        print("empty inputs")
        checkEq("empty title", m("", [coucou]), nil)
        checkEq("no workspaces", m("coucou", []), nil)
        checkEq("no match", m("Finder", [coucou, api]), nil)

        print("")
        if failures == 0 {
            print("All tests passed.")
        } else {
            print("\(failures) test(s) failed.")
            exit(1)
        }
    }
}
