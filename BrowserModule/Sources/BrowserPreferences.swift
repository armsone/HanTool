import Foundation
import Combine
import CryptoKit
import Compression

public enum StartPageMode: String, Codable, CaseIterable {
    case builtInHome = "home"
    case customURL = "custom"

    public var displayName: String {
        switch self {
        case .builtInHome: return "기본 시작 화면 (즐겨찾기 목록)"
        case .customURL: return "사용자 지정 시작 주소"
        }
    }
}

/// Which kind of fresh browser surface is being started. `startPageMode`/`customHomeURL` keep the "new window" choice
/// (the pre-split storage fields); the "new tab" choice is stored beside them.
public enum StartPageTarget {
    case newWindow
    case newTab
}

public struct BookmarkCategory: Identifiable, Codable, Equatable {
    public let id: UUID
    public var name: String
    public let createdAt: Date

    public init(id: UUID = UUID(), name: String, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }
}

public struct BookmarkItem: Identifiable, Codable, Equatable {
    public let id: UUID
    public var title: String
    public var url: String
    public let createdAt: Date
    public var categoryID: UUID?

    public init(id: UUID = UUID(), title: String, url: String, createdAt: Date = Date(), categoryID: UUID? = nil) {
        self.id = id
        self.title = title
        self.url = url
        self.createdAt = createdAt
        self.categoryID = categoryID
    }

    public var host: String {
        URLComponents(string: url)?.host ?? ""
    }
}

/// One page's "hide this element" rules. `key` is the SHA-256 of the exact page URL (no raw URL/query is stored).
public struct AdHideRule: Codable, Equatable {
    public var key: String
    public var selectors: [String]
    public var updatedAt: Double
    /// Exact canonical hostname this legacy rule belongs to. Recorded only when its own exact page was visited (never guessed
    /// from the selector or the hash); nil for rules saved before this field existed. Lets other pages of that host promote it.
    public var host: String? = nil
}

/// One step of a slot path: the child of the previous element with this tag and these stable classes; `i` is its 1-based
/// position among the siblings of that same kind (0 = the only one). No `:nth-of-type` over arbitrary siblings.
public struct AdHideSlotStep: Codable, Equatable {
    public var t: String
    public var c: [String]
    public var i: Int

    public init(t: String, c: [String], i: Int) {
        self.t = t
        self.c = c
        self.i = i
    }
}

/// Stable descriptor of an ad SLOT (its container), independent of what the ad currently is: the nearest stable ancestor
/// (`a`: a unique `#id`, or `tag.class` with at most 12 matches of which `n` is the 1-based one; 0 = unique) plus the
/// relative path `p` down to the container. The ad iframe's provider/query/text are never part of it, so a new creative
/// in the same frame stays hidden.
///
/// A position number (`n`, a step's `i`) is NEVER an identity by itself: an inserted or reordered sibling moves it onto
/// unrelated content. Bounded branch metadata guards that: `an` (anchor matches when `n > 0`), `k` (same-kind sibling count
/// per step; the page script refuses a positional path whose branch no longer has that cardinality), `w` (layout witness:
/// up to 3 `tag.class` tokens of stable wrappers INSIDE the container but outside the creative; a positional slot must still
/// hold one) and `t` (original text bucket, positional slots only). A slot without `k` (older shape) is never trusted
/// positionally. A purely positional slot without a witness cannot be created and stays visible.
public struct AdHideSlot: Codable, Equatable {
    public var a: String
    public var n: Int
    public var p: [AdHideSlotStep]
    public var an: Int?
    public var k: [Int]?
    public var w: [String]?
    public var t: Int?

    public init(a: String, n: Int, p: [AdHideSlotStep], an: Int? = nil, k: [Int]? = nil, w: [String]? = nil, t: Int? = nil) {
        self.a = a
        self.n = n
        self.p = p
        self.an = an
        self.k = k
        self.w = w
        self.t = t
    }
}

/// One same-host hide rule: the selector plus a coarse structural fingerprint of the element it was made for
/// (`tag,parent,...|textBucket|flags`), so another page whose match looks different is left alone.
public struct AdHideSiteEntry: Codable, Equatable {
    public var selector: String
    public var fp: String
    /// Provider identity for a region that has no `#id`/`.class` anchor of its own (ancestor-anchored iframe, `:nth-of-type`
    /// footer slot): `host/path` of the ad iframe that is, or sits inside, the element (no query, no ids). The rule only
    /// hides an element that really holds such an iframe. nil = classic anchored rule (selector + fingerprint).
    public var ident: String?
    /// Parent steps from that iframe up to the hidden element (0 = the iframe itself); used when the selector no longer fits.
    public var up: Int?
    /// Stable slot descriptor (see `AdHideSlot`). Added to provider-identified rules when the live page is first seen with
    /// them, and to new rules that have no `#id`/`.class` anchor of their own. nil on rules saved before it existed.
    public var slot: AdHideSlot?

    public init(selector: String, fp: String, ident: String? = nil, up: Int? = nil, slot: AdHideSlot? = nil) {
        self.selector = selector
        self.fp = fp
        self.ident = ident
        self.up = up
        self.slot = slot
    }
}

/// All same-host hide rules of one exact canonical hostname (no parent/subdomain wildcard).
public struct AdHideSiteRule: Codable, Equatable {
    public var host: String
    public var entries: [AdHideSiteEntry]
    public var updatedAt: Double
}

public struct BrowserPreferencesData: Codable {
    public var startPageMode: StartPageMode = .builtInHome
    public var customHomeURL: String = ""
    /// nil = file written before the split: the new-tab choice is restored from the new-window one on load.
    public var newTabStartPageMode: StartPageMode?
    public var newTabCustomHomeURL: String?
    public var bookmarks: [BookmarkItem] = []
    public var categories: [BookmarkCategory] = []
    public var mouseGesturesEnabled: Bool = true
    public var autoRetryTLS: Bool = true
    public var adBlockingEnabled: Bool = true
    public var adHideRules: [AdHideRule] = []
    public var adHideSiteRules: [AdHideSiteRule] = []

    public init(
        startPageMode: StartPageMode = .builtInHome,
        customHomeURL: String = "",
        newTabStartPageMode: StartPageMode? = nil,
        newTabCustomHomeURL: String? = nil,
        bookmarks: [BookmarkItem] = [],
        categories: [BookmarkCategory] = [],
        mouseGesturesEnabled: Bool = true,
        autoRetryTLS: Bool = true,
        adBlockingEnabled: Bool = true,
        adHideRules: [AdHideRule] = [],
        adHideSiteRules: [AdHideSiteRule] = []
    ) {
        self.startPageMode = startPageMode
        self.customHomeURL = customHomeURL
        self.newTabStartPageMode = newTabStartPageMode
        self.newTabCustomHomeURL = newTabCustomHomeURL
        self.bookmarks = bookmarks
        self.categories = categories
        self.mouseGesturesEnabled = mouseGesturesEnabled
        self.autoRetryTLS = autoRetryTLS
        self.adBlockingEnabled = adBlockingEnabled
        self.adHideRules = adHideRules
        self.adHideSiteRules = adHideSiteRules
    }

    enum CodingKeys: String, CodingKey {
        case startPageMode, customHomeURL, newTabStartPageMode, newTabCustomHomeURL, bookmarks, categories, mouseGesturesEnabled, autoRetryTLS, adBlockingEnabled, adHideRules, adHideSiteRules
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.startPageMode = try container.decodeIfPresent(StartPageMode.self, forKey: .startPageMode) ?? .builtInHome
        self.customHomeURL = try container.decodeIfPresent(String.self, forKey: .customHomeURL) ?? ""
        self.newTabStartPageMode = try? container.decodeIfPresent(StartPageMode.self, forKey: .newTabStartPageMode)
        self.newTabCustomHomeURL = try? container.decodeIfPresent(String.self, forKey: .newTabCustomHomeURL)
        self.bookmarks = try container.decodeIfPresent([BookmarkItem].self, forKey: .bookmarks) ?? []
        self.categories = try container.decodeIfPresent([BookmarkCategory].self, forKey: .categories) ?? []
        self.mouseGesturesEnabled = try container.decodeIfPresent(Bool.self, forKey: .mouseGesturesEnabled) ?? true
        self.autoRetryTLS = try container.decodeIfPresent(Bool.self, forKey: .autoRetryTLS) ?? true
        self.adBlockingEnabled = try container.decodeIfPresent(Bool.self, forKey: .adBlockingEnabled) ?? true
        self.adHideRules = (try? container.decodeIfPresent([AdHideRule].self, forKey: .adHideRules)) ?? []
        self.adHideSiteRules = (try? container.decodeIfPresent([AdHideSiteRule].self, forKey: .adHideSiteRules)) ?? []
    }
}

@MainActor
public final class BrowserPreferences: ObservableObject {
    public static let maxBookmarks = 100
    public static let maxCategories = 30
    public static let maxCategoryNameLength = 50
    public static let maxURLLength = 4096
    public static let maxTitleLength = 200
    public static let maxFileSizeBytes = 512 * 1024

    @Published public private(set) var startPageMode: StartPageMode = .builtInHome
    @Published public private(set) var customHomeURL: String = ""
    @Published public private(set) var newTabStartPageMode: StartPageMode = .builtInHome
    @Published public private(set) var newTabCustomHomeURL: String = ""
    @Published public private(set) var bookmarks: [BookmarkItem] = []
    @Published public private(set) var categories: [BookmarkCategory] = []
    @Published public private(set) var mouseGesturesEnabled: Bool = true
    /// Default ON: browser-only pre-request TLS retry inside the validated proxy (see HTD Engine/connection.py).
    @Published public private(set) var autoRetryTLS: Bool = true
    /// Default ON: browser-only WebKit WKContentRuleList third-party ad blocking.
    @Published public private(set) var adBlockingEnabled: Bool = true
    /// Per exact page (hashed URL) element-hide rules made with the toolbar 광고 editor; independent of `adBlockingEnabled`.
    @Published public private(set) var adHideRules: [AdHideRule] = []
    /// Per exact canonical hostname element-hide rules (apply on every page of that host); see `AdHideSiteEntry`.
    @Published public private(set) var adHideSiteRules: [AdHideSiteRule] = []
    @Published public var errorMessage: String?

    public static let maxAdHidePages = 200
    public static let maxAdHideSites = 200
    public static let maxAdHideSelectorsPerPage = 30
    public static let maxAdHideSelectorLength = 300

    private let storeURL: URL
    /// Address bar names, search addresses and 길찾기 settings (own file: `address-search.json`).
    let addressSearch: AddressSearchStore

    public init(storeDirectory: URL) {
        self.storeURL = storeDirectory.appendingPathComponent("browser-preferences.json")
        self.addressSearch = AddressSearchStore(storeDirectory: storeDirectory)
        load()
    }

    // MARK: - Validation

    public static func validateWebURL(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxURLLength else { return nil }
        guard !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        guard var comps = URLComponents(string: trimmed),
              let scheme = comps.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              comps.user == nil, comps.password == nil,
              let host = comps.host, !host.isEmpty, host.count <= 253 else {
            return nil
        }
        guard !host.contains(" ") && !host.contains("\t") else { return nil }
        guard comps.url != nil else { return nil }
        return comps.string
    }

    public static func sanitizeTitle(_ raw: String, fallback: String) -> String {
        let filtered = String(raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
        let trimmed = filtered.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            let fbFiltered = String(fallback.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
            let fbTrimmed = fbFiltered.trimmingCharacters(in: .whitespacesAndNewlines)
            return String((fbTrimmed.isEmpty ? "즐겨찾기" : fbTrimmed).prefix(maxTitleLength))
        }
        return String(trimmed.prefix(maxTitleLength))
    }

    // MARK: - Persistence

    private func load() {
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return }
        do {
            let attr = try FileManager.default.attributesOfItem(atPath: storeURL.path)
            if let size = attr[.size] as? Int64, size > Int64(Self.maxFileSizeBytes) {
                NSLog("[HttpsDown] browser-preferences.json exceeds max size bound")
                return
            }
            let data = try Data(contentsOf: storeURL)
            let decoded = try JSONDecoder().decode(BrowserPreferencesData.self, from: data)

            var validCategories: [BookmarkCategory] = []
            for cat in decoded.categories.prefix(Self.maxCategories) {
                let safeName = Self.sanitizeCategoryName(cat.name)
                guard !safeName.isEmpty else { continue }
                validCategories.append(BookmarkCategory(id: cat.id, name: safeName, createdAt: cat.createdAt))
            }
            self.categories = validCategories

            var validBookmarks: [BookmarkItem] = []
            for item in decoded.bookmarks.prefix(Self.maxBookmarks) {
                guard let validURL = Self.validateWebURL(item.url) else { continue }
                let safeTitle = Self.sanitizeTitle(item.title, fallback: item.host)
                let validCatID = (item.categoryID != nil && validCategories.contains { $0.id == item.categoryID }) ? item.categoryID : nil
                validBookmarks.append(BookmarkItem(id: item.id, title: safeTitle, url: validURL, createdAt: item.createdAt, categoryID: validCatID))
            }
            self.bookmarks = validBookmarks

            (self.startPageMode, self.customHomeURL) = Self.validatedStartPage(decoded.startPageMode, decoded.customHomeURL)
            // First run after the split: the user's existing choice is restored into both entries unchanged.
            if let tabMode = decoded.newTabStartPageMode {
                (self.newTabStartPageMode, self.newTabCustomHomeURL) =
                    Self.validatedStartPage(tabMode, decoded.newTabCustomHomeURL ?? "")
            } else {
                self.newTabStartPageMode = self.startPageMode
                self.newTabCustomHomeURL = self.customHomeURL
            }

            self.mouseGesturesEnabled = decoded.mouseGesturesEnabled
            self.autoRetryTLS = decoded.autoRetryTLS
            self.adBlockingEnabled = decoded.adBlockingEnabled

            var seenKeys = Set<String>()
            self.adHideRules = decoded.adHideRules.prefix(Self.maxAdHidePages).compactMap { rule in
                guard Self.isValidAdHideKey(rule.key), seenKeys.insert(rule.key).inserted else { return nil }
                let sels = rule.selectors.filter(Self.isValidAdHideSelector).prefix(Self.maxAdHideSelectorsPerPage)
                let ruleHost = rule.host.flatMap { Self.isValidAdHideHost($0) ? $0 : nil }
                return sels.isEmpty ? nil : AdHideRule(key: rule.key, selectors: Array(sels), updatedAt: rule.updatedAt, host: ruleHost)
            }

            var seenHosts = Set<String>()
            self.adHideSiteRules = decoded.adHideSiteRules.prefix(Self.maxAdHideSites).compactMap { rule in
                guard Self.isValidAdHideHost(rule.host), seenHosts.insert(rule.host).inserted else { return nil }
                var seenSel = Set<String>()
                // A damaged slot descriptor is dropped on its own; the rule itself (selector / provider identity) stays.
                let entries = rule.entries.map { e -> AdHideSiteEntry in
                    var e = e
                    if let slot = e.slot, !Self.isValidAdHideSlot(slot) { e.slot = nil }
                    return e
                }.filter {
                    Self.isValidAdHideSiteEntry($0) && seenSel.insert($0.selector).inserted
                }.prefix(Self.maxAdHideSelectorsPerPage)
                return entries.isEmpty ? nil : AdHideSiteRule(host: rule.host, entries: Array(entries), updatedAt: rule.updatedAt)
            }
        } catch {
            NSLog("[HttpsDown] failed to load browser-preferences: \(error.localizedDescription)")
        }
    }

    private func persist() -> Bool {
        do {
            let dataObj = BrowserPreferencesData(
                startPageMode: startPageMode,
                customHomeURL: customHomeURL,
                newTabStartPageMode: newTabStartPageMode,
                newTabCustomHomeURL: newTabCustomHomeURL,
                bookmarks: bookmarks,
                categories: categories,
                mouseGesturesEnabled: mouseGesturesEnabled,
                autoRetryTLS: autoRetryTLS,
                adBlockingEnabled: adBlockingEnabled,
                adHideRules: adHideRules,
                adHideSiteRules: adHideSiteRules
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let encoded = try encoder.encode(dataObj)
            guard encoded.count <= Self.maxFileSizeBytes else {
                NSLog("[HttpsDown] browser-preferences.json would exceed max size bound; not saved")
                self.errorMessage = "즐겨찾기 데이터가 저장 가능한 크기를 초과했습니다."
                return false
            }
            try encoded.write(to: storeURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storeURL.path)
            return true
        } catch {
            NSLog("[HttpsDown] failed to save browser-preferences: \(error.localizedDescription)")
            self.errorMessage = "설정을 파일에 저장하지 못했습니다."
            return false
        }
    }

    @discardableResult
    public func setMouseGesturesEnabled(_ enabled: Bool) -> Bool {
        self.mouseGesturesEnabled = enabled
        return persist()
    }

    @discardableResult
    public func setAutoRetryTLS(_ enabled: Bool) -> Bool {
        self.autoRetryTLS = enabled
        return persist()
    }

    @discardableResult
    public func setAdBlockingEnabled(_ enabled: Bool) -> Bool {
        self.adBlockingEnabled = enabled
        return persist()
    }

    // MARK: - Page element hiding (광고 editor)

    /// Stable key of the exact page: SHA-256 of scheme://host:port/path?query (fragment dropped, query kept verbatim so
    /// different articles of one path stay separate). Neither the URL nor the query is ever stored in clear text.
    public static func adHidePageKey(_ url: URL?) -> String? {
        guard let url = url, let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = c.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = c.host?.lowercased(), !host.isEmpty, c.user == nil, c.password == nil else { return nil }
        let port = c.port ?? (scheme == "https" ? 443 : 80)
        var canonical = "\(scheme)://\(host):\(port)\(c.percentEncodedPath.isEmpty ? "/" : c.percentEncodedPath)"
        if let q = c.percentEncodedQuery { canonical += "?\(q)" }
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func isValidAdHideKey(_ key: String) -> Bool {
        key.utf8.count == 64 && key.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }
    }

    /// Only the plain `tag.class#id > :nth-of-type(n)` shapes the editor generates; nothing that could leave a CSS rule.
    static func isValidAdHideSelector(_ s: String) -> Bool {
        !s.isEmpty && s.utf8.count <= maxAdHideSelectorLength
            && s.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122)
                || $0 == 95 || $0 == 45 || $0 == 46 || $0 == 35 || $0 == 58 || $0 == 40 || $0 == 41 || $0 == 62 || $0 == 32 }
    }

    public func adHideSelectors(forKey key: String) -> [String] {
        adHideRules.first(where: { $0.key == key })?.selectors ?? []
    }

    /// Replaces one page's list (empty removes it). On a refused or failed write the previous data is restored.
    @discardableResult
    public func setAdHideSelectors(_ selectors: [String], forKey key: String) -> Bool {
        guard Self.isValidAdHideKey(key), selectors.count <= Self.maxAdHideSelectorsPerPage,
              selectors.allSatisfy(Self.isValidAdHideSelector) else {
            errorMessage = "이 페이지에는 숨김 영역을 더 저장할 수 없습니다."
            return false
        }
        let previous = adHideRules
        let keptHost = previous.first(where: { $0.key == key })?.host
        var next = previous.filter { $0.key != key }
        if !selectors.isEmpty {
            guard next.count < Self.maxAdHidePages else {
                errorMessage = "숨김 영역을 저장할 수 있는 페이지는 최대 \(Self.maxAdHidePages)개입니다."
                return false
            }
            next.append(AdHideRule(key: key, selectors: selectors, updatedAt: Date().timeIntervalSince1970, host: keptHost))
        }
        adHideRules = next
        if persist() { return true }
        adHideRules = previous
        return false
    }

    // MARK: - Same-host element hiding

    /// Canonical exact hostname of a web page: lower-case, no trailing dot, no port/scheme. Reuses `validateWebURL`
    /// (http/https, no credentials, bounded host). Subdomains stay separate hosts; no parent-domain inference.
    public static func adHideSiteHost(_ url: URL?) -> String? {
        guard let url = url, let valid = validateWebURL(url.absoluteString),
              let host = URLComponents(string: valid)?.host else { return nil }
        var h = host.lowercased()
        while h.hasSuffix(".") { h.removeLast() }
        return isValidAdHideHost(h) ? h : nil
    }

    static func isValidAdHideHost(_ h: String) -> Bool {
        !h.isEmpty && h.utf8.count <= 253 && !h.hasPrefix(".") && !h.hasSuffix(".")
            && h.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 122) || $0 == 45 || $0 == 46 || $0 == 58 }
    }

    /// `tag,parent,..(<=4 tags)|textBucket 0-4|flags 0-255`, as produced by the editor script.
    static func isValidAdHideFingerprint(_ fp: String) -> Bool {
        guard fp.utf8.count <= 120 else { return false }
        let parts = fp.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 3, let bucket = Int(parts[1]), (0...4).contains(bucket),
              let flags = Int(parts[2]), (0...255).contains(flags) else { return false }
        let tags = parts[0].split(separator: ",", omittingEmptySubsequences: false)
        return (1...4).contains(tags.count) && tags.allSatisfy { t in
            guard let f = t.utf8.first, f >= 97 && f <= 122 else { return false }
            return t.utf8.allSatisfy { ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 45 }
        }
    }

    private static let genericAnchorNames: Set<String> = [
        "container", "content", "contents", "wrapper", "wrap", "main", "body", "article", "post", "view", "inner",
        "row", "col", "layout", "page", "box", "list", "item", "text", "title", "section", "area", "document", "entry"
    ]

    /// Classic same-host eligibility: no `:nth-of-type`, and the element's own compound carries a non-generic
    /// `#id` or `.class` anchor (>= 3 chars). Layout-only chains (`div > div`, anchored only on an ancestor) are page-only
    /// unless the element holds an identifiable ad iframe (see `AdHideSiteEntry.ident`).
    static func isDomainAnchoredSelector(_ s: String) -> Bool {
        guard isValidAdHideSelector(s), !s.contains(":") else { return false }
        guard let last = s.components(separatedBy: " > ").last, !last.isEmpty, !last.contains(" ") else { return false }
        // Everything after the tag name is an `#id` / `.class` token.
        let tokens = last.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "#" || $0 == "." })
            .dropFirst().map(String.init)
        return tokens.contains { $0.count >= 3 && !genericAnchorNames.contains($0.lowercased()) }
    }

    static let maxAdHideIdentUp = 6

    /// `host/path` of an ad iframe, as produced by the editor script: lower-case `[a-z0-9._-]` host with a dot, then a path.
    static func isValidAdHideIdent(_ s: String) -> Bool {
        guard s.utf8.count >= 5, s.utf8.count <= 100, let slash = s.firstIndex(of: "/") else { return false }
        let host = s[s.startIndex..<slash]
        return host.contains(".") && !host.hasPrefix(".") && !host.hasSuffix(".")
            && s.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 122) || $0 == 46 || $0 == 45 || $0 == 95 || $0 == 47 }
    }

    private static let slotAnchorPattern = #"^(#[A-Za-z_][A-Za-z0-9_-]{0,39}|[a-z][a-z0-9-]{0,19}(\.[A-Za-z_][A-Za-z0-9_-]{0,39}){1,2})$"#
    private static let slotNamePattern = #"^[A-Za-z_][A-Za-z0-9_-]{0,39}$"#
    private static let slotForbiddenLeafTags: Set<String> = ["html", "body", "head", "main", "article", "script", "style"]

    private static let slotWitnessPattern = #"^[a-z][a-z0-9-]{0,19}\.[A-Za-z_][A-Za-z0-9_-]{0,39}$"#

    /// True when the slot depends on a position number (anchor ordinal or any step ordinal).
    static func isOrdinalAdHideSlot(_ slot: AdHideSlot) -> Bool {
        slot.n > 0 || slot.p.contains { $0.i > 0 }
    }

    /// Shape check of a slot descriptor produced by the editor script (what it means is decided on the page).
    /// Branch metadata is all-or-nothing and bounded; a positional slot with metadata must carry a witness and a text bucket.
    static func isValidAdHideSlot(_ slot: AdHideSlot) -> Bool {
        guard slot.a.range(of: slotAnchorPattern, options: .regularExpression) != nil,
              (0...12).contains(slot.n), (1...6).contains(slot.p.count) else { return false }
        for (index, step) in slot.p.enumerated() {
            guard step.t.range(of: "^[a-z][a-z0-9-]{0,19}$", options: .regularExpression) != nil,
                  step.c.count <= 2, step.c.allSatisfy({ $0.range(of: slotNamePattern, options: .regularExpression) != nil }),
                  (0...400).contains(step.i) else { return false }
            if index == slot.p.count - 1, slotForbiddenLeafTags.contains(step.t) { return false }
        }
        guard let k = slot.k else {
            // Older shape: kept as is (nothing is deleted); the page script never trusts its positions.
            return slot.an == nil && slot.w == nil && slot.t == nil
        }
        guard k.count == slot.p.count else { return false }
        for (index, step) in slot.p.enumerated() {
            guard (1...400).contains(k[index]) else { return false }
            let consistent = step.i == 0 ? k[index] == 1 : (k[index] >= 2 && step.i <= k[index])
            if !consistent { return false }
        }
        if slot.n > 0 {
            guard let an = slot.an, (2...12).contains(an), slot.n <= an else { return false }
        } else if slot.an != nil { return false }
        let w = slot.w ?? []
        guard w.count <= 3, Set(w).count == w.count,
              w.allSatisfy({ $0.range(of: slotWitnessPattern, options: .regularExpression) != nil }) else { return false }
        if isOrdinalAdHideSlot(slot) {
            guard !w.isEmpty, let t = slot.t, (0...4).contains(t) else { return false }
        } else if slot.t != nil { return false }
        return true
    }

    /// A host rule is classic (own non-generic `#id`/`.class`, no `:` in the selector), provider-identified (`ident` + `up`,
    /// selector may use ancestors and `:nth-of-type`) and/or slot-described (`slot`; without an ident the selector is only
    /// the position it was made at). The page script still guards every kind on every page.
    static func isValidAdHideSiteEntry(_ e: AdHideSiteEntry) -> Bool {
        guard isValidAdHideFingerprint(e.fp) else { return false }
        if let slot = e.slot, !isValidAdHideSlot(slot) { return false }
        if let ident = e.ident {
            guard isValidAdHideIdent(ident), let up = e.up, (0...maxAdHideIdentUp).contains(up) else { return false }
            return isValidAdHideSelector(e.selector)
        }
        if e.slot != nil { return e.up == nil && isValidAdHideSelector(e.selector) }
        return e.up == nil && isDomainAnchoredSelector(e.selector)
    }

    /// Slot descriptor from the page script's JSON (nil when missing or malformed).
    static func adHideSlot(fromJSON value: Any?) -> AdHideSlot? {
        guard let d = value as? [String: Any], let a = d["a"] as? String, let n = (d["n"] as? NSNumber)?.intValue,
              let list = d["p"] as? [[String: Any]] else { return nil }
        var steps: [AdHideSlotStep] = []
        for item in list {
            guard let t = item["t"] as? String, let c = item["c"] as? [String], let i = (item["i"] as? NSNumber)?.intValue else { return nil }
            steps.append(AdHideSlotStep(t: t, c: c, i: i))
        }
        var slot = AdHideSlot(a: a, n: n, p: steps)
        if let raw = d["k"] {
            guard let list = raw as? [Any], list.count <= 6 else { return nil }
            var k: [Int] = []
            for item in list {
                guard let v = (item as? NSNumber)?.intValue else { return nil }
                k.append(v)
            }
            slot.k = k
        }
        if let raw = d["an"] {
            guard let v = (raw as? NSNumber)?.intValue else { return nil }
            slot.an = v
        }
        if let raw = d["w"] {
            guard let w = raw as? [String], w.count <= 3 else { return nil }
            slot.w = w
        }
        if let raw = d["t"] {
            guard let v = (raw as? NSNumber)?.intValue else { return nil }
            slot.t = v
        }
        return isValidAdHideSlot(slot) ? slot : nil
    }

    public func adHideSiteEntries(forHost host: String) -> [AdHideSiteEntry] {
        adHideSiteRules.first(where: { $0.host == host })?.entries ?? []
    }

    /// Replaces one host's list (empty removes it). On a refused or failed write the previous data is restored.
    @discardableResult
    public func setAdHideSiteEntries(_ entries: [AdHideSiteEntry], forHost host: String) -> Bool {
        guard Self.isValidAdHideHost(host), entries.count <= Self.maxAdHideSelectorsPerPage,
              entries.allSatisfy(Self.isValidAdHideSiteEntry) else {
            errorMessage = "이 사이트에는 숨김 영역을 더 저장할 수 없습니다."
            return false
        }
        let previous = adHideSiteRules
        var next = previous.filter { $0.host != host }
        if !entries.isEmpty {
            guard next.count < Self.maxAdHideSites else {
                errorMessage = "숨김 영역을 저장할 수 있는 사이트는 최대 \(Self.maxAdHideSites)개입니다."
                return false
            }
            next.append(AdHideSiteRule(host: host, entries: entries, updatedAt: Date().timeIntervalSince1970))
        }
        adHideSiteRules = next
        if persist() { return true }
        adHideSiteRules = previous
        return false
    }

    /// Adds the slot descriptor to provider-identified host rules that were saved without one, or with an older-shape one
    /// that has no branch metadata (matched by selector; the descriptor is derived from the live element the provider
    /// identity resolved). One write; the previous data is restored if it fails. Nothing else of a rule changes and no
    /// rule is removed.
    @discardableResult
    public func attachAdHideSlots(_ slots: [String: AdHideSlot], forHost host: String) -> Bool {
        guard Self.isValidAdHideHost(host), !slots.isEmpty,
              let index = adHideSiteRules.firstIndex(where: { $0.host == host }) else { return false }
        var rule = adHideSiteRules[index]
        var changed = false
        for i in rule.entries.indices {
            let e = rule.entries[i]
            guard e.slot?.k == nil, e.ident != nil, let slot = slots[e.selector], Self.isValidAdHideSlot(slot) else { continue }
            rule.entries[i].slot = slot
            changed = true
        }
        guard changed else { return false }
        let previous = adHideSiteRules
        var next = previous
        next[index] = rule
        adHideSiteRules = next
        if persist() { return true }
        adHideSiteRules = previous
        return false
    }

    /// Moves the given legacy page selectors (only those still in that page's rule) to the host's rules in ONE write.
    /// Both lists are restored if the write fails, so nothing is lost; selectors that do not fit stay page-only.
    @discardableResult
    public func promoteAdHidePageSelectors(_ promoted: [AdHideSiteEntry], pageKey: String, host: String) -> Bool {
        guard Self.isValidAdHideKey(pageKey), Self.isValidAdHideHost(host) else { return false }
        let pageHost = adHideRules.first(where: { $0.key == pageKey })?.host
        // A rule associated with another host never moves here.
        if let pageHost = pageHost, pageHost != host { return false }
        let pageSels = adHideSelectors(forKey: pageKey)
        var site = adHideSiteEntries(forHost: host)
        var moved = Set<String>()
        for e in promoted where Self.isValidAdHideSiteEntry(e) && pageSels.contains(e.selector) {
            if let existing = site.first(where: { $0.selector == e.selector }) {
                // Different fingerprint would fail on this page: keep the legacy page rule, never replace the host entry.
                // Provider-identified rules do not depend on the (dynamic) fingerprint: same provider + depth is the same rule.
                if e.ident != nil ? (existing.ident == e.ident && existing.up == e.up)
                    : (e.slot != nil ? existing.slot == e.slot : (existing.ident == nil && existing.slot == nil && existing.fp == e.fp)) {
                    moved.insert(e.selector)
                }
                continue
            }
            guard site.count < Self.maxAdHideSelectorsPerPage else { continue }
            site.append(e)
            moved.insert(e.selector)
        }
        guard !moved.isEmpty else { return false }
        let siteIsNew = !adHideSiteRules.contains { $0.host == host }
        let remainingPage = pageSels.filter { !moved.contains($0) }
        guard !siteIsNew || adHideSiteRules.count < Self.maxAdHideSites else { return false }

        let previousPage = adHideRules, previousSite = adHideSiteRules
        var nextPage = previousPage.filter { $0.key != pageKey }
        if !remainingPage.isEmpty {
            nextPage.append(AdHideRule(key: pageKey, selectors: remainingPage, updatedAt: Date().timeIntervalSince1970, host: pageHost ?? host))
        }
        var nextSite = previousSite.filter { $0.host != host }
        nextSite.append(AdHideSiteRule(host: host, entries: site, updatedAt: Date().timeIntervalSince1970))
        adHideRules = nextPage
        adHideSiteRules = nextSite
        if persist() { return true }
        adHideRules = previousPage
        adHideSiteRules = previousSite
        return false
    }

    /// Legacy page rules explicitly associated with exactly this hostname (rules without a recorded host are never listed).
    public func adHideLegacyKeys(forHost host: String) -> [String] {
        adHideRules.filter { $0.host == host }.map { $0.key }
    }

    /// Records the host of a legacy page rule once its own exact page was visited. Only a rule without a host is changed
    /// (one persist, restored on failure); an existing association is never overwritten.
    @discardableResult
    public func associateAdHidePage(key: String, host: String) -> Bool {
        guard Self.isValidAdHideKey(key), Self.isValidAdHideHost(host),
              let i = adHideRules.firstIndex(where: { $0.key == key }), adHideRules[i].host == nil else { return false }
        let previous = adHideRules
        adHideRules[i].host = host
        if persist() { return true }
        adHideRules = previous
        return false
    }

    // MARK: - Categories Management

    public static func sanitizeCategoryName(_ raw: String) -> String {
        let filtered = String(raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
        let trimmed = filtered.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(maxCategoryNameLength))
    }

    @discardableResult
    public func addCategory(name: String) -> BookmarkCategory? {
        let safe = Self.sanitizeCategoryName(name)
        guard !safe.isEmpty else {
            errorMessage = "카테고리 이름을 입력해 주세요."
            return nil
        }
        if categories.count >= Self.maxCategories {
            errorMessage = "카테고리는 최대 \(Self.maxCategories)개까지 생성할 수 있습니다."
            return nil
        }
        if categories.contains(where: { $0.name == safe }) {
            errorMessage = "이미 존재하는 카테고리 이름입니다."
            return nil
        }
        let cat = BookmarkCategory(name: safe)
        categories.append(cat)
        errorMessage = nil
        if persist() {
            return cat
        } else {
            return nil
        }
    }

    @discardableResult
    public func renameCategory(id: UUID, newName: String) -> Bool {
        guard let idx = categories.firstIndex(where: { $0.id == id }) else { return false }
        let safe = Self.sanitizeCategoryName(newName)
        guard !safe.isEmpty else {
            errorMessage = "카테고리 이름을 입력해 주세요."
            return false
        }
        if categories.contains(where: { $0.id != id && $0.name == safe }) {
            errorMessage = "이미 존재하는 카테고리 이름입니다."
            return false
        }
        categories[idx].name = safe
        errorMessage = nil
        return persist()
    }

    @discardableResult
    public func removeCategory(id: UUID) -> Bool {
        guard let idx = categories.firstIndex(where: { $0.id == id }) else { return false }
        categories.remove(at: idx)
        for i in bookmarks.indices {
            if bookmarks[i].categoryID == id {
                bookmarks[i].categoryID = nil
            }
        }
        errorMessage = nil
        return persist()
    }

    public func canMoveCategory(id: UUID, by offset: Int) -> Bool {
        guard let idx = categories.firstIndex(where: { $0.id == id }) else { return false }
        return categories.indices.contains(idx + offset)
    }

    @discardableResult
    public func moveCategory(id: UUID, by offset: Int) -> Bool {
        guard canMoveCategory(id: id, by: offset),
              let from = categories.firstIndex(where: { $0.id == id }) else { return false }
        let to = from + offset
        let previous = categories
        let cat = categories.remove(at: from)
        categories.insert(cat, at: to)
        errorMessage = nil
        if persist() { return true }
        categories = previous
        return false
    }

    @discardableResult
    public func moveCategory(id: UUID, toIndex destination: Int) -> Bool {
        guard let from = categories.firstIndex(where: { $0.id == id }) else { return false }
        let to = min(max(destination, 0), categories.count - 1)
        guard to != from else { return true }
        let previous = categories
        let cat = categories.remove(at: from)
        categories.insert(cat, at: to)
        errorMessage = nil
        if persist() { return true }
        categories = previous
        return false
    }

    /// Atomically creates a named category and moves every currently uncategorized favorite into it.
    /// Order, ids, titles, URLs and creation dates are untouched; only `categoryID` changes.
    /// Any validation or write failure restores the previous in-memory state and leaves the stored file as it was.
    @discardableResult
    public func nameUncategorized(as name: String) -> BookmarkCategory? {
        let safe = Self.sanitizeCategoryName(name)
        guard !safe.isEmpty else {
            errorMessage = "카테고리 이름을 입력해 주세요."
            return nil
        }
        guard safe != "미분류" else {
            errorMessage = "'미분류'는 예약된 이름입니다. 다른 이름을 입력해 주세요."
            return nil
        }
        guard categories.count < Self.maxCategories else {
            errorMessage = "카테고리는 최대 \(Self.maxCategories)개까지 생성할 수 있습니다."
            return nil
        }
        guard !categories.contains(where: { $0.name == safe }) else {
            errorMessage = "이미 존재하는 카테고리 이름입니다."
            return nil
        }
        guard bookmarks.contains(where: { $0.categoryID == nil }) else {
            errorMessage = "이름을 붙일 미분류 즐겨찾기가 없습니다."
            return nil
        }

        let prevCategories = categories
        let prevBookmarks = bookmarks
        let cat = BookmarkCategory(name: safe)
        categories.append(cat)
        for i in bookmarks.indices where bookmarks[i].categoryID == nil {
            bookmarks[i].categoryID = cat.id
        }
        errorMessage = nil
        if persist() {
            return cat
        }
        categories = prevCategories
        bookmarks = prevBookmarks
        return nil
    }

    @discardableResult
    public func assignBookmark(id: UUID, categoryID: UUID?) -> Bool {
        guard let idx = bookmarks.firstIndex(where: { $0.id == id }) else { return false }
        if let catID = categoryID {
            guard categories.contains(where: { $0.id == catID }) else { return false }
        }
        bookmarks[idx].categoryID = categoryID
        errorMessage = nil
        return persist()
    }

    // MARK: - Bookmarks Management

    public func isBookmarked(url: String) -> Bool {
        guard let normalized = Self.validateWebURL(url) else { return false }
        return bookmarks.contains { $0.url == normalized }
    }

    public func bookmark(for url: String) -> BookmarkItem? {
        guard let normalized = Self.validateWebURL(url) else { return nil }
        return bookmarks.first { $0.url == normalized }
    }

    @discardableResult
    public func addBookmark(url: String, title: String, categoryID: UUID? = nil) -> Bool {
        guard let validURL = Self.validateWebURL(url) else {
            errorMessage = "유효한 웹 주소만 즐겨찾기할 수 있습니다."
            return false
        }
        if bookmarks.count >= Self.maxBookmarks {
            errorMessage = "즐겨찾기는 최대 \(Self.maxBookmarks)개까지 저장할 수 있습니다."
            return false
        }
        let fallback = URLComponents(string: validURL)?.host ?? "즐겨찾기"
        let safeTitle = Self.sanitizeTitle(title, fallback: fallback)
        let safeCatID = (categoryID != nil && categories.contains { $0.id == categoryID }) ? categoryID : nil

        if let existingIndex = bookmarks.firstIndex(where: { $0.url == validURL }) {
            bookmarks[existingIndex].title = safeTitle
            if safeCatID != nil {
                bookmarks[existingIndex].categoryID = safeCatID
            }
        } else {
            let item = BookmarkItem(title: safeTitle, url: validURL, categoryID: safeCatID)
            bookmarks.insert(item, at: 0)
        }
        errorMessage = nil
        return persist()
    }

    @discardableResult
    public func removeBookmark(id: UUID) -> Bool {
        guard let idx = bookmarks.firstIndex(where: { $0.id == id }) else { return false }
        bookmarks.remove(at: idx)
        errorMessage = nil
        return persist()
    }

    @discardableResult
    public func removeBookmark(url: String) -> Bool {
        guard let validURL = Self.validateWebURL(url) else { return false }
        guard let idx = bookmarks.firstIndex(where: { $0.url == validURL }) else { return false }
        bookmarks.remove(at: idx)
        errorMessage = nil
        return persist()
    }

    @discardableResult
    public func renameBookmark(id: UUID, newTitle: String) -> Bool {
        guard let idx = bookmarks.firstIndex(where: { $0.id == id }) else { return false }
        let safeTitle = Self.sanitizeTitle(newTitle, fallback: bookmarks[idx].host)
        bookmarks[idx].title = safeTitle
        errorMessage = nil
        return persist()
    }

    @discardableResult
    public func updateBookmark(id: UUID, title: String, url: String, categoryID: UUID?) -> (success: Bool, error: String?) {
        guard let idx = bookmarks.firstIndex(where: { $0.id == id }) else {
            let msg = "즐겨찾기를 찾을 수 없습니다."
            errorMessage = msg
            return (false, msg)
        }

        guard let validURL = Self.validateWebURL(url) else {
            let msg = "유효한 웹 주소만 즐겨찾기할 수 있습니다."
            errorMessage = msg
            return (false, msg)
        }

        // Duplicate URL check: if another bookmark already has this URL, reject
        if bookmarks.contains(where: { $0.id != id && $0.url == validURL }) {
            let msg = "이미 동일한 웹 주소의 즐겨찾기가 존재합니다."
            errorMessage = msg
            return (false, msg)
        }

        let safeCatID: UUID?
        if let catID = categoryID {
            guard categories.contains(where: { $0.id == catID }) else {
                let msg = "선택한 카테고리가 존재하지 않습니다."
                errorMessage = msg
                return (false, msg)
            }
            safeCatID = catID
        } else {
            safeCatID = nil
        }

        let fallback = URLComponents(string: validURL)?.host ?? "즐겨찾기"
        let safeTitle = Self.sanitizeTitle(title, fallback: fallback)

        // Preserve previous state for rollback on persistence failure
        let previousItem = bookmarks[idx]

        // Update in-place preserving UUID and index/order
        bookmarks[idx] = BookmarkItem(
            id: previousItem.id,
            title: safeTitle,
            url: validURL,
            createdAt: previousItem.createdAt,
            categoryID: safeCatID
        )

        if persist() {
            errorMessage = nil
            return (true, nil)
        } else {
            // Rollback
            bookmarks[idx] = previousItem
            let msg = errorMessage ?? "설정을 파일에 저장하지 못했습니다."
            return (false, msg)
        }
    }

    /// Moves one bookmark so it ends up at `destination` (index in the current array, clamped). Same position = no-op.
    /// Only the order changes: ids, titles, URLs and the item count stay exactly as they were.
    @discardableResult
    public func moveBookmark(id: UUID, toIndex destination: Int) -> Bool {
        guard let from = bookmarks.firstIndex(where: { $0.id == id }) else { return false }
        let to = min(max(destination, 0), bookmarks.count - 1)
        guard to != from else { return true }
        let item = bookmarks.remove(at: from)
        bookmarks.insert(item, at: to)
        errorMessage = nil
        return persist()
    }

    /// Moves a bookmark to the slot of another one (drag and drop onto a tile).
    @discardableResult
    public func moveBookmark(id: UUID, before targetID: UUID) -> Bool {
        guard id != targetID,
              let from = bookmarks.firstIndex(where: { $0.id == id }),
              let target = bookmarks.firstIndex(where: { $0.id == targetID }) else { return false }
        return moveBookmark(id: id, toIndex: target)
    }

    public func canMoveBookmark(id: UUID, by offset: Int) -> Bool {
        guard let idx = bookmarks.firstIndex(where: { $0.id == id }) else { return false }
        return bookmarks.indices.contains(idx + offset)
    }

    @discardableResult
    public func moveBookmark(id: UUID, by offset: Int) -> Bool {
        guard canMoveBookmark(id: id, by: offset),
              let idx = bookmarks.firstIndex(where: { $0.id == id }) else { return false }
        return moveBookmark(id: id, toIndex: idx + offset)
    }

    /// Atomically updates a bookmark's category and position within that category (or globally if destination is global index).
    /// If targetCategoryID is specified, the bookmark is assigned to targetCategoryID and placed at targetIndex within that category's items.
    @discardableResult
    public func moveBookmark(id: UUID, toCategory targetCategoryID: UUID?, atCategoryIndex targetIndex: Int) -> Bool {
        guard let currentIdx = bookmarks.firstIndex(where: { $0.id == id }) else { return false }
        if let catID = targetCategoryID {
            guard categories.contains(where: { $0.id == catID }) else { return false }
        }

        var item = bookmarks.remove(at: currentIdx)
        item.categoryID = targetCategoryID

        // Find the insertion position in bookmarks array corresponding to targetIndex in the destination category
        let matchingIndices = bookmarks.enumerated().filter { $0.element.categoryID == targetCategoryID }.map { $0.offset }
        let insertIndex: Int
        if matchingIndices.isEmpty {
            // If target category is currently empty in bookmarks:
            // Place it after existing items of preceding categories or at end
            if let targetCatID = targetCategoryID,
               let catIdx = categories.firstIndex(where: { $0.id == targetCatID }) {
                // Try to find the last bookmark belonging to any category before catIdx
                var foundInsert: Int? = nil
                for prevCat in categories[..<catIdx].reversed() {
                    if let lastMatching = bookmarks.lastIndex(where: { $0.categoryID == prevCat.id }) {
                        foundInsert = lastMatching + 1
                        break
                    }
                }
                if let foundInsert = foundInsert {
                    insertIndex = foundInsert
                } else if let nextCat = categories[(catIdx + 1)...].first(where: { cat in bookmarks.contains { $0.categoryID == cat.id } }),
                          let firstNext = bookmarks.firstIndex(where: { $0.categoryID == nextCat.id }) {
                    insertIndex = firstNext
                } else {
                    insertIndex = bookmarks.count
                }
            } else {
                // targetCategoryID is nil (uncategorized)
                // Place at end or beginning
                insertIndex = bookmarks.count
            }
        } else {
            let clampedIdx = min(max(targetIndex, 0), matchingIndices.count)
            if clampedIdx < matchingIndices.count {
                insertIndex = matchingIndices[clampedIdx]
            } else {
                insertIndex = matchingIndices[matchingIndices.count - 1] + 1
            }
        }

        let finalIndex = min(max(insertIndex, 0), bookmarks.count)
        bookmarks.insert(item, at: finalIndex)
        errorMessage = nil
        return persist()
    }

    // MARK: - Home / Start Page Settings

    private static func validatedStartPage(_ mode: StartPageMode, _ url: String) -> (StartPageMode, String) {
        if mode == .customURL, let valid = validateWebURL(url) { return (.customURL, valid) }
        return (.builtInHome, "")
    }

    /// The saved start page for a new window or a new tab.
    public func startPage(for target: StartPageTarget) -> (mode: StartPageMode, url: String) {
        switch target {
        case .newWindow: return (startPageMode, customHomeURL)
        case .newTab: return (newTabStartPageMode, newTabCustomHomeURL)
        }
    }

    @discardableResult
    public func setStartPage(mode: StartPageMode, customURL: String,
                             target: StartPageTarget = .newWindow) -> (success: Bool, error: String?) {
        var newMode = StartPageMode.builtInHome
        var newURL = ""
        if mode == .customURL {
            guard let valid = Self.validateWebURL(customURL) else {
                return (false, "유효한 http 또는 https 주소를 입력해 주세요.")
            }
            newMode = .customURL
            newURL = valid
        }
        switch target {
        case .newWindow: (startPageMode, customHomeURL) = (newMode, newURL)
        case .newTab: (newTabStartPageMode, newTabCustomHomeURL) = (newMode, newURL)
        }
        let ok = persist()
        return (ok, ok ? nil : "설정을 저장하지 못했습니다.")
    }

    // MARK: - Markdown Import/Export

    public func exportBookmarksMarkdown() -> String {
        var lines: [String] = ["# 즐겨찾기 목록", ""]

        for category in categories {
            let catBookmarks = bookmarks.filter { $0.categoryID == category.id }
            if !catBookmarks.isEmpty {
                lines.append("## \(category.name)")
                for item in catBookmarks {
                    lines.append("- [\(item.title)](\(item.url))")
                }
                lines.append("")
            }
        }

        let uncategorized = bookmarks.filter { $0.categoryID == nil }
        if !uncategorized.isEmpty {
            lines.append("## 미분류")
            for item in uncategorized {
                lines.append("- [\(item.title)](\(item.url))")
            }
            lines.append("")
        }

        let dataObj = BrowserPreferencesData(
            bookmarks: bookmarks,
            categories: categories
        )
        if let encoded = try? JSONEncoder().encode(dataObj) {
            lines.append("<!-- BrowserPreferencesData:\(encoded.base64EncodedString()) -->")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - HTD Share Code (copy/paste between HTD instances)
    //
    // Format: "HTDF2." + base64url( zlib( compact JSON ) )
    // Compact JSON: [[categoryName, ...], [[title, url, categoryNumber], ...]] where categoryNumber is
    // 0 for "uncategorized" and 1-based index into the category list otherwise. IDs, dates and settings are
    // never exported; they are recreated on import and the rows go through the regular bounded merge path.
    // This is only unreadable text, NOT confidentiality or tamper protection: anyone holding the code can import it.

    public static let shareCodePrefix = "HTDF2."
    /// Upper bound for a pasted code: prefix + base64url of the largest allowed (incompressible) payload.
    public static let maxShareCodeLength = shareCodePrefix.count + ((maxFileSizeBytes + 2) / 3) * 4

    private static func shareError(_ code: Int, _ message: String) -> NSError {
        NSError(domain: "BrowserPreferences", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }

    public func exportShareCode() throws -> String {
        guard !bookmarks.isEmpty else { throw Self.shareError(10, "공유할 즐겨찾기가 없습니다.") }
        var indexByID: [UUID: Int] = [:]
        for (i, cat) in categories.enumerated() { indexByID[cat.id] = i + 1 }
        let rows: [[Any]] = bookmarks.map { [$0.title, $0.url, $0.categoryID.flatMap { indexByID[$0] } ?? 0] }
        let root: [Any] = [categories.map { $0.name }, rows]
        guard let json = try? JSONSerialization.data(withJSONObject: root, options: [.withoutEscapingSlashes]),
              json.count <= Self.maxFileSizeBytes,
              let packed = Self.zlib(json, encode: true) else {
            throw Self.shareError(11, "즐겨찾기 데이터가 공유 가능한 크기를 초과했습니다.")
        }
        let b64 = packed.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return Self.shareCodePrefix + b64
    }

    /// Validates the whole code first; the store is only touched by the shared atomic merge path afterwards.
    public func importShareCode(_ code: String) throws -> Int {
        let invalid = Self.shareError(13, "올바른 HTD 즐겨찾기 공유 코드가 아니거나 손상되었습니다.")
        guard code.utf8.count <= Self.maxShareCodeLength + 4096 else { throw invalid }
        let compact = String(code.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
        guard compact.hasPrefix(Self.shareCodePrefix), compact.utf8.count <= Self.maxShareCodeLength else {
            throw Self.shareError(14, "지원하지 않는 공유 코드이거나 길이가 허용치를 초과했습니다.")
        }
        let body = compact.dropFirst(Self.shareCodePrefix.count)
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        guard !body.isEmpty, body.unicodeScalars.allSatisfy({ allowed.contains($0) }), body.count % 4 != 1 else { throw invalid }
        var b64 = String(body).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64.append("=") }
        guard let packed = Data(base64Encoded: b64),
              let json = Self.zlib(packed, encode: false),
              let root = try? JSONSerialization.jsonObject(with: json) as? [Any],
              root.count == 2,
              let names = root[0] as? [String],
              let rows = root[1] as? [[Any]],
              names.count <= Self.maxCategories,
              rows.count <= Self.maxBookmarks,
              names.allSatisfy({ $0.count <= Self.maxCategoryNameLength }) else { throw invalid }

        let cats = names.map { BookmarkCategory(name: $0) }
        var items: [BookmarkItem] = []
        items.reserveCapacity(rows.count)
        for row in rows {
            guard row.count == 3,
                  let title = row[0] as? String, title.count <= Self.maxTitleLength,
                  let url = row[1] as? String, url.count <= Self.maxURLLength,
                  let num = row[2] as? Int, num >= 0, num <= cats.count else { throw invalid }
            items.append(BookmarkItem(title: title, url: url, categoryID: num == 0 ? nil : cats[num - 1].id))
        }
        return try mergeBookmarks(categories: cats, items: items)
    }

    /// System zlib via Compression. Decoding is capped at `maxFileSizeBytes` (+1 byte to detect overflow).
    private static func zlib(_ input: Data, encode: Bool) -> Data? {
        guard !input.isEmpty else { return nil }
        let capacity = encode ? input.count + 1024 : maxFileSizeBytes + 1
        var out = Data(count: capacity)
        let written: Int = out.withUnsafeMutableBytes { dst in
            input.withUnsafeBytes { src in
                guard let d = dst.bindMemory(to: UInt8.self).baseAddress,
                      let s = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return encode
                    ? compression_encode_buffer(d, capacity, s, input.count, nil, COMPRESSION_ZLIB)
                    : compression_decode_buffer(d, capacity, s, input.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0, encode || written <= maxFileSizeBytes else { return nil }
        return out.prefix(written)
    }

    public func importBookmarksMarkdown(_ markdown: String) throws -> Int {
        guard markdown.utf8.count <= Self.maxFileSizeBytes else {
            throw NSError(domain: "BrowserPreferences", code: 1, userInfo: [NSLocalizedDescriptionKey: "즐겨찾기 파일 크기가 허용치를 초과했습니다."])
        }

        let prefix = "<!-- BrowserPreferencesData:"
        let suffix = " -->"
        if let startRange = markdown.range(of: prefix),
           let endRange = markdown.range(of: suffix, range: startRange.upperBound..<markdown.endIndex) {
            let base64String = String(markdown[startRange.upperBound..<endRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if let data = Data(base64Encoded: base64String),
               let decoded = try? JSONDecoder().decode(BrowserPreferencesData.self, from: data) {
                return try mergeBookmarks(categories: decoded.categories, items: decoded.bookmarks)
            }
        }

        // Fallback: parse plain Markdown text with headings and `- [title](url)`
        return try importPlainMarkdown(markdown)
    }

    private func importPlainMarkdown(_ markdown: String) throws -> Int {
        let lines = markdown.components(separatedBy: .newlines)
        var parsedCategories: [BookmarkCategory] = []
        var parsedItems: [BookmarkItem] = []
        var currentCatID: UUID? = nil

        let mdLinkRegex = try? NSRegularExpression(pattern: #"^\s*-\s*\[([^\]]*)\]\(([^)]+)\)"#, options: [])

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("## ") {
                let catName = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                let safeName = Self.sanitizeCategoryName(catName)
                if safeName.isEmpty || safeName == "미분류" {
                    currentCatID = nil
                } else {
                    if let existing = parsedCategories.first(where: { $0.name == safeName }) {
                        currentCatID = existing.id
                    } else {
                        let newCat = BookmarkCategory(name: safeName)
                        parsedCategories.append(newCat)
                        currentCatID = newCat.id
                    }
                }
                continue
            }

            guard let regex = mdLinkRegex else { continue }
            let nsLine = line as NSString
            let matches = regex.matches(in: line, options: [], range: NSRange(location: 0, length: nsLine.length))
            if let match = matches.first, match.numberOfRanges >= 3 {
                let rawTitle = nsLine.substring(with: match.range(at: 1))
                let rawURL = nsLine.substring(with: match.range(at: 2))
                if let validURL = Self.validateWebURL(rawURL) {
                    let safeTitle = Self.sanitizeTitle(rawTitle, fallback: URLComponents(string: validURL)?.host ?? "즐겨찾기")
                    let item = BookmarkItem(title: safeTitle, url: validURL, categoryID: currentCatID)
                    parsedItems.append(item)
                }
            }
        }

        guard !parsedItems.isEmpty else {
            throw NSError(domain: "BrowserPreferences", code: 2, userInfo: [NSLocalizedDescriptionKey: "가져올 즐겨찾기 데이터를 찾을 수 없습니다."])
        }

        return try mergeBookmarks(categories: parsedCategories, items: parsedItems)
    }

    public func importBookmarksHTML(_ html: String) throws -> Int {
        guard html.utf8.count <= Self.maxFileSizeBytes else {
            throw NSError(domain: "BrowserPreferences", code: 1, userInfo: [NSLocalizedDescriptionKey: "즐겨찾기 파일 크기가 허용치를 초과했습니다."])
        }

        let parsed = parseNetscapeBookmarksHTML(html)
        guard !parsed.items.isEmpty else {
            throw NSError(domain: "BrowserPreferences", code: 2, userInfo: [NSLocalizedDescriptionKey: "가져올 즐겨찾기 데이터를 찾을 수 없습니다."])
        }

        return try mergeBookmarks(categories: parsed.categories, items: parsed.items)
    }

    private func mergeBookmarks(categories newCategories: [BookmarkCategory], items newItems: [BookmarkItem]) throws -> Int {
        let prevCategories = self.categories
        let prevBookmarks = self.bookmarks

        var currentCategories = self.categories
        var categoryMap: [UUID: UUID] = [:]

        for cat in newCategories {
            let safeName = Self.sanitizeCategoryName(cat.name)
            guard !safeName.isEmpty else { continue }
            if let existing = currentCategories.first(where: { $0.name == safeName }) {
                categoryMap[cat.id] = existing.id
            } else if currentCategories.count < Self.maxCategories {
                let newCat = BookmarkCategory(name: safeName)
                currentCategories.append(newCat)
                categoryMap[cat.id] = newCat.id
            }
        }

        var currentBookmarks = self.bookmarks
        var importedCount = 0

        for item in newItems {
            guard let validURL = Self.validateWebURL(item.url) else { continue }
            if currentBookmarks.contains(where: { $0.url == validURL }) {
                continue
            }
            if currentBookmarks.count >= Self.maxBookmarks {
                break
            }

            let safeTitle = Self.sanitizeTitle(item.title, fallback: item.host)
            let assignedCatID: UUID?
            if let oldCatID = item.categoryID, let mappedID = categoryMap[oldCatID] {
                assignedCatID = mappedID
            } else {
                assignedCatID = nil
            }

            let newItem = BookmarkItem(title: safeTitle, url: validURL, createdAt: item.createdAt, categoryID: assignedCatID)
            currentBookmarks.append(newItem)
            importedCount += 1
        }

        self.categories = currentCategories
        self.bookmarks = currentBookmarks

        if persist() {
            return importedCount
        } else {
            self.categories = prevCategories
            self.bookmarks = prevBookmarks
            throw NSError(domain: "BrowserPreferences", code: 4, userInfo: [NSLocalizedDescriptionKey: "가져온 즐겨찾기 저장에 실패했습니다."])
        }
    }

    private func parseNetscapeBookmarksHTML(_ html: String) -> (categories: [BookmarkCategory], items: [BookmarkItem]) {
        var categories: [BookmarkCategory] = []
        var items: [BookmarkItem] = []
        var categoryStack: [UUID] = []

        // Tokenize HTML tags and text elements
        // Netscape format structure:
        // <DT><H3 ...>FolderName</H3>
        // <DL><p>
        //   <DT><A HREF="url" ...>Title</A>
        // </DL><p>
        let tagRegex = try? NSRegularExpression(pattern: #"<(/?[a-zA-Z0-9]+)([^>]*)>|([^<]+)"#, options: [])
        guard let regex = tagRegex else { return (categories, items) }

        let nsString = html as NSString
        let matches = regex.matches(in: html, options: [], range: NSRange(location: 0, length: nsString.length))

        var i = 0
        while i < matches.count {
            let m = matches[i]
            if m.range(at: 1).location != NSNotFound {
                let tagName = nsString.substring(with: m.range(at: 1)).lowercased()
                let attributes = m.range(at: 2).location != NSNotFound ? nsString.substring(with: m.range(at: 2)) : ""

                if tagName == "h3" {
                    // Extract folder name until </h3 or next tag
                    var folderName = ""
                    var j = i + 1
                    while j < matches.count {
                        let nextM = matches[j]
                        if nextM.range(at: 1).location != NSNotFound {
                            let nextTag = nsString.substring(with: nextM.range(at: 1)).lowercased()
                            if nextTag == "/h3" {
                                i = j
                                break
                            } else if nextTag.hasPrefix("/") {
                                break
                            }
                        } else if nextM.range(at: 3).location != NSNotFound {
                            folderName += nsString.substring(with: nextM.range(at: 3))
                        }
                        j += 1
                    }
                    let decodedName = Self.decodeHTMLEntities(folderName)
                    let safeName = Self.sanitizeCategoryName(decodedName)
                    if !safeName.isEmpty {
                        let catID: UUID
                        if let existing = categories.first(where: { $0.name == safeName }) {
                            catID = existing.id
                        } else {
                            let newCat = BookmarkCategory(name: safeName)
                            categories.append(newCat)
                            catID = newCat.id
                        }
                        categoryStack.append(catID)
                    }
                } else if tagName == "/dl" {
                    if !categoryStack.isEmpty {
                        categoryStack.removeLast()
                    }
                } else if tagName == "a" {
                    // Extract href attribute
                    let href = Self.extractAttribute(named: "href", from: attributes)
                    // Extract link text until </a>
                    var linkText = ""
                    var j = i + 1
                    while j < matches.count {
                        let nextM = matches[j]
                        if nextM.range(at: 1).location != NSNotFound {
                            let nextTag = nsString.substring(with: nextM.range(at: 1)).lowercased()
                            if nextTag == "/a" {
                                i = j
                                break
                            }
                        } else if nextM.range(at: 3).location != NSNotFound {
                            linkText += nsString.substring(with: nextM.range(at: 3))
                        }
                        j += 1
                    }

                    if let rawURL = href, let validURL = Self.validateWebURL(rawURL) {
                        let decodedTitle = Self.decodeHTMLEntities(linkText)
                        let fallback = URLComponents(string: validURL)?.host ?? "즐겨찾기"
                        let safeTitle = Self.sanitizeTitle(decodedTitle, fallback: fallback)
                        let currentCat = categoryStack.last
                        items.append(BookmarkItem(title: safeTitle, url: validURL, categoryID: currentCat))
                    }
                }
            }
            i += 1
        }

        return (categories, items)
    }

    public static func decodeHTMLEntities(_ string: String) -> String {
        var result = string
        let entities = [
            ("&quot;", "\""),
            ("&amp;", "&"),
            ("&apos;", "'"),
            ("&#39;", "'"),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&nbsp;", " ")
        ]
        for (ent, val) in entities {
            result = result.replacingOccurrences(of: ent, with: val, options: .caseInsensitive)
        }

        // Numeric entity decoding: &#123; or &#x1a;
        let numRegex = try? NSRegularExpression(pattern: #"&#(x?[0-9a-fA-F]+);"#, options: [])
        if let regex = numRegex {
            let nsStr = result as NSString
            let matches = regex.matches(in: result, options: [], range: NSRange(location: 0, length: nsStr.length))
            for m in matches.reversed() {
                let codeStr = nsStr.substring(with: m.range(at: 1))
                let scalarValue: UInt32?
                if codeStr.hasPrefix("x") || codeStr.hasPrefix("X") {
                    scalarValue = UInt32(codeStr.dropFirst(), radix: 16)
                } else {
                    scalarValue = UInt32(codeStr, radix: 10)
                }
                if let scalarVal = scalarValue, let scalar = UnicodeScalar(scalarVal) {
                    let charStr = String(Character(scalar))
                    let r = Range(m.range, in: result)!
                    result.replaceSubrange(r, with: charStr)
                }
            }
        }

        return result
    }

    private static func extractAttribute(named attrName: String, from string: String) -> String? {
        let pattern = #"(?i)\b"# + attrName + #"\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let ns = string as NSString
        guard let match = regex.firstMatch(in: string, options: [], range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        for i in 1...3 {
            let r = match.range(at: i)
            if r.location != NSNotFound {
                return decodeHTMLEntities(ns.substring(with: r))
            }
        }
        return nil
    }
}
