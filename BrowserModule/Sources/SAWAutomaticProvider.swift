import Foundation
import WebKit

@MainActor
final class SAWAutomaticProvider {
    struct Choice {
        let service: AIService
        let dataStore: WKWebsiteDataStore
        let key: String
        let label: String
    }

    static let preservedDraftReason: String = "작성 중인 사용자 입력 내용이 보존되었습니다. 입력을 완료하거나 내용을 지운 후 다시 진행해 주세요."
    private var excludedProfiles: Set<String> = []
    private var exclusionRunID: UUID?
    private(set) var waitReason: String = "로그인된 AI를 확인하고 있습니다. 설정에서 로그인하면 자동으로 이어집니다."
    private static var providerCooldowns: [String: Date] = [:]
    private static var profileCooldowns: [String: Date] = [:]
    private static var positiveAuthCache: [String: Date] = [:]
    private static let zeroUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    private var profileStores: [String: WKWebsiteDataStore] = [:]

    func choose(
        workspace: SAWWorkspace,
        project: SAWProject,
        isCurrent: @escaping () -> Bool,
        onStatus: (String) -> Void
    ) async -> Choice? {
        guard isCurrent() && !Task.isCancelled else { return nil }

        let runID = workspace.existingSession(for: project.id)?.teamRunID
        if exclusionRunID != runID {
            exclusionRunID = runID
            excludedProfiles.removeAll()
        }
        waitReason = "로그인된 AI를 확인하고 있습니다. 설정에서 로그인하면 자동으로 이어집니다."

        var excludedDraftCount = 0
        var busyCount = 0

        let supportedIDs: Set<String> = ["chatgpt", "claude", "gemini"]
        let allowedServices = CuratedAIServices.all.filter { supportedIDs.contains($0.id) }
        let serviceMap = Dictionary(uniqueKeysWithValues: allowedServices.map { ($0.id, $0) })

        var candidates: [Choice] = []
        var seenKeys: Set<String> = []

        func addCandidate(service: AIService, worker: SAWTeamWorker?) {
            let shared = workspace.appModel.store(for: service)
            let store: WKWebsiteDataStore
            if let uuid = worker?.websiteDataStoreID, uuid != Self.zeroUUID {
                let cacheKey = "\(service.id):\(uuid.uuidString)"
                let custom: WKWebsiteDataStore
                if let cached = profileStores[cacheKey] {
                    custom = cached
                } else {
                    custom = WKWebsiteDataStore(forIdentifier: uuid)
                    profileStores[cacheKey] = custom
                }
                custom.proxyConfigurations = shared.proxyConfigurations
                store = custom
            } else {
                store = shared
            }

            let storeKey = store.identifier?.uuidString ?? "default"
            let key = "\(service.id):\(storeKey)"
            guard seenKeys.insert(key).inserted else { return }

            let trimmedName = worker?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let label: String
            if let name = trimmedName, !name.isEmpty {
                label = "\(service.name) \(name)"
            } else {
                label = "\(service.name) 기존 로그인"
            }
            candidates.append(Choice(service: service, dataStore: store, key: key, label: label))
        }

        if let workers = project.team?.workers {
            for worker in workers where supportedIDs.contains(worker.providerID) {
                if let service = serviceMap[worker.providerID] {
                    addCandidate(service: service, worker: worker)
                }
            }
        }

        for proj in workspace.store.projects {
            if let workers = proj.team?.workers {
                for worker in workers where supportedIDs.contains(worker.providerID) {
                    if let service = serviceMap[worker.providerID] {
                        addCandidate(service: service, worker: worker)
                    }
                }
            }
        }

        for service in allowedServices {
            addCandidate(service: service, worker: nil)
        }

        candidates.sort { $0.service.id == project.providerID && $1.service.id != project.providerID }
        for candidate in candidates {
            guard isCurrent() && !Task.isCancelled else { return nil }

            if excludedProfiles.contains(candidate.key) {
                excludedDraftCount += 1
                continue
            }

            let now = Date()
            if let providerCool = Self.providerCooldowns[candidate.service.id], providerCool > now {
                continue
            }
            if let profileCool = Self.profileCooldowns[candidate.key], profileCool > now {
                continue
            }

            guard WebPageAgentTransport.isProviderProfileAvailable(provider: candidate.service.id, dataStore: candidate.dataStore) else {
                busyCount += 1
                continue
            }

            if let cachedAt = Self.positiveAuthCache[candidate.key], now.timeIntervalSince(cachedAt) < 60 {
                return candidate
            }

            onStatus("\(candidate.label) 로그인 확인 중...")

            var probeResult: AILoginStatus? = nil
            let probe = AILoginProbeSession(service: candidate.service, store: candidate.dataStore) { status in
                probeResult = status
            }
            probe.start()

            let probeStart = Date()
            while isCurrent() && !Task.isCancelled && probeResult == nil && Date().timeIntervalSince(probeStart) < 16 {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            probe.cancel()

            guard isCurrent() && !Task.isCancelled else { return nil }

            guard WebPageAgentTransport.isProviderProfileAvailable(provider: candidate.service.id, dataStore: candidate.dataStore) else {
                busyCount += 1
                continue
            }

            if probeResult == .loggedIn {
                Self.positiveAuthCache[candidate.key] = Date()
                return candidate
            } else {
                Self.positiveAuthCache.removeValue(forKey: candidate.key)
                Self.profileCooldowns[candidate.key] = Date().addingTimeInterval(15)
            }
        }

        if excludedDraftCount > 0 {
            waitReason = "작성 중인 입력이 있는 계정은 그대로 두고, 다른 로그인 계정을 기다립니다."
            if busyCount > 0 {
                waitReason += " 다른 업무에서 사용 중인 계정도 건너뛰었습니다."
            }
        } else if busyCount > 0 {
            waitReason = "다른 업무에서 사용 중인 AI 계정을 건너뛰고, 사용 가능한 계정을 기다립니다."
        }

        return nil
    }

    func recover(
        _ choice: Choice,
        reason: String,
        webView: WKWebView?,
        isCurrent: @escaping () -> Bool
    ) async -> Bool {
        guard isCurrent() && !Task.isCancelled else { return false }
        if reason == Self.preservedDraftReason {
            excludedProfiles.insert(choice.key)
            return true
        }
        Self.positiveAuthCache.removeValue(forKey: choice.key)

        let lowerReason = reason.lowercased()
        if reason.hasPrefix("작업 목표가 허용 한도(") || reason.hasPrefix("프롬프트 크기가 전송 한도(") {
            return false
        }
        let unrecoverableTokens = [
            "보안", "captcha", "권한", "접근제한", "접근 제한", "정책", "안전", "초안", "draft", "permission", "access denied", "unauthorized", "forbidden", "policy", "safety", "refusal", "restricted"
        ]
        for token in unrecoverableTokens {
            if lowerReason.contains(token) {
                return false
            }
        }

        var domTag: String? = nil
        if let webView = webView,
           let webHost = webView.url?.host?.lowercased(),
           let expectedHost = URL(string: choice.service.homeURL)?.host?.lowercased(),
           webHost == expectedHost {
            let script = """
            (() => {
                const sel = "[role=alert], [data-testid*='limit'], [data-testid*='quota']";
                const els = document.querySelectorAll(sel);
                for (const el of els) {
                    if (!el || el.offsetParent === null) continue;
                    const txt = (el.innerText || el.textContent || '').toLowerCase();
                    if (/safety|access denied|captcha|보안|권한|접근제한/.test(txt)) return 'restricted';
                    if (/rate limit|too many requests|usage limit|message limit|사용량 한도|메시지 한도|try again later/.test(txt)) return 'capacity';
                }
                return '';
            })()
            """
            var evalDone = false
            webView.evaluateJavaScript(script) { result, _ in
                domTag = result as? String
                evalDone = true
            }
            let scanStart = Date()
            while isCurrent() && !Task.isCancelled && !evalDone && Date().timeIntervalSince(scanStart) < 2.0 {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }

        guard isCurrent() && !Task.isCancelled else { return false }

        if domTag == "restricted" {
            return false
        } else if domTag == "capacity" {
            Self.providerCooldowns[choice.service.id] = Date().addingTimeInterval(300)
            return true
        } else if reason == "AI 프롬프트 전송에 실패했습니다." || reason == "AI 응답 생성이 시작되지 않았습니다." {
            return false
        } else {
            Self.providerCooldowns[choice.service.id] = Date().addingTimeInterval(30)
            return true
        }
    }
}

