import Foundation
import WebKit
import Combine
import AppKit

/// In-browser planning adapter using dedicated Hana panel WKWebView.
/// Complies with TransportAPI contract and verified Hana DOM specifications.
@MainActor
final class SAWHanaTeamAdapter: NSObject, ObservableObject {
    @Published private(set) var plannerWebView: WKWebView?
    @Published private(set) var isPlannerLoading: Bool = false

    private var currentRequestGeneration: UInt64 = 0
    private var navigationGeneration: Int = 0
    private var ownInstanceBusy: Bool = false

    // Static profile lease map across adapter instances: serial execution per dataStore profile
    private static var profileLeases: [String: UUID] = [:]

    override init() {
        super.init()
    }

    /// Configures the retained 420x500 WKWebView using the provided websiteDataStore.
    /// Preserves user session and invalidates own state only on change.
    func configurePlanner(dataStore: WKWebsiteDataStore) {
        if let existingWV = plannerWebView {
            if existingWV.configuration.websiteDataStore === dataStore {
                return
            }
            teardownPlanner()
        }

        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        PageAudioController.shared.prepareConfiguration(config)
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 420, height: 500), configuration: config)
        wv.navigationDelegate = self
        self.plannerWebView = wv
        PageAudioController.shared.register(webView: wv, kind: .sawHanaAdapter)
        self.navigationGeneration += 1
        self.isPlannerLoading = true

        wv.load(URLRequest(url: HanaPanelHost.trustedURL))
    }

    /// Requests next typed web action JSON planning from Hana.
    func requestNextAction(
        snapshot: WebPageAgentSnapshot,
        userGoal: String,
        currentStep: Int,
        maxSteps: Int,
        contextText: String = "",
        trustedInstructions: String = "",
        isCurrent: @escaping () -> Bool,
        onRemainingSecondsUpdate: @escaping (Int) -> Void
    ) async -> WebPageAgentResult<WebPageAgentAction> {
        guard !ownInstanceBusy else {
            return .failure("하나 플래너가 이미 다른 요청을 처리 중입니다. 현재 작업이 끝난 뒤 다시 시도해 주세요.")
        }
        guard !Task.isCancelled, isCurrent(), let wv = plannerWebView else {
            return .failure("하나 화면을 사용할 수 없거나 요청이 취소되었습니다.")
        }

        currentRequestGeneration &+= 1
        let requestToken = currentRequestGeneration
        ownInstanceBusy = true

        defer {
            if self.currentRequestGeneration == requestToken {
                self.ownInstanceBusy = false
            }
        }

        let result = await performRequestNextAction(
            snapshot: snapshot,
            userGoal: userGoal,
            currentStep: currentStep,
            maxSteps: maxSteps,
            contextText: contextText,
            trustedInstructions: trustedInstructions,
            isCurrent: isCurrent,
            onRemainingSecondsUpdate: onRemainingSecondsUpdate,
            targetWebView: wv,
            requestToken: requestToken
        )

        guard isCurrentRequest(token: requestToken, targetWebView: wv, callerIsCurrent: isCurrent) else {
            return .failure("결과를 반영하기 전에 페이지가 변경되었거나 요청이 취소되었습니다.")
        }

        return result
    }

    /// Synchronously cancels active generation and allows immediate restart.
    func cancelActiveGeneration() {
        currentRequestGeneration &+= 1
        ownInstanceBusy = false
    }

    /// Tears down retained webView and cancels own active generation.
    func teardownPlanner() {
        cancelActiveGeneration()
        navigationGeneration += 1
        isPlannerLoading = false
        if let wv = plannerWebView {
            wv.stopLoading()
            wv.navigationDelegate = nil
            plannerWebView = nil
        }
    }

    // MARK: - Core Execution

    private func isCurrentRequest(
        token: UInt64,
        targetWebView: WKWebView,
        callerIsCurrent: () -> Bool
    ) -> Bool {
        return !Task.isCancelled &&
               currentRequestGeneration == token &&
               plannerWebView === targetWebView &&
               callerIsCurrent()
    }

    private func isCurrentBound(
        token: UInt64,
        targetWebView: WKWebView,
        boundNavigationGeneration: Int,
        callerIsCurrent: () -> Bool
    ) -> Bool {
        return isCurrentRequest(token: token, targetWebView: targetWebView, callerIsCurrent: callerIsCurrent) &&
               HanaPanelHost.isTrustedAlfredURL(targetWebView.url) &&
               self.navigationGeneration == boundNavigationGeneration
    }

    private func performRequestNextAction(
        snapshot: WebPageAgentSnapshot,
        userGoal: String,
        currentStep: Int,
        maxSteps: Int,
        contextText: String,
        trustedInstructions: String,
        isCurrent: @escaping () -> Bool,
        onRemainingSecondsUpdate: @escaping (Int) -> Void,
        targetWebView: WKWebView,
        requestToken: UInt64
    ) async -> WebPageAgentResult<WebPageAgentAction> {
        guard isCurrentRequest(token: requestToken, targetWebView: targetWebView, callerIsCurrent: isCurrent) else {
            return .failure("작업 시작 전에 페이지가 변경되었거나 요청이 취소되었습니다.")
        }

        // 1. Acquire per-profile lease across adapters
        let store = targetWebView.configuration.websiteDataStore
        let profileKey = Self.profileKey(for: store)
        let leaseToken = UUID()

        let leaseAcquired = await Self.acquireProfileLease(
            key: profileKey,
            token: leaseToken,
            isCurrent: { [weak self] in
                self?.isCurrentRequest(token: requestToken, targetWebView: targetWebView, callerIsCurrent: isCurrent) ?? false
            }
        )
        guard leaseAcquired else {
            return .failure("하나가 다른 요청을 처리 중이거나 작업이 취소되었습니다. 잠시 후 다시 시도해 주세요.")
        }
        defer { Self.releaseProfileLease(key: profileKey, token: leaseToken) }

        guard isCurrentRequest(token: requestToken, targetWebView: targetWebView, callerIsCurrent: isCurrent) else {
            return .failure("작업 준비 도중 페이지가 변경되었거나 요청이 취소되었습니다.")
        }

        // 2. Finite 15s readiness check: positive visible #afRoot, hidden #afLogin, openQuery bridge
        let readinessStart = Date()
        var isReady = false

        let checkScript = """
        (() => {
            const root = document.querySelector('#afRoot');
            const login = document.querySelector('#afLogin');
            const hasBridge = typeof window.HanstreeAlfred === 'object' &&
                              window.HanstreeAlfred !== null &&
                              typeof window.HanstreeAlfred.openQuery === 'function';
            const isVisibleStrict = (el) => {
                if (!el) return false;
                const rect = el.getBoundingClientRect();
                const style = window.getComputedStyle(el);
                return style.display !== 'none' &&
                       style.visibility !== 'hidden' &&
                       style.opacity !== '0' &&
                       rect.width > 0 &&
                       rect.height > 0;
            };
            return {
                hasRoot: !!root,
                rootVisible: isVisibleStrict(root),
                hasLogin: !!login,
                loginVisible: isVisibleStrict(login),
                hasBridge: hasBridge
            };
        })()
        """

        while Date().timeIntervalSince(readinessStart) < 15.0 {
            guard isCurrentRequest(token: requestToken, targetWebView: targetWebView, callerIsCurrent: isCurrent) else {
                return .failure("하나 대화창 준비 중 페이지가 이동했거나 안전하지 않은 주소로 전환되어 취소되었습니다.")
            }

            let currentURL = targetWebView.url
            if currentURL == nil || currentURL?.absoluteString == "about:blank" {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard isCurrentRequest(token: requestToken, targetWebView: targetWebView, callerIsCurrent: isCurrent) else {
                    return .failure("하나 대화창 준비 중 페이지가 이동했거나 안전하지 않은 주소로 전환되어 취소되었습니다.")
                }
                continue
            }

            guard HanaPanelHost.isTrustedAlfredURL(currentURL) else {
                return .failure("하나 대화창 준비 중 페이지가 이동했거나 안전하지 않은 주소로 전환되어 취소되었습니다.")
            }

            let checkResult = try? await Self.evaluateJavaScriptWithTimeout(webView: targetWebView, script: checkScript, timeoutSeconds: 4.0)

            guard isCurrentRequest(token: requestToken, targetWebView: targetWebView, callerIsCurrent: isCurrent) &&
                  HanaPanelHost.isTrustedAlfredURL(targetWebView.url) else {
                return .failure("대화창 상태 확인 후 페이지가 변경되었거나 요청이 취소되었습니다.")
            }

            if let dict = checkResult as? [String: Any] {
                if dict["loginVisible"] as? Bool == true {
                    return makeNeedsUserAction(reason: "하나(Hana) 로그인이 필요합니다. 로그인 상태를 확인한 뒤 다시 시도해 주세요.")
                }

                if dict["rootVisible"] as? Bool == true,
                   dict["loginVisible"] as? Bool == false,
                   dict["hasBridge"] as? Bool == true {
                    isReady = true
                    break
                }
            }

            guard isCurrentRequest(token: requestToken, targetWebView: targetWebView, callerIsCurrent: isCurrent) &&
                  HanaPanelHost.isTrustedAlfredURL(targetWebView.url) else {
                return .failure("대화창 대기 시작 전에 페이지가 변경되었거나 요청이 취소되었습니다.")
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard isCurrentRequest(token: requestToken, targetWebView: targetWebView, callerIsCurrent: isCurrent) &&
                  HanaPanelHost.isTrustedAlfredURL(targetWebView.url) else {
                return .failure("대화창 대기 후 페이지가 변경되었거나 요청이 취소되었습니다.")
            }
        }

        guard isReady else {
            return .failure("하나 대화창 준비 확인 시간 초과 (15초)")
        }

        guard isCurrentRequest(token: requestToken, targetWebView: targetWebView, callerIsCurrent: isCurrent) &&
              HanaPanelHost.isTrustedAlfredURL(targetWebView.url) else {
            return .failure("다음 단계 진행 전에 페이지가 변경되었거나 요청이 취소되었습니다.")
        }

        // Settle & bind navigation generation after positive app ready
        let boundNavigationGeneration = self.navigationGeneration

        // 3. Build prompt passing full raw trustedInstructions to formatSystemAndUserPrompt
        let requestMarker = "HANA_REQ_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let executionBoundary = "[REQUEST_MARKER: \(requestMarker)]\nYou are acting as an in-browser planning agent. You must output ONLY a valid JSON web action matching snapshotId \"\(snapshot.snapshotId)\". The host executes web actions; do not reference or search older NAS projects, conversations, or internal server tools."

        let formattedPrompt = WebPageAgentTransport.formatSystemAndUserPrompt(
            snapshot: snapshot,
            userGoal: userGoal,
            currentStep: currentStep,
            maxSteps: maxSteps,
            contextText: contextText,
            trustedInstructions: trustedInstructions
        )

        let fullPrompt = executionBoundary + "\n\n" + formattedPrompt
        let payload = HanaPanelHost.freshEnvelope + fullPrompt

        guard payload.utf16.count < 49000 else {
            return .failure("질문 크기가 허용 한도(49,000자)를 초과했습니다.")
        }

        guard let markerData = try? JSONSerialization.data(withJSONObject: [requestMarker], options: []),
              let markerArg = String(data: markerData, encoding: .utf8),
              let payloadData = try? JSONSerialization.data(withJSONObject: [payload], options: []),
              let payloadArg = String(data: payloadData, encoding: .utf8) else {
            return .failure("질문 데이터를 전송 형식으로 변환하지 못했습니다.")
        }

        // 4. Input draft protection, baseline row capture, and single openQuery dispatch
        let dispatchScript = """
        (() => {
            const input = document.querySelector('#afInput');
            if (input && typeof input.value === 'string' && input.value.trim().length > 0) {
                return { status: 'draftPresent' };
            }
            if (!window.HanstreeAlfred || typeof window.HanstreeAlfred.openQuery !== 'function') {
                return { status: 'noBridge' };
            }
            const messagesRoot = document.querySelector('#afMessages');
            if (!messagesRoot) {
                return { status: 'noMessagesRoot' };
            }
            const baselineNodes = new WeakSet();
            const existingRows = messagesRoot.querySelectorAll(':scope > .af-msg-row');
            existingRows.forEach(r => baselineNodes.add(r));

            const nonce = String(Date.now()) + '_' + Math.random().toString(36).slice(2);
            window.__sawHanaState = {
                marker: (\(markerArg))[0],
                nonce: nonce,
                messagesRoot: messagesRoot,
                baselineNodes: baselineNodes
            };

            const accepted = window.HanstreeAlfred.openQuery((\(payloadArg))[0]) === true;
            return {
                status: accepted ? 'accepted' : 'rejected',
                nonce: nonce
            };
        })()
        """

        guard isCurrentBound(token: requestToken, targetWebView: targetWebView, boundNavigationGeneration: boundNavigationGeneration, callerIsCurrent: isCurrent) else {
            return .failure("질문 전송 직전에 페이지가 변경되었거나 요청이 취소되었습니다.")
        }

        let dispatchResult: Any?
        do {
            dispatchResult = try await Self.evaluateJavaScriptWithTimeout(webView: targetWebView, script: dispatchScript, timeoutSeconds: 4.0)
        } catch {
            return makeNeedsUserAction(reason: "하나 전송 결과를 확인할 수 없습니다. 대화를 확인한 뒤 다시 시도해 주세요.")
        }

        guard isCurrentBound(token: requestToken, targetWebView: targetWebView, boundNavigationGeneration: boundNavigationGeneration, callerIsCurrent: isCurrent) else {
            return .failure("질문 전송 중 페이지가 변경되었거나 요청이 취소되었습니다.")
        }

        guard let dispatchDict = dispatchResult as? [String: Any],
              let dispatchStatus = dispatchDict["status"] as? String else {
            return makeNeedsUserAction(reason: "하나 전송 응답을 확인할 수 없습니다. 대화창에 질문이 정상 접수되었는지 확인해 주세요.")
        }

        if dispatchStatus == "draftPresent" {
            return makeNeedsUserAction(reason: "하나 입력창에 작성 중인 초안이 있어 보존을 위해 중단되었습니다. 입력창 내용을 확인해 주세요.")
        }

        guard dispatchStatus == "accepted", let nonce = dispatchDict["nonce"] as? String else {
            return .failure("하나 질문 접수에 실패했습니다. 대화창 상태를 확인한 뒤 다시 시도해 주세요.")
        }

        guard let nonceData = try? JSONSerialization.data(withJSONObject: [nonce], options: []),
              let nonceArg = String(data: nonceData, encoding: .utf8) else {
            return .failure("요청 식별 데이터 변환 중 오류가 발생했습니다. 잠시 후 다시 시도해 주세요.")
        }

        // 5. Streaming observation: strict adjacent new user/assistant & 3x 800ms stability verification
        let streamStartTime = Date()
        var assistantFirstSeenTime: Date? = nil
        let totalObservationSeconds: Double = 119.0
        let firstAssistantTimeoutSeconds: Double = 119.0
        var stableText: String = ""
        var stablePollCount: Int = 0

        let pollScript = """
        (() => {
            const state = window.__sawHanaState;
            if (!state || state.nonce !== (\(nonceArg))[0]) {
                return { error: 'state_invalid' };
            }
            const currentRoot = document.querySelector('#afMessages');
            if (!currentRoot || currentRoot !== state.messagesRoot || !document.contains(currentRoot)) {
                return { error: 'root_detached' };
            }

            const currentRows = Array.from(currentRoot.querySelectorAll(':scope > .af-msg-row'));
            const newRows = currentRows.filter(r => !state.baselineNodes.has(r));

            let userRow = null;
            for (let i = 0; i < newRows.length; i++) {
                const row = newRows[i];
                if (row.classList.contains('user')) {
                    const userMsg = row.querySelector(':scope > .af-msg.user');
                    if (userMsg && userMsg.textContent && userMsg.textContent.includes(state.marker)) {
                        userRow = row;
                        break;
                    } else {
                        return { error: 'unexpected_user_row_before_anchor' };
                    }
                }
            }
            if (!userRow) {
                return { status: 'waiting_user_row' };
            }

            let after = userRow.nextElementSibling;
            while (after) {
                if (after.classList.contains('user')) {
                    return { error: 'new_user_after_anchor' };
                }
                after = after.nextElementSibling;
            }

            const assistantRow = userRow.nextElementSibling;
            if (!assistantRow) {
                return { status: 'waiting_assistant_row' };
            }
            if (!assistantRow.classList.contains('assistant') || state.baselineNodes.has(assistantRow)) {
                return { status: 'waiting_assistant_row' };
            }

            const assistantMsg = assistantRow.querySelector(':scope > .af-msg.assistant');
            if (!assistantMsg) {
                return { status: 'waiting_assistant_text' };
            }

            const shareControls = assistantRow.querySelector('.af-share-controls');
            let streamingStatus = 'unknown';
            if (shareControls) {
                const attr = shareControls.getAttribute('data-streaming');
                if (attr === 'false') {
                    streamingStatus = 'done';
                } else if (attr === 'true') {
                    streamingStatus = 'streaming';
                }
            }

            let extractedText = '';
            const codeEl = assistantMsg.querySelector('pre code');
            if (codeEl && codeEl.textContent && codeEl.textContent.trim().length > 0) {
                extractedText = codeEl.textContent.trim();
            } else {
                const clone = assistantMsg.cloneNode(true);
                const actionElements = clone.querySelectorAll('.af-msg-actions, .af-share-controls, button');
                actionElements.forEach(el => el.remove());
                extractedText = clone.textContent ? clone.textContent.trim() : '';
            }

            return {
                status: 'received',
                streamingStatus: streamingStatus,
                text: extractedText
            };
        })()
        """

        while true {
            let observationOrigin = assistantFirstSeenTime ?? streamStartTime
            let elapsed = Date().timeIntervalSince(observationOrigin)
            let remaining = max(0, Int(totalObservationSeconds - elapsed))
            onRemainingSecondsUpdate(remaining)

            if assistantFirstSeenTime == nil {
                if Date().timeIntervalSince(streamStartTime) >= firstAssistantTimeoutSeconds {
                    return .failure("하나 첫 응답 시작 시간 초과 (119초)")
                }
            } else {
                if Date().timeIntervalSince(assistantFirstSeenTime!) >= totalObservationSeconds {
                    return .failure("하나 응답 대기 시간 초과 (119초)")
                }
            }

            guard isCurrentBound(token: requestToken, targetWebView: targetWebView, boundNavigationGeneration: boundNavigationGeneration, callerIsCurrent: isCurrent) else {
                return .failure("응답을 기다리는 도중 페이지가 변경되었거나 요청이 취소되었습니다.")
            }

            let pollResult = try? await Self.evaluateJavaScriptWithTimeout(webView: targetWebView, script: pollScript, timeoutSeconds: 4.0)

            guard isCurrentBound(token: requestToken, targetWebView: targetWebView, boundNavigationGeneration: boundNavigationGeneration, callerIsCurrent: isCurrent) else {
                return .failure("응답 확인 도중 페이지가 변경되었거나 요청이 취소되었습니다.")
            }

            guard let pollDict = pollResult as? [String: Any] else {
                stablePollCount = 0
                guard isCurrentBound(token: requestToken, targetWebView: targetWebView, boundNavigationGeneration: boundNavigationGeneration, callerIsCurrent: isCurrent) else {
                    return .failure("응답 대기 중 페이지가 변경되었거나 요청이 취소되었습니다.")
                }
                try? await Task.sleep(nanoseconds: 800_000_000)
                continue
            }

            if let err = pollDict["error"] as? String {
                return .failure("하나 대화가 변경되어 응답이 적용되지 않았습니다.")
            }

            guard let status = pollDict["status"] as? String, status == "received" else {
                stablePollCount = 0
                guard isCurrentBound(token: requestToken, targetWebView: targetWebView, boundNavigationGeneration: boundNavigationGeneration, callerIsCurrent: isCurrent) else {
                    return .failure("응답 대기 중 페이지가 변경되었거나 요청이 취소되었습니다.")
                }
                try? await Task.sleep(nanoseconds: 800_000_000)
                continue
            }

            if assistantFirstSeenTime == nil {
                assistantFirstSeenTime = Date()
            }

            let streamingStatus = pollDict["streamingStatus"] as? String ?? "unknown"
            if streamingStatus == "done" {
                let text = (pollDict["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !text.isEmpty {
                    if text == stableText {
                        stablePollCount += 1
                    } else {
                        stableText = text
                        stablePollCount = 1
                    }

                    if stablePollCount >= 3 {
                        guard isCurrentBound(token: requestToken, targetWebView: targetWebView, boundNavigationGeneration: boundNavigationGeneration, callerIsCurrent: isCurrent) else {
                            return .failure("응답 결과를 처리하기 전에 페이지가 변경되었거나 요청이 취소되었습니다.")
                        }
                        return WebPageAgentTransport.parseActionJSON(stableText, expectedSnapshotID: snapshot.snapshotId)
                    }
                } else {
                    stablePollCount = 0
                }
            } else {
                stablePollCount = 0
            }

            guard isCurrentBound(token: requestToken, targetWebView: targetWebView, boundNavigationGeneration: boundNavigationGeneration, callerIsCurrent: isCurrent) else {
                return .failure("응답 대기 중 페이지가 변경되었거나 요청이 취소되었습니다.")
            }
            try? await Task.sleep(nanoseconds: 800_000_000)
        }
    }

    private func makeNeedsUserAction(reason: String) -> WebPageAgentResult<WebPageAgentAction> {
        let action = WebPageAgentAction(action: .needsUser, reason: reason)
        return .success(action)
    }

    // MARK: - Lease Management

    private static func profileKey(for dataStore: WKWebsiteDataStore) -> String {
        if dataStore.isPersistent {
            if #available(macOS 14.0, *), let uuid = dataStore.identifier {
                return "persistent_\(uuid.uuidString)"
            }
            return "persistent_default"
        } else {
            return "nonpersistent_\(ObjectIdentifier(dataStore))"
        }
    }

    @MainActor
    private static func acquireProfileLease(
        key: String,
        token: UUID,
        isCurrent: () -> Bool
    ) async -> Bool {
        while true {
            guard !Task.isCancelled, isCurrent() else {
                return false
            }
            if profileLeases[key] == nil {
                profileLeases[key] = token
                return true
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    @MainActor
    private static func releaseProfileLease(key: String, token: UUID) {
        if profileLeases[key] == token {
            profileLeases.removeValue(forKey: key)
        }
    }

    // MARK: - WK EvaluateJavaScript Timeout Helper

    private struct WKTimeoutError: Error {}

    @MainActor
    private static func evaluateJavaScriptWithTimeout(
        webView: WKWebView,
        script: String,
        timeoutSeconds: TimeInterval = 4.0
    ) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            var didResume = false

            DispatchQueue.main.asyncAfter(deadline: .now() + timeoutSeconds) {
                if !didResume {
                    didResume = true
                    continuation.resume(throwing: WKTimeoutError())
                }
            }

            webView.evaluateJavaScript(script) { result, error in
                if !didResume {
                    didResume = true
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: result)
                    }
                }
            }
        }
    }
}

// MARK: - WKNavigationDelegate

extension SAWHanaTeamAdapter: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        if HanaPanelHost.isSameOrigin(url) {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        navigationGeneration += 1
        isPlannerLoading = true
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isPlannerLoading = false
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isPlannerLoading = false
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        isPlannerLoading = false
    }
}
