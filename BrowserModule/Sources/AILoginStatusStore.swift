import Foundation
import SwiftUI
import AppKit
import WebKit

/// Honest login status of an AI service (observed directly, never cached across app restarts).
public enum AILoginStatus: Equatable {
    case checking
    case loggedIn
    case connected
    case notLoggedIn
    case unknown

    public var label: String {
        switch self {
        case .checking: return "확인 중"
        case .loggedIn: return "로그인됨"
        case .connected: return "연결됨"
        case .notLoggedIn: return "로그인 안 됨"
        case .unknown: return "확인 안 됨"
        }
    }
}

/// Manages honest login status detection using the exact WKWebsiteDataStore configured for the AI service.
/// Follows AIBI probe rules:
/// - Real 800x680 viewport mounted in view hierarchy behind opaque surface (never 0x0 / unattached)
/// - Exact-origin scripts only, no scripts on auth / OAuth pages
/// - Positive account markers for ChatGPT/Claude/Gemini from AIBI registry
/// - Explicit logout / account sign-in evidence only; never infer authenticated from cookies, URL, composer, page load
/// - Bounded 12-20s timeout resolving to unknown
/// - No auto-probing disabled services on startup
/// - No durable cached login state across launches
@MainActor
public final class AILoginStatusStore: ObservableObject {
    public static let shared = AILoginStatusStore()

    @Published public private(set) var statuses: [String: AILoginStatus] = [:]

    private var activeProbes: [String: AILoginProbeSession] = [:]
    private var openLoginWindows: [String: NSWindow] = [:]

    private init() {}

    public func status(for serviceID: String) -> AILoginStatus {
        statuses[serviceID] ?? .unknown
    }

    public func setStatus(_ status: AILoginStatus, for serviceID: String) {
        statuses[serviceID] = status
    }

    /// Explicitly check login status for a service row.
    public func checkStatus(for service: AIService, store: WKWebsiteDataStore) {
        // Cancel any existing probe for this service
        activeProbes[service.id]?.cancel()
        activeProbes.removeValue(forKey: service.id)

        if service.isHana {
            let host = HanaPanelHost.shared
            let isConnected = host.isBridgeReady && HanaPanelHost.isTrustedAlfredURL(host.webView.url)
            statuses[service.id] = isConnected ? .connected : .unknown
            return
        }

        statuses[service.id] = .checking

        let session = AILoginProbeSession(service: service, store: store) { [weak self] result in
            guard let self = self else { return }
            self.activeProbes.removeValue(forKey: service.id)
            self.statuses[service.id] = result
        }
        activeProbes[service.id] = session
        session.start()
    }

    /// Opens dedicated login window for the service using the EXACT specified store and supplied OAuth child windows.
    public func openLoginWindow(for service: AIService, store: WKWebsiteDataStore, onAuthSuccess: (() -> Void)? = nil) {
        if let existing = openLoginWindows[service.id] {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let config = WKWebViewConfiguration()
        config.websiteDataStore = store
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        config.applicationNameForUserAgent = "Version/\(major >= 26 ? major : major + 3).0 Safari/605.1.15"

        PageAudioController.shared.prepareConfiguration(config)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 680), configuration: config)
        let coordinator = AILoginWindowCoordinator(service: service, store: store, webView: webView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 680),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "\(service.name) 로그인"
        window.contentView = webView
        window.isReleasedWhenClosed = false
        window.center()

        coordinator.window = window
        coordinator.onSuccess = { [weak self, weak window] in
            self?.statuses[service.id] = .loggedIn
            onAuthSuccess?()
            window?.close()
        }

        openLoginWindows[service.id] = window
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            self?.openLoginWindows.removeValue(forKey: service.id)
            let wasSuccess = coordinator.hasSucceeded
            coordinator.teardown()
            // Only probe on manual/unsuccessful close if attached surface is available and did not already succeed
            if !wasSuccess, AILoginProbeHiddenSurface.shared.availableHost() != nil {
                self?.checkStatus(for: service, store: store)
            }
        }

        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator

        guard let url = URL(string: service.homeURL) else { return }
        webView.load(URLRequest(url: url))
        window.makeKeyAndOrderFront(nil)
        PageAudioController.shared.register(webView: webView, kind: .aiLoginWindow(window: window, serviceName: service.name))
    }

    /// Notify that visible browsing/panel observed navigation on this service origin
    public func notifyServiceNavigation(service: AIService, currentURL: URL?) {
        guard let url = currentURL, let host = url.host?.lowercased() else { return }
        guard let serviceHost = URL(string: service.homeURL)?.host?.lowercased(),
              host == serviceHost || host.hasSuffix("." + serviceHost) else { return }
        // Leave to explicit or finished nav check
    }
}

// MARK: - Attached Probe Surface (Real 800x680 Viewport behind Opaque View)

private final class AIProbeHiddenWebView: WKWebView {
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class AILoginProbeHiddenSurface {
    static let shared = AILoginProbeHiddenSurface()
    static let probeViewport = NSSize(width: 800, height: 680)

    private final class WeakHost {
        weak var view: NSView?
        init(_ view: NSView) { self.view = view }
    }
    private var hosts: [WeakHost] = []

    func register(_ view: NSView) {
        hosts.removeAll { $0.view == nil || $0.view === view }
        hosts.append(WeakHost(view))
    }

    func availableHost() -> NSView? {
        hosts.reversed().compactMap(\.view).first { v in
            guard let w = v.window else { return false }
            return w.isVisible && !w.isMiniaturized
        }
    }
}

public struct AILoginProbeSurfaceView: NSViewRepresentable {
    public init() {}

    public func makeNSView(context: Context) -> NSView {
        let container = NSView(frame: NSRect(origin: .zero, size: AILoginProbeHiddenSurface.probeViewport))
        container.wantsLayer = true
        container.layer?.masksToBounds = true
        container.setAccessibilityElement(false)

        let cover = NSView(frame: container.bounds)
        cover.wantsLayer = true
        cover.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        cover.autoresizingMask = [.width, .height]
        container.addSubview(cover)

        AILoginProbeHiddenSurface.shared.register(container)
        return container
    }

    public func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Bounded Probe Session

final class AILoginProbeSession: NSObject, WKNavigationDelegate {
    private let service: AIService
    private let store: WKWebsiteDataStore
    private let completion: (AILoginStatus) -> Void
    private var webView: WKWebView?
    private var timeoutTask: Task<Void, Never>?
    private var checkTimer: Timer?
    private var isCancelled = false
    private var generation: Int = 0
    private let startTime = Date()

    init(service: AIService, store: WKWebsiteDataStore, completion: @escaping (AILoginStatus) -> Void) {
        self.service = service
        self.store = store
        self.completion = completion
        super.init()
    }

    func start() {
        guard let hostView = AILoginProbeHiddenSurface.shared.availableHost() else {
            // Cannot probe without real attached surface in view hierarchy
            completion(.unknown)
            return
        }

        let config = WKWebViewConfiguration()
        config.websiteDataStore = store
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        config.applicationNameForUserAgent = "Version/\(major >= 26 ? major : major + 3).0 Safari/605.1.15"

        PageAudioController.shared.prepareConfiguration(config)
        let wv = AIProbeHiddenWebView(frame: NSRect(origin: .zero, size: AILoginProbeHiddenSurface.probeViewport), configuration: config)
        wv.setAccessibilityHidden(true)
        wv.navigationDelegate = self
        self.webView = wv
        PageAudioController.shared.register(webView: wv, kind: .aiProbe(serviceName: service.name))

        // Mount behind opaque cover
        hostView.addSubview(wv, positioned: .below, relativeTo: hostView.subviews.first)

        guard let url = URL(string: service.homeURL) else {
            finish(.unknown)
            return
        }

        wv.load(URLRequest(url: url))

        // Bounded 15s timeout
        timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard let self = self, !self.isCancelled else { return }
            self.finish(.unknown)
        }
    }

    func cancel() {
        isCancelled = true
        cleanup()
    }

    private func finish(_ status: AILoginStatus) {
        guard !isCancelled else { return }
        isCancelled = true
        cleanup()
        completion(status)
    }

    private func cleanup() {
        generation += 1
        timeoutTask?.cancel()
        timeoutTask = nil
        checkTimer?.invalidate()
        checkTimer = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.removeFromSuperview()
        webView = nil
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        generation += 1
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        scheduleDomChecks()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.unknown)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.unknown)
    }

    private func scheduleDomChecks() {
        checkTimer?.invalidate()
        var attempts = 0
        let currentGen = self.generation
        checkTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            guard let self = self, !self.isCancelled, self.generation == currentGen else {
                timer.invalidate()
                return
            }
            attempts += 1
            Task { @MainActor in
                guard !self.isCancelled, self.generation == currentGen else { return }
                if let status = await self.evaluateDOM() {
                    guard !self.isCancelled, self.generation == currentGen else { return }
                    timer.invalidate()
                    self.finish(status)
                } else if attempts >= 6 {
                    guard !self.isCancelled, self.generation == currentGen else { return }
                    timer.invalidate()
                    self.finish(.unknown)
                }
            }
        }
    }

    private func evaluateDOM() async -> AILoginStatus? {
        guard let wv = webView, let currentURL = wv.url else { return nil }
        guard !isCancelled else { return nil }
        let currentGen = self.generation
        let expectedHref = currentURL.absoluteString
        let sid = service.id.lowercased()

        // 1. Curated providers ChatGPT / Claude / Gemini
        if sid == "chatgpt" || sid == "claude" || sid == "gemini" {
            guard let config = AIBIResourceLoader.providerConfig(for: sid),
                  (config["status"] as? String) == "active",
                  let providerID = config["id"] as? String, providerID.lowercased() == sid,
                  let allowedOrigins = config["allowedScriptOrigins"] as? [String] else {
                return nil
            }
            // Claude /login must not block whole origin, but scripts must not run on auth origins
            if let authOrigins = config["allowedAuthOrigins"] as? [String] {
                for auth in authOrigins {
                    if AIOriginValidator.matchesAuthOrigin(candidate: currentURL, authEntry: auth) {
                        return .notLoggedIn
                    }
                }
            }
            if AIOriginValidator.isCommonAuthPath(currentURL.path) {
                return .notLoggedIn
            }
            guard allowedOrigins.contains(where: { AIOriginValidator.matchesAllowedScriptOrigin(candidate: currentURL, allowedEntry: $0) }) else {
                return nil
            }

            let selectors = config["selectors"] as? [String: [String]] ?? [:]
            var authenticatedSelectors = selectors["authenticatedIndicator"] ?? []
            if sid == "gemini", !authenticatedSelectors.contains(where: { $0.contains("SignOutOptions") }) {
                authenticatedSelectors.append("a[href*='SignOutOptions']")
            }
            let arguments: [String: Any] = [
                "expectedHref": expectedHref,
                "serviceID": sid,
                "authenticated": authenticatedSelectors,
                "login": selectors["loginIndicator"] ?? [],
                "challenge": selectors["challengeIndicator"] ?? []
            ]

            let script = """
            if (window.location.href !== expectedHref) return null;
            const visible = (el) => {
              if (!el) return false;
              const style = window.getComputedStyle(el);
              if (style.display === 'none' || style.visibility === 'hidden' || style.opacity === '0') return false;
              const rect = el.getBoundingClientRect();
              return rect.width > 0 && rect.height > 0;
            };
            const any = (list) => {
              for (const selector of (list || [])) {
                try { for (const el of document.querySelectorAll(selector)) { if (visible(el)) return true; } } catch (_) {}
              }
              return false;
            };
            if (any(challenge)) return 'challenge';
            if (any(authenticated)) return 'authenticated';
            if (any(login)) return 'login';
            for (const el of document.querySelectorAll('a, button')) {
              if (!visible(el)) continue;
              const text = String(el.innerText || el.getAttribute('aria-label') || '').trim().toLowerCase();
              if (['log in', 'login', 'sign in', '로그인', '로그인하기'].includes(text)) return 'login';
            }
            if (serviceID === 'gemini' && !window.__httLoginMenuExpanded) {
              const candidates = [];
              for (const b of document.querySelectorAll('button')) {
                if (!visible(b)) continue;
                const label = (b.getAttribute('aria-label') || '').trim();
                if (label === '기본 메뉴' || label === 'Main menu') {
                  const exp = b.getAttribute('aria-expanded');
                  if (exp !== 'true') candidates.push(b);
                }
              }
              if (candidates.length === 1) {
                window.__httLoginMenuExpanded = true;
                candidates[0].click();
              }
            }
            return 'pending';
            """

            return await withCheckedContinuation { continuation in
                wv.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .defaultClient) { [weak self, weak wv] result in
                    guard let self = self, !self.isCancelled, self.generation == currentGen,
                          let targetWV = self.webView, targetWV === wv,
                          targetWV.url?.absoluteString == expectedHref else {
                        continuation.resume(returning: nil)
                        return
                    }
                    switch result {
                    case .success(let val):
                        let str = val as? String
                        if str == "authenticated" { continuation.resume(returning: .loggedIn) }
                        else if str == "login" { continuation.resume(returning: .notLoggedIn) }
                        else { continuation.resume(returning: nil) }
                    case .failure:
                        continuation.resume(returning: nil)
                    }
                }
            }
        } else if service.isHana {
            // Hana Alfred on NAS: check login / session
            return nil
        } else {
            // Curated other & custom services: conservative visible account evidence
            if AIOriginValidator.isCommonAuthPath(currentURL.path) {
                return .notLoggedIn
            }
            guard AIOriginValidator.matchesAllowedScriptOrigin(candidate: currentURL, allowedEntry: service.homeURL) else {
                return nil
            }

            let arguments: [String: Any] = [
                "expectedHref": expectedHref,
                "isGrok": (sid == "grok"),
                "isPerplexity": (sid == "perplexity")
            ]
            let script = """
            if (window.location.href !== expectedHref) return null;
            const visible = (el) => {
              if (!el) return false;
              const style = window.getComputedStyle(el);
              if (style.display === 'none' || style.visibility === 'hidden' || style.opacity === '0') return false;
              const rect = el.getBoundingClientRect();
              return rect.width > 0 && rect.height > 0;
            };
            for (const el of document.querySelectorAll("iframe[src*='challenges.cloudflare.com'], #challenge-running, #challenge-stage")) {
              if (visible(el)) return 'unknown';
            }
            let hasLoginOrChallenge = false;
            const isLogoutMatch = (t) => {
              if (['logout', 'log out', 'sign out', '로그아웃'].includes(t)) return true;
              return /^(logout|log out|sign out|로그아웃)(\\s|[\\u2190-\\u21ff\\u2300-\\u23ff\\u2460-\\u25ff\\u2b00-\\u2bff]|$)/i.test(t);
            };
            for (const el of document.querySelectorAll('a, button, [role="menuitem"]')) {
              if (!visible(el)) continue;
              const rawAria = el.getAttribute('aria-label');
              const raw = (rawAria && rawAria.trim().length > 0) ? rawAria : (el.innerText || el.textContent || '');
              const firstLine = String(raw).trim().split('\\n')[0].trim();
              const text = firstLine.toLowerCase();
              if (isLogoutMatch(text)) return 'authenticated';
              if (['login', 'log in', 'sign in', '로그인'].includes(text)) {
                hasLoginOrChallenge = true;
              }
            }
            if (hasLoginOrChallenge) return 'login';
            if (isGrok && !window.__httLoginMenuExpanded) {
              const candidates = [];
              for (const b of document.querySelectorAll('button, [role="button"]')) {
                if (!visible(b)) continue;
                const label = (b.getAttribute('aria-label') || '').trim();
                if (label.startsWith('계정 메뉴') || label.startsWith('Account menu')) {
                  candidates.push(b);
                }
              }
              if (candidates.length === 1) {
                window.__httLoginMenuExpanded = true;
                candidates[0].click();
              }
            } else if (isPerplexity && !window.__httLoginMenuExpanded) {
              const candidates = [];
              for (const b of document.querySelectorAll('button, [role="button"]')) {
                if (!visible(b)) continue;
                const aria = (b.getAttribute('aria-label') || '').trim();
                let matches = (aria === '프로필 아바타' || aria === 'Profile avatar');
                if (!matches) {
                  for (const img of b.querySelectorAll('img')) {
                    const alt = (img.getAttribute('alt') || '').trim();
                    if (alt === '프로필 아바타' || alt === 'Profile avatar') {
                      matches = true;
                      break;
                    }
                  }
                }
                if (matches) {
                  candidates.push(b);
                }
              }
              if (candidates.length === 1) {
                window.__httLoginMenuExpanded = true;
                candidates[0].dispatchEvent(new PointerEvent('pointerdown', { bubbles: true, cancelable: true, pointerType: 'mouse', button: 0, isPrimary: true }));
                candidates[0].dispatchEvent(new PointerEvent('pointerup', { bubbles: true, cancelable: true, pointerType: 'mouse', button: 0, isPrimary: true }));
              }
            }
            return 'unknown';
            """
            return await withCheckedContinuation { continuation in
                wv.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .defaultClient) { [weak self, weak wv] result in
                    guard let self = self, !self.isCancelled, self.generation == currentGen,
                          let targetWV = self.webView, targetWV === wv,
                          targetWV.url?.absoluteString == expectedHref else {
                        continuation.resume(returning: nil)
                        return
                    }
                    switch result {
                    case .success(let val):
                        let str = val as? String
                        if str == "authenticated" { continuation.resume(returning: .loggedIn) }
                        else if str == "login" { continuation.resume(returning: .notLoggedIn) }
                        else { continuation.resume(returning: nil) }
                    case .failure:
                        continuation.resume(returning: nil)
                    }
                }
            }
        }
    }
}

// MARK: - Login Window Coordinator (WebKit Child Popup & Positive Auth Dismissal)

final class AILoginWindowCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
    let service: AIService
    let store: WKWebsiteDataStore
    let webView: WKWebView
    weak var window: NSWindow?
    var onSuccess: (() -> Void)?
    private(set) var hasSucceeded = false
    private var isClosed = false
    private var generation: Int = 0
    private var childPopups: [NSWindow] = []
    private var checkTimer: Timer?

    init(service: AIService, store: WKWebsiteDataStore, webView: WKWebView) {
        self.service = service
        self.store = store
        self.webView = webView
        super.init()
    }

    func teardown() {
        isClosed = true
        generation += 1
        checkTimer?.invalidate()
        checkTimer = nil
        for w in childPopups { w.close() }
        childPopups.removeAll()
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        // Only advance navigation generation for main login webView
        if webView === self.webView {
            generation += 1
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Child OAuth views only trigger scheduleCheck on MAIN webView, never evaluate DOM in child
        scheduleCheck()
    }

    private func scheduleCheck() {
        guard !hasSucceeded, !isClosed else { return }
        checkTimer?.invalidate()
        var count = 0
        let currentGen = self.generation
        checkTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            guard let self = self, !self.isClosed, !self.hasSucceeded, self.generation == currentGen else {
                timer.invalidate()
                return
            }
            count += 1
            Task { @MainActor in
                guard !self.isClosed, !self.hasSucceeded, self.generation == currentGen else { return }
                let res = await self.checkAuth()
                guard !self.isClosed, !self.hasSucceeded, self.generation == currentGen else { return }
                if res == .loggedIn {
                    timer.invalidate()
                    self.hasSucceeded = true
                    self.onSuccess?()
                } else if count >= 10 {
                    timer.invalidate()
                }
            }
        }
    }

    private func checkAuth() async -> AILoginStatus? {
        guard !isClosed, !hasSucceeded else { return nil }
        guard let url = webView.url else { return nil }
        let currentGen = self.generation
        let expectedHref = url.absoluteString
        let sid = service.id.lowercased()

        if sid == "chatgpt" || sid == "claude" || sid == "gemini" {
            guard let config = AIBIResourceLoader.providerConfig(for: sid),
                  (config["status"] as? String) == "active",
                  let providerID = config["id"] as? String, providerID.lowercased() == sid,
                  let allowedOrigins = config["allowedScriptOrigins"] as? [String] else {
                return nil
            }
            if let authOrigins = config["allowedAuthOrigins"] as? [String] {
                for auth in authOrigins {
                    if AIOriginValidator.matchesAuthOrigin(candidate: url, authEntry: auth) { return .notLoggedIn }
                }
            }
            if AIOriginValidator.isCommonAuthPath(url.path) { return .notLoggedIn }
            guard allowedOrigins.contains(where: { AIOriginValidator.matchesAllowedScriptOrigin(candidate: url, allowedEntry: $0) }) else {
                return nil
            }

            let selectors = config["selectors"] as? [String: [String]] ?? [:]
            var authenticatedSelectors = selectors["authenticatedIndicator"] ?? []
            if sid == "gemini", !authenticatedSelectors.contains(where: { $0.contains("SignOutOptions") }) {
                authenticatedSelectors.append("a[href*='SignOutOptions']")
            }
            let arguments: [String: Any] = [
                "expectedHref": expectedHref,
                "serviceID": sid,
                "authenticated": authenticatedSelectors,
                "login": selectors["loginIndicator"] ?? [],
                "challenge": selectors["challengeIndicator"] ?? []
            ]
            let script = """
            if (window.location.href !== expectedHref) return false;
            const visible = (el) => {
              if (!el) return false;
              const style = window.getComputedStyle(el);
              if (style.display === 'none' || style.visibility === 'hidden' || style.opacity === '0') return false;
              const rect = el.getBoundingClientRect();
              return rect.width > 0 && rect.height > 0;
            };
            const any = (list) => {
              for (const selector of (list || [])) {
                try { for (const el of document.querySelectorAll(selector)) { if (visible(el)) return true; } } catch (_) {}
              }
              return false;
            };
            if (any(authenticated)) return true;
            let hasLoginOrChallenge = any(challenge) || any(login);
            if (!hasLoginOrChallenge) {
              for (const el of document.querySelectorAll('a, button')) {
                if (!visible(el)) continue;
                const text = String(el.innerText || el.getAttribute('aria-label') || '').trim().toLowerCase();
                if (['log in', 'login', 'sign in', '로그인', '로그인하기'].includes(text)) {
                  hasLoginOrChallenge = true;
                  break;
                }
              }
            }
            if (!hasLoginOrChallenge && serviceID === 'gemini' && !window.__httLoginMenuExpanded) {
              const candidates = [];
              for (const b of document.querySelectorAll('button')) {
                if (!visible(b)) continue;
                const label = (b.getAttribute('aria-label') || '').trim();
                if (label === '기본 메뉴' || label === 'Main menu') {
                  const exp = b.getAttribute('aria-expanded');
                  if (exp !== 'true') candidates.push(b);
                }
              }
              if (candidates.length === 1) {
                window.__httLoginMenuExpanded = true;
                candidates[0].click();
              }
            }
            return false;
            """
            return await withCheckedContinuation { continuation in
                self.webView.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .defaultClient) { [weak self] res in
                    guard let self = self, !self.isClosed, !self.hasSucceeded, self.generation == currentGen,
                          self.webView.url?.absoluteString == expectedHref else {
                        continuation.resume(returning: nil)
                        return
                    }
                    if case .success(let val) = res, (val as? Bool) == true {
                        continuation.resume(returning: .loggedIn)
                    } else {
                        continuation.resume(returning: nil)
                    }
                }
            }
        }
        return nil
    }

    // MARK: WKUIDelegate (OAuth Popups)

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard childPopups.count < 4 else { return nil }
        PageAudioController.shared.prepareConfiguration(configuration)
        let child = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 680), configuration: configuration)
        child.navigationDelegate = self
        child.uiDelegate = self

        let popupWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 680),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        popupWindow.title = navigationAction.request.url?.host ?? "로그인 연결"
        popupWindow.contentView = child
        popupWindow.isReleasedWhenClosed = false

        childPopups.append(popupWindow)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: popupWindow, queue: .main) { [weak self, weak popupWindow] _ in
            guard let self = self, let w = popupWindow else { return }
            self.childPopups.removeAll { $0 === w }
            self.scheduleCheck()
        }

        popupWindow.center()
        popupWindow.makeKeyAndOrderFront(nil)
        PageAudioController.shared.register(webView: child, kind: .popup(window: popupWindow, title: popupWindow.title))
        return child
    }

    func webViewDidClose(_ webView: WKWebView) {
        for w in childPopups where w.contentView === webView {
            w.close()
            childPopups.removeAll { $0 === w }
            scheduleCheck()
            break
        }
    }
}
