import SwiftUI
import AppKit
import WebKit
import Combine

/// One browser tab (the "브라우저" screen shows the active one; the former login window routes here). Owned by AppModel
/// (`tabs`) so it survives sidebar changes; every tab keeps its own WebView, history, candidates and callbacks, while
/// the session store (cookies) is shared. Shows the real navigation state (loading, address, secure or not, errors);
/// it never claims "logged in" just because cookies exist — the user checks the site's own page.
@MainActor
final class LoginBrowserModel: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    /// Identity of this tab inside AppModel.tabs (memory only).
    let tabID = UUID()
    /// Tabs get disjoint session-token ranges, so a candidate or callback can never be mistaken for another tab's.
    private static var tokenBlock = 0
    private static func nextTokenBase() -> Int {
        tokenBlock += 1
        return tokenBlock * 1_000_000
    }
    /// Popup tabs one document may open (a new document starts over) and the page-level pop-up budget.
    private static let maxPopupsPerDocument = 3
    private var popupsOpened = 0
    private var popupDocumentGeneration = -1
    /// The tab's own user content controller (script + message handler); never the opener's.
    private var ownedUCC: WKUserContentController?
    /// Connection mode (helper generation, nil = system connection) the current WebView/store was built for.
    private(set) var viewMode: Int?
    /// Route (connection path + store) of the current WebView. Pages and pop-ups opened from it inherit it only when
    /// their own site has no explicit choice; inheriting never writes a choice.
    @Published private(set) var viewRoute: BrowsingRoute = .direct
    /// True when the current WebView sits on the primary (long-standing identifier) store.
    private(set) var usesPrimaryStore = true
    /// Route chosen for the view `prepare()` builds next (an explicit address or a rebuild); nil = decide from the
    /// pending address and the global default.
    private var pendingRoute: BrowsingRoute?
    var hasWebView: Bool { webView != nil }

    /// True if this tab is the currently active/focused tab in either ordinary AppModel or its SAW project session.
    var isCurrentActiveBrowser: Bool {
        if let sawWorkspace = sawWorkspace, let pid = sawProjectID {
            guard let sess = sawWorkspace.sessions[pid] else { return false }
            return sess.activeBrowser === self
        }
        return appModel?.browser === self
    }

    /// Helper behind this tab's route (nil = system connection). Only valid for the current view.
    var routeConnection: ConnectionManager? { appModel?.connectionManager(for: viewRoute) }
    /// Bumped whenever this tab stops being the active one: automatic recovery of an older activation
    /// (timer, helper acknowledgement) is dropped.
    private var activationEpoch = 0
    let googleFill = GoogleAutofill()
    private var credentialAutofillPromptedForDocument = false
    private var activeCredentialAlertPresented = false
    /// A pop-up tab's first navigation waits (in the policy decision, without a second request) for the helper.
    private var awaitsHelperPolicyForFirstNavigation = false
    @Published var address = ""
    @Published var currentURL: URL?
    private var authorizedPlannerReportURL: URL?
    private var authorizedExternalHTMLURL: URL?
    /// The committed main-frame URL of this tab's webView, reset at view install/teardown/home.
    @Published public private(set) var popupCommittedURL: URL?
    @Published var pageTitle = ""
    @Published var isLoading = false
    /// Optional project workspace and ID when this tab is owned by a SAW project session.
    weak var sawWorkspace: SAWWorkspace?
    var sawProjectID: UUID?
    var onOpenSAWPopup: ((LoginBrowserModel, WKWebViewConfiguration, URL?) -> WKWebView?)?
    var onCloseSAWTab: ((LoginBrowserModel) -> Void)?
    @Published var progress: Double = 0
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var secureContent = true
    @Published var lastError: String?
    /// Settled info banners (notice / modeNotice / adWallNotice) hide themselves ~3 s after the LAST assignment of
    /// that banner. Every assignment bumps its sequence, so a repeated identical text restarts the timer and an old
    /// timer never clears a newer value; the timers live in this tab's model, so other tabs are never touched.
    private static let noticeLifetime: UInt64 = 3_000_000_000
    private var noticeSeq = 0, modeNoticeSeq = 0, adWallNoticeSeq = 0
    /// Set (by `postPendingNotice`) while the banner explains a wait or blocker; such a banner is cleared by its own flow.
    private var noticeIsPending = false
    @Published var notice: String? {
        didSet {
            noticeIsPending = false
            noticeSeq += 1
            scheduleDismiss(seq: noticeSeq, isCurrent: { $0.noticeSeq }, active: notice != nil, blocked: { $0.noticeIsPending || $0.recoveryInProgress || $0.activeEditorOrCapture }) { $0.notice = nil }
        }
    }
    /// Kept until the user opens a page again: the session was replaced because the connection path changed.
    @Published var modeNotice: String? {
        didSet {
            modeNoticeSeq += 1
            scheduleDismiss(seq: modeNoticeSeq, isCurrent: { $0.modeNoticeSeq }, active: modeNotice != nil, blocked: { $0.directRetryOffer != nil || $0.routeConnection?.isFailed == true }) { $0.modeNotice = nil }
        }
    }
    /// Visible only while the offer of the "일반 연결로 한 번 다시 열기" button is valid for the current attempt.
    @Published private(set) var directRetryOffer: DirectRetryOffer?
    @Published private(set) var webView: WKWebView?
    @Published var isShowingHome: Bool = true
    private var hasStartedUp = false

    /// Video candidates of the current top-level page (memory only).
    @Published private(set) var candidates: [MediaCandidate] = []
    /// Candidate id → job id queued from it on this page.
    @Published private(set) var queuedJobs: [String: String] = [:]
    @Published private(set) var discoveryProblem: String?

    /// Where the bounded initial search for the current page stands. `.settled` only means the timed search window
    /// ended without being a verdict: automatic updates from player events continue and the page can still be
    /// re-searched or analysed. Driven by the model's own timer, never by anything the page reports.
    enum DiscoveryPhase { case searching, settled }
    @Published private(set) var discoveryPhase: DiscoveryPhase = .searching
    private var discoveryTask: Task<Void, Never>?
    /// Embedded frames that reported on this page (bounded), so "다시 찾기" can reach them too.
    private var reportingFrames: [WKFrameInfo] = []
    private static let discoveryWindowNanos: UInt64 = 12_000_000_000
    private static let discoveryLoadExtensionNanos: UInt64 = 5_000_000_000
    private static let discoveryMaxLoadExtensions = 3
    private static let maxReportingFrames = 8

    weak var appModel: AppModel? {
        didSet {
            setupBlockedSubscription()
        }
    }
    private var blockedSubscription: AnyCancellable?

    /// ATTRIBUTION LIMITATION NOTE:
    /// The fixed client tag (browserClient = "web") cannot cryptographically prove which previous
    /// document or frame originated a delayed refusal event, and timestamps alone cannot provide
    /// perfect document provenance or distinguish advertising/tracker requests from required site CDNs.
    /// In accordance with user approval authorizing public extra hosts requested by the enabled app
    /// browser, automatic recovery is bounded to the current stable GET page, logical attempt,
    /// sessionToken, and helper generation. It enforces brief coalescing, strict per-attempt budgets,
    /// no-progress loop prevention, and prompt invalidation on cancellation, navigation, or stop.
    private(set) var logicalAttemptId = 0
    private var attemptRoundsUsed = 0
    private var attemptAllowedHosts = Set<String>()
    private var currentMainFrameMethod = "GET"
    private var isAutoReloading = false
    private var scheduledRecoveryTask: Task<Void, Never>?
    private var activeRecoveryTicket = 0
    private var recoveryEnabled = true
    private var stopEpoch = 0
    private var lastMainFrameURL: URL?
    private var currentNavigation: WKNavigation?

    private struct SafeRetryRequest {
        let request: URLRequest
        let url: URL
        let attemptId: Int
        let sessionToken: Int
        let helperGeneration: Int
        /// Built by this app's own programmatic GET of an address (typed / bookmark / route switch). A request that WebKit
        /// built for a link, redirect or script is not known to be header-free, so it never qualifies for the direct retry.
        let programmaticAddress: Bool
    }
    private var safeRetryRequest: SafeRetryRequest?
    /// Host of the first main-frame GET of the current navigation chain (a redirect to another host never counts as it).
    private var chainOriginHost: String?
    /// What the button shows (host only). The binding to attempt / session / navigation is `directRetryBinding`.
    struct DirectRetryOffer: Equatable { let host: String }
    private struct DirectRetryBinding {
        let url: URL
        let host: String
        let attemptId: Int
        let sessionToken: Int
        let navigation: WKNavigation
        weak var view: WKWebView?
    }
    private var directRetryBinding: DirectRetryBinding?
    /// Set only on a view rebuilt by the explicit direct retry: the one host that view may keep on the system
    /// connection. Runtime only (never a saved site rule); cleared whenever the view is replaced.
    private var directFallbackHost: String?
    /// True only from the fallback's replay until that navigation commits, fails, or any fresh navigation starts: the
    /// window in which the replay (and its same-host server redirects) may stay on the system connection.
    private var directFallbackChain = false
    /// The one address the fallback replay may load (fragment ignored); every top-level redirect away from it is cancelled.
    private var directFallbackURL: String?

    private static func createSafeGETRequest(for url: URL) -> URLRequest? {
        guard let scheme = url.scheme?.lowercased(), scheme == "https",
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else {
            return nil
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.httpBody = nil
        req.httpBodyStream = nil
        return req
    }

    static let autoRecoveryMaxRounds = 8
    static let autoRecoveryMaxHosts = 32

    @Published private(set) var recoveryStatus: String?
    @Published private(set) var recoveryProblem: String?
    @Published private(set) var pageStartedAt = Date()
    @Published private(set) var recoveryInProgress = false

    private var observations: [NSKeyValueObservation] = []
    private var pendingURL: URL?
    /// The user asked for the browser (tab shown or address opened); only then is a session store created.
    private var wanted = false
    /// Bumped for every new WebView/session and on teardown: late callbacks of an old browser are ignored.
    private(set) var sessionToken = LoginBrowserModel.nextTokenBase()
    /// Bumped for every new top-level document: candidates and selections of an older page are refused.
    private(set) var generation = 0
    private var pendingResponseCandidate: URL?
    private var pendingResponseKind: MediaCandidate.Kind?
    /// The committed top-level document is a validated direct media response (WebKit's built-in player shows it).
    private var committedMediaPage: URL?

    /// The tab's own controller (lets a pop-up check that WebKit's configuration did not keep sharing the opener's).
    var contentController: WKUserContentController? { ownedUCC }

    // MARK: Ad blocker (per tab) and ad-blocker wall handling

    /// Rule stage of THIS tab only: `.full` normally; `.reduced` / `.off` only while this tab shows one site whose
    /// visible ad-blocker wall asked for it. The stored global preference is never written from here.
    private(set) var adBlockStage: BrowserAdBlockMode = .full
    /// Visible Korean notice while this tab runs with less ad blocking than usual.
    @Published private(set) var adWallNotice: String? {
        didSet {
            adWallNoticeSeq += 1
            scheduleDismiss(seq: adWallNoticeSeq, isCurrent: { $0.adWallNoticeSeq }, active: adWallNotice != nil, blocked: { $0.activeEditorOrCapture }) { $0.adWallNotice = nil }
        }
    }
    private var adWallOrigin: String?
    /// Bumped by every top-level navigation decision and every reset: pending bounded checks of an older page stop.
    private var adWallTicket = 0
    /// Per-tab ticket of the pending (not yet started) main-frame load in loadWhenAllowed/startLoadWhenAllowed. Bumped by
    /// every new logical navigation, Home/Stop/teardown and top-level delegate decision, so a stale async continuation never loads.
    private var loadTicket = 0

    private var activeEditorOrCapture: Bool {
        BrowserAdHideManager.shared.isEditing || BrowserScreenshotManager.shared.captureStatus != nil
    }

    private func postPendingNotice(_ text: String) {
        notice = text
        noticeIsPending = true
    }

    /// Hides the banner after the lifetime unless it was replaced meanwhile or is currently not dismissible (the
    /// banner's own state — ad-block stage, connection state, pending retry — is left untouched).
    private func scheduleDismiss(seq: Int, isCurrent: @escaping (LoginBrowserModel) -> Int, active: Bool,
                                 blocked: @escaping (LoginBrowserModel) -> Bool, clear: @escaping (LoginBrowserModel) -> Void) {
        guard active else { return }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.noticeLifetime)
            guard let self = self, isCurrent(self) == seq, !blocked(self) else { return }
            clear(self)
        }
    }

    private var adBlockPrefEnabled: Bool { appModel?.preferences.adBlockingEnabled ?? true }

    /// What this tab should carry right now (global OFF always wins).
    var effectiveAdBlockMode: BrowserAdBlockMode { adBlockPrefEnabled ? adBlockStage : .off }

    /// Brings this tab's own user content controller to the desired rule set. Safe to call any time; when a list is
    /// still compiling, the then-current desired mode is re-read when it finishes, so "off" requested meanwhile wins.
    func refreshAdBlock() {
        guard let ucc = ownedUCC else { return }
        let blocker = BrowserAdBlocker.shared
        let mode = effectiveAdBlockMode
        blocker.apply(mode, to: ucc)
        guard mode != .off, !blocker.isSettled(mode) else { return }
        blocker.getRuleList(mode) { [weak self, weak ucc] _ in
            guard let self = self, let ucc = ucc, self.ownedUCC === ucc else { return }
            BrowserAdBlocker.shared.apply(self.effectiveAdBlockMode, to: ucc)
        }
    }

    /// The global ad-block preference changed (already stored by the caller): back to the normal stage for this tab.
    func setAdBlockingEnabled(_ enabled: Bool) {
        resetAdWall()
        refreshAdBlock()
    }

    private func resetAdWall() {
        adWallTicket += 1
        adWallOrigin = nil
        adWallNotice = nil
        adBlockStage = .full
    }

    private static func originKey(_ url: URL?) -> String? {
        guard let url = url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        return "\(scheme)://\(host):\(url.port ?? (scheme == "https" ? 443 : 80))"
    }

    /// Called for every top-level navigation decision: older checks stop, and leaving the site that needed the
    /// reduced/off stage restores normal blocking.
    private func adWallWillNavigate(to url: URL) {
        adWallTicket += 1
        loadTicket += 1
        if adBlockStage != .full, Self.originKey(url) != adWallOrigin {
            resetAdWall()
            refreshAdBlock()
        }
    }

    private static let adWallAuthPathWords = ["login", "log-in", "logon", "signin", "sign-in", "signup", "sign-up",
                                              "auth", "oauth", "sso", "saml", "account", "password", "passwd",
                                              "logout", "register", "verify", "captcha", "checkout", "payment"]
    private static let adWallAuthHostLabels: Set<String> = ["login", "auth", "accounts", "account", "sso", "signin", "id", "secure"]
    private static let adWallAuthQueryNames: Set<String> = ["code", "token", "access_token", "id_token", "state", "ticket",
                                                            "password", "samlresponse", "saml", "sessionid", "session"]

    private static func looksLikeAuthPage(_ url: URL) -> Bool {
        if let first = url.host?.lowercased().split(separator: ".").first, adWallAuthHostLabels.contains(String(first)) { return true }
        let path = url.path.lowercased()
        if adWallAuthPathWords.contains(where: { path.contains($0) }) { return true }
        if let fragment = url.fragment?.lowercased(), fragment.contains("access_token") || fragment.contains("id_token") { return true }
        if let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
           items.contains(where: { adWallAuthQueryNames.contains($0.name.lowercased()) }) { return true }
        return false
    }

    /// The page is the result of an exact, header-free GET this app can replay: never a POST/form result, an
    /// authenticated request, a media response, an authentication page, or a page already moved to another origin.
    private func adWallEligible(_ wv: WKWebView) -> Bool {
        guard webView === wv, !isShowingHome, directFallbackHost == nil, adBlockPrefEnabled, adBlockStage != .off,
              let url = wv.url, let origin = Self.originKey(url), url.user == nil, url.password == nil,
              currentMainFrameMethod == "GET", committedMediaPage == nil,
              let retry = safeRetryRequest, retry.sessionToken == sessionToken,
              Self.withoutFragment(retry.url) == Self.withoutFragment(url),
              !Self.looksLikeAuthPage(url) else { return false }
        if adBlockStage != .full, adWallOrigin != origin { return false }
        return true
    }

    /// Main-frame only, run in the app's own isolated world (page scripts cannot tamper with the check or its result).
    /// High confidence = a visible, hit-testable overlay that covers (or sits on a page-covering backdrop) AND whose
    /// short visible text both names the ad blocker and asks to disable/allow it. Hidden copy, long articles, password
    /// forms and ordinary error text do not match.
    private static let adWallDetectScript = #"""
    (() => {
      try {
        if (window.top !== window) return false;
        const vw = window.innerWidth, vh = window.innerHeight;
        if (!(vw > 200 && vh > 200)) return false;
        const named = /(ad[\s\-_]?block(er|ers|ing)?|adblock\s?plus|ublock|ads?\s*blocker|block(ing)?\s+ads|광고\s*차단|광고차단|광고\s*방지|애드\s*블록|애드블록|에드\s*블록|广告拦截|广告屏蔽|広告ブロック)/i;
        const asks = /(disable|turn\s*off|switch\s*off|deactivate|pause|white\s?list|allow\s+(ads|us|this)|해제|꺼\s*주|끄고|끄세요|꺼야|비활성|사용\s*중지|허용해|禁用|关闭|停用|無効|オフにし)/i;
        const area = r => Math.max(0, r.width) * Math.max(0, r.height);
        const vpArea = vw * vh;
        const chainOpacity = el => { let o = 1; for (let n = el, i = 0; n && i < 30; n = n.parentElement, i++) o *= parseFloat(getComputedStyle(n).opacity || '1'); return o; };
        const fixedCover = el => { let best = 0; for (let n = el, i = 0; n && n !== document.documentElement && i < 30; n = n.parentElement, i++) { if (getComputedStyle(n).position === 'fixed') best = Math.max(best, area(n.getBoundingClientRect())); } return best / vpArea; };
        const points = [[.5,.5],[.5,.3],[.5,.7],[.3,.5],[.7,.5]];
        const corners = [[.1,.1],[.9,.1],[.1,.9],[.9,.9]];
        let covered = 0;
        for (const [x, y] of corners) { const e = document.elementFromPoint(vw * x, vh * y); if (e && fixedCover(e) >= 0.6) covered++; }
        for (const [x, y] of points) {
          let el = document.elementFromPoint(vw * x, vh * y);
          for (let depth = 0; el && el !== document.body && el !== document.documentElement && depth < 14; el = el.parentElement, depth++) {
            const cs = getComputedStyle(el);
            if (!(cs.position === 'fixed' || cs.position === 'absolute' || cs.position === 'sticky')) continue;
            if (cs.display === 'none' || cs.visibility !== 'visible') continue;
            if (el.tagName === 'ARTICLE' || el.closest('article')) continue;
            const rect = el.getBoundingClientRect();
            const share = area(rect) / vpArea;
            if (share < 0.08) continue;
            if (!(share >= 0.5 || covered >= 3)) continue;
            if (chainOpacity(el) < 0.5) continue;
            if (el.querySelector('input[type=password]')) continue;
            const text = (el.innerText || '').replace(/\s+/g, ' ').trim();
            if (text.length < 20 || text.length > 1200) continue;
            if (named.test(text) && asks.test(text)) return true;
          }
        }
        return false;
      } catch (e) { return false; }
    })()
    """#

    private func detectAdWall(in wv: WKWebView) async -> Bool {
        do {
            let result = try await wv.evaluateJavaScript(Self.adWallDetectScript, contentWorld: .defaultClient)
            return (result as? Bool) == true
        } catch {
            return false
        }
    }

    /// Bounded: three checks (≈0.4 s, 2.2 s, 6.7 s after load finished) per document, each one script run.
    private static let adWallCheckGaps: [UInt64] = [400_000_000, 1_800_000_000, 4_500_000_000]

    private func scheduleAdWallChecks(for wv: WKWebView) {
        adWallTicket += 1
        let ticket = adWallTicket
        guard adWallEligible(wv), let url = wv.url else { return }
        let token = sessionToken
        let gen = generation
        Task { @MainActor [weak self, weak wv] in
            for gap in Self.adWallCheckGaps {
                try? await Task.sleep(nanoseconds: gap)
                guard let self = self, let wv = wv, self.adWallTicket == ticket, self.sessionToken == token,
                      self.generation == gen, self.webView === wv, wv.url == url, !wv.isLoading,
                      self.adWallEligible(wv) else { return }
                let hit = await self.detectAdWall(in: wv)
                guard self.adWallTicket == ticket, self.sessionToken == token, self.generation == gen,
                      self.webView === wv, wv.url == url else { return }
                if hit {
                    self.escalateAdWall(wv, url: url)
                    return
                }
            }
        }
    }

    /// One stage, one reload: normal → reduced (only if that set is materially different) → off for this tab/site.
    private func escalateAdWall(_ wv: WKWebView, url: URL) {
        guard let origin = Self.originKey(url), Self.createSafeGETRequest(for: url) != nil else { return }
        let next: BrowserAdBlockMode
        switch adBlockStage {
        case .full: next = BrowserAdBlocker.reducedIsDistinct ? .reduced : .off
        case .reduced: next = .off
        case .off: return
        }
        adWallTicket += 1
        let ticket = adWallTicket
        let gen = generation
        adWallOrigin = origin
        let token = sessionToken
        let proceed: () -> Void = { [weak self, weak wv] in
            guard let self = self, let wv = wv, self.adWallTicket == ticket, self.generation == gen,
                  self.webView === wv, self.sessionToken == token, wv.url == url, !wv.isLoading,
                  self.adWallOrigin == origin, self.adBlockPrefEnabled, !self.isShowingHome,
                  self.adWallEligible(wv) else { return }
            var stage = next
            // The reduced rules failed to compile: that would be "no rules" anyway, so say and do exactly that once.
            if stage == .reduced, BrowserAdBlocker.shared.compiledList(.reduced) == nil { stage = .off }
            self.adBlockStage = stage
            self.adWallNotice = stage == .reduced
                ? "이 사이트가 광고 차단 해제를 요구하는 안내창을 표시해, 이 탭에서만 일부 광고 차단을 줄여 한 번 다시 불러옵니다. 이 사이트를 벗어나면 원래대로 돌아갑니다."
                : "이 사이트가 광고 차단 해제를 계속 요구해, 이 탭의 이 사이트에서만 광고 차단을 잠시 끄고 한 번 다시 불러옵니다. 이 사이트를 벗어나면 원래대로 돌아가며, 전체 설정과 다른 탭은 바뀌지 않습니다."
            self.refreshAdBlock()
            self.pageStartedAt = Date()
            self.loadWhenAllowed(url, in: wv)
        }
        if next == .reduced, !BrowserAdBlocker.shared.isSettled(.reduced) {
            BrowserAdBlocker.shared.getRuleList(.reduced) { _ in proceed() }
        } else {
            proceed()
        }
    }

    /// Label of the tab strip: page title, else host, else a blank tab.
    var tabTitle: String {
        if isShowingHome { return "새 탭" }
        if !pageTitle.isEmpty { return pageTitle }
        if let host = currentURL?.host ?? URL(string: address)?.host ?? pendingURL?.host, !host.isEmpty { return host }
        return "새 탭"
    }

    /// Another tab (or nothing) became the active one. The page, history and candidates stay as they are; only
    /// automatic recovery that was prepared while this tab was active is dropped (it must not reload a hidden page).
    func didDeactivate() {
        activationEpoch += 1
        BrowserScreenshotManager.shared.cancelCapture(for: self)
        BrowserAdHideManager.shared.cancel(for: self, reapply: true)
        cancelScheduledRecovery()
    }

    /// The tab became visible (also called each time the browser screen appears; the activation epoch only changes
    /// in `didDeactivate`, so re-showing the same tab never drops its own pending recovery).
    func activate() {
        wanted = true
        if !hasStartedUp {
            hasStartedUp = true
            if let pending = pendingURL {
                isShowingHome = false
                prepare()
            } else {
                let prefs = appModel?.preferences
                if prefs?.startPageMode == .customURL, let custom = prefs?.customHomeURL, !custom.isEmpty {
                    isShowingHome = false
                    prepare()
                    open(custom)
                } else {
                    isShowingHome = true
                    prepare()
                }
            }
        } else {
            // Tab switch: preserve current state (page, session, or home)
            prepare()
        }
    }

    /// Builds the WebView only once the session store exists with the current connection policy applied.
    func prepare() {
        guard wanted, let app = appModel, webView == nil else { return }
        if blockedSubscription == nil { setupBlockedSubscription() }
        let route = pendingRoute ?? app.route(forHost: pendingURL?.host)
        let manager: ConnectionManager? = route == .assist ? app.prepareAssistRoute() : nil
        if let manager, !manager.isReady {
            // Fail closed: a page that needs the assist route never opens on the system connection instead.
            if manager === app.connection {
                postPendingNotice(manager.isStarting ? "HTTPS 연결 도움을 준비하는 중입니다. 준비되면 페이지가 열립니다."
                    : "HTTPS 연결 도움이 준비되지 않았습니다. 맨 위 'HTTPS 연결 도움' 옆 상태를 확인해 주세요.")
            } else {
                postPendingNotice(manager.isStarting ? "이 사이트용 HTTPS 연결 도움을 준비하는 중입니다. 준비되면 페이지가 열립니다."
                    : "이 사이트용 HTTPS 연결 도움이 준비되지 않아 페이지를 열지 않았습니다. 주소창 옆 연결 메뉴에서 다시 시작해 주세요.")
            }
            return
        }
        var proxy: ProxyConfiguration?
        if route == .assist {
            guard let configured = manager?.webProxyConfiguration() else {
                postPendingNotice("HTTPS 연결 도움 설정을 확인하지 못해 페이지를 열지 않았습니다.")
                return
            }
            proxy = configured
        }
        if app.session.isClearing {
            postPendingNotice("세션을 지우는 중입니다. 끝나면 페이지가 열립니다.")
            app.session.whenClearFinished { [weak self] in self?.prepare() }
            return
        }
        notice = nil
        recoveryInProgress = false
        let mode: Int? = manager?.generation
        let primary = app.isPrimaryRoute(route)
        let store: WKWebsiteDataStore
        if primary {
            if app.session.hasPrimaryStore && app.session.proxyGeneration != mode {
                // A store keeps the connection path it was created with: never reuse it under another mode. Other tabs
                // still hold views on that store, so they are reset first. The store is only detached, never wiped: the
                // fixed-identifier persistent store (and its cookies) is reopened below under the new connection policy.
                app.teardownOtherTabs(usingPrimaryStore: true, except: self)
                app.session.detachConnectionStore()
            }
            store = app.session.ensureStore(proxy: proxy, generation: mode)
        } else {
            if app.session.alternateStore != nil && app.session.alternateProxyGeneration != mode {
                app.teardownOtherTabs(usingPrimaryStore: false, except: self)
                app.session.detachAlternateStore()
            }
            store = app.session.ensureAlternateStore(proxy: proxy, generation: mode)
        }
        pendingRoute = nil
        sessionToken += 1
        safeRetryRequest = nil
        lastMainFrameURL = nil
        let config = WKWebViewConfiguration()
        config.websiteDataStore = store
        // Start with fresh WKPreferences with automatic false; enabled only on didCommit when exact URL allowed.
        config.preferences = WKPreferences()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.preferences.isElementFullscreenEnabled = true
        // The translation extension's controller is bound to the primary store only.
        if primary { app.extensions.attach(to: config, store: store) }
        installDiscovery(into: config)
        PageAudioController.shared.prepareConfiguration(config)
        let wv = LinkMenuWebView(frame: .zero, configuration: config)
        install(wv, mode: mode, route: route, primary: primary)
        // A new view starts at the normal stage; rules go onto this tab's own controller before its first load.
        resetAdWall()
        refreshAdBlock()
        if let url = pendingURL {
            pendingURL = nil
            loadWhenAllowed(url, in: wv)
        }
    }

    /// Gives `config` this tab's own user content controller: discovery script plus a message handler that targets
    /// this model only. Never registers on a controller another tab uses (a duplicate name would raise, and closing
    /// one tab would remove the other's handler).
    private func installDiscovery(into config: WKWebViewConfiguration) {
        ownedUCC = nil
        if let source = MediaDiscovery.scriptSource() {
            // Isolated world: page scripts can neither see nor call the handler.
            let world = WKContentWorld.world(name: MediaDiscovery.worldName)
            let ucc = WKUserContentController()
            ucc.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world))
            ucc.add(MediaScriptHandler(model: self, sessionToken: sessionToken), contentWorld: world,
                    name: MediaDiscovery.handlerName)
            ucc.addUserScript(YouTubeLink.dragScript)
            installLinkMenuCapture(into: ucc)
            AutoShorts.install(into: ucc, model: self)
            config.userContentController = ucc
            ownedUCC = ucc
            discoveryProblem = nil
        } else {
            let ucc = WKUserContentController()
            ucc.addUserScript(YouTubeLink.dragScript)
            installLinkMenuCapture(into: ucc)
            AutoShorts.install(into: ucc, model: self)
            config.userContentController = ucc
            discoveryProblem = "영상 찾기 기능을 불러오지 못했습니다. '현재 페이지 분석'은 그대로 쓸 수 있습니다."
        }
    }

    /// Right-click target capture (isolated world, all frames): the exact link of each trusted `contextmenu` event is
    /// reported before WebKit opens its native menu. Only this tab's own controller carries the handler.
    private func installLinkMenuCapture(into ucc: WKUserContentController) {
        SiteCredentialCapture.install(into: ucc, model: self)
        ucc.addUserScript(LinkMenuCapture.script)
        ucc.add(LinkMenuHandler(model: self, sessionToken: sessionToken), contentWorld: LinkMenuCapture.world,
                name: LinkMenuCapture.handlerName)
    }

    /// Only the isolated link-menu world of the current view of this tab may report; the payload is re-validated.
    func receiveLinkMenuMessage(_ message: WKScriptMessage, sessionToken token: Int) {
        guard token == sessionToken, let wv = webView as? LinkMenuWebView, message.webView === wv,
              message.world.name == LinkMenuCapture.worldName,
              let body = message.body as? [String: Any] else { return }
        var link: String? = nil
        if let raw = body["link"] as? String, raw.count <= 4096 { link = raw }
        guard let ms = (body["time"] as? NSNumber)?.doubleValue, ms.isFinite else { return }
        wv.receiveLinkCapture(link, page: body["page"] as? String, eventTime: ms / 1000,
                              origin: message.frameInfo.securityOrigin)
    }

    /// AutoShorts state queries from the main frame on YouTube.
    func receiveAutoShortsMessage(_ message: WKScriptMessage) {
        guard AutoShorts.isBundledInHTT else { return }
        guard message.frameInfo.isMainFrame else { return }
        guard let wv = webView, message.webView === wv else { return }
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }
        if type == "getState" {
            let enabled = AutoShorts.isEnabled
            wv.evaluateJavaScript("window.__htdAutoShorts?.setEnabled(\(enabled));", completionHandler: nil)
        }
    }

    private func install(_ wv: WKWebView, mode: Int?, route: BrowsingRoute, primary: Bool) {
        popupCommittedURL = nil
        viewRoute = route
        usesPrimaryStore = primary
        wv.customUserAgent = SessionManager.userAgent
        (wv as? LinkMenuWebView)?.owner = self
        wv.navigationDelegate = self
        wv.uiDelegate = self
        viewMode = mode
        observe(wv)
        webView = wv
        PageAudioController.shared.register(webView: wv, model: self)
        newDocument()
    }

    private var policyTicket = 0

    /// With connection assist on, navigation starts only after the helper confirmed the site policy; a failed or
    /// late confirmation leaves the page unopened with the reason shown (no direct fallback).
    private func loadWhenAllowed(_ url: URL, in wv: WKWebView) {
        // The first navigation waits (the compile always ends, with or without a list) until the desired rule list is
        // installed, so it is never started unprotected; the mode is re-read when the wait is over.
        loadTicket += 1
        let loadTick = loadTicket
        let mode = effectiveAdBlockMode
        if mode != .off, !BrowserAdBlocker.shared.isSettled(mode) {
            let token = sessionToken
            BrowserAdBlocker.shared.getRuleList(mode) { [weak self, weak wv] _ in
                guard let self = self, let wv = wv, self.webView === wv, self.sessionToken == token,
                      self.loadTicket == loadTick else { return }
                self.refreshAdBlock()
                self.startLoadWhenAllowed(url, in: wv, loadTick: loadTick)
            }
            return
        }
        startLoadWhenAllowed(url, in: wv, loadTick: loadTick)
    }

    private func startLoadWhenAllowed(_ url: URL, in wv: WKWebView, loadTick: Int) {
        guard let connection = routeConnection, connection.enabled else {
            wv.load(URLRequest(url: url))
            return
        }
        if connection.autoAllowPublicConfirmed {
            notice = nil
            pageStartedAt = Date()
            wv.load(URLRequest(url: url))
            return
        }
        policyTicket += 1
        let ticket = policyTicket
        recoveryInProgress = false
        postPendingNotice("연결 도움에 이 사이트 허용을 적용하는 중...")
        connection.awaitPolicyApplied { [weak self] problem in
            guard let self = self, self.policyTicket == ticket, self.loadTicket == loadTick, self.webView === wv else { return }
            self.notice = nil
            if let problem = problem {
                self.lastError = "페이지를 열지 않았습니다: " + problem
                return
            }
            self.pageStartedAt = Date()
            wv.load(URLRequest(url: url))
        }
    }

    /// "허용 후 다시 시도" in the browser: allows exactly the listed hosts (refused as not_allowed for this browser
    /// since the current page started loading), waits for the helper's acknowledgement, then reloads the page.
    func allowBlockedAndReload(_ list: [String]) {
        guard let connection = routeConnection, connection.enabled, connection.isReady,
              let wv = webView, !recoveryInProgress else { return }
        let needed = list.filter { !connection.covers(host: $0) }
        let sent = connection.allowExactHosts(needed)
        guard sent.count == needed.count else {
            lastError = "차단 기록이 바뀌어 일부 주소를 허용하지 않았습니다. 페이지를 새로 고친 뒤 다시 확인해 주세요."
            return
        }
        policyTicket += 1
        let ticket = policyTicket
        recoveryInProgress = true
        postPendingNotice("선택한 주소의 허용을 적용하는 중...")
        connection.awaitPolicyApplied { [weak self] problem in
            guard let self = self, self.policyTicket == ticket, self.webView === wv else { return }
            self.recoveryInProgress = false
            self.notice = nil
            if let problem = problem {
                self.lastError = "허용을 적용하지 못해 다시 불러오지 않았습니다: " + problem
                return
            }
            self.lastError = nil
            self.pageStartedAt = Date()
            if let safeReq = self.safeRetryRequest, self.currentMainFrameMethod == "GET" {
                wv.load(safeReq.request)
            } else if wv.url != nil {
                wv.reload()
            } else if let url = self.currentURL ?? URL(string: self.address) {
                wv.load(URLRequest(url: url))
            }
        }
    }

    func setupBlockedSubscription() {
        guard let app = appModel else {
            blockedSubscription = nil
            return
        }
        guard blockedSubscription == nil else { return }
        blockedSubscription = app.connection.$blocked
            .merge(with: app.browsingConnection.$blocked)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] blocked in
                self?.handleBlockedUpdate(blocked)
            }
    }

    private func startNewLogicalAttempt() {
        adWallTicket += 1
        loadTicket += 1
        logicalAttemptId += 1
        attemptRoundsUsed = 0
        attemptAllowedHosts.removeAll()
        recoveryProblem = nil
        isAutoReloading = false
        safeRetryRequest = nil
        chainOriginHost = nil
        lastMainFrameURL = nil
        currentNavigation = nil
        clearDirectRetryOffer()
        cancelScheduledRecovery()
    }

    private func clearDirectRetryOffer() {
        directRetryBinding = nil
        if directRetryOffer != nil {
            directRetryOffer = nil
            modeNotice = nil   // the offer's own explanation must not outlive its button
        }
    }

    func cancelScheduledRecovery() {
        scheduledRecoveryTask?.cancel()
        scheduledRecoveryTask = nil
        activeRecoveryTicket += 1
        recoveryInProgress = false
        recoveryStatus = nil
        isAutoReloading = false
    }

    func stopLoading() {
        recoveryEnabled = false
        stopEpoch += 1
        cancelScheduledRecovery()
        policyTicket += 1
        loadTicket += 1
        adWallTicket += 1
        currentNavigation = nil
        safeRetryRequest = nil
        clearDirectRetryOffer()
        isAutoReloading = false
        webView?.stopLoading()
        isLoading = false
        notice = nil
    }

    func reload() {
        startNewLogicalAttempt()
        recoveryEnabled = true
        webView?.reload()
    }

    /// Toolbar, Cmd+Left, Cmd+[ and mouse button 3 all end here and use the current WKWebView's own history; the
    /// published flags are only a mirror, so the live view decides (they can lag behind SPA/pushState changes).
    @discardableResult
    func goBack() -> Bool {
        guard let wv = webView, wv.canGoBack else { syncHistoryState(); return false }
        startNewLogicalAttempt()
        recoveryEnabled = true
        wv.goBack()
        return true
    }

    @discardableResult
    func goForward() -> Bool {
        guard let wv = webView, wv.canGoForward else { syncHistoryState(); return false }
        startNewLogicalAttempt()
        recoveryEnabled = true
        wv.goForward()
        return true
    }

    private func syncHistoryState() {
        canGoBack = webView?.canGoBack ?? false
        canGoForward = webView?.canGoForward ?? false
    }

    /// Hosts this page itself validated natively: its main document, embedded frames and media candidates.
    private func ownValidatedHosts() -> Set<String> {
        var hosts = Set<String>()
        func add(_ host: String?) {
            if let h = host?.lowercased(), !h.isEmpty { hosts.insert(h) }
        }
        add(currentURL?.host)
        add(webView?.url?.host)
        add(lastMainFrameURL?.host)
        for c in candidates {
            add(c.url?.host)
            add(c.pageURL.host)
            add(c.frameURL?.host)
            add(c.frameHost)
        }
        for frame in reportingFrames {
            add(frame.request.url?.host)
            add(frame.securityOrigin.host)
        }
        return hosts
    }

    /// The shared browser client tag ("web") cannot prove which tab caused a refusal. With one live page the refusals
    /// are this page's; with several, only hosts this page itself validated are attributed to it, the rest are left
    /// refused (never allowed on a guess).
    private func attributable(_ allowable: [String]) -> (ok: [String], unattributed: [String]) {
        guard let app = appModel, app.liveTabCount > 1 else { return (allowable, []) }
        let own = ownValidatedHosts()
        return (allowable.filter { own.contains($0) }, allowable.filter { !own.contains($0) })
    }

    private func handleBlockedUpdate(_ blocked: [ConnectionManager.BlockedHost]) {
        guard let connection = routeConnection, connection.enabled, connection.isReady else { return }
        if connection.autoAllowPublicConfirmed {
            // Under approved automatic public policy, authenticated public requests succeed directly
            // in the helper; no auto-reload loop or multi-tab attribution warning needed.
            return
        }
        guard recoveryEnabled, wanted, !isShowingHome, webView != nil else { return }
        // Only the tab the user is looking at recovers by itself; a background page keeps its state untouched.
        guard isCurrentActiveBrowser else { return }
        guard currentMainFrameMethod == "GET" else { return }
        guard !recoveryInProgress else { return }
        guard let safeReq = safeRetryRequest,
              safeReq.attemptId == logicalAttemptId,
              safeReq.sessionToken == sessionToken,
              safeReq.helperGeneration == connection.generation else { return }

        // Only consider fresh not_allowed records for browserClient ("web") since current page started
        let freshRefusals = connection.refusals(forClient: ConnectionManager.browserClient, since: pageStartedAt)
        guard !freshRefusals.isEmpty else { return }

        // Exact valid public DNS names only
        let allowable = Array(Set(freshRefusals.filter { $0.canAllow }.map { $0.host }))
        let candidatesNeeded = allowable.filter { !connection.covers(host: $0) && !attemptAllowedHosts.contains($0) }
        let attributed = attributable(candidatesNeeded)
        let needed = attributed.ok
        guard !needed.isEmpty else { return }

        // Budget check per logical attempt
        guard attemptRoundsUsed < Self.autoRecoveryMaxRounds else {
            recoveryProblem = "추가 주소 자동 허용 한도(최대 \(Self.autoRecoveryMaxRounds)회)에 도달해 멈췄습니다."
            return
        }
        guard attemptAllowedHosts.count + needed.count <= Self.autoRecoveryMaxHosts else {
            recoveryProblem = "추가 주소 자동 허용 한도(최대 \(Self.autoRecoveryMaxHosts)개)를 초과하여 더 이상 자동으로 허용하지 않았습니다."
            return
        }

        // Brief coalescing (~0.35s)
        scheduledRecoveryTask?.cancel()
        let attemptId = logicalAttemptId
        let token = sessionToken
        let helperGen = connection.generation
        let wv = webView
        let ticket = activeRecoveryTicket
        let epoch = activationEpoch

        scheduledRecoveryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard let self = self, !Task.isCancelled else { return }
            self.executeCoalescedRecovery(
                attemptId: attemptId,
                sessionToken: token,
                helperGeneration: helperGen,
                targetWebView: wv,
                ticket: ticket,
                activationEpoch: epoch
            )
        }
    }

    private func executeCoalescedRecovery(
        attemptId: Int,
        sessionToken: Int,
        helperGeneration: Int,
        targetWebView: WKWebView?,
        ticket: Int,
        activationEpoch epoch: Int
    ) {
        guard recoveryEnabled,
              self.activationEpoch == epoch, isCurrentActiveBrowser,
              let connection = routeConnection, connection.enabled, connection.isReady,
              self.logicalAttemptId == attemptId,
              self.sessionToken == sessionToken,
              connection.generation == helperGeneration,
              self.webView != nil, self.webView === targetWebView,
              self.activeRecoveryTicket == ticket,
              !self.isShowingHome,
              self.currentMainFrameMethod == "GET",
              let safeReq = self.safeRetryRequest,
              safeReq.attemptId == attemptId,
              safeReq.sessionToken == sessionToken,
              safeReq.helperGeneration == helperGeneration else {
            return
        }

        let fresh = connection.refusals(forClient: ConnectionManager.browserClient, since: self.pageStartedAt)
        let allowable = Array(Set(fresh.filter { $0.canAllow }.map { $0.host }))
        let candidatesNeeded = allowable.filter { !connection.covers(host: $0) && !self.attemptAllowedHosts.contains($0) }
        let attributed = attributable(candidatesNeeded)
        let needed = attributed.ok
        guard !needed.isEmpty else { return }

        guard self.attemptRoundsUsed < Self.autoRecoveryMaxRounds else {
            self.recoveryProblem = "추가 주소 자동 허용 한도(최대 \(Self.autoRecoveryMaxRounds)회)에 도달해 멈췄습니다."
            return
        }
        guard self.attemptAllowedHosts.count + needed.count <= Self.autoRecoveryMaxHosts else {
            self.recoveryProblem = "추가 주소 자동 허용 한도(최대 \(Self.autoRecoveryMaxHosts)개)를 초과하여 더 이상 자동으로 허용하지 않았습니다."
            return
        }

        let sent = connection.allowExactHosts(needed)
        guard !sent.isEmpty else { return }

        self.attemptAllowedHosts.formUnion(sent)
        self.attemptRoundsUsed += 1
        self.recoveryInProgress = true
        self.recoveryProblem = nil
        self.recoveryStatus = "추가 주소 연결을 자동으로 적용하고 페이지를 다시 불러오는 중... (\(self.attemptRoundsUsed)/\(Self.autoRecoveryMaxRounds))"

        policyTicket += 1
        let myPolicyTicket = policyTicket
        let recoveryTicket = self.activeRecoveryTicket
        let capturedStopEpoch = self.stopEpoch

        connection.awaitPolicyApplied { [weak self] problem in
            guard let self = self else { return }
            guard self.recoveryEnabled,
                  self.activationEpoch == epoch, self.isCurrentActiveBrowser,
                  self.stopEpoch == capturedStopEpoch,
                  self.logicalAttemptId == attemptId,
                  self.sessionToken == sessionToken,
                  self.webView === targetWebView,
                  self.activeRecoveryTicket == recoveryTicket,
                  self.policyTicket == myPolicyTicket,
                  !self.isShowingHome,
                  self.currentMainFrameMethod == "GET",
                  let safeReq = self.safeRetryRequest,
                  safeReq.attemptId == attemptId,
                  safeReq.sessionToken == sessionToken,
                  safeReq.helperGeneration == helperGeneration,
                  let currentConn = self.routeConnection,
                  currentConn.enabled, currentConn.isReady,
                  currentConn.generation == helperGeneration else {
                return
            }

            self.recoveryInProgress = false
            self.recoveryStatus = nil

            if let problem = problem {
                self.recoveryProblem = "추가 주소 허용을 적용하지 못했습니다: \(problem)"
                self.lastError = "허용을 적용하지 못해 다시 불러오지 않았습니다: " + problem
                return
            }

            self.lastError = nil
            self.pageStartedAt = Date()
            self.isAutoReloading = true
            if let wv = self.webView {
                wv.load(safeReq.request)
            }
        }
    }

    private final class WeakModel: @unchecked Sendable {
        weak var model: LoginBrowserModel?
        init(_ model: LoginBrowserModel) { self.model = model }
    }

    private nonisolated static func hop(_ ref: WeakModel, _ body: @escaping @MainActor (LoginBrowserModel) -> Void) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if let m = ref.model { body(m) }
            }
        }
    }

    private static func withoutFragment(_ url: URL?) -> String? {
        guard let url = url, var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        c.fragment = nil
        return c.string
    }

    private func observe(_ wv: WKWebView) {
        let ref = WeakModel(self)
        observations = [
            wv.observe(\.estimatedProgress) { v, _ in let p = v.estimatedProgress; Self.hop(ref) { if !$0.isShowingHome { $0.progress = p } } },
            wv.observe(\.isLoading) { v, _ in let l = v.isLoading; Self.hop(ref) { if !$0.isShowingHome { $0.isLoading = l; $0.appModel?.extensions.tabChanged($0, .loading) } } },
            wv.observe(\.title) { v, _ in let t = v.title ?? ""; Self.hop(ref) { if !$0.isShowingHome { $0.pageTitle = t; $0.appModel?.extensions.tabChanged($0, .title) } } },
            // Only the model's current view may update the mirrored flags (a replaced view must not leak its state).
            wv.observe(\.canGoBack) { v, _ in let vid = ObjectIdentifier(v); Self.hop(ref) { if let c = $0.webView, ObjectIdentifier(c) == vid { $0.canGoBack = c.canGoBack } } },
            wv.observe(\.canGoForward) { v, _ in let vid = ObjectIdentifier(v); Self.hop(ref) { if let c = $0.webView, ObjectIdentifier(c) == vid { $0.canGoForward = c.canGoForward } } },
            wv.observe(\.hasOnlySecureContent) { v, _ in let s = v.hasOnlySecureContent; Self.hop(ref) { $0.secureContent = s } },
            wv.observe(\.url) { v, _ in
                let u = v.url
                let vid = ObjectIdentifier(v)
                Self.hop(ref) { m in
                    guard let current = m.webView, ObjectIdentifier(current) == vid, !m.isShowingHome else { return }
                    let old = m.currentURL
                    m.currentURL = u
                    m.appModel?.extensions.tabChanged(m, .url)
                    if let u = u, ["http", "https"].contains(u.scheme?.lowercased() ?? "") {
                        m.address = u.absoluteString
                        m.appModel?.session.noteVisited(u)
                    }
                    // Same-document page change (history.pushState): the candidate list belongs to the old page.
                    if !m.isLoading, old != nil, Self.withoutFragment(old) != Self.withoutFragment(u) { m.newDocument() }
                    m.syncHistoryState()   // pushState changes the back list without always firing a canGoBack change
                }
            }
        ]
    }

    @discardableResult
    func openPlannerReport(_ artifact: SAWArtifact) -> Bool {
        guard let pid = sawProjectID, let fileURL = SAWReport.validatedURL(artifact, projectID: pid) else {
            return false
        }
        authorizedPlannerReportURL = fileURL
        authorizedExternalHTMLURL = nil
        startNewLogicalAttempt()
        wanted = true
        hasStartedUp = true
        isShowingHome = false
        pendingURL = nil
        prepare()
        guard let wv = webView else { return false }
        wv.stopLoading()
        address = "보고서"
        currentURL = fileURL
        pageTitle = artifact.title
        lastError = nil
        wv.loadFileURL(fileURL, allowingReadAccessTo: fileURL.deletingLastPathComponent())
        return true
    }

    @discardableResult
    func openExternalHTMLFile(_ fileURL: URL) -> Bool {
        guard fileURL.isFileURL else { return false }
        let standardized = fileURL.standardizedFileURL.resolvingSymlinksInPath()
        let path = standardized.path
        guard path.utf8.count <= 4096,
              !path.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
            return false
        }
        let ext = standardized.pathExtension.lowercased()
        guard ext == "html" || ext == "htm" || ext == "xhtml" else { return false }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else {
            return false
        }
        authorizedPlannerReportURL = nil
        authorizedExternalHTMLURL = standardized
        startNewLogicalAttempt()
        wanted = true
        hasStartedUp = true
        isShowingHome = false
        pendingURL = nil
        prepare()
        guard let wv = webView else { return false }
        wv.stopLoading()
        address = standardized.lastPathComponent
        currentURL = standardized
        pageTitle = standardized.lastPathComponent
        lastError = nil
        let documentDir = standardized.deletingLastPathComponent()
        let homePath = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.resolvingSymlinksInPath().path
        let docPath = documentDir.path
        let isBroadContainer = docPath == "/" || docPath == "/Users" || docPath == homePath
        let readAccessURL = isBroadContainer ? standardized : documentDir
        wv.loadFileURL(standardized, allowingReadAccessTo: readAccessURL)
        return true
    }

    func open(_ raw: String) {
        startNewLogicalAttempt()
        recoveryEnabled = true
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let fileURL = URL(string: trimmed), fileURL.isFileURL {
            if openExternalHTMLFile(fileURL) {
                return
            }
            lastError = "유효하지 않거나 접근할 수 없는 HTML 파일입니다."
            return
        }
        let candidate = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let url = URL(string: candidate), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil else {
            lastError = "http 또는 https 주소만 열 수 있습니다."
            return
        }
        authorizedPlannerReportURL = nil
        authorizedExternalHTMLURL = nil
        let route = routeForAddressEntry(url)
        if webView != nil, route != viewRoute {
            // The address needs the other route's store: this tab's view cannot change its connection path.
            rebuildView(route: route, url: url)
            return
        }
        openResolved(url, route: route, build: true)
    }

    /// A typed / bookmarked / home address starts fresh: the destination's explicit choice, else the global default.
    /// Re-entering an address of the very page that is open keeps that page's route (no silent change on Enter).
    private func routeForAddressEntry(_ url: URL) -> BrowsingRoute {
        guard let app = appModel else { return .direct }
        var inherited: BrowsingRoute?
        if webView != nil, !isShowingHome, directFallbackHost == nil, let current = currentURL?.host?.lowercased(),
           current == url.host?.lowercased() {
            inherited = viewRoute
        }
        return app.route(forHost: url.host, inherited: inherited)
    }

    /// Starts navigating to `url` on `route`. A live WebView must already be on that route.
    private func openResolved(_ url: URL, route: BrowsingRoute, build: Bool, userEntered: Bool = true) {
        discardStaleHomeView()
        lastError = nil
        modeNotice = nil
        wanted = true
        hasStartedUp = true
        isShowingHome = false
        address = url.absoluteString
        lastMainFrameURL = url
        currentMainFrameMethod = "GET"
        if chainOriginHost == nil { chainOriginHost = SiteRouteRules.normalizedHost(url.host) }
        let manager = appModel?.connectionManager(for: route)
        if let safeReq = Self.createSafeGETRequest(for: url) {
            safeRetryRequest = SafeRetryRequest(
                request: safeReq,
                url: url,
                attemptId: logicalAttemptId,
                sessionToken: sessionToken,
                helperGeneration: manager?.generation ?? 0,
                programmaticAddress: userEntered
            )
        } else {
            safeRetryRequest = nil
        }
        allowSite(url, route: route)
        if let wv = webView {
            loadWhenAllowed(url, in: wv)
        } else {
            pendingURL = url
            pendingRoute = route
            if build { prepare() }
        }
    }

    /// The address is one the user chose on purpose: allow its site on the global helper (as before) and, for the
    /// assist route while the global switch is off, on the browsing helper.
    private func allowSite(_ url: URL, route: BrowsingRoute) {
        guard let app = appModel else { return }
        app.connection.allowSite(forURL: url.absoluteString)
        if route == .assist, app.assistConnection !== app.connection {
            app.assistConnection.allowSite(forURL: url.absoluteString)
        }
    }

    /// A fresh tab (no view yet) that will open `url` on `route` once it is shown.
    func startOnRoute(_ url: URL, route: BrowsingRoute) {
        openResolved(url, route: route, build: false)
    }

    /// Replaces only this tab's WebView so `url` opens on `route` (the other store / connection path). Other tabs,
    /// the shared stores and running downloads are untouched. History of the replaced view does not carry over.
    /// Callers have already checked that the navigation is a plain GET that can be replayed.
    private func rebuildView(route: BrowsingRoute, url: URL, fallbackHost: String? = nil) {
        teardown()
        startNewLogicalAttempt()
        recoveryEnabled = true
        if let fallbackHost {
            // Armed before the load starts so the replay's first decidePolicyFor already sees the guard.
            directFallbackHost = fallbackHost
            directFallbackChain = true
            directFallbackURL = Self.withoutFragment(url)
        }
        // A rebuilt view (route switch for a link / redirect, or the fallback itself) is never a fresh user-entered address.
        openResolved(url, route: route, build: true, userEntered: false)
        modeNotice = "이 사이트는 \(route.label)(으)로 열도록 설정되어 있어 탭을 새 연결로 다시 열었습니다. 연결마다 로그인 저장소가 따로이고, 이전 이동 기록은 이어지지 않습니다."
    }

    /// A request may move to another store only if it is a plain GET without a body: nothing else is ever resent.
    static func isReplayable(_ request: URLRequest) -> Bool {
        let method = request.httpMethod?.uppercased() ?? "GET"
        guard method == "GET", request.httpBody == nil, request.httpBodyStream == nil,
              let url = request.url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host != nil, url.user == nil, url.password == nil else { return false }
        return true
    }

    // MARK: Site route (toolbar)

    /// Host the toolbar's site route control refers to: the page this tab shows.
    var routeSubjectHost: String? {
        guard !isShowingHome, webView != nil, let url = currentURL,
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return SiteRouteRules.normalizedHost(url.host)
    }

    /// Sets (on/off) or clears (nil) the explicit choice of the shown page's host, then moves this tab to the matching
    /// route when it is on another one. A page that cannot be replayed safely (POST result, ...) stays as it is and
    /// the choice applies from the next navigation; nothing is resent.
    func setSiteRoute(_ choice: SiteRouteChoice?) {
        guard let app = appModel, let host = routeSubjectHost, let url = currentURL else { return }
        switch app.siteRoutes.set(choice, forHost: host) {
        case .notRoutable:
            notice = "IP 주소, localhost, 내부망 주소 등에는 사이트별 연결 설정을 저장하지 않습니다."
            return
        case .limitReached:
            notice = "사이트별 연결 설정은 최대 \(SiteRouteRules.maxRules)개까지 저장할 수 있습니다."
            return
        case .saved, .cleared, .unchanged:
            break
        }
        let target = app.route(forHost: host)
        guard target != viewRoute else { return }
        guard currentMainFrameMethod == "GET" else {
            notice = "이 화면은 양식 제출 결과라 다른 연결로 안전하게 다시 열 수 없습니다. 설정은 저장했고, 이 사이트로 새로 이동할 때부터 적용됩니다."
            return
        }
        rebuildView(route: target, url: url)
    }

    /// Return to home: built-in home screen or configured custom start page.
    func goHome() {
        guard let app = appModel else {
            showBuiltInHome()
            return
        }
        let prefs = app.preferences
        if prefs.startPageMode == .customURL && !prefs.customHomeURL.isEmpty {
            discardStaleHomeView()
            open(prefs.customHomeURL)
        } else {
            showBuiltInHome()
        }
    }

    /// While the built-in home is shown, this tab's WKWebView is only hidden: it still holds the previous page's
    /// document. Leaving home for a new navigation must never reveal that frame before the new page commits, so the
    /// hidden view is dropped first and the navigation starts on a fresh, blank one. Only this tab's view goes; the
    /// shared stores (cookies, other tabs' history, downloads) are untouched. Normal back/forward and tab switches
    /// never pass here (they do not leave the home state).
    private func discardStaleHomeView() {
        guard isShowingHome, webView != nil else { return }
        let keepRecovery = recoveryEnabled
        teardown()
        recoveryEnabled = keepRecovery
        wanted = true
        hasStartedUp = true
    }

    /// Safely transitions to the built-in home screen (bookmark list), invalidating any outstanding
    /// navigation, helper policy wait, or pending load.
    func showBuiltInHome() {
        recoveryEnabled = false
        stopEpoch += 1
        wanted = true
        hasStartedUp = true
        pendingURL = nil
        policyTicket += 1
        loadTicket += 1
        adWallTicket += 1
        cancelScheduledRecovery()
        startNewLogicalAttempt()
        currentNavigation = nil
        safeRetryRequest = nil
        lastMainFrameURL = nil
        webView?.stopLoading()
        isShowingHome = true
        popupCommittedURL = nil
        address = ""
        isLoading = false
        progress = 0
        lastError = nil
        notice = nil
        pendingResponseCandidate = nil
        pendingResponseKind = nil
        committedMediaPage = nil
        cancelDiscoveryWindow()
    }

    /// Connection assist was turned on/off or restarted: the old WebView (and its session store) used the old path,
    /// so both are dropped and the page is reopened in a new session once the new path is ready.
    /// What a tab had open when the connection mode changed (AppModel snapshots every tab, clears the shared session
    /// once, then lets each tab reopen its own page).
    struct ModeSnapshot {
        let last: URL?
        let hadPage: Bool
        let hadSession: Bool
        let wasWanted: Bool
        let wasHome: Bool
        /// Route to carry over: a view on the alternate store (explicit rule or inherited route) keeps its route; a view on
        /// the primary store follows the default as before. A not-yet-built tab's pending route only when `carryPending`.
        let route: BrowsingRoute?
    }

    func captureModeSnapshot(carryPending: Bool = false) -> ModeSnapshot {
        cancelScheduledRecovery()
        startNewLogicalAttempt()
        let carried: BrowsingRoute? = webView != nil ? ((usesPrimaryStore || directFallbackHost != nil) ? nil : viewRoute) : (carryPending ? pendingRoute : nil)
        return ModeSnapshot(last: currentURL ?? pendingURL, hadPage: webView != nil || pendingURL != nil,
                            hadSession: appModel?.session.isAlive ?? false, wasWanted: wanted, wasHome: isShowingHome,
                            route: carried)
    }

    /// After the session was cleared (this tab is torn down): the active tab reopens its page in the new session as
    /// before; a background tab keeps its address and opens it when selected.
    func reopenAfterModeChange(_ s: ModeSnapshot, active: Bool) {
        guard s.hadPage || s.wasWanted else { return }
        let reopenURL: URL? = s.wasHome ? nil : s.last.flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }
        if let url = reopenURL {
            // An explicit choice for the destination wins; otherwise the carried (inherited) route is kept so a helper
            // restart never moves the page to another path; nil = the global default.
            let resolved = appModel?.route(forHost: url.host, inherited: s.route) ?? .direct
            appModel?.connection.allowSite(forURL: url.absoluteString)
            if let app = appModel, resolved == .assist, app.assistConnection !== app.connection {
                app.assistConnection.allowSite(forURL: url.absoluteString)
            }
            pendingURL = url
            pendingRoute = s.route == nil ? nil : resolved
            address = url.absoluteString
        }
        if active {
            wanted = true
            hasStartedUp = true
            isShowingHome = reopenURL == nil
            prepare()
        } else if reopenURL != nil {
            // activate() builds the view and opens the remembered address when this tab is selected.
            isShowingHome = false
        }
    }

    /// Compatibility entry of the former single browser: the mode change now covers every tab (see AppModel).
    func connectionModeChanged() {
        appModel?.connectionModeChangedForAllTabs()
    }

    /// Helper became ready or failed.
    func connectionStatusChanged() {
        if wanted && webView == nil && isCurrentActiveBrowser {
            prepare()
        } else if webView != nil, let app = appModel, let helper = routeConnection,
                  helper === app.browsingConnection, helper.isFailed {
            // The page keeps its proxy settings and fails closed; it is never moved to a direct connection by itself.
            modeNotice = "이 사이트용 HTTPS 연결 도움이 멈췄습니다. 직접 연결로 바꾸지 않았습니다. 주소창 옆 연결 메뉴에서 다시 시작해 주세요."
        }
    }

    /// Closing the tab (or a global reset): stops only this tab's own loading, callbacks and observations and
    /// invalidates its session token. The shared cookie store and the other tabs are not touched.
    func teardown() {
        googleFill.cancel()
        recoveryEnabled = false
        stopEpoch += 1
        cancelScheduledRecovery()
        startNewLogicalAttempt()
        observations = []
        if let wv = webView {
            wv.stopLoading()
            wv.navigationDelegate = nil
            wv.uiDelegate = nil
            // Silence the discarded page's audio natively; the completion handler keeps the view alive until
            // WebKit has applied the suspension, then releases it.
            wv.setAllMediaPlaybackSuspended(true) { _ = wv }
        }
        resetAdWall()
        ownedUCC?.removeAllScriptMessageHandlers()
        ownedUCC?.removeAllUserScripts()
        ownedUCC = nil
        awaitsHelperPolicyForFirstNavigation = false
        pendingRoute = nil
        webView = nil
        wanted = false
        hasStartedUp = false
        isShowingHome = true
        pendingURL = nil
        policyTicket += 1
        recoveryInProgress = false
        sessionToken += 1
        newDocument()
        cancelDiscoveryWindow()
        isLoading = false
        progress = 0
        currentURL = nil
        popupCommittedURL = nil
        currentNavigation = nil
        safeRetryRequest = nil
        directFallbackHost = nil
        directFallbackChain = false
        directFallbackURL = nil
        lastMainFrameURL = nil
        pageTitle = ""
        canGoBack = false
        canGoForward = false
        notice = nil
    }

    // MARK: Video candidates

    private func newDocument() {
        generation += 1
        candidates = []
        queuedJobs = [:]
        reportingFrames = []
        startDiscoveryWindow()
    }

    /// One bounded search window per document (and per manual "다시 찾기"): 12 s, extended in short steps (at most 3×5 s)
    /// only while the page is still loading. Restarted solely by a new document or a manual re-search, never by
    /// candidate/blob reports; cancelled on teardown/home; a stale generation or session never settles a newer page.
    private func startDiscoveryWindow() {
        discoveryTask?.cancel()
        discoveryPhase = .searching
        let gen = generation
        let token = sessionToken
        discoveryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.discoveryWindowNanos)
            var extensions = 0
            while let s = self, !Task.isCancelled, s.generation == gen, s.sessionToken == token,
                  s.isLoading, extensions < Self.discoveryMaxLoadExtensions {
                extensions += 1
                try? await Task.sleep(nanoseconds: Self.discoveryLoadExtensionNanos)
            }
            guard let s = self, !Task.isCancelled, s.generation == gen, s.sessionToken == token else { return }
            s.discoveryPhase = .settled
            s.discoveryTask = nil
        }
    }

    private func cancelDiscoveryWindow() {
        discoveryTask?.cancel()
        discoveryTask = nil
        reportingFrames = []
        discoveryPhase = .settled
    }

    /// Messages come only from the isolated discovery world; everything is re-validated here and bounded.
    func receiveMediaMessage(_ message: WKScriptMessage, sessionToken token: Int) {
        guard token == sessionToken, let wv = webView, message.webView === wv,
              message.world.name == MediaDiscovery.worldName,
              let page = wv.url, ["http", "https"].contains(page.scheme?.lowercased() ?? ""),
              let body = message.body as? [String: Any], body["type"] as? String == "media",
              let items = body["items"] as? [Any], items.count <= MediaDiscovery.maxItemsPerMessage else { return }
        let frame = message.frameInfo
        if frame.isMainFrame {
            // A late message from the previous top-level document is dropped.
            guard frame.request.url?.host?.lowercased() == page.host?.lowercased() else { return }
        }
        let frameHost = frame.securityOrigin.host
        // Trusted native value (not the message payload): the frame's own document is the media request's Referer source.
        var frameURL: URL? = nil
        if !frame.isMainFrame, let u = frame.request.url, ["http", "https"].contains(u.scheme?.lowercased() ?? ""), u.host != nil {
            frameURL = u
        }
        if !frame.isMainFrame, reportingFrames.count < Self.maxReportingFrames,
           !reportingFrames.contains(where: { $0 === frame || $0.request.url == frame.request.url }) {
            reportingFrames.append(frame)
        }
        for item in items {
            guard let d = item as? [String: Any],
                  let kind = d["kind"] as? String, kind.count < 16,
                  let source = d["source"] as? String, source == "element" || source == "resource" else { continue }
            let title = Self.cleanTitle(d["title"] as? String)
            let obsSource: MediaCandidate.ObservationSource = source == "element" ? .element : (source == "resource" ? .resource : .navigation)
            if kind == "blob" {
                if source == "element" {
                    addCandidate(url: nil, kind: .blob, title: title, isMainFrame: frame.isMainFrame, frameHost: frameHost, page: page, frameURL: frameURL, observationSource: obsSource)
                }
                continue
            }
            guard let raw = d["url"] as? String,
                  let valid = MediaDiscovery.validate(rawURL: raw, reportedKind: kind, source: source) else { continue }
            addCandidate(url: valid.0, kind: valid.1, title: title, isMainFrame: frame.isMainFrame, frameHost: frameHost, page: page, frameURL: frameURL, observationSource: obsSource)
        }
    }

    private static func cleanTitle(_ raw: String?) -> String {
        let s = String((raw ?? "").unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
        return redactPersistedText(String(s.trimmingCharacters(in: .whitespaces).prefix(200)))
    }

    private func addCandidate(url: URL?, kind: MediaCandidate.Kind, title: String, isMainFrame: Bool, frameHost: String, page: URL, frameURL: URL? = nil, observationSource: MediaCandidate.ObservationSource = .navigation) {
        let id = url?.absoluteString ?? "blob|\(frameHost)"
        let fallback = url.map { $0.lastPathComponent.isEmpty ? ($0.host ?? "영상") : $0.lastPathComponent } ?? "영상"
        if let idx = candidates.firstIndex(where: { $0.id == id }) {
            let existing = candidates[idx]
            guard url != nil, existing.url != nil else { return }
            guard existing.observationSource == .resource && observationSource == .element else { return }
            guard existing.url == url, existing.pageURL == page, existing.sessionToken == sessionToken, existing.generation == generation else {
                return
            }
            let resolvedKind: MediaCandidate.Kind
            if existing.kind == .element {
                resolvedKind = kind
            } else {
                resolvedKind = existing.kind
            }
            let oldTitle = existing.title
            let resolvedTitle: String
            if (oldTitle.isEmpty || oldTitle == fallback || oldTitle == "영상" || oldTitle == "내장 플레이어 영상") && !title.isEmpty && title != "영상" && title != "내장 플레이어 영상" {
                resolvedTitle = title
            } else {
                resolvedTitle = oldTitle
            }
            candidates[idx] = MediaCandidate(
                id: existing.id,
                url: existing.url,
                kind: resolvedKind,
                title: resolvedTitle,
                pageURL: existing.pageURL,
                isMainFrame: isMainFrame,
                frameHost: frameHost,
                frameURL: frameURL,
                observationSource: .element,
                sessionToken: existing.sessionToken,
                generation: existing.generation
            )
            return
        }
        guard candidates.count < MediaDiscovery.maxCandidates else { return }
        candidates.append(MediaCandidate(
            id: id, url: url, kind: kind, title: title.isEmpty ? fallback : title, pageURL: page,
            isMainFrame: isMainFrame, frameHost: frameHost, frameURL: frameURL, observationSource: observationSource, sessionToken: sessionToken, generation: generation))
    }

    /// "다시 찾기": clears the list, restarts the bounded search window and asks the discovery script of the main frame
    /// and of embedded frames that already reported to scan again (local page reads only; each runs a short burst).
    func rescan() {
        candidates = []
        lastError = nil
        startDiscoveryWindow()
        guard let wv = webView else { return }
        let world = WKContentWorld.world(name: MediaDiscovery.worldName)
        let js = "if (window.__hdScan) { window.__hdScan(); } 0;"
        wv.evaluateJavaScript(js, in: nil, in: world, completionHandler: nil)
        for frame in reportingFrames { wv.evaluateJavaScript(js, in: frame, in: world, completionHandler: nil) }
    }

    /// "MP4로 저장": queues the address into the normal extraction → quality → MP4 flow, bound to this page.
    /// Returns the job id, or nil with the reason in `lastError`.
    @discardableResult
    func saveCandidate(_ c: MediaCandidate) -> String? {
        guard c.sessionToken == sessionToken, c.generation == generation, webView != nil,
              let latest = candidates.first(where: { $0.id == c.id }),
              latest.sessionToken == sessionToken, latest.generation == generation,
              latest.url == c.url, latest.pageURL == c.pageURL else {
            lastError = "페이지가 바뀌었거나 세션이 새로 시작되어 이전 목록의 영상은 저장하지 않았습니다. 목록에서 다시 골라 주세요."
            return nil
        }
        guard latest.supported, let url = latest.url else {
            lastError = "이 영상은 페이지 안에서 조각을 이어 붙여 재생하는 방식이라 주소로 바로 받을 수 없습니다. 목록에 HLS/DASH 후보가 있으면 그것을 고르거나 '영상 찾아받기'를 눌러 보세요."
            return nil
        }
        if let existing = queuedJobs[latest.id], appModel?.jobs.contains(where: { $0.id == existing }) == true {
            notice = "이미 대기열에 추가한 영상입니다. 진행 상황은 '다운로드 > 진행 중'에서 볼 수 있습니다."
            return existing
        }
        guard let app = appModel, let jobId = app.addJobFromBrowserMedia(url, pageURL: latest.pageURL, refererURL: latest.frameURL, title: latest.title, route: viewRoute) else { return nil }
        queuedJobs[latest.id] = jobId
        lastError = nil
        notice = "대기열에 추가했습니다. 진행 상황은 '다운로드 > 진행 중'에서 볼 수 있습니다."
        return jobId
    }

    /// Supported candidates of the current list that are not yet queued, deduplicated by normalized address
    /// (scheme/host case and fragment ignored). Finite snapshot in list order; blob/unsupported are never included.
    var bulkSendableCandidates: [MediaCandidate] {
        var seen = Set<String>()
        var result: [MediaCandidate] = []
        for c in candidates where c.supported {
            guard let url = c.url else { continue }
            if let existing = queuedJobs[c.id], appModel?.jobs.contains(where: { $0.id == existing }) == true { continue }
            var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            comps?.fragment = nil
            let lowScheme = comps?.scheme?.lowercased()
            let lowHost = comps?.host?.lowercased()
            comps?.scheme = lowScheme
            comps?.host = lowHost
            let key = comps?.string ?? url.absoluteString
            guard seen.insert(key).inserted else { continue }
            result.append(c)
            if result.count >= 200 { break }
        }
        return result
    }

    /// "전체를 다운로드로 보내기": runs the per-item `saveCandidate` (same provenance checks, no recording intent)
    /// over a snapshot of the current list. The loop stops as soon as the session or page generation changes.
    func saveAllCandidates() {
        guard let app = appModel else { return }
        let snapshot = bulkSendableCandidates
        guard !snapshot.isEmpty else {
            app.setDropFeedback("다운로드로 보낼 수 있는 영상이 없습니다.")
            return
        }
        let token = sessionToken
        let gen = generation
        let jobIdsBefore = Set(app.jobs.map(\.id))
        var added = 0
        var skipped = 0
        var staleStop = false
        app.performQueueBatch {
            for c in snapshot {
                guard token == sessionToken, gen == generation else {
                    staleStop = true
                    break
                }
                if let id = saveCandidate(c), !jobIdsBefore.contains(id) {
                    added += 1
                } else {
                    skipped += 1
                }
            }
        }
        if staleStop {
            app.setDropFeedback("페이지가 바뀌어 전송을 중단했습니다. (\(added)개 추가)")
        } else if skipped > 0 {
            app.setDropFeedback("\(added)개 영상을 다운로드로 보냈습니다. (\(skipped)개 제외)")
        } else {
            app.setDropFeedback("\(added)개 영상을 다운로드로 보냈습니다.")
        }
    }

    /// "현재 페이지 분석": the existing yt-dlp page extraction with this session.
    func analyzePage() {
        guard let url = currentURL, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        appModel?.addJobFromLoginPage(url, route: viewRoute)
    }

    // MARK: WKNavigationDelegate

    /// A page the user deliberately opened from a link/pop-up on another site: with connection assist on, its site is
    /// allowed first (explicit user action, not a wildcard) and it is opened through the same proxy path.
    private func openUserInitiated(_ url: URL, in wv: WKWebView) -> Bool {
        guard let connection = routeConnection, connection.enabled, let host = url.host,
              !connection.covers(host: host) else { return false }
        if connection.autoAllowPublicConfirmed {
            return false
        }
        connection.allowSite(forURL: url.absoluteString)
        loadWhenAllowed(url, in: wv)
        return true
    }

    /// Route a destination must use regardless of what this page inherited: its explicit choice. On a view that is only
    /// on the system connection because of the direct fallback, only the one replay request (exact original address;
    /// every redirect is cancelled in decidePolicyFor) may stay there; every other destination, fresh navigation,
    /// reload and new tab goes back to the saved explicit choice or the normal default, so the fallback never spreads
    /// or outlives the one chain it was made for.
    func routeNeeded(forHost host: String?, app: AppModel, forNewTab: Bool = false) -> BrowsingRoute? {
        guard let fallbackHost = directFallbackHost else { return app.explicitRoute(forHost: host) }
        if !forNewTab, directFallbackChain, SiteRouteRules.normalizedHost(host) == fallbackHost { return nil }
        return app.explicitRoute(forHost: host) ?? app.defaultRoute
    }

    /// True when the helper recorded a policy refusal of this host since the page started, or cannot be consulted.
    private func hasPolicyRefusal(forHost host: String) -> Bool {
        let policyCodes: Set<String> = ["private_address", "not_allowed", "bad_host", "port_denied", "bad_request"]
        guard let helper = routeConnection else { return true }
        let records = helper.refusals(forClient: ConnectionManager.browserClient, since: pageStartedAt)
        return records.contains(where: { $0.host == host && policyCodes.contains($0.code) })
    }

    /// A provisional address navigation through connection assist failed to connect. Only an offer is recorded (a visible
    /// button); nothing is sent over the system connection until the user clicks it. Everything unproven fails closed.
    private func offerDirectRetry(_ error: Error, navigation: WKNavigation?) {
        clearDirectRetryOffer()
        guard let app = appModel, recoveryEnabled, let wv = webView,
              viewRoute == .assist, directFallbackHost == nil,
              let navigation, let current = currentNavigation, navigation === current,
              let retry = safeRetryRequest, retry.attemptId == logicalAttemptId, retry.sessionToken == sessionToken,
              retry.url.scheme?.lowercased() == "https", retry.request.httpMethod == "GET",
              currentMainFrameMethod == "GET",
              retry.request.httpBody == nil, retry.request.httpBodyStream == nil,
              retry.request.allHTTPHeaderFields?.isEmpty ?? true,
              retry.programmaticAddress, retry.url.user == nil, retry.url.password == nil,
              retry.url.query == nil, retry.url.port == nil || retry.url.port == 443,
              let host = SiteRouteRules.normalizedHost(retry.url.host), host == chainOriginHost,
              SiteRouteRules.isRoutable(host: host),
              app.explicitRoute(forHost: host) != .direct, app.route(forHost: host) == .assist else { return }
        let ns = error as NSError
        let connectionClass: Set<Int> = [NSURLErrorTimedOut, NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost,
                                         NSURLErrorNetworkConnectionLost, NSURLErrorDNSLookupFailed]
        guard ns.domain == NSURLErrorDomain, connectionClass.contains(ns.code),
              let failing = ns.userInfo[NSURLErrorFailingURLErrorKey] as? URL,
              Self.withoutFragment(failing) == Self.withoutFragment(retry.url) else { return }
        // The helper's records are only a negative signal (they cannot be bound to this one request): any policy refusal
        // of this host since the page started (private/loopback address, not allowed, bad host/port) means no offer.
        guard !hasPolicyRefusal(forHost: host) else { return }
        directRetryBinding = DirectRetryBinding(url: retry.url, host: host, attemptId: logicalAttemptId,
                                                sessionToken: sessionToken, navigation: navigation, view: wv)
        directRetryOffer = DirectRetryOffer(host: host)
        modeNotice = "연결 도움으로 \(host)을(를) 열지 못했습니다. 아래 버튼을 누르면 이 주소 하나만 연결 도움 없이(일반 연결로) 한 번 다시 엽니다. 연결 도움의 보호(사설망 차단 등)가 적용되지 않고, 이 사이트의 저장된 켜짐/꺼짐은 바뀌지 않으며, 다른 주소로 이동시키면 따라가지 않습니다. 쿠키·로그인 저장소는 따로입니다."
    }

    /// The "일반 연결로 한 번 다시 열기" button. Re-validates that the offer still belongs to the current attempt, session,
    /// view and failed navigation, consumes it first, then opens exactly the original address once on the system connection.
    func retryOnceDirect() {
        guard let binding = directRetryBinding, directRetryOffer != nil else { return }
        clearDirectRetryOffer()   // consumed: a second click or a later failure cannot reuse it
        guard let app = appModel, let wv = webView, binding.view === wv, !isShowingHome,
              binding.attemptId == logicalAttemptId, binding.sessionToken == sessionToken,
              let current = currentNavigation, current === binding.navigation,
              viewRoute == .assist, directFallbackHost == nil,
              app.explicitRoute(forHost: binding.host) != .direct, app.route(forHost: binding.host) == .assist else {
            modeNotice = nil
            return
        }
        // Late refusal events may have arrived after the offer was made: re-check just before reopening.
        guard !hasPolicyRefusal(forHost: binding.host) else {
            modeNotice = nil
            return
        }
        let url = binding.url
        rebuildView(route: .direct, url: url, fallbackHost: binding.host)
        modeNotice = "\(binding.host) 주소 하나를 연결 도움 없이 일반 연결로 한 번 다시 열었습니다. 이 사이트의 저장된 연결 설정(켜짐/꺼짐)은 바뀌지 않았고, 다시 불러오기·새 이동·새 탭은 원래 설정을 따릅니다. 다른 주소로 이동시키면 따라가지 않으며, 일반 연결은 로그인 저장소가 따로입니다."
    }

    /// The navigation's destination has an explicit choice for another route. A plain GET is cancelled here and reopened
    /// in a replacement view on the right store; anything else (POST, a body, credentials in the address) is cancelled
    /// and reported, never resent through a different connection.
    private func switchRouteForNavigation(_ action: WKNavigationAction, in wv: WKWebView, to route: BrowsingRoute,
                                          url: URL) -> WKNavigationActionPolicy {
        guard Self.isReplayable(action.request) else {
            let method = action.request.httpMethod?.uppercased() ?? "GET"
            lastError = "이 사이트는 \(route.label)(으)로 열도록 설정되어 있지만, 현재 연결에서 보낸 \(method) 요청은 다른 연결로 안전하게 다시 보낼 수 없어 열지 않았습니다. 주소를 직접 열어 주세요."
            return .cancel
        }
        let token = sessionToken
        Task { @MainActor [weak self, weak wv] in
            guard let self, let wv, self.webView === wv, self.sessionToken == token else { return }
            self.rebuildView(route: route, url: url)
        }
        return .cancel
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard webView === self.webView else { return .cancel }
        guard let url = navigationAction.request.url, let scheme = url.scheme?.lowercased() else { return .cancel }
        if url.scheme?.lowercased() == "file" {
            if navigationAction.targetFrame?.isMainFrame == true {
                if let authURL = authorizedPlannerReportURL,
                   let pid = sawProjectID,
                   url.standardizedFileURL.resolvingSymlinksInPath() == authURL.standardizedFileURL.resolvingSymlinksInPath(),
                   SAWReport.validatedURL(SAWArtifact(title: "", filename: authURL.lastPathComponent, fileURL: authURL.path), projectID: pid) == authURL {
                    return .allow
                }
                if let authExtURL = authorizedExternalHTMLURL,
                   url.standardizedFileURL.resolvingSymlinksInPath() == authExtURL.standardizedFileURL.resolvingSymlinksInPath() {
                    return .allow
                }
            }
            return .cancel
        }

        if authorizedPlannerReportURL != nil,
           navigationAction.navigationType == .linkActivated,
           let scheme = url.scheme?.lowercased(), (scheme == "http" || scheme == "https"),
           url.user == nil, url.password == nil {
            if let pid = sawProjectID {
                let session = sawWorkspace?.existingSession(for: pid)
                _ = session?.newTab(url: url)
            }
            return .cancel
        }

        if navigationAction.targetFrame == nil {
            // New-window request (target=_blank, window.open): not a navigation of this page. Only the scheme rules are
            // checked here; createWebViewWith makes the tab and WebKit performs the one request (method and body
            // included) there. Nothing is loaded into this view and this page's main-frame state stays untouched.
            if scheme == "https" || scheme == "http" { return .allow }
            if url.absoluteString == "about:blank" { return .allow }
            lastError = "이 브라우저에서는 http/https 웹 페이지만 열 수 있습니다. 다른 앱이나 파일을 여는 요청은 막았습니다."
            return .cancel
        }
        let isMain = navigationAction.targetFrame?.isMainFrame ?? true
        if isMain { clearDirectRetryOffer() }
        if isMain, directFallbackChain, Self.withoutFragment(url) != directFallbackURL {
            // Redirect (any host, scheme or port) during the one fallback replay: never followed on this connection.
            directFallbackChain = false
            lastError = "시스템 연결로 보낸 새 요청이 다른 주소로 이동시켜 열지 않았습니다. 이동하려면 주소를 직접 열어 주세요."
            return .cancel
        }
        if isMain { adWallWillNavigate(to: url) }
        if isMain, scheme == "http" || scheme == "https", let app = appModel,
           let needed = routeNeeded(forHost: url.host, app: app), needed != viewRoute {
            // Same-tab cross-site navigation (also the first real request of a pop-up that started on about:blank) to a
            // site with its own explicit choice: this view's store / proxy cannot serve it.
            return switchRouteForNavigation(navigationAction, in: webView, to: needed, url: url)
        }
        if isMain {
            if scheme == "https", let host = url.host, let session = appModel?.session {
                let store = webView.configuration.websiteDataStore
                await session.restoreSessionCookiesIfNeeded(forHost: host, store: store)
                guard webView === self.webView, self.appModel?.session === session else { return .cancel }
            }

            let method = navigationAction.request.httpMethod?.uppercased() ?? "GET"
            let methodChanged = method != currentMainFrameMethod
            let urlChanged = url != lastMainFrameURL
            currentMainFrameMethod = method

            var isExplicitUserNav = false
            if isAutoReloading {
                isAutoReloading = false
            } else if navigationAction.navigationType == .linkActivated
                        || navigationAction.navigationType == .backForward
                        || navigationAction.navigationType == .reload {
                startNewLogicalAttempt()
                recoveryEnabled = true
                isExplicitUserNav = true
            }

            if methodChanged || urlChanged || isExplicitUserNav {
                cancelScheduledRecovery()
                lastMainFrameURL = url
                let plainRequest = Self.isReplayable(navigationAction.request)
                    && navigationAction.request.value(forHTTPHeaderField: "Authorization") == nil
                    && navigationAction.request.value(forHTTPHeaderField: "Proxy-Authorization") == nil
                if plainRequest, chainOriginHost == nil { chainOriginHost = SiteRouteRules.normalizedHost(url.host) }
                if method == "GET", plainRequest, let safeReq = Self.createSafeGETRequest(for: url) {
                    safeRetryRequest = SafeRetryRequest(
                        request: safeReq,
                        url: url,
                        attemptId: logicalAttemptId,
                        sessionToken: sessionToken,
                        helperGeneration: routeConnection?.generation ?? 0,
                        programmaticAddress: false
                    )
                } else {
                    safeRetryRequest = nil
                }
            }
        }
        if scheme == "http" || scheme == "https" {
            if isMain && routeConnection != nil {
                if awaitsHelperPolicyForFirstNavigation {
                    // First http(s) request of a pop-up tab (also after an about:blank start): WebKit itself performs this
                    // one request (any method, same body) once the helper confirmed the policy for exactly this URL;
                    // nothing is loaded by hand or resent. The flag stays set until such a request was allowed.
                    guard let connection = routeConnection, connection.isReady,
                          url.user == nil, url.password == nil, let host = url.host, !host.isEmpty else {
                        lastError = "페이지를 열지 않았습니다: 연결 도움이 준비되지 않았거나 주소를 확인할 수 없습니다."
                        return .cancel
                    }
                    awaitsHelperPolicyForFirstNavigation = false
                    if connection.autoAllowPublicConfirmed {
                        notice = nil
                        pageStartedAt = Date()
                        return .allow
                    }
                    let token = sessionToken
                    let helperGen = connection.generation
                    let mode = viewMode
                    let requestURL = url
                    let requestMethod = navigationAction.request.httpMethod?.uppercased() ?? "GET"
                    policyTicket += 1
                    let ticket = policyTicket
                    postPendingNotice("연결 도움에 이 사이트 허용을 적용하는 중...")
                    connection.allowSite(forURL: requestURL.absoluteString)
                    let problem: String? = await withCheckedContinuation { cont in
                        connection.awaitPolicyApplied { cont.resume(returning: $0) }
                    }
                    guard self.webView === webView, sessionToken == token, policyTicket == ticket,
                          viewMode == mode, mode == helperGen,
                          let now = routeConnection, now.enabled, now.isReady, now.generation == helperGen,
                          navigationAction.request.url == requestURL,
                          (navigationAction.request.httpMethod?.uppercased() ?? "GET") == requestMethod else {
                        if self.webView === webView, sessionToken == token, policyTicket == ticket { awaitsHelperPolicyForFirstNavigation = true }
                        return .cancel
                    }
                    notice = nil
                    if let problem = problem {
                        awaitsHelperPolicyForFirstNavigation = true
                        lastError = "페이지를 열지 않았습니다: " + problem
                        return .cancel
                    }
                    pageStartedAt = Date()
                    return .allow
                }
                if navigationAction.navigationType == .linkActivated,
                   (navigationAction.request.httpMethod ?? "GET") == "GET", openUserInitiated(url, in: webView) {
                    return .cancel
                }
            }
            return .allow
        }
        if !isMain && ["about", "data", "blob"].contains(scheme) { return .allow }
        if isMain && scheme == "about" && url.absoluteString == "about:blank" { return .allow }
        lastError = "이 브라우저에서는 http/https 웹 페이지만 열 수 있습니다. 다른 앱이나 파일을 여는 요청은 막았습니다."
        return .cancel
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        guard webView === self.webView else { return .cancel }
        if navigationResponse.isForMainFrame, let url = navigationResponse.response.url,
           let kind = MediaDiscovery.kind(forMIME: navigationResponse.response.mimeType),
           let valid = MediaDiscovery.validate(rawURL: url.absoluteString, reportedKind: kind.rawValue, source: "element") {
            let clean = valid.0
            if navigationResponse.canShowMIMEType {
                // Becomes a candidate of the media page once it commits.
                pendingResponseCandidate = clean
                pendingResponseKind = valid.1
            } else {
                // Not displayable (e.g. MKV): offered from the page that linked to it, which stays open.
                addCandidate(url: clean, kind: valid.1, title: clean.lastPathComponent, isMainFrame: true,
                             frameHost: clean.host ?? "", page: currentURL ?? clean)
                notice = "이 영상 파일은 오른쪽 목록에서 'MP4로 저장'으로 받을 수 있습니다."
                return .cancel
            }
        }
        if navigationResponse.isForMainFrame && !navigationResponse.canShowMIMEType {
            lastError = "이 브라우저는 파일을 바로 내려받지 않습니다. 오른쪽 목록의 'MP4로 저장'이나 '현재 페이지 분석'을 사용해 주세요."
            return .cancel
        }
        return .allow
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        lastError = nil
        if webView === self.webView {
            popupCommittedURL = nil
            webView.configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
            guard !isShowingHome else { return }
            isShowingHome = false
            clearDirectRetryOffer()
            currentNavigation = navigation
            pageStartedAt = Date()
        }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard webView === self.webView, !isShowingHome else { return }
        guard navigation == nil || currentNavigation == nil || navigation === currentNavigation else { return }
        directFallbackChain = false
        clearDirectRetryOffer()
        isShowingHome = false
        BrowserAdHideManager.shared.cancel(for: self, reapply: false)
        newDocument()
        committedMediaPage = nil

        let committedURL = webView.url
        popupCommittedURL = committedURL
        // Dynamically update javaScriptCanOpenWindowsAutomatically for committed top-level opener
        let isCommittedAllowed = PopupSitePermissions.shared.isAllowed(url: committedURL)
        webView.configuration.preferences.javaScriptCanOpenWindowsAutomatically = isCommittedAllowed

        if let pending = pendingResponseCandidate, let kind = pendingResponseKind,
           Self.withoutFragment(webView.url) == pending.absoluteString {
            addCandidate(url: pending, kind: kind, title: pending.lastPathComponent, isMainFrame: true,
                         frameHost: pending.host ?? "", page: pending)
            committedMediaPage = pending
        }
        pendingResponseCandidate = nil
        pendingResponseKind = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let cur = currentURL {
            let standardizedCur = cur.standardizedFileURL.resolvingSymlinksInPath()
            if let authURL = authorizedPlannerReportURL,
               standardizedCur == authURL.standardizedFileURL.resolvingSymlinksInPath() {
                return
            }
            if let authExtURL = authorizedExternalHTMLURL,
               standardizedCur == authExtURL.standardizedFileURL.resolvingSymlinksInPath() {
                return
            }
        }
        guard webView === self.webView, !isShowingHome else { return }
        armGoogleFill()
        scheduleAdWallChecks(for: webView)
        BrowserAdHideManager.shared.reapply(for: self)
    }

    /// Arms the Google password step for the current view only (page finished, or the user just saved/enabled it).
    func armGoogleFill() {
        guard let webView = webView, !isShowingHome else { return }
        let token = sessionToken
        googleFill.onNotice = { [weak self] text in self?.notice = text }
        googleFill.pageFinished(in: webView) { [weak self, weak webView] in
            guard let self = self, let webView = webView else { return false }
            return self.webView === webView && self.sessionToken == token && !self.isShowingHome
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard webView === self.webView, !isShowingHome else { return }
        guard navigation == nil || currentNavigation == nil || navigation === currentNavigation else { return }
        directFallbackChain = false
        offerDirectRetry(error, navigation: navigation)
        report(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard webView === self.webView, !isShowingHome else { return }
        guard navigation == nil || currentNavigation == nil || navigation === currentNavigation else { return }
        directFallbackChain = false
        clearDirectRetryOffer()
        let ns = error as NSError
        // WebKitErrorDomain 204 ("plug-in handled load"): after a direct media response commits, WebKit hands the
        // stream to its built-in player and ends the frame load this way. Expected only for that committed media page.
        if ns.domain == "WebKitErrorDomain" && ns.code == 204, webView === self.webView,
           let media = committedMediaPage, Self.withoutFragment(webView.url) == media.absoluteString {
            return
        }
        report(error)
    }

    private func report(_ error: Error) {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        if ns.domain == "WebKitErrorDomain" && ns.code == 102 { return }   // frame load interrupted (policy cancel)
        guard recoveryEnabled else { return }
        var message = "페이지를 열지 못했습니다: \(ns.localizedDescription)"
        if let helper = routeConnection {
            if let problem = recoveryProblem {
                message += " (\(problem))"
            } else if helper.autoAllowPublicConfirmed != true {
                message += " HTTPS 연결 도움이 일부 연결을 막았거나 처리 중일 수 있습니다."
            }
        }
        lastError = redactPersistedText(message)
    }

    // MARK: WKUIDelegate

    /// Pop-up / target=_blank requests open in a NEW tab of this browser (http/https or an about:blank placeholder
    /// only). This page and its view are never navigated by the request: WebKit performs the one original request
    /// (method and body included) in the returned view. `javaScriptCanOpenWindowsAutomatically` is false by default,
    /// and enabled only when the committed top-level opener is allowlisted in PopupSitePermissions.
    /// The checks below add the app-level limits.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // Routed popup handling for SAW project tab pools (H3)
        if let onOpenSAWPopup = self.onOpenSAWPopup {
            guard webView === self.webView, let app = appModel else { return nil }

            let isAutomaticAllowed = webView.configuration.preferences.javaScriptCanOpenWindowsAutomatically
            if isAutomaticAllowed {
                guard let committed = popupCommittedURL,
                      let committedHost = committed.host, !committedHost.isEmpty,
                      let committedScheme = committed.scheme?.lowercased(),
                      committedScheme == "http" || committedScheme == "https",
                      PopupSitePermissions.shared.isAllowed(url: committed) else {
                    return nil
                }
                let sourceFrame = navigationAction.sourceFrame
                guard sourceFrame.isMainFrame else {
                    return nil
                }
                let origin = sourceFrame.securityOrigin
                guard origin.`protocol`.lowercased() == committedScheme,
                      origin.host.caseInsensitiveCompare(committedHost) == .orderedSame else {
                    return nil
                }
            }

            guard let url = navigationAction.request.url, let scheme = url.scheme?.lowercased() else { return nil }
            let isBlank = url.absoluteString == "about:blank"
            guard scheme == "http" || scheme == "https" || isBlank else {
                lastError = "이 브라우저에서는 http/https 웹 페이지만 열 수 있습니다. 다른 앱이나 파일을 여는 요청은 막았습니다."
                return nil
            }
            let targetURL = isBlank ? nil : url
            if let target = targetURL, let needed = routeNeeded(forHost: target.host, app: app, forNewTab: true), needed != viewRoute {
                guard Self.isReplayable(navigationAction.request) else {
                    let method = navigationAction.request.httpMethod?.uppercased() ?? "GET"
                    lastError = "새 창의 사이트는 \(needed.label)(으)로 열도록 설정되어 있지만, \(method) 요청은 다른 연결로 안전하게 다시 보낼 수 없어 열지 않았습니다."
                    return nil
                }
                // Open fresh tab on destination route inside SAW project pool without stealing ordinary browser
                if let pid = sawProjectID, let session = sawWorkspace?.sessions[pid] {
                    let newTab = session.newTab()
                    newTab.startOnRoute(target, route: needed)
                    newTab.activate()
                }
                return nil
            }
            let helper = routeConnection
            if let helper {
                guard helper.isReady else {
                    lastError = "HTTPS 연결 도움이 준비되지 않아 새 탭을 열지 않았습니다."
                    return nil
                }
            }
            let mode: Int? = helper?.generation
            let openerStore = usesPrimaryStore ? app.session.dataStore : app.session.alternateStore
            let openerStoreMode = usesPrimaryStore ? app.session.proxyGeneration : app.session.alternateProxyGeneration
            guard viewMode == mode, let openerStore, openerStoreMode == mode,
                  configuration.websiteDataStore === openerStore else {
                lastError = "연결 방식이나 세션이 바뀌어 새 탭을 열지 않았습니다. 주소를 다시 열어 주세요."
                return nil
            }
            return onOpenSAWPopup(self, configuration, targetURL)
        }

        // A stale, hidden or closed opener never spawns a tab.
        guard webView === self.webView, let app = appModel, app.tabs.contains(where: { $0 === self }),
              app.browser === self, app.selectedTab == .browser, !isShowingHome else { return nil }

        // Popup initiation check:
        // When automatic window.open is enabled on view preferences, WebKit permits automatic popups.
        // Guard popup creation using public sourceFrame API:
        // Require main frame, HTTP(S), sourceFrame.securityOrigin.host exactly matching the committed allowlisted host, same scheme.
        // Under the enabled gate, verify the allowlist again so removal applies immediately, and reject source mismatches.
        let isAutomaticAllowed = webView.configuration.preferences.javaScriptCanOpenWindowsAutomatically
        if isAutomaticAllowed {
            guard let committed = popupCommittedURL,
                  let committedHost = committed.host, !committedHost.isEmpty,
                  let committedScheme = committed.scheme?.lowercased(),
                  committedScheme == "http" || committedScheme == "https",
                  PopupSitePermissions.shared.isAllowed(url: committed) else {
                return nil
            }
            let sourceFrame = navigationAction.sourceFrame
            guard sourceFrame.isMainFrame else {
                return nil
            }
            let origin = sourceFrame.securityOrigin
            guard origin.`protocol`.lowercased() == committedScheme,
                  origin.host.caseInsensitiveCompare(committedHost) == .orderedSame else {
                return nil
            }
        }

        guard let url = navigationAction.request.url, let scheme = url.scheme?.lowercased() else { return nil }
        let isBlank = url.absoluteString == "about:blank"
        guard scheme == "http" || scheme == "https" || isBlank else {
            lastError = "이 브라우저에서는 http/https 웹 페이지만 열 수 있습니다. 다른 앱이나 파일을 여는 요청은 막았습니다."
            return nil
        }
        // Click handlers using window.open are .other, so navigation-type quotas also block user clicks.
        let targetURL = isBlank ? nil : url
        if let target = targetURL, let needed = routeNeeded(forHost: target.host, app: app, forNewTab: true), needed != viewRoute {
            // The destination's explicit choice outranks this page's route. WebKit's configuration for the new window is
            // bound to this page's store, so it cannot be used: a GET opens in a fresh tab on the right route (the page
            // gets no window handle); anything else is refused rather than resent through another connection.
            guard Self.isReplayable(navigationAction.request) else {
                let method = navigationAction.request.httpMethod?.uppercased() ?? "GET"
                lastError = "새 창의 사이트는 \(needed.label)(으)로 열도록 설정되어 있지만, \(method) 요청은 다른 연결로 안전하게 다시 보낼 수 없어 열지 않았습니다."
                return nil
            }
            if app.openRoutedTab(from: self, url: target, route: needed, keepOpenerSelected: isAutomaticAllowed) == nil {
                lastError = "새 탭을 열지 못했습니다. 열려 있는 탭을 닫고 다시 시도해 주세요."
            }
            return nil
        }
        // Unset destination: the new window inherits this page's effective route (runtime only, no choice is saved).
        let helper = routeConnection
        if let helper {
            guard helper.isReady else {
                lastError = "HTTPS 연결 도움이 준비되지 않아 새 탭을 열지 않았습니다."
                return nil
            }
        }
        // The new tab must run on the same store and connection mode as this page (never an old store under a new proxy).
        let mode: Int? = helper?.generation
        let openerStore = usesPrimaryStore ? app.session.dataStore : app.session.alternateStore
        let openerStoreMode = usesPrimaryStore ? app.session.proxyGeneration : app.session.alternateProxyGeneration
        guard viewMode == mode, let openerStore, openerStoreMode == mode,
              configuration.websiteDataStore === openerStore else {
            lastError = "연결 방식이나 세션이 바뀌어 새 탭을 열지 않았습니다. 주소를 다시 열어 주세요."
            return nil
        }
        guard let newTab = app.openPopupTab(from: self, configuration: configuration, targetURL: targetURL,
                                            mode: mode, route: viewRoute, primaryStore: usesPrimaryStore,
                                            keepOpenerSelected: isAutomaticAllowed) else {
            return nil
        }
        return newTab.webView
    }

    /// `window.close()` of a page this tab shows: closes this tab only.
    func webViewDidClose(_ webView: WKWebView) {
        guard webView === self.webView else { return }
        if let onCloseSAWTab = self.onCloseSAWTab {
            onCloseSAWTab(self)
            return
        }
        guard let app = appModel, app.tabs.contains(where: { $0 === self }) else { return }
        app.closeTab(tabID)
    }

    /// Pop-up tab: adopts a view created from WebKit's own configuration for the opener's request. The configuration
    /// object (process pool, data store, opener relation) is used as given; only its user content controller is
    /// replaced by this tab's own, so no handler is shared with or removed from the opener. Returns nil (nothing
    /// adopted) when the controller could not be made separate.
    func adoptPopup(configuration: WKWebViewConfiguration, openerUCC: WKUserContentController?, targetURL: URL?,
                    mode: Int?, route: BrowsingRoute, primaryStore: Bool) -> WKWebView? {
        guard webView == nil, let app = appModel else { return nil }
        sessionToken += 1
        recoveryEnabled = true
        // Start with fresh WKPreferences with automatic false; enabled only on didCommit when exact URL allowed.
        configuration.preferences = WKPreferences()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.preferences.isElementFullscreenEnabled = true
        if primaryStore { app.extensions.attach(to: configuration, store: configuration.websiteDataStore) }
        installDiscovery(into: configuration)
        guard configuration.userContentController !== openerUCC else {
            ownedUCC = nil
            sessionToken += 1
            return nil
        }
        PageAudioController.shared.prepareConfiguration(configuration)
        wanted = true
        hasStartedUp = true
        isShowingHome = false
        let wv = LinkMenuWebView(frame: .zero, configuration: configuration)
        install(wv, mode: mode, route: route, primary: primaryStore)
        resetAdWall()
        refreshAdBlock()
        if let url = targetURL { address = url.absoluteString }
        // Also for an about:blank start: the first real http(s) request waits for its own exact allow + acknowledgement
        // inside its policy decision (see decidePolicyFor); no site is allowed here in advance. A first request whose
        // site has an explicit choice for another route is moved to a replacement view there before this wait applies.
        if routeConnection != nil { awaitsHelperPolicyForFirstNavigation = true }
        return wv
    }
}

/// Right-click link capture. A user script in an isolated world (all frames, page scripts cannot see it) listens for
/// TRUSTED `contextmenu` events (`event.isTrusted`, so page-made events cannot forge a link) and reports the link of
/// the exact event target (`composedPath`, shadow roots and YouTube cards included) before WebKit opens its menu.
/// Same-origin frames are reported; a cross-origin frame reports "no link" (fail closed). Nothing is recomputed from
/// coordinates later, so layout shifts (notice banner, scroll, page zoom) cannot change the target.
enum LinkMenuCapture {
    static let worldName = "HttpsDownLinkMenu"
    static let handlerName = "htdLinkMenu"
    static let world = WKContentWorld.world(name: worldName)

    static var script: WKUserScript {
        let source = """
        (function () { try {
          if (window.__htdLinkMenuCapture) return; window.__htdLinkMenuCapture = true;
          \(YouTubeLink.functions)
          function sameOriginChain() {
            try { var w = window; for (var i = 0; i < 8 && w !== w.top; i++) { w = w.parent; void w.document.body; } return w === w.top; }
            catch (e) { return false; }
          }
          window.addEventListener('contextmenu', function (e) {
            if (!e.isTrusted) return;
            var link = null, page = null, time = 0;
            try { page = window.top.location.href; } catch (err) { page = null; }
            try {
              var ts = e.timeStamp;
              time = ts > 1e12 ? ts : ((performance.timeOrigin || (Date.now() - performance.now())) + ts);
            } catch (err) { time = 0; }
            try {
              if (sameOriginChain()) {
                var path = e.composedPath ? e.composedPath() : [e.target];
                if (htdYTHost.test(location.hostname)) link = htdYTNode(path[0]);
                for (var i = 0; !link && i < path.length && i < 60; i++) {
                  var n = path[i];
                  if (n && n.nodeType === 1 && n.tagName === 'A' && n.getAttribute('href') !== null) {
                    var raw = (typeof n.href === 'string') ? n.href : n.getAttribute('href');
                    link = new URL(raw, n.baseURI).href;
                    break;
                  }
                }
              }
            } catch (err) { link = null; }
            try { window.webkit.messageHandlers.\(handlerName).postMessage({ link: link, page: page, time: time }); } catch (err) {}
          }, true);
        } catch (e) {} })();
        """
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world)
    }
}

final class LinkMenuHandler: NSObject, WKScriptMessageHandler {
    weak var model: LoginBrowserModel?
    let sessionToken: Int

    init(model: LoginBrowserModel, sessionToken: Int) {
        self.model = model
        self.sessionToken = sessionToken
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        model?.receiveLinkMenuMessage(message, sessionToken: sessionToken)
    }
}

/// WKWebView that adds one native item, '링크를 다운로드로 보내기', to WebKit's own context menu through the public
/// `NSView.willOpenMenu(_:with:)` hook (all original WebKit items stay). The link is the one `LinkMenuCapture`
/// reported for THIS right click (it must be newer than the native mouse event, fresh, for the same page, and is
/// consumed once). A report that has not arrived yet enables the item when it does; if none comes the item is hidden.
/// A closed menu, a newer click, a navigation or a replaced view drops late results. The address is checked again
/// with URLDropValidator and goes through `addJobs(from:)` unchanged.
final class LinkMenuWebView: WKWebView {
    weak var owner: LoginBrowserModel?
    private static let itemID = NSUserInterfaceItemIdentifier("com.hanstree.HttpsDown.sendLinkToDownloads")
    private struct Capture { let link: String?; let page: URL; let eventTime: TimeInterval; let uptime: TimeInterval }
    private static let eventTolerance: TimeInterval = 0.5
    private var clickGeneration = 0
    private var resolvedLink: String?
    private var resolvedPage: URL?
    private var capture: Capture?
    private weak var pendingItem: NSMenuItem?
    private var pendingEventTime: TimeInterval = 0
    private var pendingPage: URL?

    // Mouse gestures tracking
    private var deferredRightMouseDownEvent: NSEvent?
    private var isGestureTracking = false
    private var gesturePoints: [CGPoint] = []
    private var gestureTrailLayer: CAShapeLayer?
    private var gestureTrailPath: CGMutablePath?

    private func clearGestureTrail() {
        gestureTrailLayer?.removeFromSuperlayer()
        gestureTrailLayer = nil
        gestureTrailPath = nil
        gesturePoints.removeAll(keepingCapacity: false)
    }

    private func appendGestureTrailPoint(_ pt: CGPoint, startPt: CGPoint) {
        if gesturePoints.isEmpty {
            gesturePoints.append(startPt)
        }
        if let last = gesturePoints.last {
            let ddx = pt.x - last.x
            let ddy = pt.y - last.y
            if (ddx * ddx + ddy * ddy) >= 4.0 {
                if gesturePoints.count < 256 {
                    gesturePoints.append(pt)
                }
            }
        }
        let dx = pt.x - startPt.x
        let dy = pt.y - startPt.y
        if gestureTrailPath == nil {
            guard (dx * dx + dy * dy) >= 16.0 else { return }
            let path = CGMutablePath()
            path.move(to: startPt)
            path.addLine(to: pt)
            gestureTrailPath = path

            let layer = CAShapeLayer()
            layer.fillColor = nil
            layer.strokeColor = NSColor.controlAccentColor.withAlphaComponent(0.85).cgColor
            layer.lineWidth = 3.5
            layer.lineCap = .round
            layer.lineJoin = .round
            layer.path = path
            layer.frame = bounds
            layer.zPosition = 1000

            self.wantsLayer = true
            self.layer?.addSublayer(layer)
            gestureTrailLayer = layer
        } else if let path = gestureTrailPath, let layer = gestureTrailLayer {
            path.addLine(to: pt)
            layer.path = path
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            clearGestureTrail()
            isGestureTracking = false
            deferredRightMouseDownEvent = nil
        }
    }

    private func replayDeferredRightClick(downEvent: NSEvent, upEvent: NSEvent, expectedURL: URL?, expectedWindow: NSWindow) {
        guard let app = owner?.appModel,
              app.selectedTab == .browser,
              app.browser === owner,
              owner?.webView === self,
              let win = window,
              win === expectedWindow,
              win.isKeyWindow || NSApp.keyWindow === win,
              !(win is NSPanel),
              let currentURL = url,
              currentURL == expectedURL else {
            return
        }
        super.rightMouseDown(with: downEvent)
        super.rightMouseUp(with: upEvent)
    }

    override func rightMouseDown(with event: NSEvent) {
        clearGestureTrail()
        guard let app = owner?.appModel,
              app.preferences.mouseGesturesEnabled,
              app.selectedTab == .browser,
              app.browser === owner,
              owner?.webView === self,
              let win = window,
              win.isKeyWindow || NSApp.keyWindow === win,
              !(win is NSPanel),
              url != nil,
              !isLoading else {
            deferredRightMouseDownEvent = nil
            isGestureTracking = false
            super.rightMouseDown(with: event)
            return
        }

        let loc = convert(event.locationInWindow, from: nil)
        guard bounds.contains(loc) else {
            deferredRightMouseDownEvent = nil
            isGestureTracking = false
            super.rightMouseDown(with: event)
            return
        }

        deferredRightMouseDownEvent = event
        isGestureTracking = true
        gesturePoints = [CGPoint(x: loc.x, y: isFlipped ? loc.y : (bounds.height - loc.y))]
    }

    override func rightMouseDragged(with event: NSEvent) {
        guard isGestureTracking, let downEvent = deferredRightMouseDownEvent else {
            super.rightMouseDragged(with: event)
            return
        }

        let startPt = convert(downEvent.locationInWindow, from: nil)
        let currPt = convert(event.locationInWindow, from: nil)
        appendGestureTrailPoint(currPt, startPt: startPt)
    }

    override func rightMouseUp(with event: NSEvent) {
        guard isGestureTracking, let downEvent = deferredRightMouseDownEvent else {
            clearGestureTrail()
            isGestureTracking = false
            deferredRightMouseDownEvent = nil
            super.rightMouseUp(with: event)
            return
        }

        let trackedPoints = gesturePoints
        clearGestureTrail()
        isGestureTracking = false
        deferredRightMouseDownEvent = nil

        let startRaw = convert(downEvent.locationInWindow, from: nil)
        let endRaw = convert(event.locationInWindow, from: nil)
        let startPt = CGPoint(x: startRaw.x, y: isFlipped ? startRaw.y : (bounds.height - startRaw.y))
        let endPt = CGPoint(x: endRaw.x, y: isFlipped ? endRaw.y : (bounds.height - endRaw.y))
        let endInView = bounds.contains(endRaw)

        var pointsForRecognition = trackedPoints
        if pointsForRecognition.isEmpty {
            pointsForRecognition = [startPt, endPt]
        } else if let last = pointsForRecognition.last, last != endPt {
            pointsForRecognition.append(endPt)
        }

        let direction = endInView ? MouseGestureRecognizer.recognizeGesture(points: pointsForRecognition) : nil

        guard let recognizedDirection = direction else {
            if let targetWin = window, let currentURL = url {
                DispatchQueue.main.async { [weak self] in
                    self?.replayDeferredRightClick(downEvent: downEvent, upEvent: event, expectedURL: currentURL, expectedWindow: targetWin)
                }
            }
            return
        }

        guard let currentOwner = owner,
              let app = currentOwner.appModel,
              app.preferences.mouseGesturesEnabled,
              app.selectedTab == .browser,
              app.browser === currentOwner,
              currentOwner.webView === self,
              let startWin = window,
              startWin.isKeyWindow || NSApp.keyWindow === startWin,
              !(startWin is NSPanel),
              let startURL = url,
              !isLoading,
              bounds.contains(startRaw),
              endInView else {
            return
        }

        let startDocGen = currentOwner.generation
        let zoom = Double(pageZoom > 0 ? pageZoom : 1.0)
        let startPageX = Double(startPt.x) / zoom
        let startPageY = Double(startPt.y) / zoom

        let probeJS = """
        (function() {
            try {
                var x = \(startPageX);
                var y = \(startPageY);
                var el = document.elementFromPoint(x, y);
                if (!el) return false;
                var curr = el;
                while (curr && curr !== document.documentElement && curr !== document.body) {
                    var tag = (curr.tagName || '').toUpperCase();
                    if (tag === 'INPUT' || tag === 'SELECT' || tag === 'TEXTAREA' || tag === 'IFRAME') return false;
                    if (curr.isContentEditable) return false;
                    curr = curr.parentElement;
                }
                var sel = window.getSelection();
                if (sel && sel.rangeCount > 0 && !sel.isCollapsed && sel.toString().length > 0) return false;
                return true;
            } catch (e) {
                return false;
            }
        })()
        """

        evaluateJavaScript(probeJS) { [weak self] res, _ in
            guard let self = self,
                  let allowed = res as? Bool, allowed,
                  let currentOwner = self.owner,
                  currentOwner.generation == startDocGen,
                  let currentApp = currentOwner.appModel,
                  currentApp.preferences.mouseGesturesEnabled,
                  currentApp.selectedTab == .browser,
                  currentApp.browser === currentOwner,
                  currentOwner.webView === self,
                  let currentWin = self.window,
                  currentWin === startWin,
                  currentWin.isKeyWindow || NSApp.keyWindow === currentWin,
                  !(currentWin is NSPanel),
                  let currentURL = self.url,
                  currentURL == startURL,
                  !self.isLoading,
                  self.bounds.contains(endRaw) else {
                return
            }

            switch recognizedDirection {
            case .left:
                self.owner?.goBack()
            case .right:
                self.owner?.goForward()
            case .shake:
                self.owner?.reload()
            case .closeTab:
                currentApp.closeTab(currentOwner.tabID)
            case .up:
                self.evaluateJavaScript("window.scrollTo({top: 0, behavior: 'smooth'});", completionHandler: nil)
            case .down:
                let scrollDownJS = """
                (function() {
                    var doc = document.scrollingElement || document.documentElement || document.body;
                    var h = doc ? doc.scrollHeight : 0;
                    window.scrollTo({top: h, behavior: 'smooth'});
                })()
                """
                self.evaluateJavaScript(scrollDownJS, completionHandler: nil)
            }
        }
    }

    /// Wall-clock creation time of a native event (`NSEvent.timestamp` counts system uptime).
    private static func wallTime(of event: NSEvent) -> TimeInterval {
        Date().timeIntervalSince1970 - (ProcessInfo.processInfo.systemUptime - event.timestamp)
    }

    /// `page` is the main-page address the script saw (nil: cross-origin, unverifiable), `eventTime` the page event's
    /// creation time (epoch seconds). A report for another document, another origin, or a stale/future time is dropped
    /// or, for a foreign origin, turned into "no link"; it never carries an older link forward.
    func receiveLinkCapture(_ link: String?, page: String?, eventTime: TimeInterval, origin: WKSecurityOrigin) {
        guard let current = url, owner?.webView === self else { return }
        let now = Date().timeIntervalSince1970
        guard eventTime <= now + 1, now - eventTime < 3 else { return }
        var link = link
        if let page = page {
            guard page == current.absoluteString else { return }
        } else {
            link = nil
        }
        if origin.`protocol`.lowercased() != current.scheme?.lowercased() || origin.host.lowercased() != current.host?.lowercased()
            || origin.port != (current.port ?? 0) {
            link = nil
        }
        let c = Capture(link: link, page: current, eventTime: eventTime, uptime: ProcessInfo.processInfo.systemUptime)
        if let item = pendingItem, c.page == pendingPage, abs(eventTime - pendingEventTime) <= Self.eventTolerance {
            pendingItem = nil
            apply(c.link, page: c.page, to: item)
        } else {
            capture = c
        }
    }

    private func apply(_ raw: String?, page: URL, to item: NSMenuItem) {
        guard owner?.webView === self, url == page else { item.isHidden = true; return }
        if let raw = raw, let valid = URLDropValidator.validateSingleURL(raw) {
            resolvedLink = valid
            resolvedPage = url
            // The item itself carries the exact link it was resolved for; the action only accepts that one.
            item.representedObject = valid
            item.action = #selector(LinkMenuWebView.sendLinkToDownloads(_:))
            item.isEnabled = true
            item.isHidden = false
        } else {
            item.isHidden = true
        }
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        clickGeneration += 1
        let generation = clickGeneration
        resolvedLink = nil
        resolvedPage = nil
        pendingItem = nil
        // A reused menu object must never collect a second copy of our item from an earlier click.
        for old in menu.items where old.identifier == Self.itemID { menu.removeItem(old) }
        for old in menu.items where old.identifier == AutoShorts.menuItemID { menu.removeItem(old) }

        let credentialItemID = NSUserInterfaceItemIdentifier("com.hanstree.HttpsDown.fillSavedAccount")
        for old in menu.items where old.identifier == credentialItemID { menu.removeItem(old) }
        if let model = owner, let app = model.appModel, app.selectedTab == .browser,
           app.browser === model, model.webView === self,
           SiteCredentialCapture.isCommittedDocument(url, committedURL: model.popupCommittedURL),
           let origin = SiteCredentialStore.canonicalOrigin(for: url),
           SiteCredentialStore.hasSavedCredential(forOrigin: origin) {
            let fillItem = NSMenuItem(title: "저장된 계정 채우기",
                                      action: #selector(fillSavedAccount), keyEquivalent: "")
            fillItem.identifier = credentialItemID
            fillItem.target = self
            menu.addItem(fillItem)
        }

        if AutoShorts.isBundledInHTT, AutoShorts.isShortsURL(url) {
            let shortsItem = NSMenuItem(
                title: AutoShorts.isEnabled ? "YouTube Shorts 자동 넘김 (켬)" : "YouTube Shorts 자동 넘김 (끔)",
                action: #selector(toggleAutoShorts(_:)),
                keyEquivalent: ""
            )
            shortsItem.identifier = AutoShorts.menuItemID
            shortsItem.target = self
            shortsItem.state = AutoShorts.isEnabled ? .on : .off
            shortsItem.isEnabled = true
            shortsItem.isHidden = false
            menu.addItem(shortsItem)
        }
        // One app download item: WebKit's own '링크된 파일 다운로드' item is reused (retitled, re-targeted, no WKDownload);
        // only when it is absent is one custom item added.
        let item: NSMenuItem
        if let native = menu.items.first(where: { $0.identifier?.rawValue == "WKMenuItemIdentifierDownloadLinkedFile" }) {
            item = native
            item.title = "링크를 다운로드로 보내기"
            item.identifier = Self.itemID
        } else {
            item = NSMenuItem(title: "링크를 다운로드로 보내기", action: nil, keyEquivalent: "")
            item.identifier = Self.itemID
            menu.addItem(item)
        }
        item.target = self
        item.action = nil
        item.representedObject = nil
        item.isHidden = false
        item.isEnabled = false

        let page = url
        let c = capture
        capture = nil
        let eventWall = Self.wallTime(of: event)
        if let c = c, c.page == page, abs(c.eventTime - eventWall) <= Self.eventTolerance,
           ProcessInfo.processInfo.systemUptime - c.uptime < 3 {
            apply(c.link, page: c.page, to: item)
            return
        }
        // The report for this click has not arrived (yet): wait briefly for it, then give up (item hidden).
        pendingItem = item
        pendingEventTime = eventWall
        pendingPage = page
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self, weak item] in
            guard let self = self, let item = item, generation == self.clickGeneration,
                  self.pendingItem === item else { return }
            self.pendingItem = nil
            item.isHidden = true
        }
    }

    override func didCloseMenu(_ menu: NSMenu, with event: NSEvent?) {
        super.didCloseMenu(menu, with: event)
        // Late results must not touch the closed menu; the resolved link stays until the next click so the chosen
        // item's action (which may be delivered after the menu closed) still has its exact address.
        clickGeneration += 1
        pendingItem = nil
        capture = nil
    }

    @objc func sendLinkToDownloads(_ sender: Any?) {
        guard let link = resolvedLink, resolvedPage == url, owner?.webView === self,
              (sender as? NSMenuItem)?.representedObject as? String == link,
              let valid = URLDropValidator.validateSingleURL(link), let app = owner?.appModel else {
            owner?.notice = "링크를 확인하지 못했습니다. 다시 한 번 우클릭해 주세요."
            return
        }
        resolvedLink = nil
        resolvedPage = nil
        if app.addJobs(from: [valid]) > 0 {
            owner?.notice = "링크를 다운로드 대기열에 보냈습니다."
        } else {
            owner?.notice = "이 링크는 다운로드 대기열에 추가할 수 없습니다."
        }
    }

    @objc private func fillSavedAccount() {
        guard let owner, owner.webView === self else { return }
        SiteCredentialCapture.triggerManualFill(model: owner)
    }

    @objc func toggleAutoShorts(_ sender: Any?) {
        guard AutoShorts.isBundledInHTT else { return }
        AutoShorts.isEnabled.toggle()
        let newState = AutoShorts.isEnabled
        owner?.notice = newState ? "YouTube Shorts 자동 넘김을 켰습니다." : "YouTube Shorts 자동 넘김을 껐습니다."
        if let tabs = owner?.appModel?.tabs {
            for tab in tabs {
                tab.webView?.evaluateJavaScript("window.__htdAutoShorts?.setEnabled(\(newState));", completionHandler: nil)
            }
        } else {
            evaluateJavaScript("window.__htdAutoShorts?.setEnabled(\(newState));", completionHandler: nil)
        }
    }
}

/// Hosts the tab's web view inside a plain AppKit container. For an HTML element (video player) fullscreen WebKit
/// replaces the web view in its superview with a placeholder and moves the web view into its own fullscreen window
/// (see `WKWebView.fullscreenState`). SwiftUI must therefore never own or re-add the `WKWebView` itself: it only owns
/// this container, and the web view is attached once and never touched while it is in or entering fullscreen.
struct LoginWebViewRepresentable: NSViewRepresentable {
    let webView: WKWebView
    var nativeInputAllowed: () -> Bool = { true }

    final class Container: NSView {
        private(set) var webView: WKWebView?
        private var observation: NSKeyValueObservation?
        var nativeInputAllowed: () -> Bool = { true }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.masksToBounds = true
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            wantsLayer = true
            layer?.masksToBounds = true
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard nativeInputAllowed() else { return nil }
            let localPoint = superview != nil ? convert(point, from: superview) : point
            guard bounds.contains(localPoint) else { return nil }
            return super.hitTest(point)
        }

        func attach(_ wv: WKWebView) {
            guard webView !== wv else { return }
            webView = wv
            observation = wv.observe(\.fullscreenState, options: [.new]) { [weak self] v, _ in
                guard v.fullscreenState == .notInFullscreen else { return }
                DispatchQueue.main.async { self?.reattachIfNeeded() }
            }
            reattachIfNeeded()
        }

        /// Adds the web view only when WebKit is not holding it for fullscreen (restore after exit is WebKit's own
        /// placeholder swap; this only covers a container rebuilt while fullscreen was active).
        private func reattachIfNeeded() {
            guard let wv = webView, wv.fullscreenState == .notInFullscreen, wv.superview !== self else { return }
            wv.removeFromSuperview()
            wv.frame = bounds
            wv.autoresizingMask = [.width, .height]
            addSubview(wv)
        }
    }

    func makeNSView(context: Context) -> Container {
        let container = Container()
        container.nativeInputAllowed = nativeInputAllowed
        container.attach(webView)
        return container
    }

    func updateNSView(_ nsView: Container, context: Context) {
        nsView.nativeInputAllowed = nativeInputAllowed
        nsView.attach(webView)
    }

    // Take exactly the space offered so the page never drives the window's minimum/ideal size.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: Container, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 320, height: 240))
    }
}

/// Shared list of hosts the connection-assist proxy refused, with explicit per-session allow actions.
struct BlockedHostsList: View {
    @ObservedObject var connection: ConnectionManager
    var limit: Int = 50

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(connection.blocked.prefix(limit)) { item in
                HStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.host + (item.port > 0 && item.port != 443 ? ":\(item.port)" : "") + (item.count > 1 ? " ×\(item.count)" : ""))
                            .font(.caption.bold())
                        Text(item.reason).font(.caption2).foregroundColor(.secondary)
                    }
                    Spacer()
                    if item.code == "not_allowed" {
                        Button("이 주소만 허용") { connection.allowBlocked(item) }
                            .accessibilityLabel("\(item.host) 연결을 이번 세션 동안 허용")
                        if let site = siteDomain(forHost: item.host), site != item.host {
                            Button("\(site) 전체 허용") { connection.allowBlockedSite(item) }
                                .accessibilityLabel("\(site) 사이트 전체 연결을 이번 세션 동안 허용")
                        }
                    }
                }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}

// MARK: - Browser Ad Blocker (WKContentRuleList)

/// Rule set applied to one tab. `.reduced` / `.off` are only ever used per tab after an explicit ad-blocker wall was
/// seen on that tab's current site; the global preference is never changed by them.
enum BrowserAdBlockMode: Equatable {
    case full
    case reduced
    case off
}

@MainActor
final class BrowserAdBlocker {
    static let shared = BrowserAdBlocker()

    static let ruleListIdentifier = "HTDBrowserAdBlockRules"
    static let reducedRuleListIdentifier = "HTDBrowserAdBlockRulesReduced"

    /// Maintained-in-source list of specific third-party ad domains.
    /// Strictly avoids broad URL matching and requires no external network fetch or dependency.
    static let adDomains: [String] = [
        "doubleclick.net",
        "googlesyndication.com",
        "googleadservices.com",
        "adservice.google.com",
        "adnxs.com",
        "criteo.com",
        "criteo.net",
        "openx.net",
        "rubiconproject.com",
        "pubmatic.com",
        "casalemedia.com",
        "taboola.com",
        "outbrain.com",
        "amazon-adsystem.com",
        "adroll.com",
        "zedo.com",
        "smartadserver.com",
        "popads.net",
        "popcash.net",
        "propellerads.com"
    ]

    /// Domains that ad-blocker detection scripts most commonly use as "bait" (they request a Google ad script or pixel
    /// and treat a blocked request as "ad blocker present"). The reduced set drops exactly these and keeps every other
    /// ad domain blocked. It is a heuristic subset, not a guarantee that a given site's detector stays quiet.
    static let detectionTriggerDomains: Set<String> = [
        "doubleclick.net",
        "googlesyndication.com",
        "googleadservices.com",
        "adservice.google.com"
    ]

    static var reducedAdDomains: [String] { adDomains.filter { !detectionTriggerDomains.contains($0) } }

    /// The reduced stage exists only while its rules differ materially from the full set (non-empty and strictly
    /// smaller); otherwise the wall handling goes straight to "off for this tab" instead of reloading twice.
    static var reducedIsDistinct: Bool {
        let reduced = reducedAdDomains
        return !reduced.isEmpty && reduced.count < adDomains.count
    }

    private struct Slot {
        var list: WKContentRuleList?
        var isCompiling = false
        var finished = false
        var callbacks: [(WKContentRuleList?) -> Void] = []
    }
    private var slots: [BrowserAdBlockMode: Slot] = [:]

    private init() {}

    static func ruleListJSON(domains: [String] = adDomains) -> String {
        let rules: [[String: Any]] = domains.map { domain in
            let escaped = NSRegularExpression.escapedPattern(for: domain)
            return [
                "trigger": [
                    "url-filter": "^https?://([a-zA-Z0-9.-]+\\.)?\(escaped)[:/]",
                    "load-type": ["third-party"]
                ],
                "action": [
                    "type": "block"
                ]
            ]
        }
        if let data = try? JSONSerialization.data(withJSONObject: rules, options: []),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "[]"
    }

    /// True once a compile attempt of this mode finished (successfully or not): nothing is left to wait for.
    func isSettled(_ mode: BrowserAdBlockMode) -> Bool {
        guard mode != .off else { return true }
        return slots[mode]?.finished ?? false
    }

    func compiledList(_ mode: BrowserAdBlockMode) -> WKContentRuleList? {
        slots[mode]?.list
    }

    /// Compiles (once) and returns the rule list of `mode` (`.full` or `.reduced`); `.off` yields nil.
    func getRuleList(_ mode: BrowserAdBlockMode = .full, completion: @escaping (WKContentRuleList?) -> Void) {
        guard mode != .off else { completion(nil); return }
        var slot = slots[mode] ?? Slot()
        if let list = slot.list {
            completion(list)
            return
        }
        slot.callbacks.append(completion)
        let alreadyCompiling = slot.isCompiling
        slot.isCompiling = true
        slots[mode] = slot
        guard !alreadyCompiling else { return }

        let identifier = mode == .full ? Self.ruleListIdentifier : Self.reducedRuleListIdentifier
        let json = Self.ruleListJSON(domains: mode == .full ? Self.adDomains : Self.reducedAdDomains)
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: identifier,
            encodedContentRuleList: json
        ) { [weak self] list, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                var slot = self.slots[mode] ?? Slot()
                slot.isCompiling = false
                slot.finished = true
                slot.list = list
                let callbacks = slot.callbacks
                slot.callbacks = []
                self.slots[mode] = slot
                if let error = error {
                    NSLog("[HttpsDown] Failed to compile ad block content rule list (\(identifier)): \(error.localizedDescription)")
                }
                for cb in callbacks { cb(list) }
            }
        }
    }

    /// Makes `ucc` carry exactly the compiled list of `mode` (none for `.off`). Synchronous and idempotent; a list
    /// that is not compiled yet is skipped here (the caller re-applies its then-current mode when compile finishes).
    func apply(_ mode: BrowserAdBlockMode, to ucc: WKUserContentController) {
        for other in [BrowserAdBlockMode.full, .reduced] where other != mode {
            if let list = slots[other]?.list { ucc.remove(list) }
        }
        if mode != .off, let list = slots[mode]?.list {
            ucc.remove(list)   // never stacked twice
            ucc.add(list)
        }
    }
}
