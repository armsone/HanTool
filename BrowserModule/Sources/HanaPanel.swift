import SwiftUI
import AppKit
import WebKit

struct HanaHandoff {
    let goal: String
    let context: String
    let token: UUID
    /// Raw #afInput value, set only when that draft was used as the goal (empty otherwise).
    let capturedDraft: String
    let navigationGeneration: Int
    /// Set only for a trusted typed delegation; nil keeps the manual handoff exactly as before.
    var delegation: HanaDelegationRequest? = nil
}

/// One native-validated, user-typed '플래너에게 맡겨줘' request from the isolated-world script.
struct HanaDelegationRequest {
    let requestID: UUID
    let docID: String
    let docNonce: String
    let generation: Int
    let originToken: String
    /// Raw #afInput value at submit time (also the literal instruction recorded on the new run).
    let utterance: String
}

/// Accepted delegation bound to its origin conversation (used by milestone 2; runtime-only, bounded).
struct HanaDelegationAssociation {
    let request: HanaDelegationRequest
    let projectID: UUID
    let runID: UUID
}

struct HanaHandoffError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private final class HanaHandoffOnce {
    private var claimed = false
    func claim() -> Bool {
        if claimed { return false }
        claimed = true
        return true
    }
}

/// Failure of a protected Planner result question. `ambiguous` means the question may already be in Hana.
struct HanaResultQuestionError: LocalizedError {
    let message: String
    let ambiguous: Bool
    var errorDescription: String? { message }
}

/// How a protected FIFO entry differs from the manual Planner result question (every field defaults to that behaviour).
struct HanaProtectedOptions {
    /// Typed-delegation origin conversation the entry must still belong to (verified natively around the page checks).
    var origin: HanaDelegationRequest? = nil
    /// Automatic completion notice: works with a hidden panel, holds while Hana streams or the user is editing.
    var completion = false
    /// Exact raw draft of a page-context question; consumed only after Hana accepted it. "" means the draft must be empty.
    var expectedDraft = ""
    /// Exact raw `window.HanstreeAlfred.hostContext()` value the page must still report, checked in the page both at
    /// the snapshot and immediately before openQuery. nil keeps the manual / page-context behaviour. Memory only.
    var expectedHostContext: String? = nil
}

/// State of the single protected queue entry (the Planner result question). Never persisted.
private final class HanaProtectedEntry {
    let requestID: UUID
    let nonce: String
    let generation: Int
    let options: HanaProtectedOptions
    let background: Bool
    let isCurrent: () -> Bool
    var enqueued = false
    var resolved = false
    var failure: HanaResultQuestionError?
    var continuation: CheckedContinuation<Void, Error>?

    init(requestID: UUID, nonce: String, generation: Int, options: HanaProtectedOptions, background: Bool, isCurrent: @escaping () -> Bool) {
        self.requestID = requestID
        self.nonce = nonce
        self.generation = generation
        self.options = options
        self.background = background
        self.isCurrent = isCurrent
    }
}

/// One automatic completion notice waiting for its origin Hana conversation (runtime-only, one per auto-origin run).
private final class HanaCompletionDelivery {
    enum State { case pending, sending, uncertain }
    let association: HanaDelegationAssociation
    let payload: String
    let note: (String) -> Void
    var state: State = .pending
    var heldNoted = false

    init(association: HanaDelegationAssociation, payload: String, note: @escaping (String) -> Void) {
        self.association = association
        self.payload = payload
        self.note = note
    }
}

/// Manages the embedded Hana conversation panel host, WebKit bridge lifecycle, security boundaries, and FIFO queue.
@MainActor
final class HanaPanelHost: ObservableObject {
    static let shared = HanaPanelHost()

    static let defaultWidth: CGFloat = 420
    static let minWidth: CGFloat = 320
    static let maxWidth: CGFloat = 900
    static let storageKey = "HanaPanelWidth"

    static let trustedHost = "hanstree.synology.me"
    static let trustedPort = 5443
    static let trustedPath = "/alfred"
    static let trustedURL = URL(string: "https://hanstree.synology.me:5443/alfred")!
    static let freshEnvelope = "\u{0001}hana:new\u{0001}"

    @Published var isPanelOpen: Bool = false {
        didSet {
            if !isPanelOpen {
                locationHandler?.cancelPending()
                uiDelegateHandler?.dismissActiveAlert()
            }
        }
    }
    @Published var preferredWidth: CGFloat
    @Published var isLoading: Bool = false
    @Published var isBridgeReady: Bool = false
    @Published var statusMessage: String? = nil
    @Published var hasAmbiguousError: Bool = false
    @Published var pendingQueueCount: Int = 0
    @Published private(set) var isCapturingPlannerHandoff: Bool = false

    static let handoffGoalLimit = 10_000
    static let handoffContextLimit = 6_000
    private var lastHandoffErrorMessage: String?

    let webView: WKWebView
    private var navigationDelegateHandler: HanaNavigationDelegate?
    private var uiDelegateHandler: HanaUIDelegate?
    private var locationHandler: HanaLocationScriptMessageHandler?

    // Trusted typed delegation (isolated world, this panel's own configuration only).
    static let delegationWorld = WKContentWorld.world(name: "HanaDelegation")
    static let delegationHandlerName = "hdeleg"
    private var delegationHandler: HanaDelegationMessageHandler?
    private var delegationDoc: (docID: String, nonce: String, generation: Int)?
    private var activeDelegation: HanaDelegationRequest?
    private var acceptedDelegationIDs: [UUID] = []
    private var lostDelegationOrigins: Set<String> = []
    private(set) var delegationAssociations: [HanaDelegationAssociation] = []
    private var delegationOwnerID: UUID?
    private var onDelegationRequest: ((HanaDelegationRequest) -> Void)?
    private var onPageContextRequest: ((HanaDelegationRequest) -> Void)?
    private var activePageContext: HanaDelegationRequest?
    private var completionDeliveries: [UUID: HanaCompletionDelivery] = [:]
    private var completedDeliveryRunIDs: [UUID] = []
    private var completionWatching = false

    private var pendingQueue: [String] = []
    private var protectedEntry: HanaProtectedEntry?
    private var isDispatching: Bool = false
    private var navigationGeneration: Int = 0
    private var readinessPollTimer: Timer?
    private var readinessPollCount: Int = 0

    var onOpenExternalURL: ((URL) -> Void)?

    /// Common assistant planner session of the Hana panel (same entry as every other service). While it is attached the
    /// private typed-delegation trigger below stays off, so exactly one component owns the control sentence.
    private(set) var plannerSession: AssistantWebSession?
    var commonPlannerOwnsDelegation: Bool { plannerSession?.binding != nil }

    /// Creates the panel's common session once and binds it to the exact Hana address and the default data store.
    @discardableResult
    func attachPlanner(coordinator: AssistantPlannerCoordinator) -> AssistantWebSession {
        if let plannerSession { return plannerSession }
        let session = AssistantWebSession(hostID: "hana-panel", coordinator: coordinator)
        plannerSession = session
        session.configure(serviceID: CuratedAIServices.hanaID, profileID: "default",
                          homeURL: Self.trustedURL.absoluteString, webView: webView)
        return session
    }

    @MainActor
    private init() {
        let saved = HTDBrowserDefaults.standard.double(forKey: Self.storageKey)
        if saved >= Double(Self.minWidth) && saved <= Double(Self.maxWidth) {
            self.preferredWidth = CGFloat(saved)
        } else {
            self.preferredWidth = Self.defaultWidth
        }

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        PageAudioController.shared.prepareConfiguration(config)
        let delegationHandler = HanaDelegationMessageHandler()
        config.userContentController.addUserScript(WKUserScript(
            source: Self.delegationScript, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: Self.delegationWorld))
        config.userContentController.add(delegationHandler, contentWorld: Self.delegationWorld, name: Self.delegationHandlerName)
        let wv = WKWebView(frame: .zero, configuration: config)
        self.webView = wv
        PageAudioController.shared.register(webView: wv, kind: .hanaPanel)

        delegationHandler.host = self
        self.delegationHandler = delegationHandler

        let locHandler = HanaLocationScriptMessageHandler(host: self)
        self.locationHandler = locHandler
        config.userContentController.addScriptMessageHandler(locHandler, contentWorld: .page, name: "hloc")

        let navDelegate = HanaNavigationDelegate(host: self)
        self.navigationDelegateHandler = navDelegate
        wv.navigationDelegate = navDelegate

        let uiDelegate = HanaUIDelegate(host: self)
        self.uiDelegateHandler = uiDelegate
        wv.uiDelegate = uiDelegate

        wv.load(URLRequest(url: Self.trustedURL))
    }

    func setPreferredWidth(_ width: CGFloat) {
        let clamped = min(max(Self.minWidth, width), Self.maxWidth)
        self.preferredWidth = clamped
        HTDBrowserDefaults.standard.set(Double(clamped), forKey: Self.storageKey)
    }

    func effectiveWidth(forAvailableWidth available: CGFloat) -> CGFloat {
        let budget = available - 16
        if budget <= Self.minWidth {
            return max(budget, 1)
        }
        let maxAllowed = max(Self.minWidth, budget - 100)
        let upper = min(Self.maxWidth, maxAllowed)
        return min(max(Self.minWidth, preferredWidth), upper)
    }

    /// Determines whether the embedded Hana panel currently has focus within the given window.
    /// Checks if the panel is open, if any modal sheet is not active, and whether the firstResponder
    /// is the Hana WKWebView or one of its descendants (including content / editing views).
    func isHanaPanelFocused(in targetWindow: NSWindow?) -> Bool {
        guard isPanelOpen else { return false }
        guard let window = targetWindow ?? webView.window else { return false }
        guard window.attachedSheet == nil else { return false }
        guard let responder = window.firstResponder else { return false }
        if responder === webView { return true }
        if let responderView = responder as? NSView {
            return responderView.isDescendant(of: webView)
        }
        return false
    }

    static func isTrustedAlfredURL(_ url: URL?) -> Bool {
        guard let url = url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        guard components.scheme?.lowercased() == "https",
              components.host?.lowercased() == trustedHost,
              components.port == trustedPort,
              components.path == trustedPath,
              components.user == nil,
              components.password == nil,
              (components.query == nil || components.query?.isEmpty == true) else {
            return false
        }
        return true
    }

    static func isSameOrigin(_ url: URL?) -> Bool {
        guard let url = url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return components.scheme?.lowercased() == "https" &&
               components.host?.lowercased() == trustedHost &&
               components.port == trustedPort &&
               components.user == nil &&
               components.password == nil
    }

    func submitAddressCommand(question: String, fresh: Bool) {
        isPanelOpen = true
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        if fresh {
            let text = trimmed.isEmpty ? Self.freshEnvelope : (Self.freshEnvelope + trimmed)
            pendingQueue.append(text)
            pendingQueueCount = pendingQueue.count
            if isBridgeReady {
                drainQueue()
            }
        } else {
            if !trimmed.isEmpty {
                pendingQueue.append(trimmed)
                pendingQueueCount = pendingQueue.count
                if isBridgeReady {
                    drainQueue()
                }
            }
            // Empty existing invocation only opens panel without submitting
        }
    }

    // MARK: - Planner handoff capture (explicit user action only, read-only)

    /// Reads the currently mounted Hana conversation and returns a goal + bounded context.
    /// Never clears, edits, or sends the #afInput draft and never navigates or fetches.
    /// `delegation` (trusted typed command only): the goal is the LAST user row already in the conversation (the control
    /// sentence is unsent), the draft must equal the typed sentence, and everything runs in the isolated world.
    func capturePlannerHandoff(delegation: HanaDelegationRequest? = nil) async throws -> HanaHandoff {
        guard !isCapturingPlannerHandoff else {
            throw HanaHandoffError(message: "하나 대화를 이미 읽는 중입니다.")
        }
        if let previous = lastHandoffErrorMessage, statusMessage == previous {
            statusMessage = nil
        }
        lastHandoffErrorMessage = nil
        isCapturingPlannerHandoff = true
        let token = UUID()
        let nonce = token.uuidString
        let world: WKContentWorld? = delegation == nil ? nil : Self.delegationWorld
        defer {
            isCapturingPlannerHandoff = false
            discardHandoffState(world: world)
        }

        do {
            try ensureHandoffReady()
            try ensureDelegationCurrent(delegation)
            let generation = navigationGeneration

            let first = try await evaluateHandoffScript(Self.handoffScript(nonce: nonce, verify: false, delegation: delegation), world: world)
            try ensureHandoffStillCurrent(generation: generation, delegation: delegation)
            guard let dict = first as? [String: Any], let status = dict["status"] as? String else {
                throw HanaHandoffError(message: "하나 대화를 읽지 못했습니다.")
            }
            switch status {
            case "ok": break
            case "login": throw HanaHandoffError(message: "하나 로그인이 필요합니다. 로그인 후 다시 시도해 주세요.")
            case "goalTooLong": throw HanaHandoffError(message: "넘길 목표가 \(Self.handoffGoalLimit)자를 넘습니다. 입력창 내용을 줄여 다시 시도해 주세요.")
            case "noGoal":
                throw HanaHandoffError(message: delegation == nil
                    ? "넘길 목표가 없습니다. 입력창에 목표를 쓰거나 대화에 내 메시지가 있어야 합니다."
                    : "플래너에게 맡길 업무 설명이 없습니다. 먼저 하나에게 할 일을 말한 뒤 다시 시도해 주세요. 입력은 그대로 둡니다.")
            case "changed" where delegation != nil:
                throw HanaHandoffError(message: "하나 대화가 바뀌어 플래너로 넘기지 않았습니다. 입력은 그대로 둡니다.")
            default: throw HanaHandoffError(message: "하나 대화를 읽을 수 없는 상태입니다. 잠시 후 다시 시도해 주세요.")
            }
            let goal = ((dict["goal"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let context = ((dict["context"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !goal.isEmpty else {
                throw HanaHandoffError(message: "넘길 목표가 없습니다. 입력창에 목표를 쓰거나 대화에 내 메시지가 있어야 합니다.")
            }
            guard goal.utf16.count <= Self.handoffGoalLimit else {
                throw HanaHandoffError(message: "넘길 목표가 \(Self.handoffGoalLimit)자를 넘습니다. 입력창 내용을 줄여 다시 시도해 주세요.")
            }
            guard context.utf16.count <= Self.handoffContextLimit else {
                throw HanaHandoffError(message: "넘길 대화 맥락이 너무 깁니다.")
            }

            // Second validation: same root, same latest nodes, same draft.
            let second = try await evaluateHandoffScript(Self.handoffScript(nonce: nonce, verify: true, delegation: delegation), world: world)
            try ensureHandoffStillCurrent(generation: generation, delegation: delegation)
            guard let check = second as? [String: Any], check["status"] as? String == "same" else {
                throw HanaHandoffError(message: "읽는 동안 하나 대화가 바뀌었습니다. 다시 시도해 주세요.")
            }
            let rawDraft = (dict["draft"] as? String) ?? ""
            return HanaHandoff(goal: goal, context: context, token: token,
                               capturedDraft: rawDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : rawDraft,
                               navigationGeneration: generation, delegation: delegation)
        } catch {
            discardHandoffAck(nonce: nonce, world: world)
            if !(error is CancellationError) && !Task.isCancelled {
                let message = (error as? HanaHandoffError)?.message ?? "하나 대화를 읽지 못했습니다."
                lastHandoffErrorMessage = message
                statusMessage = message
            }
            throw error
        }
    }

    private func ensureHandoffReady() throws {
        guard isPanelOpen, Self.isTrustedAlfredURL(webView.url), webView.window != nil,
              webView.bounds.width > 0, webView.bounds.height > 0, !webView.isLoading, !isLoading, isBridgeReady else {
            throw HanaHandoffError(message: "하나 대화창이 아직 준비되지 않았습니다.")
        }
    }

    private func ensureHandoffStillCurrent(generation: Int, delegation: HanaDelegationRequest? = nil) throws {
        try Task.checkCancellation()
        guard navigationGeneration == generation, isCapturingPlannerHandoff, Self.shared === self else {
            throw HanaHandoffError(message: "하나 대화창이 바뀌어 읽기를 취소했습니다.")
        }
        try ensureHandoffReady()
        try ensureDelegationCurrent(delegation)
    }

    /// The exact typed request must still be the active one on the same document, nonce and navigation generation.
    private func ensureDelegationCurrent(_ request: HanaDelegationRequest?) throws {
        guard let request = request else { return }
        guard activeDelegation?.requestID == request.requestID, request.generation == navigationGeneration,
              delegationDoc?.docID == request.docID, delegationDoc?.nonce == request.docNonce else {
            throw HanaHandoffError(message: "하나 화면이 바뀌어 플래너로 넘기지 않았습니다. 입력은 그대로 둡니다.")
        }
    }

    private func runIgnoringResult(_ script: String, world: WKContentWorld?) {
        if let world = world {
            webView.evaluateJavaScript(script, in: nil, in: world, completionHandler: nil)
        } else {
            webView.evaluateJavaScript(script, completionHandler: nil)
        }
    }

    private func discardHandoffState(world: WKContentWorld? = nil) {
        guard Self.isTrustedAlfredURL(webView.url) else { return }
        runIgnoringResult("try { delete window.__hanaHandoffState; } catch (e) {}", world: world)
    }

    private func discardHandoffAck(nonce: String, world: WKContentWorld? = nil) {
        guard Self.isTrustedAlfredURL(webView.url),
              let data = try? JSONSerialization.data(withJSONObject: [nonce], options: []),
              let literal = String(data: data, encoding: .utf8) else { return }
        runIgnoringResult("try { const a = window.__hanaHandoffAck; if (a && a.nonce === (\(literal))[0]) delete window.__hanaHandoffAck; } catch (e) {}", world: world)
    }

    /// Call only after the planner run for this handoff was confirmed started. Consumes the transferred draft
    /// like Send (clears #afInput + input event) only if the page, conversation, nodes and the exact raw draft
    /// are unchanged; otherwise does nothing. Never sends, never throws, never touches newer drafts.
    @discardableResult
    func acknowledgePlannerHandoff(_ handoff: HanaHandoff) async -> Bool {
        let nonce = handoff.token.uuidString
        let world: WKContentWorld? = handoff.delegation == nil ? nil : Self.delegationWorld
        defer { discardHandoffAck(nonce: nonce, world: world) }
        guard !Task.isCancelled, !handoff.capturedDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !isCapturingPlannerHandoff, navigationGeneration == handoff.navigationGeneration,
              (try? ensureHandoffReady()) != nil, (try? ensureDelegationCurrent(handoff.delegation)) != nil,
              let data = try? JSONSerialization.data(withJSONObject: [nonce, handoff.capturedDraft], options: []),
              let args = String(data: data, encoding: .utf8) else { return false }
        let script = """
        (() => {
            const args = (\(args));
            const a = window.__hanaHandoffAck;
            if (!a || a.nonce !== args[0]) return false;
            try { delete window.__hanaHandoffAck; } catch (e) {}
            const root = document.querySelector('#afMessages');
            const input = document.querySelector('#afInput');
            if (!root || !document.contains(root) || a.root !== root) return false;
            if (!input || input.tagName !== 'TEXTAREA' || a.input !== input || !document.contains(input)) return false;
            if (input.value !== args[1] || a.draft !== args[1]) return false;
            const shown = (el) => {
                const r = el.getBoundingClientRect();
                const s = window.getComputedStyle(el);
                return s.display !== 'none' && s.visibility !== 'hidden' && r.width > 0 && r.height > 0;
            };
            let lastUser = null, lastRow = null;
            for (const row of root.querySelectorAll(':scope > .af-msg-row')) {
                const role = row.classList.contains('user') ? 'user' : (row.classList.contains('assistant') ? 'assistant' : null);
                if (!role) continue;
                const msg = row.querySelector(':scope > .af-msg.' + role);
                if (!msg || !shown(row) || !shown(msg)) continue;
                lastRow = row;
                if (role === 'user') lastUser = row;
            }
            if (a.lastUserRow !== lastUser || a.lastRow !== lastRow) return false;
            input.value = '';
            input.dispatchEvent(new Event('input', { bubbles: true }));
            return true;
        })()
        """
        let consumed = try? await evaluateHandoffScript(script, world: world)
        return (consumed as? Bool) == true
    }

    /// `world == nil` evaluates in the page world exactly as before; the trusted delegation uses its isolated world.
    private func evaluateHandoffScript(_ script: String, world: WKContentWorld? = nil) async throws -> Any? {
        let wv = webView
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any?, Error>) in
            let once = HanaHandoffOnce()
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                if once.claim() {
                    continuation.resume(throwing: HanaHandoffError(message: "하나 대화 읽기 시간이 초과되었습니다."))
                }
            }
            if let world = world {
                wv.evaluateJavaScript(script, in: nil, in: world) { result in
                    guard once.claim() else { return }
                    switch result {
                    case .success(let value): continuation.resume(returning: value)
                    case .failure(let error): continuation.resume(throwing: error)
                    }
                }
                return
            }
            wv.evaluateJavaScript(script) { result, error in
                guard once.claim() else { return }
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: result)
                }
            }
        }
    }

    /// Capture (verify == false) stores nonce-scoped node refs and returns goal/context;
    /// verify (verify == true) only compares the refs and draft with the live DOM.
    private static func handoffScript(nonce: String, verify: Bool, delegation: HanaDelegationRequest? = nil) -> String {
        let nonceLiteral = (try? JSONSerialization.data(withJSONObject: [nonce], options: []))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        let autoLiteral = delegation.flatMap { try? JSONSerialization.data(withJSONObject: [$0.utterance, $0.originToken], options: []) }
            .flatMap { String(data: $0, encoding: .utf8) } ?? "null"
        return """
        (() => {
            const nonce = (\(nonceLiteral))[0];
            const auto = \(autoLiteral);
            const GOAL_LIMIT = \(handoffGoalLimit);
            const CTX_LIMIT = \(handoffContextLimit);
            const PER_MSG = 1500;
            const MAX_ROWS = 8;
            const root = document.querySelector('#afMessages');
            const input = document.querySelector('#afInput');
            const textarea = (input && input.tagName === 'TEXTAREA') ? input : null;
            const shown = (el) => {
                const r = el.getBoundingClientRect();
                const s = window.getComputedStyle(el);
                return s.display !== 'none' && s.visibility !== 'hidden' && r.width > 0 && r.height > 0;
            };
            const rowsOf = (rt) => Array.from(rt.querySelectorAll(':scope > .af-msg-row')).map((row) => {
                const role = row.classList.contains('user') ? 'user' : (row.classList.contains('assistant') ? 'assistant' : null);
                if (!role) return null;
                const msg = row.querySelector(':scope > .af-msg.' + role);
                if (!msg || !shown(row) || !shown(msg)) return null;
                return { row: row, msg: msg, role: role };
            }).filter(Boolean);
            const textOf = (e) => {
                if (e.role === 'assistant') {
                    const clone = e.msg.cloneNode(true);
                    clone.querySelectorAll('.af-msg-actions, .af-share-controls, button').forEach((n) => n.remove());
                    return (clone.textContent || '').trim();
                }
                return (e.msg.textContent || '').trim();
            };
            if (!root || !document.contains(root) || !shown(root)) return { status: 'noRoot' };
            const login = document.querySelector('#afLogin');
            if (login && shown(login)) return { status: 'login' };
            const rows = rowsOf(root);
            let lastUser = null;
            for (let i = rows.length - 1; i >= 0; i--) { if (rows[i].role === 'user') { lastUser = rows[i]; break; } }
            const lastRow = rows.length ? rows[rows.length - 1] : null;
            const draft = textarea ? textarea.value : '';
            // Trusted typed delegation only: the SAME origin conversation registered by the isolated script, typed draft unchanged.
            let originOK = true;
            if (auto) {
                const bridge = window.__hdeleg;
                const origin = bridge ? bridge.origin(auto[1]) : null;
                originOK = !!(origin && origin.root === root && origin.valid()) && draft === auto[0];
                if (!lastUser) return { status: 'noGoal' };
                if (!originOK) return { status: 'changed' };
            }

            if (\(verify ? "true" : "false")) {
                const st = window.__hanaHandoffState;
                if (!st || st.nonce !== nonce) return { status: 'changed' };
                const same = originOK && st.root === root && st.input === textarea && st.draft === draft &&
                    st.lastUserRow === (lastUser ? lastUser.row : null) &&
                    st.lastUserText === (lastUser ? textOf(lastUser) : '') &&
                    st.lastRow === (lastRow ? lastRow.row : null) &&
                    st.lastRowLen === (lastRow ? textOf(lastRow).length : 0);
                delete window.__hanaHandoffState;
                if (same && draft.trim().length > 0) {
                    window.__hanaHandoffAck = { nonce: nonce, root: root, input: textarea, draft: draft,
                        lastUserRow: lastUser ? lastUser.row : null, lastRow: lastRow ? lastRow.row : null };
                }
                return { status: same ? 'same' : 'changed' };
            }

            const draftGoal = auto ? '' : draft.trim();
            const lastUserText = lastUser ? textOf(lastUser) : '';
            const goal = draftGoal.length > 0 ? draftGoal : lastUserText;
            if (goal.length === 0) return { status: 'noGoal' };
            if (goal.length > GOAL_LIMIT) return { status: 'goalTooLong' };

            const cut = (t) => {
                if (t.length <= PER_MSG) return t;
                let s = t.slice(0, PER_MSG);
                const c = s.charCodeAt(s.length - 1);
                if (c >= 0xD800 && c <= 0xDBFF) s = s.slice(0, -1);
                return s + ' …[잘림]';
            };
            const picked = [];
            let total = 0;
            const recent = rows.slice(-MAX_ROWS);
            for (let i = recent.length - 1; i >= 0; i--) {
                const t = textOf(recent[i]);
                if (!t) continue;
                const label = recent[i].role === 'user' ? '[사용자]' : '[하나 답변 · 비신뢰 참고]';
                const entry = label + '\\n' + cut(t);
                if (total + entry.length + 2 > CTX_LIMIT) break;
                picked.unshift(entry);
                total += entry.length + 2;
            }
            window.__hanaHandoffState = {
                nonce: nonce, root: root, input: textarea, draft: draft,
                lastUserRow: lastUser ? lastUser.row : null, lastUserText: lastUserText,
                lastRow: lastRow ? lastRow.row : null, lastRowLen: lastRow ? textOf(lastRow).length : 0
            };
            return { status: 'ok', goal: goal, context: picked.join('\\n\\n'), draft: (auto || draftGoal.length > 0) ? draft : '' };
        })()
        """
    }

    func handleDidStartProvisionalNavigation() {
        locationHandler?.cancelPending()
        uiDelegateHandler?.dismissActiveAlert()
        if isDispatching {
            hasAmbiguousError = true
            statusMessage = "전송 결과를 확인할 수 없습니다. 대화를 확인한 뒤 다시 시도해 주세요. 중복될 수 있습니다."
        }
        if let entry = protectedEntry {
            if isDispatching && entry.enqueued {
                failProtected(entry, message: "전송 중 하나 화면이 바뀌어 결과를 확인할 수 없습니다. 하나에서 확인해 주세요.", ambiguous: true)
            } else {
                failProtected(entry, message: "하나 화면이 바뀌어 질문을 보내지 않았습니다.", ambiguous: false)
            }
        }
        navigationGeneration += 1
        isBridgeReady = false
        isLoading = true
        stopReadinessPolling()
        // A new document gets a new handshake; nothing from the previous one stays valid.
        delegationDoc = nil
        activeDelegation = nil
        activePageContext = nil
        // Accepted runs keep their association: the origin is only marked unavailable, so a later completion gets an honest
        // hold/notice instead of being silently dropped or delivered to a conversation that cannot be proven the same.
        lostDelegationOrigins = Set(delegationAssociations.map { $0.request.originToken })
        completionWatching = false
        for delivery in Array(completionDeliveries.values) where delivery.state == .pending { holdCompletion(delivery) }
    }

    func handleDidFinishNavigation() {
        isLoading = false
        guard Self.isTrustedAlfredURL(webView.url) else {
            isBridgeReady = false
            stopReadinessPolling()
            return
        }
        startReadinessPolling()
    }

    func handleNavigationFailure(error: Error) {
        isLoading = false
        isBridgeReady = false
        stopReadinessPolling()
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            return
        }
        statusMessage = "하나 연결에 실패했습니다. 네트워크 상태를 확인해 주세요."
    }

    func reload() {
        stopReadinessPolling()
        isBridgeReady = false
        statusMessage = nil
        webView.load(URLRequest(url: Self.trustedURL))
    }

    func retrySend() {
        hasAmbiguousError = false
        statusMessage = nil
        if isBridgeReady {
            drainQueue()
        } else if Self.isTrustedAlfredURL(webView.url) {
            startReadinessPolling()
        } else {
            reload()
        }
    }

    private func startReadinessPolling() {
        stopReadinessPolling()
        readinessPollCount = 0
        let currentGen = self.navigationGeneration

        probeBridgeReadiness(generation: currentGen)

        readinessPollTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] timer in
            Task { @MainActor [weak self] in
                guard let self = self else {
                    timer.invalidate()
                    return
                }
                guard self.navigationGeneration == currentGen else {
                    timer.invalidate()
                    return
                }
                self.readinessPollCount += 1
                if self.isBridgeReady || self.readinessPollCount >= 25 {
                    timer.invalidate()
                    self.readinessPollTimer = nil
                    if !self.isBridgeReady && Self.isTrustedAlfredURL(self.webView.url) {
                        self.statusMessage = "대화창 준비가 지연되고 있습니다."
                    }
                    return
                }
                self.probeBridgeReadiness(generation: currentGen)
            }
        }
    }

    private func stopReadinessPolling() {
        readinessPollTimer?.invalidate()
        readinessPollTimer = nil
        readinessPollCount = 0
    }

    private func probeBridgeReadiness(generation: Int) {
        guard Self.isTrustedAlfredURL(webView.url) else { return }
        let script = "typeof window.HanstreeAlfred === 'object' && window.HanstreeAlfred !== null && typeof window.HanstreeAlfred.openQuery === 'function'"
        webView.evaluateJavaScript(script) { [weak self] result, _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                guard self.navigationGeneration == generation else { return }
                if let ready = result as? Bool, ready == true {
                    self.isBridgeReady = true
                    self.stopReadinessPolling()
                    if !self.hasAmbiguousError {
                        self.statusMessage = nil
                    }
                    self.drainQueue()
                    self.attemptPendingCompletions()
                }
            }
        }
    }

    // MARK: - Planner result question (explicit user Send only, one protected FIFO entry)

    /// Queues one Planner result question through the existing FIFO / openQuery path.
    /// Returns only when Hana's openQuery returned `true` for this request; throws otherwise.
    /// Refuses (never overwrites or clears) when the Hana input has any draft, the queue is busy,
    /// the bridge is not ready, or the conversation/navigation changed. No automatic retry.
    /// `options` (default = the manual result question above) also serves the automatic completion notice and the
    /// explicit current-page question; both keep the same snapshot/verify/openQuery steps and never retry.
    func submitPlannerResultQuestion(payload: String, requestID: UUID, isCurrent: @escaping () -> Bool,
                                     options: HanaProtectedOptions = HanaProtectedOptions()) async throws {
        func refuse(_ message: String) -> HanaResultQuestionError {
            HanaResultQuestionError(message: message, ambiguous: false)
        }
        func ready() throws {
            if options.completion { try ensureCompletionReady() } else { try ensureHandoffReady() }
        }
        func originLive() async -> Bool {
            guard let origin = options.origin else { return true }
            return await isDelegationOriginLive(origin)
        }
        guard protectedEntry == nil, !isCapturingPlannerHandoff else { throw refuse("이미 질문을 보내는 중입니다.") }
        guard !hasAmbiguousError else { throw refuse("이전 전송 결과가 확인되지 않았습니다. 하나에서 확인한 뒤 다시 시도해 주세요.") }
        guard pendingQueue.isEmpty, !isDispatching else { throw refuse("하나에 아직 보내지 않은 질문이 있습니다. 잠시 후 다시 시도해 주세요.") }
        guard isCurrent() else { throw refuse("프로젝트가 바뀌어 질문을 보내지 않았습니다.") }
        do { try ready() } catch { throw refuse("하나 대화창이 아직 준비되지 않았습니다. 잠시 후 다시 보내 주세요.") }

        let generation = navigationGeneration
        // Only a verified auto-origin completion may run while the panel is hidden; its page checks then skip the size test.
        let background = options.completion && !(isPanelOpen && webView.window != nil && webView.bounds.width > 0 && webView.bounds.height > 0)
        let entry = HanaProtectedEntry(requestID: requestID, nonce: UUID().uuidString, generation: generation,
                                       options: options, background: background, isCurrent: isCurrent)
        protectedEntry = entry
        func release() {
            if protectedEntry === entry { protectedEntry = nil }
            discardResultState()
        }

        guard await originLive() else {
            release()
            if let failure = entry.failure { throw failure }
            throw refuse("원래 하나 대화를 확인할 수 없어 보내지 않았습니다.")
        }
        let snapshot: Any?
        do {
            snapshot = try await evaluateHandoffScript(Self.resultScript(nonce: entry.nonce, jsonArgs: nil, options: options, background: background))
        } catch {
            release()
            if let failure = entry.failure { throw failure }
            throw refuse("하나 대화 상태를 확인하지 못했습니다. 다시 시도해 주세요.")
        }
        if let failure = entry.failure { throw failure }
        guard protectedEntry === entry, navigationGeneration == generation, isCurrent(),
              pendingQueue.isEmpty, !isDispatching, !hasAmbiguousError else {
            release()
            throw refuse("하나 대화나 프로젝트가 바뀌어 질문을 보내지 않았습니다.")
        }
        do { try ready() } catch {
            release()
            throw refuse("하나 대화창이 아직 준비되지 않았습니다. 잠시 후 다시 보내 주세요.")
        }
        switch snapshot as? String {
        case "ok": break
        case "busy":
            release()
            throw refuse("하나가 응답 중이라 보내지 않았습니다.")
        case "focused":
            release()
            throw refuse("하나 입력창을 사용 중이라 보내지 않았습니다.")
        case "draft":
            release()
            throw refuse(options.expectedDraft.isEmpty
                ? "하나 입력창에 작성 중인 내용이 있어 보내지 않았습니다. 입력창을 비운 뒤 다시 보내 주세요."
                : "하나 입력창 내용이 바뀌어 보내지 않았습니다. 입력은 그대로 둡니다.")
        case "login":
            release()
            throw refuse("하나 로그인이 필요합니다. 로그인 후 다시 보내 주세요.")
        default:
            release()
            throw refuse("하나 대화를 확인할 수 없는 상태입니다. 잠시 후 다시 보내 주세요.")
        }

        // Origin re-check right before enqueueing; the page-side refs then pin the conversation until openQuery.
        let stillOrigin = await originLive()
        if let failure = entry.failure { throw failure }
        guard stillOrigin, protectedEntry === entry, navigationGeneration == generation, isCurrent(),
              pendingQueue.isEmpty, !isDispatching, !hasAmbiguousError else {
            release()
            throw refuse("하나 대화나 프로젝트가 바뀌어 질문을 보내지 않았습니다.")
        }
        pendingQueue.append(payload)
        pendingQueueCount = pendingQueue.count
        entry.enqueued = true
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            entry.continuation = continuation
            Task { @MainActor [weak self] in self?.drainQueue() }
        }
    }

    private func dispatchProtected(_ entry: HanaProtectedEntry) {
        guard !entry.resolved, protectedEntry === entry, !pendingQueue.isEmpty else { return }
        guard navigationGeneration == entry.generation, entry.isCurrent() else {
            failProtected(entry, message: "프로젝트나 하나 대화가 바뀌어 질문을 보내지 않았습니다.", ambiguous: false)
            return
        }
        guard let data = try? JSONSerialization.data(withJSONObject: [pendingQueue[0]], options: []),
              let jsonArgs = String(data: data, encoding: .utf8) else {
            failProtected(entry, message: "질문 인코딩 오류로 보내지 않았습니다.", ambiguous: false)
            return
        }
        isDispatching = true
        let once = HanaHandoffOnce()
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) { [weak self] in
            guard once.claim() else { return }
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.isDispatching = false
                guard self.protectedEntry === entry else { return }
                self.failProtected(entry, message: "전송 결과를 확인할 수 없습니다(시간 초과). 하나에서 확인해 주세요. 중복될 수 있습니다.", ambiguous: true)
            }
        }
        webView.evaluateJavaScript(Self.resultScript(nonce: entry.nonce, jsonArgs: jsonArgs, options: entry.options, background: entry.background)) { [weak self] result, error in
            guard once.claim() else { return }
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.isDispatching = false
                guard self.protectedEntry === entry, !entry.resolved else { return }
                if error != nil {
                    self.failProtected(entry, message: "전송 결과를 확인할 수 없습니다. 하나에서 확인해 주세요. 중복될 수 있습니다.", ambiguous: true)
                    return
                }
                switch result as? String {
                case "accepted":
                    self.succeedProtected(entry)
                case "changed":
                    self.failProtected(entry, message: entry.options.expectedDraft.isEmpty
                        ? "하나 입력창이나 대화가 바뀌어 질문을 보내지 않았습니다. 입력창을 비운 뒤 다시 보내 주세요."
                        : "하나 입력창이나 대화가 바뀌어 보내지 않았습니다. 입력은 그대로 둡니다.", ambiguous: false)
                case "rejected", "unavailable":
                    self.failProtected(entry, message: "하나가 질문을 접수하지 않았습니다. 다시 보내 주세요.", ambiguous: false)
                default:
                    self.failProtected(entry, message: "전송 결과를 확인할 수 없습니다. 하나에서 확인해 주세요. 중복될 수 있습니다.", ambiguous: true)
                }
            }
        }
    }

    private func succeedProtected(_ entry: HanaProtectedEntry) {
        guard !entry.resolved else { return }
        entry.resolved = true
        if protectedEntry === entry { protectedEntry = nil }
        if entry.enqueued, !pendingQueue.isEmpty {
            pendingQueue.removeFirst()
            pendingQueueCount = pendingQueue.count
        }
        hasAmbiguousError = false
        statusMessage = nil
        let continuation = entry.continuation
        entry.continuation = nil
        continuation?.resume()
        if !pendingQueue.isEmpty { drainQueue() }
    }

    /// Removes only the protected head entry (other queued questions stay) and resolves the waiter once.
    private func failProtected(_ entry: HanaProtectedEntry, message: String, ambiguous: Bool) {
        guard !entry.resolved else { return }
        entry.resolved = true
        let error = HanaResultQuestionError(message: message, ambiguous: ambiguous)
        entry.failure = error
        if protectedEntry === entry { protectedEntry = nil }
        if entry.enqueued, !pendingQueue.isEmpty {
            pendingQueue.removeFirst()
            pendingQueueCount = pendingQueue.count
        }
        if ambiguous {
            hasAmbiguousError = true
            statusMessage = message
        }
        let continuation = entry.continuation
        entry.continuation = nil
        continuation?.resume(throwing: error)
    }

    private func discardResultState() {
        guard Self.isTrustedAlfredURL(webView.url) else { return }
        webView.evaluateJavaScript("try { delete window.__hanaResultState; } catch (e) {}", completionHandler: nil)
    }

    /// jsonArgs == nil: snapshot (root/first/last row identity + empty draft) and store nonce-scoped refs.
    /// jsonArgs != nil: re-verify the same refs and an EXACT empty #afInput, then call openQuery once.
    private static func resultScript(nonce: String, jsonArgs: String?, options: HanaProtectedOptions = HanaProtectedOptions(), background: Bool = false) -> String {
        var expectedContext: Any = NSNull()
        if let value = options.expectedHostContext { expectedContext = value }
        let nonceLiteral = (try? JSONSerialization.data(withJSONObject: [nonce, options.expectedDraft, expectedContext], options: []))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\",\"\",\"\"]"
        let send = jsonArgs != nil
        return """
        (() => {
            const nonce = (\(nonceLiteral))[0];
            const expected = (\(nonceLiteral))[1];
            const expectedContext = (\(nonceLiteral))[2];
            // Exact raw host context (account|project|thread with the page generation) when the caller pinned one.
            const contextOK = () => {
                if (typeof expectedContext !== 'string') return true;
                try {
                    return !!(window.HanstreeAlfred && typeof window.HanstreeAlfred.hostContext === 'function' &&
                        window.HanstreeAlfred.hostContext() === expectedContext);
                } catch (e) { return false; }
            };
            const send = \(send ? "true" : "false");
            const completion = \(options.completion ? "true" : "false");
            const background = \(background ? "true" : "false");
            const fail = (s) => (send ? 'changed' : s);
            const root = document.querySelector('#afMessages');
            const input = document.querySelector('#afInput');
            const textarea = (input && input.tagName === 'TEXTAREA') ? input : null;
            const shown = (el) => {
                const s = window.getComputedStyle(el);
                if (s.display === 'none' || s.visibility === 'hidden') return false;
                if (background) return true;
                const r = el.getBoundingClientRect();
                return r.width > 0 && r.height > 0;
            };
            if (!contextOK()) return fail('context');
            if (!root || !document.contains(root) || !shown(root)) return fail('noRoot');
            const login = document.querySelector('#afLogin');
            if (login && shown(login)) return fail('login');
            if (!textarea) return fail('noInput');
            if (textarea.value !== expected) return fail('draft');
            if (completion) {
                if (root.querySelector('.af-share-controls[data-streaming="true"]')) return fail('busy');
                if (document.activeElement === textarea && document.hasFocus()) return fail('focused');
            }
            const rows = Array.from(root.querySelectorAll(':scope > .af-msg-row')).filter(shown);
            const first = rows.length ? rows[0] : null;
            const last = rows.length ? rows[rows.length - 1] : null;
            const len = last ? (last.textContent || '').length : 0;
            if (!send) {
                window.__hanaResultState = { nonce: nonce, root: root, input: textarea, first: first, last: last, len: len, count: rows.length };
                return 'ok';
            }
            const st = window.__hanaResultState;
            try { delete window.__hanaResultState; } catch (e) {}
            if (!st || st.nonce !== nonce || st.root !== root || st.input !== textarea ||
                st.first !== first || st.last !== last || st.len !== len || st.count !== rows.length) return 'changed';
            if (!(window.HanstreeAlfred && typeof window.HanstreeAlfred.openQuery === 'function')) return 'unavailable';
            // Same evaluation as the openQuery call below: no asynchronous gap for the account/project/thread to change.
            if (!contextOK()) return 'changed';
            const accepted = window.HanstreeAlfred.openQuery((\(jsonArgs ?? "[\"\"]"))[0]) === true;
            // Page-context question: the typed draft was consumed by this send; clear it only if it is still exactly that draft.
            if (accepted && expected !== '' && textarea.value === expected) {
                textarea.value = '';
                textarea.dispatchEvent(new Event('input', { bubbles: true }));
            }
            return accepted ? 'accepted' : 'rejected';
        })()
        """
    }

    private func drainQueue() {
        guard !isDispatching else { return }
        guard !hasAmbiguousError else { return }
        guard isBridgeReady else { return }
        guard !pendingQueue.isEmpty else { return }
        guard Self.isTrustedAlfredURL(webView.url) else { return }

        if let entry = protectedEntry, entry.enqueued {
            dispatchProtected(entry)
            return
        }

        let question = pendingQueue[0]
        let currentGen = self.navigationGeneration

        guard let data = try? JSONSerialization.data(withJSONObject: [question], options: []),
              let jsonArgs = String(data: data, encoding: .utf8) else {
            statusMessage = "질문 인코딩 오류"
            return
        }

        isDispatching = true
        let script = "(() => { if (window.HanstreeAlfred && typeof window.HanstreeAlfred.openQuery === 'function') { return window.HanstreeAlfred.openQuery((\(jsonArgs))[0]) === true; } return false; })()"

        webView.evaluateJavaScript(script) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                guard self.navigationGeneration == currentGen else {
                    self.isDispatching = false
                    return
                }
                self.isDispatching = false

                if let error = error {
                    _ = error
                    self.hasAmbiguousError = true
                    self.statusMessage = "전송 결과를 확인할 수 없습니다. 대화를 확인한 뒤 다시 시도해 주세요. 중복될 수 있습니다."
                    return
                }

                if let accepted = result as? Bool, accepted == true {
                    self.hasAmbiguousError = false
                    self.statusMessage = nil
                    if !self.pendingQueue.isEmpty {
                        self.pendingQueue.removeFirst()
                        self.pendingQueueCount = self.pendingQueue.count
                    }
                    if !self.pendingQueue.isEmpty {
                        self.drainQueue()
                    }
                } else {
                    self.statusMessage = "질문이 아직 접수되지 않았습니다. 다시 시도해 주세요."
                }
            }
        }
    }
}

// MARK: - Trusted typed delegation (HTT embedded Hana only)

@MainActor
final class HanaDelegationMessageHandler: NSObject, WKScriptMessageHandler {
    weak var host: HanaPanelHost?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        host?.handleDelegationMessage(message)
    }
}

extension HanaPanelHost {
    /// Whole-utterance Korean command: optional 이건/이거/이걸 + 플래너/플레너(에게/한테) + 맡겨줘/맡겨 주세요/넘겨줘 + punctuation only.
    /// The isolated script embeds this same source, so both sides accept exactly the same sentences.
    static let delegationPattern = #"^(?:(?:이건|이거|이걸)\s*)?(?:플래너|플레너)(?:에게|한테)?\s*(?:맡겨\s?줘|맡겨\s?주세요|넘겨\s?줘)[\s.!~]*$"#

    /// Explicit reference to the page the user is looking at ('현재 페이지', '이 페이지', '현재 보고 있는 페이지'). Embedded in the script too.
    static let pageContextPattern = #"(?:현재\s*(?:(?:보고\s*있는|보는|열려\s*있는|열린)\s*)?(?:웹\s*)?페이지(?!네이)|이\s*(?:웹\s*)?페이지(?!네이))"#
    /// Negated / refusing wording is a description, not a request to read the page.
    static let pageContextNegation = #"(?:지\s*마|지\s*말|말고|말아|필요\s*없|불\s*필요|아니|않|싫)"#
    /// An explicit request (read/summarize/organize/analyze/explain/translate + 줘/봐/주세요…) or a real question (무슨/뭐/어떤 … ?).
    /// A bare noun such as '요약' or '읽기' is not a request. Embedded in the script too.
    static let pageRequestPattern = #"(?:(?:읽어|요약해|요약\s*좀\s*해|요약\s*부탁|정리해|정리\s*좀\s*해|분석해|분석\s*좀\s*해|설명해|설명\s*좀\s*해|번역해|번역\s*좀\s*해)\s*(?:줘|주세|주실|줄래|주라|주십|봐|보세|달라|라(?![가-힣])|요)|(?:무슨|뭐|뭘|무엇|어떤)[^?？]*[?？])"#

    /// Whole-text decision: a reference AND an explicit request, no negation, no quotation marks (quoted text is a description, not a command).
    static func isPageContextQuestion(_ raw: String) -> Bool {
        let text = raw.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf16.count <= 10_000 else { return false }
        let quotes = CharacterSet(charactersIn: "\"'`\u{201C}\u{201D}\u{2018}\u{2019}\u{300C}\u{300D}\u{300E}\u{300F}")
        guard text.rangeOfCharacter(from: quotes) == nil else { return false }
        return text.range(of: pageContextPattern, options: .regularExpression) != nil &&
            text.range(of: pageRequestPattern, options: .regularExpression) != nil &&
            text.range(of: pageContextNegation, options: .regularExpression) == nil
    }

    static func isDelegationUtterance(_ raw: String) -> Bool {
        let text = raw.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf16.count <= 200 else { return false }
        return text.range(of: delegationPattern, options: .regularExpression) != nil
    }

    /// Runs only in the private "HanaDelegation" content world of the main frame at the exact HTT Hana URL.
    /// It posts a request only for a native-trusted Enter on #afInput / click on #afSend whose whole text is the command.
    /// A trusted `submit` on the same form is only swallowed as a duplicate of that gesture, never a trigger of its own
    /// (a page script can fire a trusted submit via requestSubmit()).
    static let delegationScript = #"""
    (() => {
        'use strict';
        const L = window.location;
        if (window.top !== window || L.protocol !== 'https:' || L.hostname !== '\#(trustedHost)' ||
            L.port !== '\#(trustedPort)' || L.pathname !== '\#(trustedPath)' || L.search !== '') return;
        const channel = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\#(delegationHandlerName);
        if (!channel || window.__hdeleg) return;
        const PATTERN = /\#(delegationPattern)/u;
        const PAGE_REF = /\#(pageContextPattern)/u;
        const PAGE_NEG = /\#(pageContextNegation)/u;
        const PAGE_REQ = /\#(pageRequestPattern)/u;
        const QUOTE = /["'`“”‘’「」『』]/u;
        const hex = () => Array.from(crypto.getRandomValues(new Uint8Array(16)), (b) => b.toString(16).padStart(2, '0')).join('');
        const docID = hex();
        let nonce = null, pending = null, handledAt = -1e9, watching = null;
        const origins = new Map();
        const input = () => { const e = document.getElementById('afInput'); return e && e.tagName === 'TEXTAREA' ? e : null; };
        // Off until native confirms the common planner does not own the control sentence (see setDelegate).
        let delegateOn = false;
        const control = (v) => { const t = String(v).normalize('NFC').trim(); return delegateOn && t.length > 0 && t.length <= 200 && PATTERN.test(t); };
        const pageAsk = (v) => { const t = String(v).normalize('NFC').trim(); return t.length > 0 && t.length <= 10000 && PAGE_REF.test(t) && PAGE_REQ.test(t) && !PAGE_NEG.test(t) && !QUOTE.test(t); };
        const kindOf = (v) => control(v) ? 'delegate' : (pageAsk(v) ? 'pageContext' : null);
        // Anything the user attached to this message would be lost by a native re-send: then the site sends it untouched.
        const attached = (ta) => {
            const scope = ta.form || ta.parentElement;
            if (!scope) return true;
            for (const f of scope.querySelectorAll('input[type="file"]')) { if (f.files && f.files.length > 0) return true; }
            for (const el of scope.querySelectorAll('[class*="attach" i], [class*="upload" i], [class*="file-chip" i], [class*="thumb" i], [class*="preview" i]')) {
                if (['BUTTON', 'LABEL', 'INPUT', 'SVG', 'svg'].includes(el.tagName)) continue;
                const r = el.getBoundingClientRect();
                if (r.width <= 0 || r.height <= 0) continue;
                if (el.querySelector('img, canvas, video') || Array.from(el.childNodes).some((n) => n.nodeType === 3 && n.textContent.trim())) return true;
            }
            return false;
        };
        const firstUser = (root) => root.querySelector(':scope > .af-msg-row.user');
        const convoID = (root) => root.getAttribute('data-conversation-id') || root.getAttribute('data-conv-id') || root.getAttribute('data-chat-id') || null;
        const post = (m) => { try { channel.postMessage(m); return true; } catch (e) { return false; } };
        const drop = (token) => { const o = origins.get(token); if (o) { if (o.mo) o.mo.disconnect(); origins.delete(token); } };
        // Origin = this #afMessages root + (stable conversation id if the DOM has one, else the FIRST user row). No contents kept.
        const register = () => {
            const root = document.getElementById('afMessages');
            if (!root || !root.isConnected) return null;
            if (origins.size >= 16) return null;
            const token = hex();
            const o = { root: root, first: firstUser(root), cid: convoID(root), ok: true, mo: null };
            o.valid = () => o.root.isConnected && document.getElementById('afMessages') === o.root &&
                (o.cid ? convoID(o.root) === o.cid : firstUser(o.root) === o.first);
            // Informs native only (lost / back, metadata); a mutation never triggers anything by itself.
            o.mo = new MutationObserver(() => {
                const ok = o.valid();
                if (ok === o.ok) return;
                o.ok = ok;
                post({ type: ok ? 'originBack' : 'originLost', docID: docID, nonce: nonce || '', origin: token });
            });
            o.mo.observe(root, { childList: true });
            if (root.parentNode) o.mo.observe(root.parentNode, { childList: true });
            origins.set(token, o);
            return token;
        };
        // Metadata-only wake-ups while a completion notice waits: draft edited/blurred, tab visibility, streaming flag, new rows.
        const notify = (() => {
            let queued = false;
            return () => {
                if (queued) return;
                queued = true;
                setTimeout(() => { queued = false; post({ type: 'stateChanged', docID: docID, nonce: nonce || '' }); }, 300);
            };
        })();
        const watch = (on) => {
            if (!on) { if (watching) { watching.stop(); watching = null; } return; }
            if (watching) return;
            const root = document.getElementById('afMessages');
            const ta = input();
            const observers = [];
            if (root) {
                const rows = new MutationObserver(notify);
                rows.observe(root, { childList: true });
                const flag = new MutationObserver(notify);
                flag.observe(root, { attributes: true, attributeFilter: ['data-streaming'], subtree: true });
                observers.push(rows, flag);
            }
            if (ta) { ta.addEventListener('input', notify); ta.addEventListener('blur', notify); }
            document.addEventListener('visibilitychange', notify);
            watching = { stop: () => {
                observers.forEach((m) => m.disconnect());
                if (ta) { ta.removeEventListener('input', notify); ta.removeEventListener('blur', notify); }
                document.removeEventListener('visibilitychange', notify);
            } };
        };
        const attempt = (e, ta) => {
            const kind = kindOf(ta.value);
            if (!kind) return;
            if (kind === 'pageContext' && attached(ta)) return;
            e.preventDefault();
            e.stopImmediatePropagation();
            handledAt = e.timeStamp;
            if (pending) return;
            const requestID = crypto.randomUUID();
            const origin = register();
            pending = { requestID: requestID, origin: origin };
            if (!post({ type: kind, docID: docID, nonce: nonce || '', requestID: requestID, text: ta.value, origin: origin || '' })) {
                if (origin) drop(origin);
                pending = null;
            }
        };
        window.addEventListener('keydown', (e) => {
            if (!e.isTrusted || e.key !== 'Enter' || e.shiftKey || e.ctrlKey || e.metaKey || e.altKey ||
                e.isComposing || e.keyCode === 229 || e.repeat) return;
            const ta = input();
            if (ta && e.target === ta) attempt(e, ta);
        }, true);
        window.addEventListener('click', (e) => {
            if (!e.isTrusted || !e.target || !e.target.closest) return;
            const send = document.getElementById('afSend');
            const ta = input();
            if (send && send.tagName === 'BUTTON' && ta && e.target.closest('#afSend') === send) attempt(e, ta);
        }, true);
        window.addEventListener('submit', (e) => {
            const ta = input();
            if (!e.isTrusted || !ta || !ta.form || e.target !== ta.form || !kindOf(ta.value)) return;
            if (pending || e.timeStamp - handledAt < 1500) { e.preventDefault(); e.stopImmediatePropagation(); }
        }, true);
        // Native-only surface (this world is invisible to the page). grant is honoured once and only for this document.
        window.__hdeleg = {
            grant: (id, n) => { if (id === docID && nonce === null) nonce = n; },
            release: (rid, ok) => {
                if (pending && pending.requestID === rid) { if (!ok && pending.origin) drop(pending.origin); pending = null; }
            },
            origin: (token) => origins.get(token) || null,
            drop: drop,
            watch: watch,
            setDelegate: (on) => { delegateOn = on === true; }
        };
        post({ type: 'ready', docID: docID });
    })();
    """#

    private static func scriptLiteral(_ values: [String]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: values, options: []) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func runDelegationScript(_ script: String) {
        guard Self.isTrustedAlfredURL(webView.url) else { return }
        webView.evaluateJavaScript(script, in: nil, in: Self.delegationWorld, completionHandler: nil)
    }

    private func releaseDelegationInScript(requestID: UUID, accepted: Bool) {
        guard let literal = Self.scriptLiteral([requestID.uuidString.lowercased()]) else { return }
        runDelegationScript("window.__hdeleg && window.__hdeleg.release((\(literal))[0], \(accepted ? "true" : "false"))")
    }

    /// Only the normal BrowserPane binds this; the handler receives a fully validated request.
    func bindDelegation(owner: UUID, handler: @escaping (HanaDelegationRequest) -> Void,
                        pageContext: ((HanaDelegationRequest) -> Void)? = nil) {
        delegationOwnerID = owner
        onDelegationRequest = handler
        onPageContextRequest = pageContext
    }

    func releaseDelegation(owner: UUID) {
        guard delegationOwnerID == owner else { return }
        delegationOwnerID = nil
        onDelegationRequest = nil
        onPageContextRequest = nil
    }

    // MARK: - Explicit current-page question (trusted typed gesture, same isolated world)

    /// The request must still be the active one on the same document with its origin conversation unchanged.
    func isPageContextCurrent(_ request: HanaDelegationRequest) -> Bool {
        activePageContext?.requestID == request.requestID && originIsCurrent(request)
    }

    /// Ends the active page-context request. A failure keeps the typed draft untouched and shows the real reason.
    func finishPageContext(_ request: HanaDelegationRequest, error: String?) {
        guard activePageContext?.requestID == request.requestID else { return }
        activePageContext = nil
        releaseOrigin(request.originToken)
        if let error = error { statusMessage = error }
        releaseDelegationInScript(requestID: request.requestID, accepted: error == nil)
    }

    /// Sends the already formatted prompt through the protected FIFO to the SAME Hana conversation the question was typed in.
    /// The exact raw draft is consumed only after Hana's openQuery returned true; throws (draft kept) otherwise.
    func sendPageContextPrompt(_ prompt: String, request: HanaDelegationRequest) async throws {
        try await submitPlannerResultQuestion(
            payload: prompt,
            requestID: request.requestID,
            isCurrent: { [weak self] in self?.isPageContextCurrent(request) ?? false },
            options: HanaProtectedOptions(origin: request, expectedDraft: request.utterance)
        )
    }

    // MARK: - Automatic completion notice (only runs started by an accepted typed delegation)

    /// Called once from the real `.done` path. Runs this host did not start (no association) are ignored.
    /// `payload` is evaluated once; `note` writes a short status line into that run's own project chat.
    func runCompleted(projectID: UUID, runID: UUID, payload: () -> String?, note: @escaping (String) -> Void) {
        guard let association = delegationAssociations.first(where: { $0.projectID == projectID && $0.runID == runID }),
              completionDeliveries[runID] == nil, !completedDeliveryRunIDs.contains(runID) else { return }
        guard let text = payload() else {
            releaseAssociation(runID: runID, recordCompleted: true)
            note("완료 알림 내용을 만들지 못해 하나에 보내지 않았습니다. 결과는 이 프로젝트에서 확인해 주세요.")
            return
        }
        let delivery = HanaCompletionDelivery(association: association, payload: text, note: note)
        completionDeliveries[runID] = delivery
        attemptCompletion(delivery)
        syncCompletionWatch()
    }

    /// Genuine non-completed terminal end (failed/cancelled/...): releases exactly this association/origin and sends no notice.
    func runEnded(projectID: UUID, runID: UUID) {
        guard delegationAssociations.contains(where: { $0.projectID == projectID && $0.runID == runID }) else { return }
        completionDeliveries.removeValue(forKey: runID)
        releaseAssociation(runID: runID, recordCompleted: true)
        syncCompletionWatch()
    }

    fileprivate func attemptPendingCompletions() {
        for delivery in Array(completionDeliveries.values) { attemptCompletion(delivery) }
        syncCompletionWatch()
    }

    /// One attempt per real state change. A definite refusal keeps the notice PENDING; an uncertain one is never retried.
    private func attemptCompletion(_ delivery: HanaCompletionDelivery) {
        let association = delivery.association
        let runID = association.runID
        guard delivery.state == .pending, completionDeliveries[runID] === delivery else { return }
        guard delegationOriginMayReturn(association) else {
            holdCompletion(delivery)
            return
        }
        delivery.state = .sending
        Task { @MainActor in
            var failure: HanaResultQuestionError?
            do {
                try await submitPlannerResultQuestion(
                    payload: delivery.payload,
                    requestID: runID,
                    isCurrent: { [weak self, weak delivery] in
                        guard let self = self, let delivery = delivery else { return false }
                        return self.completionDeliveries[runID] === delivery && self.delegationOriginMayReturn(association)
                    },
                    options: HanaProtectedOptions(origin: association.request, completion: true)
                )
            } catch {
                failure = (error as? HanaResultQuestionError)
                    ?? HanaResultQuestionError(message: "전송 결과를 확인할 수 없습니다.", ambiguous: true)
            }
            guard self.completionDeliveries[runID] === delivery else { return }
            if let failure = failure {
                if failure.ambiguous {
                    delivery.state = .uncertain
                    delivery.note("하나에 완료 알림이 전달됐는지 확인할 수 없습니다. 자동으로 다시 보내지 않습니다. 하나 대화에서 확인해 주세요.")
                    self.completionDeliveries.removeValue(forKey: runID)
                    self.releaseAssociation(runID: runID, recordCompleted: true)
                } else {
                    delivery.state = .pending
                    self.holdCompletion(delivery)
                }
            } else {
                self.completionDeliveries.removeValue(forKey: runID)
                self.releaseAssociation(runID: runID, recordCompleted: true)
                delivery.note("하나 대화에 완료 알림을 전달했습니다.")
            }
            self.syncCompletionWatch()
        }
    }

    /// Keeps the notice pending with one truthful line, or ends it when the document was replaced (origin unprovable).
    fileprivate func holdCompletion(_ delivery: HanaCompletionDelivery) {
        if delivery.association.request.generation != navigationGeneration {
            completionDeliveries.removeValue(forKey: delivery.association.runID)
            releaseAssociation(runID: delivery.association.runID, recordCompleted: true)
            delivery.note("원래 하나 화면이 다시 열려 같은 대화인지 확인할 수 없습니다. 완료 알림을 보내지 않았습니다. 결과는 이 프로젝트에서 확인해 주세요.")
        } else if !delivery.heldNoted {
            delivery.heldNoted = true
            delivery.note("원래 하나 대화가 사용 중이거나 다른 대화가 열려 있어 완료 알림을 보류했습니다. 원래 대화로 돌아와 입력이 비면 한 번 알려 드립니다.")
        }
    }

    /// Wake-up signals exist only while some notice is pending on the current document.
    private func syncCompletionWatch() {
        let needed = completionDeliveries.values.contains {
            $0.state == .pending && $0.association.request.generation == navigationGeneration
        }
        guard needed != completionWatching else { return }
        completionWatching = needed
        runDelegationScript("window.__hdeleg && window.__hdeleg.watch(\(needed ? "true" : "false"))")
    }

    fileprivate func ensureCompletionReady() throws {
        guard Self.isTrustedAlfredURL(webView.url), !webView.isLoading, !isLoading, isBridgeReady else {
            throw HanaHandoffError(message: "하나 대화창이 아직 준비되지 않았습니다.")
        }
    }

    private func originIsCurrent(_ request: HanaDelegationRequest) -> Bool {
        request.generation == navigationGeneration && delegationDoc?.docID == request.docID &&
            delegationDoc?.nonce == request.docNonce && !lostDelegationOrigins.contains(request.originToken)
    }

    /// Native identity check plus the isolated script's own origin record (same #afMessages and same conversation).
    fileprivate func isDelegationOriginLive(_ request: HanaDelegationRequest) async -> Bool {
        guard originIsCurrent(request), let literal = Self.scriptLiteral([request.originToken]) else { return false }
        let generation = navigationGeneration
        let script = "(() => { const b = window.__hdeleg; const o = b ? b.origin((\(literal))[0]) : null; return !!(o && o.valid()); })()"
        let result = try? await evaluateHandoffScript(script, world: Self.delegationWorld)
        return (result as? Bool) == true && generation == navigationGeneration && originIsCurrent(request)
    }

    func isDelegationCurrent(_ request: HanaDelegationRequest) -> Bool {
        (try? ensureDelegationCurrent(request)) != nil
    }

    /// Ends the active request. Failure keeps the typed draft (nothing is cleared here) and shows the real error;
    /// success is remembered (bounded) so a replayed requestID can never create a second project.
    func finishDelegation(_ request: HanaDelegationRequest, error: String?, accepted: Bool = false) {
        guard activeDelegation?.requestID == request.requestID else { return }
        activeDelegation = nil
        if accepted {
            acceptedDelegationIDs.append(request.requestID)
            if acceptedDelegationIDs.count > 32 { acceptedDelegationIDs.removeFirst(acceptedDelegationIDs.count - 32) }
        } else {
            lostDelegationOrigins.remove(request.originToken)
            if let error = error { statusMessage = error }
        }
        releaseDelegationInScript(requestID: request.requestID, accepted: accepted)
    }

    /// Outstanding origins/associations are bounded; nothing running or pending is ever evicted to make room.
    static let maxOutstandingOrigins = 16

    /// Forgets one origin natively and in the isolated script (no-op when the document was replaced).
    private func releaseOrigin(_ token: String) {
        lostDelegationOrigins.remove(token)
        if let literal = Self.scriptLiteral([token]) {
            runDelegationScript("window.__hdeleg && window.__hdeleg.drop((\(literal))[0])")
        }
    }

    /// Releases exactly one association and its own origin; completedIDs keeps the anti-replay record.
    private func releaseAssociation(runID: UUID, recordCompleted: Bool) {
        if recordCompleted {
            completedDeliveryRunIDs.append(runID)
            if completedDeliveryRunIDs.count > 32 { completedDeliveryRunIDs.removeFirst(completedDeliveryRunIDs.count - 32) }
        }
        guard let index = delegationAssociations.firstIndex(where: { $0.runID == runID }) else { return }
        releaseOrigin(delegationAssociations.remove(at: index).request.originToken)
    }

    /// Binds the accepted request to its ACTUAL project/run for the completion notification (milestone 2).
    func registerDelegation(_ request: HanaDelegationRequest, projectID: UUID, runID: UUID) {
        guard (try? ensureDelegationCurrent(request)) != nil else { releaseOrigin(request.originToken); return }
        delegationAssociations.append(HanaDelegationAssociation(request: request, projectID: projectID, runID: runID))
    }

    /// False once the isolated script reported that the origin conversation was replaced or removed.
    func delegationOriginMayReturn(_ association: HanaDelegationAssociation) -> Bool {
        originIsCurrent(association.request)
    }

    fileprivate func handleDelegationMessage(_ message: WKScriptMessage) {
        let frame = message.frameInfo
        guard message.webView === webView, message.world === Self.delegationWorld, frame.isMainFrame,
              frame.securityOrigin.protocol.lowercased() == "https",
              frame.securityOrigin.host.lowercased() == Self.trustedHost,
              frame.securityOrigin.port == Self.trustedPort,
              Self.isTrustedAlfredURL(frame.request.url), Self.isTrustedAlfredURL(webView.url),
              let body = message.body as? [String: Any], let type = body["type"] as? String,
              let docID = body["docID"] as? String, docID.utf16.count == 32 else { return }

        if type == "ready" {
            // The handshake only hands this document its nonce; it authorises no job.
            let doc = (docID: docID, nonce: UUID().uuidString, generation: navigationGeneration)
            delegationDoc = doc
            if let ids = Self.scriptLiteral([doc.docID, doc.nonce]) {
                runDelegationScript("window.__hdeleg && window.__hdeleg.grant((\(ids))[0], (\(ids))[1])")
            }
            // The private control-sentence trigger runs only when the common planner is not attached to this panel.
            if !commonPlannerOwnsDelegation {
                runDelegationScript("window.__hdeleg && window.__hdeleg.setDelegate(true)")
            }
            return
        }

        let requestUUID = (body["requestID"] as? String).flatMap { UUID(uuidString: $0) }
        func reject(_ text: String) {
            statusMessage = text
            if let id = requestUUID { releaseDelegationInScript(requestID: id, accepted: false) }
        }
        guard let doc = delegationDoc, doc.docID == docID, doc.generation == navigationGeneration,
              (body["nonce"] as? String) == doc.nonce else {
            if type == "delegate" || type == "pageContext" { reject("플래너 연결이 아직 준비되지 않았습니다. 잠시 후 다시 보내 주세요. 입력은 그대로 둡니다.") }
            return
        }

        switch type {
        case "originLost", "originBack":
            if let origin = body["origin"] as? String,
               activeDelegation?.originToken == origin || activePageContext?.originToken == origin ||
                delegationAssociations.contains(where: { $0.request.originToken == origin }) {
                if type == "originLost" {
                    lostDelegationOrigins.insert(origin)
                } else {
                    lostDelegationOrigins.remove(origin)
                    attemptPendingCompletions()
                }
            }
        case "stateChanged":
            attemptPendingCompletions()
        case "pageContext":
            guard let requestID = requestUUID else { return }
            guard activeDelegation == nil, activePageContext == nil, !isCapturingPlannerHandoff, protectedEntry == nil else {
                reject("이미 하나 요청을 처리하는 중입니다. 입력은 그대로 둡니다.")
                return
            }
            guard delegationAssociations.count < Self.maxOutstandingOrigins else {
                reject("진행 중이거나 알림을 기다리는 플래너 작업이 \(Self.maxOutstandingOrigins)개로 가득 차 보내지 않았습니다. 작업이 끝난 뒤 다시 시도해 주세요. 입력은 그대로 둡니다.")
                return
            }
            guard let text = body["text"] as? String, text.utf16.count <= 10_000, Self.isPageContextQuestion(text),
                  let origin = body["origin"] as? String, origin.utf16.count == 32 else {
                reject("현재 페이지 질문으로 확인하지 못해 보내지 않았습니다. 입력은 그대로 둡니다.")
                return
            }
            guard isPanelOpen, isBridgeReady, !isLoading, let handler = onPageContextRequest else {
                reject("지금은 일반 브라우저 화면의 하나 대화창에서만 현재 페이지를 읽을 수 있습니다. 입력은 그대로 둡니다.")
                return
            }
            let request = HanaDelegationRequest(requestID: requestID, docID: doc.docID, docNonce: doc.nonce,
                                                generation: doc.generation, originToken: origin, utterance: text)
            activePageContext = request
            handler(request)
        case "delegate":
            guard let requestID = requestUUID else { return }
            guard !acceptedDelegationIDs.contains(requestID), activeDelegation == nil, activePageContext == nil, !isCapturingPlannerHandoff else {
                reject("이미 플래너로 넘기는 중이거나 처리된 요청입니다. 입력은 그대로 둡니다.")
                return
            }
            guard delegationAssociations.count < Self.maxOutstandingOrigins else {
                reject("진행 중이거나 알림을 기다리는 플래너 작업이 \(Self.maxOutstandingOrigins)개로 가득 차 플래너로 넘기지 않았습니다. 작업이 끝난 뒤 다시 시도해 주세요. 입력은 그대로 둡니다.")
                return
            }
            guard let text = body["text"] as? String, text.utf16.count <= 10_000, Self.isDelegationUtterance(text),
                  let origin = body["origin"] as? String, origin.utf16.count == 32 else {
                reject("하나 대화를 확인하지 못해 플래너로 넘기지 않았습니다. 입력은 그대로 둡니다.")
                return
            }
            guard isPanelOpen, isBridgeReady, !isLoading, let handler = onDelegationRequest else {
                reject("지금은 일반 브라우저 화면의 하나 대화창에서만 플래너로 넘길 수 있습니다. 입력은 그대로 둡니다.")
                return
            }
            let request = HanaDelegationRequest(requestID: requestID, docID: doc.docID, docNonce: doc.nonce,
                                                generation: doc.generation, originToken: origin, utterance: text)
            activeDelegation = request
            handler(request)
        default:
            break
        }
    }
}

@MainActor
final class HanaNavigationDelegate: NSObject, WKNavigationDelegate {
    weak var host: HanaPanelHost?

    init(host: HanaPanelHost) {
        self.host = host
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }

        if navigationAction.navigationType == .linkActivated {
            if !HanaPanelHost.isSameOrigin(url) {
                decisionHandler(.cancel)
                if let onOpen = host?.onOpenExternalURL {
                    onOpen(url)
                } else {
                    host?.statusMessage = "외부 링크는 브라우저 탭에서만 열 수 있습니다."
                }
                return
            }
        }

        if HanaPanelHost.isSameOrigin(url) {
            decisionHandler(.allow)
            return
        }

        decisionHandler(.cancel)
        host?.statusMessage = "허용되지 않은 외부 주소 연결이 차단되었습니다."
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        host?.handleDidStartProvisionalNavigation()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        host?.handleDidFinishNavigation()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        host?.handleNavigationFailure(error: error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        host?.handleNavigationFailure(error: error)
    }
}

@MainActor
final class HanaUIDelegate: NSObject, WKUIDelegate {
    weak var host: HanaPanelHost?
    private var isPresentingAlert = false
    private weak var activeAlertWindow: NSWindow?
    private var isPresentingOpenPanel = false
    private weak var activeOpenPanelWindow: NSWindow?
    private var activeOpenPanel: NSOpenPanel?
    private var pendingOpenPanelCompletion: (([URL]?) -> Void)?
    private var activeOpenPanelToken = UUID()

    init(host: HanaPanelHost) {
        self.host = host
    }

    func dismissActiveAlert() {
        if let sheet = activeAlertWindow?.attachedSheet {
            activeAlertWindow?.endSheet(sheet, returnCode: .alertSecondButtonReturn)
        }
        isPresentingAlert = false
        activeAlertWindow = nil

        cancelOpenPanel()
    }

    func cancelOpenPanel() {
        activeOpenPanelToken = UUID()
        if let panel = activeOpenPanel {
            activeOpenPanelWindow?.endSheet(panel, returnCode: .cancel)
        }
        let completion = pendingOpenPanelCompletion
        pendingOpenPanelCompletion = nil
        isPresentingOpenPanel = false
        activeOpenPanelWindow = nil
        activeOpenPanel = nil
        completion?(nil)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            if HanaPanelHost.isSameOrigin(url) {
                webView.load(navigationAction.request)
            } else {
                host?.onOpenExternalURL?(url)
            }
        }
        return nil
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        var didComplete = false
        func completeOnce(_ result: Bool) {
            guard !didComplete else { return }
            didComplete = true
            completionHandler(result)
        }

        // Validate exact mainframe and current page
        guard frame.isMainFrame,
              let frameURL = frame.request.url,
              HanaPanelHost.isTrustedAlfredURL(frameURL),
              HanaPanelHost.isTrustedAlfredURL(webView.url) else {
            completeOnce(false)
            return
        }

        // Host panel must be open, window visible, and NSApp active
        guard let host = self.host,
              host.isPanelOpen,
              let window = webView.window,
              window.isVisible,
              NSApp.isActive else {
            completeOnce(false)
            return
        }

        // Prevent overlapping dialogs
        guard !isPresentingAlert else {
            completeOnce(false)
            return
        }

        isPresentingAlert = true
        activeAlertWindow = window

        let alert = NSAlert()
        alert.messageText = "알림"
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "확인")
        alert.addButton(withTitle: "취소")

        alert.beginSheetModal(for: window) { [weak self, weak webView] response in
            Task { @MainActor in
                defer {
                    self?.isPresentingAlert = false
                    self?.activeAlertWindow = nil
                }
                guard let self = self,
                      let host = self.host,
                      host.isPanelOpen,
                      let webView = webView,
                      let currentWindow = webView.window,
                      currentWindow.isVisible,
                      NSApp.isActive,
                      HanaPanelHost.isTrustedAlfredURL(webView.url) else {
                    completeOnce(false)
                    return
                }

                completeOnce(response == .alertFirstButtonReturn)
            }
        }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        var didComplete = false
        func completeOnce() {
            guard !didComplete else { return }
            didComplete = true
            completionHandler()
        }

        guard frame.isMainFrame,
              let frameURL = frame.request.url,
              HanaPanelHost.isTrustedAlfredURL(frameURL),
              HanaPanelHost.isTrustedAlfredURL(webView.url) else {
            completeOnce()
            return
        }

        guard let host = self.host,
              host.isPanelOpen,
              let window = webView.window,
              window.isVisible,
              NSApp.isActive else {
            completeOnce()
            return
        }

        guard !isPresentingAlert else {
            completeOnce()
            return
        }

        isPresentingAlert = true
        activeAlertWindow = window

        let alert = NSAlert()
        alert.messageText = "알림"
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "확인")

        alert.beginSheetModal(for: window) { [weak self] _ in
            Task { @MainActor in
                self?.isPresentingAlert = false
                self?.activeAlertWindow = nil
                completeOnce()
            }
        }
    }

    @available(macOS 27.0, *)
    func webView(
        _ webView: WKWebView,
        requestGeolocationPermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        var didDecide = false
        func decideOnce(_ decision: WKPermissionDecision) {
            guard !didDecide else { return }
            didDecide = true
            decisionHandler(decision)
        }

        guard frame.isMainFrame,
              origin.protocol.lowercased() == "https",
              origin.host.lowercased() == HanaPanelHost.trustedHost,
              origin.port == HanaPanelHost.trustedPort,
              let frameURL = frame.request.url,
              HanaPanelHost.isTrustedAlfredURL(frameURL),
              HanaPanelHost.isTrustedAlfredURL(webView.url),
              let host = self.host,
              host.isPanelOpen,
              let window = webView.window,
              window.isVisible,
              NSApp.isActive else {
            decideOnce(.deny)
            return
        }

        decideOnce(.prompt)
    }

    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping ([URL]?) -> Void
    ) {
        var didComplete = false
        func completeOnce(_ result: [URL]?) {
            guard !didComplete else { return }
            didComplete = true
            completionHandler(result)
        }

        // Validate exact mainframe and current page
        guard frame.isMainFrame,
              let frameURL = frame.request.url,
              HanaPanelHost.isTrustedAlfredURL(frameURL),
              HanaPanelHost.isTrustedAlfredURL(webView.url) else {
            completeOnce(nil)
            return
        }

        // Host panel must be open, window visible, and NSApp active
        guard let host = self.host,
              host.isPanelOpen,
              let window = webView.window,
              window.isVisible,
              NSApp.isActive else {
            completeOnce(nil)
            return
        }

        // Reject concurrent picker/dialog
        guard !isPresentingAlert, !isPresentingOpenPanel else {
            completeOnce(nil)
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection

        let pickerToken = UUID()
        activeOpenPanelToken = pickerToken
        isPresentingOpenPanel = true
        activeOpenPanelWindow = window
        activeOpenPanel = panel
        pendingOpenPanelCompletion = { urls in
            completeOnce(urls)
        }

        panel.beginSheetModal(for: window) { [weak self, weak webView] response in
            let selectedURLs = response == .OK ? panel.urls : nil
            Task { @MainActor in
                defer {
                    if self?.activeOpenPanelToken == pickerToken {
                        self?.isPresentingOpenPanel = false
                        self?.activeOpenPanelWindow = nil
                        self?.activeOpenPanel = nil
                        self?.pendingOpenPanelCompletion = nil
                    }
                }
                guard let self = self,
                      self.activeOpenPanelToken == pickerToken,
                      let host = self.host,
                      host.isPanelOpen,
                      let webView = webView,
                      let currentWindow = webView.window,
                      currentWindow.isVisible,
                      currentWindow == window,
                      HanaPanelHost.isTrustedAlfredURL(webView.url) else {
                    completeOnce(nil)
                    return
                }

                completeOnce(selectedURLs)
            }
        }
    }
}

struct HanaWebViewRepresentable: NSViewRepresentable {
    let webView: WKWebView
    var nativeInputAllowed: () -> Bool = { true }

    func makeNSView(context: Context) -> LoginWebViewRepresentable.Container {
        let container = LoginWebViewRepresentable.Container()
        container.nativeInputAllowed = nativeInputAllowed
        container.attach(webView)
        return container
    }

    func updateNSView(_ nsView: LoginWebViewRepresentable.Container, context: Context) {
        nsView.nativeInputAllowed = nativeInputAllowed
        nsView.attach(webView)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: LoginWebViewRepresentable.Container, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 320, height: 240))
    }
}

struct HanaPanelDivider: View {
    @ObservedObject var host: HanaPanelHost
    let availableWidth: CGFloat
    @Environment(\.bkPalette) private var palette
    @State private var dragStartWidth: CGFloat? = nil
    @State private var isHovering: Bool = false
    @State private var hasPushedCursor: Bool = false

    var body: some View {
        PlannerNativeResizeDivider(
            onBegan: {
                dragStartWidth = host.preferredWidth
            },
            onChanged: { delta in
                let start = dragStartWidth ?? host.preferredWidth
                let newWidth = start - delta
                let clamped = min(max(HanaPanelHost.minWidth, newWidth), HanaPanelHost.maxWidth)
                host.setPreferredWidth(clamped)
            },
            onEnded: { delta in
                let start = dragStartWidth ?? host.preferredWidth
                let newWidth = start - delta
                let clamped = min(max(HanaPanelHost.minWidth, newWidth), HanaPanelHost.maxWidth)
                host.setPreferredWidth(clamped)
                dragStartWidth = nil
            }
        )
        .frame(width: 16)
        .frame(maxHeight: .infinity)
        .accessibilityElement()
        .accessibilityLabel("하나 대화창 너비 조절 핸들")
        .accessibilityValue("\(Int(host.preferredWidth))픽셀")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                host.setPreferredWidth(min(host.preferredWidth + 20, HanaPanelHost.maxWidth))
            case .decrement:
                host.setPreferredWidth(max(host.preferredWidth - 20, HanaPanelHost.minWidth))
            @unknown default:
                break
            }
        }
    }
}

struct HanaPanelView: View {
    @ObservedObject var host: HanaPanelHost
    let availableWidth: CGFloat
    var nativeInputAllowed: () -> Bool = { true }
    @Environment(\.bkPalette) private var palette

    private var displayedWidth: CGFloat {
        host.effectiveWidth(forAvailableWidth: availableWidth)
    }

    var body: some View {
        HStack(spacing: 0) {
            HanaPanelDivider(host: host, availableWidth: availableWidth)

            VStack(spacing: 0) {
                if let msg = host.statusMessage {
                    statusBanner(msg)
                }
                HanaWebViewRepresentable(webView: host.webView, nativeInputAllowed: nativeInputAllowed)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: displayedWidth)
            .background(palette.cardColor)
        }
    }

    private func statusBanner(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: host.hasAmbiguousError ? "exclamationmark.triangle" : "info.circle")
                .font(.caption2)
                .foregroundColor(host.hasAmbiguousError ? palette.warnInkColor : palette.textColor)
            Text(text)
                .font(.caption2)
                .foregroundColor(host.hasAmbiguousError ? palette.warnInkColor : palette.textColor)
                .lineLimit(2)
            Spacer()
            if host.hasAmbiguousError || host.pendingQueueCount > 0 {
                Button("다시 시도") {
                    host.retrySend()
                }
                .font(.caption2.bold())
                .buttonStyle(.plain)
                .foregroundColor(palette.accentColor)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(host.hasAmbiguousError ? palette.warnSoftColor : palette.accentSoftColor)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}
