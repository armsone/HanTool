import SwiftUI
import AppKit
import WebKit
import Security
import Combine

/// Separately installed browser extension support ("확장 기능").
///
/// The only extension this connects is the one inside the user's own HTT.app (a signed Safari web extension with its
/// own native handler). HTD never copies HTT's resources or translation engine: it points WebKit at the installed
/// app extension bundle (`WKWebExtension(appExtensionBundle:)`), so updating HTT updates the translation, and the
/// resources are read again on every start or explicit reload. Native messages for
/// com.local.screentranslator are forwarded to HTT's own signed Contents/Helpers/SMTBrowserHost (see ExtensionRuntime;
/// no borrowed identity, no other target).
///
/// Everything WebKit-extension related needs macOS 15.4; on older systems the menu says so and nothing else happens.
/// Privacy boundaries: the extension controller runs on the app's own persistent login store (same cookies and
/// proxy path as the pages). The extension's own settings/consent live in a dedicated persistent controller identity,
/// page cookies/logins never do. For the verified HTT extension only, its known API permissions and http/https site
/// access are accepted without repeated prompts (user-authorized); unknown permissions still need real approval.
struct ExtensionUIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// What the user is asked to confirm; WebKit-free so the manager works on every supported macOS.
struct ExtensionSummary {
    let name: String
    let version: String
    let permissions: [String]
    let optionalPermissions: [String]
    let hostPatterns: [String]
    let optionalHostPatterns: [String]
    let hasInjectedContent: Bool
    let loadErrors: [String]

    /// True when everything requested is HTT's known API set and only http/https (or all-http(s)) sites, so no
    /// confirmation dialog is needed. Anything new or unknown still goes through the real confirmation.
    var isKnownHTTAccess: Bool {
        let known = Self.knownPermissionNames
        let all = permissions + optionalPermissions
        guard all.allSatisfy({ known.contains($0) }) else { return false }
        return (hostPatterns + optionalHostPatterns).allSatisfy { Self.isWebPattern($0) }
    }

    /// HTT's known API permission set (auto-allowed for the verified HTT context only).
    static let knownPermissionNames: Set<String> = ["storage", "activeTab", "scripting", "nativeMessaging"]

    /// http/https (or all-http(s)) match patterns only; no file, custom or browser-internal schemes.
    static func isWebPattern(_ pattern: String) -> Bool {
        if pattern == "<all_urls>" { return true }
        guard let range = pattern.range(of: "://") else { return false }
        return ["http", "https", "*"].contains(String(pattern[..<range.lowerBound]).lowercased())
    }

    /// Changes when the requested access changes (an update with the same requests is not asked again).
    var fingerprint: String {
        [permissions.joined(separator: ","), hostPatterns.joined(separator: ","),
         optionalPermissions.joined(separator: ","), optionalHostPatterns.joined(separator: ",")]
            .joined(separator: "|")
    }
}

/// A verified HTT installation.
struct ExtensionIdentity {
    let appURL: URL
    let appexURL: URL
    let appexBundle: Bundle
    let appName: String
    let appIdentifier: String
}

enum ExtensionTabChange { case title, url, loading }

@MainActor
final class BrowserExtensionManager: ObservableObject {
    enum Status: Equatable {
        case unavailable
        case notConnected
        case loading
        case needsConsent(String)
        case connected
        case failed(String)
    }

    /// The one native-messaging peer that may ever be used: HTT's own app extension.
    static let expectedExtensionIdentifier = "com.local.screentranslator.safari-extension"
    static let installedAppPath = "/Applications/HanTool.app"
    static let httBundleIdentifier = "com.local.screentranslator"

    /// HTD가 HTT.app/Contents/Helpers/HTD.app 안에서 실행 중이거나 HTT_HOST 하에서 호스트 번들일 때의 HTT.app.
    /// 위치 구조, HTT 앱 식별자, HTD와 같은 개발자 서명(팀)을 모두 만족할 때만 인정한다(아니면 nil, 기존 방식 유지).
    static let embeddingHTTApp: URL? = {
        #if HTT_HOST
        let app = Bundle.main.bundleURL.resolvingSymlinksInPath()
        guard Bundle.main.bundleIdentifier == httBundleIdentifier,
              let own = ownTeamIdentifier(), teamIdentifier(of: app) == own else { return nil }
        return app
        #else
        let me = Bundle.main.bundleURL.resolvingSymlinksInPath()
        let helpers = me.deletingLastPathComponent()
        let contents = helpers.deletingLastPathComponent()
        let app = contents.deletingLastPathComponent()
        guard me.lastPathComponent == "HTD.app", helpers.lastPathComponent == "Helpers",
              contents.lastPathComponent == "Contents", app.pathExtension == "app",
              Bundle(url: app)?.bundleIdentifier == httBundleIdentifier,
              let own = ownTeamIdentifier(), teamIdentifier(of: app) == own else { return nil }
        return app
        #endif
    }()
    private static let extensionPoint = "com.apple.Safari.web-extension"
    private static let pathKey = "htd.httExtension.appPath"
    private static let enabledKey = "htd.httExtension.enabled"
    private static let approvedKey = "htd.httExtension.approvedAccess"

    @Published private(set) var status: Status
    @Published private(set) var extensionName: String?
    @Published private(set) var extensionVersion: String?
    /// Problems WebKit reported for the extension (load or runtime), shown instead of any success claim.
    @Published private(set) var issues: [String] = []
    @Published private(set) var notice: String?
    @Published private(set) var registeredAppPath: String?
    @Published private(set) var isEnabled = true
    /// Bumped when the extension's toolbar action (icon, badge, enabled) changed.
    @Published private(set) var actionRevision = 0

    private weak var appModel: AppModel?
    let persists: Bool
    private var runtimeObject: AnyObject?
    private var loadGeneration = 0
    private var cancellables = Set<AnyCancellable>()

    init(appModel: AppModel, persists: Bool) {
        self.appModel = appModel
        self.persists = persists
        if #available(macOS 15.4, *) {
            status = .notConnected
        } else {
            status = .unavailable
        }
        if persists {
            let d = HTDBrowserDefaults.standard
            registeredAppPath = d.string(forKey: Self.pathKey)
            isEnabled = d.object(forKey: Self.enabledKey) as? Bool ?? true
        }
        // HTT 안에서 실행 중이면 그 HTT를 쓴다(저장된 경로는 건드리지 않고, 별도 설치한 HTD 설정과 섞이지 않게 저장하지 않는다).
        if let embedded = Self.embeddingHTTApp { registeredAppPath = embedded.path }

        appModel.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                if !self.isBrowserVisiblyActive {
                    self.closeActionPopover()
                } else if #available(macOS 15.4, *), let rt = self.currentRuntime, !rt.matchesPopupSnapshot() {
                    self.closeActionPopover()
                }
            }
            .store(in: &cancellables)

        UnifiedNavigationModel.shared.$destination
            .receive(on: RunLoop.main)
            .sink { [weak self] destination in
                guard let self = self else { return }
                if destination != .browser {
                    self.closeActionPopover()
                }
                self.actionRevision += 1
            }
            .store(in: &cancellables)
    }

    var isInsideHTT: Bool { Self.embeddingHTTApp != nil }

    // MARK: State for the UI

    var isSupported: Bool {
        if #available(macOS 15.4, *) { return true }
        return false
    }

    var isConnected: Bool { status == .connected }

    var installedAppAvailable: Bool {
        FileManager.default.fileExists(atPath: Self.installedAppPath)
    }

    var statusText: String {
        switch status {
        case .unavailable: return "이 기능은 macOS 15.4 이상에서만 쓸 수 있습니다."
        case .notConnected:
            if registeredAppPath != nil && !isEnabled { return "연결 꺼짐" }
            if registeredAppPath != nil { return "브라우저 세션이 시작되면 불러옵니다" }
            return "연결된 확장 없음"
        case .loading: return "불러오는 중…"
        case .needsConsent(let why): return why
        case .connected:
            let name = extensionName ?? "확장"
            return "\(name) \(extensionVersion ?? "") 불러옴".trimmingCharacters(in: .whitespaces)
        case .failed(let why): return "연결하지 못했습니다: " + why
        }
    }

    /// Visible problem text for the browser banner (failures and WebKit-reported issues).
    var problemText: String? {
        var parts: [String] = []
        if case .failed(let why) = status { parts.append("확장 연결 실패: " + why) }
        if case .needsConsent(let why) = status { parts.append(why) }
        if !issues.isEmpty { parts.append("확장 문제: " + issues.prefix(3).joined(separator: " / ")) }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    var isBrowserVisiblyActive: Bool {
        guard let app = appModel, app.selectedTab == .browser else { return false }
        guard UnifiedNavigationModel.shared.destination == .browser else { return false }
        #if HTT_HOST
        guard HTDHostExport.shared.hostedToolID == nil else { return false }
        #endif
        return app.browser.usesPrimaryStore && app.browser.webView != nil && !app.browser.isShowingHome
    }

    var canPerformAction: Bool {
        guard isConnected else { return false }
        return isBrowserVisiblyActive
    }

    func dismissNotice() { notice = nil }

    // MARK: Attaching to web views

    /// Called for EVERY web view configuration (normal tabs and pop-ups) before its WKWebView is created. The
    /// controller is bound to the same app-owned persistent store as the pages.
    func attach(to config: WKWebViewConfiguration, store: WKWebsiteDataStore) {
        guard #available(macOS 15.4, *) else { return }
        guard let rt = runtime(for: store) else { return }
        config.webExtensionController = rt.controller
    }

    @available(macOS 15.4, *)
    private func runtime(for store: WKWebsiteDataStore) -> ExtensionRuntime? {
        if let rt = runtimeObject as? ExtensionRuntime, rt.store === store { return rt }
        guard let app = appModel else { return nil }
        if let old = runtimeObject as? ExtensionRuntime {
            // The session store was replaced: the old controller (bound to the old store) goes away.
            old.shutdown()
            runtimeObject = nil
            loadGeneration += 1
            extensionName = nil
            extensionVersion = nil
            issues = []
            status = .notConnected
        }
        let rt = ExtensionRuntime(manager: self, appModel: app, store: store, persistent: persists)
        runtimeObject = rt
        if let path = registeredAppPath, isEnabled {
            beginLoad(appURL: URL(fileURLWithPath: path), firstConnection: false)
        }
        return rt
    }

    @available(macOS 15.4, *)
    private var currentRuntime: ExtensionRuntime? { runtimeObject as? ExtensionRuntime }

    // MARK: Menu actions

    /// '확장 기능' → 'HTT 번역 확장 연결…': the user picks HTT.app.
    func chooseAppAndConnect() {
        guard isSupported else { return }
        let panel = NSOpenPanel()
        panel.title = "HanTool.app 선택"
        panel.message = "연결할 한툴 앱을 선택하세요. 앱 파일은 읽기만 하고 복사하거나 바꾸지 않습니다."
        panel.prompt = "선택"
        panel.allowedContentTypes = [.application]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        beginLoad(appURL: url, firstConnection: true)
    }

    func connectInstalledApp() {
        guard isSupported else { return }
        beginLoad(appURL: URL(fileURLWithPath: Self.installedAppPath), firstConnection: true)
    }

    /// '업데이트 다시 불러오기': reads the installed extension again (HTT may have been updated).
    func reload() {
        guard isSupported, let path = registeredAppPath else { return }
        isEnabled = true
        save(enabled: true)
        beginLoad(appURL: URL(fileURLWithPath: path), firstConnection: false)
    }

    func setEnabled(_ enabled: Bool) {
        guard isSupported, registeredAppPath != nil else { return }
        isEnabled = enabled
        save(enabled: enabled)
        if enabled {
            reload()
        } else {
            unloadCurrent()
            status = .notConnected
            notice = "한툴 번역 확장 연결을 껐습니다. 한툴 앱 파일은 그대로입니다."
        }
    }

    /// Removes only HTD's own registration of the extension (its path, switch and approval). HTT's files are not touched.
    func removeRegistration() {
        guard isSupported else { return }
        unloadCurrent()
        registeredAppPath = nil
        isEnabled = true
        if persists {
            let d = HTDBrowserDefaults.standard
            d.removeObject(forKey: Self.pathKey)
            d.removeObject(forKey: Self.enabledKey)
            d.removeObject(forKey: Self.approvedKey)
        }
        status = .notConnected
        notice = "한툴 번역 확장 등록을 지웠습니다. 한툴 앱 파일은 그대로입니다."
    }

    /// 'HTT 번역' (menu) and the toolbar button: the user's click is the gesture for the active tab.
    func performAction() {
        guard #available(macOS 15.4, *) else {
            notice = "이 기능은 macOS 15.4 이상에서만 쓸 수 있습니다."
            return
        }
        guard isConnected, let rt = currentRuntime else {
            if installedAppAvailable {
                notice = "설치된 한툴 번역 확장을 연결하는 중입니다…"
                connectInstalledApp()
            } else if !isInsideHTT {
                chooseAppAndConnect()
            } else {
                notice = "확장이 아직 연결되지 않았습니다."
            }
            return
        }
        guard isBrowserVisiblyActive else {
            notice = "브라우저 화면에서 실행해 주세요."
            return
        }
        notice = "번역 메뉴를 여는 중입니다…"
        if let problem = rt.performAction() { notice = problem }
    }

    func closeActionPopover() {
        guard #available(macOS 15.4, *) else { return }
        currentRuntime?.closeActionPopover()
    }

    // MARK: Loading and consent

    private func unloadCurrent() {
        loadGeneration += 1
        if #available(macOS 15.4, *), let rt = currentRuntime {
            rt.unloadCurrent()
            rt.discardCandidate()
        }
        extensionName = nil
        extensionVersion = nil
        issues = []
    }

    private func save(path: String? = nil, enabled: Bool? = nil, approved: String? = nil) {
        if let path = path { registeredAppPath = path }
        guard persists else { return }
        let d = HTDBrowserDefaults.standard
        if let path = path, path != Self.embeddingHTTApp?.path { d.set(path, forKey: Self.pathKey) }
        if let enabled = enabled { d.set(enabled, forKey: Self.enabledKey) }
        if let approved = approved { d.set(approved, forKey: Self.approvedKey) }
    }

    private var approvedAccess: String? {
        persists ? HTDBrowserDefaults.standard.string(forKey: Self.approvedKey) : nil
    }

    private func beginLoad(appURL: URL, firstConnection: Bool) {
        guard #available(macOS 15.4, *) else {
            status = .unavailable
            return
        }
        guard let rt = currentRuntime else {
            notice = "브라우저 세션이 아직 시작되지 않았습니다. 브라우저에서 페이지를 연 뒤 다시 시도해 주세요."
            return
        }
        loadGeneration += 1
        let generation = loadGeneration
        status = .loading
        notice = nil
        issues = []
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            do {
                let identity = try Self.verify(appURL: appURL)
                let summary = try await rt.loadCandidate(bundle: identity.appexBundle)
                guard generation == self.loadGeneration else { rt.discardCandidate(); return }
                let autoAccess = summary.isKnownHTTAccess
                if !autoAccess && (firstConnection || self.approvedAccess != summary.fingerprint) {
                    // Changed or new access is never active before the user confirms it.
                    rt.unloadCurrent()
                    guard Self.askConsent(summary: summary, identity: identity) else {
                        rt.discardCandidate()
                        self.extensionName = nil
                        self.extensionVersion = nil
                        if firstConnection && self.registeredAppPath == nil {
                            self.status = .notConnected
                            self.notice = "허용하지 않아 연결하지 않았습니다."
                        } else {
                            self.status = .needsConsent("권한 확인이 필요합니다. '업데이트 다시 불러오기'에서 다시 확인해 주세요.")
                        }
                        return
                    }
                }
                try rt.activateCandidate(grantWebSites: autoAccess)
                self.save(path: appURL.path, enabled: true, approved: summary.fingerprint)
                self.isEnabled = true
                self.extensionName = summary.name
                self.extensionVersion = summary.version
                self.issues = rt.currentIssues()
                self.status = .connected
                self.notice = firstConnection
                    ? "\(summary.name) 확장을 불러왔습니다.\(autoAccess ? " 알려진 기능과 http/https 사이트 접근은 자동으로 허용했습니다." : "") 번역이 실제로 되는지는 '한툴 번역'을 실행해 확인해 주세요."
                    : nil
            } catch {
                guard generation == self.loadGeneration else { return }
                rt.discardCandidate()
                self.extensionName = nil
                self.extensionVersion = nil
                self.status = .failed(error.localizedDescription)
            }
        }
    }

    func setIssues(_ list: [String]) {
        issues = list
    }

    // MARK: HTT identity (signature and identifier), no WebKit

    static func verify(appURL: URL) throws -> ExtensionIdentity {
        var isDir: ObjCBool = false
        guard appURL.pathExtension.lowercased() == "app",
              FileManager.default.fileExists(atPath: appURL.path, isDirectory: &isDir), isDir.boolValue,
              let appBundle = Bundle(url: appURL), let appID = appBundle.bundleIdentifier else {
            throw ExtensionUIError(message: "선택한 항목이 앱(.app)이 아닙니다.")
        }
        let plugIns = appURL.appendingPathComponent("Contents/PlugIns", isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(at: plugIns, includingPropertiesForKeys: nil)) ?? []
        for url in entries where url.pathExtension.lowercased() == "appex" {
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier, id == expectedExtensionIdentifier,
                  id.hasPrefix(appID + "."),
                  let ext = bundle.infoDictionary?["NSExtension"] as? [String: Any],
                  ext["NSExtensionPointIdentifier"] as? String == extensionPoint else { continue }
            if let problem = signatureProblem(appURL) { throw ExtensionUIError(message: "한툴 앱: " + problem) }
            if let problem = signatureProblem(url) { throw ExtensionUIError(message: "한툴 확장: " + problem) }
            let name = (appBundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (appBundle.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? appURL.deletingPathExtension().lastPathComponent
            return ExtensionIdentity(appURL: appURL, appexURL: url, appexBundle: bundle, appName: name, appIdentifier: appID)
        }
        throw ExtensionUIError(message: "이 앱에서 한툴 웹 번역 확장(\(expectedExtensionIdentifier))을 찾지 못했습니다.")
    }

    private static func ownTeamIdentifier() -> String? {
        var dynamic: SecCode?
        var code: SecStaticCode?
        guard SecCodeCopySelf(SecCSFlags(rawValue: 0), &dynamic) == errSecSuccess, let dynamic,
              SecCodeCopyStaticCode(dynamic, SecCSFlags(rawValue: 0), &code) == errSecSuccess, let code else { return nil }
        return teamIdentifier(code)
    }

    private static func teamIdentifier(of url: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(rawValue: 0), &code) == errSecSuccess, let code else { return nil }
        return teamIdentifier(code)
    }

    private static func teamIdentifier(_ code: SecStaticCode) -> String? {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: UInt32(kSecCSSigningInformation)), &info) == errSecSuccess,
              let dict = info as? [String: Any], let team = dict[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty else { return nil }
        return team
    }

    /// Checks the code signature as it is (nothing is re-signed or bypassed).
    fileprivate static func signatureProblem(_ url: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(rawValue: 0), &code) == errSecSuccess, let code = code else {
            return "서명 정보를 읽지 못했습니다."
        }
        let flags = SecCSFlags(rawValue: UInt32(kSecCSCheckAllArchitectures | kSecCSStrictValidate))
        let status = SecStaticCodeCheckValidityWithErrors(code, flags, nil, nil)
        return status == errSecSuccess ? nil : "코드 서명이 올바르지 않습니다 (오류 \(status))."
    }

    // MARK: Prompts

    /// Plain confirmation: "허용 안 함" is the default button; only the second button allows.
    static func confirm(message: String, detail: String, allow: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.alertStyle = .informational
        alert.addButton(withTitle: "허용 안 함")
        alert.addButton(withTitle: allow)
        alert.window.appearance = NSApp.keyWindow?.appearance
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertSecondButtonReturn
    }

    static func listText(_ items: [String], limit: Int = 12) -> String {
        if items.isEmpty { return "없음" }
        let shown = items.prefix(limit).joined(separator: ", ")
        return items.count > limit ? shown + " 외 \(items.count - limit)개" : shown
    }

    private static func askConsent(summary: ExtensionSummary, identity: ExtensionIdentity) -> Bool {
        var lines: [String] = []
        lines.append("앱: \(identity.appURL.path) (코드 서명 확인됨)")
        lines.append("요청하는 기능: " + listText(summary.permissions))
        if summary.permissions.contains("nativeMessaging") {
            lines.append("한툴 앱과 통신(nativeMessaging)은 서명된 한툴 앱 확장 \(expectedExtensionIdentifier) 한 곳과만 이루어집니다.")
        }
        lines.append("접근을 요청하는 사이트: " + listText(summary.hostPatterns))
        lines.append("알려진 기능 외의 요청과 http/https가 아닌 주소는 허용되지 않습니다.")
        if summary.hasInjectedContent {
            lines.append("허용한 사이트에서는 확장이 페이지에 스크립트를 넣을 수 있습니다.")
        }
        if !summary.loadErrors.isEmpty {
            lines.append("읽는 중 알려진 문제: " + listText(summary.loadErrors, limit: 3))
        }
        lines.append("페이지 내용은 '한툴 번역'을 직접 실행하고 해당 사이트 접근을 허용한 경우에만 확장이 읽습니다. 이 앱은 아무것도 몰래 보내지 않습니다.")
        return confirm(message: "\(summary.name) \(summary.version) 확장을 이 브라우저에 연결할까요?",
                       detail: lines.joined(separator: "\n\n"), allow: "연결")
    }

    // MARK: Lifecycle notifications (tabs of AppModel)

    func tabOpened(_ tab: LoginBrowserModel) {
        guard #available(macOS 15.4, *), let rt = currentRuntime else { return }
        rt.announceOpen(tab)
    }

    func tabActivated(_ tab: LoginBrowserModel, previous: LoginBrowserModel?) {
        guard #available(macOS 15.4, *), let rt = currentRuntime else { return }
        actionRevision += 1
        guard tab.usesPrimaryStore else { return }
        rt.controller.didActivateTab(rt.adapter(for: tab), previousActiveTab: previous.flatMap { $0.usesPrimaryStore ? rt.adapter(for: $0) : nil })
    }

    func tabClosed(_ tab: LoginBrowserModel) {
        guard #available(macOS 15.4, *), let rt = currentRuntime else { return }
        rt.controller.didCloseTab(rt.adapter(for: tab), windowIsClosing: false)
        rt.forget(tab)
    }

    func tabChanged(_ tab: LoginBrowserModel, _ change: ExtensionTabChange) {
        guard #available(macOS 15.4, *), let rt = currentRuntime, tab.usesPrimaryStore else { return }
        let props: WKWebExtension.TabChangedProperties
        switch change {
        case .title: props = .title
        case .url: props = .URL
        case .loading: props = .loading
        }
        rt.controller.didChangeTabProperties(props, for: rt.adapter(for: tab))
        if tab === appModel?.browser { actionRevision += 1 }
    }

    // MARK: Toolbar button support

    func setAnchor(_ view: NSView) {
        guard #available(macOS 15.4, *) else { return }
        currentRuntime?.anchor = view
    }

    func toolbarIcon() -> NSImage? {
        guard #available(macOS 15.4, *), let rt = currentRuntime else { return nil }
        return rt.currentAction()?.icon(for: CGSize(width: 18, height: 18))
    }

    var toolbarLabel: String {
        guard #available(macOS 15.4, *), let rt = currentRuntime, let action = rt.currentAction() else { return "한툴 번역" }
        return action.label.isEmpty ? "한툴 번역" : action.label
    }

    func bumpAction() { actionRevision += 1 }
}

// MARK: - WebKit runtime (macOS 15.4+)

@available(macOS 15.4, *)
@MainActor
final class ExtensionRuntime: NSObject, WKWebExtensionControllerDelegate {
    let controller: WKWebExtensionController
    let store: WKWebsiteDataStore
    weak var manager: BrowserExtensionManager?
    weak var appModel: AppModel?
    weak var anchor: NSView?
    private(set) var context: WKWebExtensionContext?
    private var candidate: WKWebExtension?
    private var windowAdapter: ExtensionWindowAdapter!
    private var tabAdapters: [UUID: ExtensionTabAdapter] = [:]
    private var announced = Set<UUID>()
    private var errorObserver: NSObjectProtocol?
    private var candidateAppURL: URL?
    private var helperAppURL: URL?
    private var helper: HelperChannel?
    /// When the user last pressed the HTT button/menu item; the popup asks once ("htdHostIntent") whether to start translating.
    private var translateIntentAt: Date?
    private var pendingReplies: [String: PendingReply] = [:]
    private var partialTranslations: [String: [[String: Any]]] = [:]
    private weak var activePopover: NSPopover?
    private var popupTargetTabID: UUID?
    private var popupTargetURL: URL?

    internal var isBrowserVisiblyActive: Bool {
        manager?.isBrowserVisiblyActive == true
    }

    func matchesPopupSnapshot() -> Bool {
        guard activePopover != nil else { return true }
        guard let app = appModel else { return false }
        if let targetTabID = popupTargetTabID, app.browser.tabID != targetTabID {
            return false
        }
        if let targetURL = popupTargetURL, app.browser.currentURL != targetURL {
            return false
        }
        return true
    }

    static let nativeApplicationIdentifier = "com.local.screentranslator"
    static let nativeOrigin = "htd-web-extension://com.hanstree.HttpsDown/"
    private static let maxPending = 16
    private static let maxInputFrame = 16 * 1024 * 1024
    private static let maxOutputFrame = 1_000_000
    private static let requestTimeout: UInt64 = 120
    /// Google/DeepL translate requests run through HTT's external engines, which allow up to 600 s there.
    private static let externalTranslateTimeout: UInt64 = 600

    private static func timeoutSeconds(for message: [String: Any]) -> UInt64 {
        let type = (message["type"] as? String)?.lowercased()
        guard type == "translate" || type == "ocr" || type == "image" else { return requestTimeout }
        let payload = message["payload"] as? [String: Any]
        let engine = ((message["engine"] as? String) ?? (payload?["engine"] as? String))?.lowercased()
        return engine == "google" || engine == "deepl" ? externalTranslateTimeout : requestTimeout
    }

    private struct PendingReply {
        let reply: (Any?, (any Error)?) -> Void
        let timeout: Task<Void, Never>
    }

    /// Own helper process. `closed` and the stdin descriptor are only touched on `queue`.
    private final class HelperChannel: @unchecked Sendable {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let queue = DispatchQueue(label: "htd.htt.nativehost.write")
        var closed = false

        func write(frame: Data) -> Bool {
            if closed { return false }
            var length = UInt32(frame.count).littleEndian
            var data = Data(bytes: &length, count: 4)
            data.append(frame)
            let fd = input.fileHandleForWriting.fileDescriptor
            return data.withUnsafeBytes { raw -> Bool in
                var offset = 0
                while offset < raw.count {
                    let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                    if n < 0 && errno == EINTR { continue }
                    if n <= 0 { return false }
                    offset += n
                }
                return true
            }
        }

        func closeInput() {
            queue.async {
                if self.closed { return }
                self.closed = true
                try? self.input.fileHandleForWriting.close()
            }
        }
    }

    /// Fixed identities so the extension's own settings/consent survive restarts and updates.
    private static let controllerIdentifier = UUID(uuidString: "6F1D2C4A-8B3E-4D57-9A10-4C2E7B5D9F31")!
    private static let contextIdentifier = "6f1d2c4a-8b3e-4d57-9a10-4c2e7b5d9f32"

    /// HTT's known API permission set (auto-allowed for the verified HTT context only).
    static let knownPermissionNames = ExtensionSummary.knownPermissionNames

    init(manager: BrowserExtensionManager, appModel: AppModel, store: WKWebsiteDataStore, persistent: Bool) {
        // Extension settings persist only for the production controller (fixture runs stay non-persistent).
        // Pages always use the app's own login store (never Safari's), same proxy path.
        let configuration = persistent
            ? WKWebExtensionController.Configuration(identifier: Self.controllerIdentifier)
            : WKWebExtensionController.Configuration.nonPersistent()
        configuration.defaultWebsiteDataStore = store
        self.controller = WKWebExtensionController(configuration: configuration)
        self.store = store
        self.manager = manager
        self.appModel = appModel
        super.init()
        windowAdapter = ExtensionWindowAdapter(runtime: self)
        controller.delegate = self
        controller.didOpenWindow(windowAdapter)
        for tab in appModel.tabs { announceOpen(tab) }
        controller.didFocusWindow(windowAdapter)
    }

    /// Each tab is announced to the controller once.
    func announceOpen(_ tab: LoginBrowserModel) {
        guard announced.insert(tab.tabID).inserted else { return }
        controller.didOpenTab(adapter(for: tab))
    }

    func shutdown() {
        unloadCurrent()
        discardCandidate()
        controller.delegate = nil
        tabAdapters = [:]
    }

    func adapter(for tab: LoginBrowserModel) -> ExtensionTabAdapter {
        if let existing = tabAdapters[tab.tabID] { return existing }
        let made = ExtensionTabAdapter(model: tab, runtime: self)
        tabAdapters[tab.tabID] = made
        return made
    }

    func forget(_ tab: LoginBrowserModel) {
        tabAdapters[tab.tabID] = nil
        announced.remove(tab.tabID)
    }

    var window: ExtensionWindowAdapter { windowAdapter }

    // MARK: Loading

    func loadCandidate(bundle: Bundle) async throws -> ExtensionSummary {
        let ext = try await WKWebExtension(appExtensionBundle: bundle)
        candidate = ext
        // <app>.app/Contents/PlugIns/<name>.appex
        candidateAppURL = bundle.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func names(_ set: Set<WKWebExtension.Permission>) -> [String] { set.map { $0.rawValue }.sorted() }
        func patterns(_ set: Set<WKWebExtension.MatchPattern>) -> [String] { set.map { $0.string }.sorted() }
        return ExtensionSummary(
            name: ext.displayName ?? ext.displayShortName ?? "확장",
            version: ext.displayVersion ?? ext.version ?? "",
            permissions: names(ext.requestedPermissions),
            optionalPermissions: names(ext.optionalPermissions),
            hostPatterns: patterns(ext.requestedPermissionMatchPatterns),
            optionalHostPatterns: patterns(ext.optionalPermissionMatchPatterns),
            hasInjectedContent: ext.hasInjectedContent,
            loadErrors: ext.errors.map { $0.localizedDescription })
    }

    func discardCandidate() { candidate = nil }

    /// Loads the confirmed extension. Only the API permissions that were confirmed (or are HTT's known set) are granted; http/https sites only when the
    /// request was entirely known HTT access.
    func activateCandidate(grantWebSites: Bool = false) throws {
        guard let ext = candidate else { throw ExtensionUIError(message: "불러온 확장이 없습니다.") }
        unloadCurrent()
        let ctx = WKWebExtensionContext(for: ext)
        if manager?.persists == true {
            ctx.uniqueIdentifier = Self.contextIdentifier
            ctx.baseURL = URL(string: "webkit-extension://" + Self.contextIdentifier)!
        }
        for permission in ext.requestedPermissions {
            ctx.setPermissionStatus(.grantedExplicitly, for: permission)
        }
        if grantWebSites {
            for raw in ["http://*/*", "https://*/*"] {
                if let pattern = try? WKWebExtension.MatchPattern(string: raw) {
                    ctx.setPermissionStatus(.grantedExplicitly, for: pattern)
                }
            }
        }
        try controller.load(ctx)
        guard ctx.isLoaded else { throw ExtensionUIError(message: "확장이 불러와지지 않았습니다.") }
        context = ctx
        helperAppURL = candidateAppURL
        candidate = nil
        errorObserver = NotificationCenter.default.addObserver(
            forName: WKWebExtensionContext.errorsDidUpdateNotification, object: ctx, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                self.manager?.setIssues(self.currentIssues())
            }
        }
        if let app = appModel, app.browser.usesPrimaryStore {
            controller.didActivateTab(adapter(for: app.browser), previousActiveTab: nil)
        }
    }

    func closeActionPopover() {
        activePopover?.close()
        activePopover = nil
        popupTargetTabID = nil
        popupTargetURL = nil
        currentAction()?.closePopup()
    }

    func unloadCurrent() {
        closeActionPopover()
        stopHelper(reason: "확장을 내렸습니다.")
        helperAppURL = nil
        if let token = errorObserver { NotificationCenter.default.removeObserver(token) }
        errorObserver = nil
        if let ctx = context {
            do { try controller.unload(ctx) } catch {
                manager?.setIssues(["확장을 내리지 못했습니다: " + error.localizedDescription])
            }
        }
        context = nil
    }

    func currentIssues() -> [String] {
        context?.errors.map { $0.localizedDescription } ?? []
    }

    // MARK: Action

    private func activeAdapter() -> ExtensionTabAdapter? {
        guard let app = appModel, app.browser.usesPrimaryStore else { return nil }
        return adapter(for: app.browser)
    }

    func currentAction() -> WKWebExtension.Action? {
        guard let ctx = context, ctx.isLoaded, let tab = activeAdapter() else { return nil }
        return ctx.action(for: tab)
    }

    /// Returns a message when nothing was started.
    func performAction() -> String? {
        guard let ctx = context, ctx.isLoaded else { return "확장이 불러와져 있지 않습니다." }
        guard let manager = manager, manager.isBrowserVisiblyActive, let tab = activeAdapter() else {
            return "브라우저 화면에서 실행해 주세요."
        }
        guard let app = appModel, app.browser.usesPrimaryStore else {
            return "이 탭은 사이트별 다른 연결로 열려 있어 번역 확장을 사용할 수 없습니다. 연결을 전체 설정과 같게 하면 쓸 수 있습니다."
        }
        guard app.browser.webView != nil, !app.browser.isShowingHome else {
            return "먼저 번역할 웹 페이지를 열어 주세요."
        }
        guard let action = ctx.action(for: tab), action.presentsPopup else {
            return "확장에서 번역 메뉴를 준비하지 못했습니다. 브라우저 추가 기능에서 확장을 다시 불러와 주세요."
        }
        ctx.userGesturePerformed(in: tab)
        translateIntentAt = nil
        popupTargetTabID = app.browser.tabID
        popupTargetURL = app.browser.currentURL
        ctx.performAction(for: tab)
        return nil
    }

    // MARK: Native messaging (HTT's own signed helper, persistent while the extension is loaded)

    private func startHelper() throws -> HelperChannel {
        if let existing = helper, existing.process.isRunning { return existing }
        guard let appURL = helperAppURL else { throw ExtensionUIError(message: "한툴 앱 위치를 알 수 없습니다.") }
        _ = try BrowserExtensionManager.verify(appURL: appURL)
        let helperURL = appURL.appendingPathComponent("Contents/Helpers/SMTBrowserHost")
        let root = appURL.resolvingSymlinksInPath().path + "/"
        var isDir: ObjCBool = false
        guard helperURL.resolvingSymlinksInPath().path.hasPrefix(root),
              FileManager.default.fileExists(atPath: helperURL.path, isDirectory: &isDir), !isDir.boolValue,
              FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            throw ExtensionUIError(message: "한툴 도우미(SMTBrowserHost)를 찾지 못했습니다.")
        }
        if let problem = BrowserExtensionManager.signatureProblem(helperURL) {
            throw ExtensionUIError(message: "한툴 도우미: " + problem)
        }
        let channel = HelperChannel()
        channel.process.executableURL = helperURL
        channel.process.arguments = [Self.nativeOrigin]
        channel.process.environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "TMPDIR": NSTemporaryDirectory()]
        channel.process.standardInput = channel.input
        channel.process.standardOutput = channel.output
        channel.process.standardError = FileHandle.nullDevice
        _ = fcntl(channel.input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        channel.process.terminationHandler = { [weak self, weak channel] process in
            let status = process.terminationStatus
            Task { @MainActor in
                guard let self = self, let channel = channel, self.helper === channel else { return }
                self.stopHelper(reason: "한툴 도우미가 종료되었습니다 (코드 \(status)).")
            }
        }
        do { try channel.process.run() } catch {
            throw ExtensionUIError(message: "한툴 도우미를 시작하지 못했습니다: " + error.localizedDescription)
        }
        helper = channel
        // Drop our copy of the child's write end so the reader sees EOF once the helper exits.
        try? channel.output.fileHandleForWriting.close()
        let limit = Self.maxOutputFrame
        // The thread owns the channel strongly for the whole read loop, so the read descriptor cannot be closed or reused underneath it.
        Thread.detachNewThread { [weak self, channel] in
            let readFD = channel.output.fileHandleForReading.fileDescriptor
            func readExactly(_ count: Int) -> Data? {
                var data = Data(count: count)
                var offset = 0
                while offset < count {
                    let n = data.withUnsafeMutableBytes { Darwin.read(readFD, $0.baseAddress! + offset, count - offset) }
                    if n < 0 && errno == EINTR { continue }
                    if n <= 0 { return nil }
                    offset += n
                }
                return data
            }
            var failure = "한툴 도우미 연결이 끊어졌습니다."
            while let header = readExactly(4) {
                let length = Int(header.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) })
                if length == 0 || length > limit {
                    failure = "한툴 도우미 응답 크기가 올바르지 않습니다."
                    break
                }
                guard let frame = readExactly(length) else { break }
                Task { @MainActor in
                    guard let self = self, self.helper === channel else { return }
                    self.receive(frame)
                }
            }
            Task { @MainActor in
                guard let self = self, self.helper === channel else { return }
                self.stopHelper(reason: failure)
            }
        }
        return channel
    }

    /// Closes stdin and terminates only the helper this runtime started; every waiting request gets the reason.
    private func stopHelper(reason: String) {
        if let channel = helper {
            helper = nil
            channel.closeInput()
            if channel.process.isRunning { channel.process.terminate() }
        }
        failAll(reason)
    }

    private func failAll(_ reason: String) {
        let all = pendingReplies
        pendingReplies = [:]
        partialTranslations.removeAll()
        for entry in all.values {
            entry.timeout.cancel()
            entry.reply(nil, ExtensionUIError(message: reason))
        }
    }

    private func finish(_ id: String, _ result: Any?, _ error: (any Error)?) {
        partialTranslations.removeValue(forKey: id)
        guard let entry = pendingReplies.removeValue(forKey: id) else { return }
        entry.timeout.cancel()
        entry.reply(result, error)
    }

    private func receive(_ frame: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: frame)) as? [String: Any] else { return }
        let type = object["type"] as? String
        if type == "progress" {
            if object["phase"] as? String == "partial",
               let id = object["id"] as? String, pendingReplies[id] != nil,
               let items = object["items"] as? [[String: Any]] {
                partialTranslations[id, default: []].append(contentsOf: items)
            }
            return
        }
        if let id = object["id"] as? String {
            finish(id, object, nil)
        } else if type == "error" {
            let text = (object["message"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "한툴 도우미 오류"
            failAll(text)
        }
    }

    private func send(_ message: [String: Any], id: String, reply: @escaping (Any?, (any Error)?) -> Void) {
        let isCancel = message["type"] as? String == "cancel"
        guard JSONSerialization.isValidJSONObject(message), let data = try? JSONSerialization.data(withJSONObject: message),
              data.count <= Self.maxInputFrame else {
            reply(nil, ExtensionUIError(message: "한툴로 보낼 메시지가 올바르지 않거나 너무 큽니다."))
            return
        }
        if isCancel {
            // Fire and forget: the extension already gave up on that request.
            finish(id, nil, ExtensionUIError(message: "취소되었습니다."))
            if let channel = helper {
                channel.queue.async { _ = channel.write(frame: data) }
            }
            reply(nil, nil)
            return
        }
        guard pendingReplies.count < Self.maxPending, pendingReplies[id] == nil else {
            reply(nil, ExtensionUIError(message: "한툴 요청이 너무 많습니다. 잠시 후 다시 시도해 주세요."))
            return
        }
        let channel: HelperChannel
        do { channel = try startHelper() } catch {
            reply(nil, error)
            return
        }
        let timeoutSeconds = Self.timeoutSeconds(for: message)
        let timeout = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.finish(id, nil, ExtensionUIError(message: "한툴 응답 시간이 지났습니다."))
        }
        pendingReplies[id] = PendingReply(reply: reply, timeout: timeout)
        channel.queue.async { [weak self, weak channel] in
            guard let channel = channel, !channel.write(frame: data) else { return }
            Task { @MainActor in
                guard let self = self, self.helper === channel else { return }
                self.stopHelper(reason: "한툴 도우미에 메시지를 보내지 못했습니다.")
            }
        }
    }

    // MARK: WKWebExtensionControllerDelegate

    func webExtensionController(_ controller: WKWebExtensionController, sendMessage message: Any, toApplicationWithIdentifier applicationIdentifier: String?, for extensionContext: WKWebExtensionContext, replyHandler: @escaping (Any?, (any Error)?) -> Void) {
        guard extensionContext === context, extensionContext.isLoaded, applicationIdentifier == Self.nativeApplicationIdentifier else {
            replyHandler(nil, ExtensionUIError(message: "허용되지 않은 네이티브 메시지 대상입니다."))
            return
        }
        guard let dict = message as? [String: Any], let id = dict["id"] as? String, !id.isEmpty else {
            replyHandler(nil, ExtensionUIError(message: "한툴로 보낼 메시지 형식이 올바르지 않습니다."))
            return
        }
        if dict["type"] as? String == "htdHostIntent" {
            // Answered here, never forwarded to HTT's helper. Valid for a few seconds after the user's click, once only.
            let fresh = translateIntentAt.map { Date().timeIntervalSince($0) < 10 } ?? false
            translateIntentAt = nil
            replyHandler(["id": id, "ok": true, "translate": fresh], nil)
            return
        }
        if dict["type"] as? String == "htdBookmarkTranslation" {
            replyHandler(["id": id, "ok": true, "enabled": false], nil)
            return
        }
        if dict["type"] as? String == "htdTranslationProgress" {
            replyHandler(["id": id, "ok": true, "items": partialTranslations.removeValue(forKey: id) ?? []], nil)
            return
        }
        send(dict, id: id, reply: replyHandler)
    }

    func webExtensionController(_ controller: WKWebExtensionController, openWindowsFor extensionContext: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        [windowAdapter]
    }

    func webExtensionController(_ controller: WKWebExtensionController, focusedWindowFor extensionContext: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        windowAdapter
    }

    func webExtensionController(_ controller: WKWebExtensionController, presentActionPopup action: WKWebExtension.Action, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        guard let manager = manager, manager.isBrowserVisiblyActive else {
            let error = ExtensionUIError(message: "브라우저 화면이 활성화되어 있지 않아 팝업을 열지 못했습니다.")
            manager?.setIssues([error.message])
            completionHandler(error)
            return
        }
        guard let app = appModel,
              let targetTabID = popupTargetTabID, app.browser.tabID == targetTabID,
              let targetURL = popupTargetURL, app.browser.currentURL == targetURL else {
            let error = ExtensionUIError(message: "팝업 대상 탭이나 페이지가 변경되어 팝업을 열지 못했습니다.")
            manager.setIssues([error.message])
            completionHandler(error)
            return
        }
        guard let popover = action.popupPopover else {
            completionHandler(ExtensionUIError(message: "확장 팝업을 만들지 못했습니다."))
            return
        }
        guard let anchor = anchor, anchor.window != nil else {
            let error = ExtensionUIError(message: "확장 버튼이 화면에 없어 팝업을 열지 못했습니다.")
            manager.setIssues([error.message])
            completionHandler(error)
            return
        }
        activePopover = popover
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        manager.dismissNotice()
        completionHandler(nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, didUpdate action: WKWebExtension.Action, forExtensionContext context: WKWebExtensionContext) {
        manager?.bumpAction()
    }

    func webExtensionController(_ controller: WKWebExtensionController, openOptionsPageFor extensionContext: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        completionHandler(ExtensionUIError(message: "이 브라우저는 확장 옵션 페이지를 지원하지 않습니다."))
    }

    private func pageHost(_ tab: (any WKWebExtensionTab)?) -> String {
        guard let adapter = tab as? ExtensionTabAdapter, let host = adapter.model.currentURL?.host else { return "(열린 페이지 없음)" }
        return host
    }

    private func name(_ ctx: WKWebExtensionContext) -> String {
        ctx.webExtension.displayName ?? "확장"
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissions permissions: Set<WKWebExtension.Permission>, in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext, completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void) {
        // Only the context activated after the HTT identity/signature check exists here, so nativeMessaging can only
        // ever reach HTT's own app extension; any other context gets nothing.
        guard extensionContext === context else { completionHandler([], nil); return }
        let asked = permissions
        guard !asked.isEmpty else { completionHandler([], nil); return }
        // HTT's known API set is accepted without a dialog; anything else still needs real approval.
        let known = asked.filter { Self.knownPermissionNames.contains($0.rawValue) }
        let unknown = asked.subtracting(known)
        guard !unknown.isEmpty else { completionHandler(known, nil); return }
        let list = unknown.map { $0.rawValue }.sorted()
        let ok = BrowserExtensionManager.confirm(
            message: "\(name(extensionContext))이(가) 추가 기능 권한을 요청합니다",
            detail: "요청: " + BrowserExtensionManager.listText(list) + "\n현재 페이지: " + pageHost(tab),
            allow: "허용")
        completionHandler(ok ? asked : known, nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionToAccess urls: Set<URL>, in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext, completionHandler: @escaping (Set<URL>, Date?) -> Void) {
        // Verified HTT context only; valid http/https URLs are accepted without a dialog, everything else is refused.
        guard extensionContext === context else { completionHandler([], nil); return }
        let allowed = urls.filter { url in
            guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
            return !(url.host ?? "").isEmpty
        }
        if allowed.count < urls.count {
            manager?.setIssues(["http/https가 아닌 주소에 대한 접근 요청은 허용하지 않았습니다."])
        }
        completionHandler(allowed, nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>, in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext, completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void) {
        guard extensionContext === context else { completionHandler([], nil); return }
        var granted = Set<WKWebExtension.MatchPattern>()
        var refused = false
        for pattern in matchPatterns {
            let raw = pattern.string
            if raw == "<all_urls>" || raw == "*://*/*" {
                // All web sites means exactly http://*/* and https://*/*.
                for web in ["http://*/*", "https://*/*"] {
                    if let p = try? WKWebExtension.MatchPattern(string: web) { granted.insert(p) }
                }
            } else if raw.lowercased().hasPrefix("http://") || raw.lowercased().hasPrefix("https://") {
                granted.insert(pattern)
            } else {
                refused = true
            }
        }
        if refused {
            manager?.setIssues(["http/https가 아닌 사이트 접근 요청은 허용하지 않았습니다."])
        }
        completionHandler(granted, nil)
    }
}

// MARK: - Tab and window adapters over AppModel's tabs

@available(macOS 15.4, *)
@MainActor
final class ExtensionTabAdapter: NSObject, WKWebExtensionTab {
    let model: LoginBrowserModel
    private weak var runtime: ExtensionRuntime?

    init(model: LoginBrowserModel, runtime: ExtensionRuntime) {
        self.model = model
        self.runtime = runtime
    }

    private var app: AppModel? { model.appModel }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        runtime?.window
    }

    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        app?.tabs.firstIndex(where: { $0 === model }) ?? 0
    }

    func webView(for context: WKWebExtensionContext) -> WKWebView? {
        model.usesPrimaryStore ? model.webView : nil
    }

    func title(for context: WKWebExtensionContext) -> String? {
        model.isShowingHome || !model.usesPrimaryStore ? nil : model.pageTitle
    }

    func url(for context: WKWebExtensionContext) -> URL? {
        guard model.usesPrimaryStore, !model.isShowingHome, let url = model.currentURL,
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }

    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool {
        !model.isLoading
    }

    func isSelected(for context: WKWebExtensionContext) -> Bool {
        app?.selectedTabID == model.tabID
    }

    /// Only a real user gesture on the toolbar action (via `userGesturePerformed`) can lead to a temporary grant.
    func shouldGrantPermissionsOnUserGesture(for context: WKWebExtensionContext) -> Bool {
        true
    }

    func activate(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        guard let app = app, app.tabs.contains(where: { $0 === model }) else {
            completionHandler(ExtensionUIError(message: "이 탭은 이미 닫혔습니다."))
            return
        }
        app.selectedTab = .browser
        app.selectTab(model.tabID)
        completionHandler(nil)
    }

    func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            completionHandler(ExtensionUIError(message: "http 또는 https 주소만 열 수 있습니다."))
            return
        }
        model.open(url.absoluteString)
        if let problem = model.lastError {
            completionHandler(ExtensionUIError(message: problem))
        } else {
            completionHandler(nil)
        }
    }

    func reload(fromOrigin: Bool, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        model.reload()
        completionHandler(nil)
    }

    func goBack(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        model.goBack()
        completionHandler(nil)
    }

    func goForward(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        model.goForward()
        completionHandler(nil)
    }

    func size(for context: WKWebExtensionContext) -> CGSize {
        guard let webView = model.webView else { return .zero }
        webView.layoutSubtreeIfNeeded()
        let size = webView.bounds.size
        guard size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite else {
            return .zero
        }
        return size
    }

    /// Snapshot of this tab's own web view (visible area unless the configuration says otherwise).
    func takeSnapshot(using configuration: WKSnapshotConfiguration, for context: WKWebExtensionContext, completionHandler: @escaping (NSImage?, (any Error)?) -> Void) {
        guard runtime?.isBrowserVisiblyActive == true else {
            completionHandler(nil, ExtensionUIError(message: "브라우저 화면이 활성화되어 있지 않아 스냅샷을 촬영하지 못했습니다."))
            return
        }
        guard let app = app,
              app.selectedTab == .browser,
              model.usesPrimaryStore,
              app.selectedTabID == model.tabID,
              let webView = model.webView,
              !model.isShowingHome,
              let currentURL = model.currentURL,
              ["http", "https"].contains(currentURL.scheme?.lowercased() ?? ""),
              webView.window != nil else {
            completionHandler(nil, ExtensionUIError(message: "현재 표시 중인 활성 웹 페이지가 없습니다."))
            return
        }

        webView.layoutSubtreeIfNeeded()
        let bounds = webView.bounds
        guard bounds.width > 0, bounds.height > 0, bounds.width.isFinite, bounds.height.isFinite else {
            completionHandler(nil, ExtensionUIError(message: "웹 페이지 화면 크기를 확인할 수 없습니다."))
            return
        }

        let snapshotConfig = WKSnapshotConfiguration()
        snapshotConfig.rect = bounds
        snapshotConfig.snapshotWidth = NSNumber(value: Double(bounds.width))
        snapshotConfig.afterScreenUpdates = true

        let capturedTabID = model.tabID
        let capturedURL = currentURL
        let capturedWebView = webView

        webView.takeSnapshot(with: snapshotConfig) { [weak self] rawImage, error in
            guard let self = self else {
                completionHandler(nil, ExtensionUIError(message: "페이지 스냅샷 처리가 취소되었습니다."))
                return
            }

            guard self.runtime?.isBrowserVisiblyActive == true else {
                completionHandler(nil, ExtensionUIError(message: "스냅샷 처리 중 브라우저 화면이 비활성화되었습니다."))
                return
            }

            guard let currentApp = self.app,
                  currentApp.selectedTab == .browser,
                  currentApp.selectedTabID == capturedTabID,
                  self.model.tabID == capturedTabID,
                  let liveWebView = self.model.webView,
                  liveWebView === capturedWebView,
                  liveWebView.window != nil,
                  !self.model.isShowingHome,
                  let liveURL = self.model.currentURL,
                  liveURL == capturedURL else {
                completionHandler(nil, ExtensionUIError(message: "스냅샷 촬영 중 활성 탭이나 페이지가 변경되었습니다."))
                return
            }

            if let error = error {
                completionHandler(nil, error)
                return
            }

            guard let rawImage = rawImage,
                  rawImage.size.width > 0,
                  rawImage.size.height > 0,
                  rawImage.size.width.isFinite,
                  rawImage.size.height.isFinite else {
                completionHandler(nil, ExtensionUIError(message: "유효한 스냅샷 이미지를 생성하지 못했습니다."))
                return
            }

            var proposedRect = CGRect(origin: .zero, size: rawImage.size)
            guard let cgImage = rawImage.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
                completionHandler(nil, ExtensionUIError(message: "스냅샷 비트맵을 생성하지 못했습니다."))
                return
            }

            let rep = NSBitmapImageRep(cgImage: cgImage)
            rep.size = rawImage.size
            let concreteImage = NSImage(size: rawImage.size)
            concreteImage.addRepresentation(rep)

            completionHandler(concreteImage, nil)
        }
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        guard let app = app, app.tabs.contains(where: { $0 === model }) else {
            completionHandler(ExtensionUIError(message: "이 탭은 이미 닫혔습니다."))
            return
        }
        app.closeTab(model.tabID)
        completionHandler(nil)
    }
}

@available(macOS 15.4, *)
@MainActor
final class ExtensionWindowAdapter: NSObject, WKWebExtensionWindow {
    private weak var runtime: ExtensionRuntime?

    init(runtime: ExtensionRuntime) {
        self.runtime = runtime
    }

    private var app: AppModel? { runtime?.appModel }

    private var hostWindow: NSWindow? {
        NSApp.mainWindow ?? NSApp.keyWindow
            ?? NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) })
    }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        guard let app = app, let runtime = runtime else { return [] }
        return app.tabs.filter { $0.usesPrimaryStore }.map { runtime.adapter(for: $0) }
    }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        guard let app = app, let runtime = runtime, app.browser.usesPrimaryStore else { return nil }
        return runtime.adapter(for: app.browser)
    }

    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType {
        .normal
    }

    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        guard let window = hostWindow else { return .normal }
        if window.isMiniaturized { return .minimized }
        if window.styleMask.contains(.fullScreen) { return .fullscreen }
        return .normal
    }

    func isPrivate(for context: WKWebExtensionContext) -> Bool {
        false
    }

    func frame(for context: WKWebExtensionContext) -> CGRect {
        hostWindow?.frame ?? .zero
    }

    func screenFrame(for context: WKWebExtensionContext) -> CGRect {
        hostWindow?.screen?.frame ?? NSScreen.main?.frame ?? .zero
    }

    func focus(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        hostWindow?.makeKeyAndOrderFront(nil)
        completionHandler(nil)
    }
}

// MARK: - Toolbar UI

/// Native button for the extension's action. The extension's own popup popover (WKWebExtension.Action.popupPopover)
/// is shown relative to this button, so the popup is always attached to the toolbar and never a detached web view.
struct ExtensionActionButton: NSViewRepresentable {
    @Environment(\.bkPalette) private var palette
    @ObservedObject var manager: BrowserExtensionManager

    final class Coordinator: NSObject {
        var manager: BrowserExtensionManager
        init(manager: BrowserExtensionManager) { self.manager = manager }
        @MainActor @objc func clicked(_ sender: NSButton) {
            manager.performAction()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(manager: manager) }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.bezelStyle = .rounded
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        button.title = "페이지 번역"
        button.target = context.coordinator
        button.action = #selector(Coordinator.clicked(_:))
        manager.setAnchor(button)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        _ = manager.actionRevision
        context.coordinator.manager = manager
        manager.setAnchor(button)
        let isConn = manager.isConnected
        button.attributedTitle = NSAttributedString(string: "페이지 번역", attributes: [.foregroundColor: NSColor(palette.textColor)])
        button.image = (isConn ? manager.toolbarIcon() : nil)
            ?? NSImage(systemSymbolName: "character.bubble", accessibilityDescription: "번역")
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        if isConn {
            let label = manager.toolbarLabel
            let tip = label.isEmpty ? "한툴 번역" : label
            button.toolTip = tip
            button.setAccessibilityLabel(tip)
            button.isEnabled = manager.canPerformAction
        } else {
            let tip = "한툴 번역 (미연결 — 클릭하여 한툴 연결)"
            button.toolTip = tip
            button.setAccessibilityLabel(tip)
            button.isEnabled = manager.isSupported
        }
    }
}

/// The "확장 기능" menu of the browser toolbar.
struct ExtensionMenu: View {
    @ObservedObject var manager: BrowserExtensionManager

    var body: some View {
        Menu {
            Text(manager.statusText)
            if manager.isSupported {
                if manager.isConnected {
                    Button("한툴 번역") { manager.performAction() }
                        .disabled(!manager.canPerformAction)
                    Button("업데이트 다시 불러오기") { manager.reload() }
                } else if manager.registeredAppPath != nil {
                    Button("업데이트 다시 불러오기") { manager.reload() }
                        .disabled(manager.status == .loading)
                }
                Divider()
                if !manager.isInsideHTT {
                    Button("한툴 번역 확장 연결…") { manager.chooseAppAndConnect() }
                        .disabled(manager.status == .loading)
                    if manager.installedAppAvailable {
                        Button("설치된 한툴 사용 (\(BrowserExtensionManager.installedAppPath))") { manager.connectInstalledApp() }
                            .disabled(manager.status == .loading)
                    }
                }
                if manager.registeredAppPath != nil {
                    Divider()
                    Button(manager.isEnabled ? "연결 끄기" : "연결 켜기") { manager.setEnabled(!manager.isEnabled) }
                    if !manager.isInsideHTT {
                        Button("등록 제거 (한툴 파일은 그대로)") { manager.removeRegistration() }
                    }
                }
            }
        } label: {
            Label("확장 기능", systemImage: "puzzlepiece.extension")
        }
        .fixedSize()
        .help("별도로 설치한 한툴 번역 확장을 연결합니다.")
        .accessibilityLabel("확장 기능 메뉴")
    }
}
