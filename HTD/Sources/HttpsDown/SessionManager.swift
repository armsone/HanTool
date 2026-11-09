import Foundation
import Network
import WebKit
import Security

/// The app's own login session ("전용 로그인").
///
/// * One app-owned persistent WKWebsiteDataStore (fixed identifier, not Safari's shared cookies): a login stays after
///   the app quits and ends only when the user clears the session ('세션 지우기'). No Safari/Chrome/other browser
///   cookies or keychain items are ever read.
/// * The user signs in by themselves in the app's window; the only fill is the optional Google password the user
///   saved in this app's own Keychain item (GoogleCredentialStore), and nothing is ever submitted for them.
/// * For a job, only cookies of the site the user bound to that job (its address, or the login page it came from)
///   are exported, in memory, into the engine's stdin request. Host-only/Domain/Path/Secure/expiry travel with each
///   cookie; partitioned cookies and anything that cannot be represented faithfully are left out (counted, not shown).
@MainActor
public final class SessionManager: ObservableObject {
    /// Stable desktop Safari-style UA, used by the login WebView and by engine requests that carry this session.
    public static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15"

    @Published public private(set) var isAlive = false
    /// Sites (eTLD+1) the user navigated to in this session; shown as choices, never used to dump everything.
    @Published public private(set) var visitedSites: [String] = []
    /// Connection-assist generation this session's store was configured with (nil = system connection).
    @Published public private(set) var proxyGeneration: Int?

    private(set) var dataStore: WKWebsiteDataStore?
    /// Connection-assist generation of the alternate store (nil = system connection).
    @Published public private(set) var alternateProxyGeneration: Int?
    /// The store of the route the global switch does NOT select. A WKWebsiteDataStore carries one proxy configuration
    /// for all of its views and cannot be changed per tab, so a tab whose site uses the other route gets its own
    /// separately identified store. Cookies and site data of the two stores are never copied into each other.
    private(set) var alternateStore: WKWebsiteDataStore?

    /// True while the primary store exists (the one `proxyGeneration` describes).
    var hasPrimaryStore: Bool { dataStore != nil }

    /// Stable identifier of the app's own persistent store (public WKWebsiteDataStore(forIdentifier:) API).
    /// Unchanged from earlier versions: existing logins stay in this store.
    private static let storeIdentifier = UUID(uuidString: "6F1D2B7A-3C54-4E8B-9A10-48D7C5E21B93")!
    /// Identifier of the alternate-route store (new; only created once a site actually needs the other route).
    private static let alternateStoreIdentifier = UUID(uuidString: "B3A8E0C4-5D17-4F62-8E39-0C6A71D94F25")!
    private static let alternateStoreUsedKey = "SessionManager.alternateStoreUsed"

    /// false = isolated/verification run: a throwaway non-persistent store, the fixed-identifier store is never touched.
    private let persistent: Bool

    // MARK: - Opt-out Login Continuity Across Restart

    private static let snapshotCutoffKey = "SessionManager.loginContinuitySnapshotCutoffs"
    private static let globalSnapshotCutoffKey = "SessionManager.loginContinuityGlobalSnapshotCutoff"
    private static let optInDefaultsKey = "SessionManager.loginContinuityOptInHosts"
    private static let optOutDefaultsKey = "SessionManager.loginContinuityOptOutHosts"
    private static let keychainService = "com.htd.session.continuity"
    private static let snapshotValidityDuration: TimeInterval = 7 * 86400 // short-lived bounded (7 days)
    private static let maxSnapshotsPerHost = 50 // bounded backup
    private static let maxSnapshotBytes = 64 * 1024 // 64 KB bounded size

    @Published public private(set) var optOutHosts: Set<String>

    private static func loadOptOutHosts() -> Set<String> {
        let defaults = UserDefaults.standard
        if let savedOptOut = defaults.stringArray(forKey: optOutDefaultsKey) {
            return Set(savedOptOut.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty })
        }
        // Migration: migrate explicit old off from snapshot cutoff keys minus old opt-in hosts,
        // only if old opt-in preference exists; distinguish new installation.
        if defaults.object(forKey: optInDefaultsKey) != nil {
            let oldOptInList = defaults.stringArray(forKey: optInDefaultsKey) ?? []
            let oldOptIn = Set(oldOptInList.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty })
            let cutoffs = defaults.dictionary(forKey: snapshotCutoffKey) ?? [:]
            var migratedOptOut = Set<String>()
            for key in cutoffs.keys {
                let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if !trimmed.isEmpty && !oldOptIn.contains(trimmed) {
                    migratedOptOut.insert(trimmed)
                }
            }
            defaults.set(Array(migratedOptOut).sorted(), forKey: optOutDefaultsKey)
            return migratedOptOut
        }
        // New installation: default empty optOutHosts (HTTPS login continuity default ON)
        defaults.set([String](), forKey: optOutDefaultsKey)
        return []
    }

    private var restoredHosts = Set<String>()
    private var inFlightRestores = Set<String>()
    private var restoreWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var cookieObserver: CookieObserverBridge?
    private var activeObserverStore: WKWebsiteDataStore?
    private var observerGeneration: UInt64 = 0
    private var observerReadRevision: UInt64 = 0

    public init(persistent: Bool = true) {
        self.persistent = persistent
        self.optOutHosts = persistent ? Self.loadOptOutHosts() : []
    }

    public func isLoginContinuityEnabled(forHost host: String?) -> Bool {
        guard persistent else { return false }
        guard let h = sanitizeHost(host) else { return false }
        return !optOutHosts.contains(h)
    }

    public func setLoginContinuityEnabled(_ enabled: Bool, forHost host: String?) {
        guard persistent else { return }
        guard let h = sanitizeHost(host) else { return }
        if enabled {
            invalidateSnapshot(forHost: h)
            optOutHosts.remove(h)
            // Enabling must snapshot existing cookies immediately and set host restored to avoid old copy
            restoredHosts.insert(h)
            handleCookiesChanged()
        } else {
            invalidateSnapshot(forHost: h)
            optOutHosts.insert(h)
            restoredHosts.remove(h)
            deleteKeychainSnapshot(forHost: h)
            observerGeneration &+= 1
        }
        UserDefaults.standard.set(Array(optOutHosts).sorted(), forKey: Self.optOutDefaultsKey)
    }

    public func sanitizeHost(_ host: String?) -> String? {
        guard let host = host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !host.isEmpty, !host.contains("/"), !host.contains(":") else { return nil }
        return host
    }

    private func setupCookieObserver(for store: WKWebsiteDataStore) {
        guard persistent else { return }
        if let oldStore = activeObserverStore, let bridge = cookieObserver {
            oldStore.httpCookieStore.remove(bridge)
        }
        let bridge = CookieObserverBridge { [weak self] in
            self?.handleCookiesChanged()
        }
        cookieObserver = bridge
        activeObserverStore = store
        store.httpCookieStore.add(bridge)
    }

    private func filterSessionOnlyCookies(from all: [HTTPCookie], forHost host: String) -> [HTTPCookie] {
        return all.filter { cookie in
            // Filter cookie.isSessionOnly
            guard cookie.isSessionOnly else { return false }

            // Trimmed exact domain == host (exclude parent-domain cookies)
            let cDomain = cookie.domain.lowercased()
            let trimmedDomain = cDomain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard trimmedDomain == host else { return false }

            // Skip partitioned/port
            if Self.isPartitioned(cookie) || cookie.name.isEmpty || cookie.portList?.isEmpty == false {
                return false
            }

            if let exp = cookie.expiresDate, exp <= Date() {
                return false
            }

            return true
        }
    }

    private func handleCookiesChanged() {
        guard persistent, !isClearing, let store = dataStore else { return }
        let currentRestored = self.restoredHosts
        let currentOptOut = self.optOutHosts
        let activeHosts = currentRestored.filter { !currentOptOut.contains($0) }
        guard !activeHosts.isEmpty else { return }
        let currentGeneration = self.observerGeneration
        self.observerReadRevision &+= 1
        let readRevision = self.observerReadRevision

        Task { @MainActor [weak self] in
            guard let self = self,
                  self.persistent,
                  !self.isClearing,
                  self.observerGeneration == currentGeneration,
                  self.observerReadRevision == readRevision,
                  let currentStore = self.dataStore,
                  currentStore === store else { return }

            let all = await currentStore.httpCookieStore.allCookies()

            // Observer must revalidate dataStore identity, optOutHosts, generation and read revision after each await,
            // not write during restoration or before host has finished first restore
            guard self.persistent,
                  !self.isClearing,
                  self.observerGeneration == currentGeneration,
                  self.observerReadRevision == readRevision,
                  let recheckedStore = self.dataStore,
                  recheckedStore === store else { return }

            let recheckedActive = activeHosts.intersection(self.restoredHosts).subtracting(self.optOutHosts)
            guard !recheckedActive.isEmpty else { return }

            for host in recheckedActive {
                guard !self.optOutHosts.contains(host) else { continue }
                // Must not write during restoration of this host
                if self.inFlightRestores.contains(host) {
                    continue
                }
                // Must snapshot only restoredHosts that are enabled and have finished restore
                if !self.restoredHosts.contains(host) {
                    continue
                }

                let validRepresentable = self.filterSessionOnlyCookies(from: all, forHost: host)

                guard self.persistent,
                      !self.isClearing,
                      self.observerGeneration == currentGeneration,
                      self.observerReadRevision == readRevision,
                      self.dataStore === store,
                      !self.optOutHosts.contains(host) else { return }

                if validRepresentable.isEmpty {
                    // Stale snapshot / logout: delete backup
                    self.deleteKeychainSnapshot(forHost: host)
                } else {
                    // Replace snapshot with fresh state
                    self.saveKeychainSnapshot(cookies: validRepresentable, forHost: host)
                }
            }
        }
    }

    public func restoreSessionCookiesIfNeeded(forHost rawHost: String, store: WKWebsiteDataStore) async {
        guard persistent, !isClearing, dataStore === store else { return }
        guard let host = sanitizeHost(rawHost) else { return }
        guard !optOutHosts.contains(host) else { return }
        guard !restoredHosts.contains(host) else { return }

        // Concurrent same-host navigation waits for in-flight restore rather than returns early
        if inFlightRestores.contains(host) {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                restoreWaiters[host, default: []].append(continuation)
            }
            return
        }

        inFlightRestores.insert(host)
        let restoreGen = observerGeneration
        defer {
            inFlightRestores.remove(host)
            let waiters = restoreWaiters.removeValue(forKey: host) ?? []
            for waiter in waiters {
                waiter.resume()
            }
        }

        guard !isClearing, !optOutHosts.contains(host), observerGeneration == restoreGen else { return }

        guard let snapshot = loadKeychainSnapshot(forHost: host) else {
            if !optOutHosts.contains(host) && observerGeneration == restoreGen {
                restoredHosts.insert(host)
            }
            return
        }

        // Check if snapshot is expired (Keep snapshot max 7 days)
        if Date().timeIntervalSince(snapshot.createdAt) > Self.snapshotValidityDuration {
            deleteKeychainSnapshot(forHost: host)
            if !optOutHosts.contains(host) && observerGeneration == restoreGen {
                restoredHosts.insert(host)
            }
            return
        }

        let existingCookies = await store.httpCookieStore.allCookies()
        // Clear/detach/opt-out invalidate in-flight restores; do not restore after opt-out
        guard !isClearing,
              !optOutHosts.contains(host),
              observerGeneration == restoreGen,
              dataStore === store else { return }

        var existingKeys = Set<String>()
        for c in existingCookies {
            let key = "\(c.name)#\(c.domain.lowercased())#\(c.path)"
            existingKeys.insert(key)
        }

        for record in snapshot.cookies {
            // Scope check: record domain trimmed must match host
            let recordTrimmed = record.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard recordTrimmed == host else { continue }

            let key = "\(record.name)#\(record.domain.lowercased())#\(record.path)"
            // Never overwrite existing cookie
            if existingKeys.contains(key) {
                continue
            }

            var props: [HTTPCookiePropertyKey: Any] = [
                .name: record.name,
                .value: record.value,
                .domain: record.domain,
                .path: record.path
            ]
            if record.secure {
                props[.secure] = "TRUE"
            }
            if record.httpOnly {
                props[.init("HttpOnly")] = "TRUE"
            }
            if let exp = record.expiresDate {
                if exp <= Date() {
                    continue // expired, do not restore
                }
                props[.expires] = exp
            }
            if let sameSite = record.sameSitePolicy {
                props[.sameSitePolicy] = sameSite
            }

            guard let cookie = HTTPCookie(properties: props) else { continue }
            if Self.isPartitioned(cookie) || cookie.name.isEmpty || cookie.portList?.isEmpty == false {
                continue
            }

            // Validate reconstructed secure/httpOnly/sameSite/isSessionOnly and record domain before set
            guard cookie.isSecure == record.secure,
                  cookie.isHTTPOnly == record.httpOnly,
                  cookie.isSessionOnly == true else {
                continue
            }

            let cookieTrimmed = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard cookieTrimmed == host, cookie.domain.lowercased() == record.domain.lowercased() else {
                continue
            }

            // Check sameSite
            if let ss = cookie.sameSitePolicy {
                guard ss.rawValue == record.sameSitePolicy else { continue }
            } else {
                guard record.sameSitePolicy == nil else { continue }
            }

            await store.httpCookieStore.setCookie(cookie)

            // Recheck state after await
            guard !isClearing,
                  !optOutHosts.contains(host),
                  observerGeneration == restoreGen,
                  dataStore === store else { return }
        }

        if !optOutHosts.contains(host) && observerGeneration == restoreGen {
            restoredHosts.insert(host)
        }
    }

    // MARK: - Keychain Backup (Device-only, bounded, short-lived, never log values)

    private struct CookieRecord: Codable, Equatable {
        let name: String
        let value: String
        let domain: String
        let path: String
        let secure: Bool
        let httpOnly: Bool
        let expiresDate: Date?
        let sameSitePolicy: String?
        let hostOnly: Bool?
    }

    private struct SnapshotData: Codable {
        let host: String
        let createdAt: Date
        let cookies: [CookieRecord]
    }

    private func saveKeychainSnapshot(cookies: [HTTPCookie], forHost host: String) {
        guard persistent, !isClearing, !optOutHosts.contains(host) else { return }
        var records: [CookieRecord] = []
        for c in cookies.prefix(Self.maxSnapshotsPerHost) {
            let sameSiteStr: String? = c.sameSitePolicy?.rawValue

            let rawDomain = c.domain.lowercased()
            let hasLeadingDot = rawDomain.hasPrefix(".")
            // Exact host-only preferred: host-only cookies do not have a leading dot.
            // Preserve leading dot bit with equality
            let isHostOnly = !hasLeadingDot
            let storedDomain: String
            if !isHostOnly && !hasLeadingDot {
                storedDomain = "." + rawDomain
            } else if isHostOnly && hasLeadingDot {
                storedDomain = String(rawDomain.drop(while: { $0 == "." }))
            } else {
                storedDomain = rawDomain
            }

            let r = CookieRecord(
                name: c.name,
                value: c.value,
                domain: storedDomain,
                path: c.path,
                secure: c.isSecure,
                httpOnly: c.isHTTPOnly,
                expiresDate: c.expiresDate,
                sameSitePolicy: sameSiteStr,
                hostOnly: isHostOnly
            )
            records.append(r)
        }

        // Avoid resetting age when snapshot contents unchanged
        var creationDate = Date()
        if let existing = loadKeychainSnapshot(forHost: host) {
            if existing.cookies == records {
                creationDate = existing.createdAt
            }
        }

        let snapshot = SnapshotData(host: host, createdAt: creationDate, cookies: records)
        guard let encoded = try? JSONEncoder().encode(snapshot),
              encoded.count <= Self.maxSnapshotBytes else {
            // On write failure invalidate old backup
            deleteKeychainSnapshot(forHost: host)
            return
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: host
        ]

        let updateAttributes: [String: Any] = [
            kSecValueData as String: encoded
        ]

        // atomic SecItemUpdate then Add; don't delete old before add
        let updateStatus = SecItemUpdate(query as CFDictionary, updateAttributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = encoded
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus != errSecSuccess {
                // On write failure invalidate old backup
                deleteKeychainSnapshot(forHost: host)
            }
        } else if updateStatus != errSecSuccess {
            // On write failure invalidate old backup
            deleteKeychainSnapshot(forHost: host)
        }
    }

    private func invalidateSnapshot(forHost host: String) {
        guard persistent else { return }
        var cutoffs = UserDefaults.standard.dictionary(forKey: Self.snapshotCutoffKey) ?? [:]
        cutoffs[host] = Date().timeIntervalSince1970
        UserDefaults.standard.set(cutoffs, forKey: Self.snapshotCutoffKey)
    }

    private func loadKeychainSnapshot(forHost host: String) -> SnapshotData? {
        guard persistent else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: host,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        guard let snapshot = try? JSONDecoder().decode(SnapshotData.self, from: data),
              snapshot.host == host else { return nil }
        let globalCutoff = UserDefaults.standard.double(forKey: Self.globalSnapshotCutoffKey)
        let hostCutoff = UserDefaults.standard.dictionary(forKey: Self.snapshotCutoffKey)?[host] as? Double ?? 0
        let cutoff = max(globalCutoff, hostCutoff)
        return snapshot.createdAt.timeIntervalSince1970 >= cutoff ? snapshot : nil
    }

    private func deleteKeychainSnapshot(forHost host: String) {
        guard persistent else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: host
        ]
        SecItemDelete(query as CFDictionary)
    }

    private func deleteAllKeychainSnapshots() {
        guard persistent else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService
        ]
        SecItemDelete(query as CFDictionary)
    }

    private func makeStore() -> WKWebsiteDataStore {
        persistent ? WKWebsiteDataStore(forIdentifier: Self.storeIdentifier) : WKWebsiteDataStore.nonPersistent()
    }

    private func makeAlternateStore() -> WKWebsiteDataStore {
        persistent ? WKWebsiteDataStore(forIdentifier: Self.alternateStoreIdentifier) : WKWebsiteDataStore.nonPersistent()
    }

    /// The alternate store holds data on disk only after a site used it; a wipe or cache clear must reach it then,
    /// but must not create it for someone who never used per-site routing.
    private var alternateStoreMayHoldData: Bool {
        alternateStore != nil || (persistent && UserDefaults.standard.bool(forKey: Self.alternateStoreUsedKey))
    }

    /// Returns the session store, creating it (with the current connection policy applied before any WebView or
    /// navigation exists) when needed.
    func ensureStore(proxy: ProxyConfiguration?, generation: Int?) -> WKWebsiteDataStore {
        if let store = dataStore { return store }
        let store = makeStore()
        // Always explicit: a persistent store must never carry an earlier route when the connection mode is off.
        store.proxyConfigurations = proxy.map { [$0] } ?? []
        dataStore = store
        proxyGeneration = proxy == nil ? nil : generation
        isAlive = true
        setupCookieObserver(for: store)
        return store
    }

    /// Alternate-route store, created on demand with its own proxy configuration applied before any WebView exists.
    /// Always explicit (proxy or none): a persistent store must never keep an earlier route. No login-continuity
    /// snapshot is read or written for this store, so no cookie crosses between the two routes' stores.
    func ensureAlternateStore(proxy: ProxyConfiguration?, generation: Int?) -> WKWebsiteDataStore {
        if let store = alternateStore { return store }
        let store = makeAlternateStore()
        store.proxyConfigurations = proxy.map { [$0] } ?? []
        alternateStore = store
        alternateProxyGeneration = proxy == nil ? nil : generation
        if persistent { UserDefaults.standard.set(true, forKey: Self.alternateStoreUsedKey) }
        isAlive = true
        return store
    }

    /// Drops the alternate store reference only (its data stays on disk); the caller reset the tabs that used it.
    func detachAlternateStore() {
        alternateStore = nil
        alternateProxyGeneration = nil
    }

    func detachConnectionStore() {
        if let store = activeObserverStore, let bridge = cookieObserver {
            store.httpCookieStore.remove(bridge)
        }
        cookieObserver = nil
        activeObserverStore = nil
        observerGeneration &+= 1
        dataStore = nil
        proxyGeneration = nil
    }

    func noteVisited(_ url: URL?) {
        guard let url = url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, let site = siteDomain(forHost: host), !visitedSites.contains(site) else { return }
        visitedSites.append(site)
    }

    /// Clears every cookie/storage item of the session and drops the store.
    func clear(completion: (() -> Void)? = nil) {
        clearPersisted(completion: completion)
    }

    /// True while the asynchronous wipe runs. The store is persistent with a fixed identifier, so no view may be
    /// created on it until the wipe finished (otherwise it could erase a login made right after).
    @Published public private(set) var isClearing = false
    private var clearWaiters: [() -> Void] = []

    /// Runs `body` once no wipe is in progress (immediately when none is).
    func whenClearFinished(_ body: @escaping () -> Void) {
        if isClearing { clearWaiters.append(body) } else { body() }
    }

    /// Removes the saved browser cookies/storage even when no browser was opened in this launch (the store is
    /// persistent). Saved Google passwords are a separate item and are not touched here.
    func clearPersisted(completion: (() -> Void)? = nil) {
        if let completion { clearWaiters.append(completion) }
        guard !isClearing else { return }
        isClearing = true
        let store = dataStore ?? makeStore()
        let otherStore: WKWebsiteDataStore? = alternateStoreMayHoldData ? (alternateStore ?? makeAlternateStore()) : nil
        detachConnectionStore()
        detachAlternateStore()
        isAlive = false
        visitedSites = []
        restoredHosts.removeAll()
        if persistent {
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.globalSnapshotCutoffKey)
        }
        deleteAllKeychainSnapshots()

        Task { @MainActor in
            // Let WebKit finish any already-issued writes before deleting its site data.
            for host in Array(inFlightRestores) where inFlightRestores.contains(host) {
                await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
                    restoreWaiters[host, default: []].append(waiter)
                }
            }
            await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
            if let otherStore {
                await otherStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
            }
            isClearing = false
            let waiters = clearWaiters
            clearWaiters = []
            waiters.forEach { $0() }
        }
    }

    /// Only WebKit's HTTP memory/disk cache types: cookies, login, localStorage/IndexedDB/service workers/Cache API
    /// and every other website data type stay untouched.
    private static let httpCacheTypes: Set<String> = [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache]

    /// True while an HTTP-cache wipe runs (a second request is refused instead of queued).
    @Published public private(set) var isClearingHTTPCache = false

    enum HTTPCacheClearOutcome: Equatable {
        case cleared
        case busy               // a session wipe or another cache wipe is running
        case nothingToClear     // isolated (non-persistent) run without a store: no browser page was ever loaded
    }

    /// Removes the HTTP cache of the app's actual store (the same fixed-identifier store the browser tabs use) without
    /// detaching it, so open pages, cookies and logins are unaffected.
    func clearHTTPCache() async -> HTTPCacheClearOutcome {
        guard !isClearing, !isClearingHTTPCache else { return .busy }
        var stores: [WKWebsiteDataStore] = []
        if let live = dataStore {
            stores.append(live)
        } else if persistent {
            stores.append(makeStore())   // same identifier = same on-disk store, even when no tab has been opened this launch
        }
        if let live = alternateStore {
            stores.append(live)
        } else if persistent && alternateStoreMayHoldData {
            stores.append(makeAlternateStore())
        }
        guard !stores.isEmpty else { return .nothingToClear }
        isClearingHTTPCache = true
        defer { isClearingHTTPCache = false }
        for store in stores {
            await store.removeData(ofTypes: Self.httpCacheTypes, modifiedSince: .distantPast)
        }
        return .cleared
    }

    /// Engine payload for one job: `{"site", "userAgent", "cookies": [...]}` with only cookies inside `site`.
    /// Returns nil when the session is gone (the job must then fail clearly instead of running logged-out).
    /// `fromAlternate` picks the store of the route the site is browsed on; the other store is never consulted.
    func cookiePayload(site: String, fromAlternate: Bool = false) async -> (payload: [String: Any], accepted: Int, rejected: Int)? {
        guard let store = fromAlternate ? alternateStore : dataStore else { return nil }
        let all = await store.httpCookieStore.allCookies()
        let now = Date()
        var out: [[String: Any]] = []
        var rejected = 0
        for cookie in all {
            let rawDomain = cookie.domain.lowercased()
            let hostOnly = !rawDomain.hasPrefix(".")
            let bare = rawDomain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard bare == site || bare.hasSuffix("." + site) else { continue }   // other sites: never exported
            if let expires = cookie.expiresDate, expires <= now { continue }
            if Self.isPartitioned(cookie) || cookie.name.isEmpty || cookie.portList != nil {
                rejected += 1
                continue
            }
            var item: [String: Any] = [
                "name": cookie.name, "value": cookie.value, "domain": rawDomain, "hostOnly": hostOnly,
                "path": cookie.path.isEmpty ? "/" : cookie.path, "secure": cookie.isSecure, "httpOnly": cookie.isHTTPOnly
            ]
            if let expires = cookie.expiresDate { item["expires"] = Int(expires.timeIntervalSince1970) }
            out.append(item)
        }
        return (["site": site, "userAgent": Self.userAgent, "cookies": out], out.count, rejected)
    }

    /// Partitioned (CHIPS) cookies are keyed to a top-level site that a downloader request cannot reproduce.
    private static func isPartitioned(_ cookie: HTTPCookie) -> Bool {
        for (key, value) in cookie.properties ?? [:] where key.rawValue.lowercased().contains("partition") {
            if let s = value as? String, !s.isEmpty { return true }
            if let b = value as? Bool, b { return true }
            if let n = value as? NSNumber, n.boolValue { return true }
        }
        return false
    }
}

private final class CookieObserverBridge: NSObject, WKHTTPCookieStoreObserver {
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        super.init()
    }

    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        DispatchQueue.main.async { [weak self] in
            self?.onChange()
        }
    }
}
