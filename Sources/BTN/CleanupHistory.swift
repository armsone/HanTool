import Foundation

struct CleanupImpactSummary: Sendable {
    let beforeMetrics: MetricsSnapshot
    let afterMetrics: MetricsSnapshot
    let beforeDiskAvailableBytes: UInt64?
    let afterDiskAvailableBytes: UInt64?
    let completedAt: Date
    let receipt: CleanupReceipt?

    init(
        beforeMetrics: MetricsSnapshot,
        afterMetrics: MetricsSnapshot,
        beforeDiskAvailableBytes: UInt64?,
        afterDiskAvailableBytes: UInt64?,
        completedAt: Date,
        receipt: CleanupReceipt? = nil
    ) {
        self.beforeMetrics = beforeMetrics
        self.afterMetrics = afterMetrics
        self.beforeDiskAvailableBytes = beforeDiskAvailableBytes
        self.afterDiskAvailableBytes = afterDiskAvailableBytes
        self.completedAt = completedAt
        self.receipt = receipt
    }
}

enum SystemImpactCollector {
    static func collect() -> (metrics: MetricsSnapshot, diskAvailableBytes: UInt64?) {
        let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        let diskBytes = values?.volumeAvailableCapacityForImportantUsage.flatMap { value in
            value >= 0 ? UInt64(value) : nil
        }
        return (MetricsCollector.collect(), diskBytes)
    }
}

/// 정리 영수증의 개별 실행 항목.
struct CleanupReceiptItem: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let kind: String
    let path: String?
    let identityAtApproval: String?
    let identityAtExecution: String?
    let status: CleanupExecutionStatus
    let message: String
    let allocatedBytes: UInt64
    let method: String
}

/// 정리 계획 중 보존 원칙에 따라 제외된 항목.
struct CleanupPreservedItem: Codable, Identifiable, Equatable, Sendable {
    var id: String { path }
    let path: String
    let reason: String
}

/// 정리 1회 실행에 대한 결정적 영수증.
/// logical/allocated/실제 df 전후 변화를 명확히 분리하고,
/// 휴지통 이동 항목의 실제 확보량은 0으로 기록한다.
struct CleanupReceipt: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let startedAt: Date
    let finishedAt: Date
    let approvedIds: [String]
    let items: [CleanupReceiptItem]
    let dfBeforeBytes: UInt64?
    let dfAfterBytes: UInt64?
    /// 실제 df 볼륨 여유 증가량 (dfAfter - dfBefore; 음수 또는 미측정이면 0).
    /// 휴지통 이동은 비우기 전까지 볼륨 여유가 늘지 않으므로 확보량에 포함하지 않는다.
    let actualFreedBytes: Int64
    let preserved: [CleanupPreservedItem]
    let notes: [String]

    var totalAllocatedBytes: UInt64 {
        items.reduce(0) { $0 + $1.allocatedBytes }
    }

    var cleanedCount: Int { items.filter { $0.status == .cleaned }.count }
    var blockedCount: Int { items.filter { $0.status == .blocked }.count }
    var failedCount: Int { items.filter { $0.status == .failed }.count }
    var skippedCount: Int { items.filter { $0.status == .skipped }.count }
}

struct CleanupAuditEntry: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let timestamp: Date
    let category: String
    let target: String
    let status: CleanupExecutionStatus
    let message: String
    // 신규 확장 필드 (기존 JSON 역직렬화 100% 하위 호환성 보장)
    let path: String?
    let logicalBytes: UInt64?
    let allocatedBytes: UInt64?
    let actualFreedBytes: Int64?
    let recoveryMethod: String?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        category: String,
        target: String,
        status: CleanupExecutionStatus,
        message: String,
        path: String? = nil,
        logicalBytes: UInt64? = nil,
        allocatedBytes: UInt64? = nil,
        actualFreedBytes: Int64? = nil,
        recoveryMethod: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.category = category
        self.target = target
        self.status = status
        self.message = message
        self.path = path
        self.logicalBytes = logicalBytes
        self.allocatedBytes = allocatedBytes
        self.actualFreedBytes = actualFreedBytes
        self.recoveryMethod = recoveryMethod
    }

    enum CodingKeys: String, CodingKey {
        case id, timestamp, category, target, status, message
        case path, logicalBytes, allocatedBytes, actualFreedBytes, recoveryMethod
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.timestamp = try container.decode(Date.self, forKey: .timestamp)
        self.category = try container.decode(String.self, forKey: .category)
        self.target = try container.decode(String.self, forKey: .target)
        self.status = try container.decode(CleanupExecutionStatus.self, forKey: .status)
        self.message = try container.decode(String.self, forKey: .message)
        self.path = try container.decodeIfPresent(String.self, forKey: .path)
        self.logicalBytes = try container.decodeIfPresent(UInt64.self, forKey: .logicalBytes)
        self.allocatedBytes = try container.decodeIfPresent(UInt64.self, forKey: .allocatedBytes)
        self.actualFreedBytes = try container.decodeIfPresent(Int64.self, forKey: .actualFreedBytes)
        self.recoveryMethod = try container.decodeIfPresent(String.self, forKey: .recoveryMethod)
    }
}

final class CleanupAuditStore {
    static let httBundleDirectoryName = "com.local.screentranslator"
    static let btnSubdirectoryName = "BTN"
    static let historyFileName = "cleanup-history.json"

    static func httHistoryFileURL(applicationSupportDirectory: URL? = nil) -> URL {
        let applicationSupport = applicationSupportDirectory ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupport
            .appendingPathComponent(httBundleDirectoryName, isDirectory: true)
            .appendingPathComponent(btnSubdirectoryName, isDirectory: true)
            .appendingPathComponent(historyFileName)
    }

    private let fileURL: URL
    private let maximumEntries: Int

    init(
        fileURL: URL? = nil,
        maximumEntries: Int = 200,
        applicationSupportDirectory: URL? = nil
    ) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            // 원본 BTN/BackToNormal 이력 파일에 직접 쓰지 않도록 항상 HTT 전용 경로만 사용한다.
            self.fileURL = Self.httHistoryFileURL(applicationSupportDirectory: applicationSupportDirectory)
        }
        self.maximumEntries = max(1, maximumEntries)
    }

    func load() -> [CleanupAuditEntry] {
        guard let data = try? Data(contentsOf: fileURL),
              let entries = try? JSONDecoder().decode([CleanupAuditEntry].self, from: data)
        else { return [] }
        return Array(entries.suffix(maximumEntries))
    }

    @discardableResult
    func append(_ newEntries: [CleanupAuditEntry], to existing: [CleanupAuditEntry]) -> [CleanupAuditEntry] {
        guard !newEntries.isEmpty else { return existing }
        let merged = Array((existing + newEntries).suffix(maximumEntries))
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(merged)
            try data.write(to: fileURL, options: .atomic)
            return merged
        } catch {
            // 이력 저장 실패가 실제 정리 결과를 바꾸거나 재시도하게 만들면 안 된다.
            return existing
        }
    }
}

final class CleanupProtectionStore {
    static let protectionKey = "protectedCleanupCandidateIDs"

    private let defaults: UserDefaults
    private let key: String

    init(
        defaults: UserDefaults = BTNPreferences.resolveHTTDefaults() ?? .standard,
        key: String = CleanupProtectionStore.protectionKey
    ) {
        self.defaults = defaults
        self.key = key
    }

    func load() -> Set<String> {
        Set(defaults.stringArray(forKey: key) ?? [])
    }

    func save(_ identifiers: Set<String>) {
        defaults.set(identifiers.sorted(), forKey: key)
    }
}
