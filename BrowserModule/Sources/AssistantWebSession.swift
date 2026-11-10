import Foundation
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
        self.scriptSource = AssistantWebScript.source(kind: kind, origin: origin, pattern: trigger.pattern,
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
            let text = Self.describe(result["reason"] as? String) + " 입력 중인 내용은 그대로입니다."
            publish(.refused, text, draftPreserved: true)
            return .refused(text)
        }
        noteObservation(result)
        let raw = String((result["raw"] as? String ?? "").prefix(AssistantPlannerTrigger.maxInputLength))
        return await dispatchHandoff(raw: raw, source: .manual, requestUUID: UUID().uuidString, capture: result, ctx: ctx, acknowledge: false)
    }

    // MARK: Message handling

    fileprivate func receive(_ message: WKScriptMessage, epoch messageEpoch: Int) {
        guard messageEpoch == epoch, let world, message.world == world, message.frameInfo.isMainFrame,
              let webView, message.webView === webView,
              Self.origin(of: message.frameInfo.securityOrigin) == homeOrigin,
              let body = message.body as? [String: Any], body["n"] as? String == nonce,
              let doc = body["doc"] as? String, Self.isToken(doc), let type = body["t"] as? String else { return }
        if type == "hello" {
            docID = doc
            docGeneration += 1
            observedStable = nil
            hanaProof = nil
            noteObservation(body)
            capability = .unknown("페이지를 확인하는 중입니다.")
            return
        }
        guard doc == docID else { return }
        noteObservation(body)
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
            let reason = Self.describe(body["reason"] as? String)
            publish(.refused, "플래너에 넘기지 못했습니다. \(reason) 입력한 내용은 그대로 두었습니다.", draftPreserved: true)
        case "trigger":
            Task { [weak self] in
                await self?.handleTrigger(body, epoch: currentEpoch, generation: generation)
            }
        default:
            break
        }
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
              Self.normalizedOrigin(identity.conversationURL) == homeOrigin,
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
        guard Self.normalizedOrigin(href) == homeOrigin, let components = URLComponents(string: href),
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
              Self.normalizedOrigin(href) == homeOrigin else { return nil }
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
              Self.normalizedOrigin(href) == homeOrigin,
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
              Self.normalizedOrigin(raw) == homeOrigin else { return nil }
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
              Self.normalizedOrigin(live) == homeOrigin else { return }
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
        default: break
        }
        let host = origin.replacingOccurrences(of: "https://", with: "")
        if host == "chatgpt.com" || host == "chat.openai.com" { return "chatgpt" }
        if host == "claude.ai" { return "claude" }
        if host == "gemini.google.com" { return "gemini" }
        return "generic"
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
        case "stale-document", "retired", "origin-changed", "url-changed", "thread-changed":
            return "대화 화면이 바뀌어 보류했습니다."
        case "composer-write-failed": return "입력창에 메시지를 넣지 못해 보내지 않았습니다."
        case "send-button-not-ready": return "전송 버튼을 하나로 확인하지 못해 보내지 않았습니다."
        case "no-script": return "대화창 연결 스크립트가 아직 준비되지 않았습니다."
        case .some(let other): return "페이지 상태를 확인하지 못했습니다(\(String(other.prefix(40))))."
        case .none: return "페이지 상태를 확인하지 못했습니다."
        }
    }
}

// MARK: - Isolated-world script

enum AssistantWebScript {
    static func source(kind: String, origin: String, pattern: String, handler: String, nonce: String, watch: Bool) -> String {
        let config: [String: Any] = ["kind": kind, "origin": origin, "pattern": pattern,
                                     "handler": handler, "nonce": nonce, "watch": watch]
        let data = (try? JSONSerialization.data(withJSONObject: config)) ?? Data("{}".utf8)
        return template.replacingOccurrences(of: "__CONFIG__", with: String(decoding: data, as: UTF8.self))
    }

    private static let template = #"""
(() => {
'use strict';
const CFG = __CONFIG__;
if (window.__afPlanner || window.top !== window || location.origin !== CFG.origin) return;
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
const textOf = (el) => (isField(el) ? String(el.value || '') : String(el.innerText != null ? el.innerText : (el.textContent || '')));
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
function isSendLike(b) {
  const t = [b.getAttribute('data-testid'), b.getAttribute('aria-label'), b.getAttribute('title'), b.id, b.getAttribute('name')].filter(Boolean).join(' ');
  if (NOT_SEND_RE.test(t)) return false;
  if (CFG.kind === 'gemini') return SEND_RE.test(t);
  if (CFG.kind === 'perplexity') return SEND_RE.test(t) || b.getAttribute('aria-label') === '제출';
  return SEND_RE.test(t) || (b.tagName === 'BUTTON' && b.type === 'submit');
}
function sendCandidates(root) {
  return innermost(q('button, [role="button"]', root).filter((b) => visible(b) && isSendLike(b)));
}
function chatRoot(el) {
  const form = el.closest('form, [role="form"]');
  if (form) return form;
  let p = el.parentElement;
  for (let i = 0; i < 8 && p && p !== document.body && p !== document.documentElement; i++, p = p.parentElement) {
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
  return list.filter((el) => chatRoot(el));
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
function onKey(e) {
  if (!alive || !e.isTrusted || e.key !== 'Enter' || e.shiftKey || e.altKey || e.ctrlKey || e.metaKey || e.isComposing || e.keyCode === 229 || e.repeat) return;
  const host = e.target && e.target.closest ? e.target.closest(EDITABLE) : null;
  if (!host) return;
  const raw = textOf(host);
  if (!isTrigger(raw)) return;
  const c = composerInfo();
  if (!c.el) { refuseAmbiguous(e, 'enter', c, (x) => x === host || x.contains(host) || host.contains(x)); return; }
  if (!(c.el === host || c.el.contains(host) || host.contains(c.el))) return;
  intercept(e, 'enter', c.el, textOf(c.el));
}
function onClick(e) {
  if (!alive || !e.isTrusted || e.button !== 0) return;
  const b = e.target && e.target.closest ? e.target.closest('button, [role="button"]') : null;
  if (!b || !isSendLike(b)) return;
  const c = composerInfo();
  if (!c.el) {
    refuseAmbiguous(e, 'click', c, (x) => { const r = chatRoot(x); return !!r && r.contains(b) && isTrigger(textOf(x)); });
    return;
  }
  const root = chatRoot(c.el);
  if (!root || !root.contains(b)) return;
  const raw = textOf(c.el);
  if (!isTrigger(raw)) return;
  intercept(e, 'click', c.el, raw);
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
const ATTACH_SEL = '[data-testid*="attachment" i], [data-testid*="file-preview" i], [data-testid*="file-chip" i], [class*="attachment" i], [class*="file-preview" i], [class*="file-chip" i], [class*="uploaded" i]';
const ATTACH_REMOVE = /(?:remove|delete|제거|삭제).*(?:attach|file|upload|첨부|파일)|(?:attach|file|upload|첨부|파일).*(?:remove|delete|제거|삭제)/i;
function hasAttachment() {
  if (q('input[type="file"]').some((i) => i.files && i.files.length > 0)) return true;
  const shown = q(ATTACH_SEL).some((el) => visible(el) && !el.closest('button, [role="button"], nav, [role="navigation"]')
    && ((el.textContent || '').trim() || el.querySelector('img, canvas, video')));
  return shown || q('button, [role="button"]').some((b) => ATTACH_REMOVE.test(b.getAttribute('aria-label') || ''));
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
  return !!(el && CFG.kind === 'perplexity' && el.matches('.composer-editable[data-lexical-editor="true"][role="textbox"][contenteditable="true"]'));
}
// Perplexity's composer is Lexical: exactly one native insertText of the normalized single-line payload into the
// editor's own contents (a multi-line insertText loses its newlines). The native input already commits Lexical's model,
// so no extra input or change events are dispatched (an explicit InputEvent duplicates the payload). Lexical may apply
// the edit after execCommand has already returned (even false), so the complete normalized payload is awaited once with
// the finite mutation-driven observe. There is no paste, DOM rebuild or second insert on a mismatch. The result is
// rejected if proof or touch generation changes.
async function writeLexicalEditor(el, text, still) {
  el.focus();
  const selection = window.getSelection();
  const range = document.createRange();
  range.selectNodeContents(el);
  selection.removeAllRanges();
  selection.addRange(range);
  try { document.execCommand('insertText', false, norm(text)); } catch (e) { /* the editor content is verified below */ }
  const gen = touchGen;
  const live = () => alive && el.isConnected && touchGen === gen && (!still || still());
  const matches = () => live() && norm(textOf(el)) === norm(text);
  const hit = await observe(() => (matches() ? 'match' : null), 1500);
  return !!hit && matches();
}
async function writeComposer(el, text, still) {
  if (isField(el)) { setFieldValue(el, text); return textOf(el) === text; }
  if (CFG.kind === 'gemini' && isQuillEditor(el)) return writeQuillEditor(el, text);
  if (isLexicalEditor(el)) return writeLexicalEditor(el, text, still);
  el.focus();
  document.execCommand('selectAll', false, null);
  let ok = false;
  try { ok = document.execCommand('insertText', false, text); } catch (e) { ok = false; }
  if (!ok || norm(textOf(el)) !== norm(text)) {
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
  if (location.origin !== CFG.origin) return 'origin-changed';
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
  retire() { alive = false; for (const k of Object.keys(pending)) delete pending[k]; return true; },
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
    return g ? { ok: false, reason: g } : captureNow();
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
  }
};

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
