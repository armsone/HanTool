import SwiftUI
import Foundation

// MARK: - Supported Sites Catalog Models (Schema v1)

public struct SupportCatalog: Codable, Equatable {
    public let schemaVersion: Int
    public let backendVersion: String
    public let summary: [String: Int]
    public let sites: [SiteEntry]
    public let appendix: [SiteEntry]
    public let registeredExtractors: [ExtractorEntry]
}

/// Optional per-row mode trial result for future sidecar updates (`<storeDirectory>/support-catalog.json`).
/// - `status == "passed"` with known analysis modes (`metadata`, `extract`, `extract_info`) resolves to "분석 성공" (not MP4 save proof).
/// - `status == "passed"` with known save modes (`download`, `full_save`, `record`, `vod_mp4`) resolves to "해당 모드 저장 성공".
/// - `status == "failed"` / `"unavailable"` with a known mode resolves to "시험 실패" / "현재 이용 불가".
/// - Any other valid public mode or unrecognized status with a valid ISO8601 `checkedAt` resolves to "시험 결과 미확인".
/// - Missing `testResult`, `status == "pending"`, or missing/invalid `mode` or `checkedAt` resolves to "시험 대기".
public struct SiteTestResult: Codable, Equatable {
    public let status: String
    public let mode: String?
    public let checkedAt: String?

    public init(status: String, mode: String? = nil, checkedAt: String? = nil) {
        self.status = status
        self.mode = mode
        self.checkedAt = checkedAt
    }
}

public struct SiteEntry: Codable, Identifiable, Equatable {
    public let id: String
    public let rowNumber: Int?
    public let name: String
    public let domain: String
    public let normalizedHost: String
    public let extractorKeys: [String]
    public let matchKind: String
    public let registryState: String
    public let hasDomainSaveExample: Bool
    public let testStatus: String
    public let testResult: SiteTestResult?

    public enum CandidateGroup: String {
        case dedicatedCandidate
        case weakNameCandidate
        case unconfirmedCandidate
        case outsideAppendix

        public var badgeTitle: String {
            switch self {
            case .dedicatedCandidate: return "전용 연동 후보"
            case .weakNameCandidate: return "이름 후보(도메인 미확인)"
            case .unconfirmedCandidate: return "전용 연동 후보 미확인"
            case .outsideAppendix: return "목록 밖 저장 사례"
            }
        }
    }

    public var candidateGroup: CandidateGroup {
        switch matchKind {
        case "domain_exact", "domain_registered", "domain_alternation":
            return .dedicatedCandidate
        case "name_only_weak":
            return .weakNameCandidate
        case "appendix":
            return .outsideAppendix
        default:
            return .unconfirmedCandidate
        }
    }

    public var isWorkingFalseOnly: Bool {
        registryState == "working_false_only"
    }

    public enum ResolvedModeTrial: Equatable {
        case pending
        case analysisPassed(mode: String, checkedAt: String)
        case savePassed(mode: String, checkedAt: String)
        case failed(mode: String, checkedAt: String)
        case unavailable(mode: String, checkedAt: String)
        case unknown(checkedAt: String)

        public var badgeTitle: String {
            switch self {
            case .pending:
                return "시험 대기"
            case .analysisPassed(let mode, _):
                return "분석 성공 (\(mode))"
            case .savePassed(let mode, _):
                return "해당 모드 저장 성공 (\(mode))"
            case .failed(let mode, _):
                return "시험 실패 (\(mode))"
            case .unavailable(let mode, _):
                return "현재 이용 불가 (\(mode))"
            case .unknown:
                return "시험 결과 미확인"
            }
        }
    }

    /// Evaluates mode trial status strictly from validated `testResult`.
    /// Never promotes `hasDomainSaveExample`, `registryState == "working"`, or bare `testStatus == "passed"` to verified.
    /// Known analysis modes (`metadata`, `extract`, `extract_info`) resolve only to `.analysisPassed` ("분석 성공"), never MP4 save proof.
    /// Known save modes (`download`, `full_save`, `record`, `vod_mp4`) resolve to `.savePassed` ("해당 모드 저장 성공").
    /// Other/unknown modes or unknown statuses with a valid ISO8601 `checkedAt` resolve to `.unknown` ("시험 결과 미확인") without echoing raw tokens.
    public var resolvedModeTrial: ResolvedModeTrial {
        guard let tr = testResult else { return .pending }
        let rawStatus = tr.status.trimmingCharacters(in: .whitespacesAndNewlines)
        if rawStatus.isEmpty || rawStatus == "pending" {
            return .pending
        }
        let rawMode = tr.mode?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let rawCheckedAt = tr.checkedAt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard SupportCatalogValidator.isValidPublicMode(rawMode),
              SupportCatalogValidator.isValidISO8601(rawCheckedAt) else {
            return .pending
        }
        switch rawStatus {
        case "passed":
            if SupportCatalogValidator.knownAnalysisModes.contains(rawMode) {
                return .analysisPassed(mode: rawMode, checkedAt: rawCheckedAt)
            } else if SupportCatalogValidator.knownSaveModes.contains(rawMode) {
                return .savePassed(mode: rawMode, checkedAt: rawCheckedAt)
            } else {
                return .unknown(checkedAt: rawCheckedAt)
            }
        case "failed":
            if SupportCatalogValidator.isKnownTrialMode(rawMode) {
                return .failed(mode: rawMode, checkedAt: rawCheckedAt)
            } else {
                return .unknown(checkedAt: rawCheckedAt)
            }
        case "unavailable":
            if SupportCatalogValidator.isKnownTrialMode(rawMode) {
                return .unavailable(mode: rawMode, checkedAt: rawCheckedAt)
            } else {
                return .unknown(checkedAt: rawCheckedAt)
            }
        default:
            return .unknown(checkedAt: rawCheckedAt)
        }
    }
}

public struct ExtractorEntry: Codable, Identifiable, Equatable {
    public var id: String { key }
    public let key: String
    public let name: String
    public let description: String?
    public let working: Bool

    private enum CodingKeys: String, CodingKey {
        case key, name, description, working
    }

    public init(key: String, name: String, description: String?, working: Bool) {
        self.key = key
        self.name = name
        self.description = description
        self.working = working
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        name = try c.decode(String.self, forKey: .name)
        working = try c.decode(Bool.self, forKey: .working)
        if try c.decodeNil(forKey: .description) {
            description = nil
        } else if let str = try? c.decode(String.self, forKey: .description) {
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            description = trimmed.isEmpty ? nil : trimmed
        } else if let flag = try? c.decode(Bool.self, forKey: .description), flag == false {
            // yt-dlp sets IE_DESC = False on internal/unlisted extractors.
            description = nil
        } else {
            throw DecodingError.typeMismatch(
                String.self,
                DecodingError.Context(codingPath: c.codingPath + [CodingKeys.description],
                                      debugDescription: "Extractor description must be String, null, or false."))
        }
    }
}

// MARK: - Bounded Loader & Validator

public enum SupportCatalogSource: Equatable {
    case bundled
    case sidecar

    public var displayTitle: String {
        switch self {
        case .bundled: return "내장 기본 목록 (Bundled)"
        case .sidecar: return "시험 결과 파일 (support-catalog.json)"
        }
    }
}

public enum SupportCatalogError: LocalizedError, Equatable {
    case invalidFileURL
    case symbolicLinkRejected
    case notRegularFile
    case fileTooLarge(Int)
    case emptyFile
    case readFailed(String)
    case decodeFailed(String)
    case unsupportedSchema(Int)
    case invalidMetadata(String)
    case invalidCounts(String)
    case duplicateIdentifier(String)
    case invalidRowData(String)

    public var errorDescription: String? {
        switch self {
        case .invalidFileURL:
            return "허용된 로컬 파일 경로가 아닙니다."
        case .symbolicLinkRejected:
            return "심볼릭 링크 파일은 보안상 불러오지 않습니다."
        case .notRegularFile:
            return "일반 파일이 아닙니다."
        case .fileTooLarge(let limit):
            return "파일 크기가 허용 상한(\(limit / (1024 * 1024))MB)을 초과합니다."
        case .emptyFile:
            return "파일이 비어 있습니다."
        case .readFailed(let detail):
            return "파일을 읽지 못했습니다 (\(detail))."
        case .decodeFailed(let detail):
            return "JSON 형식이 올바르지 않습니다 (\(detail))."
        case .unsupportedSchema(let ver):
            return "지원하지 않는 스키마 버전입니다 (schemaVersion=\(ver), 필요=1)."
        case .invalidMetadata(let detail):
            return "카탈로그 메타데이터가 올바르지 않습니다 (\(detail))."
        case .invalidCounts(let detail):
            return "카탈로그 행 수 또는 요약 집계가 기준과 일치하지 않습니다 (\(detail))."
        case .duplicateIdentifier(let detail):
            return "중복된 식별자가 포함되어 있습니다 (\(detail))."
        case .invalidRowData(let detail):
            return "허용되지 않는 호스트·상태·시험 필드가 포함되어 있습니다 (\(detail))."
        }
    }
}

public enum SupportCatalogValidator {
    public static let maxCatalogBytes = 2 * 1024 * 1024 // 2 MiB
    public static let expectedSiteCount = 658
    public static let originalRowNumberUpperBound = 690
    public static let expectedNormalizedHostCount = 563
    public static let expectedDomainCandidateCount = 288
    public static let expectedWeakCandidateCount = 57
    public static let expectedUnmatchedCount = 313
    public static let expectedInactiveCandidateCount = 18
    public static let expectedDomainSampleRowCount = 21
    public static let expectedAppendixCount = 4
    public static let expectedExtractorCount = 1754

    public static let maxModeLength = 64
    public static let maxStatusLength = 32
    public static let maxDateLength = 64

    public static let knownAnalysisModes: Set<String> = [
        "metadata", "extract", "extract_info"
    ]
    public static let knownSaveModes: Set<String> = [
        "download", "full_save", "record", "vod_mp4"
    ]
    public static let knownTrialStatuses: Set<String> = [
        "pending", "passed", "failed", "unavailable"
    ]

    public static func isKnownTrialMode(_ mode: String) -> Bool {
        knownAnalysisModes.contains(mode) || knownSaveModes.contains(mode)
    }

    private static let allowedSiteMatchKinds: Set<String> = [
        "domain_exact", "domain_registered", "domain_alternation", "name_only_weak", "none"
    ]
    private static let allowedRegistryStates: Set<String> = [
        "working", "working_false_only", "none"
    ]
    private static let forbiddenHostSuffixes: [String] = [
        ".localhost", ".local", ".internal", ".intranet", ".lan", ".home", ".corp", ".arpa"
    ]

    /// Reads at most `maxCatalogBytes` from an exact scoped local file URL using `FileHandle.read(upToCount:)`.
    public static func readBoundedData(from url: URL) throws -> Data {
        guard url.isFileURL else { throw SupportCatalogError.invalidFileURL }
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        } catch {
            throw SupportCatalogError.readFailed("파일 속성을 확인할 수 없음")
        }
        if values.isSymbolicLink == true {
            throw SupportCatalogError.symbolicLinkRejected
        }
        guard values.isRegularFile == true else {
            throw SupportCatalogError.notRegularFile
        }
        if let size = values.fileSize, size > maxCatalogBytes {
            throw SupportCatalogError.fileTooLarge(maxCatalogBytes)
        }
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw SupportCatalogError.readFailed("파일 열기 실패")
        }
        defer { try? handle.close() }
        let data: Data?
        do {
            data = try handle.read(upToCount: maxCatalogBytes + 1)
        } catch {
            throw SupportCatalogError.readFailed("제한 읽기 실패")
        }
        guard let bytes = data, !bytes.isEmpty else {
            throw SupportCatalogError.emptyFile
        }
        if bytes.count > maxCatalogBytes {
            throw SupportCatalogError.fileTooLarge(maxCatalogBytes)
        }
        return bytes
    }

    public static func decodeAndValidate(from url: URL) throws -> SupportCatalog {
        let data = try readBoundedData(from: url)
        let catalog: SupportCatalog
        do {
            catalog = try JSONDecoder().decode(SupportCatalog.self, from: data)
        } catch {
            throw SupportCatalogError.decodeFailed("스키마 필드 불일치")
        }
        try validate(catalog)
        return catalog
    }

    public static func validate(_ catalog: SupportCatalog) throws {
        guard catalog.schemaVersion == 1 else {
            throw SupportCatalogError.unsupportedSchema(catalog.schemaVersion)
        }
        let backend = catalog.backendVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !backend.isEmpty, backend.count <= 64, !containsForbiddenPathOrURL(backend) else {
            throw SupportCatalogError.invalidMetadata("backendVersion")
        }

        guard catalog.sites.count == expectedSiteCount else {
            throw SupportCatalogError.invalidCounts("sites=\(catalog.sites.count), 필요=\(expectedSiteCount)")
        }
        guard catalog.appendix.count == expectedAppendixCount else {
            throw SupportCatalogError.invalidCounts("appendix=\(catalog.appendix.count), 필요=\(expectedAppendixCount)")
        }
        guard catalog.registeredExtractors.count == expectedExtractorCount else {
            throw SupportCatalogError.invalidCounts("registeredExtractors=\(catalog.registeredExtractors.count), 필요=\(expectedExtractorCount)")
        }

        let s = catalog.summary
        guard s["original_row_count"] == expectedSiteCount,
              s["unique_normalized_hosts"] == expectedNormalizedHostCount,
              s["domain_candidate_rows"] == expectedDomainCandidateCount,
              s["weak_name_only_rows"] == expectedWeakCandidateCount,
              s["no_candidate_rows"] == expectedUnmatchedCount,
              s["inactive_only_candidate_rows"] == expectedInactiveCandidateCount,
              s["previous_domain_sample_rows"] == expectedDomainSampleRowCount else {
            throw SupportCatalogError.invalidCounts("summary 집계 불일치")
        }

        var seenSiteIds = Set<String>()
        var seenRowNumbers = Set<Int>()
        var normalizedHosts = Set<String>()
        var domainCandidateRows = 0
        var weakRows = 0
        var unmatchedRows = 0
        var inactiveCandidateRows = 0
        var domainSampleRows = 0

        for site in catalog.sites {
            guard !site.id.isEmpty, site.id.count <= 80, seenSiteIds.insert(site.id).inserted else {
                throw SupportCatalogError.duplicateIdentifier("site.id=\(site.id)")
            }
            guard let rowNum = site.rowNumber, (1...originalRowNumberUpperBound).contains(rowNum),
                  seenRowNumbers.insert(rowNum).inserted else {
                throw SupportCatalogError.invalidRowData("site.rowNumber (\(site.id))")
            }
            guard allowedSiteMatchKinds.contains(site.matchKind) else {
                throw SupportCatalogError.invalidRowData("site.matchKind=\(site.matchKind)")
            }
            try validateSiteCommon(site, allowAnyNormalizedHost: site.domain == "any",
                                   allowDomainlessSentinel: true)
            normalizedHosts.insert(site.normalizedHost)

            switch site.matchKind {
            case "domain_exact", "domain_registered", "domain_alternation":
                domainCandidateRows += 1
            case "name_only_weak":
                weakRows += 1
            case "none":
                unmatchedRows += 1
            default:
                break
            }
            if site.registryState == "working_false_only" {
                inactiveCandidateRows += 1
            }
            if site.hasDomainSaveExample {
                domainSampleRows += 1
            }
        }

        guard normalizedHosts.count == expectedNormalizedHostCount,
              domainCandidateRows == expectedDomainCandidateCount,
              weakRows == expectedWeakCandidateCount,
              unmatchedRows == expectedUnmatchedCount,
              inactiveCandidateRows == expectedInactiveCandidateCount,
              domainSampleRows == expectedDomainSampleRowCount else {
            throw SupportCatalogError.invalidCounts("sites 실제 행 집계와 summary 불일치")
        }

        var appendixHosts = Set<String>()
        for item in catalog.appendix {
            guard !item.id.isEmpty, item.id.count <= 80, seenSiteIds.insert(item.id).inserted else {
                throw SupportCatalogError.duplicateIdentifier("appendix.id=\(item.id)")
            }
            guard item.rowNumber == nil, item.matchKind == "appendix" else {
                throw SupportCatalogError.invalidRowData("appendix 형식 오류 (\(item.id))")
            }
            try validateSiteCommon(item, allowAnyNormalizedHost: false)
            guard appendixHosts.insert(item.normalizedHost).inserted else {
                throw SupportCatalogError.duplicateIdentifier("appendix.normalizedHost=\(item.normalizedHost)")
            }
        }

        var seenExtractorKeys = Set<String>()
        for ext in catalog.registeredExtractors {
            let k = ext.key.trimmingCharacters(in: .whitespacesAndNewlines)
            let n = ext.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !k.isEmpty, k.count <= 160, !n.isEmpty, n.count <= 200 else {
                throw SupportCatalogError.invalidRowData("extractor key/name")
            }
            guard seenExtractorKeys.insert(ext.key).inserted else {
                throw SupportCatalogError.duplicateIdentifier("extractor.key=\(ext.key)")
            }
            if let desc = ext.description {
                guard desc.count <= 4096, !containsLocalPathLeak(desc) else {
                    throw SupportCatalogError.invalidRowData("extractor.description (\(ext.key))")
                }
            }
        }
    }

    /// Exact literal used by the bundled data for rows without any domain (e.g. Flashvars, SWF Object Extractor).
    /// Display-only: it is never a host, never resolved or opened.
    public static let domainlessSentinel = "(none)"

    public static func isDomainlessEntry(_ site: SiteEntry) -> Bool {
        site.domain == domainlessSentinel && site.normalizedHost == domainlessSentinel
    }

    private static func validateSiteCommon(_ site: SiteEntry, allowAnyNormalizedHost: Bool,
                                           allowDomainlessSentinel: Bool = false) throws {
        let trimmedName = site.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, trimmedName.count <= 200, !containsForbiddenPathOrURL(trimmedName) else {
            throw SupportCatalogError.invalidRowData("site.name (\(site.id))")
        }
        guard isValidDisplayDomain(site.domain) else {
            throw SupportCatalogError.invalidRowData("site.domain (\(site.id))")
        }
        guard (allowDomainlessSentinel && isDomainlessEntry(site))
                || isValidNormalizedHost(site.normalizedHost, allowAnyToken: allowAnyNormalizedHost) else {
            throw SupportCatalogError.invalidRowData("site.normalizedHost (\(site.id))")
        }
        guard allowedRegistryStates.contains(site.registryState) else {
            throw SupportCatalogError.invalidRowData("site.registryState (\(site.id))")
        }
        let rawTestStatus = site.testStatus.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawTestStatus.isEmpty, rawTestStatus.count <= maxStatusLength,
              !containsForbiddenPathOrURL(rawTestStatus) else {
            throw SupportCatalogError.invalidRowData("site.testStatus (\(site.id))")
        }
        guard site.extractorKeys.count <= 200,
              site.extractorKeys.allSatisfy({ !$0.isEmpty && $0.count <= 160 && !containsForbiddenPathOrURL($0) }) else {
            throw SupportCatalogError.invalidRowData("site.extractorKeys (\(site.id))")
        }
        if let tr = site.testResult {
            let trStatus = tr.status.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trStatus.count <= maxStatusLength, !containsForbiddenPathOrURL(trStatus) else {
                throw SupportCatalogError.invalidRowData("site.testResult.status (\(site.id))")
            }
            if let rawMode = tr.mode {
                let mode = rawMode.trimmingCharacters(in: .whitespacesAndNewlines)
                guard mode.count <= maxModeLength, !containsForbiddenPathOrURL(mode),
                      (mode.isEmpty || isValidPublicMode(mode)) else {
                    throw SupportCatalogError.invalidRowData("site.testResult.mode (\(site.id))")
                }
            }
            if let rawCheckedAt = tr.checkedAt {
                let checkedAt = rawCheckedAt.trimmingCharacters(in: .whitespacesAndNewlines)
                guard checkedAt.count <= maxDateLength, !containsForbiddenPathOrURL(checkedAt) else {
                    throw SupportCatalogError.invalidRowData("site.testResult.checkedAt (\(site.id))")
                }
            }
        }
    }

    public static func isValidDisplayDomain(_ raw: String) -> Bool {
        guard !raw.isEmpty, raw.count <= 253,
              raw == raw.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        if raw.contains("://") || raw.contains("?") || raw.contains("#") || raw.contains("@") || raw.contains(" ") {
            return false
        }
        return !containsLocalPathLeak(raw)
    }

    public static func isValidNormalizedHost(_ host: String, allowAnyToken: Bool) -> Bool {
        guard !host.isEmpty, host.count <= 253,
              host == host.trimmingCharacters(in: .whitespacesAndNewlines),
              host == host.lowercased() else { return false }
        if host.contains("://") || host.contains("/") || host.contains("?") || host.contains("#")
            || host.contains("@") || host.contains(":") || host.contains("\\") || host.contains(" ") {
            return false
        }
        if allowAnyToken && host == "any" {
            return true
        }
        guard host.contains("."), !host.hasPrefix("."), !host.hasSuffix("."), !host.contains("..") else {
            return false
        }
        if host == "localhost" || forbiddenHostSuffixes.contains(where: { host.hasSuffix($0) }) {
            return false
        }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty && $0.count <= 63 }) else {
            return false
        }
        // Reject IPv4 literals and private/loopback numeric hosts.
        if labels.allSatisfy({ $0.allSatisfy(\.isNumber) }) {
            return false
        }
        for label in labels {
            if label.hasPrefix("-") || label.hasSuffix("-") { return false }
            guard label.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else {
                return false
            }
        }
        guard let tld = labels.last, tld.rangeOfCharacter(from: .letters) != nil else {
            return false
        }
        return true
    }

    /// Public generic mode string (e.g. "extract_info", "vod_mp4", "browser_media") without URLs, paths, or IDs.
    public static func isValidPublicMode(_ mode: String) -> Bool {
        guard !mode.isEmpty, mode.count <= 64 else { return false }
        if mode.contains("://") || mode.contains("/") || mode.contains("?") || mode.contains("#")
            || mode.contains("@") || mode.contains("\\") {
            return false
        }
        if containsLocalPathLeak(mode) { return false }
        // Reject long opaque tokens that look like media IDs or hashes.
        let tokens = mode.split { $0 == " " || $0 == ":" || $0 == "," || $0 == ";" }
        if tokens.contains(where: { $0.count >= 24 && $0.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) }) {
            return false
        }
        return true
    }

    public static func isValidISO8601(_ text: String) -> Bool {
        guard text.count >= 10, text.count <= 40, text.contains("T") else { return false }
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime]
        if f1.date(from: text) != nil { return true }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f2.date(from: text) != nil
    }

    private static func containsForbiddenPathOrURL(_ text: String) -> Bool {
        if text.contains("://") { return true }
        return containsLocalPathLeak(text)
    }

    private static func containsLocalPathLeak(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("/users/") || lower.contains("/private/") || lower.contains("/var/folders/")
            || lower.contains("file://")
    }
}

@MainActor
public final class SupportCatalogStore: ObservableObject {
    public enum State: Equatable {
        case loading
        case loaded(SupportCatalog, SupportCatalogSource)
        case unavailable(String)
    }

    @Published public private(set) var state: State = .loading
    @Published public private(set) var sidecarWarning: String? = nil

    public init() {}

    /// Loads `<storeDirectory>/support-catalog.json` if present and valid; otherwise falls back to bundled `SupportedSites.json`.
    public func reload(sidecarURL: URL, bundledURL: URL? = Bundle.main.url(forResource: "SupportedSites", withExtension: "json")) {
        sidecarWarning = nil

        if FileManager.default.fileExists(atPath: sidecarURL.path) {
            do {
                let sidecarCatalog = try SupportCatalogValidator.decodeAndValidate(from: sidecarURL)
                state = .loaded(sidecarCatalog, .sidecar)
                return
            } catch {
                let reason = (error as? LocalizedError)?.errorDescription ?? "알 수 없는 검증 오류"
                sidecarWarning = "시험 결과 파일(support-catalog.json)을 검증하지 못해 내장 기본 목록으로 표시합니다: \(reason)"
            }
        }

        guard let bundledURL = bundledURL else {
            let baseMsg = "앱 번들 내장 카탈로그(SupportedSites.json)를 찾을 수 없습니다."
            if let warn = sidecarWarning {
                state = .unavailable("\(warn)\n\(baseMsg)")
            } else {
                state = .unavailable(baseMsg)
            }
            return
        }

        do {
            let bundledCatalog = try SupportCatalogValidator.decodeAndValidate(from: bundledURL)
            state = .loaded(bundledCatalog, .bundled)
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? "알 수 없는 읽기 오류"
            let baseMsg = "내장 기본 목록(SupportedSites.json)을 불러올 수 없습니다: \(reason)"
            if let warn = sidecarWarning {
                state = .unavailable("\(warn)\n\(baseMsg)")
            } else {
                state = .unavailable(baseMsg)
            }
        }
    }
}

// MARK: - Supported Sites View

public struct SupportedSitesView: View {
    @ObservedObject var appModel: AppModel

    @StateObject private var store = SupportCatalogStore()
    @Environment(\.bkPalette) private var palette

    public enum CatalogTab: String, CaseIterable, Identifiable {
        case sites = "사이트 목록"
        case extractors = "등록 연동"
        public var id: String { rawValue }
    }

    public enum SiteFilter: String, CaseIterable, Identifiable {
        case all = "전체 (658 + 목록 밖 4)"
        case dedicated = "전용 연동 후보 (288)"
        case weakName = "이름 후보·도메인 미확인 (57)"
        case unconfirmed = "전용 연동 후보 미확인 (313)"
        case workingFalse = "연동 점검 대상 (18)"
        case domainExample = "도메인 저장 사례 (21 + 목록 밖 4)"
        case appendixOnly = "목록 밖 저장 사례 (4)"
        case trialSavePassed = "해당 모드 저장 성공"
        case trialAnalysisPassed = "분석 성공"
        case trialFailed = "시험 실패"
        case trialUnavailable = "현재 이용 불가"
        case trialUnknown = "시험 결과 미확인"
        case trialPending = "시험 대기"
        public var id: String { rawValue }
    }

    private struct TrialSummaryCounts {
        var pending: Int = 0
        var savePassed: Int = 0
        var analysisPassed: Int = 0
        var failed: Int = 0
        var unavailable: Int = 0
        var unknown: Int = 0

        init(rows: [SiteEntry]) {
            for row in rows {
                switch row.resolvedModeTrial {
                case .pending:
                    pending += 1
                case .savePassed:
                    savePassed += 1
                case .analysisPassed:
                    analysisPassed += 1
                case .failed:
                    failed += 1
                case .unavailable:
                    unavailable += 1
                case .unknown:
                    unknown += 1
                }
            }
        }
    }

    private func siteFilterLabel(_ filter: SiteFilter, counts: TrialSummaryCounts) -> String {
        switch filter {
        case .all, .dedicated, .weakName, .unconfirmed, .workingFalse, .domainExample, .appendixOnly:
            return filter.rawValue
        case .trialSavePassed:
            return "해당 모드 저장 성공 (\(counts.savePassed))"
        case .trialAnalysisPassed:
            return "분석 성공 (\(counts.analysisPassed))"
        case .trialFailed:
            return "시험 실패 (\(counts.failed))"
        case .trialUnavailable:
            return "현재 이용 불가 (\(counts.unavailable))"
        case .trialUnknown:
            return "시험 결과 미확인 (\(counts.unknown))"
        case .trialPending:
            return "시험 대기 (\(counts.pending))"
        }
    }

    public enum ExtractorFilter: String, CaseIterable, Identifiable {
        case all = "전체 등록 연동 (1,754)"
        case workingTrue = "일반 등록 (working=true)"
        case workingFalse = "연동 점검 대상 (working=false)"
        public var id: String { rawValue }
    }

    @State private var selectedTab: CatalogTab = .sites
    @State private var searchText: String = ""
    @State private var siteFilter: SiteFilter = .all
    @State private var extractorFilter: ExtractorFilter = .all

    public init(appModel: AppModel) {
        self.appModel = appModel
    }

    public var body: some View {
        GeometryReader { proxy in
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            Rectangle().fill(palette.borderColor).frame(height: 1)

            if let warning = store.sidecarWarning {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(palette.warnColor)
                    Text(warning)
                        .font(.caption)
                        .foregroundColor(palette.warnInkColor)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(palette.warnSoftColor)
                Rectangle().fill(palette.borderColor).frame(height: 1)
            }

            switch store.state {
            case .loading:
                VStack(spacing: 12) {
                    ProgressView()
                    Text("지원 사이트 카탈로그를 확인하는 중입니다...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .unavailable(let reason):
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 36))
                        .foregroundColor(palette.warnColor)
                    Text("지원 사이트 목록을 표시할 수 없습니다.")
                        .font(.headline)
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                    Button("새로고침") {
                        store.reload(sidecarURL: appModel.supportCatalogSidecarURL)
                    }
                    .buttonStyle(.bkProminent)
                    .accessibilityLabel("지원 사이트 카탈로그 새로고침")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)

            case .loaded(let catalog, let source):
                catalogContentView(catalog: catalog, source: source)
            }
        }
        .frame(width: max(proxy.size.width, 0), height: max(proxy.size.height, 0), alignment: .topLeading)
        .background(palette.bgColor)
        .clipped()
        }
        .onAppear {
            store.reload(sidecarURL: appModel.supportCatalogSidecarURL)
        }
    }

    private var headerBar: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("지원 사이트 및 등록 연동 목록")
                    .font(.headline.bold())
                    .fixedSize(horizontal: false, vertical: true)
                if case .loaded(let catalog, let source) = store.state {
                    Text("원본: \(source.displayTitle) · yt-dlp \(catalog.backendVersion) · 비교 항목 \(catalog.sites.count)개 (정규화 도메인 \(catalog.summary["unique_normalized_hosts"] ?? SupportCatalogValidator.expectedNormalizedHostCount)개)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("비교 기준 사이트 658개 항목 · 정규화 도메인 563개 · 등록 연동(IE) 1,754개")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Button {
                store.reload(sidecarURL: appModel.supportCatalogSidecarURL)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                    Text("새로고침")
                }
            }
            .buttonStyle(.bordered)
            .fixedSize()
            .layoutPriority(1)
            .help("앱 데이터 폴더의 시험 결과 파일(support-catalog.json) 또는 내장 기본 목록을 최대 2MB 범위에서 다시 읽고 검증합니다.")
            .accessibilityLabel("지원 사이트 카탈로그 새로고침")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(palette.cardColor)
    }

    @ViewBuilder
    private func catalogContentView(catalog: SupportCatalog, source: SupportCatalogSource) -> some View {
        let trialCounts = TrialSummaryCounts(rows: catalog.sites + catalog.appendix)

        VStack(alignment: .leading, spacing: 0) {
            // Summary & semantic separation notice
            VStack(alignment: .leading, spacing: 6) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 520), spacing: 6, alignment: .leading)], alignment: .leading, spacing: 6) {
                    summaryBadge("비교 항목 \(catalog.sites.count)개 · 도메인 \(catalog.summary["unique_normalized_hosts"] ?? SupportCatalogValidator.expectedNormalizedHostCount)개",
                                 bg: palette.surface2Color, fg: palette.textColor)
                    summaryBadge("전용 연동 후보 \(catalog.summary["domain_candidate_rows"] ?? SupportCatalogValidator.expectedDomainCandidateCount)개",
                                 bg: palette.accentSoftColor, fg: palette.accentColor)
                    summaryBadge("이름 후보(도메인 미확인) \(catalog.summary["weak_name_only_rows"] ?? SupportCatalogValidator.expectedWeakCandidateCount)개",
                                 bg: palette.warnSoftColor, fg: palette.warnInkColor)
                    summaryBadge("후보 미확인 \(catalog.summary["no_candidate_rows"] ?? SupportCatalogValidator.expectedUnmatchedCount)개",
                                 bg: palette.surface2Color, fg: palette.text2Color)
                    summaryBadge("연동 점검 대상 \(catalog.summary["inactive_only_candidate_rows"] ?? SupportCatalogValidator.expectedInactiveCandidateCount)개",
                                 bg: palette.warnSoftColor, fg: palette.warnColor)
                    summaryBadge("시험 대기 \(trialCounts.pending)개",
                                 bg: palette.surface2Color, fg: palette.mutedColor)
                    summaryBadge("해당 모드 저장 성공 \(trialCounts.savePassed)개",
                                 bg: Color.green.opacity(0.16), fg: Color.green)
                    summaryBadge("분석 성공 \(trialCounts.analysisPassed)개",
                                 bg: palette.accentSoftColor, fg: palette.accentColor)
                    summaryBadge("시험 실패 \(trialCounts.failed)개 · 현재 이용 불가 \(trialCounts.unavailable)개",
                                 bg: palette.warnSoftColor, fg: palette.warnInkColor)
                    summaryBadge("시험 결과 미확인 \(trialCounts.unknown)개",
                                 bg: palette.surface2Color, fg: palette.text2Color)
                }

                Text("• 위 288 / 57 / 313 수치는 정적 추출기 후보 대조 집계이며 실제 다운로드 성공 보증이 아닙니다. 등록 연동 1,754개는 yt-dlp 추출기(IE) 수이며 사이트 수가 아닙니다.\n• '분석 성공'(metadata / extract / extract_info)은 메타데이터·추출 분석만 통과한 상태이며 MP4 파일 저장 완료 증명이 아닙니다. '해당 모드 저장 성공'(download / full_save / record / vod_mp4)만 실제 저장 검증 건수에 포함됩니다.\n• '도메인 저장 사례'(비교 목록 21개 행·목록 밖 4개 호스트)는 같은 도메인에서 저장된 기록이 있다는 참고 표시일 뿐, 해당 행·모드(예: Vimeo On Demand, Twitch Clip 등)의 검증 완료 근거가 아닙니다.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(palette.surfaceColor)

            Rectangle().fill(palette.borderColor).frame(height: 1)

            // Controls bar: Picker + Search + Filter
            VStack(alignment: .leading, spacing: 8) {
                Picker("구분", selection: $selectedTab) {
                    Text("사이트 목록 (\(catalog.sites.count) + 목록 밖 \(catalog.appendix.count))").tag(CatalogTab.sites)
                    Text("등록 연동 (\(catalog.registeredExtractors.count))").tag(CatalogTab.extractors)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: .infinity)
                .accessibilityLabel("사이트 목록 또는 등록 연동 선택")

                HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField(
                        selectedTab == .sites
                            ? "사이트 이름 또는 도메인 검색 (예: youtube.com, vimeo, bbc)"
                            : "추출기 이름, 키(key), 설명 검색 (예: Youtube, generic, twitch)",
                        text: $searchText
                    )
                    .textFieldStyle(.plain)
                    .accessibilityLabel(selectedTab == .sites ? "사이트 이름 또는 도메인 검색" : "등록 연동 이름, 키, 설명 검색")

                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("검색어 지우기")
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(palette.surfaceColor))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(palette.border2Color, lineWidth: 1))
                .frame(minWidth: 0, maxWidth: .infinity)

                if selectedTab == .sites {
                    Picker("분류", selection: $siteFilter) {
                        ForEach(SiteFilter.allCases) { f in
                            Text(siteFilterLabel(f, counts: trialCounts)).tag(f)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(minWidth: 140, idealWidth: 200, maxWidth: 220)
                    .accessibilityLabel("사이트 상태 분류 필터")
                } else {
                    Picker("상태", selection: $extractorFilter) {
                        ForEach(ExtractorFilter.allCases) { f in
                            Text(f.rawValue).tag(f)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(minWidth: 140, idealWidth: 200, maxWidth: 220)
                    .accessibilityLabel("등록 연동 상태 필터")
                }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(palette.cardColor)

            Rectangle().fill(palette.borderColor).frame(height: 1)

            if selectedTab == .sites {
                sitesListContent(catalog: catalog)
            } else {
                extractorsListContent(catalog: catalog)
            }
        }
    }

    @ViewBuilder
    private func sitesListContent(catalog: SupportCatalog) -> some View {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filteredMain: [SiteEntry] = catalog.sites.filter { site in
            guard matchesSiteFilter(site, filter: siteFilter, isAppendix: false) else { return false }
            guard !query.isEmpty else { return true }
            return site.name.lowercased().contains(query)
                || site.domain.lowercased().contains(query)
                || site.normalizedHost.lowercased().contains(query)
        }
        let filteredAppendix: [SiteEntry] = catalog.appendix.filter { site in
            guard matchesSiteFilter(site, filter: siteFilter, isAppendix: true) else { return false }
            guard !query.isEmpty else { return true }
            return site.name.lowercased().contains(query)
                || site.domain.lowercased().contains(query)
                || site.normalizedHost.lowercased().contains(query)
        }

        if filteredMain.isEmpty && filteredAppendix.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                Text("조건에 맞는 사이트 항목이 없습니다.")
                    .font(.subheadline.bold())
                    .foregroundStyle(.secondary)
                Text("사이트 이름이나 도메인으로만 검색합니다 (영상 제목·개별 주소는 포함하지 않음).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                if !filteredMain.isEmpty {
                    Section("비교 기준 사이트 목록 (\(filteredMain.count) / \(catalog.sites.count)개)") {
                        ForEach(filteredMain) { site in
                            SupportedSiteRowView(site: site, isAppendix: false)
                        }
                    }
                }
                if !filteredAppendix.isEmpty {
                    Section {
                        ForEach(filteredAppendix) { site in
                            SupportedSiteRowView(site: site, isAppendix: true)
                        }
                    } header: {
                        Text("목록 밖 저장 사례 (\(filteredAppendix.count) / \(catalog.appendix.count)개 도메인)")
                    } footer: {
                        Text("658개 비교 표 바깥의 도메인에서 확인된 저장 사례(호스트 중복 제거 4개)이며, 개별 모드 검증 완료가 아닌 '시험 대기' 상태로 동일하게 관리됩니다.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .background(palette.bgColor)
            .frame(minHeight: 0, maxHeight: .infinity)
        }
    }

    private func matchesSiteFilter(_ site: SiteEntry, filter: SiteFilter, isAppendix: Bool) -> Bool {
        switch filter {
        case .all:
            return true
        case .dedicated:
            return !isAppendix && site.candidateGroup == .dedicatedCandidate
        case .weakName:
            return !isAppendix && site.candidateGroup == .weakNameCandidate
        case .unconfirmed:
            return !isAppendix && site.candidateGroup == .unconfirmedCandidate
        case .workingFalse:
            return !isAppendix && site.isWorkingFalseOnly
        case .domainExample:
            return site.hasDomainSaveExample
        case .appendixOnly:
            return isAppendix
        case .trialSavePassed:
            if case .savePassed = site.resolvedModeTrial { return true }
            return false
        case .trialAnalysisPassed:
            if case .analysisPassed = site.resolvedModeTrial { return true }
            return false
        case .trialFailed:
            if case .failed = site.resolvedModeTrial { return true }
            return false
        case .trialUnavailable:
            if case .unavailable = site.resolvedModeTrial { return true }
            return false
        case .trialUnknown:
            if case .unknown = site.resolvedModeTrial { return true }
            return false
        case .trialPending:
            if case .pending = site.resolvedModeTrial { return true }
            return false
        }
    }

    @ViewBuilder
    private func extractorsListContent(catalog: SupportCatalog) -> some View {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered: [ExtractorEntry] = catalog.registeredExtractors.filter { ext in
            switch extractorFilter {
            case .all: break
            case .workingTrue: if !ext.working { return false }
            case .workingFalse: if ext.working { return false }
            }
            guard !query.isEmpty else { return true }
            if ext.key.lowercased().contains(query) || ext.name.lowercased().contains(query) {
                return true
            }
            if let desc = ext.description, desc.lowercased().contains(query) {
                return true
            }
            return false
        }

        if filtered.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                Text("조건에 맞는 등록 연동(IE)이 없습니다.")
                    .font(.subheadline.bold())
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                Section {
                    ForEach(filtered) { ext in
                        RegisteredExtractorRowView(extractor: ext)
                    }
                } header: {
                    Text("yt-dlp 등록 연동 추출기 (\(filtered.count) / \(catalog.registeredExtractors.count)개 · 사이트 수 아님)")
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .background(palette.bgColor)
            .frame(minHeight: 0, maxHeight: .infinity)
        }
    }

    private func summaryBadge(_ text: String, bg: Color, fg: Color) -> some View {
        Text(text)
            .font(.caption2.bold())
            .foregroundColor(fg)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 10).fill(bg))
    }
}

// MARK: - Row Views

private struct SupportedSiteRowView: View {
    let site: SiteEntry
    let isAppendix: Bool
    @Environment(\.bkPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                if let rowNum = site.rowNumber {
                    Text("#\(rowNum)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(site.name)
                        .font(.subheadline.bold())
                        .foregroundColor(palette.textColor)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(domainDisplayText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .trailing, spacing: 3) {
                // 1. Static candidate group or appendix label
                candidateBadge

                // 2. working=false warning badge when applicable
                if site.isWorkingFalseOnly {
                    badge("연동 점검 대상", bg: palette.warnSoftColor, fg: palette.warnColor)
                        .help("연결된 추출기(IE)가 working=false로 표시된 항목입니다.")
                }

                // 3. Domain save example badge (kept even while mode trial is pending; never green verified)
                if site.hasDomainSaveExample {
                    badge("도메인 저장 사례", bg: palette.surface2Color, fg: palette.text2Color)
                        .help("같은 도메인에서 저장된 사례가 있으나, 이 항목(개별 모드)의 검증 완료 근거는 아닙니다.")
                }

                // 4. Mode trial status badge
                trialBadge
                }
                .layoutPriority(1)
            }

            VStack(alignment: .leading, spacing: 2) {
                if !site.extractorKeys.isEmpty {
                    let preview = site.extractorKeys.prefix(4).joined(separator: ", ")
                    let extra = site.extractorKeys.count > 4 ? " 외 \(site.extractorKeys.count - 4)개" : ""
                    Text("연결 추출기 후보: \(preview)\(extra)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(statusDetailNote)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    private var domainDisplayText: String {
        if SupportCatalogValidator.isDomainlessEntry(site) {
            return "특정 도메인 없음"
        }
        if site.domain == site.normalizedHost {
            return site.normalizedHost
        }
        return "\(site.domain) (\(site.normalizedHost))"
    }

    @ViewBuilder
    private var candidateBadge: some View {
        switch site.candidateGroup {
        case .dedicatedCandidate:
            badge("전용 연동 후보", bg: palette.accentSoftColor, fg: palette.accentColor)
        case .weakNameCandidate:
            badge("이름 후보(도메인 미확인)", bg: palette.warnSoftColor, fg: palette.warnInkColor)
        case .unconfirmedCandidate:
            badge("전용 연동 후보 미확인", bg: palette.surface2Color, fg: palette.text2Color)
        case .outsideAppendix:
            badge("목록 밖 저장 사례", bg: palette.accentSoftColor, fg: palette.accentColor)
        }
    }

    @ViewBuilder
    private var trialBadge: some View {
        switch site.resolvedModeTrial {
        case .pending:
            badge(site.resolvedModeTrial.badgeTitle, bg: palette.surface2Color, fg: palette.mutedColor)
        case .analysisPassed(_, let checkedAt):
            badge(site.resolvedModeTrial.badgeTitle, bg: palette.accentSoftColor, fg: palette.accentColor)
                .help("분석 점검 시각: \(checkedAt) (메타데이터·추출 분석만 확인됨, MP4 파일 저장 완료 증명이 아님)")
        case .savePassed(_, let checkedAt):
            badge(site.resolvedModeTrial.badgeTitle, bg: Color.green.opacity(0.16), fg: Color.green)
                .help("저장 검증 시각: \(checkedAt)")
        case .failed(_, let checkedAt):
            badge(site.resolvedModeTrial.badgeTitle, bg: palette.dangerSoftColor, fg: palette.dangerColor)
                .help("점검 시각: \(checkedAt)")
        case .unavailable(_, let checkedAt):
            badge(site.resolvedModeTrial.badgeTitle, bg: palette.warnSoftColor, fg: palette.warnInkColor)
                .help("점검 시각: \(checkedAt)")
        case .unknown(let checkedAt):
            badge(site.resolvedModeTrial.badgeTitle, bg: palette.surface2Color, fg: palette.text2Color)
                .help("점검 시각: \(checkedAt) (인식되지 않은 시험 모드 또는 상태)")
        }
    }

    private var statusDetailNote: String {
        var notes: [String] = []
        if isAppendix {
            notes.append("비교 목록 밖 도메인 저장 사례 · 모드별 실제 시험은 별도")
        } else if site.hasDomainSaveExample {
            notes.append("도메인 저장 사례는 도메인 단위 참고 기록이며 이 행·모드의 검증 완료 근거가 아님")
        }
        if site.candidateGroup == .unconfirmedCandidate {
            notes.append("지원 불가 확정 아님 (일반 추출 Generic·앱 안 브라우저 동작 가능)")
        } else if site.candidateGroup == .weakNameCandidate {
            notes.append("이름 유사 추출기 후보만 있으며 도메인 규칙 일치는 미확인")
        }
        if site.isWorkingFalseOnly {
            notes.append("등록 추출기 working=false (연동 점검 대상)")
        }
        return notes.joined(separator: " · ")
    }

    private func badge(_ text: String, bg: Color, fg: Color) -> some View {
        Text(text)
            .font(.caption2.bold())
            .foregroundColor(fg)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(bg))
    }
}

private struct RegisteredExtractorRowView: View {
    let extractor: ExtractorEntry
    @Environment(\.bkPalette) private var palette

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(extractor.key)
                        .font(.subheadline.bold())
                        .foregroundColor(palette.textColor)
                    if extractor.name != extractor.key {
                        Text(extractor.name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let desc = extractor.description {
                    Text(desc)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            if !extractor.working {
                Text("연동 점검 대상 (working=false)")
                    .font(.caption2.bold())
                    .foregroundColor(palette.warnColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(palette.warnSoftColor))
            } else {
                Text("등록됨 (시험 별도)")
                    .font(.caption2)
                    .foregroundColor(palette.mutedColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(palette.surface2Color))
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
