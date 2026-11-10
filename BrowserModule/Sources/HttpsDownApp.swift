import SwiftUI
import AppKit

/// Holds external http(s) addresses (command line / OS URL event) until the main model exists, then hands them over
/// once. Normal tabs only: no private mode. `open -n` is not needed (and would start a second process on the same store).
@MainActor
final class ExternalURLCoordinator {
    static let shared = ExternalURLCoordinator()

    private weak var model: AppModel?
    private var pending: [String] = []
    private var launchArgumentURLs: Set<String> = []
    private var launchWindowEnd = Date.distantPast
    /// Set once by an unsupported private-mode flag in the launch arguments and kept for the whole process: the OS URL
    /// event of that same launch (`open -a APP URL --args --incognito`) can arrive well after the alert, so it is never
    /// time-limited. Only a new process (normal launch without the flag) opens external URLs again.
    private var externalLaunchRejected = false
    /// Name of the refused flag until the alert has been shown (always one of `unsupportedFlags`, never a URL).
    private var rejectedFlagToAnnounce: String?

    private static let unsupportedFlags: Set<String> = ["--incognito", "-incognito", "--private", "-private", "--inprivate"]
    private static let maxPending = 10
    private static let maxScannedPerCall = 64
    /// Cold-launch dedup window: a URL event for an address that also came in as an argument is skipped only inside it.
    /// It only de-duplicates; it never decides whether a refused launch stays refused.
    private static let coldLaunchWindow: TimeInterval = 1.0

    /// Validated (`BrowserPreferences.validateWebURL`) addresses only; at most `maxPending` wait for the model.
    private func enqueue(_ raw: String) -> String? {
        guard let url = BrowserPreferences.validateWebURL(raw) else { return nil }
        if !pending.contains(url), pending.count < Self.maxPending { pending.append(url) }
        return url
    }

    /// Cold launch (`open -a HTD.app --args URL` or the binary with arguments): only valid http(s) URLs are taken, and
    /// at most `maxScannedPerCall` raw arguments are looked at for addresses. If a private-mode flag is present anywhere
    /// in the arguments nothing is opened (no pretending to be private): the launch is marked rejected for good, every
    /// queued/suppressed address is dropped, and only the alert is shown.
    /// Dedup semantics: those addresses suppress one matching URL event for ~1s after launch, then are forgotten.
    func ingestLaunchArguments(_ args: [String]) {
        launchWindowEnd = Date().addingTimeInterval(Self.coldLaunchWindow)
        let rest = args.dropFirst()
        // `--incognito` and `--incognito=…` alike (the part before `=` is compared; the alert shows only that fixed name).
        let flagName = { (arg: String) -> String in String(arg.lowercased().split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first ?? "") }
        if let flag = rest.map(flagName).first(where: { Self.unsupportedFlags.contains($0) }) {
            externalLaunchRejected = true
            rejectedFlagToAnnounce = flag
            pending.removeAll()
            launchArgumentURLs.removeAll()
            return
        }
        for arg in rest.prefix(Self.maxScannedPerCall) {
            if let url = enqueue(arg) { launchArgumentURLs.insert(url) }
        }
    }

    /// OS URL event. After a refused launch every address is dropped, however late the event arrives. Otherwise an
    /// address that just came in through launch arguments is skipped once, only inside the cold-launch window;
    /// afterwards (or for any other address) every event opens normally.
    func receive(_ urls: [URL]) {
        if externalLaunchRejected {
            pending.removeAll()
            flush()   // may still have to show the alert
            return
        }
        let inWindow = Date() < launchWindowEnd
        if !inWindow { launchArgumentURLs.removeAll() }
        for url in urls.prefix(Self.maxScannedPerCall) {
            guard let valid = BrowserPreferences.validateWebURL(url.absoluteString) else { continue }
            if inWindow, launchArgumentURLs.remove(valid) != nil { continue }
            if !pending.contains(valid), pending.count < Self.maxPending { pending.append(valid) }
        }
        flush()
    }

    /// Called when the main window attaches; binds the model weakly and delivers everything received so far.
    func bind(_ model: AppModel) {
        self.model = model
        flush()
    }

    private func flush() {
        guard let model else { return }
        if let flag = rejectedFlagToAnnounce {
            rejectedFlagToAnnounce = nil
            model.alertMessage = "\(flag) 옵션은 지원하지 않아 전달된 주소를 열지 않았습니다."
            model.showingAlert = true
        }
        if externalLaunchRejected { pending.removeAll(); return }
        guard !pending.isEmpty else { return }
        let batch = pending
        pending.removeAll()
        model.openExternalURLs(batch)
    }
}

/// Plain delegate attached through NSApplicationDelegateAdaptor (SwiftUI keeps owning the real application delegate).
final class HttpsDownAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        MainActor.assumeIsolated { ExternalURLCoordinator.shared.ingestLaunchArguments(args) }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { ExternalURLCoordinator.shared.receive(urls) }
    }
}

#if !HTT_HOST
@main
struct HttpsDownApp: App {
    @NSApplicationDelegateAdaptor(HttpsDownAppDelegate.self) private var appDelegate
    @StateObject private var appModel = AppModel()
    @StateObject private var appearance = AppearanceStore()   // read synchronously before the first render

    var body: some Scene {
        WindowGroup(AppIdentity.displayName) {
            MainView(appModel: appModel)
                .background(MainWindowKeyMonitor(appModel: appModel))
                .background(AILoginProbeSurfaceView().frame(width: 800, height: 680).allowsHitTesting(false).accessibilityHidden(true))
                .environmentObject(appearance)
                .byungkiThemed(appearance.palette)
                .onAppear { appearance.startObservingSystem() }
                .frame(minWidth: 860, idealWidth: 1120, minHeight: 560, idealHeight: 760)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    // Quitting must not leave engine/ffmpeg/deno children behind.
                    appModel.shutdown()
                }
        }
        .defaultSize(WindowSizeStore.savedSize ?? CGSize(width: 1120, height: 760))
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
            // Close lives in .saveItem. Declaring it here keeps ⌘W on the browser's tab logic even when SwiftUI rebuilds
            // the menu (the former performClose: rebinding could be lost); other windows still get the standard close.
            CommandGroup(replacing: .saveItem) {
                Button("닫기") { appModel.performStandardClose() }
                    .keyboardShortcut("w", modifiers: .command)
            }
        }
    }
}
#endif

/// Captures the main app window via its own NSView.window and monitors key down & mouse events.
/// Handles Cmd+W (switches or closes browser tab without closing window), Cmd+Left Arrow (browser back),
/// Cmd+[ (same back action), and the mouse Back side button (buttonNumber 3: .otherMouseDown primary,
/// .otherMouseUp-only fallback). Local app-event monitor only; no global input monitoring.
struct MainWindowKeyMonitor: NSViewRepresentable {
    @ObservedObject var appModel: AppModel

    func makeCoordinator() -> Coordinator {
        Coordinator(appModel: appModel)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.attachedView = view
        DispatchQueue.main.async {
            context.coordinator.installCloseMenuHook()
            context.coordinator.attachWindowAndRestoreSizeIfNeeded()
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.attachedView = nsView
        DispatchQueue.main.async {
            context.coordinator.installCloseMenuHook()
            context.coordinator.attachWindowAndRestoreSizeIfNeeded()
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.cleanup()
    }

    final class Coordinator: NSObject {
        weak var appModel: AppModel?
        weak var attachedView: NSView?
        private var monitor: Any?
        private var sideBackDownSeen = false
        private var observers: [NSObjectProtocol] = []
        private weak var closeItem: NSMenuItem?
        private var originalTarget: AnyObject?
        private var originalAction: Selector?
        private weak var observedWindow: NSWindow?
        private var hasAppliedRestoredSize = false

        init(appModel: AppModel) {
            self.appModel = appModel
            super.init()
            // SwiftUI may rebuild menu items; re-bind whenever a window becomes key/main.
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    self?.installCloseMenuHook()
                })
            }
            self.monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .otherMouseDown, .otherMouseUp]) { [weak self] event in
                guard let self = self else { return event }
                guard let window = self.attachedView?.window else {
                    return event
                }
                let targetWindow = event.window ?? NSApp.keyWindow
                guard targetWindow === window, NSApp.isActive, window.isKeyWindow else {
                    return event
                }

                #if HTT_HOST
                if HTDHostExport.shared.hostedToolID != nil {
                    self.sideBackDownSeen = false
                    return event
                }
                #endif

                // Mouse dedicated Back button (standard button 3). Down is the primary trigger; the paired up is
                // consumed so it cannot go back twice. If a driver only delivers up, that up acts as the fallback.
                if (event.type == .otherMouseDown || event.type == .otherMouseUp) && event.buttonNumber == 3 {
                    guard let app = self.appModel, app.selectedTab == .browser else {
                        self.sideBackDownSeen = false
                        return event
                    }
                    if event.type == .otherMouseDown {
                        self.sideBackDownSeen = true
                    } else if self.sideBackDownSeen {
                        self.sideBackDownSeen = false
                        return nil
                    }
                    let browser = app.browser
                    Task { @MainActor in
                        browser.goBack()   // decides on the live WKWebView history
                    }
                    return nil
                }

                guard event.type == .keyDown else {
                    return event
                }

                let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])

                // Cmd + W: physical W key (keyCode 13) so it also works on a Korean layout (where the character is "ㅈ")
                if flags == .command, event.keyCode == 13 || event.charactersIgnoringModifiers?.lowercased() == "w" {
                    #if HTT_HOST
                    if HTDHostExport.shared.hostedToolID != nil {
                        return event
                    }
                    #endif
                    Task { @MainActor [weak self] in
                        self?.appModel?.handleCloseBrowserShortcut()
                    }
                    return nil
                }

                // Cmd + Left Arrow (keyCode 123) or Cmd + [ (physical key 33, so it also works on a Korean layout)
                if flags == .command, event.keyCode == 123 || event.keyCode == 33 {
                    if let app = self.appModel {
                        if app.selectedTab == .browser {
                            let browser = app.browser
                            Task { @MainActor in
                                browser.goBack()
                            }
                            return nil
                        } else if app.selectedTab == .saw {
                            if let pid = app.sawWorkspace.selectedProjectID {
                                let session = app.sawWorkspace.session(for: pid)
                                if let activeTab = session.activeBrowser {
                                    Task { @MainActor in
                                        activeTab.goBack()
                                    }
                                    return nil
                                }
                            }
                        }
                    }
                }

                // Cmd + T: new owned tab in .saw mode
                if flags == .command, event.keyCode == 17 || event.charactersIgnoringModifiers?.lowercased() == "t" {
                    if let app = self.appModel, app.selectedTab == .saw {
                        Task { @MainActor in
                            if let pid = app.sawWorkspace.selectedProjectID {
                                let session = app.sawWorkspace.session(for: pid)
                                let tab = session.newTab()
                                app.requestAddressFocus(for: tab, isNewTab: true, isExplicit: true)
                            }
                        }
                        return nil
                    }
                }

                // Cmd + L: explicit address bar focus
                if flags == .command, event.keyCode == 37 || event.charactersIgnoringModifiers?.lowercased() == "l" {
                    if let app = self.appModel {
                        Task { @MainActor in
                            if app.selectedTab == .saw {
                                if let pid = app.sawWorkspace.selectedProjectID {
                                    let session = app.sawWorkspace.session(for: pid)
                                    if let activeTab = session.activeBrowser {
                                        app.requestAddressFocus(for: activeTab, isNewTab: false, isExplicit: true)
                                    }
                                }
                            } else if app.selectedTab == .browser {
                                app.requestAddressFocus(for: app.browser, isNewTab: false, isExplicit: true)
                            }
                        }
                        return nil
                    }
                }

                return event
            }
        }

        private func findCloseItem(in menu: NSMenu) -> NSMenuItem? {
            for item in menu.items {
                if item.action == #selector(NSWindow.performClose(_:)) { return item }
                if let sub = item.submenu, let found = findCloseItem(in: sub) { return found }
            }
            return nil
        }

        /// Rebinds the standard Close (performClose:) menu item so Cmd+W and menu clicks
        /// on the main window go to the browser-tab logic instead of closing the window.
        func installCloseMenuHook() {
            guard let mainMenu = NSApp.mainMenu else { return }
            applyEmbeddedMenuNames(mainMenu)
            if let item = closeItem, item.action == #selector(handleCloseMenu(_:)), item.target === self { return }
            guard let item = findCloseItem(in: mainMenu) else { return }
            originalTarget = item.target
            originalAction = item.action
            item.target = self
            item.action = #selector(handleCloseMenu(_:))
            closeItem = item
        }

        /// HTT 안에서 실행될 때만 앱 메뉴의 'HTD' 표기를 'HTT 브라우저'로 바꾼다(표시 문구만, 동작은 그대로).
        private func applyEmbeddedMenuNames(_ mainMenu: NSMenu) {
            guard AppIdentity.isEmbedded, let appMenuItem = mainMenu.items.first, let appMenu = appMenuItem.submenu else { return }
            let name = AppIdentity.displayName
            if appMenu.title != name { appMenu.title = name }
            if appMenuItem.title != name { appMenuItem.title = name }
            for item in appMenu.items where item.title.contains("HTD") {
                item.title = item.title.replacingOccurrences(of: "HTD", with: name)
            }
        }

        private func restoreCloseMenu() {
            if let item = closeItem, item.target === self {
                item.target = originalTarget
                item.action = originalAction
            }
            closeItem = nil
        }

        @MainActor @objc func handleCloseMenu(_ sender: Any?) {
            #if HTT_HOST
            if HTDHostExport.shared.hostedToolID != nil {
                if let action = originalAction {
                    NSApp.sendAction(action, to: originalTarget, from: sender)
                }
                return
            }
            #endif
            if let window = attachedView?.window, NSApp.keyWindow === window || NSApp.mainWindow === window {
                Task { @MainActor [weak self] in
                    self?.appModel?.handleCloseBrowserShortcut()
                }
                return
            }
            if let action = originalAction {
                NSApp.sendAction(action, to: originalTarget, from: sender)
            }
        }

        func cleanup() {
            restoreCloseMenu()
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers.removeAll()
            observedWindow = nil
            if let monitor = monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        func attachWindowAndRestoreSizeIfNeeded() {
            guard let window = attachedView?.window else { return }
            appModel?.browserWindow = window
            if let appModel { MainActor.assumeIsolated { ExternalURLCoordinator.shared.bind(appModel) } }
            if observedWindow !== window {
                observedWindow = window
                observers.append(NotificationCenter.default.addObserver(
                    forName: NSWindow.didResizeNotification,
                    object: window,
                    queue: .main
                ) { [weak window] _ in
                    guard let win = window else { return }
                    // Ignore fullscreen and minimized states
                    if win.styleMask.contains(.fullScreen) || win.isMiniaturized { return }
                    let size = win.contentRect(forFrameRect: win.frame).size
                    WindowSizeStore.saveSize(size)
                })
            }

            if !hasAppliedRestoredSize {
                hasAppliedRestoredSize = true
                if let size = WindowSizeStore.savedSize {
                    WindowSizeStore.applySize(size, to: window)
                }
            }
        }

        deinit {
            cleanup()
        }
    }
}

// MARK: - Window Size Persistence

private enum WindowSizeStore {
    private static let keyWidth = "htd_last_window_content_width"
    private static let keyHeight = "htd_last_window_content_height"

    static var savedSize: CGSize? {
        if ProcessInfo.processInfo.environment["HTTPSDOWN_APP_SUPPORT_DIR"] != nil {
            return nil
        }
        let w = HTDBrowserDefaults.standard.double(forKey: keyWidth)
        let h = HTDBrowserDefaults.standard.double(forKey: keyHeight)
        guard isValid(width: w, height: h) else { return nil }
        return CGSize(width: w, height: h)
    }

    static func saveSize(_ size: CGSize) {
        if ProcessInfo.processInfo.environment["HTTPSDOWN_APP_SUPPORT_DIR"] != nil {
            return
        }
        guard isValid(width: size.width, height: size.height) else { return }
        HTDBrowserDefaults.standard.set(size.width, forKey: keyWidth)
        HTDBrowserDefaults.standard.set(size.height, forKey: keyHeight)
    }

    static func applySize(_ size: CGSize, to window: NSWindow) {
        guard isValid(width: size.width, height: size.height) else { return }
        let screen = window.screen ?? NSScreen.main
        let maxVisible = screen?.visibleFrame.size ?? CGSize(width: 3840, height: 2160)
        let clampedW = min(max(size.width, 860), maxVisible.width)
        let clampedH = min(max(size.height, 560), maxVisible.height)
        window.setContentSize(CGSize(width: clampedW, height: clampedH))
    }

    private static func isValid(width: Double, height: Double) -> Bool {
        width.isFinite && height.isFinite && width >= 860 && height >= 560
    }
}
