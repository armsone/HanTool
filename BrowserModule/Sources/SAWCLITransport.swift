import Foundation
import Combine
import Darwin

@MainActor
final class SAWCLITransport {
    enum CLIReadiness: Equatable {
        case ready(label: String)
        case unavailable(reason: String)
    }

    private var activeGenerationEpoch: Int = 0
    private var activeHandle: EngineTaskHandle?
    private static var lastSuccessfulAccount: [String: SAWCLIAccount] = [:]
    private static var cooldownByPrincipal: [String: Date] = [:]
    private static var cooldownByID: [String: Date] = [:]

    init() {}

    static func readiness(for providerID: String) -> CLIReadiness {
        let candidates = SAWCLIAccounts.discover(providerID: providerID)
        guard !candidates.isEmpty else {
            let name = providerDisplayName(providerID)
            return .unavailable(reason: "연결 가능한 \(name) CLI 계정이 없습니다.")
        }
        let label = "\(providerDisplayName(providerID)) CLI · 연결 확인 전"
        return .ready(label: label)
    }

    private static func providerDisplayName(_ providerID: String) -> String {
        switch providerID {
        case "chatgpt": return "Codex"
        case "claude": return "Claude"
        case "gemini": return "Gemini"
        default: return providerID.capitalized
        }
    }

    func cancelActiveGeneration() {
        activeGenerationEpoch += 1
        activeHandle?.cancel()
        activeHandle = nil
    }

    func requestNextAction(
        service: AIService,
        snapshot: WebPageAgentSnapshot,
        userGoal: String,
        currentStep: Int,
        maxSteps: Int,
        contextText: String = "",
        trustedInstructions: String = "",
        allowedProviderIDs: [String] = [],
        allowedAccountIDs: Set<String>? = nil,
        isCurrent: @escaping () -> Bool,
        onRemainingSecondsUpdate: @escaping (Int) -> Void,
        onStatus: @escaping (String) -> Void = { _ in }
    ) async -> WebPageAgentResult<WebPageAgentAction> {
        guard userGoal.utf16.count <= 10_000 else {
            return .failure("사용자 목표가 최대 길이(10,000자)를 초과했습니다.")
        }

        let fullPrompt = WebPageAgentTransport.formatSystemAndUserPrompt(
            snapshot: snapshot,
            userGoal: userGoal,
            currentStep: currentStep,
            maxSteps: maxSteps,
            contextText: contextText,
            trustedInstructions: trustedInstructions
        )
        guard fullPrompt.utf16.count <= 49_000 else {
            return .failure("생성된 프롬프트가 최대 크(49,000자)를 초과했습니다.")
        }

        let targetProviderIDs = allowedProviderIDs.isEmpty ? [service.id] : allowedProviderIDs
        let validProviders = ["chatgpt", "claude", "gemini"]
        let enabledProviders = targetProviderIDs.filter { validProviders.contains($0) }
        guard !enabledProviders.isEmpty else {
            return .failure("CLI_POLICY:AI 연결 정책에 따라 이 요청을 진행하지 못했습니다.")
        }

        let deadline = Date().addingTimeInterval(119.0)
        let capturedEpoch = activeGenerationEpoch

        func isCancelled() -> Bool {
            return !isCurrent() || Task.isCancelled || self.activeGenerationEpoch != capturedEpoch
        }

        var attemptedAccountIDs = Set<String>()
        var hadAuthFailure = false
        var hadRetryFailure = false

        while Date() < deadline {
            if isCancelled() {
                return .failure("작업이 취소되었습니다.")
            }

            let remaining = max(0, Int(deadline.timeIntervalSinceNow))
            onRemainingSecondsUpdate(remaining)

            var candidateAccounts: [SAWCLIAccount] = []
            for pid in enabledProviders {
                let discovered = SAWCLIAccounts.discover(providerID: pid)
                let preferred = Self.lastSuccessfulAccount[pid]
                for acc in discovered {
                    if let allowedIDs = allowedAccountIDs, !allowedIDs.contains(acc.id) { continue }
                    if acc.id == preferred?.id {
                        candidateAccounts.insert(acc, at: 0)
                    } else {
                        candidateAccounts.append(acc)
                    }
                }
            }

            if allowedAccountIDs != nil && candidateAccounts.isEmpty {
                return .failure("CLI_UNAVAILABLE:지정한 CLI 계정을 찾을 수 없습니다.")
            }

            let now = Date()
            var eligibleAccounts: [SAWCLIAccount] = []
            var allInCooldown = true

            for acc in candidateAccounts {
                if attemptedAccountIDs.contains(acc.id) { continue }
                if let authUntil = Self.cooldownByID[acc.id], authUntil > now { continue }
                let pKey = acc.principalKey.isEmpty ? "\(acc.providerID):unverified" : acc.principalKey
                if let rateUntil = Self.cooldownByPrincipal[pKey], rateUntil > now { continue }
                allInCooldown = false
                eligibleAccounts.append(acc)
            }

            if eligibleAccounts.isEmpty {
                if hadRetryFailure {
                    return .failure("CLI_RETRY:AI 연결이 일시적으로 중단되어 다시 시도합니다.")
                }
                if hadAuthFailure && attemptedAccountIDs.count == candidateAccounts.count && !candidateAccounts.isEmpty {
                    return .failure("CLI 로그인이 필요합니다. 연결된 계정 상태를 확인해 주세요.")
                }
                if allInCooldown && Date() < deadline {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    continue
                }
                return .failure("CLI_WAIT:사용 가능한 계정을 기다리는 중입니다.")
            }

            var selectedAccount: SAWCLIAccount?
            var selectedLease: SAWCLIAccountLease?

            for acc in eligibleAccounts {
                if let lease = SAWCLIAccounts.acquire(acc) {
                    selectedAccount = acc
                    selectedLease = lease
                    break
                }
            }

            guard let account = selectedAccount, let lease = selectedLease else {
                onStatus("CLI 계정이 사용 중이어서 기다립니다.")
                try? await Task.sleep(nanoseconds: 250_000_000)
                continue
            }

            attemptedAccountIDs.insert(account.id)

            let attemptResult = await withTaskCancellationHandler {
                await executeAttempt(
                    account: account,
                    lease: lease,
                    fullPrompt: fullPrompt,
                    snapshotID: snapshot.snapshotId,
                    capturedEpoch: capturedEpoch,
                    deadline: deadline,
                    isCancelled: isCancelled,
                    onStatus: onStatus
                )
            } onCancel: {
                Task { @MainActor [weak self] in
                    guard let self = self, capturedEpoch == self.activeGenerationEpoch else { return }
                    self.activeHandle?.cancel()
                }
            }

            guard !isCancelled() else {
                return .failure("작업이 취소되었습니다.")
            }

            switch attemptResult {
            case .success(let action):
                Self.lastSuccessfulAccount[account.providerID] = account
                onStatus("\(account.label) CLI 연결 확인")
                return .success(action)
            case .policyViolation:
                return .failure("CLI_POLICY:AI 연결 정책에 따라 이 요청을 진행하지 못했습니다.")
            case .cancelled:
                return .failure("작업이 취소되었습니다.")
            case .authFailed:
                hadAuthFailure = true
                Self.cooldownByID[account.id] = Date().addingTimeInterval(60.0)
                onStatus("\(account.label) 인증 실패로 다른 계정을 시도합니다.")
                continue
            case .rateLimited:
                let pKey = account.principalKey.isEmpty ? "\(account.providerID):unverified" : account.principalKey
                Self.cooldownByPrincipal[pKey] = Date().addingTimeInterval(60.0)
                onStatus("\(account.label) 사용량 한도로 다른 계정을 시도합니다.")
                continue
            case .busyRetry:
                onStatus("CLI 계정이 사용 중이어서 기다립니다.")
                try? await Task.sleep(nanoseconds: 250_000_000)
                continue
            case .retryLater:
                hadRetryFailure = true
                Self.cooldownByID[account.id] = Date().addingTimeInterval(60.0)
                onStatus("\(account.label) 일시적 지연으로 다른 계정을 시도합니다.")
                continue
            case .failedNoRetry:
                return .failure("CLI 응답을 처리하지 못했습니다.")
            }
        }

        if hadRetryFailure {
            return .failure("CLI_RETRY:AI 연결이 일시적으로 중단되어 다시 시도합니다.")
        }
        if hadAuthFailure {
            return .failure("CLI 로그인이 필요합니다. 연결된 계정 상태를 확인해 주세요.")
        }
        return .failure("CLI_WAIT:사용 가능한 계정을 기다리는 중입니다.")
    }

    private enum AttemptOutcome {
        case success(WebPageAgentAction)
        case policyViolation
        case cancelled
        case authFailed
        case rateLimited
        case busyRetry
        case retryLater
        case failedNoRetry
    }

    private func executeAttempt(
        account: SAWCLIAccount,
        lease: SAWCLIAccountLease,
        fullPrompt: String,
        snapshotID: String,
        capturedEpoch: Int,
        deadline: Date,
        isCancelled: @escaping () -> Bool,
        onStatus: @escaping (String) -> Void
    ) async -> AttemptOutcome {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("saw-cli-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        defer {
            try? FileManager.default.removeItem(at: tempDir)
            lease.release()
        }

        var executable = ""
        var arguments: [String] = []
        var stdinData: Data? = nil
        var keepStdinOpen = false

        let fm = FileManager.default

        switch account.providerID {
        case "claude":
            executable = fm.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/claude").path
            guard fm.isExecutableFile(atPath: executable) else { return .failedNoRetry }
            arguments = [
                "--print",
                "--tools", "",
                "--strict-mcp-config",
                "--mcp-config", "{\"mcpServers\":{}}",
                "--safe-mode",
                "--disable-slash-commands",
                "--no-session-persistence",
                "--output-format", "json",
                "--permission-mode", "dontAsk",
                "--max-turns", "1"
            ]
            stdinData = fullPrompt.data(using: .utf8)
            keepStdinOpen = false

        case "chatgpt":
            let nodeCandidates = ["/opt/homebrew/opt/node/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
            guard let nodePath = nodeCandidates.first(where: { fm.isExecutableFile(atPath: $0) }) else { return .failedNoRetry }
            let codexCandidates = [
                "/opt/homebrew/lib/node_modules/@openai/codex/bin/codex.js",
                "/usr/local/lib/node_modules/@openai/codex/bin/codex.js"
            ]
            guard let codexScript = codexCandidates.first(where: { fm.fileExists(atPath: $0) }) else { return .failedNoRetry }

            executable = nodePath
            arguments = [
                codexScript, "exec",
                "--ignore-user-config",
                "--ignore-rules",
                "--ephemeral",
                "--skip-git-repo-check",
                "--sandbox", "read-only",
                "--json",
                "--color", "never",
                "-c", "approval_policy=\"never\"",
                "-c", "web_search=\"disabled\"",
                "-c", "project_doc_max_bytes=0",
                "-"
            ]
            let disabledTools = [
                "shell_tool", "unified_exec", "view_image", "apps", "plugins", "remote_plugin",
                "hooks", "multi_agent", "browser_use", "browser_use_external",
                "browser_use_full_cdp_access", "computer_use", "in_app_browser", "code_mode",
                "code_mode_host", "code_mode_tool_search", "image_generation", "skill_search", "tool_suggest"
            ]
            for tool in disabledTools {
                arguments.append("--disable")
                arguments.append(tool)
            }
            stdinData = fullPrompt.data(using: .utf8)
            keepStdinOpen = false

        case "gemini":
            let agyBin = fm.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/agy").path
            guard fm.isExecutableFile(atPath: agyBin) else { return .failedNoRetry }

            let agentsDir = tempDir.appendingPathComponent(".agents/agents")
            try? fm.createDirectory(at: agentsDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let agentFile = agentsDir.appendingPathComponent("htt-planner.md")
            let agentDoc = """
            ---
            name: htt-planner
            description: Reasoning only
            tools: []
            mcpServers: []
            skills: []
            plugins: []
            commandExecutionPolicy: off
            mainAgent: true
            subagent: false
            ---
            Return only Action JSON. No tools.
            """
            try? agentDoc.write(to: agentFile, atomically: true, encoding: .utf8)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: agentFile.path)

            var agyArgs = [
                "--agent", "htt-planner",
                "--settings", "{\"toolPermission\":\"strict\",\"allowNonWorkspaceAccess\":false,\"permissions\":{\"deny\":[\"read_file(*)\",\"write_file(*)\",\"read_url(*)\",\"execute_url(*)\",\"command(*)\",\"unsandboxed(*)\",\"mcp(*)\"]}}",
                "--input-format", "stream-json",
                "--output-format", "stream-json",
                "--mode", "plan",
                "--sandbox",
                "--disable-slash-commands",
                "--print-timeout", "119s"
            ]

            if !account.isDefault {
                agyArgs.removeAll { $0 == "--sandbox" }
                let sandboxExec = "/usr/bin/sandbox-exec"
                guard fm.isExecutableFile(atPath: sandboxExec) else {
                    return .failedNoRetry
                }
                let mainHome = fm.homeDirectoryForCurrentUser.path
                let profile = """
                (version 1)
                (allow default)
                (deny mach-lookup (global-name "com.apple.securityd") (global-name "com.apple.secd"))
                (deny process-exec (literal "/usr/bin/security"))
                (deny file-read* file-write* (subpath "\(mainHome)/.gemini") (subpath "\(mainHome)/Library/Keychains"))
                """
                executable = sandboxExec
                arguments = ["-p", profile, agyBin] + agyArgs
            } else {
                executable = agyBin
                arguments = agyArgs
            }
            stdinData = nil
            keepStdinOpen = true

        default:
            return .failedNoRetry
        }

        if isCancelled() { return .cancelled }

        let env = account.environment(base: ProcessInfo.processInfo.environment)
        let timeoutSeconds = max(1.0, deadline.timeIntervalSinceNow)

        var stdoutBuffer = ""
        var stderrBuffer = ""
        var policyViolation = false

        let runResult: (taskResult: EngineTaskResult, out: String, err: String, isPolicy: Bool) = await withCheckedContinuation { continuation in
            var resumed = false
            var taskHandle: EngineTaskHandle?

            func finishOnce(res: EngineTaskResult, out: String, err: String, pol: Bool) {
                if !resumed {
                    resumed = true
                    continuation.resume(returning: (res, out, err, pol))
                }
            }

            let handle = EngineBridge.shared.launch(
                jobId: "cli-\(UUID().uuidString)",
                generation: capturedEpoch,
                executable: executable,
                arguments: arguments,
                environment: env,
                workingDirectory: tempDir.path,
                inheritedFileDescriptors: lease.fileDescriptors,
                onDiagnosticLine: { diag in
                    DispatchQueue.main.async {
                        if stderrBuffer.utf8.count < 65536 {
                            stderrBuffer.append(diag + "\n")
                        }
                    }
                },
                stdinData: stdinData,
                timeout: timeoutSeconds,
                keepStdinOpen: keepStdinOpen,
                onLine: { line in
                    DispatchQueue.main.async {
                        if stdoutBuffer.utf8.count + line.utf8.count > 1_048_576 {
                            policyViolation = true
                            taskHandle?.cancel()
                            return
                        }
                        stdoutBuffer.append(line + "\n")

                        if account.providerID == "gemini" {
                            if let data = line.data(using: .utf8),
                               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                               let event = json["event"] as? String {
                                if event == "init" {
                                    if let initObj = json["init"] as? [String: Any],
                                       let permissionMode = initObj["permission_mode"] as? String, permissionMode == "strict",
                                       let agentName = initObj["agent"] as? String, agentName.contains("htt-planner") {
                                        if let pData = try? JSONSerialization.data(withJSONObject: [
                                            "event": "user",
                                            "message": ["content": fullPrompt]
                                        ]) {
                                            _ = taskHandle?.sendLine(pData)
                                            taskHandle?.closeStdin()
                                        }
                                    } else {
                                        policyViolation = true
                                        taskHandle?.cancel()
                                    }
                                } else if event == "step" || event == "step_update" {
                                    var hasToolUsage = json["tool_calls"] != nil || json["tool_call"] != nil
                                    if let stepUpdate = json["step_update"] as? [String: Any] {
                                        if let stepType = stepUpdate["step_type"] as? String {
                                            let normalized = stepType.lowercased()
                                            if normalized == "tool" || normalized == "tool_call" || normalized == "tool_execution" || normalized == "tool_use" {
                                                hasToolUsage = true
                                            }
                                        }
                                        if stepUpdate["tool_calls"] != nil || stepUpdate["tool_call"] != nil {
                                            hasToolUsage = true
                                        }
                                    }
                                    if hasToolUsage {
                                        policyViolation = true
                                        taskHandle?.cancel()
                                    }
                                }
                            }
                        } else if account.providerID == "chatgpt" {
                            let forbidden = [
                                "command_execution", "file_change", "mcp_tool_call", "web_search", "image_view", "collab_tool_call",
                                "commandExecution", "fileChange", "mcpToolCall", "webSearch", "imageView", "collabToolCall"
                            ]
                            if let data = line.data(using: .utf8),
                               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                                let eventType = obj["type"] as? String ?? ""
                                var detectedType: String? = nil
                                if eventType == "item.started" || eventType == "item.completed",
                                   let item = obj["item"] as? [String: Any],
                                   let itemType = item["type"] as? String {
                                    detectedType = itemType
                                } else if forbidden.contains(eventType) {
                                    detectedType = eventType
                                }
                                if let type = detectedType, forbidden.contains(type) {
                                    policyViolation = true
                                    taskHandle?.cancel()
                                }
                            }
                        }
                    }
                },
                onExit: { res in
                    finishOnce(res: res, out: stdoutBuffer, err: stderrBuffer, pol: policyViolation)
                }
            )

            taskHandle = handle
            self.activeHandle = handle

            let monitor = Task {
                while !resumed {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    let shouldCancel = await MainActor.run {
                        return isCancelled() || Date() >= deadline || stdoutBuffer.utf8.count > 1_048_576
                    }
                    if shouldCancel {
                        handle.cancel()
                        break
                    }
                }
            }

            _ = monitor
        }

        if self.activeGenerationEpoch == capturedEpoch {
            self.activeHandle = nil
        }

        guard !isCancelled() else {
            return .cancelled
        }

        if runResult.isPolicy {
            return .policyViolation
        }

        if runResult.taskResult.timedOut || Date() >= deadline {
            return .retryLater
        }

        var candidateOutput = ""
        switch account.providerID {
        case "claude":
            if let data = runResult.out.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let isErr = json["is_error"] as? Bool, isErr {
                    candidateOutput = ""
                } else if let res = json["result"] as? String {
                    candidateOutput = res
                }
            }
        case "chatgpt":
            for line in runResult.out.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                if let type = json["type"] as? String, type == "item.completed",
                   let item = json["item"] as? [String: Any],
                   let itemType = item["type"] as? String, (itemType == "agent_message" || itemType == "text"),
                   let text = item["text"] as? String {
                    candidateOutput = text
                }
            }
        case "gemini":
            for line in runResult.out.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                if let ev = json["event"] as? String, ev == "result",
                   let resObj = json["result"] as? [String: Any] {
                    if let status = resObj["status"] as? String, status == "SUCCESS" {
                        if let resp = resObj["response"] as? String {
                            candidateOutput = resp
                        } else if let structured = resObj["structured_output"] as? [String: Any],
                                  let sData = try? JSONSerialization.data(withJSONObject: structured),
                                  let sStr = String(data: sData, encoding: .utf8) {
                            candidateOutput = sStr
                        }
                    }
                }
            }
        default:
            break
        }

        let isNormalCompletion = runResult.taskResult.groupClean && runResult.taskResult.pipesDrained && !runResult.taskResult.cancelled && !runResult.taskResult.timedOut && runResult.taskResult.exitCode == 0
        if isNormalCompletion && !candidateOutput.isEmpty {
            let parseResult = WebPageAgentTransport.parseActionJSON(candidateOutput, expectedSnapshotID: snapshotID)
            if case .success(let action) = parseResult {
                return .success(action)
            }
        }

        let failureKind = SAWCLIAccounts.classify(
            exitCode: runResult.taskResult.exitCode,
            cancelled: runResult.taskResult.cancelled,
            timedOut: runResult.taskResult.timedOut,
            text: runResult.out + "\n" + runResult.err
        )

        switch failureKind {
        case .cancelled:
            return .cancelled
        case .policy:
            return .policyViolation
        case .authentication:
            return .authFailed
        case .rateLimit:
            return .rateLimited
        case .busy:
            return .busyRetry
        case .runtime:
            return .retryLater
        case .invalidOutput:
            return .retryLater
        }
    }
}
