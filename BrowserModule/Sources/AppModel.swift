import Foundation
import Darwin
import SwiftUI
import AppKit
import WebKit
import UniformTypeIdentifiers

public enum TabSelection: String, CaseIterable, Identifiable {
    case browser = "브라우저"
    case queue = "대기열"
    case history = "완료기록"
    case settings = "설정"
    case speed = "속도측정"
    case pageVideos = "이 페이지의 영상"
    case addressSearch = "주소창·검색"
    case ai = "비서"
    case saw = "AI플레너"

    public var id: String { rawValue }
    public var iconName: String {
        switch self {
        case .browser: return "globe"
        case .queue: return "arrow.down.circle"
        case .history: return "clock.arrow.circlepath"
        case .settings: return "gearshape"
        case .speed: return "speedometer"
        case .pageVideos: return "film"
        case .addressSearch: return "magnifyingglass"
        case .ai: return "sparkles"
        case .saw: return "checklist"
        }
    }
}

/// Where the app keeps its state. Production defaults are unchanged; the support directory can be redirected
/// (HTTPSDOWN_APP_SUPPORT_DIR) so verification and UI inspection never touch the real history or Downloads.
public struct AppConfiguration {
    public var storeDirectory: URL
    public var workRoot: URL
    public var defaultDestination: String
    public var usesUserDefaults: Bool
    public var refreshHealthOnLaunch = true

    public init(storeDirectory: URL, workRoot: URL, defaultDestination: String, usesUserDefaults: Bool) {
        self.storeDirectory = storeDirectory
        self.workRoot = workRoot
        self.defaultDestination = defaultDestination
        self.usesUserDefaults = usesUserDefaults
    }

    public static func production() -> AppConfiguration {
        let env = ProcessInfo.processInfo.environment
        if let override = env["HTTPSDOWN_APP_SUPPORT_DIR"], override.hasPrefix("/") {
            let dir = URL(fileURLWithPath: override, isDirectory: true)
            let dest = env["HTTPSDOWN_DEFAULT_DESTINATION"].flatMap { $0.hasPrefix("/") ? $0 : nil }
                ?? dir.appendingPathComponent("Downloads").path
            return AppConfiguration(storeDirectory: dir, workRoot: dir.appendingPathComponent("work", isDirectory: true),
                                    defaultDestination: dest, usesUserDefaults: false)
        }
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path
            ?? NSHomeDirectory() + "/Downloads"
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        let dir = support.appendingPathComponent("HttpsDown", isDirectory: true)
        return AppConfiguration(storeDirectory: dir, workRoot: dir.appendingPathComponent("work", isDirectory: true),
                                defaultDestination: downloads, usesUserDefaults: true)
    }
}

/// Why a failed job's connections were refused by "HTTPS 연결 도움", bound to that job's generation and to the helper
/// session it ran on (memory only, hostnames and reason codes only — never paths, queries or credentials).
public struct ConnectionRecovery: Equatable {
    public struct Refusal: Identifiable, Equatable {
        public var id: String { "\(host)|\(code)" }
        public let host: String
        public let code: String
        public let reason: String
    }
    public let generation: Int
    public let helperGeneration: Int
    /// Exact hosts refused as not_allowed: what '허용 후 다시 시도' allows, nothing else (bounded).
    public let allowable: [String]
    /// Not-allowed refusals beyond the bound (not allowed by the button).
    public let omitted: Int
    /// Other refusals (private address, port, DNS, connect failure, plain http): reason only, no allow action.
    public let others: [Refusal]
    public var inProgress = false
    public var problem: String?
}

@MainActor
public final class AppModel: ObservableObject {
    @Published public var jobs: [JobRecord] = []
    /// Job id → refusals seen by that job's last failed run (see ConnectionRecovery).
    @Published public private(set) var connectionRecoveries: [String: ConnectionRecovery] = [:]
    nonisolated static let recoveryHostLimit = 32
    /// Automatic "추가 서버 허용 후 다시 시도" bounds, per logical user attempt (automatic retries do not reset them).
    nonisolated static let autoRecoveryMaxRounds = 8
    nonisolated static let autoRecoveryMaxHosts = 32
    /// '속도 측정' (memory only; see Engine/speed.py).
    @Published public private(set) var speedTest = SpeedTestState()
    @Published public var selectedJobId: String? = nil
    @Published public var selectedTab: TabSelection = .browser {
        didSet {
            if oldValue != selectedTab && (oldValue == .browser || oldValue == .saw || selectedTab == .browser || selectedTab == .saw) {
                browserWindow?.makeFirstResponder(nil)
            }
            if selectedTab != .browser {
                cancelPendingPopupBurstFocus()
            }
        }
    }
    @Published public var destinationFolder: String
    nonisolated static let defaultMaxConcurrentJobs = 3
    nonisolated static let minConcurrentJobs = 1
    nonisolated static let maxAllowedConcurrentJobs = 8
    nonisolated static let maxConcurrentJobsKey = "maxConcurrentJobs"
    @Published public var maxConcurrentJobs: Int {
        didSet {
            let clamped = max(Self.minConcurrentJobs, min(Self.maxAllowedConcurrentJobs, maxConcurrentJobs))
            if maxConcurrentJobs != clamped {
                maxConcurrentJobs = clamped
            }
            if config.usesUserDefaults {
                HTDBrowserDefaults.standard.set(clamped, forKey: Self.maxConcurrentJobsKey)
            }
            processQueue()
        }
    }

    @Published public var engineHealth: EngineHealthStatus = EngineHealthStatus()
    @Published public var urlInput: String = ""
    @Published public var alertMessage: String? = nil
    @Published public var showingAlert: Bool = false
    /// Set when an engine process group could not be confirmed gone; the queue will not start new work.
    @Published public var queueBlockedReason: String? = nil
    /// Attach the app's own login session to the address typed in the main bar (only offered while a session exists).
    @Published public var useLoginSessionForInput: Bool = false
    /// Nonmodal feedback for drag-and-drop or batch ingestion (auto-dismissed; avoids popping alerts per item).
    @Published public var dropFeedback: String? = nil

    public func setDropFeedback(_ message: String) {
        dropFeedback = message
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if self.dropFeedback == message {
                self.dropFeedback = nil
            }
        }
    }

    /// "연결 도움" (app-only loopback proxy). Off by default.
    public let connection = ConnectionManager()
    /// Per-site "HTTPS 연결 도움" choices of the in-app browser (exact host, unset/on/off).
    let siteRoutes: SiteRouteRules
    /// Helper for the browser's assist route while the global switch is OFF (a site was set to ON). It serves browser
    /// tabs only: downloads, the queue, speed checks and the header switch keep using `connection` alone, and a tab
    /// whose site needs it never falls back to a direct connection when it is not ready.
    let browsingConnection = ConnectionManager()
    /// App-owned login session (own persistent WebKit store; cleared only by the user).
    public let session: SessionManager
    /// Separately installed HTT translation extension (see BrowserExtensions.swift); created on first use.
    lazy var extensions: BrowserExtensionManager = BrowserExtensionManager(appModel: self, persists: config.usesUserDefaults)
    /// Open browser tabs (memory only: addresses and titles are never saved). Each tab is its own LoginBrowserModel
    /// with its own WebView, history, candidates and callbacks; they share this app's one session store.
    @Published private(set) var tabs: [LoginBrowserModel]
    @Published private(set) var selectedTabID: UUID
    static let maxTabs = 8
    /// Tab whose address field should take input focus once its view is attached (built-in New Tab only).
    /// BrowserPane consumes and clears it; it is never persisted.
    /// One-shot address-field focus request bound to a tab and (when known) its logical navigation attempt.
    /// `isNewTab`: the tab was just created / reset as a New Tab, so focus applies even if a custom start page loads.
    /// Otherwise (revisiting an empty built-in home) it applies only while the tab still shows an empty home.
    struct AddressFocusRequest: Equatable {
        let tabID: UUID
        let attemptId: Int?   // nil: first launch, the tab is not activated yet (activation opens the start page)
        let isNewTab: Bool
        let isExplicit: Bool

        init(tabID: UUID, attemptId: Int?, isNewTab: Bool = false, isExplicit: Bool = false) {
            self.tabID = tabID
            self.attemptId = attemptId
            self.isNewTab = isNewTab
            self.isExplicit = isExplicit
        }
    }
    @Published private(set) var addressFocusRequest: AddressFocusRequest?
    func requestAddressFocus(for tab: LoginBrowserModel, isNewTab: Bool = false, isExplicit: Bool = false) {
        addressFocusRequest = AddressFocusRequest(tabID: tab.tabID, attemptId: tab.logicalAttemptId, isNewTab: isNewTab, isExplicit: isExplicit)
    }
    func clearAddressFocusRequest() { addressFocusRequest = nil }
    @Published public private(set) var downloadInputFocusRequest: Int = 0
    public func requestDownloadInputFocus() {
        downloadInputFocusRequest &+= 1
    }
    /// Burst of permitted popups: track pending focus to select the first popup after popups settle.
    private var pendingPopupBurstFocusTask: Task<Void, Never>?
    private var pendingPopupBurstFirstTabID: UUID?

    private func schedulePopupBurstFocus(firstTabID: UUID, openerID: UUID) {
        if pendingPopupBurstFirstTabID == nil {
            pendingPopupBurstFirstTabID = firstTabID
        }
        pendingPopupBurstFocusTask?.cancel()
        pendingPopupBurstFocusTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 300_000_000)
            } catch {
                return
            }
            guard let self = self else { return }
            guard !Task.isCancelled else { return }
            defer {
                self.pendingPopupBurstFocusTask = nil
                self.pendingPopupBurstFirstTabID = nil
            }
            guard self.selectedTab == .browser,
                  self.selectedTabID == openerID,
                  let targetID = self.pendingPopupBurstFirstTabID,
                  self.tabs.contains(where: { $0.tabID == targetID }) else {
                return
            }
            self.selectTab(targetID)
        }
    }

    private func cancelPendingPopupBurstFocus() {
        pendingPopupBurstFocusTask?.cancel()
        pendingPopupBurstFocusTask = nil
        pendingPopupBurstFirstTabID = nil
    }
    /// Tab opener relationships (child tabID -> opener tabID).
    private var tabOpeners: [UUID: UUID] = [:]
    func setTabOpener(childID: UUID, openerID: UUID) { tabOpeners[childID] = openerID }
    func tabOpener(for childID: UUID) -> UUID? { tabOpeners[childID] }

    /// The ACTIVE browser tab. Everything that used the app's single browser (the browser screen, the video list,
    /// recovery, job context) keeps working through this accessor; changing the selection republishes the AppModel.
    var browser: LoginBrowserModel { tabs.first(where: { $0.tabID == selectedTabID }) ?? tabs[0] }
    /// Tabs with a live page (can issue requests of their own).
    var liveTabCount: Int { tabs.filter { $0.webView != nil && !$0.isShowingHome }.count }
    /// Browser bookmarks and home/start screen settings.
    public let preferences: BrowserPreferences
    /// Preferred AI services catalog, selection, and custom services store.
    public let aiServices: AIServiceStore
    /// Unprivileged side-panel host for third-party AI web chat.
    public let thirdPartyAIHost: ThirdPartyAIPanelHost
    /// Whether the embedded AI side-panel is currently open.
    @Published public var isAIPanelOpen: Bool = false
    /// Whether the passive video candidates popover in the browser toolbar is currently open.
    @Published public var isMediaCandidatePresented: Bool = false
    /// Set when a specific '하나' command routed explicitly to Hana while a non-Hana provider is selected.
    @Published public var temporaryShowHanaPanel: Bool = false
    /// Sanitized diagnostic trace (memory ring + `<storeDirectory>/Diagnostics`), see Diagnostics.swift.
    let diagnostics: DiagnosticsStore
    /// True from pressing '진단 로그 내보내기' until the ZIP is written or the save panel is dismissed.
    @Published public private(set) var diagnosticsExportBusy = false
    /// Supervised AI Work (SAW) persistent project workspace with independent tab pools.
    private var _sawWorkspace: SAWWorkspace?
    var sawWorkspace: SAWWorkspace {
        if let existing = _sawWorkspace { return existing }
        let ws = SAWWorkspace(appModel: self)
        _sawWorkspace = ws
        return ws
    }

    /// All browser tabs including ordinary tabs and all active SAW project session tabs.
    var allBrowserTabs: [LoginBrowserModel] {
        var list = tabs
        if let ws = _sawWorkspace {
            for session in ws.sessions.values {
                list.append(contentsOf: session.tabs)
            }
        }
        return list
    }
    /// Keys (never values) of the last engine context, for diagnostics/verification.
    private(set) var debugLastContextKeys: [String] = []

    private enum RunKind { case extract, download, record, publish }

    private final class ActiveRun {
        let jobId: String
        let generation: Int
        let kind: RunKind
        let startedAt = Date()
        var handle: EngineTaskHandle?
        var publishControl: PublishControl?
        /// Pause/cancel/delete/quit: the outcome may never be promoted to success.
        var userStopped = false
        /// "녹화 마치고 저장": cooperative finish. Deliberately separate from `userStopped`, because a finished
        /// recording is still decided by the engine's terminal event and the normal exit checks.
        var gracefulFinish = false
        var terminal: String?
        var terminalPayload: [String: Any] = [:]
        var extractPayload: [String: Any]?
        var restoreStateOnStop: JobState?
        /// Proxy client tag of this run ("j<n>"), so the helper's refusals are bound to this run only.
        var proxyClient = ""
        var helperGeneration = 0
        /// Diagnostics only: what this run asked for, and what the exact context submitted to the engine carried.
        var requestedContext: DiagAttachment?
        var attachedContext: DiagAttachment?
        init(jobId: String, generation: Int, kind: RunKind) {
            self.jobId = jobId
            self.generation = generation
            self.kind = kind
        }
    }

    @Published private var activeRuns: [String: ActiveRun] = [:]
    private var isProcessingQueue = false
    private var runSerial = 0
    private var uncleanProcessGroups: [pid_t: EngineTaskHandle] = [:]
    private var hasUnresolvedUnknownCleanup = false
    private var priorNonCleanupBlocker: String? = nil
    private static let engineCleanupBlockedMessage = "엔진 하위 프로세스가 종료되었는지 확인하지 못했습니다. 설정 및 진단에서 '엔진 정리 재확인' 후 다시 시작해 주세요."
    public let config: AppConfiguration
    private let storeURL: URL
    var thumbnailDirectory: URL { config.storeDirectory.appendingPathComponent("thumbnails", isDirectory: true) }

    /// Exact scoped sidecar URL (`<storeDirectory>/support-catalog.json`); respects isolated `HTTPSDOWN_APP_SUPPORT_DIR`.
    public var supportCatalogSidecarURL: URL {
        config.storeDirectory.appendingPathComponent("support-catalog.json", isDirectory: false)
    }

    /// Automatic recovery used so far by one logical user attempt (job id → rounds and exact hosts allowed).
    private struct AutoRecoveryBudget {
        var rounds = 0
        var hosts = 0
    }
    private var autoRecoveryBudgets: [String: AutoRecoveryBudget] = [:]
    /// Job id → generation of an automatic retry that waits for the helper's `policyApplied` (kept out of the queue
    /// until then; removed by cancel/pause/delete/retry/quit, so a late acknowledgement starts nothing).
    private var autoRecoveryWaiting: [String: Int] = [:]
    /// Verification probe only: called right before an automatic retry awaits the helper.
    var debugAutoRecoveryWillAwait: ((String) -> Void)?

    /// In-memory dependency plan for trusted owned engine fallback (bound to clean extract completion).
    private struct DependencyPlan {
        let jobId: String
        let generation: Int
        let helperGeneration: Int
        let hosts: [String]
    }
    private var dependencyPlans: [String: DependencyPlan] = [:]

    /// The one user-started speed measurement (never concurrent with a job: the queue waits while it runs).
    private final class SpeedRun {
        let generation: Int
        let viaHelper: Bool
        var handle: EngineTaskHandle?
        var stopped = false
        /// Proxy client tag ("s<n>") and helper generation pinned at start (helper mode only).
        var client = ""
        var helperGeneration = 0
        var result: [String: Any]?
        var engineError: String?
        init(generation: Int, viaHelper: Bool) {
            self.generation = generation
            self.viaHelper = viaHelper
        }
    }
    private var speedRun: SpeedRun?
    private var speedSerial = 0

    /// True while an engine process or publish is in flight.
    public var hasActiveRun: Bool { !activeRuns.isEmpty }

    /// True from '속도 측정' until the measurement's own process group is gone.
    public var isMeasuringSpeed: Bool { speedRun != nil }

    /// Generation of the running measurement (verification probes: a second press must not start another).
    var debugSpeedRunGeneration: Int? { speedRun?.generation }

    /// Engine handle of an active task (diagnostics and verification probes; serial compatibility).
    var debugActiveHandle: EngineTaskHandle? { activeRuns.values.compactMap { $0.handle }.first }

    /// Engine handle of the active task for a specific job (if running).
    func debugActiveHandle(for jobId: String) -> EngineTaskHandle? { activeRuns[jobId]?.handle }

    public init(configuration: AppConfiguration = .production()) {
        let firstTab = LoginBrowserModel()
        firstTab.startTarget = .newWindow
        self.tabs = [firstTab]
        self.selectedTabID = firstTab.tabID
        self.addressFocusRequest = AddressFocusRequest(tabID: firstTab.tabID, attemptId: nil, isNewTab: true)   // launch: built-in New Tab takes address focus
        self.config = configuration
        self.session = SessionManager(persistent: configuration.usesUserDefaults)
        self.siteRoutes = SiteRouteRules(persists: configuration.usesUserDefaults)
        if configuration.usesUserDefaults,
           let saved = HTDBrowserDefaults.standard.string(forKey: "destinationFolder") {
            self.destinationFolder = saved
        } else {
            self.destinationFolder = configuration.defaultDestination
        }
        if configuration.usesUserDefaults {
            if let saved = HTDBrowserDefaults.standard.object(forKey: Self.maxConcurrentJobsKey) {
                let intVal = (saved as? NSNumber)?.intValue ?? Self.defaultMaxConcurrentJobs
                self.maxConcurrentJobs = max(Self.minConcurrentJobs, min(Self.maxAllowedConcurrentJobs, intVal))
            } else {
                self.maxConcurrentJobs = Self.defaultMaxConcurrentJobs
            }
        } else {
            self.maxConcurrentJobs = Self.defaultMaxConcurrentJobs
        }
        // The old "maxConcurrentFragments" preference stays in UserDefaults untouched but is deprecated and never read.
        try? FileManager.default.createDirectory(at: configuration.storeDirectory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? FileManager.default.createDirectory(at: configuration.workRoot, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        self.storeURL = configuration.storeDirectory.appendingPathComponent("jobs.json")
        self.preferences = BrowserPreferences(storeDirectory: configuration.storeDirectory)
        self.aiServices = AIServiceStore(storeDirectory: configuration.storeDirectory)
        self.thirdPartyAIHost = ThirdPartyAIPanelHost()
        self.diagnostics = DiagnosticsStore(
            directory: configuration.storeDirectory.appendingPathComponent("Diagnostics", isDirectory: true))
        // Derived bookmark icon/color cache lives in this configuration's own store directory (isolated runs never touch production).
        BookmarkAppearanceManager.shared.configurePersistence(
            fileURL: configuration.storeDirectory.appendingPathComponent(BookmarkAppearanceManager.cacheFileName, isDirectory: false))

        loadJobs()
        if configuration.refreshHealthOnLaunch { refreshEngineHealth() }
        firstTab.appModel = self
        connection.onStatusChange = { [weak self] in
            guard let self = self, !self.suppressTabStatusCallback else { return }
            if self.connection.enabled, case .failed = self.connection.status, !self.hasActiveRun && !self.isMeasuringSpeed {
                self.setConnectionAssist(false)
                return
            }
            self.speedConnectionChanged()
            self.processQueue()
            for tab in self.allBrowserTabs { tab.connectionStatusChanged() }
        }
        browsingConnection.onStatusChange = { [weak self] in
            guard let self = self, !self.suppressTabStatusCallback else { return }
            if self.browsingConnection.isReady { self.resetStaleAlternateRouteTabs() }
            for tab in self.allBrowserTabs { tab.connectionStatusChanged() }
        }
        // The user's last "HTTPS 연결 도움" choice (production only; isolated runs start off and never touch preferences).
        connection.persistsChoice = configuration.usesUserDefaults
        // Opt-in browser TLS retry (default off) is applied to both route helpers before they start.
        connection.setAutoRetryTLS(preferences.autoRetryTLS)
        browsingConnection.setAutoRetryTLS(preferences.autoRetryTLS)
        if configuration.usesUserDefaults && ConnectionManager.savedChoice() {
            connection.setEnabled(true)
        }
        processQueue()
        // Eagerly initialize SAW workspace and scheduler once configs and stores are ready
        _ = sawWorkspace
        attachAssistantPlanner()
        session.onLoginContinuityAccessIssue = { [weak self] issue in
            self?.browser.notice = issue
        }
        if let existingIssue = session.loginContinuityAccessIssue {
            browser.notice = existingIssue
        }
    }

    /// Owner of the common planner trigger for every chat host (Hana panel and the third-party panel, catalog and custom
    /// services alike). The sessions share the workspace's one coordinator; lifecycle events only wake its outbox.
    private func attachAssistantPlanner() {
        let coordinator = sawWorkspace.assistantPlanner
        let sessions = [HanaPanelHost.shared.attachPlanner(coordinator: coordinator),
                        thirdPartyAIHost.attachPlanner(coordinator: coordinator)]
        for session in sessions {
            session.onLifecycle = { [weak self] _ in self?._sawWorkspace?.wakeAssistantOutbox() }
        }
    }

    /// Stable owner identity for dock delegation and assistant handoff callbacks.
    public let ownerUUID = UUID()

    /// The pane that currently owns the typed/manual handoff callbacks of the chat hosts (memory only).
    var assistantHandoffOwner: UUID?

    public func setDestinationFolder(_ path: String) {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
            self.destinationFolder = path
            if config.usesUserDefaults { HTDBrowserDefaults.standard.set(path, forKey: "destinationFolder") }
        }
    }

    public func refreshEngineHealth() {
        EngineBridge.shared.checkHealth { [weak self] status in
            MainActor.assumeIsolated { self?.engineHealth = status }
        }
    }

    /// Called when the app quits: cancels every engine group and waits (bounded) for them to disappear.
    public func shutdown() {
        // Capture the resume intent of really-running assistant runs before anything rewrites run state.
        sawWorkspace.beginAssistantShutdown()
        for run in activeRuns.values {
            run.userStopped = true
            _ = run.publishControl?.requestCancel()
            run.handle?.cancel()
        }
        if let run = speedRun {
            run.stopped = true
            run.handle?.cancel()
        }
        // An automatic retry still waiting for the helper must not start on the next launch by itself.
        for (jobId, generation) in autoRecoveryWaiting {
            if let i = jobs.firstIndex(where: { $0.id == jobId && $0.generation == generation }), jobs[i].state == .queued {
                jobs[i].state = .interrupted
                jobs[i].stateMessage = "추가 서버를 허용해 자동으로 다시 시도하기 전에 앱이 종료되었습니다. '다시 시도'를 눌러 주세요."
            }
        }
        autoRecoveryWaiting = [:]
        dependencyPlans.removeAll()
        connection.onStatusChange = nil
        browsingConnection.onStatusChange = nil
        for tab in tabs { tab.teardown() }
        connection.stop()
        browsingConnection.stop()
        thirdPartyAIHost.teardown()
        sawWorkspace.shutdown()
        _ = EngineBridge.shared.terminateAll(timeout: 6.0)
        persistJobs()
    }

    /// Cmd+Q 브라우저 종료: 모든 브라우저 탭과 WKWebView 실행을 즉시 중단하고 해제하며,
    /// 쿠키·로그인·비밀번호·북마크 및 백그라운드 다운로드/플래너 작업은 온전히 보존한 채
    /// 다음 실행 시 주소창 포커스를 가진 새 탭 홈 상태로 시작할 수 있도록 초기화한다.
    public func terminateBrowserExecution() {
        cancelPendingPopupBurstFocus()
        tabOpeners.removeAll()
        for tab in tabs {
            tab.webView?.stopLoading()
            tab.teardown()
            extensions.tabClosed(tab)
        }
        let freshTab = LoginBrowserModel()
        freshTab.startTarget = .newWindow   // reopened window: its first tab starts with the new-window start page
        freshTab.skipStartPage = false
        freshTab.appModel = self
        self.tabs = [freshTab]
        self.selectedTabID = freshTab.tabID
        self.selectedTab = .browser
        requestAddressFocus(for: freshTab, isNewTab: true, isExplicit: true)
    }

    // MARK: - Connection assist / login session

    /// The one "HTTPS 연결 도움" switch: proxy and TLS first-record split together (on) or neither (off).
    /// Mode changes only while nothing runs, so a job never silently switches its connection path mid-way.
    /// One actual change = one helper start/stop and one browser session reset.
    public func setConnectionAssist(_ on: Bool) {
        guard on != connection.enabled else { return }
        guard !hasActiveRun else {
            showAlert("다운로드·녹화가 진행 중일 때는 연결 방식을 바꿀 수 없습니다. 작업이 끝난 뒤 바꿔 주세요.")
            return
        }
        guard !isMeasuringSpeed else {
            showAlert("속도 측정 중에는 연결 방식을 바꿀 수 없습니다. 측정이 끝나거나 취소한 뒤 바꿔 주세요.")
            return
        }
        dependencyPlans.removeAll()
        // stop() fires onStatusChange synchronously, before tabs are snapshotted: a tab could prepare() against the old
        // store and consume its pendingURL. Hold the tab callback until the tabs were torn down and reopened.
        suppressTabStatusCallback = true
        connection.setEnabled(on)
        connectionModeChangedForAllTabs()
        suppressTabStatusCallback = false
        speedConnectionChanged()
        processQueue()
    }
    private var suppressTabStatusCallback = false

    /// Pre-0.4 entry point: the split is no longer a separate option, so this is the same switch.
    public func setSplitTLS(_ on: Bool) {
        setConnectionAssist(on)
    }

    public func restartConnectionAssist() {
        guard !hasActiveRun else {
            showAlert("다운로드·녹화가 진행 중일 때는 연결 도움을 다시 시작할 수 없습니다.")
            return
        }
        guard !isMeasuringSpeed else {
            showAlert("속도 측정 중에는 연결 도움을 다시 시작할 수 없습니다. 측정이 끝나거나 취소한 뒤 다시 시도해 주세요.")
            return
        }
        guard connection.enabled else { return }
        dependencyPlans.removeAll()
        connection.restart()
        // Same switch state: the route of every tab (including a pending inherited one) stays what it was.
        connectionModeChangedForAllTabs(carryPending: true)
    }

    /// "허용 후 다시 시도" on a failed job: allows exactly the hosts this job's last run was refused as not_allowed
    /// (shown on the button), waits until the helper confirmed the update, then retries the same job. Nothing is
    /// allowed for a stale record (job retried/changed, helper restarted or switched off).
    public func allowBlockedAndRetry(jobId: String) {
        guard let rec = connectionRecoveries[jobId], !rec.inProgress, !rec.allowable.isEmpty,
              let index = jobs.firstIndex(where: { $0.id == jobId }),
              jobs[index].generation == rec.generation, jobs[index].state == .failed else { return }
        if jobs[index].urlWasRedacted {
            connectionRecoveries[jobId]?.problem = "보안을 위해 주소의 일부가 저장되지 않아 다시 받을 수 없습니다. 주소를 새로 입력해 주세요."
            return
        }
        guard connection.enabled, connection.isReady, connection.generation == rec.helperGeneration else {
            connectionRecoveries[jobId]?.problem = "HTTPS 연결 도움이 다시 시작되었거나 꺼져 이전 차단 기록으로는 허용하지 않았습니다. '다시 시도'를 눌러 주세요."
            return
        }
        let needed = rec.allowable.filter { !connection.covers(host: $0) }
        let sent = connection.allowExactHosts(needed)
        if sent.count != needed.count {
            let missing = needed.filter { !sent.contains($0) }.joined(separator: ", ")
            connectionRecoveries[jobId]?.problem = "차단 기록이 지워져 다음 주소는 허용하지 않았습니다: \(missing). '다시 시도'로 다시 확인해 주세요."
            if sent.isEmpty { return }
        }
        connectionRecoveries[jobId]?.inProgress = true
        let generation = rec.generation
        connection.awaitPolicyApplied { [weak self] problem in
            guard let self = self, let current = self.connectionRecoveries[jobId], current.generation == generation,
                  let i = self.jobs.firstIndex(where: { $0.id == jobId }), self.jobs[i].generation == generation,
                  self.jobs[i].state == .failed else { return }
            if let problem = problem {
                self.connectionRecoveries[jobId]?.inProgress = false
                self.connectionRecoveries[jobId]?.problem = problem
                return
            }
            if sent.count != needed.count {
                // Partially applied: the user retries explicitly after reading which hosts were not allowed.
                self.connectionRecoveries[jobId]?.inProgress = false
                return
            }
            self.retryJob(jobId: jobId)
        }
    }

    // MARK: Automatic recovery of extra download servers

    enum AutoRecoveryVerdict: Equatable {
        case allow([String])
        /// Empty reason: nothing to say (no allowable host at all).
        case stop(String)
    }

    /// Whether a failed run's refusals may be allowed automatically (pure: also checked in isolation).
    /// Only exact DNS hosts refused as not_allowed for THIS run's client tag, only when they are the whole story of
    /// a normal engine failure, and only within the per-attempt budget. Everything else keeps the manual path.
    nonisolated static func autoRecoveryVerdict(
        allowable: [String], omitted: Int, otherRefusals: Int, uncovered: [String],
        roundsUsed: Int, hostsUsed: Int, cleanFailure: Bool, errorCode: String?, errorDetail: String,
        sourceRedacted: Bool
    ) -> AutoRecoveryVerdict {
        guard !allowable.isEmpty else { return .stop("") }
        if sourceRedacted {
            return .stop("보안을 위해 주소의 일부가 저장되지 않아 자동으로 다시 시도하지 않았습니다. 주소를 새로 입력해 주세요.")
        }
        if !cleanFailure || !["extract_failed", "download_failed"].contains(errorCode ?? "") {
            return .stop("이 실패는 추가 서버 차단만으로 설명되지 않아(엔진 시간 초과·비정상 종료 또는 다른 오류) 자동으로 허용하지 않았습니다.")
        }
        let detail = errorDetail.lowercased()
        let authMarkers = ["http error 401", "http error 403", "http error 407", "login", "log in", "sign in", "sign-in",
                           "cookie", "authenticat", "password", "private video", "members-only", "premium"]
        if authMarkers.contains(where: { detail.contains($0) }) {
            return .stop("로그인·권한 문제로 보이는 실패라 자동으로 허용하지 않았습니다.")
        }
        if detail.contains("http error ") {
            return .stop("서버가 오류 응답을 보낸 실패라 자동으로 허용하지 않았습니다.")
        }
        if otherRefusals > 0 {
            return .stop("사설망·포트·DNS·연결 실패 등 다른 이유로 막힌 연결도 있어 자동으로 허용하지 않았습니다.")
        }
        if uncovered.isEmpty {
            return .stop("새로 허용할 서버가 없는데도 실패해 자동으로 다시 시도하지 않았습니다.")
        }
        if roundsUsed >= autoRecoveryMaxRounds {
            return .stop("자동 재시도 한도(\(autoRecoveryMaxRounds)회)에 도달해 멈췄습니다.")
        }
        if omitted > 0 || hostsUsed + uncovered.count > autoRecoveryMaxHosts {
            return .stop("자동 허용 한도(작업당 추가 서버 \(autoRecoveryMaxHosts)개)를 넘어 더 허용하지 않았습니다.")
        }
        return .allow(uncovered)
    }

    /// Called from `failJob` (same main-actor turn as the exit, so the helper/run state is the one that failed).
    /// Allows exactly the run's not_allowed hosts, requeues the same job as a new generation and keeps it out of the
    /// queue until the helper confirmed the policy. Returns false (manual fallback, reason in the record) otherwise.
    private func startAutoRecovery(index: Int, run: ActiveRun, result: EngineTaskResult,
                                   refused: [ConnectionManager.BlockedHost]) -> Bool {
        let job = jobs[index]
        guard run.kind != .publish, run.restoreStateOnStop == nil, job.runMode == .full,
              connection.enabled, connection.isReady, connection.generation == run.helperGeneration else { return false }
        var allowable: [String] = []
        for host in refused.filter({ $0.canAllow }).map({ $0.host }) where !allowable.contains(host) {
            allowable.append(host)
        }
        let others = refused.filter { !$0.canAllow }.count
        let budget = autoRecoveryBudgets[job.id] ?? AutoRecoveryBudget()
        let clean = run.terminal == "error" && !result.cancelled && !result.timedOut && result.terminatedBySignal == nil
            && result.spawnError == nil && result.readyHandshake && result.groupClean && result.pipesDrained
        // Allow the full in-budget batch; do not let display-cap constants prematurely block automatic recovery
        let uncovered = allowable.filter { !connection.covers(host: $0) }
        let verdict = Self.autoRecoveryVerdict(
            allowable: allowable, omitted: max(0, allowable.count - Self.autoRecoveryMaxHosts), otherRefusals: others,
            uncovered: uncovered,
            roundsUsed: budget.rounds, hostsUsed: budget.hosts, cleanFailure: clean,
            errorCode: run.terminalPayload["code"] as? String,
            errorDetail: run.terminalPayload["detail"] as? String ?? "", sourceRedacted: job.urlWasRedacted)
        guard case .allow(let hosts) = verdict else {
            if case .stop(let why) = verdict, !why.isEmpty { connectionRecoveries[job.id]?.problem = why }
            return false
        }
        let sent = connection.allowExactHosts(hosts)
        guard !sent.isEmpty, Set(sent) == Set(hosts) else {
            connectionRecoveries[job.id]?.problem = "차단 기록이 바뀌어 자동으로 허용하지 않았습니다. 아래 주소를 확인한 뒤 다시 시도해 주세요."
            return false
        }
        let used = AutoRecoveryBudget(rounds: budget.rounds + 1, hosts: budget.hosts + sent.count)
        autoRecoveryBudgets[job.id] = used
        connectionRecoveries[job.id] = nil
        requeueForRetry(index)
        let generation = jobs[index].generation
        jobs[index].stateMessage = "추가 서버 연결을 허용하고 자동으로 다시 시도하는 중... "
            + "(자동 재시도 \(used.rounds)/\(Self.autoRecoveryMaxRounds), 허용한 서버: \(sent.joined(separator: ", ")))"
        autoRecoveryWaiting[job.id] = generation
        let helperGeneration = run.helperGeneration
        debugAutoRecoveryWillAwait?(job.id)
        connection.awaitPolicyApplied { [weak self] problem in
            self?.finishAutoRecovery(jobId: job.id, generation: generation, helperGeneration: helperGeneration,
                                     problem: problem)
        }
        return true
    }

    /// The helper answered (or could not): release the requeued job to the queue, or stop with a reason. A job that
    /// was cancelled, paused, deleted, retried by the user or changed meanwhile is left alone.
    private func finishAutoRecovery(jobId: String, generation: Int, helperGeneration: Int, problem: String?) {
        guard autoRecoveryWaiting[jobId] == generation else { return }
        autoRecoveryWaiting[jobId] = nil
        guard let i = jobs.firstIndex(where: { $0.id == jobId }), jobs[i].generation == generation,
              jobs[i].state == .queued else { return }
        var reason = problem
        if reason == nil, !(connection.enabled && connection.isReady && connection.generation == helperGeneration) {
            reason = "HTTPS 연결 도움이 다시 시작되었거나 꺼졌습니다."
        }
        if let reason = reason {
            jobs[i].state = .failed
            jobs[i].pendingDownload = false
            jobs[i].stateMessage = redactPersistedText(
                "추가 서버 허용이 적용되었는지 확인하지 못해 자동으로 다시 시도하지 않았습니다: \(reason) '다시 시도'를 눌러 주세요.")
        }
        jobs[i].updatedAt = Date()
        persistJobs()
        processQueue()
    }

    /// A genuinely new user attempt (retry, resume, new selection, delete): the automatic budget starts over and any
    /// automatic retry still waiting for the helper is dropped.
    private func resetAutoRecovery(_ jobId: String) {
        autoRecoveryBudgets[jobId] = nil
        autoRecoveryWaiting[jobId] = nil
    }

    // MARK: - Speed test (user-started, bounded, on the current connection path)

    /// '속도 측정': one bounded measurement against the fixed Cloudflare endpoints on the app's CURRENT path (off →
    /// direct; on → the authenticated helper with its own client tag, after the helper confirmed that exactly
    /// speed.cloudflare.com is allowed). Never concurrent with a job: refused while one runs, and the queue waits
    /// while it measures. A second press while measuring does nothing.
    public func startSpeedTest() {
        guard speedRun == nil else { return }
        var state = SpeedTestState()
        state.viaHelper = connection.enabled
        if hasActiveRun {
            state.phase = .unavailable
            state.message = "다운로드·녹화·저장이 진행 중이라 측정하지 않았습니다. 작업이 끝난 뒤 '다시 측정'을 눌러 주세요."
            speedTest = state
            return
        }
        if connection.enabled && !(connection.isReady && connection.splitConfirmed) {
            state.phase = .unavailable
            state.message = "HTTPS 연결 도움이 준비되지 않아 측정하지 않았습니다 (직접 연결로 바꿔 재지 않습니다). 연결 도움 상태를 확인해 주세요."
            speedTest = state
            return
        }
        speedSerial += 1
        let run = SpeedRun(generation: speedSerial, viaHelper: connection.enabled)
        speedRun = run
        state.phase = .preparing
        state.message = run.viaHelper ? "HTTPS 연결 도움에 측정 서버(\(ConnectionManager.speedTestHost))만 허용하는 중..."
            : "측정을 준비하는 중..."
        speedTest = state
        guard run.viaHelper else {
            launchSpeedTest(run, context: [:])
            return
        }
        runSerial += 1
        run.client = "s\(runSerial)"
        run.helperGeneration = connection.generation
        guard let proxy = connection.engineProxyURL(client: run.client) else {
            endSpeedTest(run, failure: "HTTPS 연결 도움이 준비되지 않아 측정하지 않았습니다.")
            return
        }
        connection.allowSpeedTestHost()
        connection.awaitPolicyApplied { [weak self] problem in
            guard let self = self, self.speedRun === run, !run.stopped else { return }
            if let problem = problem {
                self.endSpeedTest(run, failure: problem)
                return
            }
            guard self.connection.generation == run.helperGeneration,
                  self.connection.engineProxyURL(client: run.client) == proxy else {
                self.endSpeedTest(run, failure: "기다리는 동안 HTTPS 연결 도움이 다시 시작되어 측정하지 않았습니다.")
                return
            }
            self.launchSpeedTest(run, context: ["proxy": proxy])
        }
    }

    /// Cancel / close of the sheet. Only this measurement's own process group is stopped; the queue resumes once it
    /// is gone. Numbers already measured stay visible as such (never promoted to a full result).
    public func cancelSpeedTest() {
        stopSpeedTest(phase: .cancelled, message: "측정을 취소했습니다. 이미 잰 항목만 보여 줍니다.")
    }

    private func stopSpeedTest(phase: SpeedTestState.Phase, message: String) {
        guard let run = speedRun, !run.stopped else { return }
        run.stopped = true
        speedTest.phase = phase
        speedTest.message = message
        speedTest.liveMbps = nil
        if let handle = run.handle {
            handle.cancel()   // handleSpeedExit releases the queue after the group is swept
        } else {
            speedRun = nil
            processQueue()
        }
    }

    /// Helper restarted/failed/switched off during a helper-mode measurement: stop it (no direct fallback).
    private func speedConnectionChanged() {
        guard let run = speedRun, !run.stopped, run.viaHelper else { return }
        if !connection.enabled || !connection.isReady || connection.generation != run.helperGeneration {
            stopSpeedTest(phase: .failed,
                          message: "측정 중 HTTPS 연결 도움 상태가 바뀌어 측정을 중단했습니다 (직접 연결로 바꿔 재지 않았습니다).")
        }
    }

    private func launchSpeedTest(_ run: SpeedRun, context: [String: Any]) {
        run.handle = EngineBridge.shared.startSpeedTest(
            generation: run.generation, context: context,
            onEvent: { [weak self] event, payload in
                MainActor.assumeIsolated { self?.handleSpeedEvent(run, event: event, payload: payload) }
            },
            onExit: { [weak self] result in
                MainActor.assumeIsolated { self?.handleSpeedExit(run, result: result) }
            })
    }

    /// Ends a measurement that never started its engine process.
    private func endSpeedTest(_ run: SpeedRun, failure: String) {
        guard speedRun === run else { return }
        speedRun = nil
        speedTest.phase = .failed
        speedTest.message = "측정하지 못했습니다."
        speedTest.failure = failure
        processQueue()
    }

    private static func metric(_ value: Any?) -> Double? {
        guard let v = (value as? NSNumber)?.doubleValue, v.isFinite, v >= 0 else { return nil }
        return v
    }

    private func handleSpeedEvent(_ run: SpeedRun, event: String, payload: [String: Any]) {
        guard speedRun === run, !run.stopped else { return }
        switch event {
        case "speedProgress":
            if let raw = payload["phase"] as? String, let phase = SpeedTestState.Phase(rawValue: raw),
               [.connect, .latency, .download, .upload].contains(phase) {
                speedTest.phase = phase
            }
            if let message = payload["message"] as? String { speedTest.message = String(message.prefix(160)) }
            speedTest.liveMbps = Self.metric(payload["liveMbps"])
            if let v = Self.metric(payload["latencyMs"]) { speedTest.latencyMs = v }
            if let v = Self.metric(payload["downloadMbps"]) { speedTest.downloadMbps = v }
            if let v = Self.metric(payload["uploadMbps"]) { speedTest.uploadMbps = v }
            if let b = (payload["bytesUsed"] as? NSNumber)?.int64Value, b >= 0 { speedTest.bytesUsed = b }
        case "speedResult":
            run.result = payload
        case "error":
            run.engineError = payload["message"] as? String
        default:
            break
        }
    }

    /// Outcome only from a clean exit with a reported result; anything else is a visible failure.
    private func handleSpeedExit(_ run: SpeedRun, result: EngineTaskResult) {
        guard speedRun === run else { return }
        speedRun = nil
        if !result.groupClean {
            recordUncleanProcess(run.handle)
        }
        var s = speedTest
        s.liveMbps = nil
        let clean = !result.cancelled && result.exitCode == 0 && result.readyHandshake && result.groupClean
            && result.pipesDrained
        if run.stopped {
            // Cancel/close/helper change already set the visible state.
        } else if clean, let r = run.result {
            s.latencyMs = Self.metric(r["latencyMs"])
            s.latencySamples = (r["latencySamples"] as? NSNumber)?.intValue ?? 0
            s.downloadMbps = Self.metric(r["downloadMbps"])
            s.downloadPartial = r["downloadPartial"] as? Bool ?? false
            s.uploadMbps = Self.metric(r["uploadMbps"])
            if let b = (r["bytesUsed"] as? NSNumber)?.int64Value, b >= 0 { s.bytesUsed = b }
            s.seconds = Self.metric(r["seconds"])
            s.failure = (r["failure"] as? String).map { String($0.prefix(240)) }
            if r["ok"] as? Bool == true {
                s.phase = .finished
                s.message = r["complete"] as? Bool == true ? "측정을 마쳤습니다." : "일부 항목만 측정했습니다."
            } else {
                s.phase = .failed
                s.message = "측정하지 못했습니다."
            }
        } else {
            s.phase = .failed
            s.message = "측정하지 못했습니다."
            if result.timedOut {
                s.failure = "측정이 제한 시간 안에 끝나지 않아 중단했습니다."
            } else if let spawn = result.spawnError {
                s.failure = spawn
            } else if let e = run.engineError {
                s.failure = String(e.prefix(240))
            } else {
                s.failure = "측정 엔진이 결과를 알리지 않고 끝났습니다."
            }
        }
        if run.viaHelper, !run.client.isEmpty, connection.generation == run.helperGeneration,
           let refusal = connection.refusals(forClient: run.client).first {
            s.failure = [s.failure, "HTTPS 연결 도움이 막은 연결: \(refusal.host) — \(refusal.reason)"]
                .compactMap { $0 }.joined(separator: " ")
        }
        speedTest = s
        processQueue()
    }

    /// Login entry points open the in-app browser tab (there is no separate login window any more).
    public func openLoginWindow(url: String? = nil) {
        selectedTab = .browser
        if let url = url, !url.isEmpty { browser.open(url) } else { browser.activate() }
    }

    /// Opens the login window with the address currently typed in the main bar (if it is an http/https address).
    public func openLoginWindowFromInput() {
        let trimmed = urlInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
           url.host != nil {
            openLoginWindow(url: trimmed)
        } else {
            openLoginWindow(url: nil)
        }
    }

    /// Clears the one shared session: every tab's page is reset (their views used the cleared store).
    public func clearLoginSession() {
        for tab in allBrowserTabs { tab.teardown() }
        if let ws = _sawWorkspace {
            for session in ws.sessions.values {
                if session.runStatus == "running" {
                    session.takeoverManual()
                }
            }
        }
        session.clearPersisted()
        useLoginSessionForInput = false
    }

    /// Settings "캐시 정리" state: the button is disabled while `isClearingCache`, the outcome stays visible in `cacheCleanupMessage`.
    @Published public private(set) var isClearingCache = false
    @Published public private(set) var cacheCleanupMessage: String?

    /// Clears only the browser's HTTP cache (WebKit memory/disk cache of the app's store), generated preview images and the
    /// saved bookmark icon/color cache (they are fetched again on the next visit to the start page).
    /// Cookies, logins, site storage, downloads, history and job work folders are not touched; previews of jobs that
    /// are not finished (active or retryable) are kept. Overlapping calls are ignored.
    /// Size of what "캐시 정리" can remove and measure (previews + bookmark icon file). nil = not measured yet or unreadable.
    /// The WebKit HTTP cache is cleared too but has no reliable public size API, so it is never part of this number.
    @Published public private(set) var measuredCacheBytes: Int64?
    @Published public private(set) var isMeasuringCache = false
    private var cacheMeasureToken = 0

    /// Re-measures off the main thread. Only the latest call may publish; a failed part yields nil (no partial total).
    public func refreshCacheUsage() {
        cacheMeasureToken += 1
        let token = cacheMeasureToken
        isMeasuringCache = true
        let keepIds = Set(jobs.filter { $0.state != .completed && $0.state != .completedWithSubtitleFailure }.map { $0.id })
        let thumbnails = thumbnailDirectory
        let bookmarkFile = config.storeDirectory.appendingPathComponent(BookmarkAppearanceManager.cacheFileName, isDirectory: false)
        Task { [weak self] in
            let thumbBytes = await JobThumbnailCache.measureGenerated(directory: thumbnails, keepJobIds: keepIds)
            let bookmarkBytes = await Task.detached(priority: .utility) { () -> Int64? in
                var st = stat()
                if lstat(bookmarkFile.path, &st) != 0 { return errno == ENOENT ? 0 : nil }
                return (st.st_mode & S_IFMT) == S_IFREG ? Int64(st.st_size) : 0   // symlinks are neither counted nor removed
            }.value
            guard let self, token == self.cacheMeasureToken else { return }
            if let t = thumbBytes, let b = bookmarkBytes { self.measuredCacheBytes = t + b } else { self.measuredCacheBytes = nil }
            self.isMeasuringCache = false
        }
    }

    public func clearCaches() {
        guard !isClearingCache else { return }
        isClearingCache = true
        cacheCleanupMessage = "캐시를 정리하는 중입니다..."
        let keepIds = Set(jobs.filter { $0.state != .completed && $0.state != .completedWithSubtitleFailure }.map { $0.id })
        let thumbnails = thumbnailDirectory
        // Synchronous: bumps the cache generation now so fetches already in flight cannot re-save stale results.
        let bookmarkIcons = BookmarkAppearanceManager.shared.clearCachedAppearances()
        Task { [weak self] in
            guard let self else { return }
            let web = await self.session.clearHTTPCache()
            let thumbs = await JobThumbnailCache.clearGenerated(directory: thumbnails, keepJobIds: keepIds)
            let size = ByteCountFormatter.string(fromByteCount: thumbs.bytes, countStyle: .file)
            let webText: String
            switch web {
            case .cleared: webText = "브라우저 캐시를 비웠습니다"
            case .busy: webText = "세션을 지우는 중이라 브라우저 캐시는 건너뜀"
            case .nothingToClear: webText = "비울 브라우저 캐시 없음"
            }
            self.cacheCleanupMessage = "\(webText) · 미리보기 이미지 \(thumbs.files)개(\(size)) 삭제 · 즐겨찾기 아이콘·색상 \(bookmarkIcons)개 삭제. 로그인·다운로드·기록은 그대로입니다."
            self.isClearingCache = false
            self.refreshCacheUsage()
        }
    }

    /// Helper/mode change: each tab remembers what it had open, the shared connection store is detached,
    /// then the active tab reopens its page in the new session and background tabs reopen theirs when selected.
    func connectionModeChangedForAllTabs(skippingActiveReopen: LoginBrowserModel? = nil, carryPending: Bool = false) {
        // Stopping the browsing helper reports a status change; tabs must not prepare against stores about to be detached.
        let previousSuppression = suppressTabStatusCallback
        suppressTabStatusCallback = true
        defer { suppressTabStatusCallback = previousSuppression }
        let activeID = selectedTabID
        let inventory = allBrowserTabs
        let snapshots = inventory.compactMap { tab -> (LoginBrowserModel, LoginBrowserModel.ModeSnapshot)? in
            if tab === skippingActiveReopen {
                return nil
            }
            return (tab, tab.captureModeSnapshot(carryPending: carryPending))
        }
        if let incoming = skippingActiveReopen {
            incoming.teardown()
        }
        for (tab, _) in snapshots { tab.teardown() }
        session.detachConnectionStore()
        session.detachAlternateStore()
        // With the global switch on, the assist route is the global helper; the browsing-only helper is not needed.
        if connection.enabled { browsingConnection.setEnabled(false) }
        for (tab, snapshot) in snapshots {
            let isActive: Bool
            if let pid = tab.sawProjectID {
                let isSessActive = tab.sawWorkspace?.sessions[pid]?.activeBrowser?.tabID == tab.tabID
                let isProjSelected = tab.sawWorkspace?.selectedProjectID == pid
                isActive = isSessActive && isProjSelected
            } else {
                isActive = tab.tabID == activeID
            }
            tab.reopenAfterModeChange(snapshot, active: isActive)
        }
    }

    /// Resets the other tabs that sit on the same store as the tab about to replace that store (their pages stay as
    /// remembered addresses only). Tabs on the other route's store are not touched.
    func teardownOtherTabs(usingPrimaryStore primary: Bool, except keep: LoginBrowserModel) {
        for tab in allBrowserTabs where tab !== keep && tab.usesPrimaryStore == primary { tab.teardown() }
    }

    // MARK: - Per-site connection route

    /// Route of sites without a choice: the global switch.
    var defaultRoute: BrowsingRoute { connection.enabled ? .assist : .direct }

    /// The helper behind the assist route: the global one when the switch is on, else the browsing-only one.
    var assistConnection: ConnectionManager { connection.enabled ? connection : browsingConnection }

    func connectionManager(for route: BrowsingRoute) -> ConnectionManager? {
        route == .assist ? assistConnection : nil
    }

    /// The primary store (the long-standing identifier) serves the global switch's route; the alternate store the other.
    func isPrimaryRoute(_ route: BrowsingRoute) -> Bool { (route == .assist) == connection.enabled }

    /// The user's explicit choice for this exact host, as a route (nil = unset).
    func explicitRoute(forHost host: String?) -> BrowsingRoute? { siteRoutes.choice(forHost: host)?.route }

    /// Explicit destination choice first, then the route the navigation inherits (opener / current page), then the
    /// global default. The inherited route is a runtime value and never becomes an explicit choice.
    func route(forHost host: String?, inherited: BrowsingRoute? = nil) -> BrowsingRoute {
        explicitRoute(forHost: host) ?? inherited ?? defaultRoute
    }

    /// Returns the exact persistent WKWebsiteDataStore instance for the given service URL/route.
    public func store(for service: AIService) -> WKWebsiteDataStore {
        if service.isHana {
            return HanaPanelHost.shared.webView.configuration.websiteDataStore
        }
        guard let url = URL(string: service.homeURL), let host = url.host else {
            let helper = connectionManager(for: defaultRoute)
            let proxy = defaultRoute == .assist ? helper?.webProxyConfiguration() : nil
            return session.ensureStore(proxy: proxy, generation: helper?.generation)
        }
        let targetRoute = route(forHost: host)
        let isPrimary = isPrimaryRoute(targetRoute)
        let helper = connectionManager(for: targetRoute)
        let mode: Int? = helper?.generation
        let proxy = targetRoute == .assist ? helper?.webProxyConfiguration() : nil
        if isPrimary {
            return session.ensureStore(proxy: proxy, generation: mode)
        } else {
            return session.ensureAlternateStore(proxy: proxy, generation: mode)
        }
    }

    /// Makes sure the assist route has a helper that is running or starting, and returns it. While the global switch is
    /// off this starts the browsing-only helper on demand; an already failed helper is not restarted silently.
    func prepareAssistRoute() -> ConnectionManager {
        if connection.enabled { return connection }
        if !browsingConnection.enabled { browsingConnection.setEnabled(true) }
        return browsingConnection
    }

    /// Saves the browser's TLS auto-retry preference and applies it live to both route helpers (no restart).
    func setBrowserAutoRetryTLS(_ on: Bool) {
        preferences.setAutoRetryTLS(on)
        connection.setAutoRetryTLS(on)
        browsingConnection.setAutoRetryTLS(on)
    }

    func restartBrowsingAssist() {
        guard !connection.enabled, browsingConnection.enabled else { return }
        browsingConnection.restart()
    }

    /// The browsing helper restarted with new credentials: views on the alternate store still point at the old helper
    /// and are reset (only those; tabs on the primary store and running downloads are untouched).
    private func resetStaleAlternateRouteTabs() {
        guard !connection.enabled, session.alternateStore != nil,
              session.alternateProxyGeneration != browsingConnection.generation else { return }
        let affected = allBrowserTabs.filter { !$0.usesPrimaryStore && $0.hasWebView }
        let activeID = selectedTabID
        let snapshots = affected.map { ($0, $0.captureModeSnapshot(carryPending: true)) }
        for (tab, _) in snapshots { tab.teardown() }
        session.detachAlternateStore()
        for (tab, snapshot) in snapshots {
            let isActive: Bool
            if let pid = tab.sawProjectID {
                let isSessActive = tab.sawWorkspace?.sessions[pid]?.activeBrowser?.tabID == tab.tabID
                let isProjSelected = tab.sawWorkspace?.selectedProjectID == pid
                isActive = isSessActive && isProjSelected
            } else {
                isActive = tab.tabID == activeID
            }
            tab.reopenAfterModeChange(snapshot, active: isActive)
        }
    }

    /// A pop-up / `target=_blank` whose destination has an explicit choice different from the opener's route cannot
    /// use WebKit's configuration (it is bound to the opener's store). A fresh tab is opened on the destination's route
    /// instead; it has no `window.opener`. Nil = nothing was opened.
    func openRoutedTab(from opener: LoginBrowserModel, url: URL, route: BrowsingRoute,
                       keepOpenerSelected: Bool) -> LoginBrowserModel? {
        guard browser === opener, tabs.count < Self.maxTabs,
              let index = tabs.firstIndex(where: { $0 === opener }) else { return nil }
        let tab = LoginBrowserModel()
        tab.appModel = self
        setTabOpener(childID: tab.tabID, openerID: opener.tabID)
        tab.startOnRoute(url, route: route)
        if keepOpenerSelected {
            tabs.insert(tab, at: index + 1)
            extensions.tabOpened(tab)
            schedulePopupBurstFocus(firstTabID: tab.tabID, openerID: opener.tabID)
            tab.prepare()
        } else {
            opener.didDeactivate()
            tabs.insert(tab, at: index + 1)
            selectedTabID = tab.tabID
            tab.activate()
            extensions.tabOpened(tab)
            extensions.tabActivated(tab, previous: opener)
        }
        return tab
    }

    // MARK: - Browser tabs

    /// "+": a blank tab with the usual start behaviour (built-in home or the user's start page).
    @discardableResult
    func newTab(explicitURL: Bool = false) -> LoginBrowserModel? {
        let tab = LoginBrowserModel()
        tab.skipStartPage = explicitURL
        tab.appModel = self
        let index = tabs.firstIndex(where: { $0.tabID == selectedTabID }) ?? (tabs.count - 1)
        let previous = browser
        browser.didDeactivate()
        tabs.insert(tab, at: index + 1)
        selectedTabID = tab.tabID
        tab.activate()
        extensions.tabOpened(tab)
        extensions.tabActivated(tab, previous: previous)
        requestAddressFocus(for: tab, isNewTab: true)
        return tab
    }

    /// Upper bound of addresses taken from one external request (`open -a ... URL`, command line, URL event).
    static let maxExternalURLsPerRequest = 10

    /// Opens http(s) addresses handed over by the OS (normal tabs of this app only; no private mode, no downloads).
    /// Each address passes `BrowserPreferences.validateWebURL` (credentials, control characters, overlong, other
    /// schemes are dropped). A blank/home tab is reused first; otherwise a new tab is added while `maxTabs` allows.
    /// Routing is `LoginBrowserModel.open`'s own: the destination's explicit choice, else the global default.
    /// Returns how many were opened and how many were not (invalid, duplicate, over the list bound or the tab cap).
    @discardableResult
    func openExternalURLs(_ rawURLs: [String]) -> (opened: Int, skipped: Int) {
        var valid: [String] = []
        for raw in rawURLs.prefix(64) {   // bounded scan
            if valid.count >= Self.maxExternalURLsPerRequest { break }
            if let fileCandidate = URL(string: raw), fileCandidate.isFileURL {
                let standardized = fileCandidate.standardizedFileURL.resolvingSymlinksInPath()
                let path = standardized.path
                if path.utf8.count <= 4096,
                   !path.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) {
                    let ext = standardized.pathExtension.lowercased()
                    if ext == "html" || ext == "htm" || ext == "xhtml" {
                        var isDir: ObjCBool = false
                        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue {
                            let validatedStr = standardized.absoluteString
                            if !valid.contains(validatedStr) {
                                valid.append(validatedStr)
                                continue
                            }
                        }
                    }
                }
            }
            if let url = BrowserPreferences.validateWebURL(raw), !valid.contains(url) {
                valid.append(url)
            }
        }
        let candidates = Array(valid.prefix(Self.maxExternalURLsPerRequest))
        var opened = 0
        selectedTab = .browser
        for url in candidates {
            let current = browser
            if current.isShowingHome {   // blank/home tab: open() drops its stale home view
                current.open(url)
            } else if tabs.count < Self.maxTabs, let tab = newTab(explicitURL: true) {
                tab.open(url)
            } else {
                continue
            }
            opened += 1
        }
        return (opened, max(0, rawURLs.count - opened))
    }

    /// Switching only changes which tab is shown: no page, view, candidate list or session is touched.
    func selectTab(_ id: UUID) {
        cancelPendingPopupBurstFocus()
        guard id != selectedTabID, let next = tabs.first(where: { $0.tabID == id }) else { return }
        let previous = browser
        browser.didDeactivate()
        selectedTabID = id
        next.activate()
        extensions.tabActivated(next, previous: previous)
        if next.isShowingHome && next.address.isEmpty { requestAddressFocus(for: next) } else { clearAddressFocusRequest() }
    }

    /// Closes one tab: its own loading, callbacks and observations stop and its token is invalidated. The shared
    /// cookie store and the other tabs are untouched. If closing the sole remaining New Tab (blank/home),
    /// terminates the application. If closing the last tab with a loaded page, resets it to a new tab instead of quitting.
    func closeTab(_ id: UUID) {
        if id == pendingPopupBurstFirstTabID {
            cancelPendingPopupBurstFocus()
        }
        tabOpeners.removeValue(forKey: id)
        guard let index = tabs.firstIndex(where: { $0.tabID == id }) else { return }
        let closing = tabs[index]
        if tabs.count == 1 && closing.isShowingHome {
            closing.teardown()
            NSApplication.shared.terminate(nil)
            return
        }
        closing.teardown()
        guard tabs.count > 1 else {
            // Last loaded tab: always come back as a fresh New Tab (built-in home), never the custom start page.
            selectedTab = .browser
            closing.showBuiltInHome()
            closing.activate()
            requestAddressFocus(for: closing, isNewTab: true)
            return
        }
        let wasSelected = id == selectedTabID
        tabs.remove(at: index)
        extensions.tabClosed(closing)
        if wasSelected {
            let next = tabs[min(index, tabs.count - 1)]
            selectedTabID = next.tabID
            next.activate()
            extensions.tabActivated(next, previous: nil)
        }
    }

    /// The browser's main window (registered by the window's key monitor). Only this window gets tab-close semantics.
    nonisolated(unsafe) weak var browserWindow: NSWindow?

    /// Close command (⌘W / File > Close) declared in the app's menu model, so it does not depend on rebinding a
    /// SwiftUI-owned menu item. The browser window closes tabs; any other window (open/save panel, alert) keeps the
    /// standard close.
    func performStandardClose() {
        guard let key = NSApp.keyWindow else { return }
        if key === browserWindow {
            handleCloseBrowserShortcut()
        } else {
            key.performClose(nil)
        }
    }

    // MARK: - AI Side-Panel Control

    public var activeAIPanelIsHana: Bool {
        temporaryShowHanaPanel || aiServices.selectedService.isHana
    }

    public func setAIPanelOpen(_ open: Bool) {
        if open && aiServices.enabledServices.isEmpty && !temporaryShowHanaPanel {
            selectedTab = .ai
            isAIPanelOpen = false
            return
        }

        isAIPanelOpen = open
        if !open {
            temporaryShowHanaPanel = false
            HanaPanelHost.shared.isPanelOpen = false
            thirdPartyAIHost.isPanelOpen = false
        } else {
            if activeAIPanelIsHana {
                HanaPanelHost.shared.isPanelOpen = true
                thirdPartyAIHost.isPanelOpen = false
            } else {
                HanaPanelHost.shared.isPanelOpen = false
                thirdPartyAIHost.isPanelOpen = true
                thirdPartyAIHost.rebindStoreIfNeeded(store(for: aiServices.selectedService))
                thirdPartyAIHost.load(service: aiServices.selectedService)
            }
        }
    }

    public func toggleAIPanel() {
        setAIPanelOpen(!isAIPanelOpen)
    }

    public func openAIPanel() {
        temporaryShowHanaPanel = false
        setAIPanelOpen(true)
    }

    /// Handles keyboard shortcut for closing the browser or current tab.
    /// If the embedded Hana or third-party AI panel has focus, closes that panel while preserving the browser page/tab and conversation.
    /// Otherwise:
    /// On .browser: closes the selected browser tab.
    /// On .queue: switches selectedTab to .browser.
    /// Elsewhere: no-op.
    func handleCloseBrowserShortcut() {
        if HanaPanelHost.shared.isHanaPanelFocused(in: browserWindow ?? NSApp.keyWindow) {
            setAIPanelOpen(false)
            return
        }
        if thirdPartyAIHost.isFocused(in: browserWindow ?? NSApp.keyWindow) {
            setAIPanelOpen(false)
            return
        }
        switch selectedTab {
        case .browser:
            closeTab(selectedTabID)
        case .queue:
            selectedTab = .browser
        case .saw:
            if let pid = sawWorkspace.selectedProjectID {
                let session = sawWorkspace.session(for: pid)
                let isPlannerFocused: Bool = {
                    guard let keyWin = NSApp.keyWindow,
                          let firstResp = keyWin.firstResponder as? NSView else { return false }
                    var curr: NSView? = firstResp
                    while let c = curr {
                        if String(describing: type(of: c)).contains("WKWebView") && session.showingPlannerSurface {
                            return true
                        }
                        curr = c.superview
                    }
                    return false
                }()

                if isPlannerFocused && session.showingPlannerSurface {
                    session.showingPlannerSurface = false
                } else if let activeTabID = session.selectedTabID {
                    session.closeTab(id: activeTabID)
                } else if session.showingPlannerSurface {
                    session.showingPlannerSurface = false
                }
            }
        default:
            break
        }
    }

    /// A page of the active tab asked for a window (`target=_blank`, `window.open`): the new tab takes WebKit's own
    /// configuration for it and is shown; the opener keeps its page. Nil = nothing was opened.
    func openPopupTab(from opener: LoginBrowserModel, configuration: WKWebViewConfiguration, targetURL: URL?,
                      mode: Int?, route: BrowsingRoute, primaryStore: Bool,
                      keepOpenerSelected: Bool = false) -> LoginBrowserModel? {
        guard browser === opener,
              let index = tabs.firstIndex(where: { $0 === opener }) else { return nil }
        let tab = LoginBrowserModel()
        tab.appModel = self
        setTabOpener(childID: tab.tabID, openerID: opener.tabID)
        guard tab.adoptPopup(configuration: configuration, openerUCC: opener.contentController,
                             targetURL: targetURL, mode: mode, route: route,
                             primaryStore: primaryStore) != nil else { return nil }
        if keepOpenerSelected {
            tabs.insert(tab, at: index + 1)
            extensions.tabOpened(tab)
            schedulePopupBurstFocus(firstTabID: tab.tabID, openerID: opener.tabID)
        } else {
            opener.didDeactivate()
            tabs.insert(tab, at: index + 1)
            selectedTabID = tab.tabID
            tab.activate()
            extensions.tabOpened(tab)
            extensions.tabActivated(tab, previous: opener)
        }
        return tab
    }

    // MARK: - Queue & Job Lifecycle

    /// Ingests dropped or batch URLs immediately: validates scheme/host/credentials,
    /// enqueues as analysis-only jobs, keeps the current tab, and starts queue processing.
    @discardableResult
    public func addJobs(from urlStrings: [String]) -> Int {
        var addedJobs: [JobRecord] = []
        for raw in urlStrings {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count <= 4096 else { continue }
            guard let url = URL(string: trimmed),
                  let scheme = url.scheme?.lowercased(),
                  (scheme == "http" || scheme == "https"),
                  !url.isFileURL,
                  let host = url.host, !host.isEmpty,
                  url.user == nil, url.password == nil else { continue }
            if let comps = URLComponents(string: trimmed), (comps.user != nil || comps.password != nil) {
                continue
            }
            var newJob = JobRecord(sourceURL: trimmed, destinationFolder: destinationFolder, title: "주소 분석 중: \(host)")
            newJob.autoConfirm = true
            if let safe = validateSafeRetryPageURL(canonicalYouTubeWatchURL(from: trimmed) ?? trimmed, fromBrowser: false, hasPageProvenance: false) {
                newJob.retryPageURL = safe
            }
            if useLoginSessionForInput && session.isAlive {
                if let site = siteDomain(forHost: host) {
                    newJob.useLoginSession = true
                    newJob.loginSite = site
                }
            }
            addedJobs.append(newJob)
        }
        guard !addedJobs.isEmpty else { return 0 }
        jobs.insert(contentsOf: addedJobs, at: 0)
        selectedJobId = addedJobs.first?.id
        persistJobs()
        processQueue()
        return addedJobs.count
    }

    public func addJobFromInput() {
        let trimmed = urlInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = url.host, !host.isEmpty else {
            showAlert("유효한 HTTP 또는 HTTPS 주소를 입력해 주세요.")
            return
        }

        var newJob = JobRecord(sourceURL: trimmed, destinationFolder: destinationFolder, title: "주소 분석 중: \(host)")
        newJob.autoConfirm = true
        if let safe = validateSafeRetryPageURL(canonicalYouTubeWatchURL(from: trimmed) ?? trimmed, fromBrowser: false, hasPageProvenance: false) {
            newJob.retryPageURL = safe
        }
        if useLoginSessionForInput && session.isAlive {
            guard let site = siteDomain(forHost: host) else {
                showAlert("이 주소에는 로그인 세션을 연결할 수 없습니다 (사이트 이름을 확인할 수 없는 주소).")
                return
            }
            newJob.useLoginSession = true
            newJob.loginSite = site
        }
        jobs.insert(newJob, at: 0)
        selectedJobId = newJob.id
        urlInput = ""
        persistJobs()
        processQueue()
    }

    /// "이 페이지를 다운로드에 사용" from the login window: the job is bound to that page's site and session.
    func addJobFromLoginPage(_ url: URL, route sourceRoute: BrowsingRoute? = nil) {
        if let refusal = routeMismatchMessage(sourceRoute) {
            showAlert(refusal)
            return
        }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, let site = siteDomain(forHost: host) else {
            showAlert("이 페이지 주소는 다운로드에 사용할 수 없습니다.")
            return
        }
        var newJob = JobRecord(sourceURL: url.absoluteString, destinationFolder: destinationFolder, title: "주소 분석 중: \(host)")
        newJob.useLoginSession = true
        newJob.loginSite = site
        newJob.sourceRoute = sourceRoute?.rawValue
        newJob.autoConfirm = true
        // Hostname of the browser's native current page (diagnostics only; fromBrowser meaning is unchanged).
        newJob.pageHost = DiagSanitize.host(url.host)
        if let safe = validateSafeRetryPageURL(canonicalYouTubeWatchURL(from: url.absoluteString) ?? url.absoluteString, fromBrowser: false, hasPageProvenance: true) {
            newJob.retryPageURL = safe
            newJob.browserPageReference = safe
        }
        jobs.insert(newJob, at: 0)
        selectedJobId = newJob.id
        persistJobs()
        processQueue()
    }

    /// "MP4로 저장" on a video candidate of the in-app browser. The job goes through the normal extraction → quality →
    /// verified MP4 flow. Context kept in memory only: the page's Referer (browser default policy) and, when the
    /// browser session is open, cookies of the media address's own site (never the whole session, never a global
    /// Cookie header). Returns the new job id.
    func addJobFromBrowserMedia(_ media: URL, pageURL: URL, refererURL: URL? = nil, title: String,
                                route sourceRoute: BrowsingRoute? = nil) -> String? {
        if let refusal = routeMismatchMessage(sourceRoute) {
            showAlert(refusal)
            return nil
        }
        guard let scheme = media.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = media.host, !host.isEmpty else {
            showAlert("이 영상 주소는 받을 수 없습니다 (http/https 주소만 가능합니다).")
            return nil
        }
        if scheme == "http" && connection.enabled {
            showAlert("연결 도움을 켠 동안에는 암호화되지 않은 http:// 영상 주소를 받을 수 없습니다. 연결 도움을 끄고 다시 골라 주세요.")
            return nil
        }
        let shownTitle = title.isEmpty ? "브라우저에서 고른 영상: \(host)" : title
        var newJob = JobRecord(sourceURL: media.absoluteString, destinationFolder: destinationFolder, title: shownTitle)
        newJob.fromBrowser = true
        newJob.sourceRoute = sourceRoute?.rawValue
        newJob.autoConfirm = true
        newJob.pageReferer = MediaDiscovery.referer(page: refererURL ?? pageURL, media: media)
        // Hostnames of the browser's native top page / chosen frame (not page-script values), for diagnostics only.
        newJob.pageHost = DiagSanitize.host(pageURL.host)
        newJob.frameHost = DiagSanitize.host(refererURL?.host)
        if session.isAlive {
            if let site = siteDomain(forHost: host) {
                newJob.useLoginSession = true
                newJob.loginSite = site
            } else {
                newJob.stateMessage = "이 영상 주소(사이트 이름이 없는 주소)에는 로그인 정보를 붙일 수 없어 로그인 없이 받습니다."
            }
        }
        // Only this candidate's own validated page first, then its own frame referer; never the global active tab.
        if let safe = validateSafeRetryPageURL(pageURL.absoluteString, fromBrowser: false, hasPageProvenance: true) {
            newJob.browserPageReference = safe
        } else if let referer = newJob.pageReferer,
                  let safe = validateSafeRetryPageURL(referer, fromBrowser: false, hasPageProvenance: true) {
            newJob.browserPageReference = safe
        }
        jobs.insert(newJob, at: 0)
        selectedJobId = newJob.id
        persistJobs()
        processQueue()
        return newJob.id
    }

    /// Downloads always run on the global route. A browser tab on the other route (site rule or inherited) cannot hand
    /// its page over: the job would silently take another path than the page used. Nil = fine.
    private func routeMismatchMessage(_ source: BrowsingRoute?) -> String? {
        guard let source, source != defaultRoute else { return nil }
        return "이 탭은 '\(source.label)'(으)로 열려 있지만 다운로드는 전체 연결 설정('\(defaultRoute.label)')으로만 진행됩니다. 경로가 달라 다른 연결로 몰래 받지 않도록 대기열에 추가하지 않았습니다. 전체 연결 도움 설정을 이 탭과 맞춘 뒤 다시 시도해 주세요."
    }

    public func processQueue() {
        guard !isProcessingQueue else { return }
        isProcessingQueue = true
        defer { isProcessingQueue = false }

        // A speed measurement holds the queue: jobs wait (they are not lost) and start once it ended.
        guard speedRun == nil, queueBlockedReason == nil else { return }
        // Wait for the helper instead of starting on a half-configured path (status change re-enters here).
        if connection.enabled && connection.isStarting { return }

        var seenInCycle = Set<String>()
        while activeRuns.count < maxConcurrentJobs {
            // Automatic retries start only after the helper confirmed the extra hosts (finishAutoRecovery re-enters).
            let queued = jobs.filter {
                $0.state == .queued &&
                autoRecoveryWaiting[$0.id] == nil &&
                activeRuns[$0.id] == nil &&
                !seenInCycle.contains($0.id)
            }.sorted { $0.createdAt < $1.createdAt }

            guard let job = queued.first else { break }
            seenInCycle.insert(job.id)

            if job.pendingPublish {
                beginPublish(jobId: job.id)
            } else if job.urlWasRedacted {
                updateJob(job.id) {
                    $0.state = .interrupted
                    $0.pendingDownload = false
                    $0.stateMessage = "보안을 위해 주소의 일부가 저장되지 않아 자동으로 다시 시작할 수 없습니다. 주소를 다시 입력해 주세요."
                }
                persistJobs()
            } else if job.pendingDownload {
                startDownload(job: job)
            } else {
                startExtracting(job: job)
            }
        }
    }

    /// Runs a synchronous bulk queue change (e.g. clearing many jobs) without starting queued work in between:
    /// processQueue is held off during `body` and pumped exactly once afterwards. A nested batch only restores the
    /// held state and does not pump.
    @MainActor
    public func performQueueBatch(_ body: () -> Void) {
        let prior = isProcessingQueue
        isProcessingQueue = true
        defer {
            isProcessingQueue = prior
            if !prior { processQueue() }
        }
        body()
    }

    // MARK: Extraction

    private func startExtracting(job: JobRecord) {
        guard activeRuns[job.id] == nil else { return }
        dependencyPlans[job.id] = nil
        updateJob(job.id) {
            $0.state = .extracting
            $0.stateMessage = "영상 정보 및 화질 목록을 확인하는 중입니다..."
            $0.updatedAt = Date()
        }
        let run = ActiveRun(jobId: job.id, generation: job.generation, kind: .extract)
        activeRuns[job.id] = run
        persistJobs()
        prepareContext(for: job, run: run) { [weak self] context in
            guard let self = self, self.activeRuns[job.id] === run else { return }
            run.handle = EngineBridge.shared.extractInfo(
                jobId: job.id, generation: job.generation, url: job.sourceURL, context: context,
                onEvent: { [weak self] event, payload in
                    MainActor.assumeIsolated { self?.handleEngineEvent(run: run, event: event, payload: payload) }
                },
                onExit: { [weak self] result in
                    MainActor.assumeIsolated { self?.handleExit(run: run, result: result) }
                })
        }
    }

    /// Builds the per-run engine context (memory only, delivered through stdin):
    ///  * connection assist on → the proxy URL with this session's credentials (no direct fallback); the job's site
    ///    and its known dependencies are allowed because the user explicitly asked for this address
    ///  * login session attached → cookies of the bound site only, fetched from the live session right now
    /// Fails the run visibly instead of silently running on another path or logged out.
    private func prepareContext(for job: JobRecord, run: ActiveRun, launch: @escaping ([String: Any]) -> Void) {
        // The route captured at enqueue must still be the global one (the switch may have changed since): never run a
        // job on another path than its page used, and never read another store's cookies.
        if let raw = job.sourceRoute {
            guard let captured = BrowsingRoute(rawValue: raw), captured == defaultRoute else {
                abortRun(run, message: "이 작업은 '\(BrowsingRoute(rawValue: raw)?.label ?? raw)' 탭에서 추가되었지만 현재 전체 연결 설정은 '\(defaultRoute.label)'입니다. 경로가 달라 시작하지 않았습니다. 연결 설정을 맞춘 뒤 다시 시도해 주세요.")
                return
            }
        }
        guard connection.enabled else {
            if dependencyPlans[job.id] != nil {
                dependencyPlans[job.id] = nil
                abortRun(run, message: "이 영상은 HTTPS 연결 도움을 통해서만 받을 수 있습니다. 연결 도움을 켠 뒤 다시 시도해 주세요.")
                return
            }
            prepareSessionContext(for: job, run: run, base: [:], launch: launch)
            return
        }
        runSerial += 1
        run.proxyClient = "j\(runSerial)"
        run.helperGeneration = connection.generation
        guard let proxy = connection.engineProxyURL(client: run.proxyClient) else {
            abortRun(run, message: "HTTPS 연결 도움이 준비되지 않아 시작하지 않았습니다. 위의 연결 도움 상태를 확인해 주세요.")
            return
        }

        if run.kind == .download && job.runMode == .full {
            if let plan = dependencyPlans[job.id] {
                if plan.jobId != job.id || plan.generation != job.generation || plan.helperGeneration != connection.generation {
                    // wrong/stale generation/helper: discard rather than apply
                    dependencyPlans[job.id] = nil
                } else {
                    guard plan.hosts.count <= 16 else {
                        dependencyPlans[job.id] = nil
                        abortRun(run, message: "허용할 추가 서버 목록이 제한(16개)을 초과하여 다운로드를 시작하지 않았습니다.")
                        return
                    }
                    guard plan.hosts.allSatisfy({ $0.count <= 253 && ConnectionManager.isAllowableHost($0) }) else {
                        dependencyPlans[job.id] = nil
                        abortRun(run, message: "유효하지 않은 추가 서버 주소가 포함되어 다운로드를 시작하지 않았습니다.")
                        return
                    }
                    guard connection.isReady else {
                        dependencyPlans[job.id] = nil
                        abortRun(run, message: "HTTPS 연결 도움이 준비되지 않아 추가 서버를 허용하지 못했습니다. 연결 도움 상태를 확인해 주세요.")
                        return
                    }
                    let needed = plan.hosts.filter { !connection.covers(host: $0) }
                    if !needed.isEmpty {
                        let budget = autoRecoveryBudgets[job.id] ?? AutoRecoveryBudget()
                        if budget.hosts + needed.count > Self.autoRecoveryMaxHosts {
                            dependencyPlans[job.id] = nil
                            abortRun(run, message: "다운로드에 필요한 추가 서버(\(needed.count)개)가 자동 허용 한도(작업당 최대 \(Self.autoRecoveryMaxHosts)개 중 남은 \(max(0, Self.autoRecoveryMaxHosts - budget.hosts))개)를 초과하여 다운로드를 시작하지 않았습니다. 직접 주소를 확인해 주세요.")
                            return
                        }
                        let sent = connection.allowPlannedHosts(needed)
                        guard !sent.isEmpty, Set(sent) == Set(needed) else {
                            dependencyPlans[job.id] = nil
                            abortRun(run, message: "추가 서버 허용을 연결 도움에 전달하지 못해 다운로드를 시작하지 않았습니다.")
                            return
                        }
                        autoRecoveryBudgets[job.id] = AutoRecoveryBudget(rounds: budget.rounds, hosts: budget.hosts + sent.count)
                    }
                    dependencyPlans[job.id] = nil
                }
            }
        }

        connection.allowSite(forURL: job.sourceURL)
        // The engine may only start once the helper confirmed this site's policy (no first-request race).
        connection.awaitPolicyApplied { [weak self] problem in
            guard let self = self, self.activeRuns[run.jobId] === run else { return }
            if run.userStopped {
                self.activeRuns.removeValue(forKey: run.jobId)
                self.persistJobs()
                self.processQueue()
                return
            }
            if let problem = problem {
                self.abortRun(run, message: problem)
                return
            }
            guard self.connection.engineProxyURL(client: run.proxyClient) == proxy else {
                self.abortRun(run, message: "기다리는 동안 연결 도움이 다시 시작되어 시작하지 않았습니다. '다시 시도'를 눌러 주세요.")
                return
            }
            self.prepareSessionContext(for: job, run: run, base: ["proxy": proxy], launch: launch)
        }
    }

    private func prepareSessionContext(for job: JobRecord, run: ActiveRun, base initial: [String: Any],
                                       launch rawLaunch: @escaping ([String: Any]) -> Void) {
        var context = initial
        // Browser-chosen media: the page Referer goes with this job's requests only (memory/stdin).
        if let referer = job.pageReferer { context["referer"] = referer }
        // Browser-chosen direct media: its validated canonical page lets the engine re-resolve the player context
        // for this attempt (memory/stdin only; the engine re-validates and only applies an exact media match).
        if job.fromBrowser, job.runMode == .full, let page = job.browserPageReference,
           let safe = validateSafeRetryPageURL(page, fromBrowser: false, hasPageProvenance: true) {
            context["pageURL"] = safe
        }
        let requested = DiagAttachment(proxy: connection.enabled, referrer: job.pageReferer != nil,
                                       session: job.useLoginSession, userAgent: job.useLoginSession)
        let launch: ([String: Any]) -> Void = { [weak self] ctx in
            self?.debugLastContextKeys = ctx.keys.sorted()
            run.requestedContext = requested
            run.attachedContext = DiagAttachment(context: ctx)
            rawLaunch(ctx)
        }
        guard job.useLoginSession else {
            launch(context)
            return
        }
        guard session.isAlive, let site = job.loginSite ?? siteDomain(forURL: job.sourceURL) else {
            abortRun(run, message: "이 작업에 연결된 로그인 세션이 끝났습니다. 브라우저에서 다시 로그인한 뒤 '다시 시도'를 눌러 주세요.")
            return
        }
        let base = context
        // Downloads run on the global route only, so cookies come from the primary store (checked above: a job
        // captured on another route never reaches here). The route is not recomputed and the alternate store is never read.
        let fromAlternate = false
        Task { @MainActor [weak self] in
            let exported = await self?.session.cookiePayload(site: site, fromAlternate: fromAlternate)
            guard let self = self, self.activeRuns[run.jobId] === run else { return }
            if run.userStopped {
                self.activeRuns.removeValue(forKey: run.jobId)
                self.persistJobs()
                self.processQueue()
                return
            }
            guard let exported = exported else {
                self.abortRun(run, message: "이 작업에 연결된 로그인 세션이 끝났습니다. 브라우저에서 다시 로그인한 뒤 '다시 시도'를 눌러 주세요.")
                return
            }
            var ctx = base
            ctx["session"] = exported.payload
            launch(ctx)
        }
    }

    /// Ends a run that never started an engine process.
    private func abortRun(_ run: ActiveRun, message: String) {
        guard activeRuns[run.jobId] === run else { return }
        activeRuns.removeValue(forKey: run.jobId)
        if !run.userStopped, let index = jobs.firstIndex(where: { $0.id == run.jobId && $0.generation == run.generation }) {
            jobs[index].state = .failed
            jobs[index].stateMessage = message
            jobs[index].updatedAt = Date()
        }
        persistJobs()
        processQueue()
    }

    private func captureDependencyPlan(from payload: [String: Any], run: ActiveRun) -> DependencyPlan? {
        guard (payload["extractor"] as? String)?.lowercased() == "generic",
              (payload["mediaId"] as? String)?.hasPrefix("pageembed-") == true,
              payload["isLive"] as? Bool == false else { return nil }
        guard connection.enabled, connection.isReady, run.helperGeneration > 0,
              run.helperGeneration == connection.generation else {
            return nil
        }
        guard let rawList = payload["dependencyHosts"] as? [Any] else {
            return nil
        }
        guard rawList.count <= 16 else { return nil }
        var validated: [String] = []
        for item in rawList {
            guard let raw = item as? String, raw.count <= 253 else { return nil }
            let host = raw.lowercased()
            guard ConnectionManager.isAllowableHost(host) else { return nil }
            if !validated.contains(host) { validated.append(host) }
        }
        guard !validated.isEmpty else { return nil }
        return DependencyPlan(jobId: run.jobId, generation: run.generation,
                              helperGeneration: run.helperGeneration, hosts: validated)
    }

    private func applyExtracted(_ payload: [String: Any], to index: Int) {
        if let title = payload["title"] as? String { jobs[index].title = title }
        if let extractor = payload["extractor"] as? String { jobs[index].extractor = extractor }
        if let mediaId = payload["mediaId"] as? String { jobs[index].mediaId = mediaId }
        jobs[index].duration = (payload["duration"] as? NSNumber)?.doubleValue
        jobs[index].isLive = payload["isLive"] as? Bool ?? false
        jobs[index].liveStatus = payload["liveStatus"] as? String

        var formats: [MediaFormat] = []
        for f in payload["formats"] as? [[String: Any]] ?? [] {
            guard let fid = f["formatId"] as? String, let ext = f["ext"] as? String else { continue }
            formats.append(MediaFormat(
                formatId: fid, ext: ext,
                vcodec: f["vcodec"] as? String, acodec: f["acodec"] as? String,
                width: (f["width"] as? NSNumber)?.intValue, height: (f["height"] as? NSNumber)?.intValue,
                fps: (f["fps"] as? NSNumber)?.doubleValue, filesize: (f["filesize"] as? NSNumber)?.int64Value,
                tbr: (f["tbr"] as? NSNumber)?.doubleValue, formatNote: f["formatNote"] as? String,
                protocolName: f["protocolName"] as? String))
        }
        jobs[index].availableFormats = formats

        let videoOnly = formats.filter { $0.isVideoOnly }.sorted { ($0.height ?? 0) > ($1.height ?? 0) }
        let audioOnly = formats.filter { $0.isAudioOnly }.sorted { ($0.tbr ?? 0) > ($1.tbr ?? 0) }
        let muxed = formats.filter { $0.isMuxed }.sorted { ($0.height ?? 0) > ($1.height ?? 0) }
        jobs[index].selectedVideoFormatId = nil
        jobs[index].selectedAudioFormatId = nil
        if let bestVideo = videoOnly.first, (bestVideo.height ?? 0) >= (muxed.first?.height ?? 0) || muxed.isEmpty {
            jobs[index].selectedVideoFormatId = bestVideo.formatId
            jobs[index].selectedAudioFormatId = audioOnly.first?.formatId
        } else if let bestMux = muxed.first {
            jobs[index].selectedVideoFormatId = bestMux.formatId
        } else if let bestAudio = audioOnly.first {
            jobs[index].selectedAudioFormatId = bestAudio.formatId
        }

        var subs: [SubtitleOption] = []
        for s in payload["subtitles"] as? [[String: Any]] ?? [] {
            if let lang = s["lang"] as? String {
                subs.append(SubtitleOption(lang: lang, name: s["name"] as? String, isAuto: s["isAuto"] as? Bool ?? false))
            }
        }
        jobs[index].availableSubtitles = subs
        jobs[index].selectedSubtitleIds = []
    }

    // MARK: Download

    /// Builds the exact request sent to the engine. Only conditions known at selection time are expected.
    func makeDownloadSpec(job: JobRecord, outputDir: String) -> (spec: [String: Any], componentIds: [String])? {
        let video = job.availableFormats.first { $0.formatId == job.selectedVideoFormatId }
        var audio = job.availableFormats.first { $0.formatId == job.selectedAudioFormatId }
        var comps: [MediaFormat] = []
        if let v = video {
            comps.append(v)
            if v.isVideoOnly {
                if audio == nil {
                    audio = job.availableFormats.filter { $0.isAudioOnly }.max { ($0.tbr ?? 0) < ($1.tbr ?? 0) }
                }
                if let a = audio, a.isAudioOnly { comps.append(a) }
            }
        } else if let a = audio, a.isAudioOnly {
            comps.append(a)
        }
        guard !comps.isEmpty else { return nil }

        let intent: String
        if comps.contains(where: { $0.vcodec != nil && $0.vcodec != "none" }) {
            intent = "video"
        } else if comps.allSatisfy({ $0.isAudioOnly }) {
            intent = "audio"
        } else {
            intent = "media"
        }

        var components: [[String: Any]] = []
        for f in comps {
            var d: [String: Any] = ["formatId": f.formatId]
            if let h = f.height { d["height"] = h }
            if let w = f.width { d["width"] = w }
            if let v = f.vcodec { d["vcodec"] = v }
            if let a = f.acodec { d["acodec"] = a }
            if let p = f.protocolName { d["protocol"] = p }
            components.append(d)
        }
        var expected: [String: Any] = ["components": components, "intent": intent]
        if let e = job.extractor, !e.isEmpty { expected["extractor"] = e }
        if let m = job.mediaId, !m.isEmpty { expected["mediaId"] = m }

        let ids = comps.map { $0.formatId }
        let spec: [String: Any] = [
            "mode": RunMode.full.rawValue,
            "outputDir": outputDir,
            "formatId": ids.joined(separator: "+"),
            "expected": expected,
            "subtitles": subtitleSpecs(for: job)
        ]
        return (spec, ids)
    }

    /// One subtitle track at most (manual or auto is part of the choice and is enforced by the engine).
    private func subtitleSpecs(for job: JobRecord) -> [[String: Any]] {
        var out: [[String: Any]] = []
        for id in job.selectedSubtitleIds {
            if let s = job.availableSubtitles.first(where: { $0.id == id }) {
                let item: [String: Any] = ["lang": s.lang, "isAuto": s.isAuto]
                out.append(item)
            }
        }
        return out
    }

    public func confirmSelectionAndDownload(jobId: String) {
        guard let index = jobs.firstIndex(where: { $0.id == jobId }),
              jobs[index].state == .awaitingSelection else { return }
        guard hasUsableSourceForStart(jobs[index]) else {
            jobs[index].stateMessage = "원본 주소 재입력 필요: 보안을 위해 주소가 저장되지 않았습니다."
            showAlert("보안을 위해 원본 주소가 저장되지 않아 시작할 수 없습니다. 원본 주소를 다시 입력해 분석해 주세요.")
            return
        }
        guard makeDownloadSpec(job: jobs[index], outputDir: "/") != nil else {
            showAlert("저장할 화질 또는 음원을 선택해 주세요.")
            return
        }
        resetAutoRecovery(jobId)
        jobs[index].pendingDownload = true
        jobs[index].runMode = .full
        jobs[index].state = .queued
        jobs[index].stateMessage = jobs[index].isLive ? "녹화 대기 중입니다." : "다운로드 대기 중입니다."
        jobs[index].updatedAt = Date()
        persistJobs()
        processQueue()
    }

    private func newWorkDirectory(job: JobRecord) -> URL? {
        let dir = config.workRoot
            .appendingPathComponent(job.id, isDirectory: true)
            .appendingPathComponent("gen\(job.generation)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            return dir
        } catch {
            return nil
        }
    }

    private func startDownload(job: JobRecord) {
        guard activeRuns[job.id] == nil else { return }
        guard let dir = newWorkDirectory(job: job) else {
            updateJob(job.id) { $0.state = .failed; $0.stateMessage = "작업 폴더를 만들 수 없습니다." }
            persistJobs()
            processQueue()
            return
        }
        var spec: [String: Any]
        if job.runMode == .subtitlesOnly {
            var expected: [String: Any] = [:]
            if let e = job.extractor, !e.isEmpty { expected["extractor"] = e }
            if let m = job.mediaId, !m.isEmpty { expected["mediaId"] = m }
            spec = ["mode": RunMode.subtitlesOnly.rawValue, "outputDir": dir.path, "expected": expected,
                    "subtitles": subtitleSpecs(for: job)]
        } else if let built = makeDownloadSpec(job: job, outputDir: dir.path) {
            spec = built.spec
        } else {
            updateJob(job.id) { $0.state = .failed; $0.stateMessage = "선택한 형식을 확인할 수 없습니다. 다시 분석해 주세요."; $0.pendingDownload = false }
            persistJobs()
            processQueue()
            return
        }
        spec["outputDir"] = dir.path
        let recording = job.isLive && job.runMode == .full
        let limit = max(60, min(job.recordLimitSeconds, 43200))
        if recording { spec["limitSeconds"] = limit }

        updateJob(job.id) {
            $0.state = recording ? .recording : .downloading
            $0.stateMessage = recording ? "녹화를 준비하는 중입니다..."
                : ($0.runMode == .subtitlesOnly ? "자막만 다시 받는 중입니다..." : "다운로드를 시작합니다...")
            $0.progressPercent = 0
            $0.downloadedBytes = 0
            $0.totalBytes = 0
            $0.speed = 0
            $0.recordedSeconds = 0
            $0.phase = recording ? "recording" : "downloading"
            $0.workDirectory = dir.path
            $0.manifest = $0.runMode == .full ? nil : $0.manifest
            $0.updatedAt = Date()
        }
        let run = ActiveRun(jobId: job.id, generation: job.generation, kind: recording ? .record : .download)
        if job.runMode == .subtitlesOnly { run.restoreStateOnStop = .completedWithSubtitleFailure }
        activeRuns[job.id] = run
        persistJobs()
        let finalSpec = spec
        prepareContext(for: job, run: run) { [weak self] context in
            guard let self = self, self.activeRuns[job.id] === run else { return }
            let onEvent: (String, [String: Any]) -> Void = { [weak self] event, payload in
                MainActor.assumeIsolated { self?.handleEngineEvent(run: run, event: event, payload: payload) }
            }
            let onExit: (EngineTaskResult) -> Void = { [weak self] result in
                MainActor.assumeIsolated { self?.handleExit(run: run, result: result) }
            }
            if recording {
                // Hard bound also covers verification and a possible post-capture MP4 conversion; the engine ends
                // its own conversion earlier (Engine/live.py `_convert_deadline` mirrors `limit * 7 + 3000`).
                run.handle = EngineBridge.shared.startRecording(
                    jobId: job.id, generation: job.generation, url: job.sourceURL, spec: finalSpec,
                    context: context, limitSeconds: limit * 7 + 3000, onEvent: onEvent, onExit: onExit)
                if run.gracefulFinish { run.handle?.requestGracefulStop() }
            } else {
                run.handle = EngineBridge.shared.startDownload(
                    jobId: job.id, generation: job.generation, url: job.sourceURL, spec: finalSpec,
                    context: context, onEvent: onEvent, onExit: onExit)
            }
        }
    }

    /// "녹화 마치고 저장": FFmpeg finishes the container and only the captured portion is verified and published.
    /// Not a cancel: `userStopped` stays false, and the outcome still comes from the engine's terminal event.
    public func finishRecording(jobId: String) {
        guard let run = activeRuns[jobId], run.kind == .record, !run.userStopped, !run.gracefulFinish,
              let index = jobs.firstIndex(where: { $0.id == jobId && $0.generation == run.generation }),
              jobs[index].state == .recording else { return }
        run.gracefulFinish = true
        run.handle?.requestGracefulStop()
        jobs[index].state = .processing
        jobs[index].stateMessage = "녹화를 마무리하는 중입니다. 지금까지 녹화한 구간만 저장합니다..."
        jobs[index].updatedAt = Date()
        persistJobs()
    }

    public func setRecordLimit(jobId: String, seconds: Int) {
        guard let index = jobs.firstIndex(where: { $0.id == jobId }), jobs[index].state == .awaitingSelection else { return }
        jobs[index].recordLimitSeconds = max(60, min(seconds, 43200))
    }

    // MARK: Engine events (live display + remembering the terminal event only)

    /// Entry used by the engine closures and by tests. Late events from an older run/generation are dropped.
    @discardableResult
    func deliverEngineEvent(jobId: String, generation: Int, event: String, payload: [String: Any]) -> Bool {
        guard let run = activeRuns[jobId], run.generation == generation else { return false }
        return handleEngineEvent(run: run, event: event, payload: payload)
    }

    @discardableResult
    private func handleEngineEvent(run: ActiveRun, event: String, payload: [String: Any]) -> Bool {
        guard activeRuns[run.jobId] === run,
              let index = jobs.firstIndex(where: { $0.id == run.jobId && $0.generation == run.generation }) else { return false }
        if run.userStopped { return false }
        captureEventDiagnostics(run: run, index: index, event: event, payload: payload)

        switch event {
        case "progress" where run.kind == .record:
            let phase = payload["phase"] as? String ?? jobs[index].phase
            jobs[index].phase = phase
            if phase == "verifying" {
                jobs[index].state = .verifying
            } else if phase == "converting" {
                // Post-capture MP4 remux/conversion of the verified recording (engine mp4.py).
                jobs[index].state = .processing
                if let p = (payload["percent"] as? NSNumber)?.doubleValue { jobs[index].progressPercent = p }
            } else if phase == "recording" && !run.gracefulFinish && jobs[index].state == .recording {
                if let s = (payload["recordedSeconds"] as? NSNumber)?.doubleValue { jobs[index].recordedSeconds = s }
                if let d = (payload["downloadedBytes"] as? NSNumber)?.int64Value { jobs[index].downloadedBytes = d }
                if let p = (payload["percent"] as? NSNumber)?.doubleValue { jobs[index].progressPercent = p }
            }
            if !run.gracefulFinish || phase == "verifying" || phase == "converting", let msg = payload["message"] as? String {
                jobs[index].stateMessage = redactPersistedText(msg)
            }

        case "progress":
            if run.kind == .download {
                let phase = payload["phase"] as? String ?? jobs[index].phase
                jobs[index].phase = phase
                if phase == "verifying" { jobs[index].state = .verifying }
                if phase == "converting" { jobs[index].state = .processing }   // final MP4 remux/conversion
                if let p = (payload["percent"] as? NSNumber)?.doubleValue { jobs[index].progressPercent = p }
                if let d = (payload["downloadedBytes"] as? NSNumber)?.int64Value { jobs[index].downloadedBytes = d }
                if let t = (payload["totalBytes"] as? NSNumber)?.int64Value { jobs[index].totalBytes = t }
                if let s = (payload["speed"] as? NSNumber)?.doubleValue { jobs[index].speed = s }
                if let e = (payload["eta"] as? NSNumber)?.doubleValue { jobs[index].eta = e }
            }
            if let msg = payload["message"] as? String { jobs[index].stateMessage = redactPersistedText(msg) }

        case "processing":
            if (run.kind == .download || run.kind == .record) && jobs[index].state != .verifying {
                jobs[index].state = .processing
                jobs[index].stateMessage = payload["message"] as? String ?? "오디오/비디오 병합 중..."
            }

        case "formatsExtracted":
            run.extractPayload = payload

        case "extractCompleted", "selectionChanged", "verificationIncomplete", "verificationFailed", "error", "verified":
            run.terminal = event
            run.terminalPayload = payload

        default:
            break
        }
        return true
    }

    private func recordUncleanProcess(_ handle: EngineTaskHandle?) {
        if queueBlockedReason != nil && queueBlockedReason != Self.engineCleanupBlockedMessage && priorNonCleanupBlocker == nil {
            priorNonCleanupBlocker = queueBlockedReason
        }
        queueBlockedReason = Self.engineCleanupBlockedMessage
        if let handle = handle, handle.processGroupId > 0 {
            uncleanProcessGroups[handle.processGroupId] = handle
        } else {
            hasUnresolvedUnknownCleanup = true
        }
    }

    // MARK: Process exit = the only place where outcomes are decided

    private func handleExit(run: ActiveRun, result: EngineTaskResult) {
        guard activeRuns[run.jobId] === run else { return }
        activeRuns.removeValue(forKey: run.jobId)

        if !result.groupClean {
            recordUncleanProcess(run.handle)
        }

        guard let index = jobs.firstIndex(where: { $0.id == run.jobId && $0.generation == run.generation }) else {
            persistJobs()
            processQueue()
            return
        }
        captureExitDiagnostics(run: run, index: index, result: result)

        if run.userStopped || (result.cancelled && !result.timedOut) {
            // pause/cancel already set the visible state; nothing may be promoted to success.
            persistJobs()
            processQueue()
            return
        }

        // A timeout is never success (the killed group cannot pass `clean`); it falls through to failJob below.
        let clean = !result.cancelled && result.exitCode == 0 && result.readyHandshake && result.groupClean && result.pipesDrained
        switch run.kind {
        case .extract:
            if clean, run.terminal == "extractCompleted", let payload = run.extractPayload {
                applyExtracted(payload, to: index)
                if let plan = captureDependencyPlan(from: payload, run: run) {
                    dependencyPlans[run.jobId] = plan
                } else {
                    dependencyPlans[run.jobId] = nil
                }
                jobs[index].state = .awaitingSelection
                jobs[index].stateMessage = jobs[index].isLive
                    ? "실시간 방송입니다. 녹화할 화질과 최대 녹화 시간을 고른 뒤 '녹화 시작'을 눌러 주세요."
                    : "다운로드할 화질과 자막을 선택해 주세요."
                // Every new link is analysed and then downloaded at once with the existing default selection
                // (best video + audio from `applyExtracted`). One-shot: the flag is consumed here, so selection
                // changes, retries and live recordings never inherit it. Live streams never start by themselves.
                let job = jobs[index]
                if job.autoConfirm {
                    jobs[index].autoConfirm = false
                    if job.isLive {
                        jobs[index].stateMessage = "실시간 방송입니다. 녹화할 화질과 최대 녹화 시간을 고른 뒤 '녹화 시작'을 눌러 주세요."
                    } else if !hasUsableSourceForStart(job) {
                        jobs[index].stateMessage = "원본 주소 재입력 필요: 보안을 위해 주소가 저장되지 않아 자동으로 받지 않았습니다."
                    } else if makeDownloadSpec(job: job, outputDir: "/") != nil {
                        resetAutoRecovery(job.id)
                        jobs[index].pendingDownload = true
                        jobs[index].runMode = .full
                        jobs[index].state = .queued
                        jobs[index].stateMessage = "다운로드 대기 중입니다."
                    } else {
                        jobs[index].stateMessage = "자동으로 받을 수 있는 화질이 없습니다. 화질을 직접 고른 뒤 '다운로드 시작'을 눌러 주세요."
                    }
                }
            } else {
                dependencyPlans[run.jobId] = nil
                jobs[index].autoConfirm = false
                failJob(index, run: run, result: result, defaultMessage: "영상 정보를 분석하지 못했습니다.")
            }

        case .download, .record:
            switch (run.terminal, clean) {
            case ("verified", true):
                if acceptVerified(index: index, payload: run.terminalPayload) {
                    persistJobs()
                    beginPublish(jobId: run.jobId)
                    return
                }
                failJob(index, run: run, result: result, defaultMessage: "엔진이 알려준 산출물 정보를 신뢰할 수 없어 저장하지 않았습니다.")
            case ("selectionChanged", _) where run.kind == .record:
                // Live formats come and go: re-analyse instead of retrying a stale selection.
                jobs[index].state = .selectionChanged
                jobs[index].pendingDownload = false
                jobs[index].availableFormats = []
                jobs[index].stateMessage = redactPersistedText(run.terminalPayload["reason"] as? String ?? "방송 상태가 바뀌어 녹화하지 않았습니다.")
            case ("selectionChanged", _):
                jobs[index].state = .selectionChanged
                jobs[index].pendingDownload = false
                jobs[index].stateMessage = redactPersistedText(run.terminalPayload["reason"] as? String ?? "선택한 규격과 서버 응답이 달라져 다운로드를 차단했습니다.")
            case ("verificationIncomplete", _):
                jobs[index].state = .verificationIncomplete
                jobs[index].stateMessage = redactPersistedText(run.terminalPayload["reason"] as? String ?? "파일을 끝까지 검증하지 못해 저장하지 않았습니다.")
            case ("verificationFailed", _):
                jobs[index].state = .failed
                jobs[index].stateMessage = redactPersistedText(run.terminalPayload["reason"] as? String ?? "손상되었거나 영상이 아닌 파일이라 저장하지 않았습니다.")
            default:
                failJob(index, run: run, result: result,
                        defaultMessage: run.kind == .record ? "녹화에 실패했습니다." : "다운로드에 실패했습니다.")
            }
            if let restore = run.restoreStateOnStop, jobs[index].state != .selectionChanged,
               jobs[index].publishedMediaPath != nil {
                let msg = jobs[index].stateMessage
                jobs[index].state = restore
                jobs[index].stateMessage = "자막을 다시 받지 못했습니다: \(msg ?? "")"
                jobs[index].runMode = .full
            }

        case .publish:
            break
        }
        jobs[index].updatedAt = Date()
        persistJobs()
        processQueue()
    }

    // MARK: Diagnostic trace capture (whitelist fields only; see Diagnostics.swift)

    private func diagnosticStage(_ kind: RunKind) -> DiagStage? {
        switch kind {
        case .extract: return .extract
        case .download: return .download
        case .record: return .record
        case .publish: return .publish
        }
    }

    /// Publish stage: fixed phase/code/category only; the error's text, paths and manifest are never read.
    private func capturePublishPhase(run: ActiveRun, index: Int, phase: String) {
        guard jobs[index].generation == run.generation else { return }
        diagnostics.notePhase(jobId: run.jobId, generation: run.generation, stage: .publish, phase: phase,
                              context: diagnosticContext(index, run: run))
    }

    private func capturePublishFailure(run: ActiveRun, index: Int, error: Error) {
        guard jobs[index].generation == run.generation else { return }
        if case PublishError.cancelledBeforePublish = error { return }   // a cancellation is not a failure
        let code = run.restoreStateOnStop != nil ? "subtitle_publish_failed" : "publish_failed"
        let category = error is CocoaError || error is POSIXError ? "filesystem" : "other"
        diagnostics.noteFailure(jobId: run.jobId, generation: run.generation, stage: .publish, code: code,
                                category: category, httpStatus: nil, tuning: nil, context: diagnosticContext(index, run: run))
    }

    /// Minimal facts of the current job: host of its address (URL.host only), extractor, protocol of the chosen format.
    /// `run` is the explicitly retained run (terminal paths clear `activeRun` first); it is used only when it belongs to
    /// this job and generation, otherwise the live `activeRun` is tried under the same check, else no snapshot.
    private func diagnosticContext(_ index: Int, run: ActiveRun? = nil) -> DiagContext {
        let job = jobs[index]
        let chosen = job.availableFormats.first { $0.formatId == job.selectedVideoFormatId }
            ?? job.availableFormats.first { $0.formatId == job.selectedAudioFormatId }
        let sourceHost = URL(string: job.sourceURL)?.host
        var context = DiagContext(host: sourceHost, extractor: job.extractor, proto: chosen?.protocolName)
        context.pageHost = job.pageHost ?? (job.fromBrowser ? nil : DiagSanitize.host(sourceHost))
        context.frameHost = job.frameHost
        func owned(_ r: ActiveRun?) -> ActiveRun? {
            guard let r = r, r.jobId == job.id, r.generation == job.generation else { return nil }
            return r
        }
        if let owner = owned(run) ?? owned(activeRuns[job.id]) {
            context.requested = owner.requestedContext
            context.attached = owner.attachedContext
        }
        return context
    }

    /// Phase and tuning-decision changes only (the store drops repeats); called after the job/generation guard.
    private func captureEventDiagnostics(run: ActiveRun, index: Int, event: String, payload: [String: Any]) {
        guard let stage = diagnosticStage(run.kind) else { return }
        switch event {
        case "progress":
            let context = diagnosticContext(index, run: run)
            if let phase = payload["phase"] as? String {
                diagnostics.notePhase(jobId: run.jobId, generation: run.generation, stage: stage, phase: phase, context: context)
            }
            if let tuning = payload["tuning"] {
                diagnostics.noteTuning(jobId: run.jobId, generation: run.generation, stage: stage, tuning: tuning, context: context)
            }
        case "processing":
            diagnostics.notePhase(jobId: run.jobId, generation: run.generation, stage: stage, phase: "processing",
                                  context: diagnosticContext(index, run: run))
        default:
            break
        }
    }

    private func captureExitDiagnostics(run: ActiveRun, index: Int, result: EngineTaskResult) {
        guard let stage = diagnosticStage(run.kind) else { return }
        var context = diagnosticContext(index, run: run)
        if context.extractor == nil { context.extractor = run.extractPayload?["extractor"] as? String }
        diagnostics.noteOutcome(jobId: run.jobId, generation: run.generation, stage: stage, terminal: run.terminal,
                                result: result, context: context)
    }

    /// Failure class from the engine's typed `diag`/`code`/`tuning` fields only; message/detail are never read.
    private func captureFailureDiagnostics(index: Int, run: ActiveRun, result: EngineTaskResult) {
        guard let stage = diagnosticStage(run.kind) else { return }
        var code: String?
        var category: String
        var status: Any?
        var tuning: Any?
        if run.terminal == "error" {
            code = run.terminalPayload["code"] as? String
            let diag = run.terminalPayload["diag"] as? [String: Any]
            category = diag?["category"] as? String ?? "other"
            status = diag?["httpStatus"]
            tuning = run.terminalPayload["tuning"]
        } else if result.timedOut {
            category = "timeout"
        } else if result.spawnError != nil || result.terminatedBySignal != nil || !result.readyHandshake {
            category = "process"
        } else {
            category = "other"
        }
        var context = diagnosticContext(index, run: run)
        if let diag = run.terminalPayload["diag"] as? [String: Any] {
            if category == "http" { context.requestHost = DiagSanitize.dnsHost(diag["requestHost"] as? String) }
            context.httpEvidence = DiagHttpEvidence(json: diag)
        }
        // Only this run's own proxy client tag in the current helper generation (never the browser's or other jobs').
        // `activeRun` is already cleared by handleExit, so ownership is the run's job/generation against the current job.
        if jobs[index].id == run.jobId, jobs[index].generation == run.generation,
           connection.enabled, !run.proxyClient.isEmpty, connection.generation == run.helperGeneration,
           let refusal = connection.refusals(forClient: run.proxyClient).first {
            context.refusalHost = refusal.host
            context.refusalCode = DiagRefusalCode(rawValue: refusal.code)?.rawValue ?? DiagRefusalCode.other.rawValue
        }
        diagnostics.noteFailure(jobId: run.jobId, generation: run.generation, stage: stage, code: code, category: category,
                                httpStatus: status, tuning: tuning, context: context)
    }

    // MARK: Diagnostic export (user-initiated, read-only, nothing is sent anywhere)

    /// '진단 로그 내보내기': versions come from the cached health or one local check, then the user picks a ZIP
    /// destination in a non-blocking save panel. Running downloads are not touched.
    /// When `jobId` is provided, exports only the selected job's diagnostics.
    public func exportDiagnostics(jobId: String? = nil) {
        guard !diagnosticsExportBusy else { return }
        let targetJobId = jobId
        if let tid = targetJobId {
            guard jobs.contains(where: { $0.id == tid }) else { return }
        }
        diagnosticsExportBusy = true
        if engineHealth.checked {
            presentDiagnosticsSavePanel(health: engineHealth, jobId: targetJobId)
            return
        }
        EngineBridge.shared.checkHealth { [weak self] status in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                self.engineHealth = status
                if let tid = targetJobId, !self.jobs.contains(where: { $0.id == tid }) {
                    self.diagnosticsExportBusy = false
                    return
                }
                self.presentDiagnosticsSavePanel(health: status, jobId: targetJobId)
            }
        }
    }

    private func presentDiagnosticsSavePanel(health: EngineHealthStatus, jobId: String? = nil) {
        let targetJobId = jobId
        if let tid = targetJobId, !jobs.contains(where: { $0.id == tid }) {
            diagnosticsExportBusy = false
            return
        }
        let panel = NSSavePanel()
        panel.title = "로그 저장"
        if targetJobId != nil {
            panel.message = "선택한 작업의 상태와 최근 진단 기록, 안전하게 보관할 수 있는 공개 페이지 참조를 ZIP으로 저장합니다. 영상·제목·쿠키·비밀번호는 포함하지 않으며, 어디로도 자동 전송하지 않습니다."
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyyMMdd-HHmmss"
            panel.nameFieldStringValue = "HTD-job-diagnostics-\(f.string(from: Date())).zip"
        } else {
            panel.message = "현재 작업 상태와 최근 진단 기록, 안전하게 보관할 수 있는 공개 페이지 참조를 ZIP으로 저장합니다. 영상·제목·쿠키·비밀번호는 포함하지 않으며, 어디로도 자동 전송하지 않습니다."
            panel.nameFieldStringValue = DiagnosticsExporter.suggestedFileName()
        }
        panel.prompt = "저장"
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        panel.begin { [weak self] response in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                guard response == .OK, let url = panel.url else {
                    self.diagnosticsExportBusy = false
                    return
                }
                if let tid = targetJobId, !self.jobs.contains(where: { $0.id == tid }) {
                    self.diagnosticsExportBusy = false
                    return
                }
                self.writeDiagnosticsZip(to: url, health: health, jobId: targetJobId)
            }
        }
    }

    private func writeDiagnosticsZip(to url: URL, health: EngineHealthStatus, jobId: String? = nil) {
        let targetJobId = jobId
        if let tid = targetJobId, !jobs.contains(where: { $0.id == tid }) {
            diagnosticsExportBusy = false
            return
        }

        let allEvents = diagnostics.snapshot()
        let events: [DiagEvent]
        let connectionFailures: [ConnectionManager.BlockedHost]

        if let tid = targetJobId {
            connectionFailures = []
            if let job = jobs.first(where: { $0.id == tid }),
               let traceId = diagnostics.traceJobId(jobId: job.id, generation: job.generation) {
                events = allEvents.filter { $0.job == traceId }
            } else {
                events = []
            }
        } else {
            connectionFailures = Array(connection.blocked)
            events = allEvents
        }

        let queueSnapshot = captureQueueSnapshot(events: events, jobId: targetJobId)
        let trace = DiagnosticsExporter.traceData(events)
        let report = DiagnosticsExporter.reportData(events, queue: queueSnapshot)
        let manifest = DiagnosticsExporter.manifestData(
            health: health, connectionHelp: connection.enabled,
            runtimeMode: EngineBridge.shared.runtimeModeName, eventCount: events.count,
            queue: queueSnapshot, connectionFailures: connectionFailures)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let ok = DiagnosticsExporter.writeZip(manifest: manifest, trace: trace, report: report, destination: url)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.diagnosticsExportBusy = false
                    self?.setDropFeedback(ok ? "진단 로그를 ZIP 파일로 저장했습니다." : "진단 로그를 저장하지 못했습니다. 다른 위치를 골라 다시 시도해 주세요.")
                }
            }
        }
    }

    @MainActor
    func captureQueueSnapshot(events: [DiagEvent], jobId: String? = nil) -> DiagnosticsQueueSnapshot {
        let total: Int
        let included: Int
        let truncated: Int
        let slice: [JobRecord]

        if let targetId = jobId {
            if let targetJob = jobs.first(where: { $0.id == targetId }) {
                total = 1
                included = 1
                truncated = 0
                slice = [targetJob]
            } else {
                total = 0
                included = 0
                truncated = 0
                slice = []
            }
        } else {
            total = jobs.count
            let cap = DiagnosticsQueueSnapshot.maxSnapshotRows
            slice = Array(jobs.prefix(cap))
            included = slice.count
            truncated = max(0, total - included)
        }

        var latestFailuresByTraceJobId: [String: DiagEvent] = [:]
        for e in events where e.kind == .failure {
            latestFailuresByTraceJobId[e.job] = e
        }

        var items: [DiagnosticsQueueItem] = []
        items.reserveCapacity(included)

        for job in slice {
            let traceId = diagnostics.traceJobId(jobId: job.id, generation: job.generation)
            let traceLinked = (traceId != nil)
            let failureEvent = traceId.flatMap { latestFailuresByTraceJobId[$0] }

            let chosenVideo = job.availableFormats.first { $0.formatId == job.selectedVideoFormatId }
            let chosenAudio = job.availableFormats.first { $0.formatId == job.selectedAudioFormatId }
            var formatIds: [String] = []
            if let vid = chosenVideo?.formatId, let s = DiagSanitize.formatId(vid) { formatIds.append(s) }
            if let aid = chosenAudio?.formatId, let s = DiagSanitize.formatId(aid), !formatIds.contains(s) { formatIds.append(s) }

            let chosenFormat = chosenVideo ?? chosenAudio
            let rawExt = chosenFormat?.ext.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            let safeExt: String? = {
                guard let e = rawExt, !e.isEmpty, e.count <= 10,
                      e.allSatisfy({ ($0 >= "a" && $0 <= "z") || ($0 >= "0" && $0 <= "9") }) else { return nil }
                return e
            }()

            let safeProto = DiagSanitize.proto(chosenFormat?.protocolName)?.rawValue
            let safeRes: String? = {
                guard let f = chosenFormat else { return nil }
                if let h = f.height, (1...65536).contains(h) {
                    if let w = f.width, (1...65536).contains(w) { return "\(w)x\(h)" }
                    return "\(h)p"
                }
                return f.isAudioOnly ? "오디오 전용" : nil
            }()

            let sourceHost = URL(string: job.sourceURL)?.host
            let safeSourceHost = DiagSanitize.dnsHost(sourceHost)
            let safePageHost = DiagSanitize.dnsHost(job.pageHost)
            let safeFrameHost = DiagSanitize.dnsHost(job.frameHost)

            let safeBrowserPage = (job.browserPageReference ?? job.retryPageURL).flatMap {
                validateSafeRetryPageURL($0, fromBrowser: false, hasPageProvenance: true)
            }

            let isPendingRetry = autoRecoveryWaiting[job.id] == job.generation

            let item = DiagnosticsQueueItem(
                jobId: UUID(uuidString: job.id)?.uuidString.lowercased(),
                frameHost: safeFrameHost,
                id: traceId,
                traceLinked: traceLinked,
                state: job.state.rawValue,
                generation: max(0, min(job.generation, 9999)),
                sourceHost: safeSourceHost,
                pageHost: safePageHost,
                fromBrowser: job.fromBrowser,
                safeBrowserPageReference: safeBrowserPage,
                extractor: DiagSanitize.extractor(job.extractor),
                selectedFormatIds: formatIds,
                ext: safeExt,
                protocolName: safeProto,
                resolution: safeRes,
                filesize: job.totalBytes > 0 ? job.totalBytes : (chosenFormat?.filesize.flatMap { $0 > 0 ? $0 : nil }),
                progressPercent: job.progressPercent.isFinite ? max(0, min(job.progressPercent, 100)) : nil,
                speedBytesPerSec: job.speed.isFinite && job.speed >= 0 ? min(job.speed, 1e12) : nil,
                downloadedBytes: max(0, job.downloadedBytes),
                totalBytes: max(0, job.totalBytes),
                isLive: job.isLive,
                recordLimitSeconds: job.isLive ? max(60, min(job.recordLimitSeconds, 43200)) : nil,
                pendingDownload: job.pendingDownload,
                pendingPublish: job.pendingPublish,
                pendingRetry: isPendingRetry,
                helperEnabled: connection.enabled,
                latestFailureHttpStatus: failureEvent?.httpStatus,
                latestFailureCategory: failureEvent?.errorCategory?.rawValue,
                latestFailureCode: failureEvent?.errorCode,
                latestFailureStage: failureEvent?.httpEvidence?.failureStage?.rawValue ?? failureEvent?.stage.rawValue,
                latestHttpEvidence: failureEvent?.httpEvidence.map { DiagHttpEvidenceSummary(evidence: $0) }
            )
            items.append(item)
        }

        return DiagnosticsQueueSnapshot(
            totalCount: total,
            includedCount: included,
            truncatedCount: truncated,
            isTruncated: truncated > 0,
            items: items
        )
    }

    private func failJob(_ index: Int, run: ActiveRun, result: EngineTaskResult, defaultMessage: String) {
        captureFailureDiagnostics(index: index, run: run, result: result)
        var message = defaultMessage
        if run.terminal == "error", let m = run.terminalPayload["message"] as? String {
            message = m
            if let detail = run.terminalPayload["detail"] as? String, !detail.isEmpty { message += " (\(detail))" }
        } else if let spawn = result.spawnError {
            message = spawn
        } else if result.timedOut {
            message = "엔진 응답 시간이 초과되었습니다."
        } else if let sig = result.terminatedBySignal {
            message = "엔진이 신호 \(sig)로 종료되었습니다."
        } else if !result.readyHandshake && result.exitCode != nil {
            message = "엔진 프로세스 소유권 확인에 실패했습니다."
        } else if let code = result.exitCode, code != 0 {
            message = defaultMessage + " (엔진 종료 코드 \(code))"
        } else if !result.groupClean {
            message = "엔진 하위 프로세스를 정리하지 못했습니다."
        }
        let engineMessage = message
        // Proxy refusals of THIS run (its own client tag) are reported separately from site/login errors and kept
        // for "허용 후 다시 시도" (hostnames and reason codes only, no paths or secrets).
        connectionRecoveries[run.jobId] = nil
        if connection.enabled, !run.proxyClient.isEmpty, connection.generation == run.helperGeneration {
            let refused = connection.refusals(forClient: run.proxyClient)
            if !refused.isEmpty {
                let allowable = refused.filter { $0.canAllow }.map { $0.host }
                let others = refused.filter { !$0.canAllow }.prefix(4).map {
                    ConnectionRecovery.Refusal(host: $0.host, code: $0.code, reason: $0.reason)
                }
                connectionRecoveries[run.jobId] = ConnectionRecovery(
                    generation: run.generation, helperGeneration: run.helperGeneration,
                    allowable: Array(allowable.prefix(Self.recoveryHostLimit)),
                    omitted: max(0, allowable.count - Self.recoveryHostLimit), others: Array(others))
                // The user authorized allowing the extra servers a download needs: try that first, within bounds.
                if startAutoRecovery(index: index, run: run, result: result, refused: refused) { return }
                let hosts = refused.prefix(4).map { $0.host }.joined(separator: ", ")
                let matchingRec = connectionRecoveries[run.jobId]
                let isOwned = matchingRec?.generation == run.generation && matchingRec?.helperGeneration == run.helperGeneration
                var explanations: [String] = []
                if isOwned, let prob = matchingRec?.problem, !prob.isEmpty {
                    explanations.append(prob)
                }
                if isOwned, let otherRefusals = matchingRec?.others, !otherRefusals.isEmpty {
                    let keyOthers = otherRefusals.prefix(2).map { "\($0.host) (\($0.reason))" }.joined(separator: ", ")
                    explanations.append("허용 불가 연결: \(keyOthers)")
                }
                let why = explanations.isEmpty ? "" : " (" + explanations.joined(separator: " / ") + ")"
                message = "HTTPS 연결 도움이 이 작업의 연결을 막았습니다: \(hosts).\(why) (엔진 메시지: \(engineMessage))"
            }
        }
        jobs[index].state = .failed
        jobs[index].stateMessage = redactPersistedText(message)
        jobs[index].pendingDownload = false
    }

    private func acceptVerified(index: Int, payload: [String: Any]) -> Bool {
        var manifest = jobs[index].runMode == .subtitlesOnly ? (jobs[index].manifest ?? OutputManifest()) : OutputManifest()
        manifest.subtitleFiles = []
        if jobs[index].runMode == .full {
            guard let primary = payload["primary"] as? [String: Any],
                  let path = primary["path"] as? String,
                  let work = jobs[index].workDirectory,
                  let size = try? Publisher.validateOwnedRegularFile(path: path, root: work),
                  size == (primary["size"] as? NSNumber)?.int64Value else { return false }
            manifest.primaryMediaFile = path
            manifest.primarySize = size
            manifest.formatName = primary["format"] as? String
            manifest.duration = (primary["duration"] as? NSNumber)?.doubleValue
            manifest.width = (primary["width"] as? NSNumber)?.intValue
            manifest.height = (primary["height"] as? NSNumber)?.intValue
            manifest.vcodec = primary["vcodec"] as? String
            manifest.acodec = primary["acodec"] as? String
            manifest.completeness = primary["completeness"] as? String
            if let rec = payload["recording"] as? [String: Any] {
                manifest.isRecording = true
                manifest.recordedSeconds = (rec["seconds"] as? NSNumber)?.doubleValue
                manifest.recordingEndReason = rec["endReason"] as? String
            }
        }
        guard let work = jobs[index].workDirectory else { return false }
        for s in payload["subtitles"] as? [[String: Any]] ?? [] {
            guard let path = s["path"] as? String, let lang = s["lang"] as? String,
                  let size = try? Publisher.validateOwnedRegularFile(path: path, root: work) else { continue }
            manifest.subtitleFiles.append(SubtitleFile(
                path: path, lang: lang, isAuto: s["isAuto"] as? Bool ?? false,
                ext: s["ext"] as? String ?? "vtt", size: size))
        }
        manifest.subtitlesFailed = payload["subtitlesFailed"] as? Bool ?? false
        manifest.subtitleError = (payload["subtitleError"] as? String).map(redactPersistedText)
        if jobs[index].runMode == .subtitlesOnly && manifest.subtitleFiles.isEmpty { return false }
        jobs[index].manifest = manifest
        jobs[index].pendingPublish = true
        return true
    }

    // MARK: Publish (serialized with cancel through PublishControl; never blocks the main actor)

    private func beginPublish(jobId: String) {
        guard activeRuns[jobId] == nil,
              let index = jobs.firstIndex(where: { $0.id == jobId }),
              let manifest = jobs[index].manifest,
              let work = jobs[index].workDirectory else { return }

        jobs[index].state = .publishing
        jobs[index].pendingPublish = true
        jobs[index].stateMessage = "안전하게 저장 폴더로 이동 중..."
        jobs[index].updatedAt = Date()

        let run = ActiveRun(jobId: jobId, generation: jobs[index].generation, kind: .publish)
        let control = PublishControl()
        run.publishControl = control
        if jobs[index].runMode == .subtitlesOnly { run.restoreStateOnStop = .completedWithSubtitleFailure }
        activeRuns[jobId] = run
        capturePublishPhase(run: run, index: index, phase: "publishing")
        persistJobs()   // intent is on disk before the first byte moves
        processQueue()

        let destination = jobs[index].destinationFolder
        let workRoot = config.workRoot.path
        let journal = URL(fileURLWithPath: work).appendingPathComponent(".publish-journal.json")
        let generation = jobs[index].generation
        let existingBase = jobs[index].runMode == .subtitlesOnly
            ? jobs[index].publishedMediaPath.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension }
            : nil

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome = Result<PublishResult, Error> {
                try Publisher.publish(
                    manifest: manifest, destinationFolder: destination, workRoot: workRoot,
                    journalURL: journal, jobId: jobId, generation: generation,
                    existingBaseName: existingBase, control: control)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.finishPublish(run: run, outcome: outcome) }
            }
        }
    }

    private func finishPublish(run: ActiveRun, outcome: Result<PublishResult, Error>) {
        guard activeRuns[run.jobId] === run else { return }
        activeRuns.removeValue(forKey: run.jobId)
        guard let index = jobs.firstIndex(where: { $0.id == run.jobId && $0.generation == run.generation }) else {
            persistJobs()
            processQueue()
            return
        }
        jobs[index].pendingPublish = false

        switch outcome {
        case .success(let result):
            capturePublishPhase(run: run, index: index, phase: "published")
            let subtitleOnly = jobs[index].runMode == .subtitlesOnly
            if let media = result.publishedMediaPath { jobs[index].publishedMediaPath = media }
            jobs[index].publishedSubtitlePaths = (subtitleOnly ? jobs[index].publishedSubtitlePaths : []) + result.publishedSubtitlePaths
            jobs[index].progressPercent = 100
            jobs[index].pendingDownload = false
            let manifestFailed = jobs[index].manifest?.subtitlesFailed ?? false
            if manifestFailed || !result.failedSubtitleLangs.isEmpty {
                jobs[index].state = .completedWithSubtitleFailure
                let base = jobs[index].manifest?.subtitleError ?? "영상은 저장되었으나 자막을 가져오지 못했습니다."
                jobs[index].stateMessage = base
            } else if jobs[index].manifest?.isRecording == true {
                jobs[index].state = .completed
                let m = jobs[index].manifest
                let length = formatClock(m?.recordedSeconds ?? m?.duration ?? 0)
                let why = m?.recordingEndDescription.map { ", \($0)" } ?? ""
                jobs[index].stateMessage = "녹화 구간 저장 (녹화 길이 \(length)\(why)). 원본 방송 전체가 아니라 녹화한 구간입니다."
            } else {
                jobs[index].state = .completed
                jobs[index].stateMessage = subtitleOnly ? "자막을 저장했습니다." : "정상적으로 저장되었습니다."
                jobs[index].manifest?.subtitlesFailed = false
                jobs[index].manifest?.subtitleError = nil
            }
            jobs[index].runMode = .full
            removeWorkDirectory(for: jobs[index])

        case .failure(let error):
            capturePublishFailure(run: run, index: index, error: error)
            if let restore = run.restoreStateOnStop, jobs[index].publishedMediaPath != nil {
                jobs[index].state = restore
                jobs[index].runMode = .full
                jobs[index].stateMessage = "자막 저장에 실패했습니다: \(error.localizedDescription)"
            } else if case PublishError.cancelledBeforePublish = error {
                jobs[index].state = .cancelled
                jobs[index].stateMessage = error.localizedDescription
                jobs[index].pendingPublish = jobs[index].manifest != nil   // verified output stays re-publishable
            } else {
                jobs[index].state = .failed
                jobs[index].stateMessage = redactPersistedText("파일 저장 실패: \(error.localizedDescription)")
                jobs[index].pendingPublish = true   // verified output is still in the work folder and can be re-published
            }
        }
        jobs[index].updatedAt = Date()
        persistJobs()
        processQueue()
    }

    private func removeWorkDirectory(for job: JobRecord) {
        guard let work = job.workDirectory,
              let realRoot = Publisher.realPath(config.workRoot.path),
              let realWork = Publisher.realPath(work),
              realWork.hasPrefix(realRoot + "/") else { return }
        try? FileManager.default.removeItem(atPath: realWork)
        let parent = (realWork as NSString).deletingLastPathComponent
        if let rest = try? FileManager.default.contentsOfDirectory(atPath: parent), rest.isEmpty, parent != realRoot {
            try? FileManager.default.removeItem(atPath: parent)
        }
    }

    // MARK: - Pause, Cancel, Retry Actions

    public func pauseJob(jobId: String) {
        guard let index = jobs.firstIndex(where: { $0.id == jobId }) else { return }
        guard [.extracting, .downloading, .processing, .verifying, .queued].contains(jobs[index].state) else { return }
        // A live recording cannot be paused and resumed later; it is finished (saved) or cancelled.
        if jobs[index].isLive && jobs[index].pendingDownload { return }
        if let run = activeRuns[jobId], run.generation == jobs[index].generation, run.kind != .publish {
            run.userStopped = true
            run.handle?.cancel()
        }
        autoRecoveryWaiting[jobId] = nil
        jobs[index].state = .paused
        jobs[index].stateMessage = "사용자에 의해 일시 정지되었습니다. 재개하면 처음부터 다시 받습니다."
        jobs[index].updatedAt = Date()
        persistJobs()
    }

    public func resumeJob(jobId: String) {
        guard activeRuns[jobId] == nil else { return }
        guard let index = jobs.firstIndex(where: { $0.id == jobId }), jobs[index].state == .paused else { return }
        if jobs[index].urlWasRedacted {
            showAlert("보안을 위해 주소의 일부가 저장되지 않아 재개할 수 없습니다. 주소를 다시 입력해 주세요.")
            return
        }
        resetAutoRecovery(jobId)
        jobs[index].generation += 1
        jobs[index].state = .queued
        jobs[index].stateMessage = "재시작 대기 중입니다 (새 작업 폴더에서 처음부터)."
        jobs[index].progressPercent = 0
        jobs[index].updatedAt = Date()
        persistJobs()
        processQueue()
    }

    public func cancelJob(jobId: String) {
        dependencyPlans[jobId] = nil
        guard let index = jobs.firstIndex(where: { $0.id == jobId }) else { return }

        if jobs[index].state == .publishing, let run = activeRuns[jobId], run.generation == jobs[index].generation,
           run.kind == .publish, let control = run.publishControl {
            switch control.requestCancel() {
            case .alreadyCommitted:
                showAlert("이미 저장이 확정되어 취소할 수 없습니다. 저장된 파일은 그대로 유지됩니다.")
            case .accepted:
                jobs[index].stateMessage = "저장을 취소하는 중입니다..."
                persistJobs()
            }
            return
        }

        if let run = activeRuns[jobId], run.generation == jobs[index].generation {
            run.userStopped = true
            run.handle?.cancel()
        }
        // Cancel beats a late helper acknowledgement: the waiting automatic retry is dropped here.
        autoRecoveryWaiting[jobId] = nil
        if jobs[index].runMode == .subtitlesOnly, jobs[index].publishedMediaPath != nil {
            jobs[index].state = .completedWithSubtitleFailure
            jobs[index].runMode = .full
            jobs[index].stateMessage = "자막 다시 받기를 취소했습니다. 영상은 이미 저장되어 있습니다."
        } else if jobs[index].isLive && jobs[index].pendingDownload {
            jobs[index].state = .cancelled
            jobs[index].stateMessage = "녹화를 취소했습니다. 녹화한 내용은 저장하지 않았습니다."
        } else {
            jobs[index].state = .cancelled
            jobs[index].stateMessage = "다운로드가 취소되었습니다."
        }
        jobs[index].pendingDownload = false
        jobs[index].updatedAt = Date()
        persistJobs()
    }

    public func retryJob(jobId: String) {
        guard activeRuns[jobId] == nil else { return }
        guard let index = jobs.firstIndex(where: { $0.id == jobId }) else { return }
        connectionRecoveries[jobId] = nil
        resetAutoRecovery(jobId)   // a user retry (also '허용 후 다시 시도') is a new logical attempt

        // A verified output still waiting in the work folder is re-published, not downloaded again.
        if jobs[index].pendingPublish, jobs[index].publishedMediaPath == nil || jobs[index].runMode == .subtitlesOnly,
           let media = jobs[index].manifest?.primaryMediaFile ?? jobs[index].manifest?.subtitleFiles.first?.path,
           let work = jobs[index].workDirectory,
           (try? Publisher.validateOwnedRegularFile(path: media, root: work)) != nil {
            jobs[index].state = .queued
            jobs[index].stateMessage = "저장을 다시 시도합니다."
            persistJobs()
            processQueue()
            return
        }

        if jobs[index].urlWasRedacted {
            showAlert("보안을 위해 주소의 일부가 저장되지 않아 다시 받을 수 없습니다. 주소를 새로 입력해 주세요.")
            return
        }
        requeueForRetry(index)
        persistJobs()
        processQueue()
    }

    /// Same job, new generation (new work folder): re-download the chosen formats, or re-analyse when the server's
    /// answer changed / nothing was chosen yet / it is live. Shared by user retries and automatic recovery.
    private func requeueForRetry(_ index: Int) {
        let wasSelection = jobs[index].state == .selectionChanged
        let embeddedHLS = jobs[index].extractor?.lowercased() == "generic"
            && jobs[index].mediaId?.hasPrefix("pageembed-") == true
        jobs[index].generation += 1
        jobs[index].state = .queued
        jobs[index].pendingPublish = false
        jobs[index].manifest = nil
        // Live: the stream moved on, so always re-analyse and let the user start a new recording.
        // Embedded streams need a fresh signed address and a plan bound to this helper session.
        if wasSelection || jobs[index].availableFormats.isEmpty || jobs[index].isLive || embeddedHLS {
            // The server's answer changed: re-extract and let the user confirm again.
            jobs[index].pendingDownload = false
            jobs[index].availableFormats = []
            jobs[index].availableSubtitles = []
            jobs[index].stateMessage = "다시 분석하기 위해 대기 중입니다."
            dependencyPlans[jobs[index].id] = nil
        } else {
            jobs[index].pendingDownload = true
            jobs[index].stateMessage = "재시도 대기열에 추가되었습니다."
        }
        jobs[index].progressPercent = 0
        jobs[index].updatedAt = Date()
    }

    /// Re-fetches only the chosen subtitle; the already published video is neither downloaded nor touched.
    public func retrySubtitleOnly(jobId: String) {
        guard activeRuns[jobId] == nil else { return }
        guard let index = jobs.firstIndex(where: { $0.id == jobId }),
              jobs[index].state == .completedWithSubtitleFailure,
              jobs[index].publishedMediaPath != nil else { return }
        if jobs[index].urlWasRedacted {
            showAlert("보안을 위해 주소의 일부가 저장되지 않아 자막을 다시 받을 수 없습니다. 주소를 새로 입력해 영상을 다시 받아야 합니다.")
            return
        }
        guard !jobs[index].selectedSubtitleIds.isEmpty else {
            showAlert("다시 받을 자막이 선택되어 있지 않습니다.")
            return
        }
        resetAutoRecovery(jobId)
        jobs[index].generation += 1
        jobs[index].runMode = .subtitlesOnly
        jobs[index].pendingDownload = true
        jobs[index].state = .queued
        jobs[index].stateMessage = "자막 다시 받기 대기 중..."
        jobs[index].updatedAt = Date()
        persistJobs()
        processQueue()
    }

    /// Settings button: re-check a process group that could not be confirmed gone.
    public func recheckEngineCleanup() {
        guard queueBlockedReason != nil else { return }
        guard !uncleanProcessGroups.isEmpty || hasUnresolvedUnknownCleanup else { return }

        var remaining: [pid_t: EngineTaskHandle] = [:]
        for (pgid, handle) in uncleanProcessGroups {
            guard pgid > 0 else {
                remaining[pgid] = handle
                continue
            }
            errno = 0
            let res = kill(-pgid, 0)
            let err = errno
            if res == 0 {
                remaining[pgid] = handle
            } else if err != ESRCH {
                remaining[pgid] = handle
            }
        }
        uncleanProcessGroups = remaining

        if !uncleanProcessGroups.isEmpty || hasUnresolvedUnknownCleanup {
            showAlert("엔진 하위 프로세스가 아직 남아 있습니다. 잠시 후 다시 확인해 주세요.")
            return
        }

        queueBlockedReason = priorNonCleanupBlocker
        priorNonCleanupBlocker = nil
        if queueBlockedReason == nil {
            processQueue()
        }
    }

    // MARK: - History Open / Finder / Delete

    private func existingRegularFile(_ path: String) -> URL? {
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        return URL(fileURLWithPath: path)
    }

    public func openInFinder(jobId: String) {
        guard let job = jobs.first(where: { $0.id == jobId }), let mediaPath = job.publishedMediaPath else {
            showAlert("저장된 파일 경로 정보를 찾을 수 없습니다.")
            return
        }
        guard let url = existingRegularFile(mediaPath) else {
            showAlert("파일이 존재하지 않거나 저장 볼륨이 분리되어 있습니다.")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    public func openFile(jobId: String) {
        guard let job = jobs.first(where: { $0.id == jobId }), let mediaPath = job.publishedMediaPath else {
            showAlert("저장된 파일 경로 정보를 찾을 수 없습니다.")
            return
        }
        guard let url = existingRegularFile(mediaPath) else {
            showAlert("파일이 존재하지 않거나 저장 볼륨이 분리되어 있습니다.")
            return
        }
        NSWorkspace.shared.open(url)
    }

    public func openJobInBrowser(jobId: String) {
        guard let job = jobs.first(where: { $0.id == jobId }) else { return }
        let target = job.browserPageReference ?? job.retryPageURL ?? (job.urlWasRedacted ? nil : job.sourceURL)
        if let target = target {
            openLoginWindow(url: target)
        } else {
            openLoginWindow(url: nil)
            showAlert("보안을 위해 주소의 일부가 저장되지 않아 브라우저에서 열 수 없습니다.")
        }
    }

    func hasActiveRun(jobId: String) -> Bool { activeRuns[jobId] != nil }

    public func deleteJob(jobId: String, removeFile: Bool, suppressAlert: Bool = false) {
        dependencyPlans[jobId] = nil
        guard let index = jobs.firstIndex(where: { $0.id == jobId }) else { return }
        let job = jobs[index]
        if let run = activeRuns[jobId] {
            if run.kind == .publish, run.publishControl?.requestCancel() == .alreadyCommitted {
                if !suppressAlert { showAlert("저장이 진행 중이라 지금은 삭제할 수 없습니다.") }
                return
            }
            run.userStopped = true
            run.handle?.cancel()
        }

        if removeFile {
            for path in [job.publishedMediaPath].compactMap({ $0 }) + job.publishedSubtitlePaths {
                if let url = existingRegularFile(path) {
                    try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
                }
            }
        }
        if activeRuns[jobId] == nil { removeWorkDirectory(for: job) }

        jobs.remove(at: index)
        JobThumbnailCache.remove(jobId: jobId, directory: thumbnailDirectory)
        connectionRecoveries[jobId] = nil
        resetAutoRecovery(jobId)
        if selectedJobId == jobId { selectedJobId = nil }
        persistJobs()
    }

    // MARK: - Persistence & Reconciliation

    private func persistJobs() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(jobs)
            try data.write(to: storeURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storeURL.path)
        } catch {
            NSLog("[HttpsDown] job store write failed")
        }
    }

    private func loadJobs() {
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return }
        guard let data = try? Data(contentsOf: storeURL),
              let loaded = try? JSONDecoder().decode([JobRecord].self, from: data) else {
            // Never overwrite an unreadable history with an empty one: keep it aside for recovery.
            let aside = storeURL.deletingLastPathComponent()
                .appendingPathComponent("jobs.unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: storeURL, to: aside)
            return
        }

        jobs = loaded.map { job in
            var j = job
            if let retry = j.retryPageURL,
               let validated = validateSafeRetryPageURL(retry, fromBrowser: j.fromBrowser, hasPageProvenance: true),
               isConsistentReference(retryURL: validated, sourceURL: j.sourceURL) {
                j.sourceURL = validated
                j.retryPageURL = validated
                j.urlWasRedacted = false
            } else if !j.fromBrowser, isKnownModelsPageRoute(j.sourceURL),
                      let route = validateSafeRetryPageURL(j.sourceURL, fromBrowser: false, hasPageProvenance: true),
                      isConsistentReference(retryURL: route, sourceURL: j.sourceURL) {
                // Known public page route stored without its (old, stripped) query: restore only the canonical address.
                j.retryPageURL = route
                if j.browserPageReference == nil { j.browserPageReference = route }
                j.urlWasRedacted = false
            } else if !j.fromBrowser, j.extractor?.lowercased() == "youtube", isYouTubeWatchSource(j.sourceURL),
                      let ref = canonicalYouTubeWatchURL(videoID: j.mediaId),
                      validateSafeRetryPageURL(ref, fromBrowser: false, hasPageProvenance: true) == ref,
                      isConsistentReference(retryURL: ref, sourceURL: j.sourceURL) {
                // Failed/old YouTube record whose watch query was stripped: rebuild only the canonical public address
                // from the known extractor + media id. Record state and files are untouched.
                j.sourceURL = ref
                j.retryPageURL = ref
                j.urlWasRedacted = false
            } else {
                j.retryPageURL = nil
                // The private address was never persisted; what we loaded cannot reproduce the original request.
                j.urlWasRedacted = j.urlWasRedacted || persistableURL(j.sourceURL).redacted
            }
            if let bRef = j.browserPageReference {
                j.browserPageReference = validateSafeRetryPageURL(bRef, fromBrowser: false, hasPageProvenance: true)
            }
            // The page context (Referer, browser session) of a browser-chosen video lived only in memory. It can be
            // restored only for a complete (never redacted) media address plus a validated canonical page reference;
            // everything else keeps the block. The source-redaction truth itself is left as it is.
            if j.fromBrowser && j.state != .completed && j.state != .completedWithSubtitleFailure {
                if !j.urlWasRedacted, let page = j.browserPageReference,
                   let pageURL = URL(string: page), let mediaURL = URL(string: j.sourceURL) {
                    if j.pageReferer == nil { j.pageReferer = MediaDiscovery.referer(page: pageURL, media: mediaURL) }
                } else {
                    j.urlWasRedacted = true
                }
            }

            if j.state == .publishing {
                reconcilePublishing(&j)
            } else if j.state.isActive {
                j.state = .interrupted
                j.stateMessage = "이전 실행 중 앱이 종료되어 안전하게 중단되었습니다."
            }
            return j
        }
        persistJobs()
    }

    /// An app/system crash during publish: decide from the write-ahead journal what actually reached the destination.
    private func reconcilePublishing(_ job: inout JobRecord) {
        let journal = job.workDirectory.map { URL(fileURLWithPath: $0).appendingPathComponent(".publish-journal.json") }
        let outcome = journal.map { Publisher.reconcile(journalURL: $0) } ?? .notCommitted
        switch outcome {
        case .committed(let media, let subs):
            if let media = media { job.publishedMediaPath = media }
            job.publishedSubtitlePaths = (job.runMode == .subtitlesOnly ? job.publishedSubtitlePaths : []) + subs
            job.pendingPublish = false
            job.pendingDownload = false
            job.progressPercent = 100
            let subtitleFailed = (job.manifest?.subtitlesFailed ?? false)
                || (job.manifest.map { $0.subtitleFiles.count > subs.count } ?? false)
            job.state = subtitleFailed ? .completedWithSubtitleFailure : .completed
            job.stateMessage = "저장 도중 앱이 종료되었지만 파일이 이미 저장된 것을 확인했습니다."
            job.runMode = .full
            removeWorkDirectory(for: job)
        case .notCommitted:
            job.state = .interrupted
            job.pendingPublish = job.manifest != nil
            job.stateMessage = "저장이 확정되기 전에 앱이 종료되었습니다. 받은 파일은 보존되어 있으며 '다시 시도'로 저장할 수 있습니다."
        }
    }

    private func updateJob(_ jobId: String, mutate: (inout JobRecord) -> Void) {
        if let idx = jobs.firstIndex(where: { $0.id == jobId }) {
            mutate(&jobs[idx])
        }
    }

    private func showAlert(_ message: String) {
        self.alertMessage = message
        self.showingAlert = true
    }
}
