import Foundation

public enum SAWTeamCapability: String, Codable, CaseIterable, Equatable, Sendable {
    case read
    case navigate
    case interact
    case exportDocument
    case search
}

public struct SAWTeamWorker: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var providerID: String
    public var accountID: String
    public var websiteDataStoreID: UUID
    public var displayName: String?
    public var capabilities: [SAWTeamCapability]
    /// Explicit local CLI account ID. nil means automatic local CLI provider pool (never derived from web accountID).
    public var cliAccountID: String?

    public init(
        id: UUID = UUID(),
        providerID: String,
        accountID: String,
        websiteDataStoreID: UUID,
        displayName: String? = nil,
        capabilities: [SAWTeamCapability] = [.read, .navigate, .search],
        cliAccountID: String? = nil
    ) {
        self.cliAccountID = cliAccountID
        self.id = id
        self.providerID = providerID
        self.accountID = accountID
        self.websiteDataStoreID = websiteDataStoreID
        self.displayName = displayName
        self.capabilities = capabilities
    }

    /// Stable session boundary deterministic key.
    /// Uses length-prefixed strings without collapsing distinct account IDs or risking separator collisions.
    public var sessionScopeKey: String {
        "\(providerID.utf8.count):\(providerID)/\(accountID.utf8.count):\(accountID)/\(websiteDataStoreID.uuidString)"
    }

    public func allows(_ capability: SAWTeamCapability) -> Bool {
        capabilities.contains(capability)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case providerID
        case accountID
        case websiteDataStoreID
        case displayName
        case capabilities
        case cliAccountID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.cliAccountID = try container.decodeIfPresent(String.self, forKey: .cliAccountID)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.providerID = try container.decode(String.self, forKey: .providerID)
        self.accountID = try container.decode(String.self, forKey: .accountID)
        self.websiteDataStoreID = try container.decode(UUID.self, forKey: .websiteDataStoreID)
        self.displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        self.capabilities = try container.decodeIfPresent([SAWTeamCapability].self, forKey: .capabilities) ?? [.read, .navigate, .search]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(providerID, forKey: .providerID)
        try container.encode(accountID, forKey: .accountID)
        try container.encode(websiteDataStoreID, forKey: .websiteDataStoreID)
        try container.encodeIfPresent(displayName, forKey: .displayName)
        try container.encode(capabilities, forKey: .capabilities)
        try container.encodeIfPresent(cliAccountID, forKey: .cliAccountID)
    }
}

public struct SAWTeamConfiguration: Codable, Equatable, Sendable {
    public var workers: [SAWTeamWorker]
    /// 자동 생성 출처를 나타내며, 사용자가 수동 편집한 뒤에도 연결 경로 보존을 위해 유지합니다.
    public var isAutomatic: Bool

    public init(workers: [SAWTeamWorker] = [], isAutomatic: Bool = false) {
        self.workers = workers
        self.isAutomatic = isAutomatic
    }

    enum CodingKeys: String, CodingKey {
        case workers
        case isAutomatic
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.workers = try container.decodeIfPresent([SAWTeamWorker].self, forKey: .workers) ?? []
        self.isAutomatic = try container.decodeIfPresent(Bool.self, forKey: .isAutomatic) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(workers, forKey: .workers)
        try container.encode(isAutomatic, forKey: .isAutomatic)
    }
}

public enum SAWTeamAssignmentStatus: String, Codable, CaseIterable, Equatable, Sendable {
    case queued
    case running
    case paused
    case completed
    case failed
}

public struct SAWTeamAssignment: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var projectID: UUID
    public var runID: UUID
    public var workerID: UUID
    public var goal: String
    public var generation: UInt64
    public var requestID: UUID
    public var status: SAWTeamAssignmentStatus
    public var result: SAWTeamResult?
    public var permissions: [SAWTeamCapability]
    public var ownedTabIDs: [UUID]

    public init(
        id: UUID = UUID(),
        projectID: UUID,
        runID: UUID,
        workerID: UUID,
        goal: String,
        generation: UInt64,
        requestID: UUID = UUID(),
        status: SAWTeamAssignmentStatus = .queued,
        result: SAWTeamResult? = nil,
        permissions: [SAWTeamCapability] = [],
        ownedTabIDs: [UUID] = []
    ) {
        self.id = id
        self.projectID = projectID
        self.runID = runID
        self.workerID = workerID
        self.goal = goal
        self.generation = generation
        self.requestID = requestID
        self.status = status
        self.result = result
        self.permissions = permissions
        self.ownedTabIDs = ownedTabIDs
    }

    /// Evaluates whether an incoming result matches the active run context and avoids stale overwrites.
    public func accepts(_ result: SAWTeamResult, currentGeneration: UInt64, currentRequestID: UUID) -> Bool {
        guard status == .running else { return false }
        guard result.assignmentID == id else { return false }
        guard result.projectID == projectID else { return false }
        guard result.runID == runID else { return false }
        guard result.workerID == workerID else { return false }
        guard result.generation == generation else { return false }
        guard result.requestID == requestID else { return false }
        guard generation == currentGeneration else { return false }
        guard requestID == currentRequestID else { return false }
        return true
    }

    enum CodingKeys: String, CodingKey {
        case id
        case projectID
        case runID
        case workerID
        case goal
        case generation
        case requestID
        case status
        case result
        case permissions
        case ownedTabIDs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.projectID = try container.decode(UUID.self, forKey: .projectID)
        self.runID = try container.decode(UUID.self, forKey: .runID)
        self.workerID = try container.decode(UUID.self, forKey: .workerID)
        self.goal = try container.decode(String.self, forKey: .goal)
        self.generation = try container.decode(UInt64.self, forKey: .generation)
        self.requestID = try container.decode(UUID.self, forKey: .requestID)
        self.status = try container.decodeIfPresent(SAWTeamAssignmentStatus.self, forKey: .status) ?? .queued
        self.result = try container.decodeIfPresent(SAWTeamResult.self, forKey: .result)
        self.permissions = try container.decodeIfPresent([SAWTeamCapability].self, forKey: .permissions) ?? []
        self.ownedTabIDs = try container.decodeIfPresent([UUID].self, forKey: .ownedTabIDs) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(projectID, forKey: .projectID)
        try container.encode(runID, forKey: .runID)
        try container.encode(workerID, forKey: .workerID)
        try container.encode(goal, forKey: .goal)
        try container.encode(generation, forKey: .generation)
        try container.encode(requestID, forKey: .requestID)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(result, forKey: .result)
        try container.encode(permissions, forKey: .permissions)
        try container.encode(ownedTabIDs, forKey: .ownedTabIDs)
    }
}

public struct SAWTeamResult: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var assignmentID: UUID
    public var projectID: UUID
    public var runID: UUID
    public var workerID: UUID
    public var generation: UInt64
    public var requestID: UUID
    public var summary: String
    public var sourceURLs: [String]
    public var error: String?

    public init(
        id: UUID = UUID(),
        assignmentID: UUID,
        projectID: UUID,
        runID: UUID,
        workerID: UUID,
        generation: UInt64,
        requestID: UUID,
        summary: String,
        sourceURLs: [String] = [],
        error: String? = nil
    ) {
        self.id = id
        self.assignmentID = assignmentID
        self.projectID = projectID
        self.runID = runID
        self.workerID = workerID
        self.generation = generation
        self.requestID = requestID
        self.summary = summary
        self.sourceURLs = sourceURLs
        self.error = error
    }

    enum CodingKeys: String, CodingKey {
        case id
        case assignmentID
        case projectID
        case runID
        case workerID
        case generation
        case requestID
        case summary
        case sourceURLs
        case error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.assignmentID = try container.decode(UUID.self, forKey: .assignmentID)
        self.projectID = try container.decode(UUID.self, forKey: .projectID)
        self.runID = try container.decode(UUID.self, forKey: .runID)
        self.workerID = try container.decode(UUID.self, forKey: .workerID)
        self.generation = try container.decode(UInt64.self, forKey: .generation)
        self.requestID = try container.decode(UUID.self, forKey: .requestID)
        self.summary = try container.decode(String.self, forKey: .summary)
        self.sourceURLs = try container.decodeIfPresent([String].self, forKey: .sourceURLs) ?? []
        self.error = try container.decodeIfPresent(String.self, forKey: .error)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(assignmentID, forKey: .assignmentID)
        try container.encode(projectID, forKey: .projectID)
        try container.encode(runID, forKey: .runID)
        try container.encode(workerID, forKey: .workerID)
        try container.encode(generation, forKey: .generation)
        try container.encode(requestID, forKey: .requestID)
        try container.encode(summary, forKey: .summary)
        try container.encode(sourceURLs, forKey: .sourceURLs)
        try container.encodeIfPresent(error, forKey: .error)
    }
}
