public struct SAWTeamTaskProposal: Codable, Equatable {
    public let goal: String
    public let url: String?

    public init(goal: String, url: String? = nil) {
        self.goal = goal
        self.url = url
    }
}

import Foundation
import SwiftUI
import AppKit
import WebKit

// MARK: - Dedicated Result Enum

enum WebPageAgentResult<Value> {
    case success(Value)
    case failure(String)
}

// MARK: - Snapshot & Interactive Models

/// Represents a validated interactive element on the active page snapshot.
struct WebPageInteractiveElement: Identifiable, Codable, Equatable {
    var id: String { ref }
    let ref: String
    let role: String
    let name: String
    let state: String
    let type: String
    let value: String
    let isSubmitLike: Bool

    init(ref: String, role: String, name: String, state: String = "", type: String = "", value: String = "", isSubmitLike: Bool = false) {
        self.ref = ref
        self.role = role
        self.name = name
        self.state = state
        self.type = type
        self.value = value
        self.isSubmitLike = isSubmitLike
    }
}

/// Represents an in-memory extraction of the target page's rendered text and interactive element registry.
struct WebPagePostEvidence: Equatable {
    let shortcode: String
    let canonicalURL: String
    let author: String
    let publishedAt: String
    let caption: String
}

struct WebPageAgentSnapshot: Equatable {
    let documentToken: String
    let snapshotId: String
    let url: String
    let title: String
    let text: String
    let isTruncated: Bool
    let interactives: [WebPageInteractiveElement]
    let capturedAt: Date
    let postEvidence: WebPagePostEvidence?

    init(
        documentToken: String,
        snapshotId: String,
        url: String,
        title: String,
        text: String,
        isTruncated: Bool,
        interactives: [WebPageInteractiveElement],
        capturedAt: Date = Date(),
        postEvidence: WebPagePostEvidence? = nil
    ) {
        self.documentToken = documentToken
        self.snapshotId = snapshotId
        self.url = url
        self.title = title
        self.text = text
        self.isTruncated = isTruncated
        self.interactives = interactives
        self.capturedAt = capturedAt
        self.postEvidence = postEvidence
    }
}

// MARK: - Action Models

enum WebPageActionType: String, Codable, Equatable {
    case click
    case fill
    case select
    case scroll
    case navigate
    case read
    case done
    case needsUser
    case openTab
    case switchTab
    case closeTab
    case remember
    case saveDocument
    case runTool
}

struct WebPageAgentAction: Codable, Equatable {
    let action: WebPageActionType
    let ref: String?
    let text: String?
    let value: String?
    let direction: String?
    let amount: Double?
    let url: String?
    let reason: String?
    let result: String?
    let summary: String?
    let tabID: String?
    let note: String?
    let filename: String?
    let content: String?
    let format: String?
    let plan: [String]?
    let stepIndex: Int?
    let message: String?
    let teamTasks: [SAWTeamTaskProposal]?
    let searchQuery: String?
    let toolID: String?
    let toolArgumentsJSON: String?

    init(
        action: WebPageActionType,
        ref: String? = nil,
        text: String? = nil,
        value: String? = nil,
        direction: String? = nil,
        amount: Double? = nil,
        url: String? = nil,
        reason: String? = nil,
        result: String? = nil,
        summary: String? = nil,
        tabID: String? = nil,
        note: String? = nil,
        filename: String? = nil,
        content: String? = nil,
        format: String? = nil,
        plan: [String]? = nil,
        stepIndex: Int? = nil,
        message: String? = nil,
        teamTasks: [SAWTeamTaskProposal]? = nil,
        searchQuery: String? = nil,
        toolID: String? = nil,
        toolArgumentsJSON: String? = nil
    ) {
        self.action = action
        self.ref = ref
        self.text = text
        self.value = value
        self.direction = direction
        self.amount = amount
        self.url = url
        self.reason = reason
        self.result = result
        self.summary = summary
        self.tabID = tabID
        self.note = note
        self.filename = filename
        self.content = content
        self.format = format
        self.plan = plan
        self.stepIndex = stepIndex
        self.message = message
        self.teamTasks = teamTasks
        self.searchQuery = searchQuery
        self.toolID = toolID
        self.toolArgumentsJSON = toolArgumentsJSON
    }
}

// MARK: - Agent Mode & State

enum WebPageAgentMode: String, Equatable {
    case idle
    case reading
    case thinking
    case acting
    case needsUser
    case userControl
    case stopped
    case completed
    case error

    var localizedTitle: String {
        switch self {
        case .idle: return "대기 중"
        case .reading: return "웹 페이지 분석 중..."
        case .thinking: return "AI 작업 계획 수립 중..."
        case .acting: return "동작 수행 중"
        case .needsUser: return "사용자 확인 필요"
        case .userControl: return "직접 조작 중"
        case .stopped: return "작업 중단됨"
        case .completed: return "작업 완료"
        case .error: return "오류"
        }
    }
}

// MARK: - External Effect Gate Approval Model

struct WebPageAgentPendingApproval: Identifiable, Equatable {
    let id: UUID
    let action: WebPageAgentAction
    let targetElement: WebPageInteractiveElement?
    let documentToken: String
    let snapshotId: String
    let reason: String

    init(
        id: UUID = UUID(),
        action: WebPageAgentAction,
        targetElement: WebPageInteractiveElement?,
        documentToken: String,
        snapshotId: String,
        reason: String
    ) {
        self.id = id
        self.action = action
        self.targetElement = targetElement
        self.documentToken = documentToken
        self.snapshotId = snapshotId
        self.reason = reason
    }
}

// MARK: - Snapshot Capture & Action Dispatch Bridge

@MainActor
enum WebPageAgentBridge {
    private static var cachedRuntimeScript: String?

    static func loadRuntimeScript() -> String? {
        if let cached = cachedRuntimeScript { return cached }
        #if SWIFT_PACKAGE
        let url = Bundle.module.url(forResource: "htt-web-agent-runtime", withExtension: "js", subdirectory: "AIResources")
            ?? Bundle.module.url(forResource: "htt-web-agent-runtime", withExtension: "js")
        #else
        let url = Bundle.main.url(forResource: "htt-web-agent-runtime", withExtension: "js", subdirectory: "AIResources")
            ?? Bundle.main.url(forResource: "htt-web-agent-runtime", withExtension: "js")
        #endif
        guard let validURL = url, let str = try? String(contentsOf: validURL, encoding: .utf8) else {
            return nil
        }
        cachedRuntimeScript = str
        return str
    }

    /// Injects runtime script into isolated content world (.defaultClient) if not already loaded.
    static func ensureRuntimeLoaded(webView: WKWebView) async -> Bool {
        guard let script = loadRuntimeScript() else { return false }
        let checkScript = """
        (() => {
            if (typeof window.__HTT_WEB_AGENT_RUNTIME__ === 'undefined') {
                \(script)
            }
            return typeof window.__HTT_WEB_AGENT_RUNTIME__ !== 'undefined';
        })()
        """
        return await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(checkScript, in: nil, in: .defaultClient) { result in
                switch result {
                case .success(let val):
                    continuation.resume(returning: (val as? Bool) ?? false)
                case .failure:
                    continuation.resume(returning: false)
                }
            }
        }
    }

    /// Captures a fresh snapshot of the active tab's webView.
    static func captureSnapshot(webView: WKWebView) async -> WebPageAgentResult<WebPageAgentSnapshot> {
        let loaded = await ensureRuntimeLoaded(webView: webView)
        guard loaded else {
            return .failure("웹 페이지 분석 런타임을 준비하지 못했습니다.")
        }

        let captureScript = """
        (() => {
            if (!window.__HTT_WEB_AGENT_RUNTIME__ || !window.__HTT_WEB_AGENT_RUNTIME__.captureSnapshot) {
                return JSON.stringify({ success: false, error: 'NO_RUNTIME' });
            }
            return window.__HTT_WEB_AGENT_RUNTIME__.captureSnapshot({ maxChars: 16000, maxNodes: 8000, maxInteractives: 120 });
        })()
        """

        return await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(captureScript, in: nil, in: .defaultClient) { result in
                switch result {
                case .failure(let error):
                    continuation.resume(returning: .failure(error.localizedDescription))
                case .success(let rawValue):
                    guard let jsonString = rawValue as? String,
                          let data = jsonString.data(using: .utf8),
                          let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        continuation.resume(returning: .failure("스냅샷 파싱 실패"))
                        return
                    }

                    guard let success = dict["success"] as? Bool, success else {
                        let err = dict["error"] as? String ?? "페이지 스냅샷을 읽을 수 없습니다."
                        continuation.resume(returning: .failure(err))
                        return
                    }

                    let docToken = dict["documentToken"] as? String ?? ""
                    let snapshotId = dict["snapshotId"] as? String ?? ""
                    let url = dict["url"] as? String ?? ""
                    let title = dict["title"] as? String ?? ""
                    let text = dict["text"] as? String ?? ""
                    let isTruncated = dict["isTruncated"] as? Bool ?? false

                    var interactives: [WebPageInteractiveElement] = []
                    if let list = dict["interactives"] as? [[String: Any]] {
                        for item in list {
                            let ref = item["ref"] as? String ?? ""
                            let role = item["role"] as? String ?? ""
                            let name = item["name"] as? String ?? ""
                            let state = item["state"] as? String ?? ""
                            let type = item["type"] as? String ?? ""
                            let val = item["value"] as? String ?? ""
                            let isSubmit = item["isSubmitLike"] as? Bool ?? false
                            if !ref.isEmpty {
                                interactives.append(WebPageInteractiveElement(
                                    ref: ref,
                                    role: role,
                                    name: name,
                                    state: state,
                                    type: type,
                                    value: val,
                                    isSubmitLike: isSubmit
                                ))
                            }
                        }
                    }

                    var parsedPostEvidence: WebPagePostEvidence? = nil
                    if let peDict = dict["postEvidence"] as? [String: Any] {
                        let rawCode = (peDict["shortcode"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        let rawURL = (peDict["canonicalURL"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        let rawAuthor = (peDict["author"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        let rawDate = (peDict["publishedAt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        let rawCaption = (peDict["caption"] as? String) ?? ""

                        let boundedCode = String(rawCode.prefix(100))
                        let boundedURL = String(rawURL.prefix(2048))
                        let boundedAuthor = String(rawAuthor.prefix(100))
                        let boundedDate = String(rawDate.prefix(100))
                        let boundedCaption = String(rawCaption.prefix(8000))

                        if !boundedCode.isEmpty || !boundedURL.isEmpty || !boundedAuthor.isEmpty || !boundedDate.isEmpty || !boundedCaption.isEmpty {
                            parsedPostEvidence = WebPagePostEvidence(
                                shortcode: boundedCode,
                                canonicalURL: boundedURL,
                                author: boundedAuthor,
                                publishedAt: boundedDate,
                                caption: boundedCaption
                            )
                        }
                    }

                    let snap = WebPageAgentSnapshot(
                        documentToken: docToken,
                        snapshotId: snapshotId,
                        url: url,
                        title: title,
                        text: text,
                        isTruncated: isTruncated,
                        interactives: interactives,
                        postEvidence: parsedPostEvidence
                    )
                    continuation.resume(returning: .success(snap))
                }
            }
        }
    }

    /// Dispatches an action to the target webView.
    static func executeAction(
        webView: WKWebView,
        documentToken: String,
        snapshotId: String,
        action: WebPageAgentAction,
        isCurrent: @escaping () -> Bool = { false }
    ) async -> WebPageAgentResult<[String: Any]> {
        guard isCurrent() else {
            return .failure("작업 유효성이 상실되어 동작을 중단했습니다.")
        }

        let loaded = await ensureRuntimeLoaded(webView: webView)
        guard isCurrent() else {
            return .failure("작업 유효성이 상실되어 동작을 중단했습니다.")
        }
        guard loaded else {
            return .failure("웹 페이지 조작 런타임이 로드되지 않았습니다.")
        }

        var actionDict: [String: Any] = [
            "type": action.action.rawValue
        ]
        if let ref = action.ref { actionDict["ref"] = ref }
        if let text = action.text { actionDict["text"] = text }
        if let val = action.value { actionDict["value"] = val }
        if let dir = action.direction { actionDict["direction"] = dir }
        if let amt = action.amount { actionDict["amount"] = amt }
        if let url = action.url { actionDict["url"] = url }

        let payloadDict: [String: Any] = [
            "documentToken": documentToken,
            "snapshotId": snapshotId,
            "action": actionDict
        ]

        guard let payloadData = try? JSONSerialization.data(withJSONObject: payloadDict),
              let payloadJSON = String(data: payloadData, encoding: .utf8) else {
            return .failure("동작 데이터 인코딩에 실패했습니다.")
        }

        let execScript = """
        (() => {
            if (!window.__HTT_WEB_AGENT_RUNTIME__ || !window.__HTT_WEB_AGENT_RUNTIME__.executeAction) {
                return JSON.stringify({ success: false, error: 'NO_RUNTIME' });
            }
            return window.__HTT_WEB_AGENT_RUNTIME__.executeAction(\(payloadJSON));
        })()
        """

        guard isCurrent() else {
            return .failure("작업 유효성이 상실되어 동작을 중단했습니다.")
        }

        return await withCheckedContinuation { continuation in
            guard isCurrent() else {
                continuation.resume(returning: .failure("작업 유효성이 상실되어 동작을 중단했습니다."))
                return
            }
            webView.evaluateJavaScript(execScript, in: nil, in: .defaultClient) { result in
                switch result {
                case .failure(let err):
                    continuation.resume(returning: .failure(err.localizedDescription))
                case .success(let raw):
                    guard let jsonString = raw as? String,
                          let data = jsonString.data(using: .utf8),
                          let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        continuation.resume(returning: .failure("동작 수행 결과 파싱 실패"))
                        return
                    }
                    guard let success = dict["success"] as? Bool, success else {
                        let err = dict["details"] as? String ?? dict["error"] as? String ?? "동작 수행 실패"
                        continuation.resume(returning: .failure(err))
                        return
                    }
                    continuation.resume(returning: .success(dict))
                }
            }
        }
    }
}

// MARK: - Web Page Agent Coordinator

@MainActor
final class WebPageAgentCoordinator: ObservableObject {
    @Published var mode: WebPageAgentMode = .idle
    @Published var statusMessage: String = "대기 중"
    @Published var userGoal: String = ""
    @Published var currentStep: Int = 0
    @Published var maxSteps: Int = 20
    @Published var remainingTimeoutSeconds: Int = 119
    @Published var pendingApproval: WebPageAgentPendingApproval? = nil
    @Published var lastCompletedResult: String? = nil
    @Published var isWorkMode: Bool = false
    @Published var isSAWMode: Bool = false
    @Published var latestSnapshot: WebPageAgentSnapshot? = nil
    var onPerformTabAction: ((WebPageAgentAction) async -> Void)?

    private(set) var boundJobID: UUID?
    private(set) var boundTabID: UUID?
    private weak var boundWebView: WKWebView?
    private var boundURL: URL?
    private var boundDocumentToken: String?
    private var taskGeneration: Int = 0
    private var isIntentionalNavigating: Bool = false

    private var ongoingLoopTask: Task<Void, Never>? = nil
    private var localEventMonitor: Any? = nil

    let transport = WebPageAgentTransport()

    init() {}

    deinit {
        if let monitor = localEventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    var isBusy: Bool {
        mode == .reading || mode == .thinking || mode == .acting
    }

    func currentContextIsValid(
        tab: LoginBrowserModel,
        appModel: AppModel,
        generation: Int,
        allowingNavigationChange: Bool = false
    ) -> Bool {
        guard !Task.isCancelled else { return false }
        guard taskGeneration == generation else { return false }
        guard boundJobID != nil else { return false }
        guard let boundTabID = boundTabID, tab.tabID == boundTabID else { return false }
        guard appModel.browser.tabID == boundTabID else { return false }
        guard let boundWV = boundWebView, tab.webView === boundWV else { return false }
        if !allowingNavigationChange && !isIntentionalNavigating {
            guard tab.currentURL == boundURL else { return false }
        }
        return true
    }

    private func validateNavigationURL(_ urlString: String?) -> (Bool, URL?) {
        guard let urlString = urlString?.trimmingCharacters(in: .whitespacesAndNewlines),
              !urlString.isEmpty else { return (false, nil) }
        for scalar in urlString.unicodeScalars {
            if scalar.value < 32 || scalar.value == 127 {
                return (false, nil)
            }
        }
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host,
              !host.isEmpty,
              url.user == nil,
              url.password == nil else {
            return (false, nil)
        }
        return (true, url)
    }

    /// Syncs context when active tab or browser changes.
    func syncContext(tab: LoginBrowserModel) {
        guard boundJobID != nil else { return }
        let tabOrViewDiffers = (boundTabID != tab.tabID || boundWebView !== tab.webView)
        let urlChanges = (boundURL != tab.currentURL)
        if tabOrViewDiffers || urlChanges {
            takeoverManual()
            pendingApproval = nil
            statusMessage = tabOrViewDiffers ? "탭이 변경되어 작업이 일시 정지되었습니다." : "페이지 주소가 변경되어 직접 조작으로 전환되었습니다."
        }
    }

    /// Teardown when panel is closed or tab is closed.
    func teardown() {
        stop()
        teardownEventMonitor()
        boundJobID = nil
        boundTabID = nil
        boundWebView = nil
        boundURL = nil
        boundDocumentToken = nil
        latestSnapshot = nil
        pendingApproval = nil
        isWorkMode = false
    }

    /// Starts a new autonomous web page agent job.
    func start(tab: LoginBrowserModel, appModel: AppModel, goal: String) {
        let trimmedGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedGoal.isEmpty else {
            statusMessage = "수행할 작업 내용을 입력해 주세요."
            mode = .error
            return
        }

        guard !tab.isShowingHome, let webView = tab.webView, let url = tab.currentURL else {
            statusMessage = "현재 열려 있는 웹 페이지가 없습니다."
            mode = .error
            return
        }

        let scheme = url.scheme?.lowercased() ?? ""
        guard scheme == "http" || scheme == "https" else {
            statusMessage = "일반 웹 페이지(HTTP/HTTPS)에서만 작업할 수 있습니다."
            mode = .error
            return
        }

        let activeService = appModel.aiServices.selectedService
        guard WebPageAgentTransport.isSupportedProvider(activeService.id) else {
            statusMessage = "현재 선택된 AI(\(activeService.name))는 페이지 자동 작업을 지원하지 않습니다. ChatGPT를 선택해 주세요."
            mode = .error
            return
        }

        // Initialize state
        stop()
        taskGeneration += 1
        let currentGen = taskGeneration
        let newJobID = UUID()
        self.boundJobID = newJobID
        self.boundTabID = tab.tabID
        self.boundWebView = webView
        self.boundURL = url
        self.userGoal = trimmedGoal
        self.currentStep = 0
        self.pendingApproval = nil
        self.lastCompletedResult = nil
        self.mode = .reading
        self.statusMessage = "웹 페이지 분석 중..."

        // Ensure planner webview shares the target browser route's WKWebsiteDataStore
        let targetStore = tab.webView?.configuration.websiteDataStore ?? appModel.thirdPartyAIHost.webView.configuration.websiteDataStore
        transport.configurePlanner(service: activeService, dataStore: targetStore)

        // Setup local event monitor to give user priority
        setupEventMonitor(for: webView)

        // Launch agent loop
        ongoingLoopTask = Task { @MainActor [weak self, weak tab, weak appModel] in
            guard let self = self, let tab = tab, let appModel = appModel else { return }
            await self.runAgentLoop(tab: tab, appModel: appModel, generation: currentGen)
        }
    }

    /// Terminates the current agent job immediately.
    func stop() {
        taskGeneration += 1
        ongoingLoopTask?.cancel()
        ongoingLoopTask = nil
        teardownEventMonitor()
        transport.cancelActiveGeneration()
        pendingApproval = nil
        if isBusy || mode == .userControl || mode == .needsUser {
            mode = .stopped
            statusMessage = "작업이 중단되었습니다."
        }
    }

    /// Switches to user control (pauses AI loop and preserves goal and state).
    func takeoverManual() {
        guard mode != .userControl && mode != .stopped && mode != .completed else { return }
        taskGeneration += 1
        ongoingLoopTask?.cancel()
        ongoingLoopTask = nil
        transport.cancelActiveGeneration()
        pendingApproval = nil
        mode = .userControl
        statusMessage = "직접 조작 중입니다. 조작을 마치면 [다시 맡기기]를 눌러주세요."
    }

    /// Resumes the paused task from current page state.
    func resume(tab: LoginBrowserModel, appModel: AppModel) {
        guard mode == .userControl || mode == .needsUser || mode == .stopped else { return }
        guard !userGoal.isEmpty else { return }
        guard let boundTabID = boundTabID, let boundWV = boundWebView else {
            statusMessage = "바인딩된 작업 대상이 없습니다."
            mode = .error
            return
        }
        guard tab.tabID == boundTabID && tab.webView === boundWV else {
            statusMessage = "원래 작업하던 탭에서만 작업을 이어갈 수 있습니다."
            mode = .error
            return
        }
        guard !tab.isShowingHome, let webView = tab.webView, let url = tab.currentURL else {
            statusMessage = "현재 열린 페이지가 없습니다."
            mode = .error
            return
        }

        taskGeneration += 1
        let currentGen = taskGeneration
        self.boundURL = url
        self.pendingApproval = nil
        self.mode = .reading
        self.statusMessage = "현재 화면을 다시 관찰하여 작업을 이어갑니다..."

        setupEventMonitor(for: webView)

        ongoingLoopTask = Task { @MainActor [weak self, weak tab, weak appModel] in
            guard let self = self, let tab = tab, let appModel = appModel else { return }
            await self.runAgentLoop(tab: tab, appModel: appModel, generation: currentGen)
        }
    }

    /// Approves pending gate action and continues loop.
    func approvePendingGate(tab: LoginBrowserModel, appModel: AppModel) {
        guard mode == .needsUser else { return }
        guard let pending = pendingApproval else { return }
        guard let boundTabID = boundTabID, tab.tabID == boundTabID else {
            statusMessage = "대상 탭이 일치하지 않아 승인이 취소되었습니다."
            mode = .userControl
            pendingApproval = nil
            return
        }
        guard appModel.browser.tabID == boundTabID else {
            statusMessage = "활성 탭이 변경되어 승인이 취소되었습니다."
            mode = .userControl
            pendingApproval = nil
            return
        }
        guard let webView = tab.webView, webView === boundWebView else {
            statusMessage = "대상 페이지가 변경되어 승인이 취소되었습니다."
            mode = .userControl
            pendingApproval = nil
            return
        }
        guard tab.currentURL == boundURL else {
            statusMessage = "페이지 주소가 변경되어 승인이 취소되었습니다."
            mode = .userControl
            pendingApproval = nil
            return
        }
        guard let latestSnap = latestSnapshot,
              latestSnap.documentToken == pending.documentToken,
              latestSnap.snapshotId == pending.snapshotId else {
            statusMessage = "페이지 상태가 변경되어 이전 승인이 무효화되었습니다."
            mode = .userControl
            pendingApproval = nil
            return
        }
        if let targetEl = pending.targetElement {
            guard latestSnap.interactives.contains(where: { $0.ref == targetEl.ref }) else {
                statusMessage = "승인 대상 요소가 페이지에서 사라졌습니다."
                mode = .userControl
                pendingApproval = nil
                return
            }
        }

        taskGeneration += 1
        let currentGen = taskGeneration
        let action = pending.action
        let docToken = pending.documentToken
        let snapId = pending.snapshotId
        self.pendingApproval = nil

        let isCurrent: () -> Bool = { [weak self, weak tab, weak appModel] in
            guard let self = self, let tab = tab, let appModel = appModel else { return false }
            return self.currentContextIsValid(tab: tab, appModel: appModel, generation: currentGen)
        }

        if action.action == .navigate {
            let (isValid, validURL) = validateNavigationURL(action.url)
            guard isValid, let targetURL = validURL else {
                mode = .needsUser
                statusMessage = "유효하지 않은 주소입니다."
                return
            }

            guard isCurrent() else { return }
            mode = .acting
            statusMessage = "페이지 이동 중: \(targetURL.host ?? targetURL.absoluteString)"
            isIntentionalNavigating = true
            self.boundURL = targetURL
            tab.open(targetURL.absoluteString)

            ongoingLoopTask = Task { @MainActor [weak self, weak tab, weak appModel] in
                guard let self = self, let tab = tab, let appModel = appModel else { return }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                self.isIntentionalNavigating = false
                guard self.currentContextIsValid(tab: tab, appModel: appModel, generation: currentGen) else { return }
                await self.runAgentLoop(tab: tab, appModel: appModel, generation: currentGen)
            }
            return
        }

        self.mode = .acting
        self.statusMessage = "승인된 동작 수행 중..."

        ongoingLoopTask = Task { @MainActor [weak self, weak tab, weak appModel] in
            guard let self = self, let tab = tab, let appModel = appModel else { return }
            guard isCurrent() else { return }
            let execResult = await WebPageAgentBridge.executeAction(
                webView: webView,
                documentToken: docToken,
                snapshotId: snapId,
                action: action,
                isCurrent: isCurrent
            )

            guard isCurrent() else { return }

            switch execResult {
            case .failure(let err):
                self.mode = .needsUser
                self.statusMessage = "동작 실행 실패: \(err)"
            case .success:
                try? await Task.sleep(nanoseconds: 800_000_000)
                guard isCurrent() else { return }
                await self.runAgentLoop(tab: tab, appModel: appModel, generation: currentGen)
            }
        }
    }

    /// Rejects/cancels pending gate action.
    func cancelPendingGate() {
        pendingApproval = nil
        takeoverManual()
    }

    // MARK: - Core Execution Loop

    private func runAgentLoop(tab: LoginBrowserModel, appModel: AppModel, generation: Int) async {
        let isCurrent: () -> Bool = { [weak self, weak tab, weak appModel] in
            guard let self = self, let tab = tab, let appModel = appModel else { return false }
            return self.currentContextIsValid(tab: tab, appModel: appModel, generation: generation)
        }

        while isCurrent() {
            if currentStep >= maxSteps {
                if isSAWMode {
                    maxSteps = currentStep + 20
                } else {
                    mode = .needsUser
                    statusMessage = "최대 단계(\(maxSteps)회)에 도달하여 대기 중입니다. 직접 확인 후 다시 맡겨주세요."
                    break
                }
            }

            guard let webView = tab.webView else {
                mode = .error
                statusMessage = "브라우저 화면을 찾을 수 없습니다."
                break
            }

            currentStep += 1

            // 1. Snapshot Capture
            guard isCurrent() else { return }
            mode = .reading
            statusMessage = "페이지 구조 분석 중... (단계 \(currentStep)/\(maxSteps))"

            let snapResult = await WebPageAgentBridge.captureSnapshot(webView: webView)
            guard isCurrent() else { return }

            let snapshot: WebPageAgentSnapshot
            switch snapResult {
            case .failure(let err):
                mode = .needsUser
                statusMessage = "페이지를 읽지 못했습니다: \(err). 직접 조작 후 다시 맡겨주세요."
                return
            case .success(let snap):
                snapshot = snap
                self.latestSnapshot = snap
                self.boundDocumentToken = snap.documentToken
            }

            // 2. AI Model Planning via Transport
            guard isCurrent() else { return }
            mode = .thinking
            statusMessage = "AI 작업 계획 수립 중... (남은 시간: \(remainingTimeoutSeconds)초)"

            let activeService = appModel.aiServices.selectedService
            let actionResult = await transport.requestNextAction(
                service: activeService,
                snapshot: snapshot,
                userGoal: userGoal,
                currentStep: currentStep,
                maxSteps: maxSteps,
                isCurrent: isCurrent,
                onRemainingSecondsUpdate: { [weak self] sec in
                    self?.remainingTimeoutSeconds = sec
                    self?.statusMessage = "AI 작업 계획 수립 중... (남은 시간: \(sec)초)"
                }
            )

            guard isCurrent() else { return }

            let plannedAction: WebPageAgentAction
            switch actionResult {
            case .failure(let err):
                mode = .needsUser
                statusMessage = err
                return
            case .success(let action):
                plannedAction = action
            }

            // 3. Process Planned Action
            switch plannedAction.action {
            case .done:
                guard isCurrent() else { return }
                mode = .reading
                statusMessage = "작업 완료 상태 검증 중..."
                let confirmSnapResult = await WebPageAgentBridge.captureSnapshot(webView: webView)
                guard isCurrent() else { return }

                switch confirmSnapResult {
                case .failure:
                    mode = .needsUser
                    statusMessage = "완료 상태를 검증하지 못했습니다. 화면을 직접 확인해 주세요."
                    return
                case .success(let freshSnap):
                    let isDocSame = (freshSnap.documentToken == snapshot.documentToken)
                    let isTextSame = (freshSnap.text == snapshot.text)
                    let isInteractivesSame = (freshSnap.interactives == snapshot.interactives)

                    if !isDocSame || !isTextSame || !isInteractivesSame {
                        self.latestSnapshot = freshSnap
                        self.boundDocumentToken = freshSnap.documentToken
                        statusMessage = "화면 상태 변화 감지됨: 추가 작업 계획 수립 중..."
                        continue
                    }

                    mode = .completed
                    let resText = plannedAction.result ?? plannedAction.summary ?? "요청하신 작업을 성공적으로 완료했습니다."
                    statusMessage = "작업 완료: \(resText)"
                    lastCompletedResult = resText
                    return
                }

            case .needsUser:
                mode = .needsUser
                let reason = plannedAction.reason ?? "사용자의 직접 확인 또는 로그인이 필요합니다."
                statusMessage = "사용자 확인 필요: \(reason)"
                return

            case .navigate:
                let (isValid, validURL) = validateNavigationURL(plannedAction.url)
                guard isValid, let targetURL = validURL else {
                    mode = .needsUser
                    statusMessage = "유효하지 않은 웹 주소로의 이동 요청이 차단되었습니다: \(plannedAction.url ?? "")"
                    return
                }

                if isSAWMode {
                    guard isCurrent() else { return }
                    mode = .acting
                    statusMessage = "페이지 이동 중: \(targetURL.host ?? targetURL.absoluteString)"
                    isIntentionalNavigating = true
                    self.boundURL = targetURL
                    tab.open(targetURL.absoluteString)
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    self.isIntentionalNavigating = false
                    guard isCurrent() else { return }
                    continue
                }

                pendingApproval = WebPageAgentPendingApproval(
                    action: plannedAction,
                    targetElement: nil,
                    documentToken: snapshot.documentToken,
                    snapshotId: snapshot.snapshotId,
                    reason: plannedAction.reason ?? "웹 페이지 이동 승인이 필요합니다: \(targetURL.absoluteString)"
                )
                mode = .needsUser
                statusMessage = "페이지 이동 승인 대기: \(targetURL.host ?? targetURL.absoluteString)"
                return

            case .click:
                guard let ref = plannedAction.ref,
                      let targetEl = snapshot.interactives.first(where: { $0.ref == ref }) else {
                    mode = .needsUser
                    statusMessage = "지정한 요소를 찾을 수 없습니다 (\(plannedAction.ref ?? "")). 직접 조작 후 다시 맡겨주세요."
                    return
                }

                let role = targetEl.role.lowercased()
                let type = targetEl.type.lowercased()
                let isClearToggleOrOption = (role == "checkbox" || role == "radio" || type == "checkbox" || type == "radio" || role == "option") && !targetEl.isSubmitLike

                if !isSAWMode && !isClearToggleOrOption {
                    pendingApproval = WebPageAgentPendingApproval(
                        action: plannedAction,
                        targetElement: targetEl,
                        documentToken: snapshot.documentToken,
                        snapshotId: snapshot.snapshotId,
                        reason: plannedAction.reason ?? "동작 실행 전 사용자 확인이 필요합니다: [\(targetEl.name.isEmpty ? targetEl.role : targetEl.name)]"
                    )
                    mode = .needsUser
                    statusMessage = "동작 실행 승인 대기: [\(targetEl.name.isEmpty ? targetEl.role : targetEl.name)]"
                    return
                }

                guard isCurrent() else { return }
                mode = .acting
                statusMessage = "클릭 동작 수행 중: \(targetEl.name.isEmpty ? targetEl.role : targetEl.name)"
                let execResult = await WebPageAgentBridge.executeAction(
                    webView: webView,
                    documentToken: snapshot.documentToken,
                    snapshotId: snapshot.snapshotId,
                    action: plannedAction,
                    isCurrent: isCurrent
                )
                guard isCurrent() else { return }

                switch execResult {
                case .failure(let err):
                    mode = .needsUser
                    statusMessage = "클릭 실패: \(err)"
                    return
                case .success:
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    guard isCurrent() else { return }
                    continue
                }

            case .fill:
                guard let ref = plannedAction.ref,
                      let targetEl = snapshot.interactives.first(where: { $0.ref == ref }) else {
                    mode = .needsUser
                    statusMessage = "입력할 대상 필드를 찾지 못했습니다 (\(plannedAction.ref ?? ""))."
                    return
                }

                guard isCurrent() else { return }
                mode = .acting
                statusMessage = "텍스트 입력 중: \(targetEl.name.isEmpty ? targetEl.role : targetEl.name)"
                let execResult = await WebPageAgentBridge.executeAction(
                    webView: webView,
                    documentToken: snapshot.documentToken,
                    snapshotId: snapshot.snapshotId,
                    action: plannedAction,
                    isCurrent: isCurrent
                )
                guard isCurrent() else { return }

                switch execResult {
                case .failure(let err):
                    mode = .needsUser
                    statusMessage = "입력 실패: \(err)"
                    return
                case .success:
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    guard isCurrent() else { return }
                    continue
                }

            case .select:
                guard let ref = plannedAction.ref,
                      let targetEl = snapshot.interactives.first(where: { $0.ref == ref }) else {
                    mode = .needsUser
                    statusMessage = "선택할 옵션 필드를 찾지 못했습니다 (\(plannedAction.ref ?? ""))."
                    return
                }

                guard isCurrent() else { return }
                mode = .acting
                statusMessage = "옵션 선택 중: \(targetEl.name)"
                let execResult = await WebPageAgentBridge.executeAction(
                    webView: webView,
                    documentToken: snapshot.documentToken,
                    snapshotId: snapshot.snapshotId,
                    action: plannedAction,
                    isCurrent: isCurrent
                )
                guard isCurrent() else { return }

                switch execResult {
                case .failure(let err):
                    mode = .needsUser
                    statusMessage = "선택 실패: \(err)"
                    return
                case .success:
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    guard isCurrent() else { return }
                    continue
                }

            case .scroll:
                guard isCurrent() else { return }
                mode = .acting
                statusMessage = "페이지 스크롤 중"
                _ = await WebPageAgentBridge.executeAction(
                    webView: webView,
                    documentToken: snapshot.documentToken,
                    snapshotId: snapshot.snapshotId,
                    action: plannedAction,
                    isCurrent: isCurrent
                )
                guard isCurrent() else { return }
                try? await Task.sleep(nanoseconds: 600_000_000)
                guard isCurrent() else { return }
                continue

            case .read:
                guard isCurrent() else { return }
                mode = .reading
                statusMessage = "페이지 상태 재확인 중"
                try? await Task.sleep(nanoseconds: 800_000_000)
                guard isCurrent() else { return }
                continue

            case .openTab, .switchTab, .closeTab, .remember:
                if let handler = onPerformTabAction {
                    await handler(plannedAction)
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    guard isCurrent() else { return }
                    continue
                } else {
                    statusMessage = "탭 관리 동작 수행됨: \(plannedAction.action.rawValue)"
                    continue
                }

            case .saveDocument:
                // Legacy coordinator does not have filesystem save permission; only SAW project scope has native save
                mode = .needsUser
                statusMessage = "바탕화면 문서 저장은 AI플레너 프로젝트에서만 지원됩니다."
                return

            case .runTool:
                // Legacy coordinator has no host tool runtime; registered tools run only inside SAW projects
                mode = .needsUser
                statusMessage = "등록된 도구 실행은 AI플레너 프로젝트에서만 지원됩니다. 이 화면에서는 사용할 수 있는 도구가 없습니다."
                return
            }
        }
    }

    // MARK: - Local Native Event Monitor

    private func setupEventMonitor(for webView: WKWebView) {
        teardownEventMonitor()
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self, weak webView] event in
            guard let self = self, let webView = webView else { return event }
            guard let targetWindow = webView.window, let eventWindow = event.window, eventWindow === targetWindow else {
                return event
            }

            let isTargetEvent: Bool
            switch event.type {
            case .keyDown:
                isTargetEvent = (eventWindow.firstResponder as? NSView)?.isDescendant(of: webView) == true
            case .leftMouseDown, .rightMouseDown:
                let webViewRectInWindow = webView.convert(webView.bounds, to: nil)
                isTargetEvent = webViewRectInWindow.contains(event.locationInWindow)
            default:
                isTargetEvent = false
            }

            if isTargetEvent {
                if self.isBusy || self.mode == .needsUser || self.pendingApproval != nil {
                    self.takeoverManual()
                }
            }
            return event
        }
    }

    private func teardownEventMonitor() {
        if let monitor = localEventMonitor {
            NSEvent.removeMonitor(monitor)
            localEventMonitor = nil
        }
    }
}
