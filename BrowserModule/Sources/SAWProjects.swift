import Foundation
import Combine

// MARK: - SAW Models

/// Schedule configuration for an automated or manual SAW project run.
public struct SAWSchedule: Codable, Equatable {
    public var enabled: Bool
    public var frequency: String
    public var hour: Int
    public var minute: Int
    public var timeZoneID: String
    public var notBefore: Date? = nil

    public init(
        enabled: Bool = false,
        frequency: String = "manual",
        hour: Int = 7,
        minute: Int = 0,
        timeZoneID: String = TimeZone.current.identifier,
        notBefore: Date? = nil
    ) {
        self.enabled = enabled
        self.frequency = frequency
        self.hour = hour
        self.minute = minute
        self.timeZoneID = timeZoneID
        self.notBefore = notBefore
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, frequency, hour, minute, timeZoneID, notBefore
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        self.frequency = try container.decodeIfPresent(String.self, forKey: .frequency) ?? "manual"
        self.hour = try container.decodeIfPresent(Int.self, forKey: .hour) ?? 7
        self.minute = try container.decodeIfPresent(Int.self, forKey: .minute) ?? 0
        self.timeZoneID = try container.decodeIfPresent(String.self, forKey: .timeZoneID) ?? TimeZone.current.identifier
        self.notBefore = try container.decodeIfPresent(Date.self, forKey: .notBefore)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(frequency, forKey: .frequency)
        try container.encode(hour, forKey: .hour)
        try container.encode(minute, forKey: .minute)
        try container.encode(timeZoneID, forKey: .timeZoneID)
        try container.encodeIfPresent(notBefore, forKey: .notBefore)
    }
}

/// A high-level process step proposed by AI for the supervised project.
public struct SAWPlanStep: Identifiable, Codable, Equatable {
    public var id: String
    public var title: String
    public var status: String // "waiting", "current", "completed", "failed"

    public init(id: String = UUID().uuidString, title: String, status: String = "waiting") {
        self.id = id
        self.title = title
        self.status = status
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, status
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        self.title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        self.status = try container.decodeIfPresent(String.self, forKey: .status) ?? "waiting"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(status, forKey: .status)
    }
}

/// Metadata for a document artifact saved to the native desktop.
public struct SAWArtifact: Identifiable, Codable, Equatable {
    public var id: UUID
    public var title: String
    public var filename: String
    public var fileURL: String
    public var format: String // "html", "txt"
    public var createdAt: Date
    public var byteCount: Int
    public var runID: UUID? = nil
    public var contentDigest: String? = nil
    public var postEvidenceDigest: String? = nil
    public var exportedArtifactID: UUID? = nil

    public init(
        id: UUID = UUID(),
        title: String,
        filename: String,
        fileURL: String,
        format: String = "html",
        createdAt: Date = Date(),
        byteCount: Int = 0,
        runID: UUID? = nil,
        contentDigest: String? = nil,
        postEvidenceDigest: String? = nil,
        exportedArtifactID: UUID? = nil
    ) {
        self.id = id
        self.title = title
        self.filename = filename
        self.fileURL = fileURL
        self.format = format
        self.createdAt = createdAt
        self.byteCount = byteCount
        self.runID = runID
        self.contentDigest = contentDigest
        self.postEvidenceDigest = postEvidenceDigest
        self.exportedArtifactID = exportedArtifactID
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, filename, fileURL, format, createdAt, byteCount, runID, contentDigest, postEvidenceDigest, exportedArtifactID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        self.filename = try container.decodeIfPresent(String.self, forKey: .filename) ?? ""
        self.fileURL = try container.decodeIfPresent(String.self, forKey: .fileURL) ?? ""
        self.format = try container.decodeIfPresent(String.self, forKey: .format) ?? "html"
        self.createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        self.byteCount = try container.decodeIfPresent(Int.self, forKey: .byteCount) ?? 0
        self.runID = try container.decodeIfPresent(UUID.self, forKey: .runID)
        self.contentDigest = try container.decodeIfPresent(String.self, forKey: .contentDigest)
        self.postEvidenceDigest = try container.decodeIfPresent(String.self, forKey: .postEvidenceDigest)
        self.exportedArtifactID = try container.decodeIfPresent(UUID.self, forKey: .exportedArtifactID)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(filename, forKey: .filename)
        try container.encode(fileURL, forKey: .fileURL)
        try container.encode(format, forKey: .format)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(byteCount, forKey: .byteCount)
        try container.encodeIfPresent(runID, forKey: .runID)
        try container.encodeIfPresent(contentDigest, forKey: .contentDigest)
        try container.encodeIfPresent(postEvidenceDigest, forKey: .postEvidenceDigest)
        try container.encodeIfPresent(exportedArtifactID, forKey: .exportedArtifactID)
    }
}

/// Chronological chat message exchanged between human and planner supervisor.
public struct SAWChatMessage: Identifiable, Codable, Equatable {
    public var id: UUID
    public var sender: String // "user", "assistant", "system"
    public var text: String
    public var timestamp: Date
    public var artifact: SAWArtifact?
    public var actionReason: String?
    public var status: String? // "success", "error", "waiting"
    public var runID: UUID? = nil

    public init(
        id: UUID = UUID(),
        sender: String,
        text: String,
        timestamp: Date = Date(),
        artifact: SAWArtifact? = nil,
        actionReason: String? = nil,
        status: String? = nil,
        runID: UUID? = nil
    ) {
        self.id = id
        self.sender = sender
        self.text = text
        self.timestamp = timestamp
        self.artifact = artifact
        self.actionReason = actionReason
        self.status = status
        self.runID = runID
    }

    private enum CodingKeys: String, CodingKey {
        case id, sender, text, timestamp, artifact, actionReason, status, runID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.sender = try container.decodeIfPresent(String.self, forKey: .sender) ?? "assistant"
        self.text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        self.timestamp = try container.decodeIfPresent(Date.self, forKey: .timestamp) ?? Date()
        self.artifact = try container.decodeIfPresent(SAWArtifact.self, forKey: .artifact)
        self.actionReason = try container.decodeIfPresent(String.self, forKey: .actionReason)
        self.status = try container.decodeIfPresent(String.self, forKey: .status)
        self.runID = try container.decodeIfPresent(UUID.self, forKey: .runID)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(sender, forKey: .sender)
        try container.encode(text, forKey: .text)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encodeIfPresent(artifact, forKey: .artifact)
        try container.encodeIfPresent(actionReason, forKey: .actionReason)
        try container.encodeIfPresent(status, forKey: .status)
        try container.encodeIfPresent(runID, forKey: .runID)
    }
}

/// A supervised AI work (SAW) project definition with its goal, provider, and history.
public struct SAWPostEvidence: Codable, Equatable {
    public var id: String
    public var canonicalURL: String
    public var author: String
    public var publishedAt: Date
    public var caption: String
    public var capturedAt: Date
    public var runID: UUID?

    public init(
        id: String,
        canonicalURL: String,
        author: String,
        publishedAt: Date,
        caption: String,
        capturedAt: Date = Date(),
        runID: UUID? = nil
    ) {
        self.id = id
        self.canonicalURL = canonicalURL
        self.author = author.lowercased()
        self.publishedAt = publishedAt
        self.caption = caption
        self.capturedAt = capturedAt
        self.runID = runID
    }
}

public struct SAWPostCollectionRequirement: Codable, Equatable {
    public var minimumCount: Int
    public var beforeYear: Int
    public var author: String

    public init(minimumCount: Int, beforeYear: Int, author: String) {
        self.minimumCount = minimumCount
        self.beforeYear = beforeYear
        self.author = author.lowercased()
    }
}

public struct SAWProject: Identifiable, Codable, Equatable {
    public var id: UUID
    public var title: String
    public var goal: String
    public var providerID: String
    public var usesAutomaticProvider: Bool
    public var connectionMode: String
    public var referenceURLs: [String]
    public var notes: [String]
    public var schedule: SAWSchedule
    public var createdAt: Date
    public var updatedAt: Date
    public var archived: Bool
    public var conversation: [SAWChatMessage]
    public var planSteps: [SAWPlanStep]
    public var artifacts: [SAWArtifact]
    public var team: SAWTeamConfiguration?
    public var teamAssignments: [SAWTeamAssignment]
    public var workTabURLs: [String]
    public var selectedWorkTabIndex: Int
    public var postEvidence: [SAWPostEvidence]
    public var postCollectionRequirement: SAWPostCollectionRequirement?
    public var toolConfiguration: SAWToolConfiguration?
    /// Explicit native-UI test provenance. Never inferred from title/goal/dates and never set by AI/web responses.
    public var isTestProject: Bool
    public var testOwnerID: String?
    public var testSessionID: UUID?
    public var testFinishedAt: Date?

    /// Fixed local label for tests designated through the native manual UI. Not an account or security identity.
    public static let manualTestOwnerID = "HTT.manual-test"

    /// True only when flag, local owner and session are all present (the finished marker is checked separately).
    public var hasExplicitManualTestProvenance: Bool {
        isTestProject && testOwnerID == Self.manualTestOwnerID && testSessionID != nil
    }

    public init(
        id: UUID = UUID(),
        title: String = "새 프로젝트",
        goal: String = "",
        providerID: String = "chatgpt",
        usesAutomaticProvider: Bool = true,
        connectionMode: String = "automatic",
        referenceURLs: [String] = [],
        notes: [String] = [],
        schedule: SAWSchedule = SAWSchedule(),
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        archived: Bool = false,
        conversation: [SAWChatMessage] = [],
        planSteps: [SAWPlanStep] = [],
        artifacts: [SAWArtifact] = [],
        team: SAWTeamConfiguration? = nil,
        teamAssignments: [SAWTeamAssignment] = [],
        workTabURLs: [String] = [],
        selectedWorkTabIndex: Int = 0,
        postEvidence: [SAWPostEvidence] = [],
        postCollectionRequirement: SAWPostCollectionRequirement? = nil,
        toolConfiguration: SAWToolConfiguration? = nil,
        isTestProject: Bool = false,
        testOwnerID: String? = nil,
        testSessionID: UUID? = nil,
        testFinishedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.goal = goal
        self.providerID = providerID
        self.usesAutomaticProvider = usesAutomaticProvider
        self.connectionMode = (connectionMode == "cli" || connectionMode == "web") ? connectionMode : "automatic"
        self.referenceURLs = referenceURLs
        self.notes = notes
        self.schedule = schedule
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.archived = archived
        self.conversation = conversation
        self.planSteps = planSteps
        self.artifacts = artifacts
        self.team = team
        self.teamAssignments = teamAssignments
        self.workTabURLs = workTabURLs
        self.selectedWorkTabIndex = selectedWorkTabIndex
        self.postEvidence = postEvidence
        self.postCollectionRequirement = postCollectionRequirement
        self.toolConfiguration = toolConfiguration
        self.isTestProject = isTestProject
        self.testOwnerID = testOwnerID
        self.testSessionID = testSessionID
        self.testFinishedAt = testFinishedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, goal, providerID, usesAutomaticProvider, connectionMode, referenceURLs, notes, schedule, createdAt, updatedAt, archived, conversation, planSteps, artifacts, team, teamAssignments, workTabURLs, selectedWorkTabIndex, postEvidence, postCollectionRequirement, toolConfiguration
        case isTestProject, testOwnerID, testSessionID, testFinishedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.title = try container.decodeIfPresent(String.self, forKey: .title) ?? "새 프로젝트"
        self.goal = try container.decodeIfPresent(String.self, forKey: .goal) ?? ""
        self.providerID = try container.decodeIfPresent(String.self, forKey: .providerID) ?? "chatgpt"
        self.usesAutomaticProvider = try container.decodeIfPresent(Bool.self, forKey: .usesAutomaticProvider) ?? true
        let rawMode = try container.decodeIfPresent(String.self, forKey: .connectionMode)
        if let raw = rawMode, (raw == "cli" || raw == "web") {
            self.connectionMode = raw
        } else {
            self.connectionMode = "automatic"
        }
        self.referenceURLs = try container.decodeIfPresent([String].self, forKey: .referenceURLs) ?? []
        self.notes = try container.decodeIfPresent([String].self, forKey: .notes) ?? []
        self.schedule = try container.decodeIfPresent(SAWSchedule.self, forKey: .schedule) ?? SAWSchedule()
        self.createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        self.updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        self.archived = try container.decodeIfPresent(Bool.self, forKey: .archived) ?? false
        self.conversation = try container.decodeIfPresent([SAWChatMessage].self, forKey: .conversation) ?? []
        self.planSteps = try container.decodeIfPresent([SAWPlanStep].self, forKey: .planSteps) ?? []
        self.artifacts = try container.decodeIfPresent([SAWArtifact].self, forKey: .artifacts) ?? []
        self.team = try container.decodeIfPresent(SAWTeamConfiguration.self, forKey: .team)
        self.teamAssignments = try container.decodeIfPresent([SAWTeamAssignment].self, forKey: .teamAssignments) ?? []
        self.workTabURLs = try container.decodeIfPresent([String].self, forKey: .workTabURLs) ?? []
        self.selectedWorkTabIndex = try container.decodeIfPresent(Int.self, forKey: .selectedWorkTabIndex) ?? 0
        self.postEvidence = try container.decodeIfPresent([SAWPostEvidence].self, forKey: .postEvidence) ?? []
        self.postCollectionRequirement = try container.decodeIfPresent(SAWPostCollectionRequirement.self, forKey: .postCollectionRequirement)
        self.toolConfiguration = try container.decodeIfPresent(SAWToolConfiguration.self, forKey: .toolConfiguration)
        self.isTestProject = try container.decodeIfPresent(Bool.self, forKey: .isTestProject) ?? false
        self.testOwnerID = try container.decodeIfPresent(String.self, forKey: .testOwnerID)
        self.testSessionID = try container.decodeIfPresent(UUID.self, forKey: .testSessionID)
        self.testFinishedAt = try container.decodeIfPresent(Date.self, forKey: .testFinishedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(goal, forKey: .goal)
        try container.encode(providerID, forKey: .providerID)
        try container.encode(usesAutomaticProvider, forKey: .usesAutomaticProvider)
        try container.encode(connectionMode, forKey: .connectionMode)
        try container.encode(referenceURLs, forKey: .referenceURLs)
        try container.encode(notes, forKey: .notes)
        try container.encode(schedule, forKey: .schedule)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(archived, forKey: .archived)
        try container.encode(conversation, forKey: .conversation)
        try container.encode(planSteps, forKey: .planSteps)
        try container.encode(artifacts, forKey: .artifacts)
        try container.encodeIfPresent(team, forKey: .team)
        try container.encode(teamAssignments, forKey: .teamAssignments)
        try container.encode(workTabURLs, forKey: .workTabURLs)
        try container.encode(selectedWorkTabIndex, forKey: .selectedWorkTabIndex)
        try container.encode(postEvidence, forKey: .postEvidence)
        try container.encodeIfPresent(postCollectionRequirement, forKey: .postCollectionRequirement)
        try container.encodeIfPresent(toolConfiguration, forKey: .toolConfiguration)
        // Only explicit test projects carry provenance keys; ordinary/legacy user objects encode unchanged.
        if isTestProject {
            try container.encode(true, forKey: .isTestProject)
            try container.encodeIfPresent(testOwnerID, forKey: .testOwnerID)
            try container.encodeIfPresent(testSessionID, forKey: .testSessionID)
            try container.encodeIfPresent(testFinishedAt, forKey: .testFinishedAt)
        }
    }
}

/// Execution run record for a SAW project execution slot.
public struct SAWRunRecord: Identifiable, Codable, Equatable {
    public var id: UUID
    public var projectID: UUID
    public var slotKey: String?
    public var startedAt: Date
    public var endedAt: Date?
    public var status: String
    public var summary: String
    public var originalGoal: String? = nil

    public init(
        id: UUID = UUID(),
        projectID: UUID,
        slotKey: String? = nil,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        status: String = "queued",
        summary: String = "",
        originalGoal: String? = nil
    ) {
        self.id = id
        self.projectID = projectID
        self.slotKey = slotKey
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.status = status
        self.summary = summary
        self.originalGoal = originalGoal
    }

    private enum CodingKeys: String, CodingKey {
        case id, projectID, slotKey, startedAt, endedAt, status, summary, originalGoal
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.projectID = try container.decode(UUID.self, forKey: .projectID)
        self.slotKey = try container.decodeIfPresent(String.self, forKey: .slotKey)
        self.startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt) ?? Date()
        self.endedAt = try container.decodeIfPresent(Date.self, forKey: .endedAt)
        self.status = try container.decodeIfPresent(String.self, forKey: .status) ?? "queued"
        self.summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        self.originalGoal = try container.decodeIfPresent(String.self, forKey: .originalGoal)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(projectID, forKey: .projectID)
        try container.encodeIfPresent(slotKey, forKey: .slotKey)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encodeIfPresent(endedAt, forKey: .endedAt)
        try container.encode(status, forKey: .status)
        try container.encode(summary, forKey: .summary)
        try container.encodeIfPresent(originalGoal, forKey: .originalGoal)
    }
}

// MARK: - SAW Project Store

/// Durable atomic per-project persistence and execution tracking for SAW.
@MainActor
public final class SAWProjectStore: ObservableObject {
    @Published public private(set) var projects: [SAWProject] = []
    @Published public private(set) var runs: [SAWRunRecord] = []
    @Published public private(set) var errorMessage: String? = nil

    public let directory: URL
    public let persistent: Bool

    private let fileURL: URL
    private var reservedSlots: [UUID: [String]] = [:]
    private var processedKeys: [UUID: [String]] = [:]
    private var loadFailed: Bool = false

    // Practical retention bounds for high-churn metadata; dedup reservations are never evicted.
    private static let maxRunsRetention = 1000
    private static let maxNotesPerProject = 200
    private static let maxConversationPerProject = 200
    private static let maxPlanStepsPerProject = 30
    private static let maxArtifactsPerProject = 50
    private static let maxProcessedKeysPerProject = 2000

    public init(directory: URL, persistent: Bool = true) {
        self.directory = directory
        self.persistent = persistent
        self.fileURL = directory.appendingPathComponent("saw-projects.json", isDirectory: false)

        if persistent {
            load()
        }
    }

    public func upsert(_ project: SAWProject) {
        if let idx = projects.firstIndex(where: { $0.id == project.id }) {
            projects[idx] = project
        } else {
            projects.append(project)
        }
        persist()
    }

    public func archive(_ id: UUID) {
        if let idx = projects.firstIndex(where: { $0.id == id }) {
            projects[idx].archived = true
            projects[idx].updatedAt = Date()
            persist()
        }
    }

    public func record(_ run: SAWRunRecord) {
        if let idx = runs.firstIndex(where: { $0.id == run.id }) {
            runs[idx] = run
        } else {
            runs.append(run)
            if runs.count > Self.maxRunsRetention {
                runs.removeFirst(runs.count - Self.maxRunsRetention)
            }
        }
        persist()
    }

    public func appendNote(projectID: UUID, note: String) {
        guard let idx = projects.firstIndex(where: { $0.id == projectID }) else { return }
        projects[idx].notes.append(note)
        if projects[idx].notes.count > Self.maxNotesPerProject {
            projects[idx].notes.removeFirst(projects[idx].notes.count - Self.maxNotesPerProject)
        }
        projects[idx].updatedAt = Date()
        persist()
    }

    public func appendChatMessage(projectID: UUID, message: SAWChatMessage) {
        guard let idx = projects.firstIndex(where: { $0.id == projectID }) else { return }
        projects[idx].conversation.append(message)
        if projects[idx].conversation.count > Self.maxConversationPerProject {
            projects[idx].conversation.removeFirst(projects[idx].conversation.count - Self.maxConversationPerProject)
        }
        projects[idx].updatedAt = Date()
        persist()
    }

    public func updatePlanSteps(projectID: UUID, steps: [SAWPlanStep]) {
        guard let idx = projects.firstIndex(where: { $0.id == projectID }) else { return }
        projects[idx].planSteps = Array(steps.prefix(Self.maxPlanStepsPerProject))
        projects[idx].updatedAt = Date()
        persist()
    }

    public func appendArtifact(projectID: UUID, artifact: SAWArtifact) {
        guard let idx = projects.firstIndex(where: { $0.id == projectID }) else { return }
        projects[idx].artifacts.append(artifact)
        if projects[idx].artifacts.count > Self.maxArtifactsPerProject {
            projects[idx].artifacts.removeFirst(projects[idx].artifacts.count - Self.maxArtifactsPerProject)
        }
        projects[idx].updatedAt = Date()
        persist()
    }

    public func reserveSlot(projectID: UUID, key: String) -> Bool {
        guard !key.isEmpty else { return false }

        var current = reservedSlots[projectID] ?? []
        if current.contains(key) {
            return false
        }

        let previous = reservedSlots[projectID]
        current.append(key)
        reservedSlots[projectID] = current

        if persistent {
            let success = persist()
            if !success {
                // Rollback in-memory state when write fails so failed reservations are never exposed
                reservedSlots[projectID] = previous
                return false
            }
        }

        return true
    }

    public func hasProcessed(projectID: UUID, key: String) -> Bool {
        guard !key.isEmpty else { return false }
        return processedKeys[projectID]?.contains(key) == true
    }

    public func markProcessed(projectID: UUID, key: String) {
        guard !key.isEmpty else { return }
        var current = processedKeys[projectID] ?? []
        guard !current.contains(key) else { return }

        current.append(key)
        if current.count > Self.maxProcessedKeysPerProject {
            current.removeFirst(current.count - Self.maxProcessedKeysPerProject)
        }
        processedKeys[projectID] = current
        persist()
    }

    /// Removes exactly one explicitly designated, QA-finished manual test project together with its own runs and its
    /// own reservedSlots/processedKeys entries. Every store-side guard is re-checked here; unrelated projects, runs and
    /// keys keep their order and values. A failed write restores the whole in-memory state.
    @discardableResult
    public func removeSettledTestProject(id: UUID, sessionID: UUID) -> Bool {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return false }
        let project = projects[index]
        guard project.hasExplicitManualTestProvenance, project.testSessionID == sessionID,
              let finishedAt = project.testFinishedAt,
              !project.archived, !project.schedule.enabled,
              !project.teamAssignments.contains(where: { $0.status == .queued || $0.status == .running }) else { return false }

        let terminalStatuses: Set<String> = ["completed", "failed", "cancelled", "interrupted"]
        let ownRuns = runs.filter { $0.projectID == id }
        guard ownRuns.allSatisfy({ $0.endedAt != nil && terminalStatuses.contains($0.status) && $0.startedAt <= finishedAt }) else {
            return false
        }

        let previousProjects = projects
        let previousRuns = runs
        let previousSlots = reservedSlots
        let previousKeys = processedKeys

        projects.remove(at: index)
        runs.removeAll { $0.projectID == id }
        reservedSlots[id] = nil
        processedKeys[id] = nil

        guard persist() else {
            projects = previousProjects
            runs = previousRuns
            reservedSlots = previousSlots
            processedKeys = previousKeys
            return false
        }
        return true
    }

    // MARK: - Persistence Details

    private struct PersistedSnapshot: Codable {
        var projects: [SAWProject]
        var runs: [SAWRunRecord]
        var reservedSlots: [UUID: [String]]
        var processedKeys: [UUID: [String]]

        enum CodingKeys: String, CodingKey {
            case projects, runs, reservedSlots, processedKeys
        }

        init(
            projects: [SAWProject] = [],
            runs: [SAWRunRecord] = [],
            reservedSlots: [UUID: [String]] = [:],
            processedKeys: [UUID: [String]] = [:]
        ) {
            self.projects = projects
            self.runs = runs
            self.reservedSlots = reservedSlots
            self.processedKeys = processedKeys
        }

        init(from decoder: Decoder) throws {
            if let container = try? decoder.container(keyedBy: CodingKeys.self) {
                self.projects = (try? container.decodeIfPresent([SAWProject].self, forKey: .projects)) ?? []
                self.runs = (try? container.decodeIfPresent([SAWRunRecord].self, forKey: .runs)) ?? []

                if let directSlots = try? container.decodeIfPresent([UUID: [String]].self, forKey: .reservedSlots) {
                    self.reservedSlots = directSlots
                } else if let stringSlots = try? container.decodeIfPresent([String: [String]].self, forKey: .reservedSlots) {
                    var converted: [UUID: [String]] = [:]
                    for (k, v) in stringSlots {
                        if let u = UUID(uuidString: k) { converted[u] = v }
                    }
                    self.reservedSlots = converted
                } else {
                    self.reservedSlots = [:]
                }

                if let directKeys = try? container.decodeIfPresent([UUID: [String]].self, forKey: .processedKeys) {
                    self.processedKeys = directKeys
                } else if let stringKeys = try? container.decodeIfPresent([String: [String]].self, forKey: .processedKeys) {
                    var converted: [UUID: [String]] = [:]
                    for (k, v) in stringKeys {
                        if let u = UUID(uuidString: k) { converted[u] = v }
                    }
                    self.processedKeys = converted
                } else {
                    self.processedKeys = [:]
                }
            } else if let single = try? decoder.singleValueContainer(),
                      let projectList = try? single.decode([SAWProject].self) {
                self.projects = projectList
                self.runs = []
                self.reservedSlots = [:]
                self.processedKeys = [:]
            } else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unknown or corrupted saw-projects structure")
                )
            }
        }
    }

    private func load() {
        guard persistent else { return }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            // Nonexistent initial file is normal
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = Self.makeDecoder()
            let snapshot = try decoder.decode(PersistedSnapshot.self, from: data)

            self.projects = snapshot.projects
            self.reservedSlots = snapshot.reservedSlots
            self.processedKeys = snapshot.processedKeys

            // Reconcile non-terminal run records on load without prematurely converting paused/user-control states to interrupted
            let terminalStatuses: Set<String> = ["completed", "failed", "cancelled", "interrupted"]
            var reconciledCount = 0
            self.runs = snapshot.runs.map { run in
                var r = run
                let normalized = r.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if terminalStatuses.contains(normalized) {
                    // Existing terminal status preserved unchanged
                } else {
                    switch normalized {
                    case "paused":
                        r.status = "paused"
                        r.endedAt = nil
                    case "usercontrol":
                        r.status = "userControl"
                        r.endedAt = nil
                    case "needsuser":
                        r.status = "needsUser"
                        r.endedAt = nil
                    case "waiting":
                        r.status = "waiting"
                        r.endedAt = nil
                    case "running", "queued":
                        r.status = "paused"
                        r.endedAt = nil
                        if r.summary.isEmpty {
                            r.summary = "앱 재시작으로 멈춘 업무입니다. 계속하기를 눌러 이어서 진행할 수 있습니다."
                        }
                    default:
                        r.status = "interrupted"
                        if r.endedAt == nil {
                            r.endedAt = Date()
                        }
                        if r.summary.isEmpty {
                            r.summary = "앱 재시작으로 인해 이전 작업이 안전하게 중단되었습니다."
                        }
                    }
                }
                if r != run {
                    reconciledCount += 1
                }
                return r
            }

            self.loadFailed = false
            self.errorMessage = nil

            if reconciledCount > 0 {
                persist()
            }
        } catch {
            // Malformed or unreadable file: keep state empty, flag load failure, and NEVER clobber existing disk data
            self.loadFailed = true
            self.errorMessage = "saw-projects.json을 불러오지 못했습니다: \(error.localizedDescription)"
        }
    }

    @discardableResult
    private func persist() -> Bool {
        guard persistent else {
            errorMessage = nil
            return true
        }

        // Do not overwrite corrupt or failed load file to prevent data clobbering
        guard !loadFailed else {
            let msg = "기존 saw-projects.json 파일이 손상되었거나 읽기에 실패하여 데이터를 보호하기 위해 저장을 중단했습니다."
            self.errorMessage = msg
            return false
        }

        do {
            let parentDir = directory
            if !FileManager.default.fileExists(atPath: parentDir.path) {
                try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }

            let snapshot = PersistedSnapshot(
                projects: projects,
                runs: runs,
                reservedSlots: reservedSlots,
                processedKeys: processedKeys
            )

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(snapshot)

            try data.write(to: fileURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            self.errorMessage = nil
            return true
        } catch {
            self.errorMessage = "saw-projects.json 저장 실패: \(error.localizedDescription)"
            return false
        }
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let seconds = try? container.decode(Double.self) {
                if seconds > 10_000_000_000 {
                    return Date(timeIntervalSince1970: seconds / 1000.0)
                } else if seconds > 978_307_200 {
                    return Date(timeIntervalSince1970: seconds)
                } else {
                    return Date(timeIntervalSinceReferenceDate: seconds)
                }
            }
            if let str = try? container.decode(String.self) {
                if let d = ISO8601DateFormatter().date(from: str) {
                    return d
                }
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
                if let d = formatter.date(from: str) {
                    return d
                }
                formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
                if let d = formatter.date(from: str) {
                    return d
                }
            }
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Invalid date representation")
            )
        }
        return decoder
    }
}
