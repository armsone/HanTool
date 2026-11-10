import Foundation
import WebKit

@MainActor
final class SAWTeamBrowserWorker {
    static func run(
        assignment: SAWTeamAssignment,
        worker: SAWTeamWorker,
        tab: LoginBrowserModel,
        transport: WebPageAgentTransport?,
        cliTransport: SAWCLITransport? = nil,
        hanaAdapter: SAWHanaTeamAdapter?,
        service: AIService,
        originalGoal: String,
        trustedInstructions: @escaping () -> String,
        isCurrent: @escaping () -> Bool,
        onStatus: @escaping (String) -> Void
    ) async -> SAWTeamResult {
        func hasCapability(_ cap: SAWTeamCapability) -> Bool {
            worker.capabilities.contains(cap) && assignment.permissions.contains(cap)
        }

        func checkAuthority() -> Bool {
            guard !Task.isCancelled else { return false }
            guard isCurrent() else { return false }
            guard assignment.status == .running else { return false }
            guard assignment.workerID == worker.id else { return false }
            guard assignment.ownedTabIDs.contains(tab.tabID) else { return false }
            guard tab.sawProjectID == assignment.projectID else { return false }
            guard hasCapability(.read) else { return false }
            return true
        }

        func makeResult(summary: String, sourceURLs: [String] = [], error: String?) -> SAWTeamResult {
            var finalError = error
            if !checkAuthority() {
                finalError = "결과 반환 전 권한 검증에 실패했습니다 (취소되었거나 유효하지 않은 배정/소유권)."
            }
            return SAWTeamResult(
                id: UUID(),
                assignmentID: assignment.id,
                projectID: assignment.projectID,
                runID: assignment.runID,
                workerID: assignment.workerID,
                generation: assignment.generation,
                requestID: assignment.requestID,
                summary: summary,
                sourceURLs: sourceURLs,
                error: finalError
            )
        }

        guard assignment.status == .running else {
            return makeResult(summary: "", error: "배정 상태가 실행 중이 아닙니다 (현재: \(assignment.status.rawValue))")
        }

        guard hasCapability(.read) else {
            return makeResult(summary: "", error: "브라우저 관찰에 필요한 읽기 권한(.read)이 없습니다.")
        }

        guard checkAuthority() else {
            return makeResult(summary: "", error: "초기 권한 검증에 실패했습니다.")
        }

        var currentStep: Int = 1
        var successfulActionsCount: Int = 0
        var observedURLs: [String] = []
        var recentFeedback: String = ""

        onStatus("브라우저 워커 시작됨")

        while true {
            guard checkAuthority() else {
                return makeResult(summary: "", error: "\(currentStep)단계 시작 시 권한이 취소되었거나 유효하지 않습니다.")
            }

            let snapshotWebView = tab.webView
            let activeSnapshot: WebPageAgentSnapshot
            let snapshotSucceeded: Bool

            if let currentWV = snapshotWebView {
                onStatus("\(currentStep)단계: 페이지 관찰 중...")
                let snapResult = await WebPageAgentBridge.captureSnapshot(webView: currentWV)

                guard checkAuthority() else {
                    return makeResult(summary: "", error: "\(currentStep)단계 스냅샷 캡처 후 권한이 취소되었습니다.")
                }

                if tab.webView !== snapshotWebView {
                    recentFeedback = "페이지 관찰 중 웹뷰가 변경되었습니다. 다시 관찰합니다."
                    continue
                }

                let currentURL = tab.currentURL ?? currentWV.url
                let isHomeBlank = currentURL == nil || currentURL?.absoluteString.isEmpty == true || currentURL?.absoluteString == "about:blank"

                if isHomeBlank {
                    snapshotSucceeded = false
                    switch snapResult {
                    case .success(let snap):
                        if snap.url.isEmpty || snap.url == "about:blank" {
                            activeSnapshot = WebPageAgentSnapshot(
                                documentToken: snap.documentToken.isEmpty ? "blank" : snap.documentToken,
                                snapshotId: snap.snapshotId.isEmpty ? UUID().uuidString : snap.snapshotId,
                                url: "about:blank",
                                title: "빈 홈 페이지",
                                text: "",
                                isTruncated: false,
                                interactives: [],
                                capturedAt: Date()
                            )
                        } else {
                            activeSnapshot = snap
                        }
                    case .failure:
                        activeSnapshot = WebPageAgentSnapshot(
                            documentToken: "blank",
                            snapshotId: UUID().uuidString,
                            url: "about:blank",
                            title: "빈 홈 페이지",
                            text: "",
                            isTruncated: false,
                            interactives: [],
                            capturedAt: Date()
                        )
                    }
                } else {
                    switch snapResult {
                    case .success(let snap):
                        snapshotSucceeded = true
                        activeSnapshot = snap
                    case .failure(let err):
                        snapshotSucceeded = false
                        recentFeedback = "페이지 스냅샷 캡처 실패: \(err)"
                        activeSnapshot = WebPageAgentSnapshot(
                            documentToken: "",
                            snapshotId: UUID().uuidString,
                            url: currentURL?.absoluteString ?? "",
                            title: "캡처 오류",
                            text: "스냅샷 캡처 실패: \(err)",
                            isTruncated: false,
                            interactives: [],
                            capturedAt: Date()
                        )
                    }
                }
            } else {
                snapshotSucceeded = false
                activeSnapshot = WebPageAgentSnapshot(
                    documentToken: "blank",
                    snapshotId: UUID().uuidString,
                    url: "about:blank",
                    title: "빈 홈 페이지",
                    text: "",
                    isTruncated: false,
                    interactives: [],
                    capturedAt: Date()
                )
            }

            let currentTrustedInstructions = trustedInstructions()

            var contextSections: [String] = []
            contextSections.append("위임된 하위 작업: \(assignment.goal)")
            contextSections.append("정책: 위임받은 읽기 전용 브라우저 워커입니다. 공개 http(s) URL에 대한 읽기, 스크롤, 탐색만 가능합니다. 클릭, 텍스트 입력, 선택, 탭 관리 등 변경 작업은 제한됩니다. 빈 홈 페이지인 경우 승인된 공개 웹 URL로 탐색할 수 있습니다.")
            if !recentFeedback.isEmpty {
                contextSections.append("최근 피드백:\n\(recentFeedback)")
            }
            let contextText = contextSections.joined(separator: "\n\n")

            onStatus("\(currentStep)단계: 다음 작업 요청 중...")

            let actionResult: WebPageAgentResult<WebPageAgentAction>
            if let cli = cliTransport {
                actionResult = await cli.requestNextAction(
                    service: service,
                    snapshot: activeSnapshot,
                    userGoal: originalGoal,
                    currentStep: currentStep,
                    maxSteps: Int.max,
                    contextText: contextText,
                    trustedInstructions: currentTrustedInstructions,
                    allowedProviderIDs: [worker.providerID],
                    allowedAccountIDs: worker.cliAccountID.map { Set([$0]) },
                    isCurrent: { checkAuthority() && tab.webView === snapshotWebView },
                    onRemainingSecondsUpdate: { _ in },
                    onStatus: onStatus
                )
            } else if service.isHana {
                guard let adapter = hanaAdapter else {
                    return makeResult(summary: "", error: "Hana 서비스를 위한 어댑터가 누락되었습니다.")
                }
                actionResult = await adapter.requestNextAction(
                    snapshot: activeSnapshot,
                    userGoal: originalGoal,
                    currentStep: currentStep,
                    maxSteps: Int.max,
                    contextText: contextText,
                    trustedInstructions: currentTrustedInstructions,
                    isCurrent: { checkAuthority() && tab.webView === snapshotWebView },
                    onRemainingSecondsUpdate: { _ in }
                )
            } else {
                guard let trans = transport else {
                    return makeResult(summary: "", error: "AI 서비스를 위한 전송 객체(transport)가 누락되었습니다.")
                }
                actionResult = await trans.requestNextAction(
                    service: service,
                    snapshot: activeSnapshot,
                    userGoal: originalGoal,
                    currentStep: currentStep,
                    maxSteps: Int.max,
                    contextText: contextText,
                    trustedInstructions: currentTrustedInstructions,
                    isCurrent: { checkAuthority() && tab.webView === snapshotWebView },
                    onRemainingSecondsUpdate: { _ in }
                )
            }

            guard checkAuthority() else {
                return makeResult(summary: "", error: "\(currentStep)단계 작업 요청 후 권한이 취소되었습니다.")
            }

            if tab.webView !== snapshotWebView {
                recentFeedback = "모델 응답 대기 중 웹뷰가 변경되었습니다. 새 페이지를 다시 관찰합니다."
                if currentStep < Int.max { currentStep += 1 }
                continue
            }

            let nextAction: WebPageAgentAction
            switch actionResult {
            case .success(let act):
                nextAction = act
            case .failure(let err):
                // CLI_WAIT는 이미 transport의 제한된 대기 이후 반환된 값이므로 추가 루프 없이
                // CLI_RETRY 등과 같이 호스트 오류 문자열 그대로 Runtime에 반환해 인계 대상으로 삼는다.
                return makeResult(summary: "", error: "모델의 다음 작업 요청에 실패했습니다: \(err)")
            }

            switch nextAction.action {
            case .navigate, .openTab:
                guard hasCapability(.read) && hasCapability(.navigate) else {
                    guard checkAuthority() else {
                        return makeResult(summary: "", error: "\(nextAction.action.rawValue) 권한 확인 중 권한이 취소되었습니다.")
                    }
                    var urls = observedURLs
                    if snapshotSucceeded {
                        let sanitizedCurrent = sanitizeSourceURL(activeSnapshot.url)
                        if !sanitizedCurrent.isEmpty && !urls.contains(sanitizedCurrent) {
                            urls.append(sanitizedCurrent)
                        }
                    }
                    let reasonMsg = nextAction.reason ?? nextAction.message ?? "탐색 권한 필요"
                    return makeResult(
                        summary: "이 작업은 담당 플레너가 현재 페이지에서 이어서 처리해야 합니다: \(reasonMsg) (작업: \(nextAction.action.rawValue))",
                        sourceURLs: urls,
                        error: "coordinatorRequired:\(nextAction.action.rawValue)"
                    )
                }

                guard let rawURL = nextAction.url?.trimmingCharacters(in: .whitespacesAndNewlines),
                      let targetURL = URL(string: rawURL),
                      let scheme = targetURL.scheme?.lowercased(),
                      (scheme == "http" || scheme == "https"),
                      let host = targetURL.host, !host.isEmpty,
                      targetURL.user == nil, targetURL.password == nil else {
                    recentFeedback = "탐색 차단: URL은 사용자 정보/비밀번호가 없는 유효한 http(s) URL이어야 합니다."
                    break
                }

                guard checkAuthority() else {
                    return makeResult(summary: "", error: "탐색 전 권한이 취소되었거나 유효하지 않습니다.")
                }

                guard tab.webView === snapshotWebView else {
                    recentFeedback = "탐색 실행 전 웹뷰가 변경되었습니다. 새 페이지를 다시 관찰합니다."
                    break
                }

                let beforeWV = snapshotWebView
                let beforeToken = activeSnapshot.documentToken
                let beforeWasNilOrHome = (beforeWV == nil) || activeSnapshot.url.isEmpty || activeSnapshot.url == "about:blank"

                let sanitizedTarget = sanitizeSourceURL(targetURL.absoluteString)
                let displayTarget = !sanitizedTarget.isEmpty ? sanitizedTarget : host
                onStatus("\(displayTarget) (으)로 이동 중...")

                tab.open(targetURL.absoluteString)

                let maxWaitNanoseconds: UInt64 = 30_000_000_000
                let intervalNanoseconds: UInt64 = 200_000_000
                var elapsedNanoseconds: UInt64 = 0

                try? await Task.sleep(nanoseconds: intervalNanoseconds)
                elapsedNanoseconds += intervalNanoseconds

                while elapsedNanoseconds < maxWaitNanoseconds {
                    guard checkAuthority() else {
                        return makeResult(summary: "", error: "탐색 대기 중 권한이 취소되었습니다.")
                    }
                    if let err = tab.lastError, !err.isEmpty {
                        break
                    }
                    if let candidateWV = tab.webView, !candidateWV.isLoading {
                        break
                    }
                    try? await Task.sleep(nanoseconds: intervalNanoseconds)
                    elapsedNanoseconds += intervalNanoseconds
                }

                guard checkAuthority() else {
                    return makeResult(summary: "", error: "탐색 완료 대기 후 권한이 취소되었습니다.")
                }

                if let err = tab.lastError, !err.isEmpty {
                    recentFeedback = "탐색 실패 (오류: \(err))."
                    break
                }

                guard let candidateWV = tab.webView else {
                    recentFeedback = "탐색 후 웹뷰가 준비되지 않았습니다."
                    break
                }

                if candidateWV.isLoading {
                    recentFeedback = "30초 내에 페이지 로딩이 완료되지 않았습니다 (\(displayTarget))."
                    break
                }

                let captureWV = candidateWV
                let postNavSnapResult = await WebPageAgentBridge.captureSnapshot(webView: captureWV)

                guard checkAuthority() else {
                    return makeResult(summary: "", error: "포스트 탐색 스냅샷 캡처 후 권한이 취소되었습니다.")
                }

                guard tab.webView === captureWV else {
                    recentFeedback = "스냅샷 캡처 도중 웹뷰가 변경되었습니다. 새 페이지를 다시 관찰합니다."
                    break
                }

                switch postNavSnapResult {
                case .success(let postSnap):
                    guard !captureWV.isLoading else {
                        recentFeedback = "스냅샷 캡처 후 웹뷰가 여전히 로딩 중입니다."
                        break
                    }

                    guard let loadedURL = URL(string: postSnap.url),
                          let s = loadedURL.scheme?.lowercased(),
                          (s == "http" || s == "https"),
                          let h = loadedURL.host, !h.isEmpty else {
                        recentFeedback = "탐색 완료된 페이지의 URL이 유효한 http(s) 형식이 아닙니다."
                        break
                    }

                    guard !postSnap.documentToken.isEmpty, !postSnap.snapshotId.isEmpty else {
                        recentFeedback = "탐색 후 캡처된 스냅샷 토큰이 비어 있습니다."
                        break
                    }

                    let tokenChanged = (postSnap.documentToken != beforeToken)
                    let wvIdentityChanged = (captureWV !== beforeWV)
                    let isProvenNew = beforeWasNilOrHome || wvIdentityChanged || (snapshotSucceeded && tokenChanged)

                    guard isProvenNew else {
                        recentFeedback = "페이지 이동이 확인되지 않았습니다 (토큰 및 웹뷰 동일 유지)."
                        break
                    }

                    guard captureWV.url?.absoluteString == postSnap.url else {
                        recentFeedback = "현재 웹뷰 페이지와 캡처된 스냅샷의 URL이 일치하지 않습니다."
                        break
                    }

                    successfulActionsCount += 1
                    let sanitizedPost = sanitizeSourceURL(postSnap.url)
                    if !sanitizedPost.isEmpty && !observedURLs.contains(sanitizedPost) {
                        observedURLs.append(sanitizedPost)
                    }
                    let displayPost = !sanitizedPost.isEmpty ? sanitizedPost : h
                    recentFeedback = "\(displayPost) (으)로 이동 완료 (제목: \(postSnap.title))."

                case .failure(let err):
                    recentFeedback = "탐색 로드는 완료되었으나 스냅샷 캡처에 실패했습니다: \(err)"
                }

            case .read:
                guard hasCapability(.read) else {
                    recentFeedback = "읽기 권한이 없습니다 (.read 필요)."
                    break
                }
                guard checkAuthority() else {
                    return makeResult(summary: "", error: "읽기 전 권한이 취소되었습니다.")
                }
                guard let currentWV = tab.webView, currentWV === snapshotWebView else {
                    recentFeedback = "페이지가 변경되어 이전 스냅샷을 읽을 수 없습니다. 다시 관찰합니다."
                    break
                }
                guard snapshotSucceeded,
                      !activeSnapshot.documentToken.isEmpty,
                      !activeSnapshot.snapshotId.isEmpty,
                      let currentHTTPURL = URL(string: activeSnapshot.url),
                      let s = currentHTTPURL.scheme?.lowercased(),
                      (s == "http" || s == "https"),
                      let h = currentHTTPURL.host, !h.isEmpty else {
                    let sanitizedRead = sanitizeSourceURL(activeSnapshot.url)
                    let displayRead = !sanitizedRead.isEmpty ? sanitizedRead : (URL(string: activeSnapshot.url)?.host ?? "미지정")
                    recentFeedback = "유효한 http(s) 웹 페이지의 스냅샷만 읽을 수 있습니다 (\(displayRead)). 빈 홈 페이지는 읽을 수 없습니다."
                    break
                }

                successfulActionsCount += 1
                let sanitized = sanitizeSourceURL(activeSnapshot.url)
                if !sanitized.isEmpty && !observedURLs.contains(sanitized) {
                    observedURLs.append(sanitized)
                }
                let displayRead = !sanitized.isEmpty ? sanitized : h
                recentFeedback = "페이지 읽기 완료: \(displayRead) (제목: \(activeSnapshot.title), 글자 수: \(activeSnapshot.text.count))"

            case .scroll:
                guard hasCapability(.read) else {
                    recentFeedback = "스크롤 권한이 없습니다 (.read 필요)."
                    break
                }
                guard checkAuthority() else {
                    return makeResult(summary: "", error: "스크롤 전 권한이 취소되었습니다.")
                }
                guard let currentWV = tab.webView, currentWV === snapshotWebView else {
                    recentFeedback = "페이지가 변경되어 이전 스냅샷에 대해 스크롤을 실행할 수 없습니다. 다시 관찰합니다."
                    break
                }
                guard snapshotSucceeded,
                      !activeSnapshot.documentToken.isEmpty,
                      !activeSnapshot.snapshotId.isEmpty,
                      let scrollURL = URL(string: activeSnapshot.url),
                      let s = scrollURL.scheme?.lowercased(),
                      (s == "http" || s == "https"),
                      let h = scrollURL.host, !h.isEmpty else {
                    let sanitizedScroll = sanitizeSourceURL(activeSnapshot.url)
                    let displayScroll = !sanitizedScroll.isEmpty ? sanitizedScroll : (URL(string: activeSnapshot.url)?.host ?? "미지정")
                    recentFeedback = "유효한 http(s) 웹 페이지의 스냅샷에서만 스크롤할 수 있습니다 (\(displayScroll))."
                    break
                }

                onStatus("페이지 스크롤 중...")
                let scrollResult = await WebPageAgentBridge.executeAction(
                    webView: currentWV,
                    documentToken: activeSnapshot.documentToken,
                    snapshotId: activeSnapshot.snapshotId,
                    action: nextAction,
                    isCurrent: { checkAuthority() && tab.webView === snapshotWebView }
                )

                guard checkAuthority() else {
                    return makeResult(summary: "", error: "스크롤 후 권한이 취소되었습니다.")
                }
                guard tab.webView === snapshotWebView else {
                    recentFeedback = "스크롤 도중 웹뷰가 변경되었습니다. 새 페이지를 다시 관찰합니다."
                    break
                }

                switch scrollResult {
                case .success:
                    successfulActionsCount += 1
                    let sanitized = sanitizeSourceURL(activeSnapshot.url)
                    if !sanitized.isEmpty && !observedURLs.contains(sanitized) {
                        observedURLs.append(sanitized)
                    }
                    recentFeedback = "페이지 스크롤 완료."
                case .failure(let err):
                    recentFeedback = "스크롤 실패: \(err)"
                }

            case .done:
                if successfulActionsCount < 1 {
                    recentFeedback = "완료 불가: 최소 1회 이상의 실제 브라우저 작업(탐색, 읽기, 스크롤)이 성공해야 작업을 완료할 수 있습니다."
                    break
                }
                guard checkAuthority() else {
                    return makeResult(summary: "", error: "작업 완료 전 권한이 취소되었습니다.")
                }

                let rawSummary = nextAction.summary?.trimmingCharacters(in: .whitespacesAndNewlines)
                let rawResult = nextAction.result?.trimmingCharacters(in: .whitespacesAndNewlines)
                let finalSummary: String
                if let s = rawSummary, !s.isEmpty {
                    finalSummary = s
                } else if let r = rawResult, !r.isEmpty {
                    finalSummary = r
                } else {
                    finalSummary = "\(successfulActionsCount)개의 브라우저 작업을 완료했습니다 (관찰된 페이지 \(observedURLs.count)개)."
                }

                var deduplicatedURLs: [String] = []
                for u in observedURLs {
                    if !deduplicatedURLs.contains(u) {
                        deduplicatedURLs.append(u)
                    }
                }

                onStatus("작업 완료")
                return makeResult(
                    summary: finalSummary,
                    sourceURLs: deduplicatedURLs,
                    error: nil
                )

            case .needsUser:
                guard checkAuthority() else {
                    return makeResult(summary: "", error: "needsUser 전 권한이 취소되었습니다.")
                }

                var urls = observedURLs
                if snapshotSucceeded {
                    let sanitizedCurrent = sanitizeSourceURL(activeSnapshot.url)
                    if !sanitizedCurrent.isEmpty && !urls.contains(sanitizedCurrent) {
                        urls.append(sanitizedCurrent)
                    }
                }

                let rawReason = nextAction.reason ?? nextAction.message ?? "사유 미지정"
                var hasRealHumanEvidence = false

                if snapshotSucceeded {
                    let lowerText = activeSnapshot.text.lowercased()
                    let textKeywords = ["captcha", "recaptcha", "인증 코드", "인증번호", "일회용", "2단계 인증", "2-factor", "verification code"]
                    let hasKeywordMatch = textKeywords.contains { lowerText.contains($0) }

                    var hasInteractiveAuth = false
                    for interactive in activeSnapshot.interactives {
                        if interactive.type.lowercased() == "password" {
                            let label = interactive.name.lowercased()
                            let id = interactive.id.lowercased()
                            let combined = "\(label) \(id) \(lowerText)"
                            if combined.contains("login") || combined.contains("signin") || combined.contains("sign in") || combined.contains("로그인") {
                                hasInteractiveAuth = true
                                break
                            }
                        }
                    }

                    let reasonLower = rawReason.lowercased()
                    let modelAligns = textKeywords.contains { reasonLower.contains($0) } ||
                                      reasonLower.contains("login") || reasonLower.contains("로그인") ||
                                      reasonLower.contains("인증") || reasonLower.contains("auth") ||
                                      reasonLower.contains("비밀번호") || reasonLower.contains("password")

                    if (hasKeywordMatch || hasInteractiveAuth) && modelAligns {
                        hasRealHumanEvidence = true
                    }
                }

                if hasRealHumanEvidence {
                    onStatus("워커 일시 정지: 실제 사용자 인증/개입 필요")
                    return makeResult(
                        summary: "실제 페이지 확인됨: 사용자 개입 필요 (사유: \(rawReason))",
                        sourceURLs: urls,
                        error: "humanRequired:\(rawReason)"
                    )
                } else {
                    onStatus("워커 작업 반환: 코디네이터 처리 필요 (needsUser)")
                    return makeResult(
                        summary: "이 작업은 담당 플레너가 현재 페이지에서 이어서 처리해야 합니다: 모델 요청 사유(미확인): \(rawReason) (작업: needsUser)",
                        sourceURLs: urls,
                        error: "coordinatorRequired:needsUser"
                    )
                }

            case .click, .fill, .select, .saveDocument, .remember, .switchTab, .closeTab, .runTool:
                guard checkAuthority() else {
                    return makeResult(summary: "", error: "\(nextAction.action.rawValue) 전달 전 권한이 취소되었습니다.")
                }
                var urls = observedURLs
                if snapshotSucceeded {
                    let sanitizedCurrent = sanitizeSourceURL(activeSnapshot.url)
                    if !sanitizedCurrent.isEmpty && !urls.contains(sanitizedCurrent) {
                        urls.append(sanitizedCurrent)
                    }
                }
                let actionReason = nextAction.reason ?? nextAction.message ?? "상태 변경 또는 탭 관리 작업"
                return makeResult(
                    summary: "이 작업은 담당 플레너가 현재 페이지에서 이어서 처리해야 합니다: \(actionReason) (작업: \(nextAction.action.rawValue))",
                    sourceURLs: urls,
                    error: "coordinatorRequired:\(nextAction.action.rawValue)"
                )
            }

            if currentStep < Int.max {
                currentStep += 1
            }
        }
    }

    private static func sanitizeSourceURL(_ rawURL: String) -> String {
        guard let url = URL(string: rawURL),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: true),
              let scheme = components.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              let host = components.host, !host.isEmpty else {
            return ""
        }

        components.user = nil
        components.password = nil
        components.fragment = nil

        if let queryItems = components.queryItems, !queryItems.isEmpty {
            let sensitiveKeys: Set<String> = [
                "token", "access_token", "auth", "authorization",
                "password", "passwd", "key", "api_key", "apikey",
                "code", "secret", "session", "sessionid", "id_token", "refresh_token"
            ]
            let filteredItems = queryItems.filter { item in
                !sensitiveKeys.contains(item.name.lowercased())
            }
            components.queryItems = filteredItems.isEmpty ? nil : filteredItems
        }

        return components.url?.absoluteString ?? ""
    }
}
