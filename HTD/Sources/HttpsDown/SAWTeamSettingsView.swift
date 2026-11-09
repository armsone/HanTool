import SwiftUI
import WebKit

// MARK: - Providers Configuration

struct SAWTeamProviderOption: Identifiable, Hashable {
    let id: String
    let name: String
}

private let allowedProviders: [SAWTeamProviderOption] = [
    SAWTeamProviderOption(id: "hana", name: "하나"),
    SAWTeamProviderOption(id: "chatgpt", name: "ChatGPT"),
    SAWTeamProviderOption(id: "claude", name: "Claude"),
    SAWTeamProviderOption(id: "gemini", name: "Gemini")
]

private func friendlyProviderLabel(for providerID: String) -> String {
    allowedProviders.first(where: { $0.id == providerID })?.name ?? providerID
}

// MARK: - Login Sheet Presentation Model

private struct SAWTeamLoginPresentation: Identifiable {
    let id: UUID
    let workerName: String
    let webView: WKWebView
    let runtime: SAWTeamRuntime
    let session: SAWProjectSession

    init(workerID: UUID, workerName: String, webView: WKWebView, runtime: SAWTeamRuntime, session: SAWProjectSession) {
        self.id = workerID
        self.workerName = workerName
        self.webView = webView
        self.runtime = runtime
        self.session = session
    }
}

// MARK: - Main Settings Section Component

@MainActor
struct SAWTeamSettingsSection: View {
    @ObservedObject var workspace: SAWWorkspace
    @Environment(\.bkPalette) private var palette

    @State private var activeLoginPresentation: SAWTeamLoginPresentation?
    @State private var loginSheetPresented: Bool = false

    init(workspace: SAWWorkspace) {
        self.workspace = workspace
    }

    private var activeProjects: [SAWProject] {
        workspace.store.projects.filter { !$0.archived }
    }

    private var selectedProject: SAWProject? {
        guard let id = workspace.selectedProjectID else { return nil }
        return activeProjects.first(where: { $0.id == id })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Project Selector Header
            projectSelectorView

            // Team Settings or Guidance
            if let project = selectedProject {
                if let session = workspace.existingSession(for: project.id) {
                    SAWProjectTeamSectionView(
                        workspace: workspace,
                        project: project,
                        session: session,
                        onStartLogin: { worker in
                            startLogin(for: worker, in: session)
                        },
                        onRemoveWorker: { worker in
                            removeWorker(worker, in: project.id)
                        },
                        onAddWorker: { providerID, displayName, useExistingLogin, errorHandler in
                            addWorker(
                                providerID: providerID,
                                displayName: displayName,
                                useExistingLogin: useExistingLogin,
                                in: project.id,
                                errorHandler: errorHandler
                            )
                        },
                        onSetCLIAccount: { worker, accountID in
                            setCLIAccount(accountID, for: worker, in: project.id)
                        }
                    )
                    .id(project.id)
                } else {
                    Text("세션 로딩 중입니다...")
                        .font(.system(size: 13))
                        .foregroundColor(palette.mutedColor)
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("팀원 설정")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(palette.textColor)
                    Text("팀원을 관리할 프로젝트를 선택하거나 플래너에서 새 프로젝트를 생성하세요.")
                        .font(.system(size: 13))
                        .foregroundColor(palette.mutedColor)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(palette.cardColor)
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(palette.borderColor, lineWidth: 1)
                )
            }

            // Exa Common Search Tool Section (Always Available)
            SAWExaToolSectionView()
        }
        .sheet(isPresented: $loginSheetPresented, onDismiss: {
            closeLoginPresentation()
        }) {
            if let presentation = activeLoginPresentation {
                VStack(spacing: 0) {
                    HStack {
                        Text("\(presentation.workerName) 로그인 화면")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(palette.textColor)
                        Spacer()
                        Button("닫기") {
                            loginSheetPresented = false
                        }
                        .font(.system(size: 13))
                        .foregroundColor(palette.accentColor)
                    }
                    .padding()
                    .background(palette.cardColor)

                    LoginWebViewRepresentable(
                        webView: presentation.webView,
                        nativeInputAllowed: { true }
                    )
                }
                .frame(minWidth: 500, minHeight: 600)
                .background(palette.bgColor)
            }
        }
        .onDisappear {
            closeLoginPresentation()
        }
        .onChange(of: workspace.selectedProjectID) { _ in
            closeLoginPresentation()
        }
    }

    private var projectSelectorView: some View {
        HStack {
            Text("프로젝트")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(palette.text2Color)
            Spacer()
            Picker("프로젝트 선택", selection: $workspace.selectedProjectID) {
                Text("프로젝트 선택 안 됨").tag(Optional<UUID>.none)
                ForEach(activeProjects, id: \.id) { proj in
                    Text(sawDisplayProjectTitle(proj)).tag(Optional<UUID>.some(proj.id))
                }
            }
            .labelsHidden()
        }
    }

    private func closeLoginPresentation() {
        loginSheetPresented = false
        if let presentation = activeLoginPresentation {
            presentation.runtime.closeLoginPresentation()
            activeLoginPresentation = nil
        }
    }

    private func startLogin(for worker: SAWTeamWorker, in session: SAWProjectSession) {
        let runtime = session.teamRuntime
        guard !runtime.busyWorkerIDs.contains(worker.id), runtime.activeLoginWorkerID == nil else {
            return
        }
        guard let webView = runtime.prepareLogin(worker: worker) else {
            return
        }
        let displayName = (worker.displayName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? worker.displayName!
            : friendlyProviderLabel(for: worker.providerID)

        self.activeLoginPresentation = SAWTeamLoginPresentation(
            workerID: worker.id,
            workerName: displayName,
            webView: webView,
            runtime: runtime,
            session: session
        )
        self.loginSheetPresented = true
    }

    private func removeWorker(_ worker: SAWTeamWorker, in projectID: UUID) {
        if let session = workspace.existingSession(for: projectID),
           let runtime = session.existingTeamRuntime {
            runtime.cancelAllWorkers()
        }
        workspace.mutateProject(id: projectID) { p in
            var team = p.team ?? SAWTeamConfiguration()
            team.workers.removeAll { $0.id == worker.id }
            p.team = team
        }
    }

    private func setCLIAccount(_ accountID: String?, for worker: SAWTeamWorker, in projectID: UUID) {
        guard let session = workspace.existingSession(for: projectID) else { return }
        let runtime = session.existingTeamRuntime
        guard session.runStatus != "running", !(runtime?.busyWorkerIDs.contains(worker.id) ?? false) else {
            return
        }
        // 매핑 변경 전에 기존 워커 작업을 먼저 취소한다.
        runtime?.cancelAllWorkers()
        workspace.mutateProject(id: projectID) { p in
            guard var team = p.team,
                  let idx = team.workers.firstIndex(where: { $0.id == worker.id }) else { return }
            team.workers[idx].cliAccountID = accountID
            p.team = team
        }
    }

    private func addWorker(
        providerID: String,
        displayName: String,
        useExistingLogin: Bool,
        in projectID: UUID,
        errorHandler: (String) -> Void
    ) {
        guard let project = workspace.store.projects.first(where: { $0.id == projectID }) else {
            return
        }
        let storeID = useExistingLogin ? SAWTeamRuntime.sharedLoginSentinelUUID : UUID()
        let currentWorkers = project.team?.workers ?? []

        if currentWorkers.contains(where: { $0.providerID == providerID && $0.websiteDataStoreID == storeID }) {
            errorHandler("이 서비스의 기존 로그인을 사용하는 팀원이 이미 있습니다. 다른 로그인으로 추가해 주세요.")
            return
        }

        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let autoName = trimmed.isEmpty ? friendlyProviderLabel(for: providerID) : trimmed
        let newWorker = SAWTeamWorker(
            id: UUID(),
            providerID: providerID,
            accountID: UUID().uuidString,
            websiteDataStoreID: storeID,
            displayName: autoName,
            capabilities: [.read, .navigate, .search]
        )

        if let session = workspace.existingSession(for: projectID),
           let runtime = session.existingTeamRuntime {
            runtime.cancelAllWorkers()
        }

        workspace.mutateProject(id: projectID) { p in
            var team = p.team ?? SAWTeamConfiguration()
            team.workers.append(newWorker)
            p.team = team
        }
    }
}

// MARK: - Project Team Section View (Session Observed)

@MainActor
private struct SAWProjectTeamSectionView: View {
    @ObservedObject var workspace: SAWWorkspace
    let project: SAWProject
    @ObservedObject var session: SAWProjectSession

    let onStartLogin: (SAWTeamWorker) -> Void
    let onRemoveWorker: (SAWTeamWorker) -> Void
    let onAddWorker: (String, String, Bool, (String) -> Void) -> Void
    let onSetCLIAccount: (SAWTeamWorker, String?) -> Void

    @Environment(\.bkPalette) private var palette

    private var isCLIMode: Bool {
        project.connectionMode == "cli" || (project.connectionMode == "automatic" && project.team?.isAutomatic == true && project.team?.workers.contains(where: { $0.cliAccountID != nil }) == true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("팀원")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(palette.textColor)
                Spacer()
            }

            if project.team == nil {
                Text("처음 업무를 맡기면 연결된 AI로 팀을 준비합니다.")
                    .font(.system(size: 13))
                    .foregroundColor(palette.mutedColor)
                    .padding(.vertical, 4)
            } else if project.team?.isAutomatic == true {
                Text("자동 구성 · 연결 확인은 실제 요청 시 이루어집니다.")
                    .font(.system(size: 11))
                    .foregroundColor(palette.mutedColor)
            }

            if project.team == nil {
                EmptyView()
            } else if let runtime = session.existingTeamRuntime {
                SAWObservedRuntimeWorkersView(
                    workers: project.team?.workers ?? [],
                    runtime: runtime,
                    isCLIMode: isCLIMode,
                    onStartLogin: onStartLogin,
                    onRemoveWorker: onRemoveWorker
                )
            } else {
                SAWStaticWorkersListView(
                    workers: project.team?.workers ?? [],
                    isCLIMode: isCLIMode,
                    onStartLogin: onStartLogin,
                    onRemoveWorker: onRemoveWorker
                )
            }

            if isCLIMode {
                SAWCLIAccountMappingView(
                    workers: project.team?.workers ?? [],
                    isRunning: session.runStatus == "running",
                    busyWorkerIDs: session.existingTeamRuntime?.busyWorkerIDs ?? [],
                    onSet: onSetCLIAccount
                )
            }

            Divider()
                .background(palette.borderColor)

            SAWAddWorkerFormView(
                onAdd: onAddWorker
            )
        }
        .padding(12)
        .background(palette.cardColor)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(palette.borderColor, lineWidth: 1)
        )
    }
}

// MARK: - Observed Runtime Workers View

@MainActor
private struct SAWObservedRuntimeWorkersView: View {
    let workers: [SAWTeamWorker]
    @ObservedObject var runtime: SAWTeamRuntime
    var isCLIMode: Bool = false
    let onStartLogin: (SAWTeamWorker) -> Void
    let onRemoveWorker: (SAWTeamWorker) -> Void

    @Environment(\.bkPalette) private var palette

    var body: some View {
        if workers.isEmpty {
            Text("등록된 팀원이 없습니다. 아래에서 팀원을 추가하세요.")
                .font(.system(size: 13))
                .foregroundColor(palette.mutedColor)
                .padding(.vertical, 4)
        } else {
            VStack(spacing: 8) {
                ForEach(workers) { worker in
                    let isBusy = runtime.busyWorkerIDs.contains(worker.id)
                    let isLoginDisabled = isBusy || runtime.activeLoginWorkerID != nil
                    let connectionState = runtime.connectionStates[worker.id] ?? .unknown

                    SAWWorkerRowView(
                        worker: worker,
                        connectionState: connectionState,
                        isBusy: isBusy,
                        isLoginDisabled: isLoginDisabled,
                        isCLIMode: isCLIMode,
                        onLogin: { onStartLogin(worker) },
                        onRemove: { onRemoveWorker(worker) }
                    )
                }
            }
        }
    }
}

// MARK: - Static Workers List View (Runtime not yet created)

@MainActor
private struct SAWStaticWorkersListView: View {
    let workers: [SAWTeamWorker]
    var isCLIMode: Bool = false
    let onStartLogin: (SAWTeamWorker) -> Void
    let onRemoveWorker: (SAWTeamWorker) -> Void

    @Environment(\.bkPalette) private var palette

    var body: some View {
        if workers.isEmpty {
            Text("등록된 팀원이 없습니다. 아래에서 팀원을 추가하세요.")
                .font(.system(size: 13))
                .foregroundColor(palette.mutedColor)
                .padding(.vertical, 4)
        } else {
            VStack(spacing: 8) {
                ForEach(workers) { worker in
                    SAWWorkerRowView(
                        worker: worker,
                        connectionState: .unknown,
                        isBusy: false,
                        isLoginDisabled: false,
                        isCLIMode: isCLIMode,
                        onLogin: { onStartLogin(worker) },
                        onRemove: { onRemoveWorker(worker) }
                    )
                }
            }
        }
    }
}

// MARK: - Single Worker Row View

@MainActor
private struct SAWWorkerRowView: View {
    let worker: SAWTeamWorker
    let connectionState: SAWTeamConnectionState
    let isBusy: Bool
    let isLoginDisabled: Bool
    var isCLIMode: Bool = false
    let onLogin: () -> Void
    let onRemove: () -> Void

    @Environment(\.bkPalette) private var palette

    private var isCLIUnsupported: Bool {
        isCLIMode && !["chatgpt", "claude", "gemini"].contains(worker.providerID.lowercased())
    }

    private var friendlyName: String {
        if let name = worker.displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        return friendlyProviderLabel(for: worker.providerID)
    }

    private var isSharedLogin: Bool {
        worker.websiteDataStoreID == SAWTeamRuntime.sharedLoginSentinelUUID
    }

    private var statusDescription: String {
        switch connectionState {
        case .unknown:
            return "상태 확인 전"
        case .checking:
            return "확인 중"
        case .authenticated:
            return "로그인됨"
        case .loginRequired:
            return "로그인 필요"
        case .failed:
            return "연결 실패"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(friendlyName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(palette.textColor)

                    Text(friendlyProviderLabel(for: worker.providerID))
                        .font(.system(size: 11))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(palette.surface2Color)
                        .foregroundColor(palette.text2Color)
                        .cornerRadius(4)

                    if isSharedLogin {
                        Text("기존 로그인")
                            .font(.system(size: 11))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(palette.accentColor.opacity(0.12))
                            .foregroundColor(palette.accentColor)
                            .cornerRadius(4)
                    }
                }

                HStack(spacing: 6) {
                    if isCLIMode {
                        Text(isCLIUnsupported ? "웹 전용 · CLI 모드에서 사용할 수 없음" : "CLI 모드")
                            .font(.system(size: 11))
                            .foregroundColor(palette.mutedColor)
                    } else {
                        Text(statusDescription)
                            .font(.system(size: 11))
                            .foregroundColor(connectionState == .authenticated ? palette.accentColor : palette.mutedColor)
                    }

                    if isBusy {
                        Text("작업 중")
                            .font(.system(size: 11))
                            .foregroundColor(palette.accentColor)
                    }
                }
            }

            Spacer()

            if !isCLIMode {
                Button("로그인") {
                    onLogin()
                }
                .font(.system(size: 12))
                .disabled(isLoginDisabled)
            }

            Button("삭제") {
                onRemove()
            }
            .font(.system(size: 12))
            .foregroundColor(palette.dangerColor)
        }
        .padding(8)
        .background(palette.bgColor)
        .cornerRadius(6)
    }
}

// MARK: - CLI Account Mapping View (CLI mode only)

@MainActor
private struct SAWCLIAccountMappingView: View {
    let workers: [SAWTeamWorker]
    let isRunning: Bool
    let busyWorkerIDs: Set<UUID>
    let onSet: (SAWTeamWorker, String?) -> Void

    @Environment(\.bkPalette) private var palette

    private var cliWorkers: [SAWTeamWorker] {
        workers.filter { ["chatgpt", "claude", "gemini"].contains($0.providerID.lowercased()) }
    }

    var body: some View {
        if !cliWorkers.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("CLI 계정 (선택)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(palette.textColor)
                Text("기본은 자동 선택입니다. 지정한 계정은 사용 전에 연결 확인이 필요하며, 목록에 있다고 로그인된 것은 아닙니다.")
                    .font(.system(size: 11))
                    .foregroundColor(palette.mutedColor)

                ForEach(cliWorkers) { worker in
                    SAWCLIAccountPickerRow(
                        worker: worker,
                        isLocked: isRunning || busyWorkerIDs.contains(worker.id),
                        onSet: { onSet(worker, $0) }
                    )
                }
            }
        }
    }
}

@MainActor
private struct SAWCLIAccountPickerRow: View {
    let worker: SAWTeamWorker
    let isLocked: Bool
    let onSet: (String?) -> Void

    @Environment(\.bkPalette) private var palette

    private var name: String {
        if let n = worker.displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty {
            return n
        }
        return friendlyProviderLabel(for: worker.providerID)
    }

    var body: some View {
        let accounts = SAWCLIAccounts.discover(providerID: worker.providerID.lowercased())
        let saved = worker.cliAccountID
        let savedMissing = saved != nil && !accounts.contains(where: { $0.id == saved })

        HStack(spacing: 8) {
            Text(name)
                .font(.system(size: 12))
                .foregroundColor(palette.text2Color)
            Spacer()
            Picker("CLI 계정", selection: Binding<String?>(
                get: { worker.cliAccountID },
                set: { onSet($0) }
            )) {
                Text("자동").tag(Optional<String>.none)
                ForEach(accounts) { acc in
                    Text(acc.label).tag(Optional<String>.some(acc.id))
                }
                if savedMissing, let saved = saved {
                    Text("저장된 계정 (사용 불가)").tag(Optional<String>.some(saved))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 220)
            .disabled(isLocked)
        }
    }
}

// MARK: - Add Worker Form View

@MainActor
private struct SAWAddWorkerFormView: View {
    let onAdd: (String, String, Bool, (String) -> Void) -> Void

    @Environment(\.bkPalette) private var palette

    @State private var selectedProviderID: String = "gemini"
    @State private var inputDisplayName: String = ""
    @State private var useExistingLogin: Bool = true
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("새 팀원 추가")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(palette.textColor)

            HStack(spacing: 12) {
                Picker("제공자", selection: $selectedProviderID) {
                    ForEach(allowedProviders) { provider in
                        Text(provider.name).tag(provider.id)
                    }
                }
                .pickerStyle(.menu)

                TextField("이름 (선택)", text: $inputDisplayName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13))

                Toggle("기존 로그인 사용", isOn: $useExistingLogin)
                    .font(.system(size: 12))
                    .toggleStyle(.checkbox)

                Button("추가") {
                    errorMessage = nil
                    onAdd(selectedProviderID, inputDisplayName, useExistingLogin) { error in
                        errorMessage = error
                    }
                    if errorMessage == nil {
                        inputDisplayName = ""
                    }
                }
                .font(.system(size: 13))
            }

            if let error = errorMessage {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundColor(palette.dangerColor)
            }
        }
    }
}

// MARK: - Exa Common Search Tool Section

@MainActor
private struct SAWExaToolSectionView: View {
    @Environment(\.bkPalette) private var palette

    @State private var credentialStatusKnown: Bool = false
    @State private var isConfigured: Bool = false
    @State private var inputKey: String = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("웹 검색 (Exa)")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(palette.textColor)
                Spacer()
                if !credentialStatusKnown {
                    Text("설정확인필요")
                        .font(.system(size: 11))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(palette.surface2Color)
                        .foregroundColor(palette.mutedColor)
                        .cornerRadius(4)
                } else if isConfigured {
                    Text("개인 API 키 사용 중")
                        .font(.system(size: 11))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(palette.accentColor.opacity(0.15))
                        .foregroundColor(palette.accentColor)
                        .cornerRadius(4)
                } else {
                    Text("기본 검색 (무료 모드)")
                        .font(.system(size: 11))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(palette.surface2Color)
                        .foregroundColor(palette.mutedColor)
                        .cornerRadius(4)
                }
            }

            Text("Exa 검색은 기본 무료 모드로 작동하며 별도의 팀원 등록이 필요하지 않습니다. 개인 API 키를 등록하려면 아래에 입력하세요.")
                .font(.system(size: 12))
                .foregroundColor(palette.mutedColor)

            HStack(spacing: 8) {
                SecureField("개인 Exa API 키 (선택 사항)", text: $inputKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13))

                Button("저장") {
                    saveKey()
                }
                .font(.system(size: 12))
                .disabled(inputKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if credentialStatusKnown && isConfigured {
                    Button("삭제") {
                        removeKey()
                    }
                    .font(.system(size: 12))
                    .foregroundColor(palette.dangerColor)
                }
            }

            if let error = errorMessage {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundColor(palette.dangerColor)
            }
        }
        .padding(12)
        .background(palette.cardColor)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(palette.borderColor, lineWidth: 1)
        )
        .onAppear {
            refreshStatus()
        }
        .onDisappear {
            inputKey = ""
        }
    }

    private func refreshStatus() {
        do {
            isConfigured = try SAWExaCredentialStore.isConfigured()
            credentialStatusKnown = true
            errorMessage = nil
        } catch {
            credentialStatusKnown = false
            errorMessage = "Exa 설정 상태를 확인할 수 없습니다."
        }
    }

    private func saveKey() {
        let key = inputKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        do {
            try SAWExaCredentialStore.save(key)
            inputKey = ""
        } catch {
            errorMessage = "API 키 저장에 실패했습니다."
            return
        }
        refreshStatus()
    }

    private func removeKey() {
        do {
            try SAWExaCredentialStore.remove()
            inputKey = ""
        } catch {
            errorMessage = "API 키 삭제에 실패했습니다."
            return
        }
        refreshStatus()
    }
}
