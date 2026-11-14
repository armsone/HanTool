import Foundation
import OSLog
import Combine
import CryptoKit
import WebKit

// Common web host adapter for the assistant planner. One AssistantWebSession exists per chat host (WKWebView) and
// owns: the isolated-world script that watches the user's own composer (trigger capture), the bounded conversation
// capture, the native handoff / draft acknowledgement, and the AssistantPlannerAdapter send + own-receipt
// verification used by the common AssistantPlannerCoordinator outbox. It performs no network, process, credential
// or history access; every read is of the already-open page in this one WKWebView.
//
// Trust model: the script lives in a private WKContentWorld whose message handler exists only for the current
// configuration epoch. Native code accepts a message only when it comes from the main frame of this WKWebView, in
// that world, from the exact configured https origin, carrying this epoch's nonce and the current document id.
// A reconfigure (service/profile swap) bumps the epoch, removes the handler and retires the old script, so late
// callbacks from the previous configuration are dropped.

// MARK: - Public models

enum AssistantWebCapability: Equatable {
    case unknown(String)        // not decided yet (page loading, no conversation rows yet)
    case supported
    case unsupported(String)    // the page cannot be read safely; the reason is user-presentable

    var isSupported: Bool { self == .supported }

    var detail: String {
        switch self {
        case .unknown(let text), .unsupported(let text): return text
        case .supported: return ""
        }
    }
}

struct AssistantWebStatus: Equatable {
    enum Kind: String { case unavailable, ready, unsupported, pending, accepted, refused }
    var kind: Kind
    var message: String
    /// True when the user's composer text was deliberately left exactly as it was.
    var draftPreserved: Bool
}

enum AssistantWebLifecycleEvent: String {
    case ready, visible, idle, inputBlur, rows
}

enum AssistantWebHandoffSource: String {
    case enter, sendButton, manual
}

struct AssistantWebMessage: Equatable {
    var role: String            // "user" | "assistant"
    var text: String
}

/// Identity of the conversation the handoff came from. The caller turns it into an AssistantPlannerIdentity with
/// `session.binding.identity(projectID:runID:requestID:)` and matches in-memory roots with `originToken` +
/// `firstUserKey` (a hash of the first user row); after a restart only `conversationURL` / `stableID` are used.
struct AssistantWebSourceIdentity: Equatable {
    var hostID: String
    var serviceID: String
    var profileID: String
    var conversationURL: String
    var stableID: String?
    var originToken: String
    var firstUserKey: String?
}

struct AssistantWebHandoff: Equatable {
    var requestUUID: String
    /// The user's exact raw control command (empty for a manual capture without a draft). It is the latest
    /// instruction and is never part of `messages`.
    var rawCommand: String
    var source: AssistantWebHandoffSource
    var identity: AssistantWebSourceIdentity
    /// At most 8 messages, 1500 characters each, 6000 in total, oldest first.
    var messages: [AssistantWebMessage]
    /// The last real user request before the command (at most 10 000 characters).
    var previousUserGoal: String?
    var userRowCount: Int
}

enum AssistantWebHandoffDecision {
    case accepted(String)       // status text; the draft is cleared only if it is still exactly the command
    case refused(String)        // status text; the draft is always preserved
}

struct AssistantWebPageContextRequest: Equatable {
    var requestUUID: String
    var rawQuestion: String
    /// The question without its slash prefix (what the AI is asked).
    var question: String
    var source: AssistantWebHandoffSource
    var serviceID: String
    var originToken: String
}

/// Formatted page prompt plus an optional request-owned masked page image (memory only, never logged or stored).
struct AssistantWebPagePayload {
    var text: String
    var image: Data?
}

// MARK: - Service adapter (coordinator side)

/// The coordinator keeps one adapter per service ID; this one fans out to the per-host sessions of that service.
@MainActor
final class AssistantWebServiceAdapter: AssistantPlannerAdapter {
    private struct Route { weak var session: AssistantWebSession? }

    let serviceID: String
    private var routes: [String: Route] = [:]

    init(serviceID: String) { self.serviceID = serviceID }

    var isEmpty: Bool {
        routes = routes.filter { $0.value.session != nil }
        return routes.isEmpty
    }

    func add(_ session: AssistantWebSession) { routes[session.hostID] = Route(session: session) }
    func remove(hostID: String) { routes[hostID] = nil }

    /// True when a different host of this service already shows exactly this conversation.
    func otherHostMatches(_ identity: AssistantPlannerIdentity, excluding hostID: String) -> Bool {
        routes.contains { $0.key != hostID && $0.value.session?.binding?.matches(identity) == true }
    }

    func send(_ entry: AssistantPlannerOutboxEntry, via host: AssistantPlannerHostBinding) async -> AssistantPlannerSendResult {
        guard let session = routes[host.hostID]?.session else { return .notSent("연결된 대화창이 없어 보류했습니다.") }
        return await session.performSend(entry, via: host)
    }

    func verifyDelivery(of entry: AssistantPlannerOutboxEntry, via host: AssistantPlannerHostBinding) async -> AssistantPlannerDeliveryProof {
        guard let session = routes[host.hostID]?.session else { return .unknown }
        return await session.performVerify(entry, via: host)
    }
}

// MARK: - Script message plumbing

@MainActor
private final class AssistantWebScriptProxy: NSObject, WKScriptMessageHandler {
    weak var owner: AssistantWebSession?
    let epoch: Int

    init(owner: AssistantWebSession, epoch: Int) {
        self.owner = owner
        self.epoch = epoch
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        owner?.receive(message, epoch: epoch)
    }
}

/// Claims a one-shot completion between a page callback and its native deadline.
private final class AssistantWebOnce {
    private var claimed = false
    func claim() -> Bool {
        if claimed { return false }
        claimed = true
        return true
    }
}

// MARK: - Session

@MainActor
final class AssistantWebSession: NSObject, ObservableObject {
    static let handlerName = "afPlanner"
    static let sendTimeoutMS = 8000
    static let hostContextTimeout: TimeInterval = 3

    let hostID: String
    /// Stable for the life of this session: lets the caller match an in-memory root to the panel that produced it.
    let originToken = UUID().uuidString

    /// Called with a bounded capture when the user sends the exact control command (Enter / send button) or uses the
    /// manual action. The draft is acknowledged from the returned decision.
    var onHandoff: ((AssistantWebHandoff) async -> AssistantWebHandoffDecision)?
    /// Runtime only. Called with the accepted handoff after its draft acknowledgement was attempted and verified (the
    /// composer is verifiably empty), or after an accepted manual capture, which never touches the draft. Never called
    /// for a refused / stale / uncertain handoff, a changed or uncleared draft, or after a reconfigure. It carries no
    /// execution authority; the owner decides whether presenting the planner is still appropriate.
    var onAcceptedPresentation: ((AssistantWebHandoff) -> Void)?
    /// Called only for a slash question (`/질문`, `//질문`) or an unprefixed question while this conversation's browser
    /// mode is on. A success is the formatted prompt written to the composer and submitted; a failure is never sent.
    var onPageContext: ((AssistantWebPageContextRequest) async -> Result<AssistantWebPagePayload, AIPageCaptureError>)?
    /// Providers with a verified image-attachment route; only these may receive the page picture next to the text.
    var supportsPageImage: Bool { ["claude", "chatgpt", "gemini", "perplexity", "grok", "copilot", "meta"].contains(kind) }
    /// Hana only: its typed-question script lives in the panel host, which mirrors the mode from here.
    var onPageModeChange: ((Bool) -> Void)?
    /// Browser mode of THIS conversation. Runtime only: never persisted, reset with a new conversation or host.
    @Published private(set) var pageModeOn = false
    private var pageModeKey: String?
    private var pageModeMayAdopt = false
    private var pageModeResets = 0
    /// Native status for the common UI (also published in `status`).
    var onStatus: ((AssistantWebStatus) -> Void)?
    /// Idle / ready / visible / input blur / new rows. Only a reason to try the durable outbox again; it never
    /// creates work.
    var onLifecycle: ((AssistantWebLifecycleEvent) -> Void)?

    @Published private(set) var status = AssistantWebStatus(kind: .unavailable, message: "대화창이 아직 연결되지 않았습니다.", draftPreserved: false)
    @Published private(set) var capability: AssistantWebCapability = .unknown("대화창이 아직 연결되지 않았습니다.")

    private(set) var binding: AssistantPlannerHostBinding?
    private(set) var serviceID = ""
    private(set) var profileID = ""

    private let coordinator: AssistantPlannerCoordinator
    private let trigger: AssistantPlannerTrigger

    private weak var webView: WKWebView?
    private var homeOrigin: String?
    private var kind = "generic"
    private var epoch = 0
    private var world: WKContentWorld?
    private var nonce = ""
    private var scriptSource = ""
    private var watchEnabled = true
    private let installedControllers = NSHashTable<WKUserContentController>.weakObjects()
    private var docID: String?
    private var docGeneration = 0
    private var observedStable: (url: String, id: String)?
    private var seenRequests: [String] = []
    private var lifecyclePending = false
    private var sendInFlight = false
    /// Captures / handoffs (manual and typed) currently running; they own the pending status until they publish.
    private var captureCount = 0
    private var homePath = ""
    /// True once the isolated script saw a trusted key / pointer / paste / drop on this configuration's pages.
    private var userTouched = false
    private var restoreInFlight = false
    /// Targets already navigated to by the restore (one attempt per target for this configuration, so a redirect back
    /// to the service home can never loop).
    private var restoredTargets: Set<String> = []
    /// Hana only: the page's own host context proof (account|project|thread). `raw` (with the volatile generation) is
    /// kept in memory for the atomic dispatch gate and is never logged or stored; `hash` is the durable stable ID.
    private var hanaProof: (hash: String, raw: String, epoch: Int, doc: String, gen: Int, href: String)?

    init(hostID: String, coordinator: AssistantPlannerCoordinator, trigger: AssistantPlannerTrigger? = nil) {
        self.hostID = hostID
        self.coordinator = coordinator
        self.trigger = trigger ?? coordinator.trigger
        super.init()
    }

    // MARK: Configuration

    /// Binds this session to the current service/profile and web view. Safe to call again whenever the service store,
    /// profile or web view is swapped: everything from the previous configuration is retired first. `homeURL` is the
    /// configured service address; only its exact https origin is trusted. Returns false (and says why in `status`)
    /// when the host cannot be used.
    @discardableResult
    func configure(serviceID: String, profileID: String, homeURL: String, webView: WKWebView?) -> Bool {
        retire()
        guard !serviceID.isEmpty, !profileID.isEmpty, let origin = Self.normalizedOrigin(homeURL), let webView else {
            publish(.unavailable, "서비스 주소 또는 대화창을 확인할 수 없어 플래너 연결을 사용하지 않습니다.")
            capability = .unsupported("서비스 주소 또는 대화창을 확인할 수 없습니다.")
            return false
        }
        self.serviceID = serviceID
        self.profileID = profileID
        self.homeOrigin = origin
        self.homePath = Self.trimmedPath(URLComponents(string: homeURL)?.path ?? "")
        self.webView = webView
        self.kind = Self.kind(serviceID: serviceID, origin: origin)
        self.world = WKContentWorld.world(name: "HTT.planner.\(hostID).\(epoch)")
        self.nonce = UUID().uuidString
        self.scriptSource = AssistantWebScript.source(kind: kind, origin: origin,
                                                      origins: Self.trustedOrigins(serviceID: serviceID, home: origin), pattern: trigger.pattern,
                                                      handler: Self.handlerName, nonce: nonce, watch: watchEnabled)
        guard registerRoute() else {
            publish(.unavailable, "이 서비스에는 이미 다른 전송 방식이 연결되어 있어 공통 연결을 사용하지 않습니다.")
            capability = .unsupported("이 서비스에는 다른 전송 방식이 연결되어 있습니다.")
            self.world = nil
            self.homeOrigin = nil
            self.scriptSource = ""
            self.serviceID = ""
            self.profileID = ""
            return false
        }
        let currentEpoch = epoch
        let binding = AssistantPlannerHostBinding(
            hostID: hostID, serviceID: serviceID, profileID: profileID, webView: webView,
            conversationURL: { [weak self] in self?.liveConversationURL(epoch: currentEpoch) },
            stableID: { [weak self] in self?.liveStableID(epoch: currentEpoch) })
        self.binding = binding
        coordinator.attach(host: binding)
        install(into: webView.configuration.userContentController)
        if webView.url != nil, let world {
            webView.evaluateJavaScript(scriptSource, in: nil, in: world, completionHandler: nil)
        }
        capability = .unknown("페이지를 확인하는 중입니다.")
        publish(.ready, "플래너 연결 준비됨")
        return true
    }

    /// Adds the isolated script and its handler to a user-content controller. `configure` calls this for the web
    /// view's own controller; a caller that builds a fresh WKWebViewConfiguration for the same session (a rebind)
    /// must call it on the new controller before the first navigation. Idempotent per controller.
    @discardableResult
    func install(into controller: WKUserContentController) -> Bool {
        guard let world, homeOrigin != nil, !scriptSource.isEmpty else { return false }
        if installedControllers.contains(controller) { return true }
        controller.add(AssistantWebScriptProxy(owner: self, epoch: epoch), contentWorld: world, name: Self.handlerName)
        controller.addUserScript(WKUserScript(source: scriptSource, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true, in: world))
        installedControllers.add(controller)
        return true
    }

    /// Releases the host: retires the script, detaches the binding and removes this session's service route.
    func detach() {
        retire()
        serviceID = ""
        profileID = ""
        publish(.unavailable, "대화창이 연결되지 않았습니다.")
        capability = .unknown("대화창이 연결되지 않았습니다.")
    }

    /// Toggles the row / idle watcher that wakes the outbox. The caller may turn it off while nothing is pending.
    func setLifecycleWatch(_ enabled: Bool) {
        watchEnabled = enabled
        guard let ctx = currentContext() else { return }
        Task { _ = await call("setWatch", [enabled], ctx) }
    }

    /// Call when the owner knows the page was replaced without a fresh script hello (belt and braces).
    func invalidate() {
        docID = nil
        docGeneration += 1
        observedStable = nil
        hanaProof = nil
    }

    // MARK: Status / capability

    /// Re-probes the page: composer and message roles must be uniquely identified. Updates `capability`.
    func refreshCapability() async {
        guard let ctx = currentContext() else {
            capability = .unknown("페이지를 불러오는 중이거나 지원하지 않는 주소입니다.")
            return
        }
        if kind == "hana" {
            await refreshHanaProof()
            guard isCurrent(ctx) else { return }
        }
        guard case .value(let result) = await call("probe", [ctx.doc], ctx), isCurrent(ctx) else { return }
        noteObservation(result)
        if result["ok"] as? Bool == true {
            capability = .supported
        } else {
            let reason = result["reason"] as? String
            let text = Self.describe(reason)
            capability = Self.isUnsupportedReason(reason) ? .unsupported(text) : .unknown(text)
        }
    }

    /// Manual capture for every service: hands the current conversation to the planner without any typed command.
    /// The composer text is never modified.
    @discardableResult
    func captureManually() async -> AssistantWebHandoffDecision {
        guard let ctx = currentContext() else {
            let text = "대화창이 준비되지 않아 플래너에 넘기지 못했습니다."
            publish(.refused, text, draftPreserved: true)
            return .refused(text)
        }
        let captureEpoch = epoch
        captureCount += 1
        defer { if captureEpoch == epoch { captureCount = max(0, captureCount - 1) } }
        publish(.pending, "현재 대화를 읽는 중…")
        guard case .value(let result) = await call("capture", [ctx.doc], ctx), isCurrent(ctx) else {
            let text = "대화 내용을 확인하지 못했습니다. 입력 중인 내용은 그대로입니다."
            publish(.refused, text, draftPreserved: true)
            return .refused(text)
        }
        guard result["ok"] as? Bool == true else {
            // Fixed stage codes/counts only (see diagCode); anything else is dropped.
            let diag = (result["diag"] as? String).flatMap { $0.range(of: "^[a-z0-9:;=._-]{1,400}$", options: .regularExpression) != nil ? " [\($0)]" : nil } ?? ""
            let text = Self.describe(result["reason"] as? String) + diag + " 입력 중인 내용은 그대로입니다."
            publish(.refused, text, draftPreserved: true)
            return .refused(text)
        }
        noteObservation(result)
        let raw = String((result["raw"] as? String ?? "").prefix(AssistantPlannerTrigger.maxInputLength))
        return await dispatchHandoff(raw: raw, source: .manual, requestUUID: UUID().uuidString, capture: result, ctx: ctx, acknowledge: false)
    }

    // MARK: Message handling

    /// Page-question stage markers in the app's local log: fixed codes and the closed provider kind only (never question
    /// text, page content, addresses, tokens or image data), bounded per document, to locate a runtime receive → submit
    /// stop. Public at the default level so a normal `log show` / `log stream` reads them; nothing else is made public.
    private static let diagLog = Logger(subsystem: "com.local.screentranslator", category: "AssistantDiag")
    private var pcLogBudget = 48
    private func pcLog(_ code: String) {
        guard pcLogBudget > 0 else { return }
        pcLogBudget -= 1
        Self.diagLog.notice("[HttpsDown] afpc \(self.kind, privacy: .public) \(code, privacy: .public)")
    }

    /// Which receive guard refused a message, as fixed bits in guard order: epoch, world, main frame, web view, trusted
    /// origin, nonce, document token. Logging only; the guard itself is unchanged and nothing is sent back to the page.
    private func receiveGate(_ message: WKScriptMessage, epoch messageEpoch: Int) -> String {
        let body = message.body as? [String: Any]
        let bits = [messageEpoch == epoch, world != nil && message.world == world, message.frameInfo.isMainFrame,
                    webView != nil && message.webView === webView,
                    isTrustedOrigin(Self.origin(of: message.frameInfo.securityOrigin)),
                    body?["n"] as? String == nonce,(body?["doc"] as? String).map(Self.isToken) == true]
        return bits.map { $0 ? "1" : "0" }.joined()
    }

    fileprivate func receive(_ message: WKScriptMessage, epoch messageEpoch: Int) {
        guard messageEpoch == epoch, let world, message.world == world, message.frameInfo.isMainFrame,
              let webView, message.webView === webView,
              isTrustedOrigin(Self.origin(of: message.frameInfo.securityOrigin)),
              let body = message.body as? [String: Any], body["n"] as? String == nonce,
              let doc = body["doc"] as? String, Self.isToken(doc), let type = body["t"] as? String else {
            if (message.body as? [String: Any])?["t"] as? String == "pageContext" { pcLog("rx-drop g=" + receiveGate(message, epoch: messageEpoch)) }
            return
        }
        if type == "hello" {
            pcLogBudget = 48
            docID = doc
            docGeneration += 1
            observedStable = nil
            hanaProof = nil
            noteObservation(body)
            capability = .unknown("페이지를 확인하는 중입니다.")
            reconcilePageMode()
            pushPageMode()
            return
        }
        guard doc == docID else {
            // Our own (nonce-checked) script on a document this session no longer tracks: nothing was sent and the
            // composer is untouched, so a page question is refused with a fixed code instead of staying silent.
            if type == "pageContext" {
                pcLog("rx-doc")
                publish(.refused, "대화 화면이 바뀌어 보내지 않았습니다. [pc-doc] 입력한 내용은 그대로 두었습니다.", draftPreserved: true)
            }
            return
        }
        noteObservation(body)
        reconcilePageMode()
        let currentEpoch = epoch
        let generation = docGeneration
        switch type {
        case "life":
            if let event = (body["k"] as? String).flatMap(AssistantWebLifecycleEvent.init(rawValue:)) {
                if event == .ready || event == .visible { scheduleRestore(epoch: currentEpoch, generation: generation) }
                wake(event)
            }
        case "touch":
            userTouched = true
        case "refused":
            if let r = body["reason"] as? String, r.hasPrefix("pagecontext-"), r.range(of: "^[a-z-]{1,40}$", options: .regularExpression) != nil {
                pcLog("rx-refused " + r)
            }
            let reason = Self.describe(body["reason"] as? String)
            publish(.refused, "플래너에 넘기지 못했습니다. \(reason) 입력한 내용은 그대로 두었습니다.", draftPreserved: true)
        case "trigger":
            Task { [weak self] in
                await self?.handleTrigger(body, epoch: currentEpoch, generation: generation)
            }
        case "pageContext":
            pcLog("rx-ok")
            Task { [weak self] in
                await self?.handlePageContext(body, epoch: currentEpoch, generation: generation)
            }
        default:
            break
        }
    }

    private func handlePageContext(_ body: [String: Any], epoch triggerEpoch: Int, generation: Int) async {
        guard triggerEpoch == epoch, let request = body["req"] as? String, Self.isToken(request), !seenRequests.contains(request) else {
            pcLog("h-drop e\(triggerEpoch == epoch ? 1 : 0)")
            return
        }
        guard generation == docGeneration, let ctx = currentContext() else {
            pcLog("h-stale")
            seenRequests.append(request)
            // Only releases this request's pending lock when the current document still owns it (the page checks its
            // document and request); the composer is never written.
            if let ctx = currentContext() { _ = await call("cancelPageContext", [ctx.doc, request], ctx) }
            publish(.refused, "대화 화면이 바뀌어 보내지 않았습니다. [pc-stale] 입력한 내용은 그대로 두었습니다.", draftPreserved: true)
            return
        }
        guard let raw = body["raw"] as? String, !raw.isEmpty else {
            pcLog("h-raw")
            seenRequests.append(request)
            _ = await call("cancelPageContext", [ctx.doc, request], ctx)
            publish(.refused, "질문 내용을 확인하지 못해 보내지 않았습니다. 입력한 내용은 그대로 두었습니다.", draftPreserved: true)
            return
        }
        seenRequests.append(request)
        if seenRequests.count > 64 { seenRequests.removeFirst(seenRequests.count - 64) }
        let source: AssistantWebHandoffSource = (body["via"] as? String) == "click" ? .sendButton : .enter
        let command = AIPageSlashCommand(parsing: raw)
        /// Nothing is sent: the pending request is dropped and the composer keeps the exact raw text.
        func refuse(_ text: String, _ code: String) async {
            pcLog("h-" + code)
            _ = await call("cancelPageContext", [ctx.doc, request], ctx)
            publish(.refused, "\(text) 입력한 내용은 그대로 두었습니다.", draftPreserved: true)
        }
        pcLog("h-parse")
        reconcilePageMode()
        let resetsAtStart = pageModeResets
        switch command.kind {
        case .toggle:
            pcLog("h-toggle")
            applyPageMode(!pageModeOn)
            // Consume the "//" only while the composer still holds exactly it; newer typing is never touched.
            var cleared = false
            if case .value(let dict) = await call("consumePageContext", [ctx.doc, request], ctx) { cleared = dict["ok"] as? Bool == true }
            let state = pageModeOn ? "브라우저 모드를 켰습니다. 질문마다 현재 페이지를 함께 읽습니다. 끄려면 //" : "브라우저 모드를 껐습니다."
            publish(.accepted, state + (cleared ? "" : " 입력창의 //는 직접 지워 주세요."), draftPreserved: !cleared)
            return
        case .empty:
            await refuse("/ 뒤에 질문을 입력해 주세요. (/질문: 이번만 현재 페이지, //질문: 브라우저 모드 켜기, //: 켜기/끄기)", "empty")
            return
        case .plain where !pageModeOn:
            pushPageMode()
            await refuse("브라우저 모드가 꺼져 있어 보내지 않았습니다. 다시 보내 주세요.", "mode-off")
            return
        default:
            break
        }
        if raw.utf16.count > 10_000 {
            await refuse("질문이 너무 길어 페이지와 함께 보내지 못했습니다(최대 10,000자).", "long")
            return
        }
        if body["att"] as? Bool != false {
            let ak = body["ak"] as? String ?? ""
            let code = ak.range(of: "^[a-z-]{1,20}$", options: .regularExpression) != nil ? " [att-\(ak)]" : ""
            await refuse("첨부 파일이 있어 페이지 본문을 함께 보낼 수 없습니다. 첨부를 지우거나 슬래시 없이 보내 주세요.\(code)", "att")
            return
        }
        if body["gen"] as? Bool != false {
            await refuse("AI가 응답하는 중이라 보내지 않았습니다.", "gen")
            return
        }
        let req = AssistantWebPageContextRequest(requestUUID: request, rawQuestion: raw, question: command.question,
                                                 source: source, serviceID: serviceID, originToken: originToken)
        guard let onPageContext else {
            await refuse("페이지를 읽는 기능이 연결되지 않아 보내지 않았습니다.", "no-callback")
            return
        }
        publish(.pending, "현재 페이지를 읽는 중…")
        pcLog("cb-call")
        let formattedPrompt: String
        var pageImage: Data?
        switch await onPageContext(req) {
        case .success(let payload):
            pcLog(payload.image == nil ? "cb-ok text" : "cb-ok image")
            formattedPrompt = payload.text
            pageImage = payload.image
        case .failure(let error):
            await refuse("페이지 본문을 읽지 못해 질문을 보내지 않았습니다. \(error.localizedDescription)", "cb-fail")
            return
        }
        reconcilePageMode()
        guard triggerEpoch == epoch, generation == docGeneration, isCurrent(ctx), resetsAtStart == pageModeResets, command.kind != .plain || pageModeOn else {
            pcLog("cb-stale")
            _ = await call("cancelPageContext", [ctx.doc, request], ctx)
            publish(.refused, "읽는 동안 대화나 화면이 바뀌어 보내지 않았습니다. 입력한 내용은 그대로 두었습니다.", draftPreserved: true)
            return
        }
        if pageImage != nil, !supportsPageImage || pageImage!.count > 8_000_000 {
            await refuse("이 서비스로 보낼 수 없는 페이지 이미지라 보내지 않았습니다.", "image")
            return
        }
        let imageArgument: Any = pageImage.map { $0.base64EncodedString() } ?? NSNull()
        pcLog("sub-call")
        let result = await call("submitPageContextPrompt", [ctx.doc, request, formattedPrompt, imageArgument], ctx)
        pageImage = nil
        if case .value(let dict) = result, dict["ok"] as? Bool == true {
            pcLog("sub-ok")
            if command.kind == .enable { applyPageMode(true) }
            // A first reply may turn the new-chat address into a conversation ID: that is still this conversation.
            if pageModeOn && pageModeKey == nil { pageModeMayAdopt = true }
            // Shown in the entry bar (a .ready status is not), so a completed send is distinguishable from silence.
            publish(.accepted, imageArgument is NSNull ? "질문과 페이지 본문을 전송했습니다." : "질문과 페이지 본문·화면 이미지를 전송했습니다.")
        } else if kind == "meta", Self.postUnconfirmed(result) {
            // Meta only: the send was clicked (or the page moved during the check) without proof of our own new message.
            // Unconfirmed, not failed: the site may still post it late, so nothing is resent.
            let restored: Bool
            if case .value(let dict) = result { restored = dict["restored"] as? Bool == true } else { restored = false }
            // Without a result (page moved) both bit sets are "-".
            pcLog((restored ? "sub-unconfirmed r1" : "sub-unconfirmed r0") + " g=" + Self.gateBits(result, "g") + " q=" + Self.gateBits(result, "q"))
            publish(.refused, "전송 버튼은 눌렀지만 대화에 질문이 올라간 것을 확인하지 못했습니다. [post-unconfirmed] 늦게 전송될 수 있으니 다시 보내기 전에 대화를 확인해 주세요."
                    + (restored ? " 입력한 원문을 입력창에 되돌렸습니다." : " 원문 복원을 확인하지 못했습니다."), draftPreserved: restored)
        } else {
            // Stage code only (fixed script identifiers); never question text, image bytes or page addresses.
            var code = "js-call-failed"
            // nil = the script never wrote into the composer on this path (the raw text was left as it was).
            var restored: Bool?
            if case .value(let dict) = result {
                let r = dict["reason"] as? String ?? ""
                code = r.range(of: "^[a-z-]{1,40}$", options: .regularExpression) != nil ? r : "unknown"
                restored = dict["restored"] as? Bool
            }
            // Meta's pre-click check and a failed composer write report their fixed bits and whether the raw text came back.
            pcLog("sub-fail " + code + (code == "preclick-stale" ? " g=" + Self.gateBits(result, "g") : "")
                  + (code == "composer-write-failed" ? " w=" + Self.gateBits(result, "w") : "")
                  + (restored == nil ? "" : (restored == true ? " r1" : " r0")))
            publish(.refused, "AI 대화창에 전송하지 못했습니다. \(Self.describe(code)) [\(code)]"
                    + (restored == false ? " 원문 복원을 확인하지 못했습니다." : (restored == true ? " 입력한 원문을 입력창에 되돌렸습니다." : " 입력한 내용은 그대로 두었습니다.")),
                    draftPreserved: restored != false)
        }
    }

    // MARK: Browser mode (this conversation only)

    /// Identity of the conversation this host shows now: Hana's proven host context, otherwise the address path of a
    /// conversation URL. nil = a new chat / landing page (or, for Hana, a context not proven yet).
    private var pageModeScope: String? {
        if kind == "hana" { return liveHanaHash(epoch: epoch) }
        guard let url = liveConversationURL(epoch: epoch), let c = URLComponents(string: url) else { return nil }
        return (c.host ?? "") + c.path
    }

    private func applyPageMode(_ on: Bool) {
        pageModeOn = on
        pageModeKey = on ? pageModeScope : nil
        pageModeMayAdopt = false
        pushPageMode()
    }

    /// Turns the mode off when this host now shows another conversation. A new chat that becomes a conversation
    /// (first reply) is adopted only after a mode question was really sent from it; anything else is conservative.
    private func reconcilePageMode() {
        guard pageModeOn, let live = webView?.url?.absoluteString, isTrustedOrigin(Self.normalizedOrigin(live)) else { return }
        let scope = pageModeScope
        if kind == "hana" && scope == nil { return }
        switch (pageModeKey, scope) {
        case (nil, nil):
            return
        case (nil, .some(let now)) where pageModeMayAdopt || kind == "hana":
            pageModeKey = now
            pageModeMayAdopt = false
            return
        case (.some(let old), .some(let now)) where old == now:
            return
        default:
            break
        }
        applyPageMode(false)
        if status.kind != .pending { publish(.accepted, "다른 대화로 바뀌어 브라우저 모드를 껐습니다.") }
    }

    /// Mirrors the mode into the page script (third-party) or the Hana host (its own script).
    private func pushPageMode() {
        onPageModeChange?(pageModeOn)
        guard kind != "hana", let ctx = currentContext() else { return }
        let on = pageModeOn
        Task { _ = await call("setPageMode", [on], ctx) }
    }

    /// Hana only: refresh the host-context proof, then drop the mode if the thread changed. Call before a mode question.
    func prepareScope() async {
        if kind == "hana" { await refreshHanaProof() }
        reconcilePageMode()
    }

    /// Trusted New Chat control: the mode ends now, and any request already reading the page can no longer re-enable it.
    func resetPageModeForNewChat() {
        pageModeResets += 1
        guard pageModeOn else { return }
        applyPageMode(false)
        publish(.accepted, "새 대화로 바뀌어 브라우저 모드를 껐습니다.")
    }

    /// Hana's typed `//`: same state change as the third-party handler; returns the new state.
    @discardableResult
    func togglePageMode() -> Bool {
        applyPageMode(!pageModeOn)
        publish(.accepted, pageModeOn ? "브라우저 모드를 켰습니다. 질문마다 현재 페이지를 함께 읽습니다. 끄려면 //" : "브라우저 모드를 껐습니다.")
        return pageModeOn
    }

    /// Hana's `//질문` after a successful send.
    func enablePageMode() {
        applyPageMode(true)
    }

    private func handleTrigger(_ body: [String: Any], epoch triggerEpoch: Int, generation: Int) async {
        guard triggerEpoch == epoch, generation == docGeneration, let ctx = currentContext(),
              let request = body["req"] as? String, Self.isToken(request), !seenRequests.contains(request) else { return }
        seenRequests.append(request)
        if seenRequests.count > 64 { seenRequests.removeFirst(seenRequests.count - 64) }
        let captureEpoch = epoch
        captureCount += 1
        defer { if captureEpoch == epoch { captureCount = max(0, captureCount - 1) } }
        let source: AssistantWebHandoffSource = (body["via"] as? String) == "click" ? .sendButton : .enter
        let raw = body["raw"] as? String ?? ""
        guard trigger.matches(raw), let capture = body["cap"] as? [String: Any] else {
            _ = await call("ack", [ctx.doc, request, false], ctx)
            publish(.refused, "플래너 명령으로 확인되지 않아 넘기지 않았습니다. 입력한 내용은 그대로 두었습니다.", draftPreserved: true)
            return
        }
        _ = await dispatchHandoff(raw: raw, source: source, requestUUID: request, capture: capture, ctx: ctx, acknowledge: true)
    }

    private func dispatchHandoff(raw: String,
                                 source: AssistantWebHandoffSource,
                                 requestUUID: String,
                                 capture: [String: Any],
                                 ctx: Ctx,
                                 acknowledge: Bool) async -> AssistantWebHandoffDecision {
        // Hana: the identity is the page's own host context, read fresh right before the handoff is built. A thread
        // that differs from the last proven one (the capture happened before this read) is never handed over.
        var hanaRefusal: String?
        if kind == "hana" {
            let prior = liveHanaHash(epoch: ctx.epoch)
            let fresh = await refreshHanaProof()
            if ctx.epoch != epoch || ctx.gen != docGeneration || !isCurrent(ctx) || fresh == nil || (prior != nil && prior != fresh?.hash) {
                hanaRefusal = "대화가 바뀌었거나 하나 대화 상태를 확인하지 못해 플래너에 넘기지 못했습니다."
            }
        }
        let decision: AssistantWebHandoffDecision
        var capturedHandoff: AssistantWebHandoff?
        if let hanaRefusal {
            decision = .refused(hanaRefusal)
        } else {
            switch makeHandoff(raw: raw, source: source, requestUUID: requestUUID, capture: capture) {
            case .failure(let refusal):
                decision = .refused(refusal.text)
            case .success(let handoff):
                capturedHandoff = handoff
                publish(.pending, "플래너에 넘기는 중…")
                if let onHandoff {
                    decision = await onHandoff(handoff)
                } else {
                    decision = .refused("플래너가 아직 연결되지 않아 넘기지 못했습니다.")
                }
            }
        }
        guard ctx.epoch == epoch else { return decision }
        var accepted = false
        switch decision {
        case .accepted(let text):
            accepted = true
            publish(.accepted, text)
        case .refused(let text):
            publish(.refused, text + " 입력한 내용은 그대로 두었습니다.", draftPreserved: true)
        }
        // A manual capture never touches the draft, so an accepted one may be presented right away; a typed command is
        // presentable only once its draft acknowledgement verified an empty composer.
        var presentable = accepted && !acknowledge
        // Exact draft acknowledgement: the script clears the composer only if it still holds exactly the command.
        if acknowledge, ctx.gen == docGeneration, let first = currentContext(), first.doc == ctx.doc {
            // An accepted typed command may only clear the draft while this exact conversation is still proven: the
            // live page and a fresh handoff identity check, both re-validated after the await. A refused ack(false)
            // never clears anything, so it needs no proof.
            var target: Ctx? = first
            if accepted {
                target = nil
                if isCurrent(ctx), let capturedHandoff, await isHandoffCurrent(capturedHandoff),
                   ctx.epoch == epoch, isCurrent(ctx), let fresh = currentContext(), fresh.doc == ctx.doc {
                    target = fresh
                }
            }
            if let target {
                let outcome = await call("ack", [ctx.doc, requestUUID, accepted], target)
                if accepted, ctx.epoch == epoch {
                    // The job stays accepted either way; only the draft status follows what the page actually verified.
                    if case .value(let result) = outcome {
                        if result["changed"] as? Bool == true {
                            publish(.accepted, "플래너에 넘겼습니다. 그 사이 새로 작성한 입력은 그대로 두었습니다.", draftPreserved: true)
                        } else if result["cleared"] as? Bool != true {
                            publish(.accepted, "플래너에 넘겼습니다. 입력창을 비우지 못해 입력한 내용이 그대로 남아 있습니다.", draftPreserved: true)
                        } else {
                            presentable = true
                        }
                    } else {
                        publish(.accepted, "플래너에 넘겼습니다. 입력창이 비워졌는지 확인하지 못했습니다.", draftPreserved: true)
                    }
                }
            } else if ctx.epoch == epoch {
                // Unproven: the page only drops its pending reference (non-destructive); the input stays untouched, the
                // planner is not presented and nothing is retried.
                if ctx.gen == docGeneration, let release = currentContext(), release.doc == ctx.doc {
                    _ = await call("ack", [ctx.doc, requestUUID, false], release)
                }
                if ctx.epoch == epoch {
                    publish(.accepted, "플래너에 넘겼습니다. 같은 대화인지 확인하지 못해 입력한 내용은 그대로 두었습니다.", draftPreserved: true)
                }
            }
        }
        if presentable, ctx.epoch == epoch, let capturedHandoff {
            onAcceptedPresentation?(capturedHandoff)
        }
        return decision
    }

    /// True while this session still shows exactly the conversation the handoff was captured from. A Hana handoff
    /// re-reads the page's host context first; every other service uses the existing live identity.
    func isHandoffCurrent(_ handoff: AssistantWebHandoff) async -> Bool {
        let identity = handoff.identity
        guard binding != nil, identity.hostID == hostID, identity.originToken == originToken,
              identity.serviceID == serviceID, identity.profileID == profileID else { return false }
        let currentEpoch = epoch
        if kind == "hana" {
            guard let fresh = await refreshHanaProof(), fresh.hash == identity.stableID else { return false }
        }
        guard currentEpoch == epoch, let url = liveConversationURL(epoch: currentEpoch), url == identity.conversationURL,
              liveStableID(epoch: currentEpoch) == identity.stableID else { return false }
        return true
    }

    private struct Refusal: Error { let text: String }

    private func makeHandoff(raw: String,
                             source: AssistantWebHandoffSource,
                             requestUUID: String,
                             capture: [String: Any]) -> Result<AssistantWebHandoff, Refusal> {
        guard let url = liveConversationURL(epoch: epoch) else {
            return .failure(Refusal(text: "이 대화는 아직 고유한 주소가 없어 플래너에 넘기지 못했습니다."))
        }
        if let reported = capture["u"] as? String,
           AssistantPlannerURL.safe(reported, hasStableID: liveStableID(epoch: epoch) != nil) != url {
            return .failure(Refusal(text: "대화가 바뀌어 플래너에 넘기지 못했습니다."))
        }
        guard let parsed = parseCapture(capture) else {
            return .failure(Refusal(text: "이 페이지의 대화 구조를 안전하게 읽지 못해 플래너에 넘기지 못했습니다."))
        }
        let identity = AssistantWebSourceIdentity(
            hostID: hostID, serviceID: serviceID, profileID: profileID, conversationURL: url,
            stableID: liveStableID(epoch: epoch), originToken: originToken, firstUserKey: parsed.firstUserKey)
        return .success(AssistantWebHandoff(
            requestUUID: requestUUID, rawCommand: String(raw.prefix(AssistantPlannerTrigger.maxInputLength)),
            source: source, identity: identity, messages: parsed.messages,
            previousUserGoal: parsed.goal, userRowCount: parsed.userRows))
    }

    private func parseCapture(_ raw: [String: Any]) -> (messages: [AssistantWebMessage], goal: String?, firstUserKey: String?, userRows: Int)? {
        guard raw["ok"] as? Bool != false, let list = raw["msgs"] as? [[String: Any]] else { return nil }
        var messages: [AssistantWebMessage] = []
        for item in list.suffix(8) {
            guard let role = item["r"] as? String, role == "user" || role == "assistant",
                  let text = item["t"] as? String else { return nil }
            let clipped = String(text.prefix(1500))
            guard !clipped.isEmpty, !trigger.matches(clipped) else { continue }
            messages.append(AssistantWebMessage(role: role, text: clipped))
        }
        while messages.reduce(0, { $0 + $1.text.count }) > 6000, !messages.isEmpty { messages.removeFirst() }
        let goal = (raw["goal"] as? String).map { String($0.prefix(10_000)) }.flatMap { $0.isEmpty ? nil : $0 }
        var key = raw["fk"] as? String
        if let value = key, value.count != 16 || !value.allSatisfy({ $0.isHexDigit }) { key = nil }
        let users = (raw["nu"] as? Int) ?? 0
        guard users > 0 else { return nil }
        return (messages, goal, key, users)
    }

    private func wake(_ event: AssistantWebLifecycleEvent) {
        guard !lifecyclePending, onLifecycle != nil else { return }
        lifecyclePending = true
        let currentEpoch = epoch
        let generation = docGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            // One read-only capability probe per coalesced real ready/rows/idle event; `lifecyclePending` stays set
            // across the await so further wakes coalesce into this one instead of re-entering the refresh.
            var refreshed = false
            switch event {
            case .ready, .rows, .idle:
                if currentEpoch == self.epoch, generation == self.docGeneration {
                    await self.refreshCapability()
                    refreshed = true
                }
            default:
                break
            }
            // A task that outlives a reconfigure must not clear the new configuration's pending flag.
            guard currentEpoch == self.epoch else { return }
            self.lifecyclePending = false
            if refreshed, generation != self.docGeneration { return }
            self.onLifecycle?(event)
        }
    }

    // MARK: Original conversation restore

    private enum RestorePlan {
        case none
        case blocked(String)
        case target(AssistantPlannerIdentity, URL)
    }

    /// Chosen only from the coordinator's own open outbox entries of active associations for this exact
    /// service/profile. More than one distinct target, an unusable address or a root-style address is never guessed.
    private func planRestore() -> RestorePlan {
        guard let homeOrigin, !serviceID.isEmpty else { return .none }
        var targets: [AssistantPlannerIdentity] = []
        for entry in coordinator.outbox where (entry.status == .prepared || entry.status == .uncertain)
            && entry.identity.serviceID == serviceID && entry.identity.profileID == profileID
            && coordinator.associations.contains(where: { $0.id == entry.associationID && $0.status == .active }) {
            if !targets.contains(where: { $0.conversationURL == entry.identity.conversationURL && $0.stableID == entry.identity.stableID }) {
                targets.append(entry.identity)
            }
        }
        guard !targets.isEmpty else { return .none }
        guard targets.count == 1, let identity = targets.first?.validated(),
              isTrustedOrigin(Self.normalizedOrigin(identity.conversationURL)),
              AssistantPlannerURL.safe(identity.conversationURL, hasStableID: identity.stableID != nil) == identity.conversationURL,
              let components = URLComponents(string: identity.conversationURL), components.scheme?.lowercased() == "https",
              AssistantPlannerURL.namesConversation(components.path), let url = components.url else {
            return .blocked("완료 알림을 보낼 원래 대화를 주소만으로 다시 열 수 없어 자동으로 이동하지 않았습니다. 원래 대화를 직접 열어 주세요.")
        }
        if restoredTargets.contains(Self.restoreKey(identity)) {
            return .blocked("원래 대화로 한 번 이동했지만 같은 대화로 확인되지 않아 보류합니다. 원래 대화를 직접 열어 주세요.")
        }
        if let hub = coordinator.adapter(for: serviceID) as? AssistantWebServiceAdapter,
           hub.otherHostMatches(identity, excluding: hostID) {
            return .none
        }
        return .target(identity, url)
    }

    private static func restoreKey(_ identity: AssistantPlannerIdentity) -> String {
        identity.conversationURL + "\u{0}" + (identity.stableID ?? "")
    }

    /// A fresh service landing page: no query and a path that names no conversation and has at most one segment (or
    /// is exactly the configured home path).
    private func isHomeLocation(_ href: String) -> Bool {
        guard isTrustedOrigin(Self.normalizedOrigin(href)), let components = URLComponents(string: href),
              (components.queryItems ?? []).isEmpty, !AssistantPlannerURL.namesConversation(components.path) else { return false }
        let path = Self.trimmedPath(components.path)
        return path.split(separator: "/").count <= 1 || path == homePath
    }

    private static func trimmedPath(_ path: String) -> String {
        var text = path
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }

    private func scheduleRestore(epoch restoreEpoch: Int, generation: Int) {
        guard !restoreInFlight, !userTouched else { return }
        Task { @MainActor [weak self] in
            await self?.restoreOriginalConversation(epoch: restoreEpoch, generation: generation)
        }
    }

    /// Asks for the same guarded restore with the current epoch/document; every idle, busy, draft and single-attempt
    /// gate of `restoreOriginalConversation` still applies. Hana only refreshes its guarded host context proof (so a
    /// hidden, API-ready current thread is bound just before the outbox flush) and never navigates; without a proof the
    /// outbox simply keeps holding.
    func restoreIfIdle() async {
        if kind == "hana" {
            await refreshHanaProof()
            return
        }
        await restoreOriginalConversation(epoch: epoch, generation: docGeneration)
    }

    /// After a restart the host shows the service home. When the page is provably fresh and idle (empty composer, no
    /// attachment, no generation, no conversation, no trusted user input since this host started) the one stored
    /// original conversation is opened with a plain native load. Nothing is focused, typed or sent here: the outbox
    /// still sends only after the page reports the exact stored conversation identity. Anything else stays pending.
    private func restoreOriginalConversation(epoch restoreEpoch: Int, generation: Int) async {
        guard !restoreInFlight, !userTouched, restoreEpoch == epoch, generation == docGeneration,
              let host = binding, let ctx = currentContext(), isHomeLocation(ctx.href) else { return }
        let plan = planRestore()
        let identity: AssistantPlannerIdentity
        switch plan {
        case .none: return
        case .blocked(let text):
            if status.message != text { publish(.pending, text, draftPreserved: true) }
            return
        case .target(let found, _): identity = found
        }
        restoreInFlight = true
        defer { if restoreEpoch == epoch { restoreInFlight = false } }
        let outcome = await call("restoreState", [ctx.doc], ctx)
        guard isCurrent(ctx), host === binding, !userTouched else { return }
        guard case .value(let state) = outcome else { return }
        guard state["ok"] as? Bool == true else {
            let reason = state["reason"] as? String
            guard reason != "loading", reason != "stale-document" else { return }
            let text = "원래 대화로 자동 이동하지 않았습니다. " + Self.describe(reason)
            if status.message != text { publish(.pending, text, draftPreserved: true) }
            return
        }
        // Re-plan after the await: the same single target, still unattempted, page still the same fresh home.
        guard case .target(let again, let url) = planRestore(), Self.restoreKey(again) == Self.restoreKey(identity),
              isHomeLocation(ctx.href), webView?.url?.absoluteString == ctx.href else { return }
        restoredTargets.insert(Self.restoreKey(again))
        publish(.pending, "원래 대화로 이동하는 중입니다. 원래 대화가 확인되면 완료 알림을 한 번 보냅니다.", draftPreserved: true)
        ctx.webView.load(URLRequest(url: url))
    }

    // MARK: Send / verify (AssistantPlannerAdapter work)

    /// A positive, own-marker delivery clears an obsolete pending status; every other outcome leaves the status alone.
    fileprivate func performSend(_ entry: AssistantPlannerOutboxEntry, via host: AssistantPlannerHostBinding) async -> AssistantPlannerSendResult {
        let startEpoch = epoch
        let result = await sendEntry(entry, via: host)
        if case .delivered = result { noteResultDelivered(epoch: startEpoch) }
        return result
    }

    fileprivate func performVerify(_ entry: AssistantPlannerOutboxEntry, via host: AssistantPlannerHostBinding) async -> AssistantPlannerDeliveryProof {
        let startEpoch = epoch
        let proof = await verifyEntry(entry, via: host)
        if case .delivered = proof { noteResultDelivered(epoch: startEpoch) }
        return proof
    }

    /// Replaces a stale pending status after a proven delivery. While a capture or handoff owns the pending status,
    /// that capture publishes its own accepted / refused result later, so nothing is overwritten here.
    private func noteResultDelivered(epoch startEpoch: Int) {
        guard startEpoch == epoch, captureCount == 0, status.kind == .pending else { return }
        publish(.accepted, "완료 결과를 원래 대화에 전달했습니다.")
    }

    private func sendEntry(_ entry: AssistantPlannerOutboxEntry, via host: AssistantPlannerHostBinding) async -> AssistantPlannerSendResult {
        let marker = AssistantPlannerCoordinator.marker(for: entry.id)
        guard entry.payload.contains(marker) else { return .notSent("수신 확인 표식이 없는 메시지라 보내지 않았습니다.") }
        guard !sendInFlight else { return .notSent("다른 전송이 진행 중이라 보류했습니다.") }
        sendInFlight = true
        defer { sendInFlight = false }
        // Hana: the page's own host context (account/project/thread) is re-read before the context is chosen.
        if kind == "hana" {
            guard let proof = await refreshHanaProof(), proof.hash == entry.identity.stableID else {
                return .notSent("하나 계정이나 프로젝트, 대화가 달라졌거나 확인하지 못해 보류했습니다.")
            }
        }
        guard let ctx = context(for: entry.identity, host: host) else {
            return .notSent("원래 대화창이 현재 상태와 일치하지 않아 보류했습니다.")
        }
        let sid = ctx.sid

        if kind == "hana" {
            // Hana submits through its own page API; nothing is touched until native validation and the page-side
            // preflight (idle, empty unfocused composer, own thread rows readable) all passed. The DOM sid is NSNull:
            // the native host-context proof (hash + exact page getter) enforces account/project/thread instead.
            guard case .value(let prep) = await call("prepare", [ctx.doc, ctx.href, sid, marker], ctx),
                  let state = prep["state"] as? String else {
                return .notSent("대화 화면을 확인하지 못해 보류했습니다.")
            }
            if state == "delivered" { return .delivered }
            guard state == "ready" else { return .notSent(Self.describe(prep["reason"] as? String)) }
            guard isCurrent(ctx), host.matches(entry.identity) else { return .notSent("대화가 바뀌어 보류했습니다.") }
            guard let requestID = UUID(uuidString: entry.id) else { return .notSent("전송 식별자가 올바르지 않아 보내지 않았습니다.") }
            guard let beforeSend = await refreshHanaProof(), beforeSend.hash == entry.identity.stableID,
                  isCurrent(ctx), host === binding, host.matches(entry.identity) else {
                return .notSent("하나 계정이나 프로젝트, 대화가 달라졌거나 확인하지 못해 보류했습니다.")
            }
            // Hana's own protected FIFO (draft, busy, pending queue, generation and page checks) is the only way in.
            // Every gate re-checks this exact page, document and host binding; completion mode lets the same identity
            // keep working while the panel is hidden, and the page compares the exact host context immediately
            // before openQuery.
            do {
                try await HanaPanelHost.shared.submitPlannerResultQuestion(
                    payload: entry.payload, requestID: requestID,
                    isCurrent: { [weak self, weak host] in
                        guard let self, let host else { return false }
                        return self.isCurrent(ctx) && self.docID == ctx.doc && host === self.binding && host.matches(entry.identity)
                    },
                    options: HanaProtectedOptions(completion: true, expectedHostContext: beforeSend.raw))
            } catch let error as HanaResultQuestionError {
                return error.ambiguous ? .uncertain(error.message) : .notSent(error.message)
            } catch {
                return .uncertain("하나로 보내는 중 오류가 났습니다. 도착 여부를 확인해야 합니다.")
            }
            // A true return from the page is not delivery: only the receipt marker in the thread's own user rows is.
            guard case .value(let seen) = await call("awaitMarker", [ctx.doc, ctx.href, sid, marker, Self.sendTimeoutMS], ctx) else {
                return .uncertain("전송 후 화면 응답이 끊겨 도착 여부를 확인해야 합니다.")
            }
            guard (seen["state"] as? String) == "delivered" else { return .uncertain("전송은 시도했지만 수신 표식을 확인하지 못했습니다.") }
            // The marker row only counts for the same account/project/thread; a host that is not ready (or moved on)
            // keeps the entry uncertain until a later reconcile proves it, and nothing is ever resent blindly.
            guard let afterMarker = await refreshHanaProof(), afterMarker.hash == entry.identity.stableID, isCurrent(ctx) else {
                return .uncertain("전송 후 하나 대화 상태를 확인하지 못해 도착 여부를 다시 확인해야 합니다.")
            }
            return .delivered
        }

        guard case .value(let result) = await call("send", [ctx.doc, ctx.href, sid, entry.payload, marker, Self.sendTimeoutMS], ctx) else {
            return .uncertain("전송 중 화면 응답이 끊겨 도착 여부를 확인해야 합니다.")
        }
        switch result["state"] as? String {
        case "delivered": return .delivered
        case "notSent": return .notSent(Self.describe(result["reason"] as? String))
        default: return .uncertain("전송은 시도했지만 수신 표식을 확인하지 못했습니다.")
        }
    }

    private func verifyEntry(_ entry: AssistantPlannerOutboxEntry, via host: AssistantPlannerHostBinding) async -> AssistantPlannerDeliveryProof {
        let marker = AssistantPlannerCoordinator.marker(for: entry.id)
        guard entry.payload.contains(marker) else { return .unknown }
        if kind == "hana" {
            guard let proof = await refreshHanaProof(), proof.hash == entry.identity.stableID else { return .unknown }
        }
        guard let ctx = context(for: entry.identity, host: host),
              case .value(let result) = await call("verify", [ctx.doc, ctx.href, ctx.sid, marker, Self.sendTimeoutMS], ctx),
              isCurrent(ctx), host.matches(entry.identity) else { return .unknown }
        if kind == "hana" {
            // Delivered or absent only counts for the same account/project/thread as before the page read.
            guard let after = await refreshHanaProof(), after.hash == entry.identity.stableID, isCurrent(ctx) else { return .unknown }
        }
        switch result["state"] as? String {
        case "delivered": return .delivered
        case "absent": return .absent
        default: return .unknown
        }
    }

    // MARK: Context and script calls

    private struct Ctx {
        let webView: WKWebView
        let world: WKContentWorld
        let doc: String
        let epoch: Int
        let gen: Int
        let href: String
        let sid: Any
    }

    private enum CallOutcome {
        case value([String: Any])
        case failed
    }

    private func currentContext() -> Ctx? {
        guard let webView, let world, let docID, let href = webView.url?.absoluteString,
              isTrustedOrigin(Self.normalizedOrigin(href)) else { return nil }
        return Ctx(webView: webView, world: world, doc: docID, epoch: epoch, gen: docGeneration, href: href,
                   sid: scriptSID(liveStableID(epoch: epoch)))
    }

    private static func argument(_ value: String?) -> Any {
        if let value { return value }
        return NSNull()
    }

    /// The DOM thread id handed to the isolated script. Hana's stable ID is a native hash of the page's host context,
    /// not a DOM value, so its script gates get none (the native proof enforces account/project/thread instead).
    private func scriptSID(_ id: String?) -> Any {
        kind == "hana" ? NSNull() : Self.argument(id)
    }

    private func context(for identity: AssistantPlannerIdentity, host: AssistantPlannerHostBinding) -> Ctx? {
        guard host === binding, host.hostID == hostID, host.webView === webView, host.matches(identity),
              identity.serviceID == serviceID, identity.profileID == profileID,
              let webView, let world, let docID, let href = webView.url?.absoluteString,
              isTrustedOrigin(Self.normalizedOrigin(href)),
              AssistantPlannerURL.safe(href, hasStableID: identity.stableID != nil) == identity.conversationURL else { return nil }
        return Ctx(webView: webView, world: world, doc: docID, epoch: epoch, gen: docGeneration, href: href,
                   sid: scriptSID(identity.stableID))
    }

    private func isCurrent(_ ctx: Ctx) -> Bool {
        ctx.epoch == epoch && ctx.gen == docGeneration && webView === ctx.webView && webView?.url?.absoluteString == ctx.href
    }

    private func call(_ function: String, _ args: [Any], _ ctx: Ctx) async -> CallOutcome {
        let body = "if (!window.__afPlanner || typeof window.__afPlanner[fn] !== 'function') { return { ok: false, state: 'notSent', reason: 'no-script' }; } return await window.__afPlanner[fn](...args);"
        do {
            let result = try await ctx.webView.callAsyncJavaScript(body, arguments: ["fn": function, "args": args],
                                                                   in: nil, contentWorld: ctx.world)
            if let dictionary = result as? [String: Any] { return .value(dictionary) }
            return .failed
        } catch {
            return .failed
        }
    }

    // MARK: Live identity

    private func liveConversationURL(epoch expected: Int) -> String? {
        guard expected == epoch, let homeOrigin, let raw = webView?.url?.absoluteString,
              isTrustedOrigin(Self.normalizedOrigin(raw)) else { return nil }
        if kind == "hana" {
            // The Hana root names a conversation only while the page's own host context proof is current.
            guard liveHanaHash(epoch: expected) != nil else { return nil }
            return AssistantPlannerURL.safe(raw, hasStableID: true)
        }
        if let url = AssistantPlannerURL.safe(raw) { return url }
        // A root-style address names a conversation only while the page itself exposes a genuine stable ID for it.
        if let observed = observedStable, observed.url == AssistantPlannerURL.safe(raw, hasStableID: true) { return observed.url }
        return nil
    }

    private func liveStableID(epoch expected: Int) -> String? {
        if kind == "hana" { return liveConversationURL(epoch: expected) == nil ? nil : liveHanaHash(epoch: expected) }
        guard let url = liveConversationURL(epoch: expected), let observed = observedStable, observed.url == url else { return nil }
        return observed.id
    }

    /// The cached Hana host-context hash, only while it belongs to this exact epoch, document and address.
    private func liveHanaHash(epoch expected: Int) -> String? {
        guard kind == "hana", expected == epoch, let proof = hanaProof, proof.epoch == epoch, proof.gen == docGeneration,
              proof.doc == docID, proof.href == webView?.url?.absoluteString else { return nil }
        return proof.hash
    }

    /// Reads the page's published `window.HanstreeAlfred.hostContext()` (page world, exact trusted Hana top frame) with a
    /// finite native deadline and refreshes the cached proof. A missing, malformed or unavailable value clears the
    /// cache, so the host reads as unprepared until the page reports a ready context again.
    @discardableResult
    private func refreshHanaProof() async -> (hash: String, raw: String)? {
        guard kind == "hana", let webView, let docID, let homeOrigin, let href = webView.url?.absoluteString,
              Self.isTrustedHanaURL(webView.url) else {
            hanaProof = nil
            return nil
        }
        let startEpoch = epoch, startGen = docGeneration
        let value = await Self.readHostContext(webView, origin: homeOrigin)
        // A newer document or configuration owns the cache now; this late answer must not touch it.
        guard startEpoch == epoch, startGen == docGeneration, docID == self.docID, webView === self.webView,
              webView.url?.absoluteString == href else { return nil }
        guard let value, let hash = Self.hanaContextHash(value) else {
            hanaProof = nil
            return nil
        }
        hanaProof = (hash, value, startEpoch, docID, startGen, href)
        reconcilePageMode()
        return (hash, value)
    }

    private static func isTrustedHanaURL(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https", url.host?.lowercased() == HanaPanelHost.trustedHost,
              (url.port ?? 443) == HanaPanelHost.trustedPort, url.user == nil, url.password == nil else { return false }
        return trimmedPath(url.path) == HanaPanelHost.trustedPath
    }

    private static func readHostContext(_ webView: WKWebView, origin: String) async -> String? {
        let body = "if (window.top !== window || location.origin !== origin) { return null; } try { const api = window.HanstreeAlfred; if (!api || typeof api.hostContext !== 'function') { return null; } const v = api.hostContext(); return typeof v === 'string' ? v : null; } catch (e) { return null; }"
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let once = AssistantWebOnce()
            DispatchQueue.main.asyncAfter(deadline: .now() + hostContextTimeout) {
                if once.claim() { continuation.resume(returning: nil) }
            }
            webView.callAsyncJavaScript(body, arguments: ["origin": origin], in: nil, in: .page) { result in
                guard once.claim() else { return }
                if case .success(let value) = result {
                    continuation.resume(returning: value as? String)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// Validates the four-part `generation|account|project|thread` value and returns SHA-256(account|project|thread).
    /// The generation is volatile and deliberately excluded so the identity survives a restart.
    private static func hanaContextHash(_ raw: String) -> String? {
        guard !raw.isEmpty, raw.utf16.count <= 2048 else { return nil }
        let parts = raw.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 4, !parts[0].isEmpty, parts[0].count <= 20,
              parts[0].allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        for part in parts.dropFirst() where part.isEmpty || part.utf16.count > 512 { return nil }
        let digest = SHA256.hash(data: Data(parts.dropFirst().joined(separator: "|").utf8))
        let hash = digest.map { String(format: "%02x", $0) }.joined()
        return hash.count <= AssistantPlannerIdentity.maxFieldLength ? hash : nil
    }

    /// Records the DOM thread id the script actually saw for the current conversation URL.
    private func noteObservation(_ body: [String: Any]) {
        // Hana's identity is the page's host context proof; a DOM observation (absent on /alfred) never replaces it.
        guard kind != "hana" else { return }
        guard let reported = body["u"] as? String, let homeOrigin, let live = webView?.url?.absoluteString,
              isTrustedOrigin(Self.normalizedOrigin(live)) else { return }
        if let id = body["s"] as? String, !id.isEmpty, id.count <= AssistantPlannerIdentity.maxFieldLength {
            guard let safe = AssistantPlannerURL.safe(reported, hasStableID: true),
                  safe == AssistantPlannerURL.safe(live, hasStableID: true) else { return }
            observedStable = (safe, id)
        } else if let safe = AssistantPlannerURL.safe(reported), safe == AssistantPlannerURL.safe(live) {
            observedStable = nil
        } else if let observed = observedStable, observed.url == AssistantPlannerURL.safe(reported, hasStableID: true) {
            observedStable = nil
        }
    }

    // MARK: Retire / routes

    private func retire() {
        if let old = world {
            for controller in installedControllers.allObjects {
                controller.removeScriptMessageHandler(forName: Self.handlerName, contentWorld: old)
            }
            webView?.evaluateJavaScript("if (window.__afPlanner) { window.__afPlanner.retire(); }", in: nil, in: old, completionHandler: nil)
        }
        installedControllers.removeAllObjects()
        if pageModeOn {
            pageModeOn = false
            onPageModeChange?(false)
        }
        pageModeKey = nil
        pageModeMayAdopt = false
        if binding != nil { coordinator.detach(hostID: hostID) }
        unregisterRoute()
        serviceID = ""
        profileID = ""
        binding = nil
        epoch += 1
        world = nil
        homeOrigin = nil
        scriptSource = ""
        docID = nil
        docGeneration += 1
        observedStable = nil
        hanaProof = nil
        seenRequests.removeAll()
        lifecyclePending = false
        captureCount = 0
        homePath = ""
        userTouched = false
        restoreInFlight = false
        restoredTargets.removeAll()
    }

    private func registerRoute() -> Bool {
        if let existing = coordinator.adapter(for: serviceID) {
            guard let hub = existing as? AssistantWebServiceAdapter else { return false }
            hub.add(self)
        } else {
            let hub = AssistantWebServiceAdapter(serviceID: serviceID)
            hub.add(self)
            coordinator.register(adapter: hub)
        }
        return true
    }

    private func unregisterRoute() {
        guard !serviceID.isEmpty, let hub = coordinator.adapter(for: serviceID) as? AssistantWebServiceAdapter else { return }
        hub.remove(hostID: hostID)
        if hub.isEmpty { coordinator.unregisterAdapter(serviceID: serviceID) }
    }

    private func publish(_ kind: AssistantWebStatus.Kind, _ message: String, draftPreserved: Bool = false) {
        let next = AssistantWebStatus(kind: kind, message: message, draftPreserved: draftPreserved)
        status = next
        onStatus?(next)
    }

    // MARK: Static helpers

    static func kind(serviceID: String, origin: String) -> String {
        switch serviceID.lowercased() {
        case "hana": return "hana"
        case "chatgpt": return "chatgpt"
        case "claude": return "claude"
        case "gemini": return "gemini"
        case "perplexity": return "perplexity"
        // Catalog providers: Grok / Copilot / Meta have an image route; the rest are read-only page transport (text).
        case "grok", "copilot", "deepseek", "mistral", "qwen", "kimi", "meta", "poe", "huggingchat": return serviceID.lowercased()
        default: break
        }
        let host = origin.replacingOccurrences(of: "https://", with: "")
        if host == "chatgpt.com" || host == "chat.openai.com" { return "chatgpt" }
        if host == "claude.ai" { return "claude" }
        if host == "gemini.google.com" { return "gemini" }
        return "generic"
    }

    /// Exact https origins trusted for a configuration. The catalog Copilot address redirects to the official chat
    /// origin, and its "채팅으로 이동" opens the signed-in personal chat on copilot.cloud.microsoft, so only those exact
    /// origins are allowed (never the login or wildcard hosts).
    static func trustedOrigins(serviceID: String, home: String) -> [String] {
        if serviceID.lowercased() == "copilot", home == "https://copilot.microsoft.com" || home == "https://copilot.com" {
            return ["https://copilot.microsoft.com", "https://copilot.com", "https://copilot.cloud.microsoft"]
        }
        return [home]
    }

    private func isTrustedOrigin(_ origin: String?) -> Bool {
        guard let origin, let homeOrigin else { return false }
        return Self.trustedOrigins(serviceID: serviceID, home: homeOrigin).contains(origin)
    }

    static func normalizedOrigin(_ raw: String) -> String? {
        guard let origin = AssistantPlannerURL.origin(of: raw) else { return nil }
        return origin.hasSuffix(":443") ? String(origin.dropLast(4)) : origin
    }

    static func origin(of security: WKSecurityOrigin) -> String? {
        guard security.protocol.lowercased() == "https", !security.host.isEmpty else { return nil }
        return "https://" + security.host.lowercased() + (security.port == 0 || security.port == 443 ? "" : ":\(security.port)")
    }

    private static func isToken(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 64 && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    private static let unsupportedReasons: Set<String> = [
        "composer-missing", "composer-ambiguous", "no-conversation-scope", "role-unidentified", "roles-not-distinct"
    ]

    private static func isUnsupportedReason(_ reason: String?) -> Bool {
        reason.map { unsupportedReasons.contains($0) } ?? false
    }

    /// A page-question submit whose post was not proven: the script's own unconfirmed result, or a call that ended without
    /// any result (the page may have moved after the click).
    private static func postUnconfirmed(_ result: CallOutcome) -> Bool {
        if case .value(let dict) = result { return dict["reason"] as? String == "post-unconfirmed" }
        return true
    }

    /// A Meta submit's fixed 0/1 gate bits (never page content), else "-".
    private static func gateBits(_ result: CallOutcome, _ key: String) -> String {
        guard case .value(let dict) = result, let s = dict[key] as? String,
              s.range(of: "^[01]{1,16}$", options: .regularExpression) != nil else { return "-" }
        return s
    }

    private static func describe(_ reason: String?) -> String {
        switch reason {
        case "composer-missing": return "이 페이지에서 메시지 입력창을 찾지 못했습니다."
        case "composer-ambiguous": return "입력창이 둘 이상이라 안전하게 고를 수 없습니다."
        case "no-conversation-scope": return "대화 영역을 찾지 못했습니다."
        case "role-unidentified": return "메시지의 사용자/AI 구분을 확인할 수 없습니다."
        case "roles-not-distinct": return "메시지의 사용자/AI 구분이 확실하지 않습니다."
        case "no-user-rows": return "이 대화에 아직 보낸 메시지가 없습니다."
        case "draft-not-empty": return "입력창에 작성 중인 내용이 있어 보류했습니다."
        case "composer-focused": return "입력창을 사용 중이라 보류했습니다."
        case "generating": return "AI가 응답 중이라 보류했습니다."
        case "loading": return "페이지를 불러오는 중이라 보류했습니다."
        case "user-active": return "직접 사용 중인 화면이라 보류했습니다."
        case "conversation-open": return "이미 다른 대화가 열려 있어 보류했습니다."
        case "attachment-present": return "첨부 중인 파일이 있어 보류했습니다."
        case "first-use-confirmation": return "이미지 첫 사용 확인 창이 떠 있어 보내지 않았습니다. 확인 후 다시 시도해 주세요."
        case "first-use-confirmation-uncancelled": return "이미지 첫 사용 확인 창이 떠 있어 보내지 않았습니다. 창을 직접 닫은 뒤 다시 시도해 주세요."
        case "stale-document", "retired", "origin-changed", "url-changed", "thread-changed":
            return "대화 화면이 바뀌어 보류했습니다."
        case "pagecontext-timeout": return "페이지 본문 전달 응답이 없어 보내지 않았습니다."
        case "composer-write-failed": return "입력창에 메시지를 넣지 못해 보내지 않았습니다."
        case "send-button-not-ready": return "전송 버튼을 하나로 확인하지 못해 보내지 않았습니다."
        case "preclick-stale": return "전송 직전 입력창의 질문이나 이미지가 그대로인지 확인하지 못해 전송 버튼을 누르지 않았습니다."
        case "no-script": return "대화창 연결 스크립트가 아직 준비되지 않았습니다."
        case .some(let other): return "페이지 상태를 확인하지 못했습니다(\(String(other.prefix(40))))."
        case .none: return "페이지 상태를 확인하지 못했습니다."
        }
    }
}

// MARK: - Isolated-world script

enum AssistantWebScript {
    static func source(kind: String, origin: String, origins: [String]? = nil, pattern: String, handler: String, nonce: String, watch: Bool) -> String {
        let config: [String: Any] = ["kind": kind, "origin": origin, "origins": origins ?? [origin], "pattern": pattern,
                                     "handler": handler, "nonce": nonce, "watch": watch]
        let data = (try? JSONSerialization.data(withJSONObject: config)) ?? Data("{}".utf8)
        return template.replacingOccurrences(of: "__CONFIG__", with: String(decoding: data, as: UTF8.self))
    }

    private static let template = #"""
(() => {
'use strict';
const CFG = __CONFIG__;
if (window.__afPlanner || window.top !== window || !CFG.origins.includes(location.origin)) return;
const HANDLER = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers[CFG.handler];
if (!HANDLER) return;
let TRIG;
try { TRIG = new RegExp(CFG.pattern, 'iu'); } catch (e) { return; }
let alive = true, watch = !!CFG.watch, sig = '', touched = false, touchGen = 0;
const pending = Object.create(null);
const uuid = () => (crypto.randomUUID && crypto.randomUUID()) || ('r' + Date.now().toString(36) + Math.random().toString(36).slice(2));
const DOC = uuid();
const EDITABLE = 'textarea, input[type="text"], [contenteditable]:not([contenteditable="false"]), [role="textbox"]';
const GEN_SEL = '[data-testid="stop-button"], [data-testid="stop-generating-button"], button[aria-label*="Stop" i], button[aria-label*="중지"], button[aria-label*="중단"], [data-streaming="true"], [data-state="streaming"], [aria-busy="true"]';
const SEND_RE = /(?:^|[^a-z])send|submit|전송|보내/i;
const NOT_SEND_RE = /stop|cancel|중지|중단|취소|attach|upload|첨부|voice|mic|resend/i;
const TESTID_RE = /^(?:(user|human|assistant|ai|bot|model)[-_](?:message|msg|turn|row|bubble|query|response)|(?:message|msg|turn|chat)[-_](user|human|assistant|ai|bot|model))$/i;

const q = (sel, root) => Array.from((root || document).querySelectorAll(sel));
const visible = (el) => {
  if (!el || !el.isConnected || !el.getClientRects().length) return false;
  const cs = getComputedStyle(el);
  return cs.visibility !== 'hidden' && cs.display !== 'none';
};
const norm = (s) => String(s == null ? '' : s).replace(/​/g, '').replace(/\s+/g, ' ').trim();
const isField = (el) => el.tagName === 'TEXTAREA' || el.tagName === 'INPUT';
// Copilot's M365 editor keeps a renderer sentinel (U+200B U+200C) after its content; observed in the live editor and,
// through the raw capture, inside the written prompt. Only that one trailing pair of that editor is dropped, so capture,
// readback and restore compare the text itself (norm keeps U+200C for every other editor).
const isM365Editor = (el) => CFG.kind === 'copilot' && el.id === 'm365-chat-editor-target-element';
const textOf = (el) => {
  if (isField(el)) return String(el.value || '');
  const t = String(el.innerText != null ? el.innerText : (el.textContent || ''));
  return isM365Editor(el) ? t.replace(/\u200B\u200C(?=\s*$)/, '') : t;
};
const rowText = (el) => String(el.innerText || el.textContent || '').replace(/\r\n?/g, '\n').replace(/\n{3,}/g, '\n\n').trim().slice(0, 12000);
const innermost = (list) => list.filter((el) => !list.some((o) => o !== el && el.contains(o)));
const clamp = (ms) => Math.max(500, Math.min(15000, Number(ms) || 8000));
const isEnabled = (b) => !b.disabled && b.getAttribute('aria-disabled') !== 'true';
const ns = (reason) => ({ state: 'notSent', reason });

function isTrigger(raw) {
  const t = String(raw == null ? '' : raw).normalize('NFC').trim();
  return t.length > 0 && t.length <= 400 && TRIG.test(t);
}

function hash(s) {
  let h1 = 0xdeadbeef, h2 = 0x41c6ce57;
  for (let i = 0; i < s.length; i++) {
    const ch = s.charCodeAt(i);
    h1 = Math.imul(h1 ^ ch, 2654435761);
    h2 = Math.imul(h2 ^ ch, 1597334677);
  }
  h1 = Math.imul(h1 ^ (h1 >>> 16), 2246822507) ^ Math.imul(h2 ^ (h2 >>> 13), 3266489909);
  h2 = Math.imul(h2 ^ (h2 >>> 16), 2246822507) ^ Math.imul(h1 ^ (h1 >>> 13), 3266489909);
  return (h2 >>> 0).toString(16).padStart(8, '0') + (h1 >>> 0).toString(16).padStart(8, '0');
}

// A DOM thread id is only used when the page itself exposes exactly one distinct value.
function domId() {
  try {
    const values = new Set();
    // Hana: only the message root's own attributes (sidebar entries carry thread ids of other conversations).
    for (const el of q(CFG.kind === 'hana' ? '#afMessages' : '[data-conversation-id], [data-conv-id], [data-thread-id], [data-chat-id]')) {
      const v = el.getAttribute('data-conversation-id') || el.getAttribute('data-conv-id') || el.getAttribute('data-thread-id') || el.getAttribute('data-chat-id');
      if (v && v.length <= 256) values.add(v);
    }
    return values.size === 1 ? Array.from(values)[0] : null;
  } catch (e) { return null; }
}

function post(o) {
  if (!alive) return false;
  try { o.n = CFG.nonce; o.doc = DOC; o.u = location.href; o.s = domId(); HANDLER.postMessage(o); return true; }
  catch (e) { alive = false; return false; }
}

// ---- roles -------------------------------------------------------------------------------------------------
const USER_TOKENS = ['user', 'human', 'me', 'you', 'prompt', 'query', 'question'];
const AI_TOKENS = ['assistant', 'ai', 'bot', 'model', 'answer', 'response', 'claude', 'gemini', 'gpt', 'chatgpt'];
function tokenRole(v) {
  const toks = String(v || '').toLowerCase().split(/[^a-z]+/).filter(Boolean);
  const u = toks.some((t) => USER_TOKENS.includes(t)), a = toks.some((t) => AI_TOKENS.includes(t));
  return u === a ? null : (u ? 'user' : 'assistant');
}
function exactRole(v) {
  const t = String(v || '').toLowerCase();
  if (t === 'user' || t === 'human') return 'user';
  if (t === 'assistant' || t === 'ai' || t === 'bot' || t === 'model') return 'assistant';
  return null;
}
function roleOf(el, withClass) {
  for (const a of ['data-message-author-role', 'data-author-role', 'data-message-role', 'data-role', 'data-sender', 'data-author']) {
    const r = exactRole(el.getAttribute(a));
    if (r) return r;
  }
  const m = TESTID_RE.exec(el.getAttribute('data-testid') || '');
  if (m) return exactRole(m[1] || m[2]);
  return withClass ? tokenRole(el.getAttribute('class')) : null;
}

// ---- composer ----------------------------------------------------------------------------------------------
function knownComposer() {
  switch (CFG.kind) {
    case 'hana': return q('#afInput');
    case 'chatgpt': return q('#prompt-textarea, [data-composer-body] [data-composer-markdown][contenteditable="true"][role="textbox"]');
    case 'claude': return q('div[contenteditable="true"][role="textbox"], div.ProseMirror[contenteditable="true"]');
    case 'gemini': return geminiComposer();
    case 'perplexity': return q('.composer-editable[data-lexical-editor="true"][role="textbox"][contenteditable="true"]');
    // Grok's signed-in composer is a tiptap editor (its measuring textarea is never the composer); Copilot's is one span.
    case 'grok': return q('[data-testid="chat-input"] div[contenteditable="true"][role="combobox"].ProseMirror');
    case 'copilot': return q('span[id="m365-chat-editor-target-element"][role="textbox"][contenteditable="true"]');
    // Meta AI: one Lexical div (role=textbox) outside any form; its send button is found by its accessible name.
    case 'meta': return q('div[data-lexical-editor="true"][role="textbox"][contenteditable="true"]');
    default: return [];
  }
}
// Gemini wraps one logical composer in rich-textarea > .ql-editor plus read-only / aria-hidden render clones.
// Only the rendered, editable innermost node counts; two independent editors stay two candidates.
function geminiComposer() {
  return innermost(q('rich-textarea .ql-editor[contenteditable="true"], rich-textarea [contenteditable="true"], rich-textarea textarea[aria-label*="prompt" i]').filter((el) => {
    if (!visible(el) || el.getAttribute('contenteditable') === 'false' || el.getAttribute('aria-readonly') === 'true') return false;
    if (el.closest('[aria-hidden="true"], [inert], [readonly], [disabled], [aria-readonly="true"]')) return false;
    const r = el.getBoundingClientRect();
    return r.width > 0 && r.height > 0;
  }));
}
// Accessible name of a button from its own label sources (the name the AX tree shows), never a sibling's text.
function accName(b) {
  const lb = (b.getAttribute('aria-labelledby') || '').split(/\s+/).filter(Boolean).map((id) => { const x = document.getElementById(id); return x ? x.textContent : ''; }).join(' ');
  const svg = b.querySelector('svg title');
  return norm(b.getAttribute('aria-label') || lb || b.getAttribute('title') || b.textContent || (svg && svg.textContent) || '');
}
function isSendLike(b) {
  // Meta's send button carries no send attribute; it is the one button whose accessible name is exactly 보내기.
  if (CFG.kind === 'meta') return accName(b) === '보내기';
  const t = [b.getAttribute('data-testid'), b.getAttribute('aria-label'), b.getAttribute('title'), b.id, b.getAttribute('name')].filter(Boolean).join(' ');
  if (NOT_SEND_RE.test(t)) return false;
  if (CFG.kind === 'gemini') return SEND_RE.test(t);
  if (CFG.kind === 'perplexity') return SEND_RE.test(t) || b.getAttribute('aria-label') === '제출';
  return SEND_RE.test(t) || (b.tagName === 'BUTTON' && b.type === 'submit');
}
function sendCandidates(root) {
  return innermost(q('button, [role="button"]', root).filter((b) => visible(b) && isSendLike(b)));
}
const ROOT_DEPTH = CFG.kind === 'meta' ? 14 : 8;
function chatRoot(el) {
  const form = el.closest('form, [role="form"]');
  if (form) return form;
  let p = el.parentElement;
  for (let i = 0; i < ROOT_DEPTH && p && p !== document.body && p !== document.documentElement; i++, p = p.parentElement) {
    if (sendCandidates(p).length) return p;
  }
  return null;
}
function genericComposer() {
  let list = q('textarea, [contenteditable]:not([contenteditable="false"]), [role="textbox"]').filter((el) =>
    visible(el) && !el.disabled && !el.readOnly && el.getAttribute('aria-readonly') !== 'true'
    && !el.closest('[aria-hidden="true"], nav, header, dialog, [role="dialog"], [role="search"], [role="navigation"]')
    && el.getAttribute('role') !== 'searchbox' && el.type !== 'search');
  list = innermost(list);
  return list.filter((el) => { const r = chatRoot(el); return !!r && !r.querySelector('input[type="password"], input[autocomplete~="username"], input[autocomplete~="current-password"]'); });
}
function composerInfo() {
  let list = innermost(Array.from(new Set(knownComposer())).filter(visible));
  if (list.length > 1) return { reason: 'composer-ambiguous', known: true, list };
  if (!list.length) {
    list = genericComposer();
    if (list.length > 1) return { reason: 'composer-ambiguous' };
    if (!list.length) return { reason: 'composer-missing' };
  }
  return { el: list[0] };
}
// Hana only: the page host may be hidden or zero-sized (no client rects), so the exact current #afInput TEXTAREA is
// identified structurally. Native hostContext proof and the protected FIFO remain the authority for visibility/login.
function hanaComposer() {
  const list = q('#afInput');
  if (list.length > 1) return { reason: 'composer-ambiguous' };
  const el = list[0];
  if (!el || !el.isConnected || el.tagName !== 'TEXTAREA') return { reason: 'composer-missing' };
  return { el };
}
function sendButton(comp) {
  const root = chatRoot(comp);
  const list = root ? sendCandidates(root) : [];
  return list.length === 1 ? list[0] : null;
}

// ---- rows --------------------------------------------------------------------------------------------------
function genericRaw() {
  const scope = document.querySelector('[role="log"]') || document.querySelector('main, [role="main"]');
  if (!scope) return null;
  const out = [];
  for (const el of q('[data-message-author-role], [data-author-role], [data-message-role], [data-role], [data-sender], [data-author], [data-testid]', scope)) {
    const role = roleOf(el, false);
    if (role) out.push({ el, role });
  }
  return out;
}
// Gemini: a user-query's single .query-text holds a screen-reader heading plus the real paragraphs; only the direct
// p.query-text-line elements are the user's words (joined in order, one row). A model-response uses its one .markdown
// body. A missing / ambiguous user body is role-less so the capture is refused instead of reading UI text.
function geminiRow(el) {
  if (el.tagName === 'USER-QUERY') {
    const boxes = q('.query-text', el);
    const lines = boxes.length === 1 ? Array.from(boxes[0].querySelectorAll(':scope > p.query-text-line')) : [];
    if (!lines.length) return { el, role: null };
    return { el: boxes[0], role: 'user', t: lines.map(rowText).join('\n').slice(0, 12000) };
  }
  const bodies = q('.markdown', el);
  if (bodies.length > 1) return { el, role: null };
  return { el: bodies.length ? bodies[0] : el, role: 'assistant' };
}
function rawRows() {
  let list = [];
  switch (CFG.kind) {
    case 'hana': {
      const c = document.querySelector('#afMessages');
      // Exact Hana structure: #afMessages > .af-msg-row.user > .af-msg.user (assistant analog). Anything else is unidentified.
      if (c) {
        list = Array.from(c.querySelectorAll(':scope > .af-msg-row')).map((row) => {
          const role = row.classList.contains('user') ? 'user' : (row.classList.contains('assistant') ? 'assistant' : null);
          const body = role ? row.querySelector(':scope > .af-msg.' + role) : null;
          return body ? { el: body, role } : { el: row, role: null };
        });
      }
      break;
    }
    case 'chatgpt': {
      // Old role-attribute nodes plus the current user and assistant bodies; one list in DOM order, each node once.
      const old = q('[data-message-author-role]').map((el) => ({ el, role: exactRole(el.getAttribute('data-message-author-role')) }));
      const cur = q('[data-markdown-text-tone="user-message"], [data-user-message-bubble="true"] [data-search-result-target] .whitespace-pre-wrap').filter((el) => !old.some((o) => o.el === el)).map((el) => ({ el, role: 'user' }));
      const ast = q('[data-markdown-text-style="assistant-message"]').filter((el) => !old.some((o) => o.el === el) && !cur.some((o) => o.el === el)).map((el) => ({ el, role: 'assistant' }));
      list = old.concat(cur, ast).sort((a, b) => (a.el.compareDocumentPosition(b.el) & Node.DOCUMENT_POSITION_FOLLOWING ? -1 : 1));
      break;
    }
    case 'claude': list = q('[data-testid="user-message"], [data-testid="assistant-message"]').map((el) => ({ el, role: el.getAttribute('data-testid') === 'user-message' ? 'user' : 'assistant' })); break;
    case 'gemini': list = q('user-query, model-response').map(geminiRow); break;
    case 'perplexity': {
      // Only the lm prose nodes: the user bubble body and the assistant final text (never the workflow card / root). One
      // query keeps DOM order and lists each node once; a node matching both roles stays role-less (refused, not guessed).
      const PU = '[data-message-bubble="right"] [data-renderer="lm"]', PA = '[data-workflow-final-text] [data-renderer="lm"]';
      list = q(PU + ', ' + PA).map((el) => {
        const u = el.matches(PU), a = el.matches(PA);
        return { el, role: u === a ? null : (u ? 'user' : 'assistant') };
      });
      break;
    }
    default: break;
  }
  if (list.length) return { list, src: 'known' };
  return { list: genericRaw(), src: 'generic' };
}
function rowsInfo(comp) {
  const raw = rawRows();
  if (!raw.list) return { reason: 'no-conversation-scope' };
  let list = raw.list.filter((x) => x.el.isConnected && !x.el.contains(comp) && !comp.contains(x.el));
  list = list.filter((x) => !list.some((o) => o !== x && o.el.contains(x.el)));
  const rows = [];
  for (const x of list) {
    if (!(x.el.textContent || '').trim()) continue;
    if (!x.role) return { reason: 'role-unidentified' };
    rows.push(x);
  }
  if (!rows.some((r) => r.role === 'user')) return { reason: 'no-user-rows' };
  if (raw.src === 'generic' && !rows.some((r) => r.role === 'assistant')) return { reason: 'roles-not-distinct' };
  return { ok: true, rows, src: raw.src };
}
function generating() {
  if (CFG.kind === 'hana' && document.querySelector('#afMessages .af-share-controls[data-streaming="true"]')) return true;
  return q(GEN_SEL).some((el) => visible(el) || el.matches('[aria-busy="true"]'));
}
// true / false when the thread's own user rows could be read, null when they could not.
function markerPresent(marker) {
  if (CFG.kind === 'hana') {
    // No viewport / client-rect requirement: only the exact composer and the connected message root's direct user
    // bodies (never toolbars), newest 80. A hit is proof by itself; absence needs the whole thread to be identified.
    const hc = hanaComposer();
    const root = q('#afMessages');
    if (!hc.el || root.length !== 1 || !root[0].isConnected || root[0].contains(hc.el)) return null;
    const bodies = Array.from(root[0].querySelectorAll(':scope > .af-msg-row.user > .af-msg.user'));
    for (let i = bodies.length - 1; i >= 0 && i >= bodies.length - 80; i--) {
      if ((bodies[i].textContent || '').includes(marker)) return true;
    }
    return rowsInfo(hc.el).ok ? false : null;
  }
  const c = composerInfo();
  if (!c.el) return null;
  const r = rowsInfo(c.el);
  if (!r.ok) return null;
  const users = r.rows.filter((x) => x.role === 'user');
  for (let i = users.length - 1; i >= 0 && i >= users.length - 80; i--) {
    if ((users[i].el.textContent || '').includes(marker)) return true;
  }
  return false;
}

// ---- capture -----------------------------------------------------------------------------------------------
function buildCapture(rows) {
  const rt = (x) => (x.t != null ? x.t : (x.t = rowText(x.el)));
  const msgs = [];
  let total = 0;
  for (let i = rows.length - 1; i >= 0 && msgs.length < 8; i--) {
    const t = rt(rows[i]);
    if (!t || isTrigger(t)) continue;
    const clip = t.slice(0, 1500);
    if (total + clip.length > 6000) break;
    total += clip.length;
    msgs.unshift({ r: rows[i].role, t: clip });
  }
  let goal = null;
  for (let i = rows.length - 1; i >= 0 && i >= rows.length - 200; i--) {
    if (rows[i].role !== 'user') continue;
    const t = rt(rows[i]);
    if (!t || isTrigger(t)) continue;
    goal = t.slice(0, 10000);
    break;
  }
  const first = rows.find((x) => x.role === 'user');
  return { ok: true, msgs, goal, fk: hash(rt(first).slice(0, 600)), nu: rows.filter((x) => x.role === 'user').length, u: location.href, s: domId() };
}
function captureNow() {
  const c = composerInfo();
  if (!c.el) return { ok: false, reason: c.reason };
  const r = rowsInfo(c.el);
  if (!r.ok) return { ok: false, reason: r.reason };
  const cap = buildCapture(r.rows);
  cap.raw = textOf(c.el).slice(0, 400);
  return cap;
}

// ---- trusted trigger ---------------------------------------------------------------------------------------
function intercept(e, via, comp, raw) {
  e.preventDefault();
  e.stopImmediatePropagation();
  const now = Date.now();
  for (const k of Object.keys(pending)) if (now - pending[k].t > 60000) delete pending[k];
  if (Object.keys(pending).length) return;
  const req = uuid();
  const cap = captureNow();
  if (!cap.ok) { post({ t: 'refused', req, via, reason: cap.reason }); return; }
  // In-memory DOM proof of this exact conversation view (never posted, logged or persisted): the ack clears the draft
  // only while the same composer, address, first user body and DOM thread id are still there.
  const proof = rowsInfo(comp);
  const firstUser = proof.ok ? proof.rows.find((x) => x.role === 'user') : null;
  if (!firstUser || !firstUser.el || !comp.isConnected) { post({ t: 'refused', req, via, reason: proof.reason || 'no-user-rows' }); return; }
  pending[req] = { raw, t: now, comp, href: location.href, user: firstUser.el, sid: domId() };
  post({ t: 'trigger', req, via, raw, cap });
}
// A genuine trigger typed into one of several known composers must not reach the AI as a normal message.
function refuseAmbiguous(e, via, c, hit) {
  if (!c.known || !c.list.some(hit)) return false;
  e.preventDefault();
  e.stopImmediatePropagation();
  post({ t: 'refused', req: uuid(), via, reason: c.reason });
  return true;
}
const IMAGE_PAGE_KINDS = new Set(['chatgpt', 'claude', 'gemini', 'perplexity', 'grok', 'copilot', 'meta']);
const SUPPORTED_PAGE_KINDS = new Set(['chatgpt', 'claude', 'gemini', 'perplexity', 'grok', 'copilot', 'deepseek', 'mistral', 'qwen', 'kimi', 'meta', 'poe', 'huggingchat']);
let pageContextInFlight = false;
// Browser mode of this conversation, mirrored from native (default off; native pushes it on every new document).
let PAGE_MODE = false;
// The provider's own slash menu is open: an expanded composer or a shown listbox with a shown option (Perplexity keeps an
// option-less listbox mounted, which is not a menu). Diagnostic only: an explicit slash question is still ours, never the
// provider's ordinary send.
function menuOptions() { return q('[role="listbox"]').filter(visible).reduce((n, l) => n + q('[role="option"]', l).filter(visible).length, 0); }
function slashMenuOpen(comp) {
  try { return comp.getAttribute('aria-expanded') === 'true' || menuOptions() > 0; } catch (e) { return false; }
}
// 'intercept' only for a slash question or, while browser mode is on, any non-empty question; 'swallow' while our own
// page question is still being read / written (a second send must never reach the site as a plain message).
function pageContextVerdict(comp, raw, via) {
  if (!SUPPORTED_PAGE_KINDS.has(CFG.kind)) return null;
  if (!comp || !comp.isConnected) return null;
  if (norm(raw).length === 0) return null;
  if (pageContextInFlight) return 'swallow';
  const slash = String(raw).trim().startsWith('/');
  if (!slash && !PAGE_MODE) return null;
  return 'intercept';
}
function interceptPageContext(e, via, comp, raw) {
  e.preventDefault();
  e.stopImmediatePropagation();
  pcStage = 'i';
  let ak = '', gen = false;
  // A failed page check never leaves the request silently pending: nothing was sent and the composer is untouched.
  try { ak = attachmentKind(); gen = generating(); } catch (err) {
    pcStage += 't';
    post({ t: 'refused', req: uuid(), via, reason: 'pagecontext-exception' });
    return;
  }
  pageContextInFlight = true;
  const req = uuid();
  const entry = { kind: 'pageContext', raw, t: Date.now(), comp, href: location.href, sid: domId(), timer: 0 };
  entry.timer = setTimeout(() => {
    if (pending[req] !== entry) return;
    delete pending[req];
    pageContextInFlight = false;
    pcStage += 'o';
    post({ t: 'refused', req: uuid(), via, reason: 'pagecontext-timeout' });
  }, IMAGE_PAGE_KINDS.has(CFG.kind) ? 75000 : 15000);
  pending[req] = entry;
  pcStage += post({ t: 'pageContext', req, via, raw: String(raw).slice(0, 10001), att: !!ak, ak, gen }) ? 'p' : 'x';
}
function pageContextGuard(e, via, comp, raw) {
  const v = pageContextVerdict(comp, raw, via);
  lastKey = via.charAt(0) + (v ? v.charAt(0) : (String(raw).trim().startsWith('/') && slashMenuOpen(comp) ? 'm' : 'n'));
  if (v === 'swallow') { e.preventDefault(); e.stopImmediatePropagation(); }
  else if (v === 'intercept') interceptPageContext(e, via, comp, raw);
}
function onKey(e) {
  if (!alive || !e.isTrusted || e.key !== 'Enter' || e.shiftKey || e.altKey || e.ctrlKey || e.metaKey || e.isComposing || e.keyCode === 229 || e.repeat) return;
  const host = e.target && e.target.closest ? e.target.closest(EDITABLE) : null;
  if (!host) { lastKey = 'nh'; return; }
  const raw = textOf(host);
  const c = composerInfo();
  if (isTrigger(raw)) {
    lastKey = 'tr';
    if (!c.el) { refuseAmbiguous(e, 'enter', c, (x) => x === host || x.contains(host) || host.contains(x)); return; }
    if (!(c.el === host || c.el.contains(host) || host.contains(c.el))) return;
    intercept(e, 'enter', c.el, textOf(c.el));
    return;
  }
  // A slash page question in an unidentified composer must never reach the AI as a plain message: refuse with the code.
  const slash = String(raw).trim().startsWith('/');
  if (!c.el && SUPPORTED_PAGE_KINDS.has(CFG.kind) && slash) {
    e.preventDefault();
    e.stopImmediatePropagation();
    lastKey = 'sr';
    post({ t: 'refused', req: uuid(), via: 'enter', reason: c.reason });
    return;
  }
  if (!c.el || !(c.el === host || c.el.contains(host) || host.contains(c.el))) { lastKey = c.el ? 'nc' : slash ? 'sm' : 'cm'; return; }
  pageContextGuard(e, 'enter', c.el, textOf(c.el));
}
// The send-button twin of the Enter rule: a slash draft next to the clicked send button never reaches the AI as a plain
// message while its composer or send root is unidentified.
function refuseSlashClick(e, b, els, reason) {
  if (!SUPPORTED_PAGE_KINDS.has(CFG.kind)) return;
  const near = (x) => { for (let i = 0, p = x.parentElement; i < ROOT_DEPTH && p; i++, p = p.parentElement) if (p.contains(b)) return true; return false; };
  if (!els.some((x) => String(textOf(x)).trim().startsWith('/') && near(x))) return;
  e.preventDefault();
  e.stopImmediatePropagation();
  lastKey = 'cs';
  post({ t: 'refused', req: uuid(), via: 'click', reason: reason || 'composer-missing' });
}
function onClick(e) {
  if (!alive || !e.isTrusted || e.button !== 0) return;
  const b = e.target && e.target.closest ? e.target.closest('button, [role="button"]') : null;
  if (!b || !isSendLike(b)) return;
  const c = composerInfo();
  if (!c.el) {
    if (!refuseAmbiguous(e, 'click', c, (x) => { const r = chatRoot(x); return !!r && r.contains(b) && isTrigger(textOf(x)); })) {
      refuseSlashClick(e, b, q(EDITABLE).filter(visible), c.reason);
    }
    return;
  }
  const root = chatRoot(c.el);
  if (!root || !root.contains(b)) { if (!root) refuseSlashClick(e, b, [c.el], 'composer-missing'); return; }
  const raw = textOf(c.el);
  if (isTrigger(raw)) {
    intercept(e, 'click', c.el, raw);
    return;
  }
  pageContextGuard(e, 'click', c.el, raw);
}
// Genuine human input only (isTrusted). A composer that merely auto-focuses never sets this. Every trusted event
// advances touchGen (even when already touched) so an ack can tell new user activity from its own clear; only the first
// one posts the touch.
function onTouch(e) {
  if (!alive || !e.isTrusted) return;
  touchGen++;
  if (touched) return;
  touched = true;
  post({ t: 'touch' });
}
const ATTACH_PARTS = ['[data-testid*="attachment" i]', '[data-testid*="file-preview" i]', '[data-testid*="file-chip" i]', '[class*="attachment" i]', '[class*="file-preview" i]', '[class*="file-chip" i]', '[class*="uploaded" i]'];
const ATTACH_SEL = ATTACH_PARTS.join(', ');
// The attachment nodes the 'attach-node' clause counts. A class hit counts only from a plain class token: a compound
// utility token that merely mentions an attachment (Claude's has-[…]/group variants on its layout divs) names no card.
const ATTACH_CLASS_RE = /attachment|file-preview|file-chip|uploaded/i;
function attachNodes() {
  return q(ATTACH_SEL).filter((el) => visible(el) && !el.closest('button, [role="button"], nav, [role="navigation"]')
    && (ATTACH_PARTS.slice(0, 3).some((s) => el.matches(s)) || (el.getAttribute('class') || '').split(/\s+/).some((t) => /^[a-z0-9_-]+$/i.test(t) && ATTACH_CLASS_RE.test(t)))
    && ((el.textContent || '').trim() || el.querySelector('img, canvas, video')));
}
const ATTACH_REMOVE = /(?:remove|delete|제거|삭제).*(?:attach|file|upload|첨부|파일)|(?:attach|file|upload|첨부|파일).*(?:remove|delete|제거|삭제)/i;
// Which check saw an attachment ('' = none); fixed codes only, so a refusal names its exact clause.
function attachmentKind() {
  if (q('input[type="file"]').some((i) => i.files && i.files.length > 0)) return 'file-input';
  if (attachNodes().length) return 'attach-node';
  if (q('button, [role="button"]').some((b) => ATTACH_REMOVE.test(b.getAttribute('aria-label') || ''))) return 'remove-label';
  // A remove button named after a file inside the composer's own send root (Claude's "<file>.jpg 삭제").
  const c = composerInfo(), r = c.el ? chatRoot(c.el) : null;
  return r && q('button, [role="button"]', r).some((b) => { const l = b.getAttribute('aria-label') || ''; return visible(b) && IMG_REMOVE_RE.test(l) && FILE_NAME_RE.test(l); }) ? 'scope-remove' : '';
}
const FILE_NAME_RE = /\.[a-z0-9]{2,5}(?![a-z0-9])/i;
function hasAttachment() { return !!attachmentKind(); }
// Stage metadata for a manual capture refusal: fixed codes and counts only (never text, names, addresses or image data),
// so the composer / attachment stage of a page can be identified without reading it.
let lastKey = '-';
// Page-question stage of the latest intercept (fixed letters only): i intercepted, t check threw, p/x posted / post
// failed, s/u native submit for a known / unknown request, k/f submit sent / failed, c native cancel, o timed out.
let pcStage = '-';
function diagCode() {
  try {
    const n = (b) => (b ? 1 : 0);
    const out = ['k=' + lastKey, 'pc=' + pcStage.slice(-12), 'ed' + q('textarea, [contenteditable]:not([contenteditable="false"]), [role="textbox"]').filter(visible).length,
      'kn' + knownComposer().filter(visible).length, 'gn' + genericComposer().length,
      'lb' + q('[role="listbox"]').filter(visible).length, 'lo' + menuOptions(), 'dl' + q('[role="dialog"], dialog').filter(visible).length];
    const a = document.activeElement && document.activeElement.closest ? document.activeElement.closest(EDITABLE) : null;
    if (a) {
      let s = 0;
      for (let i = 0, p = a.parentElement; i < ROOT_DEPTH && p && p !== document.body && !s; i++, p = p.parentElement) s = sendCandidates(p).length;
      if (CFG.kind === 'meta') {
        // Depth of the first ancestor holding a shown button named 보내기, and which label source names it.
        let d = -1, src = '-';
        for (let i = 0, p = a.parentElement; i < 20 && p && d < 0; i++, p = p.parentElement) {
          const hit = q('button, [role="button"]', p).find((b) => visible(b) && accName(b) === '보내기');
          if (hit) {
            d = i;
            src = hit.getAttribute('aria-label') ? 'l' : hit.getAttribute('aria-labelledby') ? 'b' : hit.getAttribute('title') ? 't' : norm(hit.textContent) ? 'x' : 'g';
            src += hit.tagName === 'BUTTON' ? 'n' : 'r';
          }
        }
        out.push('sv' + d + src);
      }
      out.push('a=' + a.tagName.toLowerCase().replace(/[^a-z]/g, '').slice(0, 10), 'lx' + n(a.hasAttribute('data-lexical-editor')),
        'pm' + n(a.classList.contains('ProseMirror')), 'rt' + n(a.getAttribute('role') === 'textbox'), 'fm' + n(a.closest('form')),
        'cr' + n(chatRoot(a)), 'sd' + s, 'ex' + n(a.getAttribute('aria-expanded') === 'true'),
        'hx' + n(a.closest('[aria-hidden="true"], nav, header, dialog, [role="dialog"], [role="search"], [role="navigation"]')));
    }
    const fi = q('input[type="file"]');
    out.push('fi' + fi.length);
    for (const i of fi.slice(0, 4)) {
      const ac = i.accept || '';
      out.push('f:' + (ac ? '' : 'any') + (/image/i.test(ac) ? 'i' : '') + (/video/i.test(ac) ? 'v' : '') + (/pdf|text|doc/i.test(ac) ? 'd' : '')
        + (i.multiple ? 'm' : '') + (i.files && i.files.length ? 'f' + i.files.length : '') + (i.disabled ? 'x' : '') + (i.isConnected && visible(i) ? 'v' : ''));
    }
    const rm = q('button, [role="button"]').filter((b) => visible(b) && IMG_REMOVE_RE.test(b.getAttribute('aria-label') || ''));
    out.push('ak=' + (attachmentKind() || 'none'), 'rm' + rm.length);
    // The first counted attachment node: selector clause, tag, site testid / matching class token (markup names only),
    // image child, and whether it sits in the composer's send root.
    const an = attachNodes();
    if (an.length) {
      const el = an[0], cc = composerInfo(), r = cc.el ? chatRoot(cc.el) : null;
      const tok = (s) => (/^[a-z0-9_-]{1,40}$/i.test(s || '') ? s.toLowerCase() : '-');
      const cls = (el.getAttribute('class') || '').split(/\s+/).find((t) => /attachment|file-preview|file-chip|uploaded/i.test(t));
      out.push('an' + an.length, 'ap' + ATTACH_PARTS.findIndex((s) => el.matches(s)), 'at=' + el.tagName.toLowerCase().replace(/[^a-z0-9]/g, '').slice(0, 10),
        'ai=' + tok(el.getAttribute('data-testid')), 'ac=' + tok(cls), 'ag' + n(el.querySelector('img, canvas, video')), 'ar' + n(r && r.contains(el)));
    }
    if (rm.length) {
      let d = 0;
      for (let p = rm[0].parentElement; p && d < 6 && !p.querySelector('img'); p = p.parentElement) d++;
      out.push('ri' + d, 'rf' + n(rm[0].closest('form')));
    }
    if (CFG.kind === 'claude') {
      // Thumbnails in the document / Claude scope, and how the first one names its file (text, own label, own remove button).
      const cc = composerInfo(), sc = cc.el ? claudeScope(cc.el) : null, th = q(CLAUDE_THUMB).filter(visible);
      out.push('ct' + th.length, 'cs' + n(sc), 'ci' + (sc ? claudeThumbs(sc).length : 0));
      if (th.length) out.push('cn' + n(FILE_NAME_RE.test(th[0].textContent || '')), 'ca' + n(FILE_NAME_RE.test(th[0].getAttribute('aria-label') || '')),
        'cb' + n(q('button, [role="button"]', th[0]).some((b) => FILE_NAME_RE.test(b.getAttribute('aria-label') || ''))));
      const rb = q('button, [role="button"]').find((b) => visible(b) && IMG_REMOVE_RE.test(b.getAttribute('aria-label') || '') && FILE_NAME_RE.test(b.getAttribute('aria-label') || ''));
      if (rb) out.push('rh' + n(rb.closest(CLAUDE_THUMB)), 'rs' + n(sc && sc.root.contains(rb)));
    }
    const route = IMG_ROUTE[CFG.kind], c = composerInfo();
    if (route && c.el) { const sc = imgScope(c.el); out.push('sc' + n(sc)); if (sc) out.push('it' + route.items(sc.root).length, 'in' + route.inputs().length); }
    return out.join(';').slice(0, 400);
  } catch (e) { return 'err'; }
}
function onBlur(e) {
  if (!alive || !e.isTrusted) return;
  const t = e.target;
  if (t && t.closest && t.closest(EDITABLE)) post({ t: 'life', k: 'inputBlur' });
}

// ---- composer writes ---------------------------------------------------------------------------------------
function setFieldValue(el, v) {
  const proto = el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
  Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, v);
  el.dispatchEvent(new Event('input', { bubbles: true }));
}
function quillParagraphs(text) {
  return String(text).split(/\r\n|\r|\n/).map((line) => {
    const paragraph = document.createElement('p');
    if (line) paragraph.textContent = line;
    else paragraph.appendChild(document.createElement('br'));
    return paragraph;
  });
}
function isQuillEditor(el) {
  return !!(el && el.isContentEditable && el.classList && el.classList.contains('ql-editor'));
}
// Gemini's composer is Quill: type with the native editing command inside the editor only, rebuild Quill paragraphs
// through DOM APIs (no HTML string sink) only when the normalized contents differ, and always finish with a change
// event. Success requires the complete normalized payload to match.
function writeQuillEditor(el, text) {
  el.focus();
  const selection = window.getSelection();
  const range = document.createRange();
  range.selectNodeContents(el);
  selection.removeAllRanges();
  selection.addRange(range);
  let typed = false;
  try { typed = document.execCommand('insertText', false, text); } catch (e) { typed = false; }
  if (!typed || norm(textOf(el)) !== norm(text)) {
    el.replaceChildren(...quillParagraphs(text));
  }
  if (norm(textOf(el)) !== norm(text)) return false;
  el.dispatchEvent(new InputEvent('input', { bubbles: true, composed: true, inputType: 'insertText', data: text }));
  el.dispatchEvent(new Event('change', { bubbles: true, composed: true }));
  return true;
}
function isLexicalEditor(el) {
  if (el && CFG.kind === 'meta') return el.matches('div[data-lexical-editor="true"][role="textbox"][contenteditable="true"]');
  return !!(el && CFG.kind === 'perplexity' && el.matches('.composer-editable[data-lexical-editor="true"][role="textbox"][contenteditable="true"]'));
}
// Perplexity's composer is Lexical: exactly one native insertText of the normalized single-line payload into the
// editor's own contents (a multi-line insertText loses its newlines). The native input already commits Lexical's model,
// so no extra input or change events are dispatched (an explicit InputEvent duplicates the payload). Lexical may apply
// the edit after execCommand has already returned (even false), so the complete normalized payload is awaited once with
// the finite mutation-driven observe. There is no paste, DOM rebuild or second insert on a mismatch. The result is
// rejected if proof or touch generation changes.
async function writeLexicalEditor(el, text, still, exact) {
  el.focus();
  const selection = window.getSelection();
  const range = document.createRange();
  range.selectNodeContents(el);
  selection.removeAllRanges();
  selection.addRange(range);
  try { document.execCommand('insertText', false, exact ? String(text) : norm(text)); } catch (e) { /* the editor content is verified below */ }
  const gen = touchGen;
  const live = () => alive && el.isConnected && touchGen === gen && (!still || still());
  const matches = () => live() && norm(textOf(el)) === norm(text);
  const hit = await observe(() => (matches() ? 'match' : null), 1500);
  if (!!hit && matches()) return true;
  // A raw restore tries the exact text (spaces, line breaks) first; the normalized write stays the fallback.
  return exact && live() ? writeLexicalEditor(el, text, still, false) : false;
}
// Generic path only, for the write-failure bits: whether insertText reported success and whether the paste fallback ran.
let genericWrite = { typed: false, pasted: false };
async function writeComposer(el, text, still, exact) {
  genericWrite = { typed: false, pasted: false };
  if (isField(el)) { setFieldValue(el, text); return textOf(el) === text; }
  if (CFG.kind === 'gemini' && isQuillEditor(el)) return writeQuillEditor(el, text);
  if (isLexicalEditor(el)) return writeLexicalEditor(el, text, still, exact);
  el.focus();
  document.execCommand('selectAll', false, null);
  let ok = false;
  try { ok = document.execCommand('insertText', false, text); } catch (e) { ok = false; }
  genericWrite.typed = ok;
  // The M365 editor adds a paste after its content instead of replacing it (observed: insertText's prompt plus the
  // pasted one), so a paste can never make an exact match there: the full match is awaited once, with no paste.
  if (isM365Editor(el)) {
    if (norm(textOf(el)) === norm(text)) return true;
    const gen = touchGen;
    const live = () => alive && el.isConnected && touchGen === gen && (!still || still());
    const hit = await observe(() => (!live() ? 'gone' : norm(textOf(el)) === norm(text) ? 'match' : null), 1500);
    return hit === 'match' && live();
  }
  if (!ok || norm(textOf(el)) !== norm(text)) {
    genericWrite.pasted = true;
    try {
      const dt = new DataTransfer();
      dt.setData('text/plain', text);
      document.execCommand('selectAll', false, null);
      el.dispatchEvent(new ClipboardEvent('paste', { clipboardData: dt, bubbles: true, cancelable: true }));
    } catch (e) { /* verified below */ }
  }
  return norm(textOf(el)) === norm(text);
}
function clearComposer(el) {
  if (isField(el)) { setFieldValue(el, ''); return; }
  el.focus();
  document.execCommand('selectAll', false, null);
  document.execCommand('delete', false, null);
}
// Rolls back a prefill only when the composer still holds exactly the text we wrote.
function clearIfOurs(el, text) {
  if (el.isConnected && norm(textOf(el)) === norm(text)) { clearComposer(el); return true; }
  return false;
}

// ---- bounded, mutation driven waits (one finite timeout each, no polling) ----------------------------------
function observe(pred, ms, quiet) {
  return new Promise((resolve) => {
    let done = false, mo = null, to = null, qt = null;
    const finish = (v) => {
      if (done) return;
      done = true;
      if (mo) mo.disconnect();
      clearTimeout(to);
      clearTimeout(qt);
      resolve(v);
    };
    const evaluate = () => { try { return pred(); } catch (e) { return null; } };
    const check = () => {
      if (done) return;
      const v = evaluate();
      if (qt) { clearTimeout(qt); qt = null; }
      if (!v) return;
      if (!quiet || v === 'found') { finish(v); return; }
      qt = setTimeout(() => finish(evaluate()), quiet);
    };
    mo = new MutationObserver(check);
    mo.observe(document.documentElement, { childList: true, subtree: true, characterData: true, attributes: true });
    to = setTimeout(() => finish(null), ms);
    check();
  });
}

function gate(docID, url, sid) {
  if (!alive) return 'retired';
  if (docID !== DOC) return 'stale-document';
  if (!CFG.origins.includes(location.origin)) return 'origin-changed';
  if (url && String(location.href).split('#')[0] !== String(url).split('#')[0]) return 'url-changed';
  if (sid && domId() !== sid) return 'thread-changed';
  return null;
}
function preflight() {
  const c = CFG.kind === 'hana' ? hanaComposer() : composerInfo();
  if (!c.el) return { reason: c.reason };
  const r = rowsInfo(c.el);
  if (!r.ok) return { reason: r.reason };
  if (norm(textOf(c.el))) return { reason: 'draft-not-empty' };
  const a = document.activeElement;
  // Focus alone (provider autofocus, a retained hidden composer) is not editing; focus plus genuine trusted input is.
  if (touched && a && (a === c.el || c.el.contains(a))) return { reason: 'composer-focused' };
  if (generating()) return { reason: 'generating' };
  // An interactive DOM is enough to send; a provider iframe may hold the window load open indefinitely.
  if (document.readyState === 'loading') return { reason: 'loading' };
  return { ok: true, comp: c.el };
}

// ---- lifecycle wake-ups ------------------------------------------------------------------------------------
// rows|composer present (0/1, structure only, never its text)|generating (last bit: endsWith('|1') / '|0' means generating).
function lifeSig() {
  try {
    const r = rawRows();
    const c = CFG.kind === 'hana' ? hanaComposer() : composerInfo();
    return (r.list ? r.list.length : 0) + '|' + (c.el ? 1 : 0) + '|' + (generating() ? 1 : 0);
  } catch (e) { return ''; }
}
function startWatch() {
  if (!alive) return;
  sig = lifeSig();
  // A single-page address change (new chat, other conversation) is reported so browser mode can follow its conversation.
  let lastHref = location.href;
  new MutationObserver(() => {
    if (!alive || location.href === lastHref) return;
    lastHref = location.href;
    post({ t: 'nav' });
  }).observe(document.documentElement, { childList: true, subtree: true });
  new MutationObserver(() => {
    if (!alive || !watch) return;
    const s = lifeSig();
    if (s === sig) return;
    const wasGenerating = sig.endsWith('|1');
    sig = s;
    post({ t: 'life', k: wasGenerating && s.endsWith('|0') ? 'idle' : 'rows' });
  }).observe(document.documentElement, { childList: true, subtree: true });
  // The DOM is ready (the window load may still be held by a provider iframe): wake the outbox once, metadata only.
  post({ t: 'life', k: 'ready' });
}

// ---- native entry points -----------------------------------------------------------------------------------
window.__afPlanner = {
  setPageMode(on) { PAGE_MODE = on === true; return { ok: true }; },
  retire() { alive = false; pageContextInFlight = false; PAGE_MODE = false; for (const k of Object.keys(pending)) { clearTimeout(pending[k].timer); delete pending[k]; } return true; },
  setWatch(on) { watch = !!on; sig = lifeSig(); return { ok: true }; },
  probe(docID) {
    const g = gate(docID);
    if (g) return { ok: false, reason: g };
    const c = composerInfo();
    if (!c.el) return { ok: false, reason: c.reason };
    const r = rowsInfo(c.el);
    if (!r.ok) return { ok: false, reason: r.reason };
    return { ok: true, src: r.src, u: location.href, s: domId() };
  },
  capture(docID) {
    const g = gate(docID);
    if (g) return { ok: false, reason: g };
    const r = captureNow();
    if (!r.ok) r.diag = diagCode();
    return r;
  },
  // Positive proof of a fresh, idle, empty home page (read only; nothing is focused, written or clicked).
  restoreState(docID) {
    const g = gate(docID);
    if (g) return { ok: false, reason: g };
    if (touched) return { ok: false, reason: 'user-active' };
    if (document.readyState !== 'complete') return { ok: false, reason: 'loading' };
    const c = composerInfo();
    if (!c.el) return { ok: false, reason: c.reason };
    if (norm(textOf(c.el))) return { ok: false, reason: 'draft-not-empty' };
    if (generating()) return { ok: false, reason: 'generating' };
    if (hasAttachment()) return { ok: false, reason: 'attachment-present' };
    if (domId()) return { ok: false, reason: 'conversation-open' };
    const raw = rawRows();
    if (!raw.list) return { ok: false, reason: 'no-conversation-scope' };
    const shown = raw.list.some((x) => x.el.isConnected && !x.el.contains(c.el) && !c.el.contains(x.el) && (x.el.textContent || '').trim());
    if (shown) return { ok: false, reason: 'conversation-open' };
    if (touched) return { ok: false, reason: 'user-active' };
    return { ok: true };
  },
  async ack(docID, req, accepted) {
    if (docID !== DOC) return { ok: false, reason: 'stale-document' };
    const p = pending[req];
    if (!p) return { ok: false, reason: 'unknown-request' };
    delete pending[req];
    if (!accepted) return { ok: true, cleared: false };
    const c = composerInfo();
    if (!c.el) return { ok: true, cleared: false, reason: 'composer-missing' };
    // Same conversation view proof: any stale, changed or missing piece means nothing is cleared.
    const now = rowsInfo(c.el);
    const firstNow = now.ok ? now.rows.find((x) => x.role === 'user') : null;
    if (c.el !== p.comp || !p.comp.isConnected || String(location.href) !== p.href
        || !p.user || !p.user.isConnected || !firstNow || firstNow.el !== p.user
        || (p.sid != null && domId() !== p.sid)) return { ok: true, cleared: false, changed: true };
    if (textOf(c.el) !== p.raw) return { ok: true, cleared: false, changed: true };
    try { clearComposer(c.el); } catch (e) { /* verified below */ }
    // The clear runs once. Rich editors (Lexical) apply it asynchronously, so the empty composer is awaited with the
    // mutation-driven observe. Trusted activity is counted from right after the clear (its own events are not new input).
    const gen = touchGen;
    const sameView = () => {
      if (!alive || docID !== DOC) return false;
      const cn = composerInfo();
      if (!cn.el || cn.el !== p.comp || !p.comp.isConnected || String(location.href) !== p.href || !p.user || !p.user.isConnected) return false;
      const rn = rowsInfo(cn.el);
      const fu = rn.ok ? rn.rows.find((x) => x.role === 'user') : null;
      return !!fu && fu.el === p.user && (p.sid == null || domId() === p.sid);
    };
    const state = () => {
      if (!sameView() || touchGen !== gen) return 'stale';
      const t = textOf(p.comp);
      if (!norm(t)) return 'empty';
      return t !== p.raw ? 'changed' : null;
    };
    let st = state() || await observe(state, 1500);
    // Whatever the wait reported, the proof is re-checked after it before anything is claimed.
    if (!st || st === 'empty') st = state();
    if (st === 'stale' || st === 'changed') return { ok: true, cleared: false, changed: true };
    // Success is claimed only when the composer is observably empty with the whole proof current; otherwise the draft
    // state stays as it is and the input stays marked as touched.
    if (st !== 'empty') return { ok: true, cleared: false, reason: 'clear-failed' };
    // Exactly the original command was removed and verified: the next genuine trusted input must mark it again.
    touched = false;
    return { ok: true, cleared: true };
  },
  prepare(docID, url, sid, marker) {
    const g = gate(docID, url, sid);
    if (g) return ns(g);
    const pre = preflight();
    if (!pre.ok) return ns(pre.reason);
    if (markerPresent(marker) === true) return { state: 'delivered', reason: 'already-present' };
    return { state: 'ready' };
  },
  async awaitMarker(docID, url, sid, marker, ms) {
    const g = gate(docID, url, sid);
    if (g) return { state: 'uncertain', reason: g };
    const found = await observe(() => (markerPresent(marker) === true ? 'found' : null), clamp(ms));
    return found ? { state: 'delivered' } : { state: 'uncertain', reason: 'marker-not-observed' };
  },
  async send(docID, url, sid, text, marker, ms) {
    const g = gate(docID, url, sid);
    if (g) return ns(g);
    const pre = preflight();
    if (!pre.ok) return ns(pre.reason);
    if (markerPresent(marker) === true) return { state: 'delivered', reason: 'already-present' };
    const comp = pre.comp, prev = document.activeElement;
    const restore = () => {
      try {
        if (prev && prev.isConnected && prev !== comp && prev !== document.body) prev.focus(); else comp.blur();
      } catch (e) { /* focus restore is best effort */ }
    };
    // The write may finish asynchronously (Lexical). Trusted input is counted from right after the synchronous part of
    // the write (its own native events are not new input); the whole proof is re-checked after the await.
    const wrote = writeComposer(comp, text, () => !gate(docID, url, sid) && composerInfo().el === comp);
    const gen = touchGen;
    const ok = await wrote;
    const drift = gate(docID, url, sid) || (!comp.isConnected || composerInfo().el !== comp ? 'composer-changed' : null)
      || (touchGen !== gen ? 'user-active' : null);
    if (drift) {
      // Anything written, typed or left over is not ours to touch any more: no rollback, no send.
      return ns(drift);
    }
    if (!ok) { clearIfOurs(comp, text); restore(); return ns('composer-write-failed'); }
    const btn = await observe(() => {
      const c = composerInfo();
      if (c.el !== comp || norm(textOf(comp)) !== norm(text)) return null;
      const b = sendButton(comp);
      return b && isEnabled(b) ? b : null;
    }, 1500);
    const again = gate(docID, url, sid);
    const moved = touchGen !== gen;
    if (!btn || again || moved || generating()) {
      if (!again && !moved && comp.isConnected && composerInfo().el === comp) { clearIfOurs(comp, text); restore(); }
      return ns(again || (moved ? 'user-active' : (generating() ? 'generating' : 'send-button-not-ready')));
    }
    btn.click();
    const found = await observe(() => (markerPresent(marker) === true ? 'found' : null), clamp(ms));
    restore();
    return found ? { state: 'delivered' } : { state: 'uncertain', reason: 'marker-not-observed' };
  },
  async verify(docID, url, sid, marker, ms) {
    const g = gate(docID, url, sid);
    if (g) return { state: 'unknown', reason: g };
    if (markerPresent(marker) === true) return { state: 'delivered' };
    const v = await observe(() => {
      const m = markerPresent(marker);
      if (m === true) return 'found';
      if (m === null || document.readyState !== 'complete' || generating()) return null;
      return 'absent';
    }, clamp(ms), 1200);
    if (v === 'found') return { state: 'delivered' };
    if (v !== 'absent') return { state: 'unknown', reason: 'not-settled' };
    // A missing marker never proves absence on any provider: markerPresent only inspects the newest user rows and no
    // page offers a positive proof that the whole thread was scanned (Hana included), so the entry stays unconfirmed.
    const g2 = gate(docID, url, sid);
    if (g2) return { state: 'unknown', reason: g2 };
    return { state: 'unknown', reason: 'completeness-unproven' };
  },
  async submitPageContextPrompt(docID, req, promptText, imageB64) {
    if (docID !== DOC) return { ok: false, reason: 'stale-document' };
    const p = pending[req];
    if (!p || p.kind !== 'pageContext') { pcStage += 'u'; return { ok: false, reason: 'unknown-request' }; }
    clearTimeout(p.timer);
    delete pending[req];
    pcStage += 's';
    // Stays in flight until the send click: a second Enter meanwhile is swallowed, never sent as a plain message.
    try {
      const r = await submitPageContextNow(docID, p, promptText, typeof imageB64 === 'string' && imageB64 ? imageB64 : null);
      pcStage += r && r.ok ? 'k' : 'f';
      return r;
    } finally {
      pageContextInFlight = false;
    }
  },
  // Clears the composer only while it still holds exactly the control input ("//"); newer typing is never touched.
  consumePageContext(docID, req) {
    if (docID !== DOC) return { ok: false, reason: 'stale-document' };
    const p = pending[req];
    if (!p || p.kind !== 'pageContext') return { ok: false, reason: 'unknown-request' };
    clearTimeout(p.timer);
    delete pending[req];
    pageContextInFlight = false;
    const c = composerInfo();
    if (!c.el || c.el !== p.comp || !p.comp.isConnected || String(location.href) !== p.href) return { ok: false, reason: 'composer-changed' };
    if (norm(textOf(c.el)) !== norm(p.raw)) return { ok: false, reason: 'user-active' };
    clearComposer(c.el);
    return { ok: true };
  },
  cancelPageContext(docID, req) {
    if (docID !== DOC) return { ok: false };
    pcStage += 'c';
    const p = pending[req];
    if (p && p.kind === 'pageContext') {
      clearTimeout(p.timer);
      delete pending[req];
      pageContextInFlight = false;
    }
    return { ok: true };
  }
};
// Claude composer attachments (verified live): thumbnails are [data-testid="file-thumbnail"] and may sit outside the
// editor's parent. The scope is the nearest bounded ancestor holding this exact editor and exactly one semantic send
// button, never one that also holds conversation history.
const CLAUDE_SEND = 'button[data-testid="chat-input-send"]';
const CLAUDE_THUMB = '[data-testid="file-thumbnail"]';
function claudeScope(comp) {
  let el = comp.parentElement;
  for (let i = 0; i < 10 && el && el !== document.body && el !== document.documentElement; i++, el = el.parentElement) {
    if (el.matches('main, [role="main"], [role="log"]') || el.querySelector('[data-testid="user-message"], [data-testid*="conversation-turn" i], [data-is-streaming]')) return null;
    const sends = q(CLAUDE_SEND, el).filter(visible);
    if (sends.length === 1) return { root: el, send: sends[0] };
    if (sends.length > 1) return null;
  }
  return null;
}
function claudeThumbs(scope) { return q(CLAUDE_THUMB, scope.root).filter(visible); }
// The dock's Claude thumbnail may carry our file name only in its own label or its own named remove button.
function claudeNamed(t, name) {
  return (t.textContent || '').includes(name) || imgNameMatches(t.getAttribute('aria-label') || '', name)
    || q('button, [role="button"]', t).some((b) => imgNameMatches(b.getAttribute('aria-label') || '', name));
}
function claudeThumbFailed(t) {
  const st = (t.getAttribute('data-state') || '').toLowerCase();
  return st === 'error' || st === 'failed' || t.getAttribute('aria-invalid') === 'true'
    || /업로드.{0,8}(?:실패|오류)|upload.{0,12}(?:fail|error)|failed to upload/i.test(t.textContent || '');
}
function claudeThumbReady(t) {
  if (t.getAttribute('aria-busy') === 'true' || t.getAttribute('data-state') === 'pending' || claudeThumbFailed(t)) return false;
  const img = t.querySelector('img');
  return !!img && img.complete && img.naturalWidth > 0;
}
// Removes only the thumbnail node this call created, and only while it is still the single attachment in scope.
function claudeCleanup(own) {
  try {
    if (!own || !own.thumb || !own.thumb.isConnected) return;
    const scope = claudeScope(own.comp);
    if (!scope || claudeThumbs(scope).length !== 1 || claudeThumbs(scope)[0] !== own.thumb) return;
    const dels = q('button', own.thumb).filter((b) => /삭제|제거|remove|delete/i.test(b.getAttribute('aria-label') || ''));
    if (dels.length === 1) dels[0].click();
  } catch (e) {}
}
// Attaches the masked page image and waits for a verified finished upload. Returns { ok, own } or { reason, own }.
async function attachClaudeImage(docID, p, comp, b64) {
  const scope = claudeScope(comp);
  if (!scope) return { reason: 'attach-scope-unsafe' };
  if (claudeThumbs(scope).length || q('input[type="file"]').some((i) => i.files && i.files.length)) return { reason: 'attachment-present' };
  const inputs = q('input[type="file"][data-testid="file-upload"]');
  if (inputs.length !== 1 || inputs[0].disabled) return { reason: 'file-input-unavailable' };
  let file;
  try {
    const bin = atob(b64);
    const bytes = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
    file = new File([bytes], 'hantool-page-' + uuid().slice(0, 8) + '.jpg', { type: 'image/jpeg' });
  } catch (e) { return { reason: 'image-invalid' }; }
  const own = { comp, file, thumb: null };
  const input = inputs[0];
  try {
    const dt = new DataTransfer();
    dt.items.add(file);
    input.files = dt.files;
    input.dispatchEvent(new Event('change', { bubbles: true }));
  } catch (e) { return { reason: 'attach-failed', own }; }
  const appeared = await observe(() => {
    if (gate(docID) || !comp.isConnected) return 'gone';
    const list = claudeThumbs(scope);
    const hit = list.filter((t) => claudeNamed(t, file.name));
    return list.length === 1 && hit.length === 1 ? hit[0] : (list.length > 1 ? 'gone' : null);
  }, 8000);
  if (!appeared || appeared === 'gone') {
    if (appeared === 'gone' && input.files && input.files.length === 1 && input.files[0] === file) input.value = '';
    return { reason: appeared ? 'attach-ambiguous' : 'attach-not-shown', own };
  }
  own.thumb = appeared;
  const ready = await observe(() => {
    if (gate(docID) || !comp.isConnected || !own.thumb.isConnected) return 'gone';
    const list = claudeThumbs(scope);
    if (list.length !== 1 || list[0] !== own.thumb) return 'gone';
    if (claudeThumbFailed(own.thumb)) return 'failed';
    return claudeThumbReady(own.thumb) && isEnabled(scope.send) ? 'ready' : null;
  }, 30000);
  if (ready !== 'ready') return { reason: ready === 'failed' ? 'upload-failed' : (ready ? 'attach-changed' : 'upload-timeout'), own };
  return { ok: true, own, scope };
}
// ChatGPT / Gemini / Perplexity composer attachments (verified live on the current apps, selectors are exact and
// semantic, never class-prefix guesses). The scope is the widest bounded ancestor of this exact editor holding exactly one
// send candidate and no conversation history, so the attachment tray is found even when it is not the editor's parent.
const IMG_HISTORY = '[data-testid="user-message"], [data-testid*="conversation-turn" i], [data-is-streaming], [data-message-author-role], user-query, model-response, [data-message-bubble], [data-renderer="lm"]';
const IMG_BUSY_RE = /업로드 중|로드 중|uploading|loading/i;
const IMG_FAIL_RE = /업로드.{0,8}(?:실패|오류)|upload.{0,12}(?:fail|error)|failed to upload/i;
const IMG_REMOVE_RE = /삭제|제거|remove|delete/i;
const IMG_ROUTE = {
  chatgpt: {
    inputs: () => q('input[type="file"]').filter((i) => i.accept === 'image/*' && i.multiple),
    items: (r) => q('.composer-attachment-surface[role="button"]', r).filter(visible),
    name: (it) => it.getAttribute('aria-label') || '',
    img: (it) => it.querySelector('img')
  },
  gemini: {
    open: (r) => { const l = q('button', r).filter((b) => visible(b) && (b.getAttribute('aria-label') || '').includes('업로드 및 도구')); return l.length === 1 ? l[0] : null; },
    inputs: () => q('input[type="file"]').filter((i) => /image\//i.test(i.accept) && /video\//i.test(i.accept) && i.multiple),
    items: (r) => q('.mat-mdc-chip', r).filter((c) => visible(c) && c.querySelector('img.gem-attachment-style-img')),
    name: null,
    img: (it) => it.querySelector('img.gem-attachment-style-img')
  },
  perplexity: {
    inputs: () => q('input[type="file"]').filter((i) => /image\/|\.jpe?g|\.png/i.test(i.accept) && i.multiple),
    items: (r) => q('button[aria-label$="미리보기"]', r).filter(visible),
    name: (it) => (it.getAttribute('aria-label') || '').replace(/\s*미리보기$/, ''),
    img: (it) => it.querySelector('img')
  },
  // Grok: one always-mounted file input; each attachment is a role=listitem whose text is the file name and whose own
  // remove button carries no name.
  grok: {
    inputs: () => q('input[type="file"]').filter((i) => !i.accept && i.multiple),
    items: (r) => q('[role="listitem"]', r).filter((it) => visible(it) && it.querySelector('button[aria-label="이 첨부파일 제거"]')),
    name: (it) => it.textContent || '',
    nameOptional: true,
    img: (it) => it.querySelector('img'),
    remove: (it) => q('button[aria-label="이 첨부파일 제거"]', it)
  },
  // Copilot: the attach button mounts the single image input; each attachment is .fx-Attachment, named only by its
  // remove button's aria-label.
  copilot: {
    open: (r) => { const l = q('button[data-testid="chat-input-attach-button"][aria-label="추가"]', r).filter(visible); return l.length === 1 ? l[0] : null; },
    inputs: () => q('input[type="file"][id="upload-file-button"]').filter((i) => i.multiple && /image\//i.test(i.accept)),
    items: (r) => q('.fx-Attachment', r).filter((it) => visible(it) && it.querySelector('button.fx-Attachment__dismissButton')),
    name: (it) => { const b = it.querySelector('button.fx-Attachment__dismissButton'); return b ? (b.getAttribute('aria-label') || '').replace(/^첨부 파일 제거\s*/, '') : ''; },
    img: (it) => it.querySelector('img')
  },
  // Meta AI: one always-mounted hidden file input; each attachment is the nearest box holding one img (alt = file name)
  // and its own "Remove image" button, shown inside the Lexical editor itself.
  meta: {
    inputs: () => q('input[type="file"]').filter((i) => i.multiple && /image\//i.test(i.accept)),
    items: (r) => q('button[aria-label="Remove image"]', r).filter(visible).map(metaItem).filter(Boolean),
    name: (it) => { const im = it.querySelector('img'); return im ? im.getAttribute('alt') || '' : ''; },
    img: (it) => it.querySelector('img'),
    remove: (it) => q('button[aria-label="Remove image"]', it)
  }
};
function metaItem(b) {
  let el = b.parentElement;
  for (let i = 0; i < 3 && el; i++, el = el.parentElement) {
    if (el.querySelector('img')) return q('img', el).length === 1 && q('button[aria-label="Remove image"]', el).length === 1 ? el : null;
  }
  return null;
}
function imgScope(comp) {
  let good = null, el = comp.parentElement;
  for (let i = 0; i < (CFG.kind === 'meta' ? ROOT_DEPTH : 10) && el && el !== document.body && el !== document.documentElement; i++, el = el.parentElement) {
    if (el.matches('main, [role="main"], [role="log"]') || el.querySelector(IMG_HISTORY)) break;
    const sends = sendCandidates(el);
    if (sends.length > 1) break;
    if (sends.length === 1) good = { root: el };
  }
  return good;
}
function imgSend(scope) {
  const l = sendCandidates(scope.root);
  return l.length === 1 ? l[0] : null;
}
// The site may shorten a long file name with an ellipsis; a shortened label still has to start and end like our name.
function imgNameMatches(label, name) {
  const l = norm(label);
  if (!l) return false;
  if (l.includes(name)) return true;
  const parts = l.split(/…|\.\.\./);
  return parts.length === 2 && parts[0].length >= 1 && parts[1].length >= 3 && name.startsWith(parts[0]) && name.endsWith(parts[1]);
}
// The single attachment in scope that is ours: by file name where the site shows one, else the only one (the scope held
// none before the attach).
function imgFind(route, scope, file) {
  const list = route.items(scope.root);
  if (list.length !== 1) return list.length ? 'many' : null;
  const fresh = file.injected && file.base && !file.base.has(list[0]);
  if (!route.name) return fresh ? list[0] : 'many';
  if (imgNameMatches(route.name(list[0]), file.name)) return list[0];
  // Grok's narrow dock layout shows no file name in the item: the single new item after our own injected file counts as
  // ours only while it names no file at all (an item naming another file is never ours).
  return route.nameOptional && fresh && !FILE_NAME_RE.test(norm(route.name(list[0]))) ? list[0] : 'many';
}
function imgOwned(own, scope) {
  const it = imgFind(own.route, scope, own.file);
  if (!it || it === 'many') return false;
  own.item = it;
  return imgReady(own, scope);
}
function imgFailed(own, scope) {
  return IMG_FAIL_RE.test(own.item.textContent || '') || q('[role="alert"]', scope.root).some((a) => visible(a) && IMG_FAIL_RE.test(a.textContent || ''));
}
// Finished: loaded thumbnail, no busy attribute, and none of the scope's own progress indicators still shown.
// '' when finished, else the fixed code of the first unmet condition (reported with an upload timeout).
function imgPending(own, scope) {
  const img = own.route.img(own.item);
  if (!img) return 'img-none';
  // Load stage: thumbnail source scheme (blob / data / https / none) and whether the element still loads or finished empty.
  if (!img.complete || !(img.naturalWidth > 0)) {
    const sch = (img.currentSrc || img.getAttribute('src') || '').slice(0, 6).toLowerCase();
    return 'img-' + (sch.startsWith('blob:') ? 'b' : sch.startsWith('data:') ? 'd' : sch.startsWith('https:') ? 'h' : sch ? 'o' : 'n') + (img.complete ? 'z' : 'w');
  }
  if (own.item.getAttribute('aria-busy') === 'true' || own.item.querySelector('[aria-busy="true"]')) return 'busy';
  if (q('[role="progressbar"]', scope.root).some((b) => visible(b) && (own.item.contains(b) || IMG_BUSY_RE.test(b.getAttribute('aria-label') || '') || (own.route.name && imgNameMatches(b.getAttribute('aria-label') || '', own.file.name))))) return 'progress';
  return imgFailed(own, scope) ? 'failed' : '';
}
function imgReady(own, scope) { return !imgPending(own, scope); }
// Removes only the attachment this call created, and only while it is still the single attachment in scope. The remove
// button must be named after our file (or, where the site shows no name, sit inside our own item).
function imageCleanup(own) {
  try {
    if (!own) return;
    if (!own.route) { claudeCleanup(own); return; }
    if (!own.item || !own.item.isConnected) return;
    const scope = imgScope(own.comp);
    if (!scope || imgFind(own.route, scope, own.file) !== own.item) return;
    // Where the site shows no file name the item must also still carry the thumbnail source seen when it became ready.
    if (!own.route.name || !imgNameMatches(own.route.name(own.item), own.file.name)) { const im = own.route.img(own.item); if (!own.src || !im || im.src !== own.src) return; }
    const dels = own.route.remove ? own.route.remove(own.item)
      : q('button', own.route.name ? scope.root : own.item).filter((b) => IMG_REMOVE_RE.test(b.getAttribute('aria-label') || '')
        && (own.route.name ? imgNameMatches(b.getAttribute('aria-label') || '', own.file.name) : own.item.contains(b)));
    if (dels.length === 1) dels[0].click();
  } catch (e) {}
}
// Attaches the masked page image and waits for a verified finished upload. Returns { ok, own, scope } or { reason, own }.
async function attachPageImage(docID, p, comp, b64) {
  const route = IMG_ROUTE[CFG.kind];
  const scope = route && imgScope(comp);
  if (!scope) return { reason: 'attach-scope-unsafe' };
  if (route.items(scope.root).length || q('input[type="file"]').some((i) => i.files && i.files.length)) return { reason: 'attachment-present' };
  let file;
  try {
    const bin = atob(b64);
    const bytes = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
    file = new File([bytes], 'hp-' + uuid().slice(0, 8) + '.jpg', { type: 'image/jpeg' });
  } catch (e) { return { reason: 'image-invalid' }; }
  const own = { comp, file, route, item: null };
  let opener = null;
  try {
    let inputs = route.inputs();
    if (!inputs.length && route.open) {
      // Gemini mounts its file inputs only while the upload menu is open.
      opener = route.open(scope.root);
      if (!opener) return { reason: 'file-input-unavailable' };
      opener.click();
      inputs = (await observe(() => { const l = route.inputs(); return l.length ? l : null; }, 3000)) || [];
    }
    if (inputs.length !== 1 || inputs[0].disabled) return { reason: 'file-input-unavailable' };
    const input = inputs[0];
    try {
      const dt = new DataTransfer();
      dt.items.add(file);
      file.base = new Set(route.items(scope.root));
      input.files = dt.files;
      file.injected = input.files.length === 1 && input.files[0] === file;
      input.dispatchEvent(new Event('change', { bubbles: true }));
    } catch (e) { return { reason: 'attach-failed', own }; }
    // Each 'gone' keeps its exact cause as a fixed reason code (several items / one unnamed-ours / composer node / document).
    const GONE = { many: 'attach-ambiguous', name: 'attach-name-mismatch', comp: 'composer-replaced', doc: 'stale-document' };
    const appeared = await observe(() => {
      if (gate(docID)) return 'doc';
      if (!comp.isConnected) return 'comp';
      const it = imgFind(route, scope, file);
      return it === 'many' ? (route.items(scope.root).length > 1 ? 'many' : 'name') : it;
    }, 8000);
    if (!appeared || typeof appeared === 'string') {
      const ours = input.files && input.files.length === 1 && input.files[0] === file;
      if (appeared && ours) input.value = '';
      // Copilot's first image use asks the person for a confirmation first: never acknowledged here, and our own
      // pending file is dropped so it cannot attach after a later manual confirmation.
      if (!appeared && CFG.kind === 'copilot' && q('[role="dialog"], dialog').some(visible)) {
        // Cancel through the notice's own "나중에" button (never the confirm button), then require proof that the
        // notice is gone and nothing of ours is left pending; without that proof the reason says so.
        const dlg = q('[role="dialog"], dialog').filter(visible);
        const later = dlg.length === 1 ? q('button', dlg[0]).filter((x) => norm(x.textContent) === '나중에') : [];
        if (later.length === 1) later[0].click();
        if (ours) input.value = '';
        const settled = later.length === 1 && await observe(() => (!q('[role="dialog"], dialog').some(visible)
          && !(input.files && input.files.length) && !route.items(scope.root).length) ? true : null, 3000);
        return { reason: settled ? 'first-use-confirmation' : 'first-use-confirmation-uncancelled', own };
      }
      return { reason: appeared ? GONE[appeared] : 'attach-not-shown', own };
    }
    own.item = appeared;
    let why = 'item';
    const ready = await observe(() => {
      if (gate(docID) || !comp.isConnected) return 'gone';
      const it = imgFind(route, scope, file);
      if (it === 'many') return 'gone';
      if (!it) { why = 'item'; return null; }
      own.item = it;
      if (imgFailed(own, scope)) return 'failed';
      why = imgPending(own, scope) || (!imgSend(scope) ? 'send-none' : (isEnabled(imgSend(scope)) ? '' : 'send-off'));
      if (why) return null;
      const im = route.img(it);
      own.src = im ? im.src : '';
      return 'ready';
    }, 30000);
    if (ready !== 'ready') return { reason: ready === 'failed' ? 'upload-failed' : (ready ? 'attach-changed' : 'upload-timeout-' + why), own };
    return { ok: true, own, scope };
  } finally {
    // Leave the provider's upload menu closed again (only the menu this call opened).
    if (opener && opener.isConnected && opener.getAttribute('aria-expanded') === 'true') opener.click();
  }
}
async function submitPageContextNow(docID, p, promptText, imageB64) {
    const c = composerInfo();
    if (!c.el || c.el !== p.comp || !p.comp.isConnected || String(location.href) !== p.href) {
      return { ok: false, reason: 'composer-changed' };
    }
    if (norm(textOf(c.el)) !== norm(p.raw)) {
      return { ok: false, reason: 'user-active' };
    }
    let own = null, scope = null;
    if (imageB64 && !IMAGE_PAGE_KINDS.has(CFG.kind)) return { ok: false, reason: 'image-route-unsupported' };
    // Meta shows its attachment inside the Lexical editor, so a later whole-editor text write would replace it: there the
    // text is written first and the image attached after it.
    const textFirst = !!imageB64 && CFG.kind === 'meta';
    const attach = async (expected) => {
      const a = CFG.kind === 'claude' ? await attachClaudeImage(docID, p, c.el, imageB64) : await attachPageImage(docID, p, c.el, imageB64);
      own = a.own || null;
      if (!a.ok) return a.reason;
      scope = a.scope;
      if (gate(docID) || composerInfo().el !== c.el || String(location.href) !== p.href || norm(textOf(c.el)) !== norm(expected)) return 'composer-changed';
      return '';
    };
    if (imageB64 && !textFirst) {
      const why = await attach(p.raw);
      if (why) {
        imageCleanup(own);
        return { ok: false, reason: why };
      }
    }
    const writeGen = touchGen;
    const wrote = writeComposer(c.el, promptText, () => !gate(docID) && composerInfo().el === c.el);
    const ok = await wrote;
    // Our own readback right after a failed write with no input since it: the editor held exactly the raw text when
    // the write began, so this value is still only ours (raw and / or our partial write) and may be replaced by the raw.
    let after = null;
    // reacquire (Meta, after the click only): a guard for taking the one new, empty current editor when ours was replaced.
    const restoreRaw = async (reacquire) => {
      // Only undo our own injected text; never overwrite newer typing or a different composer.
      try {
        if (String(location.href) !== p.href) return false;
        if (!c.el.isConnected) {
          if (!reacquire || !reacquire()) return false;
          const cn = composerInfo().el, sc = cn ? imgScope(cn) : null;
          if (!cn || cn === c.el || norm(textOf(cn)) !== '' || !sc || IMG_ROUTE.meta.items(sc.root).length) return false;
          return await writeComposer(cn, p.raw, () => reacquire() && composerInfo().el === cn, true);
        }
        if (composerInfo().el !== c.el) return false;
        const cur = norm(textOf(c.el));
        if (cur === norm(promptText) || cur === '' || (after !== null && cur === after && touchGen === writeGen)) return await writeComposer(c.el, p.raw, null, true);
      } catch (e) {}
      return false;
    };
    if (!ok) {
      // Fixed bits (1 = holds), logged only: editor connected, still the current editor, same address, same document,
      // no input since the write, insertText reported success, paste fallback ran, readback empty, readback = raw,
      // readback starts with raw, readback starts with the prompt's head, prompt starts with readback (non-empty),
      // readback shorter than the prompt, readback longer, the prompt twice in it. Text stays in this page.
      let w = '';
      try {
        const cur = c.el.isConnected ? norm(textOf(c.el)) : null, np = norm(promptText), nr = norm(p.raw);
        if (cur !== null && touchGen === writeGen && composerInfo().el === c.el) after = cur;
        w = [c.el.isConnected, composerInfo().el === c.el, String(location.href) === p.href, !gate(docID), touchGen === writeGen,
          genericWrite.typed, genericWrite.pasted, cur === '', cur === nr, cur !== null && cur.startsWith(nr),
          cur !== null && cur.startsWith(np.slice(0, 40)), !!cur && np.startsWith(cur), cur !== null && cur.length < np.length,
          cur !== null && cur.length > np.length, cur !== null && cur.indexOf(np) >= 0 && cur.indexOf(np) !== cur.lastIndexOf(np)]
          .map((b) => (b ? '1' : '0')).join('');
      } catch (e) { w = '0'; }
      const restored = await restoreRaw() === true;
      imageCleanup(own);
      return { ok: false, reason: 'composer-write-failed', restored, w };
    }
    if (textFirst) {
      // Our prompt is already in the editor: a throw here must still end in the raw restore below.
      const why = await attach(promptText).catch(() => 'attach-exception');
      if (why) {
        // Our own attachment goes first so the raw text is restored into an editor without it.
        imageCleanup(own);
        const restored = await restoreRaw() === true;
        return { ok: false, reason: why, restored };
      }
    }
    // With an image the semantic send button also needs the single owned, loaded, settled thumbnail.
    const stillOwned = () => !own || (own.route ? imgOwned(own, scope) : own.thumb.isConnected && claudeThumbs(scope).length === 1 && claudeThumbs(scope)[0] === own.thumb && claudeThumbReady(own.thumb));
    const btn = await observe(() => {
      const cn = composerInfo();
      if (cn.el !== c.el || norm(textOf(c.el)) !== norm(promptText) || !stillOwned()) return null;
      const b = own ? (own.route ? imgSend(scope) : scope.send) : sendButton(c.el);
      return b && isEnabled(b) ? b : null;
    }, own ? 4000 : 1500);
    let sendable = false;
    try { sendable = !!btn && !gate(docID) && !generating() && stillOwned(); } catch (e) { sendable = false; }
    if (!sendable) {
      // Meta's attachment sits inside the editor, so it is removed before the raw restore (as after a failed attach).
      if (textFirst) imageCleanup(own);
      const restored = await restoreRaw() === true;
      if (!textFirst) imageCleanup(own);
      return { ok: false, reason: 'send-button-not-ready', restored };
    }
    // Meta: the click alone is not a send (seen live: click, then an empty editor and a disabled send button with nothing
    // posted). Only our own new message counts; without it the result is unconfirmed and never resent (it may post late).
    const meta = CFG.kind === 'meta';
    // Meta: one-shot state right before the click, as fixed bits (1 = holds): same document, still the current editor,
    // connected, same address, the full prompt in it, our own image still ready (or none), send button live, no new
    // input since our write, not generating. Any miss = no click (never an empty or stale question).
    let pre = '';
    if (meta) {
      try {
        pre = [!gate(docID), composerInfo().el === c.el, c.el.isConnected, String(location.href) === p.href,
          norm(textOf(c.el)) === norm(promptText), stillOwned(), btn.isConnected && isEnabled(btn), touchGen === writeGen,
          !generating()].map((b) => (b ? '1' : '0')).join('');
      } catch (e) { pre = '0'; }
      if (pre !== '111111111') {
        imageCleanup(own);
        const restored = await restoreRaw() === true;
        return { ok: false, reason: 'preclick-stale', g: pre, restored };
      }
    }
    const before = meta ? metaOwnPosts(promptText, c.el) : null;
    const clickGen = touchGen;
    btn.click();
    if (!meta) return { ok: true };
    const posted = await observe(() => {
      if (gate(docID)) return 'doc';
      const now = metaOwnPosts(promptText, c.el);
      return now.size > before.size && Array.from(now).some((el) => !before.has(el)) ? 'found' : null;
    }, 8000);
    if (posted === 'found') return { ok: true };
    // Restore guard at this point as fixed bits (logged only): no document move, same document, no input since the click,
    // our editor connected, still the current editor, same address, our editor empty or ours, a different current editor
    // that is empty (remount), our own image card still shown.
    let q = '';
    try {
      const cn = composerInfo().el, cur = c.el.isConnected ? norm(textOf(c.el)) : null;
      q = [posted !== 'doc', !gate(docID), touchGen === clickGen, c.el.isConnected, cn === c.el, String(location.href) === p.href,
        cur === '' || cur === norm(promptText), !!cn && cn !== c.el && norm(textOf(cn)) === '', !!own && !!own.item && own.item.isConnected]
        .map((b) => (b ? '1' : '0')).join('');
    } catch (e) { q = '0'; }
    // Same document, no newer input: our own attachment goes first, then the exact raw text (restoreRaw keeps newer typing).
    // Our editor replaced (seen live: q=111001010) → only the one new, empty current editor, while still the same document
    // and address, no input since the click and no own new message even now (it may post late; nothing is resent).
    let restored = false;
    if (posted !== 'doc' && !gate(docID) && touchGen === clickGen) {
      imageCleanup(own);
      const reacquire = () => !gate(docID) && touchGen === clickGen
        && !Array.from(metaOwnPosts(promptText, composerInfo().el || c.el)).some((el) => !before.has(el));
      restored = touchGen === clickGen && await restoreRaw(reacquire) === true;
    }
    return { ok: false, reason: 'post-unconfirmed', restored, g: pre, q };
}
// Meta's shown nodes holding our prompt's start: outside the composer, its send root and side / dialog chrome. Counted
// against the same scan taken just before the click, so earlier history with the same page header (or a re-render of it)
// never counts. The text is compared inside this page only and never leaves it.
function metaOwnPosts(promptText, comp) {
  const squash = (s) => String(s == null ? '' : s).replace(/\s+/g, '');
  const out = new Set();
  const probe = squash(promptText).slice(0, 80);
  const anchor = squash(String(promptText).split('\n').find((l) => l.trim()) || '').slice(0, 12);
  if (!probe || !anchor) return out;
  const root = chatRoot(comp);
  const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
  for (let n = walker.nextNode(); n; n = walker.nextNode()) {
    if (!squash(n.data).includes(anchor)) continue;
    let el = n.parentElement;
    for (let i = 0; i < 8 && el && el !== document.body && !squash(el.textContent).includes(probe); i++) el = el.parentElement;
    if (!el || el === document.body || !squash(el.textContent).includes(probe)) continue;
    if (el.contains(comp) || comp.contains(el) || (root && (root.contains(el) || el.contains(root)))) continue;
    if (!visible(el) || el.closest('[contenteditable="true"], textarea, nav, aside, header, dialog, [role="dialog"], [role="navigation"], [aria-hidden="true"]')) continue;
    out.add(el);
  }
  return out;
}

for (const type of ['keydown', 'pointerdown', 'mousedown', 'touchstart', 'paste', 'drop', 'input']) window.addEventListener(type, onTouch, true);
window.addEventListener('keydown', onKey, true);
window.addEventListener('click', onClick, true);
window.addEventListener('focusout', onBlur, true);
window.addEventListener('load', () => post({ t: 'life', k: 'ready' }));
document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'visible') post({ t: 'life', k: 'visible' }); });
post({ t: 'hello' });
if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', startWatch, { once: true }); else startWatch();
})();
"""#
}
