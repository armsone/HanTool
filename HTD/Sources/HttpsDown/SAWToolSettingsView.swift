import SwiftUI
import AppKit

private struct SAWToolSettingsError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Lets discovery code (possibly on another thread) ask "may I still run?" without touching UI objects.
private final class SAWDiscoveryGate: @unchecked Sendable {
    private let lock = NSLock()
    private var open = true
    var isOpen: Bool { lock.lock(); defer { lock.unlock() }; return open }
    func close() { lock.lock(); open = false; lock.unlock() }
}

/// Project-specific tool registration sheet. Opening, editing and closing never start work or send anything to an AI.
@MainActor
struct SAWToolSettingsView: View {
    @ObservedObject var workspace: SAWWorkspace
    @ObservedObject var session: SAWProjectSession
    @Environment(\.bkPalette) private var palette
    @Environment(\.dismiss) private var dismiss
    @StateObject private var discoveryRuntime = SAWToolRuntime()

    @State private var draft: SAWToolConfiguration
    @State private var original: SAWToolConfiguration
    @State private var errorMessage = ""

    @State private var cmdName = ""
    @State private var cmdExec = ""
    @State private var cmdArgs = "[]"
    @State private var cmdEnv = ""
    @State private var srvName = ""
    @State private var srvExec = ""
    @State private var srvArgs = "[]"
    @State private var srvEnv = ""

    @State private var discoveryGate: SAWDiscoveryGate?
    @State private var discoveryTask: Task<Void, Never>?
    @State private var discoveringID: UUID?
    @State private var discoveryStatus = ""
    @State private var serverErrors: [UUID: String] = [:]

    init(workspace: SAWWorkspace, session: SAWProjectSession) {
        self.workspace = workspace
        self.session = session
        let initial = session.project?.toolConfiguration ?? SAWToolConfiguration()
        _draft = State(initialValue: initial)
        _original = State(initialValue: initial)
    }

    private var isRunning: Bool { session.runStatus == "running" }
    private var isOwner: Bool { workspace.selectedProjectID == session.projectID && session.project != nil }
    private var canEdit: Bool { !isRunning && isOwner }
    private var trimmedWorkspace: String { draft.workspaceDirectory.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 10) {
                    introSection
                    if isRunning { notice("실행 중에는 도구 설정을 바꿀 수 없습니다. 먼저 일시정지해 주세요. 자동으로 다시 시작되지 않습니다.") }
                    if !isOwner { notice("이 프로젝트가 현재 선택된 프로젝트가 아니어서 편집할 수 없습니다.") }
                    workspaceSection
                    skillSection
                    commandSection
                    serverSection
                }
                .padding(12)
                .disabled(!canEdit)
            }
            Divider()
            footer
        }
        .frame(width: 640, height: 650)
        .background(palette.cardColor)
        .onDisappear { cancelDiscovery() }
        .onChange(of: workspace.selectedProjectID) { _ in cancelDiscovery() }
        .onChange(of: session.runStatus) { _ in if isRunning { cancelDiscovery() } }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack {
            Text("도구 연결 설정")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(palette.textColor)
            Spacer()
            Button { close() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .accessibilityLabel("닫기")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.system(size: 12))
                    .foregroundColor(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text(draft == original ? "변경 사항 없음" : "저장하지 않은 변경 사항이 있습니다")
                    .font(.system(size: 12))
                    .foregroundColor(palette.textColor.opacity(0.7))
                Spacer()
                Button("취소") { close() }
                    .keyboardShortcut(.cancelAction)
                Button("저장") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canEdit || draft == original)
            }
        }
        .padding(12)
    }

    private var introSection: some View {
        card("안내") {
            Text("이 프로젝트에서 직접 등록·선택한 항목만 앱이 실행합니다. 등록은 이 프로젝트에 대한 허가로 한 번만 적용되며 도구 호출마다 다시 묻지 않습니다. 선택한 입력은 읽기 전용이고, 결과는 작업 폴더의 .HTT-Planner 아래 새 출력 폴더에만 기록됩니다. 등록한 고정 명령과 허용한 도구 외에는 실행되지 않으며 네트워크는 차단됩니다. 설정을 열고 닫는 것만으로는 아무 작업도 시작되지 않고 스킬이나 데이터가 AI로 전송되지 않습니다.")
                .font(.system(size: 12))
                .foregroundColor(palette.textColor.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 1. Workspace

    private var workspaceSection: some View {
        card("1 작업 폴더") {
            HStack(spacing: 6) {
                TextField("/절대/경로/작업폴더", text: $draft.workspaceDirectory)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                Button("폴더 선택") {
                    if let url = choose(files: false, message: "작업 폴더를 선택하세요") { draft.workspaceDirectory = url.path }
                }
            }
            hint("자동으로 찾거나 만들지 않습니다. 홈 폴더 전체, 시스템 폴더, 인증 정보 폴더는 사용할 수 없습니다. 폴더가 필요한 도구를 실제로 실행할 때 확인합니다.")
        }
    }

    // MARK: - 2. Skills

    private var skillSection: some View {
        card("2 스킬 (최대 4개)") {
            ForEach(draft.skillFiles, id: \.self) { file in
                HStack {
                    Text(skillLabel(file))
                        .font(.system(size: 12))
                        .foregroundColor(palette.textColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(file)
                    Spacer()
                    Button("제거") { draft.skillFiles.removeAll { $0 == file } }
                        .controlSize(.small)
                }
            }
            Button("SKILL.md 추가") { addSkill() }
                .controlSize(.small)
                .disabled(draft.skillFiles.count >= 4)
            hint("직접 고른 SKILL.md 파일만 낮은 우선순위의 참고 지침으로 쓰이며 권한이나 실행 파일을 주지 않습니다. 같은 폴더의 다른 파일은 읽지 않습니다. 제거는 설정에서만 빼며 파일은 지우지 않습니다.")
        }
    }

    private func skillLabel(_ file: String) -> String {
        let parent = ((file as NSString).deletingLastPathComponent as NSString).lastPathComponent
        return "\((file as NSString).lastPathComponent) · \(parent)"
    }

    private func addSkill() {
        errorMessage = ""
        guard let url = choose(files: true, message: "SKILL.md 파일을 선택하세요") else { return }
        guard url.lastPathComponent == "SKILL.md" else { errorMessage = "파일 이름이 SKILL.md인 파일만 추가할 수 있습니다."; return }
        guard !draft.skillFiles.contains(url.path) else { return }
        draft.skillFiles.append(url.path)
    }

    // MARK: - 3. Commands

    private var commandSection: some View {
        card("3 터미널 도구") {
            ForEach(draft.commands) { command in
                registrationRow(title: command.name, executable: command.executable, arguments: command.arguments) {
                    draft.commands.removeAll { $0.id == command.id }
                }
            }
            registrationForm(name: $cmdName, exec: $cmdExec, args: $cmdArgs, env: $cmdEnv, button: "터미널 도구 추가") { addCommand() }
            hint("인자는 JSON 배열로 고정합니다. 예: [\"-I\",\"/작업폴더/audit.py\",\"/작업폴더/input.csv\"]. 인자 전체를 \"{{키}}\" 형태로 쓰면 계획 단계에서 문자열 값만 받습니다. 실행 파일·옵션·스크립트는 변수가 될 수 없고 sh -c, python -c는 등록할 수 없습니다. 환경 변수에는 비밀 값을 넣지 마세요. 추가해도 실행되지 않으며, 수정은 제거 후 다시 추가합니다.")
        }
    }

    private func addCommand() {
        errorMessage = ""
        do {
            let v = try validatedRegistration(name: cmdName, exec: cmdExec, args: cmdArgs, env: cmdEnv)
            draft.commands.append(SAWRegisteredCommand(name: v.name, executable: v.exec, arguments: v.args, environment: v.env))
            cmdName = ""; cmdExec = ""; cmdArgs = "[]"; cmdEnv = ""
        } catch { errorMessage = error.localizedDescription }
    }

    // MARK: - 4. MCP servers

    private var serverSection: some View {
        card("4 MCP 서버 (stdio)") {
            ForEach(draft.mcpServers) { server in
                serverBlock(server)
            }
            registrationForm(name: $srvName, exec: $srvExec, args: $srvArgs, env: $srvEnv, button: "MCP 서버 추가") { addServer() }
            hint("stdio로 실행되는 서버만 지원하며 네트워크는 차단됩니다. 모든 MCP 서버가 동작한다는 뜻은 아닙니다. '도구 찾기'는 서버를 실제로 한 번 실행해 목록을 가져오며, 허용할 도구는 직접 체크한 것만 쓰입니다(기본 없음). 서버가 알려주는 설명은 신뢰할 수 없는 정보입니다. 서버 설정을 바꾸려면 제거 후 다시 추가하세요.")
        }
    }

    private func addServer() {
        errorMessage = ""
        do {
            let v = try validatedRegistration(name: srvName, exec: srvExec, args: srvArgs, env: srvEnv)
            draft.mcpServers.append(SAWMCPServer(name: v.name, executable: v.exec, arguments: v.args, environment: v.env, tools: [], allowedToolNames: []))
            srvName = ""; srvExec = ""; srvArgs = "[]"; srvEnv = ""
        } catch { errorMessage = error.localizedDescription }
    }

    private func serverBlock(_ server: SAWMCPServer) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            registrationRow(title: server.name, executable: server.executable, arguments: server.arguments) {
                if discoveringID == server.id { cancelDiscovery() }
                serverErrors[server.id] = nil
                draft.mcpServers.removeAll { $0.id == server.id }
            }
            HStack(spacing: 6) {
                Button(discoveringID == server.id ? "찾는 중…" : "도구 찾기") { discover(server.id) }
                    .controlSize(.small)
                    .disabled(!canEdit || discoveringID != nil)
                if discoveringID == server.id {
                    ProgressView().controlSize(.small)
                    Text(discoveryStatus)
                        .font(.system(size: 12))
                        .foregroundColor(palette.textColor.opacity(0.7))
                        .lineLimit(1)
                }
            }
            if let message = serverErrors[server.id] {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundColor(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if server.tools.isEmpty {
                hint("아직 가져온 도구가 없습니다. 허용된 도구가 없으면 이 서버는 실행되지 않습니다.")
            }
            ForEach(server.tools) { tool in
                Toggle(isOn: allowBinding(server.id, tool.name)) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(tool.name).font(.system(size: 12, weight: .bold))
                        if !tool.toolDescription.isEmpty {
                            Text("서버 설명(신뢰할 수 없음): " + SAWBoundedText.clip(tool.toolDescription, limit: 160).text)
                                .font(.system(size: 11))
                                .foregroundColor(palette.textColor.opacity(0.65))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .toggleStyle(.checkbox)
                .disabled(!SAWMCPStdioClient.isValidToolName(tool.name))
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(palette.surface2Color))
    }

    private func allowBinding(_ serverID: UUID, _ tool: String) -> Binding<Bool> {
        Binding(
            get: { draft.mcpServers.first { $0.id == serverID }?.allowedToolNames.contains(tool) ?? false },
            set: { on in
                guard let i = draft.mcpServers.firstIndex(where: { $0.id == serverID }) else { return }
                var names = draft.mcpServers[i].allowedToolNames.filter { $0 != tool }
                if on { names.append(tool) }
                draft.mcpServers[i].allowedToolNames = names
            }
        )
    }

    // MARK: - Discovery

    private func discover(_ id: UUID) {
        errorMessage = ""
        guard canEdit, discoveringID == nil, !discoveryRuntime.running,
              let server = draft.mcpServers.first(where: { $0.id == id }) else { return }
        guard !trimmedWorkspace.isEmpty else {
            serverErrors[id] = "도구를 찾으려면 먼저 작업 폴더를 지정하세요."
            return
        }
        var config = draft
        config.workspaceDirectory = trimmedWorkspace
        let projectID = session.projectID
        let gate = SAWDiscoveryGate()
        discoveryGate = gate
        discoveringID = id
        discoveryStatus = ""
        serverErrors[id] = nil
        discoveryTask = Task { @MainActor in
            var found: [SAWMCPTool]?
            var failure = ""
            do {
                found = try await discoveryRuntime.listMCPTools(
                    server: server, configuration: config, projectID: projectID,
                    isCurrent: { gate.isOpen },
                    onStatus: { message in if gate.isOpen { discoveryStatus = message } })
            } catch {
                failure = (error as? SAWMCPClientError)?.message ?? error.localizedDescription
            }
            guard gate.isOpen, discoveryGate === gate, canEdit, session.projectID == projectID else { return }
            discoveringID = nil
            discoveryStatus = ""
            if let tools = found {
                applyDiscovered(tools, to: server)
            } else {
                serverErrors[id] = failure.isEmpty ? "도구 목록을 가져오지 못했습니다." : failure
            }
        }
    }

    private func applyDiscovered(_ tools: [SAWMCPTool], to server: SAWMCPServer) {
        guard let i = draft.mcpServers.firstIndex(where: { $0.id == server.id && $0.executable == server.executable && $0.arguments == server.arguments }) else { return }
        // An allowance survives only if the same tool came back with an identical definition.
        let keep = draft.mcpServers[i].allowedToolNames.filter { name in
            draft.mcpServers[i].tools.first { $0.name == name } == tools.first { $0.name == name }
        }
        draft.mcpServers[i].tools = tools
        draft.mcpServers[i].allowedToolNames = keep
        if tools.isEmpty { serverErrors[server.id] = "서버가 도구를 하나도 알려주지 않았습니다." }
    }

    /// Stops only this sheet's own discovery runtime; the project's tool runtime is never touched.
    private func cancelDiscovery() {
        discoveryGate?.close()
        discoveryGate = nil
        discoveryTask?.cancel()
        discoveryTask = nil
        discoveryRuntime.cancelAll()
        discoveringID = nil
        discoveryStatus = ""
    }

    // MARK: - Save / close

    private func close() {
        cancelDiscovery()
        dismiss()
    }

    private func save() {
        errorMessage = ""
        guard canEdit else { errorMessage = "지금은 저장할 수 없습니다. 실행 중이면 먼저 일시정지해 주세요."; return }
        var next = draft
        next.workspaceDirectory = trimmedWorkspace
        do {
            if !next.commands.isEmpty || !next.mcpServers.isEmpty {
                _ = try SAWToolScope.approvedRoot(configuration: next)
            }
            _ = try SAWToolScope.loadSkills(configuration: next)
            for server in next.mcpServers {
                let known = Set(server.tools.map(\.name))
                guard server.allowedToolNames.allSatisfy({ known.contains($0) }) else {
                    throw SAWToolSettingsError("'\(server.name)'에 허용된 도구가 목록에 없습니다. 도구를 다시 찾아 주세요.")
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        guard next != original else { close(); return }
        session.setToolConfiguration(next)
        guard (session.project?.toolConfiguration ?? SAWToolConfiguration()) == next else {
            errorMessage = "설정을 저장하지 못했습니다. 실행 중이거나 프로젝트가 바뀌었는지 확인해 주세요."
            return
        }
        original = next
        close()
    }

    // MARK: - Validation

    private func validatedRegistration(name: String, exec: String, args: String, env: String) throws -> (name: String, exec: String, args: [String], env: [String: String]) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let exec = exec.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf16.count <= 80 else { throw SAWToolSettingsError("이름은 1~80자로 입력하세요.") }
        guard exec.hasPrefix("/") else { throw SAWToolSettingsError("실행 파일은 '파일 선택'으로 고르거나 절대 경로로 입력하세요.") }
        let argText = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let argData = (argText.isEmpty ? "[]" : argText).data(using: .utf8),
              let arguments = try? JSONDecoder().decode([String].self, from: argData) else {
            throw SAWToolSettingsError("고정 인자는 문자열 JSON 배열이어야 합니다. 예: [\"-I\",\"/작업폴더/audit.py\"]")
        }
        guard arguments.count <= 32, arguments.allSatisfy({ $0.utf8.count <= 4096 }) else {
            throw SAWToolSettingsError("인자는 최대 32개, 각 4096바이트까지 허용됩니다.")
        }
        guard !arguments.contains("-c") else { throw SAWToolSettingsError("-c 인라인 코드 실행은 등록할 수 없습니다.") }
        for argument in arguments where argument.contains("{{") || argument.contains("}}") {
            guard argument.range(of: "^\\{\\{[A-Za-z0-9_]{1,40}\\}\\}$", options: .regularExpression) != nil else {
                throw SAWToolSettingsError("변수는 인자 전체가 \"{{키}}\" 형태여야 합니다.")
            }
        }
        let envText = env.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let envData = (envText.isEmpty ? "{}" : envText).data(using: .utf8),
              let environment = try? JSONDecoder().decode([String: String].self, from: envData) else {
            throw SAWToolSettingsError("환경 변수는 문자열 값만 가진 JSON 객체여야 합니다. 예: {\"LANG\":\"ko_KR.UTF-8\"}")
        }
        guard environment.count <= 16 else { throw SAWToolSettingsError("환경 변수는 최대 16개까지 허용됩니다.") }
        return (name, exec, arguments, environment)
    }

    // MARK: - Small building blocks

    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(palette.textColor)
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(palette.surface2Color))
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundColor(palette.textColor.opacity(0.7))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func notice(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundColor(palette.textColor)
            .fixedSize(horizontal: false, vertical: true)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(palette.accentSoftColor))
    }

    private func registrationRow(title: String, executable: String, arguments: [String], remove: @escaping () -> Void) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(title) · \((executable as NSString).lastPathComponent)")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(palette.textColor)
                Text(arguments.isEmpty ? "(고정 인자 없음)" : SAWBoundedText.clip(arguments.joined(separator: " "), limit: 300).text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(palette.textColor.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("제거", action: remove)
                .controlSize(.small)
        }
    }

    private func registrationForm(name: Binding<String>, exec: Binding<String>, args: Binding<String>, env: Binding<String>, button: String, add: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("이름", text: name)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
            HStack(spacing: 6) {
                TextField("실행 파일 절대 경로", text: exec)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                Button("파일 선택") {
                    if let url = choose(files: true, message: "실행 파일을 선택하세요") { exec.wrappedValue = url.path }
                }
            }
            jsonEditor("고정 인자 (JSON 배열)", text: args)
            jsonEditor("환경 변수 (선택, 문자열 JSON 객체, 비밀 값 금지)", text: env)
            Button(button, action: add)
                .controlSize(.small)
        }
    }

    private func jsonEditor(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(palette.textColor.opacity(0.7))
            TextEditor(text: text)
                .font(.system(size: 12, design: .monospaced))
                .frame(height: 44)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(palette.textColor.opacity(0.2)))
        }
    }

    /// Plain AppKit picker; no default location, no sandbox bookmarks. The returned path is kept exactly as selected.
    private func choose(files: Bool, message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.message = message
        panel.canChooseFiles = files
        panel.canChooseDirectories = !files
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}
