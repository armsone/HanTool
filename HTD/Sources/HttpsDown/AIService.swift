import Foundation
import SwiftUI
import AppKit
import WebKit

// MARK: - AI Service Model

/// Represents an AI chat service provider (curated official service or user-added custom service).
public struct AIService: Identifiable, Codable, Equatable {
    public var id: String
    public var name: String
    public var homeURL: String
    public var serviceDescription: String
    public var restrictions: String
    public var isCurated: Bool

    public init(id: String, name: String, homeURL: String, serviceDescription: String, restrictions: String, isCurated: Bool) {
        self.id = id
        self.name = name
        self.homeURL = homeURL
        self.serviceDescription = serviceDescription
        self.restrictions = restrictions
        self.isCurated = isCurated
    }

    public var isHana: Bool { id == "hana" }
}

// MARK: - Validation Error

public enum AIServiceValidationError: LocalizedError, Equatable {
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let message):
            return message
        }
    }
}

// MARK: - Curated Services Catalog

public enum CuratedAIServices {
    public static let hanaID = "hana"

    public static let all: [AIService] = [
        AIService(
            id: hanaID,
            name: "하나",
            homeURL: "https://hanstree.synology.me:5443/alfred",
            serviceDescription: "나스 전용 지능형 어시스턴트",
            restrictions: "",
            isCurated: true
        ),
        AIService(
            id: "chatgpt",
            name: "ChatGPT (OpenAI)",
            homeURL: "https://chatgpt.com/",
            serviceDescription: "OpenAI 대화형 인공지능 서비스",
            restrictions: "제공사 정책에 따름 (게스트/무료 대화 또는 공식 로그인) · 수동 웹 대화",
            isCurated: true
        ),
        AIService(
            id: "claude",
            name: "Claude",
            homeURL: "https://claude.ai/",
            serviceDescription: "Anthropic 대화형 인공지능 서비스",
            restrictions: "제공사 정책에 따름 (계정 로그인 또는 웹 대화 정책) · 수동 웹 대화",
            isCurated: true
        ),
        AIService(
            id: "gemini",
            name: "Gemini",
            homeURL: "https://gemini.google.com/",
            serviceDescription: "Google 대화형 인공지능 어시스턴트",
            restrictions: "제공사 정책에 따름 (Google 계정 또는 지원 웹 세션) · 수동 웹 대화",
            isCurated: true
        ),
        AIService(
            id: "grok",
            name: "Grok",
            homeURL: "https://grok.com/",
            serviceDescription: "xAI 대화형 인공지능 서비스",
            restrictions: "제공사 정책에 따름 (게스트/무료 또는 공식 계정) · 수동 웹 대화",
            isCurated: true
        ),
        AIService(
            id: "perplexity",
            name: "Perplexity",
            homeURL: "https://www.perplexity.ai/",
            serviceDescription: "실시간 웹 검색 기반 대화형 질의응답 서비스",
            restrictions: "제공사 정책에 따름 (비로그인 검색·대화 또는 공식 로그인) · 수동 웹 대화",
            isCurated: true
        ),
        AIService(
            id: "copilot",
            name: "Microsoft Copilot",
            homeURL: "https://copilot.microsoft.com/",
            serviceDescription: "Microsoft 대화형 AI 어시스턴트",
            restrictions: "제공사 정책에 따름 (무료 웹 대화 또는 Microsoft 계정) · 수동 웹 대화",
            isCurated: true
        ),
        AIService(
            id: "deepseek",
            name: "DeepSeek",
            homeURL: "https://chat.deepseek.com/",
            serviceDescription: "DeepSeek 대화형 인공지능 서비스",
            restrictions: "제공사 정책에 따름 (공식 웹 정책 및 계정 지원) · 수동 웹 대화",
            isCurated: true
        ),
        AIService(
            id: "mistral",
            name: "Mistral Le Chat",
            homeURL: "https://chat.mistral.ai/",
            serviceDescription: "Mistral AI 공식 대화형 챗 서비스",
            restrictions: "제공사 정책에 따름 (공식 웹 정책 및 계정 지원) · 수동 웹 대화",
            isCurated: true
        ),
        AIService(
            id: "qwen",
            name: "Qwen",
            homeURL: "https://chat.qwen.ai/",
            serviceDescription: "Alibaba Cloud 대화형 인공지능 서비스",
            restrictions: "제공사 정책에 따름 (공식 웹 정책 및 계정 지원) · 수동 웹 대화",
            isCurated: true
        ),
        AIService(
            id: "kimi",
            name: "Kimi",
            homeURL: "https://www.kimi.com/",
            serviceDescription: "Moonshot AI 대화형 인공지능 서비스",
            restrictions: "제공사 정책에 따름 (공식 웹 정책 및 계정 지원) · 수동 웹 대화",
            isCurated: true
        ),
        AIService(
            id: "meta",
            name: "Meta AI",
            homeURL: "https://www.meta.ai/",
            serviceDescription: "Meta 공식 대화형 인공지능 서비스",
            restrictions: "제공사 정책에 따름 (지역/계정별 무료 대화 또는 공식 로그인) · 수동 웹 대화",
            isCurated: true
        ),
        AIService(
            id: "poe",
            name: "Poe",
            homeURL: "https://poe.com/",
            serviceDescription: "Quora 멀티 모델 AI 대화 플랫폼",
            restrictions: "제공사 정책에 따름 (무료 체험 또는 공식 계정 로그인) · 수동 웹 대화",
            isCurated: true
        ),
        AIService(
            id: "huggingchat",
            name: "HuggingChat",
            homeURL: "https://huggingface.co/chat/",
            serviceDescription: "Hugging Face 오픈소스 모델 대화 서비스",
            restrictions: "제공사 정책에 따름 (게스트 대화 가능 또는 Hugging Face 계정) · 수동 웹 대화",
            isCurated: true
        )
    ]

    public static func defaultService() -> AIService {
        all.first { $0.id == hanaID } ?? all[0]
    }
}

// MARK: - AI Service Catalog Store

private struct AIServiceStorageData: Codable {
    var version: Int = 1
    var selectedServiceID: String = CuratedAIServices.hanaID
    var customServices: [AIService] = []
    var enabledServiceIDs: [String]? = nil

    init() {}
}

@MainActor
public final class AIServiceStore: ObservableObject {
    public static let maxCustomServices = 50
    public static let maxNameLength = 40
    public static let maxURLLength = 1000
    private static let selectedServiceStorageKey = "SelectedAIServiceID"

    @Published public private(set) var selectedServiceID: String = CuratedAIServices.hanaID
    @Published public private(set) var customServices: [AIService] = []
    @Published public private(set) var enabledServiceIDs: Set<String> = []

    private let storeURL: URL

    public init(storeDirectory: URL) {
        self.storeURL = storeDirectory.appendingPathComponent("ai-services.json")
        load()
    }

    public var curatedServices: [AIService] {
        CuratedAIServices.all
    }

    public var allServices: [AIService] {
        CuratedAIServices.all + customServices
    }

    public var enabledServices: [AIService] {
        allServices.filter { enabledServiceIDs.contains($0.id) }
    }

    public var selectedService: AIService {
        allServices.first { $0.id == selectedServiceID } ?? CuratedAIServices.defaultService()
    }

    public func isServiceEnabled(id: String) -> Bool {
        enabledServiceIDs.contains(id)
    }

    public func canDisableService(id: String) -> Bool {
        true
    }

    public func setServiceEnabled(id: String, enabled: Bool) {
        if enabled {
            guard allServices.contains(where: { $0.id == id }) else { return }
            enabledServiceIDs.insert(id)
            persist()
        } else {
            guard enabledServiceIDs.contains(id) else { return }
            enabledServiceIDs.remove(id)
            if selectedServiceID == id {
                if let next = allServices.first(where: { enabledServiceIDs.contains($0.id) }) {
                    selectedServiceID = next.id
                }
            }
            persist()
        }
    }

    public func selectService(id: String) {
        guard allServices.contains(where: { $0.id == id }) else { return }
        selectedServiceID = id
        persist()
    }

    public static func validateCustom(name: String, urlString: String, existing: [AIService], editingID: String? = nil) -> Result<(name: String, url: String), AIServiceValidationError> {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return .failure(.invalid("서비스 이름을 입력해 주세요.")) }
        guard trimmedName.count <= maxNameLength else { return .failure(.invalid("서비스 이름은 \(maxNameLength)자 이하이어야 합니다.")) }
        guard !trimmedName.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return .failure(.invalid("서비스 이름에 제어 문자를 포함할 수 없습니다."))
        }
        if trimmedName.contains("@") && trimmedName.contains(".") {
            return .failure(.invalid("계정이나 이메일 형식의 이름은 사용할 수 없습니다."))
        }

        let nameKey = trimmedName.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "ko_KR"))
        for other in existing where other.id != editingID {
            let otherKey = other.name.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "ko_KR"))
            if nameKey == otherKey {
                return .failure(.invalid("‘\(other.name)’ 이름의 서비스가 이미 등록되어 있습니다."))
            }
        }

        let trimmedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else { return .failure(.invalid("웹 주소(HTTPS)를 입력해 주세요.")) }
        guard trimmedURL.count <= maxURLLength else { return .failure(.invalid("주소가 너무 깁니다.")) }
        guard !trimmedURL.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return .failure(.invalid("주소에 잘못된 제어 문자가 포함되어 있습니다."))
        }

        guard let comps = URLComponents(string: trimmedURL),
              let scheme = comps.scheme?.lowercased(),
              scheme == "https" else {
            return .failure(.invalid("안전한 공식 웹 주소(https://로 시작)만 등록할 수 있습니다."))
        }
        guard comps.user == nil && comps.password == nil else {
            return .failure(.invalid("사용자 정보나 비밀번호가 포함된 주소는 등록할 수 없습니다."))
        }
        guard let host = comps.host, !host.isEmpty, !host.contains(" "), !host.contains("\t") else {
            return .failure(.invalid("유효한 호스트(도메인) 주소가 필요합니다."))
        }
        guard comps.url != nil else {
            return .failure(.invalid("올바른 URL 형식이 아닙니다."))
        }

        let lower = trimmedURL.lowercased()
        if lower.hasPrefix("javascript:") || lower.hasPrefix("data:") || lower.hasPrefix("file:") {
            return .failure(.invalid("지원하지 않는 스킴 형식입니다."))
        }

        return .success((name: trimmedName, url: comps.url?.absoluteString ?? trimmedURL))
    }

    public func addCustomService(name: String, urlString: String, description: String = "") -> String? {
        guard customServices.count < Self.maxCustomServices else {
            return "사용자 지정 서비스는 최대 \(Self.maxCustomServices)개까지 등록할 수 있습니다."
        }
        switch Self.validateCustom(name: name, urlString: urlString, existing: allServices) {
        case .failure(let err):
            return err.errorDescription ?? err.localizedDescription
        case .success(let val):
            let desc = description.trimmingCharacters(in: .whitespacesAndNewlines)
            let newService = AIService(
                id: "custom-\(UUID().uuidString)",
                name: val.name,
                homeURL: val.url,
                serviceDescription: desc.isEmpty ? "사용자 등록 웹 AI 서비스" : desc,
                restrictions: "공식 웹 로그인 필요 · 수동 웹 대화",
                isCurated: false
            )
            customServices.append(newService)
            persist()
            return nil
        }
    }

    public func removeCustomService(id: String) {
        guard let index = customServices.firstIndex(where: { $0.id == id }) else { return }
        customServices.remove(at: index)
        enabledServiceIDs.remove(id)
        if selectedServiceID == id {
            selectedServiceID = allServices.first(where: { enabledServiceIDs.contains($0.id) })?.id ?? CuratedAIServices.hanaID
        }
        persist()
    }

    private func persist() {
        var data = AIServiceStorageData()
        data.selectedServiceID = selectedServiceID
        data.customServices = customServices
        data.enabledServiceIDs = Array(enabledServiceIDs)

        if let encoded = try? JSONEncoder().encode(data) {
            try? encoded.write(to: storeURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storeURL.path)
        }
        UserDefaults.standard.set(selectedServiceID, forKey: Self.selectedServiceStorageKey)
    }

    private func load() {
        if let savedID = UserDefaults.standard.string(forKey: Self.selectedServiceStorageKey), !savedID.isEmpty {
            self.selectedServiceID = savedID
        }
        guard FileManager.default.fileExists(atPath: storeURL.path),
              let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode(AIServiceStorageData.self, from: data) else {
            return
        }
        var valid: [AIService] = []
        for s in decoded.customServices.prefix(Self.maxCustomServices) {
            if case .success(let val) = Self.validateCustom(name: s.name, urlString: s.homeURL, existing: CuratedAIServices.all + valid, editingID: s.id) {
                valid.append(AIService(
                    id: s.id,
                    name: val.name,
                    homeURL: val.url,
                    serviceDescription: s.serviceDescription,
                    restrictions: "공식 웹 로그인 필요 · 수동 웹 대화",
                    isCurated: false
                ))
            }
        }
        self.customServices = valid
        if allServices.contains(where: { $0.id == decoded.selectedServiceID }) {
            self.selectedServiceID = decoded.selectedServiceID
        } else if !allServices.contains(where: { $0.id == self.selectedServiceID }) {
            self.selectedServiceID = CuratedAIServices.hanaID
        }
        if let savedIDs = decoded.enabledServiceIDs {
            let validIDs = Set(allServices.map { $0.id })
            self.enabledServiceIDs = Set(savedIDs).intersection(validIDs)
        } else {
            self.enabledServiceIDs = []
        }
    }
}

// MARK: - Unprivileged Third-Party AI Panel Host

/// Manages an unprivileged, isolated WKWebView for ordinary third-party AI chat providers.
/// Uses WKWebsiteDataStore.default() for login consistency and persistent session storage.
/// Supports real child WKWebView popups for OAuth authentication without automation injection.
@MainActor
public final class ThirdPartyAIPanelHost: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    public static let defaultWidth: CGFloat = 420
    public static let minWidth: CGFloat = 320
    public static let maxWidth: CGFloat = 900
    public static let storageKey = "HanaPanelWidth"

    @Published public var preferredWidth: CGFloat
    @Published public var isLoading: Bool = false
    @Published public var statusMessage: String? = nil
    @Published public var currentService: AIService? = nil
    @Published public var isPanelOpen: Bool = false

    public private(set) var webView: WKWebView
    public var onOpenExternalURL: ((URL) -> Void)?

    private var openPopups: [NSWindow] = []
    private var currentDataStore: WKWebsiteDataStore

    /// Common assistant planner session of this panel (one per host). Configured with the exact current service,
    /// website data store and web view; every service/store/web view change reconfigures it before the next load.
    private(set) var plannerSession: AssistantWebSession?
    private var plannerConfigKey: String?

    public init(dataStore: WKWebsiteDataStore = .default()) {
        let saved = UserDefaults.standard.double(forKey: Self.storageKey)
        if saved >= Double(Self.minWidth) && saved <= Double(Self.maxWidth) {
            self.preferredWidth = CGFloat(saved)
        } else {
            self.preferredWidth = Self.defaultWidth
        }

        self.currentDataStore = dataStore
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        config.applicationNameForUserAgent = "Version/\(major >= 26 ? major : major + 3).0 Safari/605.1.15"

        PageAudioController.shared.prepareConfiguration(config)
        self.webView = WKWebView(frame: .zero, configuration: config)
        super.init()

        self.webView.navigationDelegate = self
        self.webView.uiDelegate = self
        PageAudioController.shared.register(webView: self.webView, kind: .aiServicePanel(self))
    }

    /// Rebinds the panel host to a different WKWebsiteDataStore if changed (e.g. browser tab route store),
    /// invalidating existing tasks and recreating the webView cleanly.
    public func rebindStoreIfNeeded(_ store: WKWebsiteDataStore) {
        guard currentDataStore !== store else { return }
        teardown()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil

        self.currentDataStore = store
        let config = WKWebViewConfiguration()
        config.websiteDataStore = store
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        config.applicationNameForUserAgent = "Version/\(major >= 26 ? major : major + 3).0 Safari/605.1.15"

        PageAudioController.shared.prepareConfiguration(config)
        let newWV = WKWebView(frame: .zero, configuration: config)
        newWV.navigationDelegate = self
        newWV.uiDelegate = self
        self.webView = newWV
        PageAudioController.shared.register(webView: newWV, kind: .aiServicePanel(self))
        configurePlanner()   // the new configuration gets its script and handler before the first navigation

        if let service = currentService {
            guard let url = URL(string: service.homeURL) else { return }
            newWV.load(URLRequest(url: url))
        }
    }

    public func setPreferredWidth(_ width: CGFloat) {
        let clamped = min(max(Self.minWidth, width), Self.maxWidth)
        self.preferredWidth = clamped
        UserDefaults.standard.set(Double(clamped), forKey: Self.storageKey)
    }

    public func effectiveWidth(forAvailableWidth available: CGFloat) -> CGFloat {
        let budget = available - 16
        if budget <= Self.minWidth {
            return max(budget, 1)
        }
        let maxAllowed = max(Self.minWidth, budget - 100)
        let upper = min(Self.maxWidth, maxAllowed)
        return min(max(Self.minWidth, preferredWidth), upper)
    }

    public func load(service: AIService) {
        if currentService?.id == service.id && webView.url != nil {
            return
        }
        self.currentService = service
        self.statusMessage = nil
        configurePlanner()   // a service change retires the previous service's session state first
        guard let url = URL(string: service.homeURL) else { return }
        webView.load(URLRequest(url: url))
    }

    /// Creates this panel's common planner session once. The caller owns the coordinator and the handoff callbacks.
    @discardableResult
    func attachPlanner(coordinator: AssistantPlannerCoordinator) -> AssistantWebSession {
        if let plannerSession { return plannerSession }
        let session = AssistantWebSession(hostID: "third-party-panel", coordinator: coordinator)
        plannerSession = session
        configurePlanner()
        return session
    }

    /// Profile of the current website data store: its persistent identifier, or "default" for the shared default
    /// store. A non-persistent store has no stable account scope, so the planner stays off for it.
    private var plannerProfileID: String? {
        guard currentDataStore.isPersistent else { return nil }
        return currentDataStore.identifier?.uuidString ?? "default"
    }

    private func configurePlanner() {
        guard let session = plannerSession else { return }
        guard let service = currentService, let profile = plannerProfileID else {
            if plannerConfigKey != nil { session.detach() }
            plannerConfigKey = nil
            return
        }
        let key = [service.id, service.homeURL, profile, String(describing: ObjectIdentifier(webView))].joined(separator: "|")
        guard key != plannerConfigKey else { return }
        plannerConfigKey = session.configure(serviceID: service.id, profileID: profile,
                                             homeURL: service.homeURL, webView: webView) ? key : nil
    }

    public func reload() {
        self.statusMessage = nil
        if let currentURL = webView.url {
            webView.load(URLRequest(url: currentURL))
        } else if let s = currentService, let url = URL(string: s.homeURL) {
            webView.load(URLRequest(url: url))
        }
    }

    public func isFocused(in targetWindow: NSWindow?) -> Bool {
        guard isPanelOpen else { return false }
        guard let window = targetWindow ?? webView.window else { return false }
        guard window.attachedSheet == nil else { return false }
        guard let responder = window.firstResponder else { return false }
        if responder === webView { return true }
        if let responderView = responder as? NSView {
            return responderView.isDescendant(of: webView)
        }
        return false
    }

    public func teardown() {
        for window in openPopups {
            window.close()
        }
        openPopups.removeAll()
    }

    // MARK: - Host & Security Helpers

    private static let allowedAuthHosts: Set<String> = [
        "accounts.google.com",
        "appleid.apple.com",
        "login.microsoftonline.com",
        "login.live.com",
        "auth0.openai.com",
        "auth.anthropic.com",
        "auth.meta.com",
        "www.facebook.com",
        "facebook.com"
    ]

    private static func isAllowedAuthHost(_ host: String) -> Bool {
        if allowedAuthHosts.contains(host) { return true }
        if host.hasSuffix(".login.microsoftonline.com") { return true }
        return false
    }

    private static func isRelatedServiceHost(_ host: String, serviceHost: String) -> Bool {
        if host == serviceHost { return true }
        if host.hasSuffix("." + serviceHost) { return true }
        let baseService = serviceHost.hasPrefix("www.") ? String(serviceHost.dropFirst(4)) : serviceHost
        let baseHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        if baseHost == baseService || baseHost.hasSuffix("." + baseService) {
            return true
        }
        return false
    }

    // MARK: - WKNavigationDelegate

    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }

        let scheme = url.scheme?.lowercased() ?? ""
        if scheme != "https" {
            if url.absoluteString == "about:blank" {
                decisionHandler(.allow)
                return
            }
            decisionHandler(.cancel)
            return
        }

        if navigationAction.navigationType == .linkActivated {
            if let host = url.host?.lowercased(),
               let curHost = self.currentService.flatMap({ URL(string: $0.homeURL)?.host?.lowercased() }) {
                if !Self.isRelatedServiceHost(host, serviceHost: curHost) && !Self.isAllowedAuthHost(host) {
                    decisionHandler(.cancel)
                    onOpenExternalURL?(url)
                    return
                }
            }
        }
        decisionHandler(.allow)
    }

    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        self.isLoading = true
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        self.isLoading = false
        if webView !== self.webView {
            for window in openPopups where window.contentView === webView {
                if let t = webView.title, !t.isEmpty {
                    window.title = t
                } else if let h = webView.url?.host, !h.isEmpty {
                    window.title = h
                }
                break
            }
        }
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        self.isLoading = false
        handleNavigationError(error)
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.isLoading = false
        handleNavigationError(error)
    }

    private func handleNavigationError(_ error: Error) {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            return
        }
        if nsError.domain == "WebKitErrorDomain" && nsError.code == 102 {
            return
        }
        self.statusMessage = "페이지를 불러오지 못했습니다. 네트워크 상태를 확인해 주세요."
    }

    // MARK: - WKUIDelegate (OAuth & Visible Popups)

    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard openPopups.count < 4 else { return nil }
        PageAudioController.shared.prepareConfiguration(configuration)
        let child = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 680), configuration: configuration)
        child.navigationDelegate = self
        child.uiDelegate = self

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 680),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        let initialHost = navigationAction.request.url?.host ?? ""
        window.title = initialHost.isEmpty ? "로그인 / 연결" : initialHost
        window.contentView = child
        window.isReleasedWhenClosed = false

        openPopups.append(window)

        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self, weak window] _ in
            guard let self = self, let window = window else { return }
            Task { @MainActor [weak self, weak window] in
                guard let self = self, let window = window else { return }
                self.openPopups.removeAll { $0 === window }
            }
        }

        window.center()
        window.makeKeyAndOrderFront(nil)
        PageAudioController.shared.register(webView: child, kind: .popup(window: window, title: window.title))
        return child
    }

    public func webViewDidClose(_ webView: WKWebView) {
        for window in openPopups where window.contentView === webView {
            window.close()
            openPopups.removeAll { $0 === window }
            break
        }
    }
}

// MARK: - Third-Party AI Views

public struct ThirdPartyAIWebViewRepresentable: NSViewRepresentable {
    public let webView: WKWebView
    public var nativeInputAllowed: () -> Bool

    public init(webView: WKWebView, nativeInputAllowed: @escaping () -> Bool = { true }) {
        self.webView = webView
        self.nativeInputAllowed = nativeInputAllowed
    }

    public func makeNSView(context: Context) -> NSView {
        let container = LoginWebViewRepresentable.Container()
        container.nativeInputAllowed = nativeInputAllowed
        container.attach(webView)
        return container
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        if let container = nsView as? LoginWebViewRepresentable.Container {
            container.nativeInputAllowed = nativeInputAllowed
            container.attach(webView)
        }
    }

    public func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 320, height: 240))
    }
}

public struct AIPanelDivider: View {
    @Binding var preferredWidth: CGFloat
    let availableWidth: CGFloat
    @Environment(\.bkPalette) private var palette
    @State private var dragStartWidth: CGFloat? = nil
    @State private var isHovering: Bool = false
    @State private var hasPushedCursor: Bool = false

    public init(preferredWidth: Binding<CGFloat>, availableWidth: CGFloat) {
        self._preferredWidth = preferredWidth
        self.availableWidth = availableWidth
    }

    public var body: some View {
        PlannerNativeResizeDivider(
            onBegan: {
                dragStartWidth = preferredWidth
            },
            onChanged: { delta in
                let start = dragStartWidth ?? preferredWidth
                let newWidth = start - delta
                let clamped = min(max(ThirdPartyAIPanelHost.minWidth, newWidth), ThirdPartyAIPanelHost.maxWidth)
                preferredWidth = clamped
                UserDefaults.standard.set(Double(clamped), forKey: ThirdPartyAIPanelHost.storageKey)
            },
            onEnded: { delta in
                let start = dragStartWidth ?? preferredWidth
                let newWidth = start - delta
                let clamped = min(max(ThirdPartyAIPanelHost.minWidth, newWidth), ThirdPartyAIPanelHost.maxWidth)
                preferredWidth = clamped
                UserDefaults.standard.set(Double(clamped), forKey: ThirdPartyAIPanelHost.storageKey)
                dragStartWidth = nil
            }
        )
        .frame(width: 16)
        .frame(maxHeight: .infinity)
        .accessibilityElement()
        .accessibilityLabel("비서 대화창 너비 조절 핸들")
        .accessibilityValue("\(Int(preferredWidth))픽셀")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                let next = min(preferredWidth + 20, ThirdPartyAIPanelHost.maxWidth)
                preferredWidth = next
                UserDefaults.standard.set(Double(next), forKey: ThirdPartyAIPanelHost.storageKey)
            case .decrement:
                let next = max(preferredWidth - 20, ThirdPartyAIPanelHost.minWidth)
                preferredWidth = next
                UserDefaults.standard.set(Double(next), forKey: ThirdPartyAIPanelHost.storageKey)
            @unknown default:
                break
            }
        }
    }
}

public struct ThirdPartyAIPanelView: View {
    @ObservedObject var host: ThirdPartyAIPanelHost
    let service: AIService
    let availableWidth: CGFloat
    let onClose: () -> Void
    var nativeInputAllowed: () -> Bool = { true }
    @Environment(\.bkPalette) private var palette

    public init(host: ThirdPartyAIPanelHost, service: AIService, availableWidth: CGFloat, onClose: @escaping () -> Void, nativeInputAllowed: @escaping () -> Bool = { true }) {
        self.host = host
        self.service = service
        self.availableWidth = availableWidth
        self.onClose = onClose
        self.nativeInputAllowed = nativeInputAllowed
    }

    private var displayedWidth: CGFloat {
        host.effectiveWidth(forAvailableWidth: availableWidth)
    }

    public var body: some View {
        HStack(spacing: 0) {
            AIPanelDivider(preferredWidth: $host.preferredWidth, availableWidth: availableWidth)

            VStack(spacing: 0) {
                headerBar
                Divider()
                if let msg = host.statusMessage {
                    statusBanner(msg)
                }
                ThirdPartyAIWebViewRepresentable(webView: host.webView, nativeInputAllowed: nativeInputAllowed)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: displayedWidth)
            .background(palette.cardColor)
        }
        .onAppear {
            host.load(service: service)
        }
        .onChange(of: service.id) { _, _ in
            host.load(service: service)
        }
    }

    private var headerBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundColor(palette.accentColor)
                .font(.caption)
            Text(service.name)
                .font(.subheadline.bold())
                .foregroundColor(palette.textColor)
                .lineLimit(1)
            Text("수동 웹 대화")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(palette.textColor.opacity(0.8))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(palette.surface2Color))

            Spacer()

            if host.isLoading {
                ProgressView().controlSize(.small)
            }

            Button(action: { host.reload() }) {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .help("새로 고침")
            .accessibilityLabel("대화창 새로 고침")

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .help("대화창 닫기")
            .accessibilityLabel("대화창 닫기")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(palette.cardColor)
    }

    private func statusBanner(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .font(.caption2)
                .foregroundColor(palette.textColor)
            Text(text)
                .font(.caption2)
                .foregroundColor(palette.textColor)
                .lineLimit(2)
            Spacer()
            Button("다시 시도") {
                host.reload()
            }
            .font(.caption2.bold())
            .buttonStyle(.plain)
            .foregroundColor(palette.accentColor)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(palette.accentSoftColor)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}
