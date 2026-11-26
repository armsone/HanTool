import AppKit
import Combine
import WebKit
import HTTThemeCore

/// 호스트에 계정 테마 통로를 내보낸다(하나 패널의 웹 보기를 그대로 쓴다).
public enum HTDThemeSync {
    @MainActor
    public static func transport() -> HTTAccountThemeTransport { HanaPanelHost.shared.themeSync }
}

/// 하나 패널 웹 보기(고정 주소 /alfred, 최상위 문서)의 기존 로그인 세션으로 계정 화면 설정을 읽고 쓴다.
/// 쿠키·토큰은 읽지 않으며, 다른 사이트나 일반 브라우저 탭에는 아무것도 넣지 않는다.
/// 웹 화면에서 오는 신호는 "다시 읽기" 계기로만 쓰고, 값은 항상 `/api/ui-preferences`에서 읽는다.
@MainActor
final class HanaThemeSync: NSObject, HTTAccountThemeTransport, WKScriptMessageHandler, WKHTTPCookieStoreObserver {
    static let world = WKContentWorld.world(name: "HanaTheme")
    static let handlerName = "htheme"
    private static let requestTimeout: TimeInterval = 15
    private static let periodicInterval: TimeInterval = 60
    private static let cookieRefreshSpacing: TimeInterval = 10

    private weak var webView: WKWebView?
    private var observers: Set<AnyCancellable> = []
    private var mirrored: HTTPaletteID?
    private var lastCookieRefresh = Date.distantPast
    private var lastRecoveryLoad = Date()
    private var cookieRefreshScheduled = false

    private var center: HTTThemeCenter { .shared }

    private static var pageGuard: String {
        """
        const L = window.location;
        const trusted = window.top === window && L.protocol === 'https:' && L.hostname === '\(HanaPanelHost.trustedHost)' &&
            L.port === '\(HanaPanelHost.trustedPort)' && L.pathname === '\(HanaPanelHost.trustedPath)' && L.search === '';
        """
    }

    private static var observerScript: String {
        """
        (() => {
            \(pageGuard)
            const channel = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(handlerName);
            if (!trusted || !channel) return;
            let timer = 0;
            const changed = () => { clearTimeout(timer); timer = setTimeout(() => channel.postMessage('changed'), 150); };
            new MutationObserver(changed).observe(document.documentElement, { attributes: true, attributeFilter: ['data-af-appearance', 'data-theme'] });
            const login = document.getElementById('afLogin');
            if (login) new MutationObserver(changed).observe(login, { attributes: true, attributeFilter: ['hidden', 'class', 'style', 'open'] });
        })();
        """
    }

    private static var requestScript: String {
        """
        \(pageGuard)
        if (!trusted) return { state: 'unavailable' };
        // 묶인 계정이 없는 쓰기는 보내지 않는다.
        if (theme !== '' && expected === '') return { state: 'unavailable' };
        const signal = AbortSignal.timeout(10000);
        const call = async (url, init) => {
            const res = await fetch(url, Object.assign({ credentials: 'same-origin', cache: 'no-store', redirect: 'error', signal }, init || {}));
            let data = null;
            try { data = await res.json(); } catch (e) {}
            return { status: res.status, ok: res.ok, data, account: res.headers.get('X-HW-Theme-Account') };
        };
        // 401·403은 모두 "이 세션으로는 안 됨"이라 로그아웃으로 보고 이전 계정 상태를 지운다.
        const denied = (r) => r.status === 401 || r.status === 403;
        // undefined: 확인 불가, null: 로그아웃, 문자열: 계정 구분값
        const identity = async () => {
            const r = await call('/api/session');
            if (denied(r)) return null;
            if (!r.ok || !r.data || typeof r.data.authenticated !== 'boolean') return undefined;
            if (!r.data.authenticated) return null;
            if (r.data.role === 'master') return 'master';
            return typeof r.data.accountId === 'string' && r.data.accountId ? 'account:' + r.data.accountId : undefined;
        };
        // 서버가 GET 응답 헤더로 알리는 계정값은 마스터면 'master', 그 외엔 계정 id 그대로다.
        const headerFor = (id) => id === 'master' ? 'master' : id.slice('account:'.length);
        const hasHeader = (r) => typeof r.account === 'string' && r.account !== '';
        // 헤더가 있고 지금 세션의 계정과 정확히 같을 때만 "같은 계정에 묶인 응답"으로 본다.
        const bound = (r, id) => hasHeader(r) && r.account === headerFor(id);
        const before = await identity();
        if (before === undefined) return { state: 'unavailable' };
        if (before === null) return { state: 'signedOut' };
        if (expected !== '' && before !== expected) return { state: 'changed' };
        const supports = (r) => r.ok && !!r.data && typeof r.data === 'object' && Object.prototype.hasOwnProperty.call(r.data, 'theme');
        let prefs = await call('/api/ui-preferences');
        if (denied(prefs)) return { state: 'signedOut' };
        if (theme !== '' && supports(prefs)) {
            // 헤더가 다른 계정이면 이 쓰기 의도를 버린다. 헤더가 없으면 쓰지 않고 아래에서 미지원으로 보고한다.
            if (hasHeader(prefs) && !bound(prefs, before)) return { state: 'changed' };
            if (bound(prefs, before)) {
                // GET 에서 받은 계정 헤더를 PATCH 에만 그대로 되돌린다(서버는 다르면 409). 앱으로는 넘기지 않는다.
                const headers = { 'Content-Type': 'application/json', 'X-HW-Theme-Account': prefs.account };
                const current = await identity();
                if (current === undefined) return { state: 'unavailable' };
                if (current === null) return { state: 'signedOut' };
                if (current !== before) return { state: 'changed' };
                const saved = await call('/api/ui-preferences', { method: 'PATCH', headers, body: JSON.stringify({ theme }) });
                if (saved.status === 409) return { state: 'changed' };
                if (denied(saved)) return { state: 'signedOut' };
                if (!saved.ok) return { state: 'unavailable' };
                // 저장한 뒤에는 서버에서 다시 읽은 값으로만 저장 여부를 확인한다.
                prefs = await call('/api/ui-preferences');
                if (denied(prefs)) return { state: 'signedOut' };
            }
        }
        const after = await identity();
        if (after === undefined) return { state: 'unavailable' };
        if (after === null) return { state: 'signedOut' };
        if (after !== before) return { state: 'changed' };
        if (!prefs.ok || !prefs.data || typeof prefs.data !== 'object') return { state: 'unavailable' };
        // 계정 헤더가 없거나 다른 계정이면 이 서버의 계정 테마를 쓰지 않는다(이 Mac 설정으로만 동작, 쓰기 없음).
        return { state: 'ok', account: before, supported: supports(prefs) && bound(prefs, before),
                 theme: typeof prefs.data.theme === 'string' ? prefs.data.theme : '' };
        """
    }

    func prepareConfiguration(_ config: WKWebViewConfiguration) {
        config.userContentController.addUserScript(WKUserScript(
            source: Self.observerScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: Self.world))
        config.userContentController.add(self, contentWorld: Self.world, name: Self.handlerName)
    }

    func start(webView: WKWebView) {
        self.webView = webView
        webView.configuration.websiteDataStore.httpCookieStore.add(self)
        let notifications = NotificationCenter.default
        notifications.publisher(for: NSApplication.didBecomeActiveNotification)
            .merge(with: notifications.publisher(for: NSWindow.didBecomeKeyNotification))
            .throttle(for: .seconds(2), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.center.requestAccountRefresh() } }
            .store(in: &observers)
        notifications.publisher(for: HTTThemeCenter.didChangeNotification)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.mirrorToPage() } }
            .store(in: &observers)
        notifications.publisher(for: HTTThemeCenter.accountThemeSavedNotification)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.notifyPageOfSavedTheme() } }
            .store(in: &observers)
        // 다른 기기에서 바꾼 값은 보이는 창이 있는 동안만 천천히 다시 읽는다.
        Timer.publish(every: Self.periodicInterval, tolerance: 10, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    let visible = NSApp.isActive || NSApp.windows.contains { $0.isVisible && $0.className != "NSStatusBarWindow" }
                    if visible { self?.center.requestAccountRefresh() }
                }
            }
            .store(in: &observers)
        applyBackground()
    }

    func pageWillChange() {
        center.accountDocumentWillChange()
    }

    func pageDidLoad() {
        mirrored = nil
        mirrorToPage()
        center.requestAccountRefresh()
    }

    // MARK: - 계정 읽기·쓰기

    func readAccountTheme() async -> HTTAccountThemeResult {
        await request(theme: nil, expected: nil)
    }

    func writeAccountTheme(_ theme: HTTPaletteID, expectedAccount: String) async -> HTTAccountThemeResult {
        await request(theme: theme, expected: expectedAccount)
    }

    private func request(theme: HTTPaletteID?, expected: String?) async -> HTTAccountThemeResult {
        guard let webView else { return .unavailable }
        // 문서를 불러오지 못한 상태(네트워크 끊김 등)면 고정 주소를 가끔 다시 연다.
        if webView.url == nil, !webView.isLoading, Date().timeIntervalSince(lastRecoveryLoad) > Self.periodicInterval {
            lastRecoveryLoad = Date()
            webView.load(URLRequest(url: HanaPanelHost.trustedURL))
        }
        guard !webView.isLoading, HanaPanelHost.isTrustedAlfredURL(webView.url) else { return .unavailable }
        let arguments: [String: Any] = ["theme": theme?.rawValue ?? "", "expected": expected ?? ""]
        let value: [String: Any]? = await withCheckedContinuation { continuation in
            var finished = false
            func finish(_ value: [String: Any]?) {
                guard !finished else { return }
                finished = true
                continuation.resume(returning: value)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.requestTimeout) { finish(nil) }
            webView.callAsyncJavaScript(Self.requestScript, arguments: arguments, in: nil, in: Self.world) { result in
                finish((try? result.get()) as? [String: Any])
            }
        }
        guard HanaPanelHost.isTrustedAlfredURL(webView.url), let value, let state = value["state"] as? String else {
            return .unavailable
        }
        switch state {
        case "ok":
            guard let account = value["account"] as? String, !account.isEmpty,
                  let supported = value["supported"] as? Bool else { return .unavailable }
            return .signedIn(account: account, supportsTheme: supported,
                             theme: HTTPaletteID(rawValue: value["theme"] as? String ?? ""))
        case "signedOut": return .signedOut
        case "changed": return .accountChanged
        default: return .unavailable
        }
    }

    // MARK: - 하나 웹 화면 반영

    private func applyBackground() {
        webView?.underPageBackgroundColor = .htt(center.paletteID.tokens.paper)
    }

    /// 팔레트가 실제로 바뀐 때와 새 문서에서만 하나 화면의 테마 속성을 맞춘다(웹에서 방금 고른 값을 되돌리지 않는다).
    private func mirrorToPage() {
        applyBackground()
        let palette = center.paletteID
        guard center.hasUnifiedChoice || mirrored != nil, palette != mirrored,
              let webView, HanaPanelHost.isTrustedAlfredURL(webView.url) else { return }
        mirrored = palette
        // 웹이 내놓은 "표시만 바꾸기" 함수를 쓰고(저장·쓰기 없음), 없으면 테마 속성만 맞춘다.
        let script = """
        \(Self.pageGuard)
        if (!trusted) return false;
        const bridge = window.HanstreeTheme;
        if (bridge && typeof bridge.applyLocalAttrs === 'function') { bridge.applyLocalAttrs(theme); return true; }
        const root = document.documentElement;
        root.dataset.theme = theme;
        root.dataset.afAppearance = theme;
        root.style.colorScheme = theme === 'jarvis' || theme === 'ultron' ? 'dark' : 'light';
        return true;
        """
        webView.callAsyncJavaScript(script, arguments: ["theme": palette.rawValue], in: nil, in: .page, completionHandler: nil)
    }

    /// 계정 저장이 확인된 뒤 하나 웹 화면이 서버 값을 다시 읽도록 알린다.
    private func notifyPageOfSavedTheme() {
        guard let webView, HanaPanelHost.isTrustedAlfredURL(webView.url) else { return }
        let script = """
        \(Self.pageGuard)
        if (trusted && window.HanstreeTheme && typeof window.HanstreeTheme.refresh === 'function') window.HanstreeTheme.refresh();
        """
        webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page, completionHandler: nil)
    }

    // MARK: - 다시 읽기 계기

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let frame = message.frameInfo
        guard message.webView === webView, message.world === Self.world, frame.isMainFrame,
              frame.securityOrigin.protocol.lowercased() == "https",
              frame.securityOrigin.host.lowercased() == HanaPanelHost.trustedHost,
              frame.securityOrigin.port == HanaPanelHost.trustedPort,
              HanaPanelHost.isTrustedAlfredURL(webView?.url) else { return }
        center.requestAccountRefresh()
        // 웹 화면의 저장 요청이 끝나기 전에 읽었을 수 있으므로 잠시 뒤 한 번 더 확인한다.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { HTTThemeCenter.shared.requestAccountRefresh() }
    }

    /// 로그인·로그아웃·계정 전환의 계기. 쿠키 내용은 읽지 않는다.
    nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task { @MainActor [weak self] in self?.scheduleCookieRefresh() }
    }

    private func scheduleCookieRefresh() {
        guard !cookieRefreshScheduled else { return }
        cookieRefreshScheduled = true
        let wait = max(1, Self.cookieRefreshSpacing - Date().timeIntervalSince(lastCookieRefresh))
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self else { return }
            self.cookieRefreshScheduled = false
            self.lastCookieRefresh = Date()
            self.center.requestAccountRefresh()
        }
    }
}
