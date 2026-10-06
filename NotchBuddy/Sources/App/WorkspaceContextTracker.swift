import AppKit
import ApplicationServices
import Combine

/// Works out which agent workspace the user is looking at, from the front window's title, and
/// publishes it as `AppState.contextWorkspace` (consumed by the main-agent picker).
///
/// Event driven, no polling: an `NSWorkspace` activation observer plus an `AXObserver` on the
/// front app (focused window changed, title changed). Runs only while at least one session exists
/// and the island is not hidden, so it costs nothing otherwise. Never prompts for Accessibility.
@MainActor
final class WorkspaceContextTracker {
    static let shared = WorkspaceContextTracker()

    /// A candidate must hold this long before it is published; a change back cancels it.
    static let dwell: Duration = .seconds(1)

    private let state = AppState.shared
    private var cancellables = Set<AnyCancellable>()
    private var started = false

    private var running = false
    private var workspaces: [(name: String, cwd: String)] = []
    private var activationObserver: NSObjectProtocol?

    private var observer: AXObserver?
    private var observedApp: AXUIElement?
    private var observedWindow: AXUIElement?

    private var pendingValue: String??       // .some(nil) = "pending nil"
    private var dwellTask: Task<Void, Never>?

    private init() {}

    // MARK: - Lifecycle

    func start() {
        #if APPSTORE
        state.contextWorkspace = nil
        #else
        guard !started else { return }
        started = true
        // @Published emits on willSet, so use the emitted values rather than reading state back.
        Publishers.CombineLatest(state.$sessionStore, state.$mode)
            .sink { [weak self] store, mode in
                MainActor.assumeIsolated { self?.update(store: store, mode: mode) }
            }
            .store(in: &cancellables)
        #endif
    }

    #if !APPSTORE

    private func update(store: AgentSessionStore, mode: IslandMode) {
        let list = store.sessions.values
            .sorted { $0.id < $1.id }
            .map { (name: $0.workspace, cwd: $0.cwd) }
        let changed = list.count != workspaces.count
            || zip(list, workspaces).contains { $0.name != $1.name || $0.cwd != $1.cwd }
        workspaces = list

        let shouldRun = !list.isEmpty && mode != .hidden
        if shouldRun && !running {
            startRunning()
        } else if !shouldRun && running {
            stopRunning()
        } else if running && changed {
            evaluate()
        }
    }

    private func startRunning() {
        running = true
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let pid = app?.processIdentifier
            let bundle = app?.bundleIdentifier
            MainActor.assumeIsolated { self?.frontAppChanged(pid: pid, bundleId: bundle) }
        }
        let front = NSWorkspace.shared.frontmostApplication
        frontAppChanged(pid: front?.processIdentifier, bundleId: front?.bundleIdentifier)
    }

    private func stopRunning() {
        running = false
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        activationObserver = nil
        removeObserver()
        dwellTask?.cancel(); dwellTask = nil
        pendingValue = nil
        publish(nil)
    }

    // MARK: - Front app + AXObserver

    private func frontAppChanged(pid: pid_t?, bundleId: String?) {
        guard running else { return }
        // Coucou's own windows (clicking the island) say nothing about the user's context:
        // keep the last value and the existing observer.
        if bundleId == Bundle.main.bundleIdentifier { return }
        removeObserver()
        guard let pid, AXIsProcessTrusted() else {
            commit(nil)   // no Accessibility: no prompt, no context
            return
        }
        installObserver(pid: pid)
        evaluate()
    }

    private func installObserver(pid: pid_t) {
        var obs: AXObserver?
        guard AXObserverCreate(pid, axCallback, &obs) == .success, let obs else { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        AXObserverAddNotification(obs, app, kAXFocusedWindowChangedNotification as CFString, nil)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        observer = obs
        observedApp = app
        watchFocusedWindowTitle()
    }

    /// Title changes fire on the window element, so follow the focused window.
    private func watchFocusedWindowTitle() {
        guard let observer, let app = observedApp else { return }
        if let old = observedWindow {
            AXObserverRemoveNotification(observer, old, kAXTitleChangedNotification as CFString)
            observedWindow = nil
        }
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &ref) == .success,
              let ref else { return }
        // swiftlint:disable:next force_cast
        let window = ref as! AXUIElement
        if AXObserverAddNotification(observer, window, kAXTitleChangedNotification as CFString, nil) == .success {
            observedWindow = window
        }
    }

    private func removeObserver() {
        if let observer {
            if let w = observedWindow {
                AXObserverRemoveNotification(observer, w, kAXTitleChangedNotification as CFString)
            }
            if let a = observedApp {
                AXObserverRemoveNotification(observer, a, kAXFocusedWindowChangedNotification as CFString)
            }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        observedApp = nil
        observedWindow = nil
    }

    /// Called (on the main actor) by the C callback for every AX notification.
    fileprivate func axNotification(_ name: String) {
        guard running, observer != nil else { return }
        if name == kAXFocusedWindowChangedNotification as String { watchFocusedWindowTitle() }
        evaluate()
    }

    // MARK: - Matching + dwell

    private func evaluate() {
        guard running, let app = observedApp,
              let title = WindowContextCapture.focusedWindowTitle(of: app) else {
            return
        }
        commit(WorkspaceTitleMatcher.match(title: title, workspaces: workspaces))
    }

    /// Publishes `value` once it has held for `dwell`. A change back to the published value cancels.
    private func commit(_ value: String?) {
        if value == state.contextWorkspace {
            dwellTask?.cancel(); dwellTask = nil; pendingValue = nil
            return
        }
        if let pending = pendingValue, pending == value, dwellTask != nil { return }
        dwellTask?.cancel()
        pendingValue = .some(value)
        dwellTask = Task { [weak self] in
            try? await Task.sleep(for: Self.dwell)
            guard !Task.isCancelled, let self else { return }
            self.dwellTask = nil
            self.pendingValue = nil
            self.publish(value)
        }
    }

    private func publish(_ value: String?) {
        guard state.contextWorkspace != value else { return }
        state.contextWorkspace = value
        appendAppLog("nb.log", "[context] workspace → \(value ?? "nil")")
    }

    #endif
}

#if !APPSTORE
/// C callback: captures nothing, hops to the main actor through the shared tracker.
private let axCallback: AXObserverCallback = { _, _, notification, _ in
    let name = notification as String
    Task { @MainActor in WorkspaceContextTracker.shared.axNotification(name) }
}
#endif
