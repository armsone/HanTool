import Foundation
import Network
import Security

/// "HTTPS 연결 도움": the app-only authenticated loopback CONNECT proxy (Engine/connection.py) and its session policy.
///
/// * One switch (header of every tab). Off on first launch; the user's last choice is remembered (production only).
///   On = proxy AND TLS first-record split together, configured before the helper starts; off = neither. The helper
///   must confirm the split in `proxyReady`, otherwise it is not used (never a proxy without the split).
/// * The helper is an owned engine process (EngineBridge process group, swept on stop/quit). Credentials are random
///   per session, live only in memory and reach the helper/engine through stdin, never argv, logs or history.
/// * When on, every engine request and every request of a newly created browser WebView goes through the proxy with
///   failover disabled: there is no quiet direct fallback. Plain http:// is refused with a visible reason.
/// * Each consumer authenticates with a client tag (`<user>-<tag>`: one per job run, "web" for the browser), so a
///   refusal is bound to the job or page that caused it, never to another job's stale refusals.
/// * Destinations: the sites the user explicitly used (job address, login page) + known dependency domains of
///   supported sites + exact hosts the user allowed for this session after seeing them blocked. Nothing is wildcarded.
@MainActor
public final class ConnectionManager: ObservableObject {
    public enum Status: Equatable {
        case off
        case starting
        case ready(port: UInt16)
        case failed(String)
    }

    public struct BlockedHost: Identifiable, Equatable {
        public var id: String { "\(host)|\(code)|\(client)" }
        public let host: String
        public let port: Int
        public let code: String
        public let reason: String
        /// Client tag of the connection that was refused ("web" = browser, "j…" = one job run, "" = untagged).
        public let client: String
        public var count: Int
        public var lastSeen: Date

        /// Only refusals by the session allow-list can be fixed by allowing that exact host (never IP literals).
        public var canAllow: Bool { code == "not_allowed" && ConnectionManager.isAllowableHost(host) }
    }

    public struct SplitFallback: Identifiable, Equatable {
        public var id: String { "\(host)|\(code)" }
        public let host: String
        public let code: String
        public let reason: String
        public var count: Int
    }

    @Published public private(set) var enabled = false
    @Published public private(set) var status: Status = .off
    /// TLS first-record split goes with the switch; there is no separate option.
    public var splitTLS: Bool { enabled }
    /// The running helper confirmed (in `proxyReady`) that the split is applied to its tunnels.
    @Published public private(set) var splitConfirmed = false
    /// Automatic public target policy goes with the switch; helper tunnels allow public targets for authenticated clients.
    public var autoAllowPublic: Bool { enabled }
    /// The running helper confirmed (in `proxyReady`) that autoAllowPublic is active on its tunnels.
    @Published public private(set) var autoAllowPublicConfirmed = false
    /// Tunnels where the split was not applied and why (bounded; diagnostics only).
    @Published public private(set) var splitFallbacks: [SplitFallback] = []
    @Published public private(set) var allowedDomains: [String] = []
    @Published public private(set) var blocked: [BlockedHost] = []
    /// Increments every time a new helper becomes ready (new port/credentials): WebViews built for an older
    /// generation must be recreated to use the new proxy.
    @Published public private(set) var generation = 0

    /// Remember the switch across launches. Only the production configuration sets this; isolated configurations
    /// (`AppConfiguration.usesUserDefaults == false`) never read or write preferences.
    var persistsChoice = false
    static let choiceKey = "httpsConnectionHelp"
    private static let legacySplitKey = "connectionAssistSplitTLS"
    static let browserClient = "web"

    /// Opt-in pre-request TLS retry for the browser client only (default off). Sent in the helper's first config line
    /// and live as a separate `config` op, so running tunnels and downloads are never interrupted.
    private(set) var autoRetryTLS = false

    func setAutoRetryTLS(_ on: Bool) {
        guard on != autoRetryTLS else { return }
        autoRetryTLS = on
        guard let h = handle, let data = try? JSONSerialization.data(withJSONObject: ["op": "config", "autoRetryTLS": on])
        else { return }
        sendQueue.async { _ = h.sendLine(data) }
    }

    /// Called when the helper becomes ready or fails, so the queue can continue.
    var onStatusChange: (() -> Void)?

    private var handle: EngineTaskHandle?
    private var username = ""
    private var password = ""
    private var domains = Set<String>()
    private var hosts = Set<String>()
    /// Policy updates carry a request id; the helper answers `policyApplied` with it after the update is in force.
    /// Updates go through one serial queue so ids are applied (and acknowledged) in order.
    private var policySent = 0
    private var policyApplied = 0
    private var policyWaiters: [Int: (target: Int, done: (String?) -> Void)] = [:]
    private var nextWaiter = 0
    private let sendQueue = DispatchQueue(label: "HttpsDown.connection.policy", qos: .userInitiated)
    private static let policyAckTimeout: UInt64 = 8_000_000_000

    /// Dependency domains of commonly supported sites (media CDNs, players, sign-in). Matched by suffix only for the
    /// listed names; this is not a wildcard for everything.
    private static let knownDependencies: [String: [String]] = [
        "youtube.com": ["youtube.com", "googlevideo.com", "ytimg.com", "ggpht.com", "youtube-nocookie.com",
                        "googleapis.com", "gstatic.com", "google.com", "googleusercontent.com", "youtu.be"],
        "youtu.be": ["youtube.com", "googlevideo.com", "ytimg.com", "ggpht.com", "googleapis.com", "gstatic.com"],
        "vimeo.com": ["vimeo.com", "vimeocdn.com", "vimeo-video.com"],
        "twitch.tv": ["twitch.tv", "ttvnw.net", "jtvnw.net", "twitchcdn.net", "twitchsvc.net", "live-video.net"],
        "soundcloud.com": ["soundcloud.com", "sndcdn.com", "soundcloud.cloud"],
        "dailymotion.com": ["dailymotion.com", "dmcdn.net", "dm-event.net", "dmxleo.com"],
        "x.com": ["x.com", "twitter.com", "twimg.com", "t.co"],
        "twitter.com": ["x.com", "twitter.com", "twimg.com", "t.co"],
        "instagram.com": ["instagram.com", "cdninstagram.com", "fbcdn.net", "facebook.com"],
        "facebook.com": ["facebook.com", "fbcdn.net", "fb.com", "facebook.net"],
        "tiktok.com": ["tiktok.com", "tiktokcdn.com", "tiktokcdn-us.com", "tiktokv.com", "ibytedtos.com", "byteoversea.com"],
        "naver.com": ["naver.com", "naver.net", "pstatic.net", "navercorp.com"],
        "kakao.com": ["kakao.com", "kakaocdn.net", "daum.net", "daumcdn.net"],
        "daum.net": ["daum.net", "daumcdn.net", "kakao.com", "kakaocdn.net"],
        "sooplive.co.kr": ["sooplive.co.kr", "afreecatv.com", "sooplive.com"],
        "afreecatv.com": ["afreecatv.com", "sooplive.co.kr"],
        "bilibili.com": ["bilibili.com", "bilivideo.com", "hdslb.com", "biliapi.net", "bilivideo.cn"],
        "reddit.com": ["reddit.com", "redd.it", "redditmedia.com", "redditstatic.com"],
        "vk.com": ["vk.com", "vkuser.net", "userapi.com", "vkvideo.ru"],
        "rumble.com": ["rumble.com", "1a-1791.com"],
        "bandcamp.com": ["bandcamp.com", "bcbits.com"],
        "archive.org": ["archive.org"],
        "ted.com": ["ted.com", "tedcdn.com"]
    ]

    public init() {}

    /// The remembered switch position (production preferences only). First launch → off. A pre-0.4 saved
    /// "첫 암호화 메시지 나눠 보내기" choice was only meaningful together with the proxy, so it becomes this switch once
    /// and the old key is removed.
    static func savedChoice() -> Bool {
        let defaults = HTDBrowserDefaults.standard
        if defaults.object(forKey: choiceKey) != nil { return defaults.bool(forKey: choiceKey) }
        guard defaults.object(forKey: legacySplitKey) != nil else { return false }
        let migrated = defaults.bool(forKey: legacySplitKey)
        defaults.set(migrated, forKey: choiceKey)
        defaults.removeObject(forKey: legacySplitKey)
        return migrated
    }

    // MARK: Derived

    public var isReady: Bool {
        if case .ready = status { return true }
        return false
    }

    public var isStarting: Bool { status == .starting }

    public var isFailed: Bool {
        if case .failed = status { return true }
        return false
    }

    public var statusText: String {
        switch status {
        case .off: return "시스템 기본 연결 사용 중"
        case .starting: return "HTTPS 연결 도움 준비 중..."
        case .ready: return "HTTPS 연결 도움 사용 중 (앱 전용, 첫 TLS 메시지 나눠 보내기 적용)"
        case .failed(let why): return "HTTPS 연결 도움을 시작하지 못했습니다: \(why)"
        }
    }

    /// Short label for the header switch: off / preparing / active / failure. Never "active" before the helper
    /// reported ready with the split confirmed.
    public var shortStatus: String {
        switch status {
        case .off: return "꺼짐"
        case .starting: return "준비 중..."
        case .ready: return "사용 중"
        case .failed: return "오류"
        }
    }

    /// Lowercase ASCII letter or digit (or "-" when `dash`).
    nonisolated private static func isLDH(_ s: Unicode.Scalar, dash: Bool) -> Bool {
        let v = s.value
        return (v >= 0x61 && v <= 0x7A) || (v >= 0x30 && v <= 0x39) || (dash && v == 0x2D)
    }

    nonisolated static func isValidClientTag(_ tag: String) -> Bool {
        !tag.isEmpty && tag.count <= 24 && tag.unicodeScalars.allSatisfy { isLDH($0, dash: false) }
    }

    /// A DNS name the recovery button may allow exactly (no IP literals, no local names).
    nonisolated static func isAllowableHost(_ host: String) -> Bool {
        let h = host.lowercased()
        let localSuffixes = [".local", ".localhost", ".internal", ".home.arpa", ".lan", ".intranet", ".corp"]
        guard h.count <= 253, h.contains("."), !h.hasSuffix("."), !localSuffixes.contains(where: { h.hasSuffix($0) })
        else { return false }
        if IPv4Address(h) != nil || IPv6Address(h) != nil { return false }
        let labels = h.split(separator: ".", omittingEmptySubsequences: false)
        for label in labels {
            guard !label.isEmpty, label.count <= 63, !label.hasPrefix("-"), !label.hasSuffix("-"),
                  label.unicodeScalars.allSatisfy({ isLDH($0, dash: true) }) else { return false }
        }
        // An all-numeric last label would be an IP-like name.
        guard let last = labels.last else { return false }
        return !last.allSatisfy { $0.isNumber }
    }

    /// Proxy URL for one engine run (credentials + client tag; memory/stdin only). Nil when off or not ready.
    func engineProxyURL(client: String) -> String? {
        guard enabled, splitConfirmed, autoAllowPublicConfirmed, case .ready(let port) = status, Self.isValidClientTag(client) else { return nil }
        return "http://\(username)-\(client):\(password)@127.0.0.1:\(port)"
    }

    /// Network.framework proxy for a WebKit data store: HTTP CONNECT to the loopback helper, session credentials
    /// (browser client tag), failover disabled, no matchDomains (= applies to all traffic of that store).
    func webProxyConfiguration() -> ProxyConfiguration? {
        guard enabled, splitConfirmed, autoAllowPublicConfirmed, case .ready(let port) = status,
              let nwPort = NWEndpoint.Port(rawValue: port) else { return nil }
        var proxy = ProxyConfiguration(httpCONNECTProxy: NWEndpoint.hostPort(host: "127.0.0.1", port: nwPort))
        proxy.applyCredential(username: "\(username)-\(Self.browserClient)", password: password)
        proxy.allowFailover = false
        return proxy
    }

    // MARK: Lifecycle

    /// The one switch. Mode changes are refused by the caller while a job is running (no silent switch mid-job).
    /// On: the helper is started with the TLS split already in its first config line; off: helper stopped.
    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        if persistsChoice { HTDBrowserDefaults.standard.set(on, forKey: Self.choiceKey) }
        if on { start() } else { stop() }
    }

    private func start() {
        stopHelper()
        username = "hd" + Self.randomToken(bytes: 6)
        password = Self.randomToken(bytes: 24)
        status = .starting
        splitConfirmed = false
        autoAllowPublicConfirmed = false
        splitFallbacks = []
        blocked = []
        // The new helper receives the full current policy in its first config line.
        policySent = 0
        policyApplied = 0
        let config: [String: Any] = [
            "username": username, "password": password,
            "domains": Array(domains), "hosts": Array(hosts),
            "splitTLS": true, "autoAllowPublic": true, "autoRetryTLS": autoRetryTLS
        ]
        var startedHandle: EngineTaskHandle?
        startedHandle = EngineBridge.shared.startProxy(
            config: config,
            onEvent: { [weak self] event, payload in
                MainActor.assumeIsolated {
                    guard let self = self, let h = startedHandle, self.handle === h else { return }
                    self.handleEvent(event, payload)
                }
            },
            onExit: { [weak self] result in
                MainActor.assumeIsolated {
                    guard let self = self, let h = startedHandle, self.handle === h else { return }
                    self.handle = nil
                    self.splitConfirmed = false
                    self.autoAllowPublicConfirmed = false
                    self.failPolicyWaiters("HTTPS 연결 도움 프로세스가 종료되어 사이트 허용을 적용하지 못했습니다. 위의 '다시 연결'을 누른 뒤 다시 시도해 주세요.")
                    if self.enabled {
                        self.status = .failed(result.spawnError ?? "연결 도움 프로세스가 종료되었습니다. 위의 '다시 연결'을 눌러 주세요.")
                    } else {
                        self.status = .off
                    }
                    self.onStatusChange?()
                }
            })
        handle = startedHandle
    }

    /// Restarts the helper with fresh credentials (e.g. after a failure).
    func restart() {
        guard enabled else { return }
        start()
    }

    func stop() {
        stopHelper()
        status = .off
        splitConfirmed = false
        autoAllowPublicConfirmed = false
        username = ""
        password = ""
        onStatusChange?()
    }

    private func stopHelper() {
        if let h = handle {
            handle = nil
            h.cancel()   // SIGTERM → SIGKILL to the helper's own process group
        }
        failPolicyWaiters("HTTPS 연결 도움이 꺼졌거나 다시 시작되어 이전 연결 설정으로는 진행하지 않았습니다. 다시 시도해 주세요.")
    }

    private func handleEvent(_ event: String, _ payload: [String: Any]) {
        switch event {
        case "proxyReady":
            guard let port = (payload["port"] as? NSNumber)?.uint16Value, port > 0 else { break }
            guard payload["splitTLS"] as? Bool == true else {
                // Never run the proxy without the split the switch promises.
                stopHelper()
                status = .failed("첫 TLS 메시지 나눠 보내기를 켜지 못해 연결 도움을 쓰지 않았습니다. '다시 연결'을 눌러 주세요.")
                onStatusChange?()
                break
            }
            guard payload["autoAllowPublic"] as? Bool == true else {
                // Helper must confirm the automatic public target policy.
                stopHelper()
                status = .failed("외부 주소 자동 연결 정책을 확인하지 못해 연결 도움을 쓰지 않았습니다. '다시 연결'을 눌러 주세요.")
                onStatusChange?()
                break
            }
            splitConfirmed = true
            autoAllowPublicConfirmed = true
            status = .ready(port: port)
            generation += 1
            onStatusChange?()
        case "splitFallback":
            let host = String((payload["host"] as? String ?? "?").lowercased().prefix(253))
            let code = payload["code"] as? String ?? "fallback"
            if let i = splitFallbacks.firstIndex(where: { $0.host == host && $0.code == code }) {
                splitFallbacks[i].count += 1
            } else {
                splitFallbacks.insert(SplitFallback(host: host, code: code,
                                                    reason: payload["reason"] as? String ?? "나눠 보내지 않고 그대로 전달했습니다.",
                                                    count: 1), at: 0)
                if splitFallbacks.count > 20 { splitFallbacks.removeLast(splitFallbacks.count - 20) }
            }
        case "blocked":
            let host = String((payload["host"] as? String ?? "?").lowercased().prefix(253))
            let code = payload["code"] as? String ?? "blocked"
            let reason = payload["reason"] as? String ?? "연결이 차단되었습니다."
            let port = (payload["port"] as? NSNumber)?.intValue ?? 0
            let client = payload["client"] as? String ?? ""
            if let i = blocked.firstIndex(where: { $0.host == host && $0.code == code && $0.client == client }) {
                blocked[i].count += 1
                blocked[i].lastSeen = Date()
            } else {
                blocked.insert(BlockedHost(host: host, port: port, code: code, reason: reason, client: client,
                                           count: 1, lastSeen: Date()), at: 0)
                if blocked.count > 200 { blocked.removeLast(blocked.count - 200) }
            }
        case "policyApplied":
            if let id = (payload["id"] as? NSNumber)?.intValue, id > policyApplied, id <= policySent {
                policyApplied = id
                let ready = policyWaiters.filter { $0.value.target <= id }
                for key in ready.keys { policyWaiters.removeValue(forKey: key) }
                for waiter in ready.sorted(by: { $0.key < $1.key }) { waiter.value.done(nil) }
            }
        case "error":
            status = .failed(payload["message"] as? String ?? "연결 도움 오류")
            splitConfirmed = false
            autoAllowPublicConfirmed = false
            failPolicyWaiters("HTTPS 연결 도움 오류로 사이트 허용을 적용하지 못했습니다. 위의 연결 도움 상태를 확인해 주세요.")
            onStatusChange?()
        default:
            break
        }
    }

    // MARK: Policy

    /// The user explicitly used this address (job or login page): allow its site plus known dependencies.
    func allowSite(forURL urlString: String) {
        guard let site = siteDomain(forURL: urlString) else {
            if let host = URLComponents(string: urlString)?.host?.lowercased() { allowHost(host) }
            return
        }
        var add = [site]
        if let deps = Self.knownDependencies[site] { add += deps }
        addDomains(add)
    }

    /// True when the current session policy already allows this host (exact host or listed domain suffix).
    func covers(host raw: String) -> Bool {
        let host = raw.lowercased()
        return hosts.contains(host) || domains.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Explicit "이번 세션 동안 허용" for a host the proxy blocked as not allowed.
    func allowBlocked(_ item: BlockedHost) {
        guard item.code == "not_allowed" else { return }
        allowHost(item.host)
        blocked.removeAll { $0.host == item.host && $0.code == item.code }
    }

    /// "허용 후 다시 시도": allows exactly these hosts (each must be an allowable DNS name the proxy refused as
    /// not_allowed), in one policy update. Returns the hosts actually sent; the caller then awaits `policyApplied`.
    func allowExactHosts(_ list: [String]) -> [String] {
        let refused = Set(blocked.filter { $0.canAllow }.map { $0.host })
        var fresh: [String] = []
        for raw in list {
            let host = raw.lowercased()
            guard refused.contains(host), Self.isAllowableHost(host), !hosts.contains(host), !fresh.contains(host)
            else { continue }
            fresh.append(host)
        }
        guard !fresh.isEmpty else { return [] }
        hosts.formUnion(fresh)
        allowedDomains = (Array(domains) + Array(hosts)).sorted()
        blocked.removeAll { $0.code == "not_allowed" && fresh.contains($0.host) }
        send(["op": "allow", "hosts": fresh])
        return fresh
    }

    /// Internal exact planning method for trusted owned engine dependency plans: validates all hosts
    /// (exact allowable DNS names, list size <= 16, raw hostname length <= 253), skips currently covered hosts,
    /// and sends the update to the helper in one policy update. Returns the hosts actually sent.
    func allowPlannedHosts(_ list: [String]) -> [String] {
        guard list.count <= 16 else { return [] }
        var fresh: [String] = []
        for raw in list {
            guard raw.count <= 253 else { return [] }
            let host = raw.lowercased()
            guard Self.isAllowableHost(host) else { return [] }
            if covers(host: host) || fresh.contains(host) { continue }
            fresh.append(host)
        }
        guard !fresh.isEmpty else { return [] }
        hosts.formUnion(fresh)
        allowedDomains = (Array(domains) + Array(hosts)).sorted()
        blocked.removeAll { $0.code == "not_allowed" && fresh.contains($0.host) }
        send(["op": "allow", "hosts": fresh])
        return fresh
    }

    /// The fixed host of the user-started speed check (Engine/speed.py). Never a user-supplied address.
    nonisolated static let speedTestHost = "speed.cloudflare.com"

    /// '속도 측정' was pressed with the helper on: allow exactly the measurement host for this session (no site,
    /// no wildcard). The caller then awaits `policyApplied` before any measurement traffic.
    func allowSpeedTestHost() {
        allowHost(Self.speedTestHost)
    }

    /// Refusals of one client tag (one job run, or the browser), newest first.
    func refusals(forClient client: String, since date: Date = .distantPast) -> [BlockedHost] {
        blocked.filter { $0.client == client && $0.lastSeen >= date }
    }

    /// Allow the whole site of a blocked host (shown separately so the user sees what is being allowed).
    func allowBlockedSite(_ item: BlockedHost) {
        guard item.code == "not_allowed", let site = siteDomain(forHost: item.host) else { return }
        addDomains([site])
        blocked.removeAll { $0.code == item.code && ($0.host == site || $0.host.hasSuffix("." + site)) }
    }

    func clearBlocked() { blocked = [] }

    private func allowHost(_ host: String) {
        guard !host.isEmpty, !hosts.contains(host) else { return }
        hosts.insert(host)
        allowedDomains = (Array(domains) + Array(hosts)).sorted()
        send(["op": "allow", "hosts": [host]])
    }

    private func addDomains(_ list: [String]) {
        let fresh = list.map { $0.lowercased() }.filter { !$0.isEmpty && !domains.contains($0) }
        guard !fresh.isEmpty else { return }
        domains.formUnion(fresh)
        allowedDomains = (Array(domains) + Array(hosts)).sorted()
        send(["op": "allow", "domains": fresh])
    }

    private func send(_ message: [String: Any]) {
        guard let h = handle else { return }
        policySent += 1
        var message = message
        message["id"] = policySent
        guard let data = try? JSONSerialization.data(withJSONObject: message) else {
            policyDeliveryFailed(h)
            return
        }
        sendQueue.async { [weak self] in
            if !h.sendLine(data) {
                Task { @MainActor [weak self] in self?.policyDeliveryFailed(h) }
            }
        }
    }

    /// Calls `done(nil)` once the helper has confirmed every policy update sent so far (so the site the user just
    /// chose is really allowed before WebKit or the engine opens a connection), or `done(reason)` if that cannot be
    /// confirmed in time. Never blocks the main thread; never falls back to a direct connection. With connection
    /// assist off there is no policy to wait for.
    func awaitPolicyApplied(_ done: @escaping (String?) -> Void) {
        guard enabled else { done(nil); return }
        guard handle != nil, isReady else {
            done("HTTPS 연결 도움이 준비되지 않아 진행하지 않았습니다. 위의 연결 도움 상태를 확인해 주세요.")
            return
        }
        if policyApplied >= policySent { done(nil); return }
        nextWaiter += 1
        let key = nextWaiter
        policyWaiters[key] = (target: policySent, done: done)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.policyAckTimeout)
            guard let self = self, let waiter = self.policyWaiters.removeValue(forKey: key) else { return }
            waiter.done("HTTPS 연결 도움이 사이트 허용을 적용했는지 제시간에 확인하지 못해 진행하지 않았습니다. "
                        + "위의 '다시 연결'을 누른 뒤 다시 시도해 주세요.")
        }
    }

    /// Fails pending waiters on the next main-actor turn, so callers never re-enter while the helper state changes.
    private func failPolicyWaiters(_ reason: String) {
        guard !policyWaiters.isEmpty else { return }
        let failed = policyWaiters.sorted { $0.key < $1.key }.map { $0.value.done }
        policyWaiters = [:]
        failedWaiters += failed.map { (done: $0, reason: reason) }
        Task { @MainActor [weak self] in self?.flushFailedWaiters() }
    }

    private var failedWaiters: [(done: (String?) -> Void, reason: String)] = []

    private func flushFailedWaiters() {
        let list = failedWaiters
        failedWaiters = []
        for item in list { item.done(item.reason) }
    }

    /// A policy update that could not be written means the helper's policy is unknown: fail closed and visibly.
    private func policyDeliveryFailed(_ h: EngineTaskHandle) {
        guard handle === h else { return }
        status = .failed("허용 목록을 연결 도움에 전달하지 못했습니다. '다시 연결'을 눌러 주세요.")
        failPolicyWaiters("허용 목록을 연결 도움에 전달하지 못해 진행하지 않았습니다. 위의 '다시 연결'을 누른 뒤 다시 시도해 주세요.")
        onStatusChange?()
    }

    private static func randomToken(bytes count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        if SecRandomCopyBytes(kSecRandomDefault, count, &bytes) != errSecSuccess {
            var rng = SystemRandomNumberGenerator()
            for i in 0..<count { bytes[i] = UInt8.random(in: 0...255, using: &rng) }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
