import SwiftUI
import AppKit
import MapKit
import CoreLocation

// MARK: - Text helpers

enum AddressText {
    static let maxQueryLength = 300
    static let maxNameLength = 40
    static let maxPlaceLength = 80
    static let reservedDirections = "길찾기"

    /// Comparison key for names and aliases: whitespace runs become one space, Korean text is composed (NFC),
    /// case and character width are ignored.
    static func fold(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            .precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "ko_KR"))
    }

    /// Trimmed, with every whitespace character (newline, tab, …) turned into a plain space.
    static func normalizedInput(_ text: String) -> String {
        var out = ""
        for ch in text.trimmingCharacters(in: .whitespacesAndNewlines) {
            out.append(ch.isWhitespace ? " " : ch)
        }
        return out
    }

    static func hasControlCharacters(_ s: String) -> Bool {
        s.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    /// Whitespace-separated words of `text` with their ranges (so the rest of the original text stays exact).
    static func words(_ text: String) -> [(word: String, range: Range<String.Index>)] {
        var result: [(word: String, range: Range<String.Index>)] = []
        var start: String.Index?
        var i = text.startIndex
        while i < text.endIndex {
            if text[i].isWhitespace {
                if let s = start {
                    result.append((word: String(text[s..<i]), range: s..<i))
                    start = nil
                }
            } else if start == nil {
                start = i
            }
            i = text.index(after: i)
        }
        if let s = start {
            result.append((word: String(text[s..<text.endIndex]), range: s..<text.endIndex))
        }
        return result
    }

    /// A word with something before and after '@' (e-mail / account shaped). Used only to refuse ambiguous bare
    /// address-or-account input and account-like names/places; a search phrase that merely contains '@' is not refused.
    static func looksLikeAccount(_ text: String) -> Bool {
        words(text).contains { w in
            guard let at = w.word.firstIndex(of: "@") else { return false }
            return at != w.word.startIndex && w.word.index(after: at) != w.word.endIndex
        }
    }
}

// MARK: - Search address templates

/// `https://host/path?q={query}` templates. The query is percent-encoded once, value only (every character
/// except unreserved ones), so it can never add a parameter, change the path or double-encode the template's own text.
enum AddressTemplate {
    static let placeholder = "{query}"
    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    /// nil = acceptable; otherwise a short message for the user.
    static func validate(_ template: String) -> String? {
        let t = template
        guard t.hasPrefix("https://") else { return "검색 주소는 https:// 로 시작해야 합니다." }
        guard t.count <= 1000, t.unicodeScalars.allSatisfy({ $0.isASCII && $0.value > 0x20 && $0.value != 0x7F }) else {
            return "검색 주소에는 공백이나 한글을 직접 쓸 수 없습니다."
        }
        guard let r = t.range(of: placeholder) else { return "검색 주소에 \(placeholder) 가 필요합니다." }
        let authorityEnd = t.dropFirst(8).firstIndex(where: { "/?#".contains($0) }) ?? t.endIndex
        guard r.lowerBound > authorityEnd else { return "\(placeholder) 는 사이트 이름 뒤쪽에만 쓸 수 있습니다." }
        if let hash = t.firstIndex(of: "#"), hash < r.lowerBound { return "\(placeholder) 는 # 앞에 있어야 합니다." }
        guard url(t, query: "테스트 a&b+c/d?e#f") != nil else { return "검색 주소 형식이 올바르지 않습니다." }
        return nil
    }

    static func url(_ template: String, query: String) -> URL? {
        guard template.hasPrefix("https://"), !query.isEmpty else { return nil }
        let s = template.replacingOccurrences(of: placeholder, with: encode(query))
        guard let c = URLComponents(string: s), c.scheme == "https", let host = c.host, !host.isEmpty,
              c.user == nil, c.password == nil else { return nil }
        return c.url
    }
}

// MARK: - Services

struct AddressService: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var aliases: [String]
    var homeURL: String
    /// Empty = this site has no known stable search address: typing `name 검색어` is then an ordinary search.
    var searchTemplate: String
    var enabled: Bool

    init(id: String, name: String, aliases: [String] = [], homeURL: String, searchTemplate: String = "", enabled: Bool = true) {
        self.id = id
        self.name = name
        self.aliases = aliases
        self.homeURL = homeURL
        self.searchTemplate = searchTemplate
        self.enabled = enabled
    }

    enum CodingKeys: String, CodingKey { case id, name, aliases, homeURL, searchTemplate, enabled }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.aliases = try c.decodeIfPresent([String].self, forKey: .aliases) ?? []
        self.homeURL = try c.decodeIfPresent(String.self, forKey: .homeURL) ?? ""
        self.searchTemplate = try c.decodeIfPresent(String.self, forKey: .searchTemplate) ?? ""
        self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    var isBuiltin: Bool { AddressServiceDefaults.builtinIDs.contains(id) }
    var allNames: [String] { [name] + aliases }
    var supportsSearch: Bool { !searchTemplate.isEmpty }
}

enum AddressServiceDefaults {
    static let mapID = "map"

    static let all: [AddressService] = [
        AddressService(id: "google", name: "Google", aliases: ["구글"],
                       homeURL: "https://www.google.com/",
                       searchTemplate: "https://www.google.com/search?q={query}"),
        AddressService(id: "naver", name: "네이버", aliases: ["naver"],
                       homeURL: "https://www.naver.com/",
                       searchTemplate: "https://search.naver.com/search.naver?where=nexearch&query={query}&sm=top_hty&fbm=0&ie=utf8"),
        AddressService(id: "youtube", name: "YouTube", aliases: ["유튜브"],
                       homeURL: "https://www.youtube.com/",
                       searchTemplate: "https://www.youtube.com/results?search_query={query}"),
        AddressService(id: "images", name: "이미지", aliases: ["images", "image", "구글이미지"],
                       homeURL: "https://www.google.com/imghp",
                       searchTemplate: "https://www.google.com/search?q={query}&tbm=isch"),
        AddressService(id: "coupang", name: "쿠팡", aliases: ["coupang"],
                       homeURL: "https://www.coupang.com/",
                       searchTemplate: "https://www.coupang.com/np/search?q={query}"),
        AddressService(id: mapID, name: "지도", aliases: ["map", "navermap", "네이버지도"],
                       homeURL: "https://map.naver.com/",
                       searchTemplate: "https://map.naver.com/p/search/{query}"),
        // No stable official search address is known for Instagram: home only.
        AddressService(id: "instagram", name: "인스타그램", aliases: ["instagram"],
                       homeURL: "https://www.instagram.com/"),
        AddressService(id: "github", name: "깃허브", aliases: ["github"],
                       homeURL: "https://github.com/",
                       searchTemplate: "https://github.com/search?q={query}"),
        AddressService(id: "googlephotos", name: "구글포토", aliases: ["googlephotos", "구글 포토", "google photos"],
                       homeURL: "https://photos.google.com/",
                       searchTemplate: "https://photos.google.com/search/{query}"),
        AddressService(id: "telegram", name: "텔레그램", aliases: ["telegram"],
                       homeURL: "https://web.telegram.org/"),
    ]

    static let builtinIDs: Set<String> = Set(all.map { $0.id })

    static func factory(_ id: String) -> AddressService? { all.first { $0.id == id } }
}

/// Text the settings editor works on (committed only after it validates as a whole).
struct AddressServiceDraft: Equatable {
    var name = ""
    var aliasesText = ""
    var homeURL = ""
    var searchTemplate = ""
    var enabled = true

    init() {}

    init(_ s: AddressService) {
        name = s.name
        aliasesText = s.aliases.joined(separator: ", ")
        homeURL = s.homeURL
        searchTemplate = s.searchTemplate
        enabled = s.enabled
    }
}

private struct AddressSearchData: Codable {
    var version = 1
    var services: [AddressService] = []
    var directionsEnabled = true
    var departFromCurrentLocation = true

    init() {}

    enum CodingKeys: String, CodingKey { case version, services, directionsEnabled, departFromCurrentLocation }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        services = try c.decodeIfPresent([AddressService].self, forKey: .services) ?? []
        directionsEnabled = try c.decodeIfPresent(Bool.self, forKey: .directionsEnabled) ?? true
        departFromCurrentLocation = try c.decodeIfPresent(Bool.self, forKey: .departFromCurrentLocation) ?? true
    }
}

/// The address bar's own settings (`address-search.json`, separate from browser-preferences.json). Every change is
/// validated as a whole, written atomically, and only then published; an invalid or failed change leaves the
/// current settings (and the file) untouched.
@MainActor
final class AddressSearchStore: ObservableObject {
    static let maxCustomServices = 50
    static let maxAliasesPerService = 10
    static let maxFileSizeBytes = 256 * 1024

    @Published private(set) var services: [AddressService] = AddressServiceDefaults.all
    @Published private(set) var directionsEnabled = true
    @Published private(set) var departFromCurrentLocation = true

    /// Set when an existing address-search.json could not be read. The file is left untouched until the user's first
    /// explicit save, which must first make a fresh, uniquely named copy of that exact file.
    private var unreadableFilePending = false
    @Published private(set) var loadWarning: String?

    private let storeURL: URL

    init(storeDirectory: URL) {
        self.storeURL = storeDirectory.appendingPathComponent("address-search.json")
        load()
    }

    // MARK: Validation

    struct ValidationError: Error { let message: String }

    /// Why `alias` cannot be a name or alias; nil when fine.
    static func aliasProblem(_ alias: String) -> String? {
        let a = AddressText.fold(alias)
        guard !a.isEmpty else { return "이름이 비어 있습니다." }
        guard alias.count <= AddressText.maxNameLength, !AddressText.hasControlCharacters(alias) else {
            return "이름은 \(AddressText.maxNameLength)자 이하의 한 줄이어야 합니다."
        }
        guard !alias.contains(",") else { return "이름에는 쉼표를 쓸 수 없습니다." }
        guard !AddressText.looksLikeAccount(alias) else { return "계정처럼 보이는 이름은 쓸 수 없습니다." }
        if a.split(separator: " ").first.map({ String($0) }) == AddressText.fold(AddressText.reservedDirections) {
            return "'\(AddressText.reservedDirections)'는 길찾기 전용입니다."
        }
        guard AddressInput.classify(alias) != .url else { return "주소처럼 보이는 이름은 쓸 수 없습니다." }
        return nil
    }

    /// First name/alias of `candidate` that another service already uses.
    private static func conflict(of candidate: AddressService, with others: [AddressService]) -> String? {
        for name in candidate.allNames {
            let key = AddressText.fold(name)
            if let other = others.first(where: { $0.id != candidate.id && $0.allNames.contains { AddressText.fold($0) == key } }) {
                return "'\(name)'는 '\(other.name)'에서 이미 쓰고 있습니다."
            }
        }
        return nil
    }

    static func validate(_ draft: AddressServiceDraft, editing id: String?, among services: [AddressService]) -> Result<AddressService, ValidationError> {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let p = aliasProblem(name) { return .failure(ValidationError(message: p)) }
        var aliases: [String] = []
        var seen: Set<String> = [AddressText.fold(name)]
        for raw in draft.aliasesText.split(separator: ",", omittingEmptySubsequences: true) {
            let a = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if a.isEmpty { continue }
            if let p = aliasProblem(a) { return .failure(ValidationError(message: "별칭 '\(a)': \(p)")) }
            if seen.insert(AddressText.fold(a)).inserted { aliases.append(a) }
        }
        guard aliases.count <= maxAliasesPerService else {
            return .failure(ValidationError(message: "별칭은 \(maxAliasesPerService)개까지 쓸 수 있습니다."))
        }
        guard let home = BrowserPreferences.validateWebURL(draft.homeURL) else {
            return .failure(ValidationError(message: "홈 주소는 http:// 또는 https:// 주소여야 합니다."))
        }
        let template = draft.searchTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        if !template.isEmpty, let p = AddressTemplate.validate(template) {
            return .failure(ValidationError(message: p))
        }
        let service = AddressService(id: id ?? "custom-\(UUID().uuidString)", name: name, aliases: aliases,
                                     homeURL: home, searchTemplate: template, enabled: draft.enabled)
        if let c = conflict(of: service, with: services) { return .failure(ValidationError(message: c)) }
        return .success(service)
    }

    // MARK: Lookups

    func service(id: String) -> AddressService? { services.first { $0.id == id } }

    func isModified(_ s: AddressService) -> Bool {
        guard let f = AddressServiceDefaults.factory(s.id) else { return false }
        return f != s
    }

    /// Address of one of the three picker engines: the edited template while it is enabled and valid, else the built-in one.
    func pickerTemplate(forServiceID id: String) -> String {
        if let s = service(id: id), s.enabled, s.supportsSearch, AddressTemplate.validate(s.searchTemplate) == nil {
            return s.searchTemplate
        }
        return AddressServiceDefaults.factory(id)?.searchTemplate ?? ""
    }

    // MARK: Changes (each returns a short error message, nil on success)

    func add(_ draft: AddressServiceDraft) -> String? {
        guard services.filter({ !$0.isBuiltin }).count < Self.maxCustomServices else {
            return "직접 추가한 사이트는 \(Self.maxCustomServices)개까지 쓸 수 있습니다."
        }
        switch Self.validate(draft, editing: nil, among: services) {
        case .failure(let e): return e.message
        case .success(let s): return commit(services: services + [s])
        }
    }

    func update(id: String, _ draft: AddressServiceDraft) -> String? {
        guard let index = services.firstIndex(where: { $0.id == id }) else { return "사이트를 찾을 수 없습니다." }
        switch Self.validate(draft, editing: id, among: services) {
        case .failure(let e): return e.message
        case .success(let s):
            var next = services
            next[index] = s
            return commit(services: next)
        }
    }

    func setEnabled(id: String, _ enabled: Bool) -> String? {
        guard let index = services.firstIndex(where: { $0.id == id }) else { return "사이트를 찾을 수 없습니다." }
        var next = services
        next[index].enabled = enabled
        return commit(services: next)
    }

    func delete(id: String) -> String? {
        guard let s = service(id: id), !s.isBuiltin else { return "기본 사이트는 삭제할 수 없습니다." }
        return commit(services: services.filter { $0.id != id })
    }

    func restoreDefault(id: String) -> String? {
        guard let factory = AddressServiceDefaults.factory(id), let index = services.firstIndex(where: { $0.id == id }) else {
            return "기본값이 없는 사이트입니다."
        }
        if let c = Self.conflict(of: factory, with: services) { return c }
        var next = services
        next[index] = factory
        return commit(services: next)
    }

    func restoreAllDefaults() -> String? {
        var next = services
        for factory in AddressServiceDefaults.all {
            if let index = next.firstIndex(where: { $0.id == factory.id }) { next[index] = factory } else { next.append(factory) }
        }
        for s in next where s.isBuiltin {
            if let c = Self.conflict(of: s, with: next) { return c }
        }
        return commit(services: next)
    }

    func setDirectionsEnabled(_ on: Bool) -> String? {
        commit(services: services, directions: on)
    }

    func setDepartFromCurrentLocation(_ on: Bool) -> String? {
        commit(services: services, depart: on)
    }

    private func commit(services next: [AddressService], directions: Bool? = nil, depart: Bool? = nil) -> String? {
        var data = AddressSearchData()
        data.services = next
        data.directionsEnabled = directions ?? directionsEnabled
        data.departFromCurrentLocation = depart ?? departFromCurrentLocation
        if let error = persist(data) { return error }
        services = next
        directionsEnabled = data.directionsEnabled
        departFromCurrentLocation = data.departFromCurrentLocation
        return nil
    }

    // MARK: Persistence

    private func persist(_ data: AddressSearchData) -> String? {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let encoded = try encoder.encode(data)
            guard encoded.count <= Self.maxFileSizeBytes else { return "주소창 설정이 저장 가능한 크기를 초과했습니다." }
            if unreadableFilePending {
                // Fail closed: never replace the unreadable file unless a copy of it was made first. The name is new
                // every time, and copyItem never overwrites, so an older .damaged-* copy can't be lost.
                guard FileManager.default.fileExists(atPath: storeURL.path) else {
                    unreadableFilePending = false
                    return try persistWritten(encoded)
                }
                let stamp = String(Int(Date().timeIntervalSince1970))
                let backup = storeURL.appendingPathExtension("damaged-\(stamp)-\(UUID().uuidString.prefix(8))")
                do {
                    try FileManager.default.copyItem(at: storeURL, to: backup)
                } catch {
                    NSLog("[HttpsDown] could not back up unreadable address-search.json")
                    return "기존 설정 파일을 읽을 수 없고 백업도 만들지 못해 저장하지 않았습니다. 파일은 그대로 두었습니다."
                }
                unreadableFilePending = false
            }
            return try persistWritten(encoded)
        } catch {
            NSLog("[HttpsDown] failed to save address-search.json")
            return "설정을 파일에 저장하지 못했습니다."
        }
    }

    private func persistWritten(_ encoded: Data) throws -> String? {
        try encoded.write(to: storeURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storeURL.path)
        loadWarning = nil
        return nil
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return }
        do {
            let attr = try FileManager.default.attributesOfItem(atPath: storeURL.path)
            if let size = attr[.size] as? Int64, size > Int64(Self.maxFileSizeBytes) {
                throw ValidationError(message: "too large")
            }
            let decoded = try JSONDecoder().decode(AddressSearchData.self, from: try Data(contentsOf: storeURL))
            services = Self.sanitized(decoded.services)
            directionsEnabled = decoded.directionsEnabled
            departFromCurrentLocation = decoded.departFromCurrentLocation
        } catch {
            // Unreadable file: run on the defaults and leave the file alone. persist() backs it up (uniquely) before
            // the first explicit save replaces it, and refuses to save if that backup fails.
            NSLog("[HttpsDown] failed to load address-search.json")
            unreadableFilePending = true
            loadWarning = "저장된 주소창 설정을 읽지 못해 기본값을 쓰고 있습니다. 설정을 바꾸거나 '전체 기본값 복원'을 하면 기존 파일을 별도 백업한 뒤 새로 저장합니다."
        }
    }

    /// Stored services → usable ones: all built-ins always exist (a bad field falls back to its default),
    /// custom ones with an invalid field are dropped, and an alias another service already took is removed.
    private static func sanitized(_ stored: [AddressService]) -> [AddressService] {
        var taken = Set<String>()
        var result: [AddressService] = []

        func clean(_ s: AddressService, fallback: AddressService?) -> AddressService? {
            var name = s.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if aliasProblem(name) != nil || taken.contains(AddressText.fold(name)) {
                guard let fallback else { return nil }
                name = fallback.name
            }
            var out = AddressService(id: s.id, name: name, homeURL: "", enabled: s.enabled)
            var keys: Set<String> = [AddressText.fold(name)]
            for a in s.aliases.prefix(maxAliasesPerService) {
                let t = a.trimmingCharacters(in: .whitespacesAndNewlines)
                let k = AddressText.fold(t)
                if aliasProblem(t) == nil, !taken.contains(k), keys.insert(k).inserted { out.aliases.append(t) }
            }
            if let home = BrowserPreferences.validateWebURL(s.homeURL) {
                out.homeURL = home
            } else if let fallback {
                out.homeURL = fallback.homeURL
            } else {
                return nil
            }
            let template = s.searchTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
            if template.isEmpty || AddressTemplate.validate(template) == nil {
                out.searchTemplate = template
            } else {
                out.searchTemplate = fallback?.searchTemplate ?? ""
            }
            taken.formUnion(keys)
            return out
        }

        for factory in AddressServiceDefaults.all {
            let source = stored.first { $0.id == factory.id } ?? factory
            result.append(clean(source, fallback: factory) ?? factory)
        }
        var ids = Set(result.map { $0.id })
        for s in stored where !AddressServiceDefaults.builtinIDs.contains(s.id) && s.id.hasPrefix("custom-") {
            guard result.count < AddressServiceDefaults.all.count + maxCustomServices, ids.insert(s.id).inserted,
                  let c = clean(s, fallback: nil) else { continue }
            result.append(c)
        }
        return result
    }
}

// MARK: - Address command

/// One row of the `/` list: choosing it only writes `name ` into the address field.
struct SlashChoice: Identifiable, Equatable {
    let id: String
    let name: String
    let hint: String
    var insertion: String { name + " " }
}

struct RouteRequest: Equatable {
    enum Origin: Equatable {
        case currentLocation
        case place(String)
        /// No origin given and "현재 위치에서 출발" is off: ask for one.
        case ask
    }
    var origin: Origin
    var destination: String
}

enum AddressCommand: Equatable {
    case empty
    /// A real web address: handed to `model.open` unchanged.
    case open(String)
    case openURL(URL)
    case hana(question: String, fresh: Bool)
    case hanaWindow
    case openAI
    case route(RouteRequest)
    /// Ordinary search words: the Google / 네이버 / YouTube choice.
    case pickEngine(String)
    /// Short message for the user; nothing is opened or sent anywhere.
    case invalid(String)
}

/// Turns the address field's text into one command. Order: real web address → 길찾기 / 지도 `A, B` → `이름 검색어`
/// → exact name/alias → unprefixed `A, B` → search choice.
@MainActor
enum AddressCommandResolver {
    static let accountMessage = "이메일·계정만 단독으로 입력하면 열거나 검색하지 않습니다. 검색하려면 '구글 ' 처럼 사이트 이름을 앞에 붙이세요."
    private static let routeFormatHint = "출발지, 도착지 형식으로 입력하세요. 예) 길찾기 장항동, 부산서면"

    static func resolve(_ raw: String, store: AddressSearchStore) -> AddressCommand {
        let text = AddressText.normalizedInput(raw)
        if text.isEmpty { return .empty }

        if AddressInput.classify(text) == .url {
            if !text.contains("://"), AddressText.looksLikeAccount(text) { return .invalid(accountMessage) }
            return .open(raw.trimmingCharacters(in: .whitespacesAndNewlines))   // the address itself is never rewritten
        }
        if text.count > AddressText.maxQueryLength {
            return .invalid("입력이 너무 깁니다. \(AddressText.maxQueryLength)자 이하로 줄여 주세요.")
        }

        let words = AddressText.words(text)
        // Only a bare single e-mail/account-shaped token is refused (it could be an address or credential typed by mistake).
        // `구글 user@example.com`, the search choice for a multi-word phrase, etc. may contain '@' on purpose.
        if words.count == 1, AddressText.looksLikeAccount(text) { return .invalid(accountMessage) }

        // Reserved Hana external window invocation: exact `하나 새창` only
        if HanaAddressCommand.isExternalWindowCommand(raw) {
            return .hanaWindow
        }

        // Reserved Hana companion invocation ahead of service aliases
        if let hanaParsed = HanaAddressCommand.parse(raw) {
            return .hana(question: hanaParsed.question, fresh: hanaParsed.fresh)
        }

        // Exact standalone generic AI shortcuts: `인공지능` and `AI` (case-insensitive)
        let foldedKey = AddressText.fold(text)
        if foldedKey == "인공지능" || foldedKey == "ai" || foldedKey == "/ai" || foldedKey == "/인공지능" {
            return .openAI
        }

        // An exact name or alias (`구글 포토`) wins over a shorter service prefix (`구글` + `포토`).
        let key = AddressText.fold(text)
        if let s = store.services.first(where: { $0.enabled && $0.allNames.contains { AddressText.fold($0) == key } }) {
            guard let home = BrowserPreferences.validateWebURL(s.homeURL), let url = URL(string: home) else {
                return .invalid("'\(s.name)' 홈 주소를 열 수 없습니다. 설정을 확인해 주세요.")
            }
            return .openURL(url)
        }

        let prefix = servicePrefix(text, words: words, services: store.services)

        if store.directionsEnabled {
            if let first = words.first, AddressText.fold(first.word) == AddressText.fold(AddressText.reservedDirections) {
                return explicitDirections(rest(of: text, after: first.range), store: store)
            }
            if let p = prefix, p.service.id == AddressServiceDefaults.mapID, p.rest.contains(",") {
                let parts = points(p.rest)
                guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return .invalid(routeFormatHint) }
                return routeCommand(origin: parts[0], destination: parts[1])
            }
        }

        if let p = prefix, p.service.supportsSearch {
            guard let url = AddressTemplate.url(p.service.searchTemplate, query: p.rest) else {
                return .invalid("'\(p.service.name)' 검색 주소를 만들 수 없습니다. 설정을 확인해 주세요.")
            }
            return .openURL(url)
        }

        // Last before the search choice: `A, B` with exactly two places. A service that searches (`구글 고양이, 강아지`)
        // and an exact name already took their input above.
        if store.directionsEnabled, text.contains(",") {
            let parts = points(text)
            if parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty,
               AddressInput.classify(parts[0]) != .url, AddressInput.classify(parts[1]) != .url {
                return routeCommand(origin: parts[0], destination: parts[1])
            }
        }
        return .pickEngine(text)
    }

    /// `/` (optionally `/네`) in the address field: every enabled service once under its canonical name, plus 길찾기
    /// when it is on. Only while the text is `/` followed by a name prefix without spaces; empty = not a command list.
    static func slashChoices(_ raw: String, store: AddressSearchStore) -> [SlashChoice] {
        let text = raw.drop(while: { $0.isWhitespace })
        guard text.hasPrefix("/") else { return [] }
        let typed = text.dropFirst()
        guard !typed.contains(where: { $0.isWhitespace }) else { return [] }
        let filter = AddressText.fold(String(typed))
        func matches(_ names: [String]) -> Bool {
            filter.isEmpty || names.contains { AddressText.fold($0).hasPrefix(filter) }
        }
        var out: [SlashChoice] = []
        for s in store.services where s.enabled && matches(s.allNames) {
            out.append(SlashChoice(id: s.id, name: s.name, hint: s.supportsSearch ? "검색어" : "홈 열기"))
        }
        if matches(["하나", "하나야", "하나씨"]) {
            out.append(SlashChoice(id: "hana-chat", name: "하나", hint: "대화"))
        }
        if matches(["하나 새창"]) {
            out.append(SlashChoice(id: "hana-window", name: "하나 새창", hint: "별도 창"))
        }
        if matches(["새대화", "새하나"]) {
            out.append(SlashChoice(id: "hana-fresh", name: "새대화", hint: "새 대화"))
        }
        if matches(["브리핑"]) {
            out.append(SlashChoice(id: "hana-briefing", name: "브리핑", hint: "브리핑"))
        }
        if matches(["ai", "인공지능"]) {
            out.append(SlashChoice(id: "ai-panel", name: "AI", hint: "AI 대화창 열기"))
        }
        if store.directionsEnabled, matches([AddressText.reservedDirections]) {
            out.append(SlashChoice(id: "directions", name: AddressText.reservedDirections, hint: "출발지, 도착지"))
        }
        return out
    }

    /// Longest enabled name/alias that starts the text and is followed by whitespace (`네이버웹툰` never matches `네이버`).
    private static func servicePrefix(_ text: String, words: [(word: String, range: Range<String.Index>)],
                                      services: [AddressService]) -> (service: AddressService, rest: String)? {
        let folded = words.map { AddressText.fold($0.word) }
        var best: (service: AddressService, count: Int)?
        for s in services where s.enabled {
            for name in s.allNames {
                let parts = AddressText.fold(name).split(separator: " ").map(String.init)
                guard !parts.isEmpty, folded.count > parts.count, Array(folded.prefix(parts.count)) == parts else { continue }
                if parts.count > (best?.count ?? 0) { best = (s, parts.count) }
            }
        }
        guard let best else { return nil }
        return (best.service, rest(of: text, after: words[best.count - 1].range))
    }

    private static func rest(of text: String, after range: Range<String.Index>) -> String {
        String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
    }

    private static func points(_ s: String) -> [String] {
        s.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func routeCommand(origin: String, destination: String) -> AddressCommand {
        guard origin.count <= AddressText.maxPlaceLength, destination.count <= AddressText.maxPlaceLength else {
            return .invalid("장소 이름이 너무 깁니다.")
        }
        return .route(RouteRequest(origin: .place(origin), destination: destination))
    }

    /// `길찾기 도착지` / `길찾기 도착지,` (current location → destination) and `길찾기 출발지, 도착지`.
    private static func explicitDirections(_ rest: String, store: AddressSearchStore) -> AddressCommand {
        guard !rest.isEmpty else { return .invalid("도착지를 입력하세요. 예) 길찾기 부산서면") }
        let parts = points(rest)
        guard parts.allSatisfy({ $0.count <= AddressText.maxPlaceLength }) else { return .invalid("장소 이름이 너무 깁니다.") }
        switch parts.count {
        case 1:
            return .route(RouteRequest(origin: store.departFromCurrentLocation ? .currentLocation : .ask, destination: parts[0]))
        case 2:
            if parts[0].isEmpty { return .invalid("출발지를 입력하세요. 예) 길찾기 장항동, 부산서면") }
            if parts[1].isEmpty { return .route(RouteRequest(origin: .currentLocation, destination: parts[0])) }
            return .route(RouteRequest(origin: .place(parts[0]), destination: parts[1]))
        default:
            return .invalid("출발지와 도착지 두 곳만 입력할 수 있습니다.")
        }
    }
}

// MARK: - Naver map route address

/// The public Naver web map route (car) address: `/p/directions/{x},{y},{name},,/{x},{y},{name},,/-/car`
/// with Web Mercator meters. The names are percent-encoded values, so a comma or slash in a name cannot split a field.
/// Whether the route page accepts exactly this form is to be confirmed on the live site (see the result notes).
enum NaverMapRoute {
    static func webMercator(latitude: Double, longitude: Double) -> (x: Double, y: Double) {
        let radius = 6378137.0
        let lat = max(min(latitude, 85.05112878), -85.05112878)
        return (radius * longitude * .pi / 180, radius * log(tan(.pi / 4 + lat * .pi / 360)))
    }

    static func url(origin: RoutePoint, destination: RoutePoint) -> URL? {
        func segment(_ p: RoutePoint) -> String? {
            let m = webMercator(latitude: p.latitude, longitude: p.longitude)
            guard m.x.isFinite, m.y.isFinite else { return nil }
            return String(format: "%.7f,%.7f,", m.x, m.y) + AddressTemplate.encode(p.name) + ",,"
        }
        guard let from = segment(origin), let to = segment(destination) else { return nil }
        var c = URLComponents()
        c.scheme = "https"
        c.host = "map.naver.com"
        c.percentEncodedPath = "/p/directions/" + from + "/" + to + "/-/car"
        return c.url
    }
}

struct RoutePoint: Equatable {
    var name: String
    var latitude: Double
    var longitude: Double
}

// MARK: - One-shot current location

/// One user-initiated location read. The system permission prompt appears only if the permission is still undecided;
/// a refusal, timeout or cancel just ends the read. The position is kept in memory for this call only.
@MainActor
final class OneShotLocation: NSObject, CLLocationManagerDelegate {
    enum Failure: Error {
        case denied, unavailable, timedOut, cancelled

        var message: String {
            switch self {
            case .denied: return "현재 위치 권한이 없습니다. 출발지를 직접 입력해 주세요."
            case .timedOut: return "현재 위치를 확인하지 못했습니다. 출발지를 직접 입력해 주세요."
            case .unavailable, .cancelled: return "현재 위치를 알 수 없습니다. 출발지를 직접 입력해 주세요."
            }
        }
    }

    private var manager: CLLocationManager?
    private var continuation: CheckedContinuation<Result<CLLocationCoordinate2D, Failure>, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var askedPermission = false
    private var requested = false
    /// Bumped by every `fetch`. The manager (compared by ===) and this token tie each delegate and timeout callback to the
    /// one fetch that created it, so a queued callback of a cancelled fetch can never complete a newer one.
    private var token = 0

    func fetch(timeout: TimeInterval = 10) async -> Result<CLLocationCoordinate2D, Failure> {
        cancel()
        askedPermission = false
        requested = false
        token &+= 1
        let mine = token
        return await withCheckedContinuation { (cont: CheckedContinuation<Result<CLLocationCoordinate2D, Failure>, Never>) in
            continuation = cont
            let m = CLLocationManager()
            m.delegate = self
            m.desiredAccuracy = kCLLocationAccuracyHundredMeters
            manager = m
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.finish(.failure(.timedOut), token: mine)
            }
            evaluate(m.authorizationStatus, from: m)
        }
    }

    func cancel() {
        finish(.failure(.cancelled))
    }

    private func evaluate(_ status: CLAuthorizationStatus, from source: CLLocationManager) {
        guard continuation != nil, let m = manager, source === m else { return }
        switch status {
        case .notDetermined:
            if !askedPermission {
                askedPermission = true
                m.requestWhenInUseAuthorization()
            }
        case .authorizedAlways, .authorizedWhenInUse:
            if !requested {
                requested = true
                m.requestLocation()
            }
        default:
            finish(.failure(.denied), from: source)
        }
    }

    /// Completes the current fetch only when the callback comes from the manager that fetch created.
    private func finish(_ result: Result<CLLocationCoordinate2D, Failure>, from source: CLLocationManager) {
        guard continuation != nil, let m = manager, source === m else { return }
        finish(result)
    }

    /// Completes the current fetch only when the callback belongs to fetch number `token`.
    private func finish(_ result: Result<CLLocationCoordinate2D, Failure>, token: Int) {
        guard continuation != nil, token == self.token else { return }
        finish(result)
    }

    private func finish(_ result: Result<CLLocationCoordinate2D, Failure>) {
        timeoutTask?.cancel()
        timeoutTask = nil
        manager?.delegate = nil
        manager?.stopUpdatingLocation()
        manager = nil
        let c = continuation
        continuation = nil
        c?.resume(returning: result)
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        // The queued task holds the original manager strongly, so it cannot be freed (and its address reused by a
        // newer manager) before the identity check inside the task.
        Task { @MainActor in self.evaluate(status, from: manager) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last, loc.horizontalAccuracy >= 0 else { return }
        let lat = loc.coordinate.latitude
        let lon = loc.coordinate.longitude
        Task { @MainActor in self.finish(.success(CLLocationCoordinate2D(latitude: lat, longitude: lon)), from: manager) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let denied = (error as? CLError)?.code == .denied
        Task { @MainActor in self.finish(.failure(denied ? .denied : .unavailable), from: manager) }
    }
}

// MARK: - Route flow (place lookup, choice, open)

/// One 길찾기 attempt of one browser tab. Names are looked up only after the user pressed Enter (never per keystroke);
/// a lookup, a location read or a pending choice belongs to `generation` and to the tab that started it, and its
/// result is dropped (no navigation, no new tab) once the user cancelled, started another command or left that tab.
@MainActor
final class AddressRouteFlow: ObservableObject {
    struct Candidate: Identifiable, Equatable {
        let id = UUID()
        let name: String
        let detail: String
        let latitude: Double
        let longitude: Double
    }

    struct Choice: Equatable {
        let query: String
        let isOrigin: Bool
        let candidates: [Candidate]
    }

    enum Phase: Equatable {
        case idle
        case working(String)
        case choosing(Choice)
        case needOrigin(String)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle

    private var generation = 0
    private var task: Task<Void, Never>?
    private var activeSearch: MKLocalSearch?
    private let locator = OneShotLocation()
    private var choiceContinuation: CheckedContinuation<Candidate?, Never>?
    private weak var owner: LoginBrowserModel?
    private weak var appModel: AppModel?
    private var destinationText = ""
    /// What the tab showed when the user pressed Enter. If the tab shows something else when the route is ready
    /// (an external link reused it, the user opened a page meanwhile), the route is dropped instead of replacing it.
    private var startURL: URL?
    private var startedAtHome = true
    private var startAttempt = 0

    var isPresented: Bool { phase != .idle }

    func start(_ request: RouteRequest, owner: LoginBrowserModel, appModel: AppModel, keepingStartPage: Bool = false) {
        cancelWork()
        generation += 1
        let gen = generation
        self.owner = owner
        self.appModel = appModel
        if !keepingStartPage {
            startURL = owner.currentURL
            startedAtHome = owner.isShowingHome
            startAttempt = owner.logicalAttemptId
        }
        destinationText = request.destination
        if case .ask = request.origin {
            phase = .needOrigin("출발지를 입력하세요.")
            return
        }
        phase = .working("장소를 찾는 중…")
        task = Task { [weak self] in await self?.run(request, generation: gen) }
    }

    /// Manual origin after "ask" / a refused or failed location read.
    func submitOrigin(_ text: String) {
        let origin = AddressText.normalizedInput(text)
        guard let owner, let appModel else { cancel(); return }
        guard !origin.isEmpty, origin.count <= AddressText.maxPlaceLength, !origin.contains(","),
              !AddressText.looksLikeAccount(origin) else {
            phase = .needOrigin("출발지를 한 곳만 알맞게 입력해 주세요.")
            return
        }
        start(RouteRequest(origin: .place(origin), destination: destinationText), owner: owner, appModel: appModel,
              keepingStartPage: true)
    }

    func choose(_ candidate: Candidate) {
        guard let k = choiceContinuation else { return }
        choiceContinuation = nil
        phase = .working("경로를 만드는 중…")
        k.resume(returning: candidate)
    }

    func cancel() {
        cancelWork()
        generation += 1
        phase = .idle
    }

    private func cancelWork() {
        task?.cancel()
        task = nil
        activeSearch?.cancel()
        activeSearch = nil
        locator.cancel()
        let k = choiceContinuation
        choiceContinuation = nil
        k?.resume(returning: nil)
    }

    private func isCurrent(_ gen: Int) -> Bool {
        gen == generation && !Task.isCancelled
    }

    private func run(_ request: RouteRequest, generation gen: Int) async {
        let origin: RoutePoint
        switch request.origin {
        case .currentLocation:
            phase = .working("현재 위치를 확인하는 중…")
            let result = await locator.fetch()
            guard isCurrent(gen) else { return }
            switch result {
            case .success(let c):
                guard Self.inKorea(c.latitude, c.longitude) else {
                    phase = .needOrigin("현재 위치가 한국 밖입니다. 출발지를 직접 입력해 주세요.")
                    return
                }
                origin = RoutePoint(name: "현재 위치", latitude: c.latitude, longitude: c.longitude)
            case .failure(let why):
                phase = .needOrigin(why.message)
                return
            }
        case .place(let name):
            guard let p = await resolve(name, isOrigin: true, generation: gen) else { return }
            origin = p
        case .ask:
            return
        }
        guard isCurrent(gen) else { return }
        guard let destination = await resolve(request.destination, isOrigin: false, generation: gen) else { return }
        guard isCurrent(gen) else { return }
        guard let owner, let appModel, appModel.tabs.contains(where: { $0 === owner }),
              appModel.selectedTabID == owner.tabID, appModel.selectedTab == .browser,
              owner.currentURL == startURL, owner.isShowingHome == startedAtHome,
              owner.logicalAttemptId == startAttempt else {
            phase = .idle   // the tab is no longer in front or now shows something else: nothing is opened
            return
        }
        guard let url = NaverMapRoute.url(origin: origin, destination: destination) else {
            phase = .failed("길찾기 주소를 만들지 못했습니다.")
            return
        }
        phase = .idle
        owner.open(url.absoluteString)
    }

    /// One place: a single result is used; several results are always shown for the user to choose from.
    private func resolve(_ query: String, isOrigin: Bool, generation gen: Int) async -> RoutePoint? {
        guard isCurrent(gen) else { return nil }
        phase = .working(isOrigin ? "출발지를 찾는 중…" : "도착지를 찾는 중…")
        let found: [Candidate]
        do {
            found = try await searchPlaces(query)
        } catch {
            if isCurrent(gen) { phase = .failed("장소를 검색하지 못했습니다. 잠시 뒤 다시 시도해 주세요.") }
            return nil
        }
        guard isCurrent(gen) else { return nil }
        guard let first = found.first else {
            phase = .failed("'\(query)' 장소를 찾지 못했습니다. 더 자세한 이름으로 입력해 보세요.")
            return nil
        }
        var chosen = first
        if found.count > 1 {
            let picked: Candidate? = await withCheckedContinuation { (cont: CheckedContinuation<Candidate?, Never>) in
                choiceContinuation = cont
                phase = .choosing(Choice(query: query, isOrigin: isOrigin, candidates: found))
            }
            guard isCurrent(gen), let picked else { return nil }
            chosen = picked
        }
        return RoutePoint(name: chosen.name, latitude: chosen.latitude, longitude: chosen.longitude)
    }

    /// Apple place search (MapKit), biased to and limited to Korea because the route page is Naver's.
    private func searchPlaces(_ query: String) async throws -> [Candidate] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 36.0, longitude: 127.8),
                                            span: MKCoordinateSpan(latitudeDelta: 6.5, longitudeDelta: 5.5))
        let search = MKLocalSearch(request: request)
        activeSearch = search
        defer { activeSearch = nil }
        let response: MKLocalSearch.Response
        do {
            response = try await search.start()
        } catch let e as MKError where e.code == .placemarkNotFound {
            return []
        }
        var out: [Candidate] = []
        for item in response.mapItems {
            let c = item.placemark.coordinate
            guard CLLocationCoordinate2DIsValid(c), Self.inKorea(c.latitude, c.longitude) else { continue }
            let rawName = (item.name ?? query).trimmingCharacters(in: .whitespacesAndNewlines)
            let name = String((rawName.isEmpty ? query : rawName).prefix(60))
            if out.contains(where: { $0.name == name && abs($0.latitude - c.latitude) < 0.0005 && abs($0.longitude - c.longitude) < 0.0005 }) {
                continue
            }
            out.append(Candidate(name: name, detail: item.placemark.title ?? "", latitude: c.latitude, longitude: c.longitude))
            if out.count == 5 { break }
        }
        return out
    }

    private static func inKorea(_ lat: Double, _ lon: Double) -> Bool {
        (33.0...38.7).contains(lat) && (124.5...132.0).contains(lon)
    }
}

struct AddressRouteSheet: View {
    @ObservedObject var flow: AddressRouteFlow
    @State private var originText = ""
    @Environment(\.bkPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("길찾기").font(.headline)
            switch flow.phase {
            case .idle:
                EmptyView()
            case .working(let text):
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(text)
                }
            case .choosing(let choice):
                Text("\(choice.isOrigin ? "출발지" : "도착지") '\(choice.query)': 장소를 선택하세요")
                    .font(.subheadline)
                ForEach(choice.candidates) { c in
                    Button { flow.choose(c) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.name).lineLimit(1)
                            if !c.detail.isEmpty {
                                Text(c.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.bordered)
                }
            case .needOrigin(let message):
                Text(message).font(.subheadline)
                HStack(spacing: 8) {
                    TextField("출발지", text: $originText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { flow.submitOrigin(originText) }
                    Button("길찾기") { flow.submitOrigin(originText) }
                        .buttonStyle(.bkProminent)
                        .disabled(originText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            case .failed(let message):
                Text(message).font(.subheadline).foregroundColor(palette.dangerColor)
            }
            HStack {
                Spacer()
                Button(flow.phase.isFailed ? "닫기" : "취소") { flow.cancel() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(width: 380)
    }
}

private extension AddressRouteFlow.Phase {
    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

// MARK: - Settings ("주소창·검색" part of the sidebar)

struct AddressEditorTarget: Identifiable {
    let id = UUID()
    /// nil = a new custom site.
    let serviceID: String?
}

struct AddressSearchSettingsView: View {
    @ObservedObject var store: AddressSearchStore
    @Environment(\.bkPalette) private var palette
    @State private var editing: AddressEditorTarget?
    @State private var message: String?
    @State private var confirmRestoreAll = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let warning = store.loadWarning {
                    Text(warning).font(.caption).foregroundStyle(.orange)
                }
                GroupBox("길찾기") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("길찾기 사용", isOn: Binding(
                            get: { store.directionsEnabled },
                            set: { message = store.setDirectionsEnabled($0) }))
                        Toggle("출발지가 없으면 현재 위치에서 출발", isOn: Binding(
                            get: { store.departFromCurrentLocation },
                            set: { message = store.setDepartFromCurrentLocation($0) }))
                            .disabled(!store.directionsEnabled)
                        LabeledContent("이동 수단", value: "자동차")
                    }
                    .padding(8)
                }

                GroupBox("바로가기 사이트") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("스위치는 이름 입력 바로가기만 켜고 끕니다. 그 외 입력의 Google·네이버·YouTube 3행 선택은 항상 나옵니다.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        ForEach(store.services) { service in
                            row(service)
                            Divider()
                        }
                        HStack {
                            Button("사이트 추가") { editing = AddressEditorTarget(serviceID: nil) }
                                .buttonStyle(.bordered)
                            Spacer()
                            Button("기본 사이트 모두 기본값으로") { confirmRestoreAll = true }
                                .buttonStyle(.bordered)
                        }
                        if let message {
                            Text(message).font(.caption).foregroundColor(palette.dangerColor)
                        }
                    }
                    .padding(8)
                }

                GroupBox("입력 예시") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("AI · 인공지능 · 하나 · 새대화 · 하나 새창 · 브리핑")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        example("AI", "기본 AI 대화창 열기")
                        example("구글", "Google 홈 열기")
                        example("네이버 날씨", "네이버에서 날씨 검색")
                        example("지도 장항동", "네이버 지도에서 장소 검색")
                        example("길찾기 부산서면", "현재 위치에서 부산서면까지")
                        example("길찾기 장항동, 부산서면", "출발지, 도착지")
                        example("그 밖의 검색어", "Google · 네이버 · YouTube 중에서 고르기")
                    }
                    .padding(8)
                }
            }
            .padding(20)
        }
        .sheet(item: $editing) { target in
            AddressServiceEditorSheet(store: store, serviceID: target.serviceID) { editing = nil }
                .byungkiThemed(palette)
        }
        .confirmationDialog("기본 사이트 \(AddressServiceDefaults.all.count)개를 기본값으로 되돌릴까요?", isPresented: $confirmRestoreAll) {
            Button("기본값으로 되돌리기") { message = store.restoreAllDefaults() }
            Button("취소", role: .cancel) {}
        }
    }

    private func row(_ service: AddressService) -> some View {
        HStack(spacing: 8) {
            Toggle("\(service.name) 바로가기 사용", isOn: Binding(
                get: { service.enabled },
                set: { message = store.setEnabled(id: service.id, $0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(service.name).font(.subheadline.bold())
                Text("\(URL(string: service.homeURL)?.host ?? service.homeURL) · \(service.supportsSearch ? "검색 가능" : "홈만")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if store.isModified(service) {
                Button("기본값") { message = store.restoreDefault(id: service.id) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            Button("수정") { editing = AddressEditorTarget(serviceID: service.id) }
                .buttonStyle(.bordered)
                .controlSize(.small)
            if !service.isBuiltin {
                Button("삭제") { message = store.delete(id: service.id) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    private func example(_ input: String, _ result: String) -> some View {
        HStack(spacing: 6) {
            Text(input).font(.system(.caption, design: .monospaced))
            Text("→ \(result)").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct AddressServiceEditorSheet: View {
    @ObservedObject var store: AddressSearchStore
    let serviceID: String?
    let onClose: () -> Void
    @State private var draft = AddressServiceDraft()
    @State private var loaded = false
    @State private var saveError: String?

    private var problem: String? {
        if case .failure(let e) = AddressSearchStore.validate(draft, editing: serviceID, among: store.services) { return e.message }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(serviceID == nil ? "사이트 추가" : "사이트 수정").font(.headline)
            TextField("이름", text: $draft.name)
                .textFieldStyle(.roundedBorder)
            TextField("별칭 (쉼표로 구분)", text: $draft.aliasesText)
                .textFieldStyle(.roundedBorder)
            TextField("홈 주소 (https://…)", text: $draft.homeURL)
                .textFieldStyle(.roundedBorder)
            TextField("검색 주소 (선택, 검색어 자리에 {query})", text: $draft.searchTemplate)
                .textFieldStyle(.roundedBorder)
            Toggle("바로가기 사용", isOn: $draft.enabled)
            if let text = saveError ?? (draft == AddressServiceDraft() ? nil : problem) {
                Text(text).font(.caption).foregroundColor(.red)
            }
            HStack {
                if let id = serviceID, let current = store.service(id: id), store.isModified(current) {
                    Button("기본값으로") {
                        if let f = AddressServiceDefaults.factory(id) { draft = AddressServiceDraft(f) }
                    }
                }
                Spacer()
                Button("취소") { onClose() }
                    .keyboardShortcut(.cancelAction)
                Button("저장") { save() }
                    .buttonStyle(.bkProminent)
                    .disabled(problem != nil)
            }
        }
        .padding(16)
        .frame(width: 420)
        .onAppear {
            guard !loaded else { return }
            if let id = serviceID, let s = store.service(id: id) { draft = AddressServiceDraft(s) }
            loaded = true
        }
        .onChange(of: draft) { _, _ in saveError = nil }
    }

    private func save() {
        let error = serviceID.map { store.update(id: $0, draft) } ?? store.add(draft)
        if let error { saveError = error } else { onClose() }
    }
}
