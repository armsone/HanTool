import Foundation
import Combine
import WebKit

// Common durable core for the assistant planner: exact conversation associations, a completion outbox,
// bounded atomic persistence and the adapter contract. Provider specific work (goal/context capture and the
// actual send into a page) lives in adapters that register here; this file performs no network, process or
// credential access. The caller supplies the store directory (appModel.config.storeDirectory).

// MARK: - Models

enum AssistantPlannerStatus: String, Codable {
    case active, prepared, sending, confirmed, uncertain, released

    /// Outbox entries in these states still owe a delivery decision.
    var isOpen: Bool { self == .prepared || self == .sending || self == .uncertain }
}

enum AssistantPlannerResumeIntent: String, Codable {
    case none
    case resumeOnLaunch
}

enum AssistantPlannerRunOutcome: String, Codable {
    case completed, failed, canceled
}

/// Exact identity of one planner request. Nothing here is normalized or guessed; equality is string equality.
struct AssistantPlannerIdentity: Codable, Hashable {
    var serviceID: String
    var profileID: String
    var conversationURL: String
    var stableID: String?
    var projectID: String
    var runID: String
    var requestID: String

    static let maxFieldLength = 256
    static let maxURLLength = 4096

    /// Returns nil unless every required field is present and within bounds (fields are never truncated) and the
    /// conversation URL is already in its canonical safe form.
    func validated() -> AssistantPlannerIdentity? {
        let required = [serviceID, profileID, projectID, runID, requestID]
        guard required.allSatisfy({ !$0.isEmpty && $0.count <= Self.maxFieldLength }) else { return nil }
        if let stableID, stableID.isEmpty || stableID.count > Self.maxFieldLength { return nil }
        guard !conversationURL.isEmpty, conversationURL.count <= Self.maxURLLength,
              AssistantPlannerURL.safe(conversationURL, hasStableID: stableID != nil) == conversationURL else { return nil }
        return self
    }
}

/// Host-scope URL check for stored conversation locations: https only, a real host, no user info, no credential
/// parameters (the URL is rejected as a whole, never rewritten except that the fragment is dropped), and a path
/// that names one conversation instead of a service landing page.
enum AssistantPlannerURL {
    private static let blockedParameters: Set<String> = [
        "code", "token", "access_token", "refresh_token", "id_token", "auth", "authorization", "password", "passwd",
        "secret", "session", "session_token", "sessionid", "signature", "sig", "key", "api_key", "state", "nonce",
        "samlresponse", "relaystate"
    ]

    /// Canonical form (fragment removed) or nil when the URL is not a safe, conversation-specific https location.
    /// `hasStableID` is true only when the page itself exposed a genuine stable conversation ID for this URL; that
    /// proof makes a root-style address (for example Hana's `/alfred`) a specific conversation.
    static func safe(_ raw: String, hasStableID: Bool = false) -> String? {
        guard raw.count <= AssistantPlannerIdentity.maxURLLength, var components = URLComponents(string: raw),
              components.scheme?.lowercased() == "https", let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil else { return nil }
        if (components.queryItems ?? []).contains(where: { blockedParameters.contains($0.name.lowercased()) }) { return nil }
        components.fragment = nil
        guard let text = components.string, hasStableID || namesConversation(components.path) else { return nil }
        return text
    }

    /// A conversation path has a segment that looks like an identifier (8+ characters with a digit), so a landing page
    /// such as "/" or "/chat" is never treated as one specific thread.
    static func namesConversation(_ path: String) -> Bool {
        path.split(separator: "/").contains { $0.count >= 8 && $0.contains(where: \.isNumber) }
    }

    /// Exact scheme://host[:port] of a configured service address, or nil.
    static func origin(of raw: String) -> String? {
        guard let components = URLComponents(string: raw), components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(), !host.isEmpty, components.user == nil, components.password == nil
        else { return nil }
        return "https://" + host + (components.port.map { ":\($0)" } ?? "")
    }
}

struct AssistantPlannerAssociation: Codable, Identifiable, Equatable {
    var id: String
    var identity: AssistantPlannerIdentity
    var status: AssistantPlannerStatus          // active | released
    var resumeIntent: AssistantPlannerResumeIntent
    var userPaused: Bool                        // explicit user pause; never overridden by automatic resume
    var provenRunning: Bool                     // last persisted state was positively observed running
    var triggerText: String?
    var createdAt: Date
    var updatedAt: Date
}

struct AssistantPlannerOutboxEntry: Codable, Identifiable, Equatable {
    var id: String
    var associationID: String
    var identity: AssistantPlannerIdentity
    var outcome: AssistantPlannerRunOutcome
    var payload: String
    var dedupeKey: String
    var status: AssistantPlannerStatus          // prepared | sending | confirmed | uncertain | released
    var attempts: Int
    var lastError: String?
    var createdAt: Date
    var updatedAt: Date
}

struct AssistantPlannerSnapshot: Codable {
    var version: Int
    var associations: [AssistantPlannerAssociation]
    var outbox: [AssistantPlannerOutboxEntry]
}

// MARK: - Trigger

/// Anchored control trigger. The whole (trimmed, bounded) message must match; nothing is searched inside prose.
/// The default pattern is the original Hana delegation sentence (identical to `HanaPanelHost.delegationPattern`).
struct AssistantPlannerTrigger {
    static let defaultPattern = #"^(?:(?:이건|이거|이걸)\s*)?(?:플래너|플레너)(?:에게|한테)?\s*(?:맡겨\s?줘|맡겨\s?주세요|넘겨\s?줘)[\s.!~]*$"#
    static let maxInputLength = 400
    static let standard = AssistantPlannerTrigger(pattern: defaultPattern)!

    let pattern: String
    private let regex: NSRegularExpression

    init?(pattern: String) {
        guard pattern.hasPrefix("^"), pattern.hasSuffix("$"),
              let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        self.pattern = pattern
        self.regex = regex
    }

    func matches(_ text: String) -> Bool {
        let normalized = text.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.count <= Self.maxInputLength else { return false }
        let range = NSRange(normalized.startIndex..., in: normalized)
        guard let match = regex.firstMatch(in: normalized, options: [.anchored], range: range) else { return false }
        return match.range == range
    }
}

// MARK: - Persistence

/// Bounded JSON store: 0700 directory, temp file written 0600 + fsync + rename(2), corrupt files quarantined.
struct AssistantPlannerStore {
    static let fileName = "assistant-planner-state.json"
    static let schemaVersion = 1
    static let maxFileBytes = 4 * 1024 * 1024
    static let maxAssociations = 64
    static let maxOutbox = 128
    static let maxPayloadLength = 16_000
    static let maxTriggerTextLength = 400
    static let maxErrorLength = 300

    let directory: URL
    var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    init(directory: URL) { self.directory = directory }

    struct LoadResult {
        var snapshot: AssistantPlannerSnapshot
        var warning: String?
    }

    static var empty: AssistantPlannerSnapshot {
        AssistantPlannerSnapshot(version: schemaVersion, associations: [], outbox: [])
    }

    func load() -> LoadResult {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else { return LoadResult(snapshot: Self.empty, warning: nil) }
        do {
            let attributes = try fm.attributesOfItem(atPath: fileURL.path)
            let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
            guard size <= Self.maxFileBytes else { throw CocoaError(.fileReadTooLarge) }
            if let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue, mode & 0o077 != 0 {
                try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            }
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var snapshot = try decoder.decode(AssistantPlannerSnapshot.self, from: data)
            guard snapshot.version == Self.schemaVersion else { throw CocoaError(.fileReadCorruptFile) }
            snapshot.associations = Array(snapshot.associations.suffix(Self.maxAssociations * 2))
            snapshot.outbox = Array(snapshot.outbox.suffix(Self.maxOutbox * 2))
            return LoadResult(snapshot: snapshot, warning: nil)
        } catch {
            let stamp = Int(Date().timeIntervalSince1970)
            let aside = directory.appendingPathComponent("\(Self.fileName).corrupt-\(stamp)")
            try? fm.moveItem(at: fileURL, to: aside)
            return LoadResult(snapshot: Self.empty, warning: "planner state unreadable and set aside: \(error.localizedDescription)")
        }
    }

    func save(_ snapshot: AssistantPlannerSnapshot) throws {
        let fm = FileManager.default
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        guard data.count <= Self.maxFileBytes else { throw CocoaError(.fileWriteOutOfSpace) }

        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temp = directory.appendingPathComponent(".\(Self.fileName).\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: temp.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let handle = try FileHandle(forWritingTo: temp)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            guard rename(temp.path, fileURL.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
    }
}

// MARK: - Adapter contract

/// Native host (page/webview) bound to one conversation. Identity is read live through closures so the
/// coordinator never caches a stale URL.
@MainActor
final class AssistantPlannerHostBinding {
    let hostID: String
    let serviceID: String
    let profileID: String
    weak var webView: WKWebView?
    var conversationURL: () -> String?
    var stableID: () -> String?

    init(hostID: String,
         serviceID: String,
         profileID: String,
         webView: WKWebView? = nil,
         conversationURL: @escaping () -> String?,
         stableID: @escaping () -> String? = { nil }) {
        self.hostID = hostID
        self.serviceID = serviceID
        self.profileID = profileID
        self.webView = webView
        self.conversationURL = conversationURL
        self.stableID = stableID
    }

    func identity(projectID: String, runID: String, requestID: String) -> AssistantPlannerIdentity? {
        guard let url = conversationURL() else { return nil }
        return AssistantPlannerIdentity(serviceID: serviceID, profileID: profileID, conversationURL: url,
                                        stableID: stableID(), projectID: projectID, runID: runID,
                                        requestID: requestID).validated()
    }

    /// Exact match: same service, profile, conversation URL and stable ID (including both being absent).
    func matches(_ identity: AssistantPlannerIdentity) -> Bool {
        serviceID == identity.serviceID && profileID == identity.profileID
            && conversationURL() == identity.conversationURL && stableID() == identity.stableID
    }
}

enum AssistantPlannerSendResult {
    case delivered              // the page demonstrably accepted and shows the message
    case notSent(String)        // nothing was submitted; safe to retry
    case uncertain(String)      // submitted or possibly submitted; must be reconciled, never blindly resent
}

enum AssistantPlannerDeliveryProof {
    case delivered, absent, unknown
}

@MainActor
protocol AssistantPlannerAdapter: AnyObject {
    var serviceID: String { get }
    func send(_ entry: AssistantPlannerOutboxEntry, via host: AssistantPlannerHostBinding) async -> AssistantPlannerSendResult
    func verifyDelivery(of entry: AssistantPlannerOutboxEntry, via host: AssistantPlannerHostBinding) async -> AssistantPlannerDeliveryProof
}

/// Closure based adapter for callers that do not want a dedicated type.
@MainActor
final class AssistantPlannerClosureAdapter: AssistantPlannerAdapter {
    let serviceID: String
    private let sendHandler: (AssistantPlannerOutboxEntry, AssistantPlannerHostBinding) async -> AssistantPlannerSendResult
    private let verifyHandler: (AssistantPlannerOutboxEntry, AssistantPlannerHostBinding) async -> AssistantPlannerDeliveryProof

    init(serviceID: String,
         send: @escaping (AssistantPlannerOutboxEntry, AssistantPlannerHostBinding) async -> AssistantPlannerSendResult,
         verify: @escaping (AssistantPlannerOutboxEntry, AssistantPlannerHostBinding) async -> AssistantPlannerDeliveryProof = { _, _ in .unknown }) {
        self.serviceID = serviceID
        self.sendHandler = send
        self.verifyHandler = verify
    }

    func send(_ entry: AssistantPlannerOutboxEntry, via host: AssistantPlannerHostBinding) async -> AssistantPlannerSendResult {
        await sendHandler(entry, host)
    }

    func verifyDelivery(of entry: AssistantPlannerOutboxEntry, via host: AssistantPlannerHostBinding) async -> AssistantPlannerDeliveryProof {
        await verifyHandler(entry, host)
    }
}

// MARK: - Coordinator

@MainActor
final class AssistantPlannerCoordinator: ObservableObject {
    @Published private(set) var associations: [AssistantPlannerAssociation] = []
    @Published private(set) var outbox: [AssistantPlannerOutboxEntry] = []
    @Published private(set) var lastPersistError: String?

    let trigger: AssistantPlannerTrigger
    /// Builds the completion message. Return nil to use the built-in text.
    var composeCompletion: ((AssistantPlannerAssociation, AssistantPlannerRunOutcome, String) -> String?)?

    private let store: AssistantPlannerStore
    private let now: () -> Date
    private var hosts: [String: AssistantPlannerHostBinding] = [:]
    private var adapters: [String: AssistantPlannerAdapter] = [:]
    private var isFlushing = false

    init(storeDirectory: URL,
         trigger: AssistantPlannerTrigger = .standard,
         now: @escaping () -> Date = Date.init) {
        self.store = AssistantPlannerStore(directory: storeDirectory)
        self.trigger = trigger
        self.now = now
        let loaded = store.load()
        associations = loaded.snapshot.associations
        outbox = loaded.snapshot.outbox
        lastPersistError = loaded.warning
        recoverAfterLaunch()
    }

    // MARK: Registration

    func attach(host: AssistantPlannerHostBinding) { hosts[host.hostID] = host }
    func detach(hostID: String) { hosts[hostID] = nil }
    func host(for hostID: String) -> AssistantPlannerHostBinding? { hosts[hostID] }
    func register(adapter: AssistantPlannerAdapter) { adapters[adapter.serviceID] = adapter }
    func unregisterAdapter(serviceID: String) { adapters[serviceID] = nil }
    func adapter(for serviceID: String) -> AssistantPlannerAdapter? { adapters[serviceID] }

    // MARK: Associations

    func isTrigger(_ text: String) -> Bool { trigger.matches(text) }

    /// Accepts a user message: when it is exactly the control trigger, records the association with the host's
    /// current exact conversation identity. Returns nil for ordinary messages or an unusable identity.
    @discardableResult
    func acceptTrigger(text: String, hostID: String, projectID: String, runID: String, requestID: String) -> AssistantPlannerAssociation? {
        guard trigger.matches(text), let host = hosts[hostID],
              let identity = host.identity(projectID: projectID, runID: runID, requestID: requestID) else { return nil }
        return recordAssociation(identity, triggerText: text)
    }

    /// Idempotent per exact identity: an existing active association is returned unchanged.
    @discardableResult
    func recordAssociation(_ identity: AssistantPlannerIdentity, triggerText: String? = nil) -> AssistantPlannerAssociation? {
        guard let identity = identity.validated() else { return nil }
        if let existing = associations.first(where: { $0.identity == identity && $0.status == .active }) { return existing }
        guard associations.filter({ $0.status == .active }).count < AssistantPlannerStore.maxAssociations else { return nil }
        let stamp = now()
        let association = AssistantPlannerAssociation(
            id: UUID().uuidString, identity: identity, status: .active, resumeIntent: .none,
            userPaused: false, provenRunning: false,
            triggerText: triggerText.map { String($0.prefix(AssistantPlannerStore.maxTriggerTextLength)) },
            createdAt: stamp, updatedAt: stamp)
        associations.append(association)
        guard commit() else {
            associations.removeAll { $0.id == association.id }
            return nil
        }
        return association
    }

    /// Records the real conversation location once the page has one (for example a new chat getting its URL).
    @discardableResult
    func rebind(associationID: String, conversationURL: String, stableID: String?) -> Bool {
        updateAssociation(associationID) { association in
            var identity = association.identity
            identity.conversationURL = conversationURL
            identity.stableID = stableID
            guard identity.validated() != nil else { return false }
            association.identity = identity
            return true
        }
    }

    func activeAssociations(projectID: String? = nil, runID: String? = nil) -> [AssistantPlannerAssociation] {
        associations.filter {
            $0.status == .active && (projectID == nil || $0.identity.projectID == projectID)
                && (runID == nil || $0.identity.runID == runID)
        }
    }

    @discardableResult
    func release(associationID: String) -> Bool {
        let changed = updateAssociation(associationID) { association in
            guard association.status != .released else { return false }
            association.status = .released
            association.resumeIntent = .none
            association.provenRunning = false
            return true
        }
        if changed {
            for entry in outbox where entry.associationID == associationID && entry.status == .prepared {
                _ = updateEntry(entry.id) { $0.status = .released; $0.lastError = "association released" }
            }
        }
        return changed
    }

    // MARK: Run state and resume intent

    /// `provenRunning` must only be true when the run was positively observed running; nil leaves it unchanged.
    /// `userPaused` records an explicit user pause (true) or an explicit user resume (false).
    func updateRunState(projectID: String, runID: String, provenRunning: Bool? = nil, userPaused: Bool? = nil) {
        var changed = false
        for index in associations.indices where associations[index].status == .active
            && associations[index].identity.projectID == projectID && associations[index].identity.runID == runID {
            var rowChanged = false
            if let provenRunning, associations[index].provenRunning != provenRunning {
                associations[index].provenRunning = provenRunning
                rowChanged = true
            }
            if let userPaused, associations[index].userPaused != userPaused {
                associations[index].userPaused = userPaused
                if userPaused { associations[index].resumeIntent = .none }
                rowChanged = true
            }
            if rowChanged {
                associations[index].updatedAt = now()
                changed = true
            }
        }
        if changed { _ = commit() }
    }

    /// Clears the running proof and the resume intent of a run (terminal state, explicit stop/pause/manual control).
    /// `userPaused` keeps its own meaning and is not touched here.
    func clearRunIntent(projectID: String, runID: String) {
        var changed = false
        for index in associations.indices where associations[index].identity.projectID == projectID
            && associations[index].identity.runID == runID
            && (associations[index].provenRunning || associations[index].resumeIntent != .none) {
            associations[index].provenRunning = false
            associations[index].resumeIntent = .none
            associations[index].updatedAt = now()
            changed = true
        }
        if changed { _ = commit() }
    }

    /// True when any association (active or released) already carries this request ID.
    func hasRequest(_ requestID: String) -> Bool {
        associations.contains { $0.identity.requestID == requestID }
    }

    /// Call before anything rewrites run state at shutdown. Only upgrades intent: proven running and not paused
    /// by the user becomes resumeOnLaunch; an existing intent is never downgraded by a later rewrite.
    func beginShutdown() {
        var changed = false
        for index in associations.indices where associations[index].status == .active {
            if associations[index].provenRunning && !associations[index].userPaused
                && associations[index].resumeIntent != .resumeOnLaunch {
                associations[index].resumeIntent = .resumeOnLaunch
                associations[index].updatedAt = now()
                changed = true
            }
        }
        if changed { _ = commit() }
    }

    func resumeCandidates() -> [AssistantPlannerAssociation] {
        associations.filter { $0.status == .active && $0.resumeIntent == .resumeOnLaunch && !$0.userPaused }
    }

    @discardableResult
    func acknowledgeResume(associationID: String) -> Bool {
        updateAssociation(associationID) { association in
            guard association.resumeIntent != .none else { return false }
            association.resumeIntent = .none
            return true
        }
    }

    // MARK: Completion outbox

    /// Receipt marker carried by the submitted message; the only proof of delivery is finding it in the origin
    /// conversation's own user rows.
    static func marker(for entryID: String) -> String {
        "HTT-" + String(entryID.replacingOccurrences(of: "-", with: "").lowercased().prefix(10))
    }

    /// Enqueues one completion message per active association of the run. Idempotent per association/outcome.
    /// Nothing is enqueued when `composeCompletion` is unset or returns nil: a notice is only ever built from
    /// validated run data, never from a generic fallback sentence.
    @discardableResult
    func runFinished(projectID: String, runID: String, outcome: AssistantPlannerRunOutcome, summary: String) -> [AssistantPlannerOutboxEntry] {
        var created: [AssistantPlannerOutboxEntry] = []
        // A finished run must never resume after a restart, even while its completion notice is still pending.
        clearRunIntent(projectID: projectID, runID: runID)
        for association in activeAssociations(projectID: projectID, runID: runID) {
            let key = "\(association.id)|\(association.identity.requestID)|\(outcome.rawValue)"
            if outbox.contains(where: { $0.dedupeKey == key && $0.status != .released }) { continue }
            guard outbox.filter({ $0.status.isOpen }).count < AssistantPlannerStore.maxOutbox else { break }
            guard let text = composeCompletion?(association, outcome, summary) else { continue }
            let stamp = now()
            let entryID = UUID().uuidString
            let footer = "\n\n[수신 확인 \(Self.marker(for: entryID))]"
            let body = String(text.prefix(AssistantPlannerStore.maxPayloadLength - footer.count))
            let entry = AssistantPlannerOutboxEntry(
                id: entryID, associationID: association.id, identity: association.identity,
                outcome: outcome, payload: body + footer, dedupeKey: key,
                status: .prepared, attempts: 0, lastError: nil, createdAt: stamp, updatedAt: stamp)
            outbox.append(entry)
            created.append(entry)
        }
        if !created.isEmpty, !commit() {
            let ids = Set(created.map(\.id))
            outbox.removeAll { ids.contains($0.id) }
            return []
        }
        return created
    }

    /// Sends prepared entries through their adapter. The `sending` state is persisted before the adapter runs, so
    /// a crash mid-send is recovered as `uncertain` rather than resent.
    func flushOutbox() async {
        guard !isFlushing else { return }
        isFlushing = true
        defer { isFlushing = false }
        for id in outbox.filter({ $0.status == .prepared }).map(\.id) {
            guard let entry = outbox.first(where: { $0.id == id }), entry.status == .prepared else { continue }
            guard let association = associations.first(where: { $0.id == entry.associationID }), association.status == .active else {
                _ = updateEntry(id) { $0.status = .released; $0.lastError = "association no longer active" }
                continue
            }
            guard let adapter = adapters[entry.identity.serviceID] else {
                noteBlocked(id, "이 서비스의 대화창이 아직 연결되지 않아 완료 알림을 보류했습니다.")
                continue
            }
            guard let host = hosts.values.first(where: { $0.matches(entry.identity) }) else {
                noteBlocked(id, "원래 대화가 열려 있지 않아 완료 알림을 보류했습니다. 같은 서비스에서 원래 대화를 열면 한 번 보냅니다.")
                continue
            }
            guard updateEntry(id, { $0.status = .sending; $0.attempts += 1; $0.lastError = nil }) else { continue }
            guard let sending = outbox.first(where: { $0.id == id }) else { continue }
            let result = await adapter.send(sending, via: host)
            switch result {
            case .delivered:
                finishDelivered(id)
            case .notSent(let reason):
                // Nothing was submitted, so the entry simply waits for the next lifecycle event (no attempt cap).
                _ = updateEntry(id) {
                    $0.status = .prepared
                    $0.lastError = Self.bounded(reason)
                }
            case .uncertain(let reason):
                _ = updateEntry(id) { $0.status = .uncertain; $0.lastError = Self.bounded(reason) }
            }
        }
    }

    /// Resolves uncertain entries using adapter proof only: delivered -> confirmed, absent -> prepared again,
    /// unknown -> unchanged.
    func reconcileOutbox() async {
        for id in outbox.filter({ $0.status == .uncertain }).map(\.id) {
            guard let entry = outbox.first(where: { $0.id == id }), entry.status == .uncertain,
                  let adapter = adapters[entry.identity.serviceID],
                  let host = hosts.values.first(where: { $0.matches(entry.identity) }) else { continue }
            switch await adapter.verifyDelivery(of: entry, via: host) {
            case .delivered: finishDelivered(id)
            case .absent: _ = updateEntry(id) { $0.status = .prepared; $0.lastError = "delivery not found on reconcile" }
            case .unknown: break
            }
        }
    }

    /// Manual resolution for an entry the user decided to drop.
    @discardableResult
    func release(outboxID: String) -> Bool {
        guard let entry = outbox.first(where: { $0.id == outboxID }), entry.status.isOpen else { return false }
        let changed = updateEntry(outboxID) { $0.status = .released; $0.lastError = "released by user" }
        if changed { releaseAssociationIfSettled(entry.associationID) }
        return changed
    }

    // MARK: Internals

    private static func bounded(_ text: String) -> String { String(text.prefix(AssistantPlannerStore.maxErrorLength)) }

    private func recoverAfterLaunch() {
        var changed = false
        for index in outbox.indices where outbox[index].status == .sending {
            outbox[index].status = .uncertain
            outbox[index].lastError = "app stopped while sending"
            outbox[index].updatedAt = now()
            changed = true
        }
        // A run that was positively running when the app died without a clean shutdown should be resumed.
        for index in associations.indices where associations[index].status == .active && associations[index].provenRunning {
            if !associations[index].userPaused { associations[index].resumeIntent = .resumeOnLaunch }
            associations[index].provenRunning = false
            associations[index].updatedAt = now()
            changed = true
        }
        if changed { _ = commit() }
    }

    private func finishDelivered(_ entryID: String) {
        guard let associationID = outbox.first(where: { $0.id == entryID })?.associationID else { return }
        _ = updateEntry(entryID) { $0.status = .confirmed; $0.lastError = nil }
        releaseAssociationIfSettled(associationID)
    }

    private func releaseAssociationIfSettled(_ associationID: String) {
        guard !outbox.contains(where: { $0.associationID == associationID && $0.status.isOpen }) else { return }
        _ = updateAssociation(associationID) { association in
            guard association.status == .active else { return false }
            association.status = .released
            association.resumeIntent = .none
            association.provenRunning = false
            return true
        }
    }

    private func noteBlocked(_ entryID: String, _ reason: String) {
        guard outbox.first(where: { $0.id == entryID })?.lastError != reason else { return }
        _ = updateEntry(entryID) { $0.lastError = reason }
    }

    @discardableResult
    private func updateAssociation(_ id: String, _ body: (inout AssistantPlannerAssociation) -> Bool) -> Bool {
        guard let index = associations.firstIndex(where: { $0.id == id }) else { return false }
        let before = associations[index]
        var copy = before
        guard body(&copy) else { return false }
        copy.updatedAt = now()
        associations[index] = copy
        if commit() { return true }
        associations[index] = before
        return false
    }

    /// Applies a change and persists it; reverts the in-memory change when persistence fails.
    @discardableResult
    private func updateEntry(_ id: String, _ body: (inout AssistantPlannerOutboxEntry) -> Void) -> Bool {
        guard let index = outbox.firstIndex(where: { $0.id == id }) else { return false }
        let before = outbox[index]
        var copy = before
        body(&copy)
        copy.updatedAt = now()
        outbox[index] = copy
        if commit() { return true }
        outbox[index] = before
        return false
    }

    /// Prunes settled history beyond the bounds and writes the snapshot atomically.
    private func commit() -> Bool {
        prune()
        do {
            try store.save(AssistantPlannerSnapshot(version: AssistantPlannerStore.schemaVersion,
                                                    associations: associations, outbox: outbox))
            lastPersistError = nil
            return true
        } catch {
            lastPersistError = "planner state not saved: \(error.localizedDescription)"
            return false
        }
    }

    private func prune() {
        let openAssociationIDs = Set(outbox.filter { $0.status.isOpen }.map(\.associationID))
        func trim<T>(_ items: inout [T], limit: Int, isSettled: (T) -> Bool) {
            var excess = items.count - limit
            guard excess > 0 else { return }
            items = items.filter { item in
                if excess > 0, isSettled(item) { excess -= 1; return false }
                return true
            }
        }
        trim(&outbox, limit: AssistantPlannerStore.maxOutbox) { !$0.status.isOpen }
        trim(&associations, limit: AssistantPlannerStore.maxAssociations) {
            $0.status == .released && !openAssociationIDs.contains($0.id)
        }
    }
}
