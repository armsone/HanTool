//
//  SAWTeamRuntime.swift
//  SAW
//
//  Created for SAW multi-account owned-browser worker action loops and coordinator runtime.
//

import Foundation
import WebKit
import Combine

// MARK: - Host Surface & Connection State Models

struct SAWTeamAISurface: Identifiable {
    let id: UUID
    let webView: WKWebView
}

enum SAWTeamConnectionState: String, CaseIterable, Codable {
    case unknown
    case checking
    case authenticated
    case loginRequired
    case failed

    var localizedLabel: String {
        switch self {
        case .unknown:
            return "미확인"
        case .checking:
            return "확인 중"
        case .authenticated:
            return "응답 확인됨"
        case .loginRequired:
            return "로그인 필요"
        case .failed:
            return "실패"
        }
    }
}

// MARK: - Team Runtime

@MainActor
final class SAWTeamRuntime: ObservableObject {

    // MARK: - Public Constants

    static let sharedLoginSentinelUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    // MARK: - Published Properties

    @Published var activeLoginWorkerID: UUID? = nil
    @Published private(set) var hostedAISurfaces: [SAWTeamAISurface] = []
    @Published private(set) var connectionStates: [UUID: SAWTeamConnectionState] = [:]

    private var lastRecordedPhase: [UUID: String] = [:]

    private func humanMemberLabel(worker: SAWTeamWorker) -> String {
        if let name = worker.displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        return session.workspace.appModel.aiServices.allServices.first(where: { $0.id == worker.providerID })?.name ?? "팀원"
    }

    private func sanitizeChatText(_ text: String) -> String {
        var cleaned = text
        if let regex = try? NSRegularExpression(pattern: "https?://\\S+", options: []) {
            let fullRange = NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned)
            let matches = regex.matches(in: cleaned, options: [], range: fullRange).reversed()
            for match in matches {
                guard let range = Range(match.range, in: cleaned) else { continue }
                let urlString = String(cleaned[range])
                let replacement: String
                if let host = URL(string: urlString)?.host, !host.isEmpty {
                    replacement = "\(host) 웹페이지"
                } else {
                    replacement = "웹페이지"
                }
                cleaned.replaceSubrange(range, with: replacement)
            }
        }
        cleaned = cleaned.replacingOccurrences(of: "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}", with: "", options: .regularExpression)
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func recordTeamPhase(
        worker: SAWTeamWorker,
        assignmentID: UUID,
        requestID: UUID,
        epoch: UInt64,
        runID: UUID,
        text: String
    ) {
        guard session.teamGeneration == epoch,
              session.teamRunID == runID,
              session.runStatus == "running",
              let project = session.project,
              let team = project.team,
              team.workers.contains(where: { $0 == worker }),
              project.teamAssignments.contains(where: {
                  $0.id == assignmentID &&
                  $0.requestID == requestID &&
                  $0.runID == runID &&
                  $0.generation == epoch &&
                  $0.status == .running
              }) else {
            return
        }

        let cleaned = sanitizeChatText(text)
        guard !cleaned.isEmpty else { return }

        if lastRecordedPhase[assignmentID] == cleaned {
            return
        }
        lastRecordedPhase[assignmentID] = cleaned

        session.workspace.store.appendChatMessage(
            projectID: session.projectID,
            message: SAWChatMessage(
                sender: "assistant",
                text: "[\(humanMemberLabel(worker: worker))] \(cleaned)",
                status: "waiting",
                runID: runID
            )
        )
    }
    @Published var busyTabIDs: Set<UUID> = []
    @Published var busyWorkerIDs: Set<UUID> = []

    // MARK: - Internal Session & State Properties

    unowned let session: SAWProjectSession

    var hasPendingAssignments: Bool {
        guard let runID = session.teamRunID,
              let assignments = session.project?.teamAssignments else {
            return false
        }
        let epoch = session.teamGeneration
        return assignments.contains { assignment in
            assignment.runID == runID &&
            assignment.generation == epoch &&
            (assignment.status == .queued || assignment.status == .running)
        }
    }

    // MARK: - Private State & Caches

    private var activeTasks: [UUID: Task<Void, Never>] = [:]
    private var runningAssignmentIDs: Set<UUID> = []
    private var transports: [UUID: WebPageAgentTransport] = [:]
    private var hanaAdapters: [UUID: SAWHanaTeamAdapter] = [:]
    private var cliTransports: [UUID: SAWCLITransport] = [:]

    private static let cliSupportedProviderIDs: Set<String> = ["chatgpt", "claude", "gemini"]

    /// Actual connection of the current run; only consulted for automatically managed team configs.
    private var currentAutomaticTeamUsesCLI = false
    /// nil: no automatic CLI preparation attempted yet; otherwise the discovered CLI candidate count.
    private var automaticCLICandidateCount: Int? = nil

    private var isForcedCLI: Bool {
        if session.project?.connectionMode == "web" { return false }
        if session.project?.connectionMode == "cli" { return true }
        return session.project?.team?.isAutomatic == true && currentAutomaticTeamUsesCLI
    }

    /// Automatic configs run CLI-backed members only on CLI and profile-backed members only on WEB.
    private func automaticModeAllows(_ worker: SAWTeamWorker) -> Bool {
        guard session.project?.team?.isAutomatic == true else { return true }
        return (worker.cliAccountID != nil) == isForcedCLI
    }

    /// Records the actual local connection for this run. Active automatic workers are cancelled before the flag changes.
    func setAutomaticTeamConnection(usingCLI: Bool) {
        guard currentAutomaticTeamUsesCLI != usingCLI else { return }
        if session.project?.team?.isAutomatic == true, !activeTasks.isEmpty {
            cancelAllWorkers()
        }
        currentAutomaticTeamUsesCLI = usingCLI
    }

    /// Prepares a first-use automatic team only when the project has no team (nil). Explicit and empty teams are never touched.
    func prepareAutomaticTeam(usingCLI: Bool, connectedWebService: AIService? = nil) {
        setAutomaticTeamConnection(usingCLI: usingCLI)
        guard let project = session.project, project.team == nil else { return }

        var workers: [SAWTeamWorker] = []
        if usingCLI {
            let services = session.workspace.appModel.aiServices
            var providerWorkers: [[SAWTeamWorker]] = []
            for providerID in ["chatgpt", "claude", "gemini"] {
                guard services.enabledServiceIDs.contains(providerID),
                      let service = services.allServices.first(where: { $0.id.caseInsensitiveCompare(providerID) == .orderedSame }) else {
                    continue
                }
                providerWorkers.append(SAWCLIAccounts.discover(providerID: providerID).map { acc in
                    SAWTeamWorker(
                        providerID: service.id,
                        accountID: "cli:\(acc.id)",
                        websiteDataStoreID: Self.sharedLoginSentinelUUID,
                        displayName: acc.label,
                        capabilities: [.read, .navigate, .search],
                        cliAccountID: acc.id
                    )
                })
            }
            // Round-robin across providers: each provider's nth account before any (n+1)th.
            for index in 0..<(providerWorkers.map(\.count).max() ?? 0) {
                for list in providerWorkers where index < list.count {
                    workers.append(list[index])
                }
            }
            automaticCLICandidateCount = workers.count
        } else if let service = connectedWebService,
                  session.workspace.appModel.aiServices.enabledServiceIDs.contains(service.id) {
            workers.append(SAWTeamWorker(
                providerID: service.id,
                accountID: "automatic",
                websiteDataStoreID: Self.sharedLoginSentinelUUID,
                displayName: service.name,
                capabilities: [.read, .navigate, .search],
                cliAccountID: nil
            ))
        }

        // No candidates: keep team nil so a later real connection can still prepare it.
        guard !workers.isEmpty else { return }
        let config = SAWTeamConfiguration(workers: workers, isAutomatic: true)
        session.workspace.mutateProject(id: session.projectID) { proj in
            if proj.team == nil { proj.team = config }
        }
    }

    private func supportsCLI(_ worker: SAWTeamWorker) -> Bool {
        Self.cliSupportedProviderIDs.contains(worker.providerID.lowercased())
    }

    private func isServiceEnabledForCLI(_ worker: SAWTeamWorker) -> Bool {
        session.workspace.appModel.aiServices.enabledServiceIDs.contains(worker.providerID)
    }

    private struct ExternalSearchResult {
        let query: String
        let summary: String
        let timestamp: Date
    }

    private var externalSearchResults: [ExternalSearchResult] = []

    // MARK: - Initialization

    init(session: SAWProjectSession) {
        self.session = session
    }

    // MARK: - DataStore Resolution

    func dataStore(for worker: SAWTeamWorker, service: AIService) -> WKWebsiteDataStore {
        if worker.websiteDataStoreID == Self.sharedLoginSentinelUUID {
            return session.workspace.appModel.store(for: service)
        } else {
            let store = WKWebsiteDataStore(forIdentifier: worker.websiteDataStoreID)
            store.proxyConfigurations = session.workspace.appModel.store(for: service).proxyConfigurations
            return store
        }
    }

    // MARK: - Login Presentation

    func prepareLogin(worker: SAWTeamWorker) -> WKWebView? {
        guard !busyWorkerIDs.contains(worker.id), !isForcedCLI else {
            return nil
        }

        let isHana = worker.providerID.lowercased().contains("hana")
        guard let service = resolveService(for: worker) else {
            connectionStates[worker.id] = .failed
            return nil
        }

        activeLoginWorkerID = worker.id
        let store = dataStore(for: worker, service: service)

        let webView: WKWebView?
        if isHana {
            let adapter = getHanaAdapter(for: worker, service: service)
            adapter.configurePlanner(dataStore: store)
            webView = adapter.plannerWebView
        } else {
            let transport = getTransport(for: worker, service: service)
            transport.configurePlanner(service: service, dataStore: store)
            webView = transport.plannerWebView
        }

        updateHostedSurfaces()
        return webView
    }

    func closeLoginPresentation() {
        if let closingID = activeLoginWorkerID {
            connectionStates[closingID] = .unknown
        }
        activeLoginWorkerID = nil
        updateHostedSurfaces()
    }

    // MARK: - External Search Recording

    func recordExternalSearchResult(query: String, summary: String) {
        let boundedSummary = String(summary.prefix(2000))
        externalSearchResults.append(ExternalSearchResult(query: query, summary: boundedSummary, timestamp: Date()))
        if externalSearchResults.count > 10 {
            externalSearchResults.removeFirst(externalSearchResults.count - 10)
        }
    }

    // MARK: - Dispatch & Queue

    func dispatch(tasks: [SAWTeamTaskProposal], goal: String) async {
        guard session.runStatus == "running" else { return }
        guard let runID = session.teamRunID else { return }
        guard let currentConfig = session.project?.team, !currentConfig.workers.isEmpty else { return }

        let validProposals = Array(tasks.prefix(8))
        let allowedCapabilities: Set<SAWTeamCapability> = [.read, .navigate, .search]

        for proposal in validProposals {
            guard let currentProject = session.project,
                  let teamConfig = currentProject.team,
                  !teamConfig.workers.isEmpty else {
                break
            }

            let currentAssignments = currentProject.teamAssignments
            let currentEpoch = session.teamGeneration

            let trimmedGoal = proposal.goal.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedGoal.isEmpty, trimmedGoal.count <= 4000 else { continue }

            var safeURLString: String? = nil
            if let rawURL = proposal.url?.trimmingCharacters(in: .whitespacesAndNewlines), !rawURL.isEmpty {
                if let parsed = URL(string: rawURL),
                   let scheme = parsed.scheme?.lowercased(),
                   (scheme == "http" || scheme == "https"),
                   parsed.host != nil {
                    safeURLString = rawURL
                }
            }

            let fullGoal: String
            if let safeURLString = safeURLString {
                fullGoal = "\(trimmedGoal)\nURL: \(safeURLString)"
            } else {
                fullGoal = trimmedGoal
            }

            let isDuplicate = currentAssignments.contains { existing in
                existing.runID == runID &&
                existing.generation == currentEpoch &&
                existing.goal == fullGoal &&
                (existing.status == .queued || existing.status == .running || existing.status == .completed)
            }
            if isDuplicate { continue }

            let forcedCLI = isForcedCLI
            let eligibleWorkers = teamConfig.workers.filter { worker in
                let intersection = Set(worker.capabilities).intersection(allowedCapabilities)
                guard !intersection.isEmpty else { return false }
                guard automaticModeAllows(worker) else { return false }
                if forcedCLI {
                    // CLI 모드: 웹 로그인 상태와 무관하게 CLI 지원 제공자만 위임 대상
                    return supportsCLI(worker) && resolveService(for: worker) != nil && isServiceEnabledForCLI(worker)
                }
                if connectionStates[worker.id] == .loginRequired {
                    return false
                }
                return true
            }

            guard !eligibleWorkers.isEmpty else { continue }

            let selectedWorker = eligibleWorkers.min { w1, w2 in
                let load1 = currentAssignments.filter { $0.workerID == w1.id && ($0.status == .queued || $0.status == .running) }.count
                let load2 = currentAssignments.filter { $0.workerID == w2.id && ($0.status == .queued || $0.status == .running) }.count
                if load1 != load2 {
                    return load1 < load2
                }

                let fail1 = currentAssignments.filter { $0.workerID == w1.id && $0.status == .failed }.count
                let fail2 = currentAssignments.filter { $0.workerID == w2.id && $0.status == .failed }.count
                if fail1 != fail2 {
                    return fail1 < fail2
                }

                let state1 = connectionStates[w1.id] ?? .unknown
                let state2 = connectionStates[w2.id] ?? .unknown
                if state1 == .authenticated && state2 != .authenticated { return true }
                if state2 == .authenticated && state1 != .authenticated { return false }
                return false
            } ?? eligibleWorkers[0]

            let effectivePermissions = Array(Set(selectedWorker.capabilities).intersection(allowedCapabilities))

            let newAssignment = SAWTeamAssignment(
                id: UUID(),
                projectID: session.projectID,
                runID: runID,
                workerID: selectedWorker.id,
                goal: fullGoal,
                generation: currentEpoch,
                requestID: UUID(),
                status: .queued,
                permissions: effectivePermissions,
                ownedTabIDs: []
            )

            session.workspace.mutateProject(id: session.projectID) { proj in
                proj.teamAssignments.append(newAssignment)
            }
            let label = humanMemberLabel(worker: selectedWorker)
            let sanitizedTitle = sanitizeChatText(trimmedGoal)
            session.workspace.store.appendChatMessage(
                projectID: session.projectID,
                message: SAWChatMessage(sender: "assistant", text: "[\(label)] \(sanitizedTitle)를 맡았습니다.", runID: session.teamRunID)
            )
        }

        drainQueue(dispatchGoal: goal)
    }

    // MARK: - Queue Drain & Task Worker

    private func drainQueue(dispatchGoal: String) {
        guard session.runStatus == "running",
              let runID = session.teamRunID,
              let project = session.project,
              let config = project.team else {
            return
        }

        let epoch = session.teamGeneration
        let assignments = project.teamAssignments

        let queued = assignments.filter {
            $0.runID == runID &&
            $0.generation == epoch &&
            $0.status == .queued
        }

        for assignment in queued {
            guard !busyWorkerIDs.contains(assignment.workerID) else { continue }

            guard let worker = config.workers.first(where: { $0.id == assignment.workerID }) else {
                markAssignmentFailed(
                    assignmentID: assignment.id,
                    requestID: assignment.requestID,
                    error: "Worker removed from team configuration"
                )
                continue
            }

            busyWorkerIDs.insert(worker.id)
            startWorkerTask(assignment: assignment, worker: worker, goal: dispatchGoal)
        }
    }

    private func startWorkerTask(assignment: SAWTeamAssignment, worker: SAWTeamWorker, goal: String) {
        let assignmentID = assignment.id
        let requestID = assignment.requestID
        let capturedEpoch = session.teamGeneration
        guard let capturedRunID = session.teamRunID else {
            cleanupTask(assignmentID: assignmentID, requestID: requestID, tabID: nil, workerID: worker.id)
            return
        }

        let session = self.session
        let task = Task { @MainActor [weak self, session] in
            defer {
                _ = session
            }
            guard let self = self else { return }

            guard self.session.teamGeneration == capturedEpoch,
                  self.session.teamRunID == capturedRunID,
                  self.session.runStatus == "running" else {
                self.cleanupTask(assignmentID: assignmentID, requestID: requestID, tabID: nil, workerID: worker.id)
                return
            }

            guard let liveWorker = self.session.project?.team?.workers.first(where: { $0.id == worker.id }),
                  liveWorker == worker else {
                self.cleanupTask(assignmentID: assignmentID, requestID: requestID, tabID: nil, workerID: worker.id)
                self.markAssignmentFailed(
                    assignmentID: assignmentID,
                    requestID: requestID,
                    error: "Worker configuration modified or worker removed"
                )
                return
            }

            guard let currentA = self.session.project?.teamAssignments.first(where: { $0.id == assignmentID }),
                  currentA.requestID == requestID,
                  currentA.status == .queued else {
                self.cleanupTask(assignmentID: assignmentID, requestID: requestID, tabID: nil, workerID: worker.id)
                return
            }

            guard let service = self.resolveService(for: worker) else {
                self.cleanupTask(assignmentID: assignmentID, requestID: requestID, tabID: nil, workerID: worker.id)
                self.markAssignmentFailed(
                    assignmentID: assignmentID,
                    requestID: requestID,
                    error: "지정된 AI 서비스를 찾을 수 없습니다: \(worker.providerID)"
                )
                return
            }

            let forcedCLI = self.isForcedCLI
            if !self.automaticModeAllows(worker) {
                self.cleanupTask(assignmentID: assignmentID, requestID: requestID, tabID: nil, workerID: worker.id)
                self.markAssignmentFailed(
                    assignmentID: assignmentID,
                    requestID: requestID,
                    error: "자동 팀원의 연결 방식이 현재 실제 연결과 달라 사용하지 않습니다."
                )
                return
            }
            if forcedCLI && !self.supportsCLI(worker) {
                self.cleanupTask(assignmentID: assignmentID, requestID: requestID, tabID: nil, workerID: worker.id)
                self.markAssignmentFailed(
                    assignmentID: assignmentID,
                    requestID: requestID,
                    error: "이 팀원은 웹 전용이라 CLI 모드에서 사용할 수 없습니다."
                )
                return
            }
            if forcedCLI && !self.isServiceEnabledForCLI(worker) {
                self.cleanupTask(assignmentID: assignmentID, requestID: requestID, tabID: nil, workerID: worker.id)
                self.markAssignmentFailed(
                    assignmentID: assignmentID,
                    requestID: requestID,
                    error: "이 팀원의 AI 서비스가 비활성화되어 CLI 모드에서 사용할 수 없습니다."
                )
                return
            }

            let initialURL = self.resolveInitialURL(for: assignment)
            let tab = self.session.newTeamTab(url: initialURL)
            let tabID = tab.tabID

            self.busyTabIDs.insert(tabID)
            self.runningAssignmentIDs.insert(assignmentID)

            self.session.workspace.mutateProject(id: self.session.projectID) { proj in
                if let idx = proj.teamAssignments.firstIndex(where: { $0.id == assignmentID && $0.requestID == requestID }) {
                    proj.teamAssignments[idx].status = .running
                    proj.teamAssignments[idx].ownedTabIDs = [tabID]
                }
            }

            let isHana = worker.providerID.lowercased().contains("hana")

            var transport: WebPageAgentTransport? = nil
            var hanaAdapter: SAWHanaTeamAdapter? = nil
            var cliTransport: SAWCLITransport? = nil
            var plannerWV: WKWebView? = nil

            if forcedCLI {
                cliTransport = self.getCLITransport(for: worker)
            } else if isHana {
                let store = self.dataStore(for: worker, service: service)
                let adapter = self.getHanaAdapter(for: worker)
                adapter.configurePlanner(dataStore: store)
                hanaAdapter = adapter
                plannerWV = adapter.plannerWebView
            } else {
                let store = self.dataStore(for: worker, service: service)
                let trans = self.getTransport(for: worker, service: service)
                trans.configurePlanner(service: service, dataStore: store)
                transport = trans
                plannerWV = trans.plannerWebView
            }

            self.updateHostedSurfaces()

            if !forcedCLI && (self.connectionStates[worker.id] == nil || self.connectionStates[worker.id] == .unknown) {
                self.connectionStates[worker.id] = .checking
            }

            var attached = false
            let deadline = Date().addingTimeInterval(15.0)

            while Date() < deadline {
                if Task.isCancelled { break }
                guard self.checkIsCurrent(
                    assignmentID: assignmentID,
                    requestID: requestID,
                    epoch: capturedEpoch,
                    runID: capturedRunID,
                    worker: worker,
                    tabID: tabID,
                    tab: tab
                ) else {
                    break
                }

                let tabWVAttached = (tab.webView?.window != nil)
                let aiWVAttached = (plannerWV == nil || plannerWV?.window != nil)

                if tabWVAttached && aiWVAttached {
                    attached = true
                    break
                }

                do {
                    try await Task.sleep(nanoseconds: 200_000_000)
                } catch {
                    break
                }
            }

            guard attached else {
                let errorMsg = Task.isCancelled ? "Task cancelled before window attachment" : "Platform window attachment timed out after 15 seconds"
                self.cleanupTask(assignmentID: assignmentID, requestID: requestID, tabID: tabID, workerID: worker.id)
                self.commitAssignmentResult(
                    assignmentID: assignmentID,
                    requestID: requestID,
                    epoch: capturedEpoch,
                    runID: capturedRunID,
                    worker: worker,
                    result: SAWTeamResult(
                        assignmentID: assignmentID,
                        projectID: self.session.projectID,
                        runID: capturedRunID,
                        workerID: worker.id,
                        generation: capturedEpoch,
                        requestID: requestID,
                        summary: "Execution failed before starting: \(errorMsg)",
                        sourceURLs: [],
                        error: errorMsg
                    ),
                    isFailure: true
                )
                self.drainQueue(dispatchGoal: goal)
                return
            }

            guard let runningAssignment = self.session.project?.teamAssignments.first(where: { $0.id == assignmentID && $0.requestID == requestID }) else {
                self.cleanupTask(assignmentID: assignmentID, requestID: requestID, tabID: tabID, workerID: worker.id)
                self.drainQueue(dispatchGoal: goal)
                return
            }

            let isCurrentClosure: @MainActor () -> Bool = { [weak self, weak tab] in
                guard let self = self, let tab = tab else { return false }
                return self.checkIsCurrent(
                    assignmentID: assignmentID,
                    requestID: requestID,
                    epoch: capturedEpoch,
                    runID: capturedRunID,
                    worker: worker,
                    tabID: tabID,
                    tab: tab
                )
            }

            let frozenGoal = self.session.teamExecutedGoal.isEmpty ? goal : self.session.teamExecutedGoal

            let result = await SAWTeamBrowserWorker.run(
                assignment: runningAssignment,
                worker: worker,
                tab: tab,
                transport: transport,
                cliTransport: cliTransport,
                hanaAdapter: hanaAdapter,
                service: service,
                originalGoal: frozenGoal,
                trustedInstructions: { [weak self] in
                    self?.session.teamLatestHumanInstructions.joined(separator: "\n") ?? ""
                },
                isCurrent: isCurrentClosure,
                onStatus: { [weak self] phase in
                    guard let self = self, isCurrentClosure() else { return }
                    self.recordTeamPhase(
                        worker: worker,
                        assignmentID: assignmentID,
                        requestID: requestID,
                        epoch: capturedEpoch,
                        runID: capturedRunID,
                        text: phase
                    )
                }
            )

            self.cleanupTask(assignmentID: assignmentID, requestID: requestID, tabID: tabID, workerID: worker.id)

            let isSuccess = (result.error == nil)
            self.commitAssignmentResult(
                assignmentID: assignmentID,
                requestID: requestID,
                epoch: capturedEpoch,
                runID: capturedRunID,
                worker: worker,
                result: result,
                isFailure: !isSuccess
            )

            self.drainQueue(dispatchGoal: goal)
        }

        activeTasks[assignmentID] = task
    }

    // MARK: - Validation & Identity Guards

    private func checkIsCurrent(
        assignmentID: UUID,
        requestID: UUID,
        epoch: UInt64,
        runID: UUID,
        worker: SAWTeamWorker,
        tabID: UUID,
        tab: LoginBrowserModel?
    ) -> Bool {
        guard session.teamGeneration == epoch,
              session.teamRunID == runID,
              session.runStatus == "running" else {
            return false
        }

        guard let project = session.project,
              let config = project.team,
              let liveWorker = config.workers.first(where: { $0.id == worker.id }),
              liveWorker == worker else {
            return false
        }

        guard automaticModeAllows(liveWorker) else { return false }

        if isForcedCLI {
            guard supportsCLI(liveWorker),
                  resolveService(for: liveWorker) != nil,
                  isServiceEnabledForCLI(liveWorker) else {
                return false
            }
        }

        guard let assignment = project.teamAssignments.first(where: { $0.id == assignmentID }),
              assignment.requestID == requestID,
              assignment.workerID == worker.id,
              assignment.projectID == session.projectID,
              assignment.runID == runID,
              assignment.generation == epoch,
              assignment.status == .running,
              assignment.ownedTabIDs.contains(tabID),
              assignment.permissions.allSatisfy({ liveWorker.capabilities.contains($0) }) else {
            return false
        }

        if let tab = tab {
            guard tab.tabID == tabID,
                  session.tabs.contains(where: { $0.tabID == tabID }) else {
                return false
            }
        }

        return true
    }

    private func commitAssignmentResult(
        assignmentID: UUID,
        requestID: UUID,
        epoch: UInt64,
        runID: UUID,
        worker: SAWTeamWorker,
        result: SAWTeamResult,
        isFailure: Bool
    ) {
        guard session.teamGeneration == epoch,
              session.teamRunID == runID else {
            return
        }

        guard let project = session.project,
              let config = project.team,
              let liveWorker = config.workers.first(where: { $0.id == worker.id }),
              liveWorker == worker else {
            return
        }

        guard let currentA = project.teamAssignments.first(where: { $0.id == assignmentID }),
              currentA.requestID == requestID,
              currentA.runID == runID,
              currentA.status == .running else {
            return
        }

        guard currentA.accepts(result, currentGeneration: session.teamGeneration, currentRequestID: currentA.requestID) else {
            return
        }

        let newStatus: SAWTeamAssignmentStatus = isFailure ? .failed : .completed

        session.workspace.mutateProject(id: session.projectID) { proj in
            if let idx = proj.teamAssignments.firstIndex(where: { $0.id == assignmentID && $0.requestID == requestID }) {
                proj.teamAssignments[idx].status = newStatus
                proj.teamAssignments[idx].result = result
            }
        }

        let label = humanMemberLabel(worker: worker)
        if !isFailure {
            session.workspace.store.appendChatMessage(
                projectID: session.projectID,
                message: SAWChatMessage(sender: "assistant", text: "[\(label)] 작업 완료했습니다.", runID: runID)
            )
        } else {
            if let err = result.error, err.hasPrefix("coordinatorRequired:") {
                session.workspace.store.appendChatMessage(
                    projectID: session.projectID,
                    message: SAWChatMessage(sender: "assistant", text: "[\(label)] 플래너가 이어서 처리합니다.", runID: runID)
                )
            } else {
                let errText = sanitizeChatText(result.error ?? "작업 실패")
                session.workspace.store.appendChatMessage(
                    projectID: session.projectID,
                    message: SAWChatMessage(sender: "assistant", text: "[\(label)] 작업에 실패했습니다: \(errText)", runID: runID)
                )
            }
        }

        if !isForcedCLI {
            if isFailure {
                if let err = result.error?.lowercased(),
                   (err.contains("login") || err.contains("auth") || err.contains("sign in") || err.contains("credential")) {
                    connectionStates[worker.id] = .loginRequired
                } else {
                    connectionStates[worker.id] = .failed
                }
            } else {
                connectionStates[worker.id] = .authenticated
            }
        }

        if isFailure, let failedAssignment = project.teamAssignments.first(where: { $0.id == assignmentID }) {
            handOffAfterConnectionFailure(
                failed: failedAssignment,
                result: result,
                worker: worker,
                epoch: epoch,
                runID: runID
            )
        }
    }

    // MARK: - Connection Failure Handoff

    private static let plannerRequestFailurePrefix = "모델의 다음 작업 요청에 실패했습니다: "
    private static let cliLoginRequiredHostMessage = "CLI 로그인이 필요합니다. 연결된 계정 상태를 확인해 주세요."

    /// Classifies only exact host-typed CLI planning failures. Model/page text is never inspected.
    private func isCLIConnectionFailure(_ error: String?) -> Bool {
        guard let error = error, error.hasPrefix(Self.plannerRequestFailurePrefix) else { return false }
        let detail = String(error.dropFirst(Self.plannerRequestFailurePrefix.count))
        return detail.hasPrefix("CLI_RETRY:") ||
            detail.hasPrefix("CLI_UNAVAILABLE:") ||
            detail.hasPrefix("CLI_WAIT:") ||
            detail.hasPrefix(Self.cliLoginRequiredHostMessage)
    }

    /// Appends one queued assignment for the same goal on an untried, idle worker. The failed result is kept as-is.
    private func handOffAfterConnectionFailure(
        failed: SAWTeamAssignment,
        result: SAWTeamResult,
        worker: SAWTeamWorker,
        epoch: UInt64,
        runID: UUID
    ) {
        guard isForcedCLI,
              !Task.isCancelled,
              isCLIConnectionFailure(result.error),
              session.runStatus == "running",
              session.teamGeneration == epoch,
              session.teamRunID == runID,
              failed.runID == runID,
              failed.generation == epoch,
              let project = session.project,
              let config = project.team else {
            return
        }

        let sameGoal = project.teamAssignments.filter {
            $0.runID == runID && $0.goal == failed.goal
        }
        // 이미 유효한 완료 결과가 있거나 같은 목표가 진행 중이면 새 배정을 만들지 않는다.
        let hasValidCompleted = sameGoal.contains { a in
            guard a.status == .completed,
                  let res = a.result,
                  res.error == nil,
                  res.assignmentID == a.id,
                  res.projectID == a.projectID,
                  res.runID == a.runID,
                  res.workerID == a.workerID,
                  res.requestID == a.requestID,
                  res.generation == a.generation else {
                return false
            }
            return true
        }
        let hasInFlight = sameGoal.contains {
            $0.generation == epoch && ($0.status == .queued || $0.status == .running)
        }
        if hasValidCompleted || hasInFlight {
            return
        }
        let triedWorkerIDs = Set(sameGoal.map(\.workerID)).union([worker.id])
        let originalPermissions = Set(failed.permissions)
        // 부작용 여부를 확인할 실행 증거가 없으므로 읽기 전용 배정만 자동으로 다시 맡긴다.
        let readOnlyCapabilities: Set<SAWTeamCapability> = [.read, .navigate, .search]
        guard originalPermissions.contains(.read), originalPermissions.isSubset(of: readOnlyCapabilities) else {
            return
        }

        let loadedWorkerIDs = Set(project.teamAssignments.filter {
            $0.runID == runID && $0.generation == epoch && ($0.status == .queued || $0.status == .running)
        }.map(\.workerID))

        let candidates: [(worker: SAWTeamWorker, permissions: [SAWTeamCapability])] = config.workers.compactMap { candidate in
            guard !triedWorkerIDs.contains(candidate.id),
                  !busyWorkerIDs.contains(candidate.id),
                  !loadedWorkerIDs.contains(candidate.id),
                  automaticModeAllows(candidate),
                  supportsCLI(candidate),
                  resolveService(for: candidate) != nil,
                  isServiceEnabledForCLI(candidate) else {
                return nil
            }
            // 같은 제공자의 같은 명시 CLI 계정은 같은 연결 실패를 반복하므로 제외한다.
            if let boundAccount = worker.cliAccountID,
               candidate.cliAccountID == boundAccount,
               candidate.providerID.caseInsensitiveCompare(worker.providerID) == .orderedSame {
                return nil
            }
            let effective = originalPermissions.intersection(candidate.capabilities)
            guard effective.contains(.read), effective == originalPermissions else { return nil }
            return (candidate, Array(effective))
        }

        guard let selected = candidates.first(where: {
            $0.worker.providerID.caseInsensitiveCompare(worker.providerID) != .orderedSame
        }) ?? candidates.first else {
            return
        }

        let newAssignment = SAWTeamAssignment(
            id: UUID(),
            projectID: session.projectID,
            runID: runID,
            workerID: selected.worker.id,
            goal: failed.goal,
            generation: epoch,
            requestID: UUID(),
            status: .queued,
            permissions: selected.permissions,
            ownedTabIDs: []
        )

        session.workspace.mutateProject(id: session.projectID) { proj in
            proj.teamAssignments.append(newAssignment)
        }

        guard session.project?.teamAssignments.contains(where: {
            $0.id == newAssignment.id && $0.requestID == newAssignment.requestID && $0.status == .queued
        }) == true else {
            return
        }

        let reason = (result.error?.hasSuffix(Self.cliLoginRequiredHostMessage) == true) ? "로그인 문제" : "연결문제"
        let oldLabel = sanitizeChatText(humanMemberLabel(worker: worker))
        let newLabel = sanitizeChatText(humanMemberLabel(worker: selected.worker))
        session.workspace.store.appendChatMessage(
            projectID: session.projectID,
            message: SAWChatMessage(
                sender: "assistant",
                text: "[\(oldLabel)] \(reason)로 [\(newLabel)]이 이어받습니다.",
                runID: runID
            )
        )
    }

    private func markAssignmentFailed(assignmentID: UUID, requestID: UUID, error: String) {
        guard let runID = session.teamRunID else { return }
        let epoch = session.teamGeneration

        session.workspace.mutateProject(id: session.projectID) { proj in
            if let idx = proj.teamAssignments.firstIndex(where: { $0.id == assignmentID && $0.requestID == requestID }) {
                if proj.teamAssignments[idx].status == .queued || proj.teamAssignments[idx].status == .running {
                    proj.teamAssignments[idx].status = .failed
                    proj.teamAssignments[idx].result = SAWTeamResult(
                        assignmentID: assignmentID,
                        projectID: proj.id,
                        runID: runID,
                        workerID: proj.teamAssignments[idx].workerID,
                        generation: epoch,
                        requestID: requestID,
                        summary: "Task execution failed: \(error)",
                        sourceURLs: [],
                        error: error
                    )
                }
            }
        }
    }

    private func cleanupTask(assignmentID: UUID, requestID: UUID, tabID: UUID?, workerID: UUID) {
        activeTasks.removeValue(forKey: assignmentID)
        runningAssignmentIDs.remove(assignmentID)

        var activeWorkers = Set<UUID>()
        var activeTabs = Set<UUID>()
        if let assignments = session.project?.teamAssignments {
            for a in assignments where runningAssignmentIDs.contains(a.id) {
                activeWorkers.insert(a.workerID)
                for tid in a.ownedTabIDs {
                    activeTabs.insert(tid)
                }
            }
        }
        busyWorkerIDs = activeWorkers
        busyTabIDs = activeTabs
    }

    // MARK: - Cancellation & Resets

    func cancelAllWorkers() {
        for (_, task) in activeTasks {
            task.cancel()
        }
        activeTasks.removeAll()

        for (_, transport) in transports {
            transport.cancelActiveGeneration()
        }
        for (_, adapter) in hanaAdapters {
            adapter.cancelActiveGeneration()
        }
        for (_, cli) in cliTransports {
            cli.cancelActiveGeneration()
        }

        if let runID = session.teamRunID {
            session.workspace.mutateProject(id: session.projectID) { project in
                for i in 0..<project.teamAssignments.count {
                    if project.teamAssignments[i].runID == runID &&
                       (project.teamAssignments[i].status == .queued || project.teamAssignments[i].status == .running) {
                        project.teamAssignments[i].status = .paused
                    }
                }
            }
        }

        busyTabIDs.removeAll()
        busyWorkerIDs.removeAll()
        runningAssignmentIDs.removeAll()
        externalSearchResults.removeAll()
    }

    func resetForNewRun() {
        cancelAllWorkers()
        activeLoginWorkerID = nil
        updateHostedSurfaces()
    }

    func restart() {
        resetForNewRun()
    }

    // MARK: - Coordinator Context

    func coordinatorContext() -> String {
        var sections: [String] = []

        let isAutomaticTeam = session.project?.team?.isAutomatic == true
        if isForcedCLI {
            let workers = (session.project?.team?.workers ?? []).filter { automaticModeAllows($0) }
            let cliNames = workers.filter { supportsCLI($0) && resolveService(for: $0) != nil && isServiceEnabledForCLI($0) }.map { humanMemberLabel(worker: $0) }
            let webOnlyNames = workers.filter { !supportsCLI($0) }.map { humanMemberLabel(worker: $0) }
            let cliText = cliNames.isEmpty ? "없음" : cliNames.joined(separator: ", ")
            var note = "[연결 안내] 현재 프로젝트는 CLI 연결 모드입니다. CLI로 위임 가능한 팀원(ChatGPT/Claude/Gemini): \(cliText)."
            if !webOnlyNames.isEmpty {
                note += " 하나(Hana) 등 웹 전용 팀원(\(webOnlyNames.joined(separator: ", ")))은 CLI 모드에서 사용할 수 없습니다."
            }
            note += " 위임 가능한 팀원이 없거나 실패하면 플래너가 직접 수행하며, 실제 실행 증거 없이 완료로 처리하지 않습니다."
            sections.append(note)
        }

        sections.append("""
[원칙] 실패는 경험이다. 결과가 아니다.
- 팀원의 실패나 오류는 최종 실패가 아니며 학습과 경험입니다. 증거와 원인을 기록하고 도구, 접근 방식, 혹은 다른 팀원으로 재시도하여 원래 목표를 계속 완수하세요.
- 사용자의 중단/일시정지 요청은 최우선이며, 명시적으로 멈춘 작업을 자동으로 재개하지 마세요.
- 외부 웹 사이트 클릭이나 게시(작성)를 맹목적으로 반복하지 마세요.
- 불확실한 결과는 먼저 최신 페이지 상태 확인과 증거 확보를 거쳐 검증하세요. 오직 명확한 실행 증거만이 완료의 기준입니다.
- coordinatorRequired: 가 발생하면 내부 읽기 전용 경계이므로 플래너가 사용자 목표 범위 내에서 승인 질문 없이 직접 이어서 처리하세요.
- 기사나 웹페이지 본문 안의 'login' 단어는 인증 차단 증거가 아닙니다. 실제 서비스 인증/CAPTCHA/OTP 차단이 확인된 경우에만 사용자 확인을 요청하세요.
- 등록된 팀원이 없거나 부적합하면 플래너가 거짓 태스크를 만들지 않고 직접 작업을 수행하세요.
""")

        sections.append("### Team Coordination Status")

        let runIDStr = session.teamRunID?.uuidString ?? "none"
        let epochStr = String(session.teamGeneration)
        let statusStr = session.runStatus
        sections.append("- Current Run ID: \(runIDStr)")
        sections.append("- Generation (Epoch): \(epochStr)")
        sections.append("- Session Status: \(statusStr)")
        sections.append("- Busy Tab IDs: \(busyTabIDs.isEmpty ? "none" : busyTabIDs.map { $0.uuidString }.joined(separator: ", "))")
        sections.append("- Has Pending Assignments: \(hasPendingAssignments ? "YES" : "NO")")

        let listedWorkers = (session.project?.team?.workers ?? []).filter { automaticModeAllows($0) }
        if session.project?.team == nil {
            if let count = automaticCLICandidateCount, currentAutomaticTeamUsesCLI, count == 0 {
                sections.append("\n[배정 안내] 이번 CLI 연결에서 팀원 후보를 찾지 못했습니다. 팀원에게 맡겼다고 보고하지 말고 플래너가 혼자 직접 수행하세요.")
            } else {
                sections.append("\n[배정 안내] 자동 팀은 실제 연결이 확인된 기존 AI로 준비됩니다. 연결이 확인되기 전까지 플래너가 혼자 수행하며, 팀원에게 맡겼다고 보고하지 마세요.")
            }
        } else if !listedWorkers.isEmpty {
            if isAutomaticTeam {
                sections.append("\n[자동 팀] 현재 연결 방식에서 쓸 수 있는 자동 팀원 후보는 \(listedWorkers.count)명이며, 로그인·응답 여부는 실제 요청 결과로만 확인됩니다.")
            }
            sections.append("\n#### Team Workers & Connection States")
            for worker in listedWorkers {
                let name = worker.displayName ?? worker.accountID
                let stateLabel = isForcedCLI ? "CLI 연결은 실제 요청 결과로 확인" : (connectionStates[worker.id] ?? .unknown).localizedLabel
                let isBusy = busyWorkerIDs.contains(worker.id)
                let caps = worker.capabilities.map { $0.rawValue }.joined(separator: ", ")
                sections.append("- Worker '\(name)' (ID: \(worker.id.uuidString)): State = [\(stateLabel)], Busy = \(isBusy ? "YES" : "NO"), Caps = [\(caps)]")
            }
        } else if isAutomaticTeam {
            sections.append("\n[배정 안내] 자동 팀원 후보가 현재 실제 연결 방식과 맞지 않아 이번에는 팀원 배정이 실행되지 않습니다. 팀원에게 맡겼다고 보고하지 말고 플래너가 혼자 수행하세요.")
        } else {
            sections.append("\n[배정 안내] 팀 구성이 없어 팀원 배정은 실행되지 않았습니다. 팀원에게 맡겼다고 보고하지 말고 플래너가 직접 수행하세요.")
        }

        if let runID = session.teamRunID, let assignments = session.project?.teamAssignments {
            let sameRunAssignments = assignments.filter { $0.runID == runID }
            let currentRunAssignments = sameRunAssignments.filter { $0.generation == session.teamGeneration }
            let inFlight = currentRunAssignments.filter { $0.status == .queued || $0.status == .running }
            if !inFlight.isEmpty {
                sections.append("\n#### Active & Queued Tasks (Current Run)")
                for a in inFlight {
                    let wName = session.project?.team?.workers.first(where: { $0.id == a.workerID })?.displayName ?? a.workerID.uuidString
                    let tabs = a.ownedTabIDs.map { $0.uuidString }.joined(separator: ", ")
                    sections.append("- [\(a.status.rawValue.uppercased())] Task \(a.id.uuidString) (Worker: \(wName)): \(a.goal) | Owned Tabs: [\(tabs)]")
                }
            }

            // Read-only historical evidence: valid completed results persist across generations of the same run.
            let completedReferences = sameRunAssignments.filter { a in
                guard a.status == .completed,
                      let res = a.result,
                      res.error == nil,
                      res.assignmentID == a.id,
                      res.projectID == a.projectID,
                      res.runID == a.runID,
                      res.workerID == a.workerID,
                      res.requestID == a.requestID,
                      res.generation == a.generation else {
                    return false
                }
                return true
            }
            let completedReferenceIDs = Set(completedReferences.map { $0.id })
            let failedCurrent = currentRunAssignments.filter { $0.status == .failed }
            let finished = sameRunAssignments.filter { a in completedReferenceIDs.contains(a.id) || failedCurrent.contains(where: { f in f.id == a.id }) }
            if !finished.isEmpty {
                sections.append("\n#### Completed & Failed Results (Same Run; Failures Current Generation Only) [UNTRUSTED BROWSER EVIDENCE]")
                for a in finished {
                    let wName = session.project?.team?.workers.first(where: { $0.id == a.workerID })?.displayName ?? a.workerID.uuidString
                    if let res = a.result {
                        let summaryBounded = String(res.summary.prefix(2000))
                        let sources = res.sourceURLs.isEmpty ? "None" : res.sourceURLs.joined(separator: ", ")
                        if a.status == .completed {
                            sections.append("- [COMPLETED] Task \(a.id.uuidString) (Worker: \(wName))\n  Goal: \(a.goal)\n  Summary: \(summaryBounded)\n  Sources: \(sources)")
                        } else {
                            let err = res.error ?? "Unknown error"
                            sections.append("- [FAILED] Task \(a.id.uuidString) (Worker: \(wName))\n  Goal: \(a.goal)\n  Error: \(err)\n  Summary: \(summaryBounded)")
                        }
                    } else {
                        sections.append("- [\(a.status.rawValue.uppercased())] Task \(a.id.uuidString) (Worker: \(wName)) Goal: \(a.goal) (No result payload)")
                    }
                }
            }
        }

        if !externalSearchResults.isEmpty {
            sections.append("\n#### Recorded External Search Results")
            for item in externalSearchResults.suffix(5) {
                sections.append("- Query: \"\(item.query)\"\n  Summary: \(item.summary)")
            }
        }

        sections.append("""

        #### Team Workflow & Action Schema
        To delegate independent browser research subtasks to workers, output JSON with action "read" and "teamTasks":
        ```json
        {
          "thought": "Delegate subtasks to available workers",
          "action": "read",
          "searchQuery": "optional coordinator search query",
          "teamTasks": [
            {
              "goal": "Specific subtask objective for the worker to navigate or extract",
              "url": "https://example.com/target-page"
            }
          ]
        }
        ```
        Rules:
        - Goal / scope / permission / tools / evidence -> one owner / small task -> independent parallel execution -> single write owner -> recover failure -> actual evidence completion.
        - For research/news tasks (조사/리서치/연구/뉴스/research/news), first search then actually open and read relevant MULTIPLE owned work tabs appropriate to the user goal. Collect facts, source URLs, and publication dates ONLY if actually observed. Exa snippets and model claims are not final evidence. Finish with .done containing the full human-readable report in result/summary; the host automatically opens the report in a workspace tab. Keep the original user goal, scope, and cancellation rules intact.
        - While `hasPendingAssignments` is true, the coordinator may continue other work, but MUST NOT declare final completion (.done) until all worker assignments are resolved.
        - Owned worker tabs are protected from coordinator write modifications.
        """)

        var combined = sections.joined(separator: "\n")
        if combined.count > 8000 {
            combined = String(combined.prefix(7950)) + "\n... [Context truncated to 8k]"
        }
        return combined
    }

    // MARK: - Private Helpers

    private func resolveInitialURL(for assignment: SAWTeamAssignment) -> URL {
        if let urlRange = assignment.goal.range(of: "URL: ") {
            let potentialURLStr = String(assignment.goal[urlRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = URL(string: potentialURLStr),
               let scheme = url.scheme?.lowercased(),
               (scheme == "http" || scheme == "https"),
               url.host != nil {
                return url
            }
        }

        if let activeURL = session.activeBrowser?.currentURL,
           let scheme = activeURL.scheme?.lowercased(),
           (scheme == "http" || scheme == "https"),
           activeURL.host != nil {
            return activeURL
        }

        let textToSearch = session.teamExecutedGoal.isEmpty ? assignment.goal : session.teamExecutedGoal
        if let detectedURL = extractFirstHTTPURL(from: textToSearch) {
            return detectedURL
        }

        var components = URLComponents(string: "https://html.duckduckgo.com/html/")
        components?.queryItems = [URLQueryItem(name: "q", value: assignment.goal)]
        if let searchURL = components?.url {
            return searchURL
        }

        return URL(string: "https://duckduckgo.com")!
    }

    private func extractFirstHTTPURL(from text: String) -> URL? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let matches = detector?.matches(in: text, options: [], range: NSRange(location: 0, length: (text as NSString).length))
        for match in matches ?? [] {
            if let url = match.url,
               let scheme = url.scheme?.lowercased(),
               (scheme == "http" || scheme == "https"),
               url.host != nil {
                return url
            }
        }
        return nil
    }

    private func resolveService(for worker: SAWTeamWorker) -> AIService? {
        let services = session.workspace.appModel.aiServices.allServices
        return services.first(where: { $0.id.caseInsensitiveCompare(worker.providerID) == .orderedSame })
    }

    private func getHanaAdapter(for worker: SAWTeamWorker, service: AIService? = nil) -> SAWHanaTeamAdapter {
        if let existing = hanaAdapters[worker.id] { return existing }
        let adapter = SAWHanaTeamAdapter()
        if let service = service ?? resolveService(for: worker) {
            let store = dataStore(for: worker, service: service)
            adapter.configurePlanner(dataStore: store)
        }
        hanaAdapters[worker.id] = adapter
        return adapter
    }

    private func getTransport(for worker: SAWTeamWorker, service: AIService) -> WebPageAgentTransport {
        if let existing = transports[worker.id] { return existing }
        let transport = WebPageAgentTransport()
        let store = dataStore(for: worker, service: service)
        transport.configurePlanner(service: service, dataStore: store)
        transports[worker.id] = transport
        return transport
    }

    private func getCLITransport(for worker: SAWTeamWorker) -> SAWCLITransport {
        if let existing = cliTransports[worker.id] { return existing }
        let cli = SAWCLITransport()
        cliTransports[worker.id] = cli
        return cli
    }

    private func updateHostedSurfaces() {
        var surfaces: [SAWTeamAISurface] = []
        guard let workers = session.project?.team?.workers else {
            hostedAISurfaces = []
            return
        }
        for worker in workers {
            if worker.id == activeLoginWorkerID { continue }
            if let transport = transports[worker.id], let wv = transport.plannerWebView {
                surfaces.append(SAWTeamAISurface(id: worker.id, webView: wv))
            } else if let hana = hanaAdapters[worker.id], let wv = hana.plannerWebView {
                surfaces.append(SAWTeamAISurface(id: worker.id, webView: wv))
            }
        }
        hostedAISurfaces = surfaces
    }
}
