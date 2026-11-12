import SwiftUI
import AppKit
import WebKit

private struct AssistantPlannerEntryBar: View {
    @ObservedObject var session: AssistantWebSession
    let refreshToken: String
    let onManual: () -> Void
    @Environment(\.bkPalette) private var palette

    private var activeFeedback: String? {
        let status = session.status
        if status.kind == .accepted || status.kind == .refused || status.kind == .pending {
            return status.message
        }
        return nil
    }

    var body: some View {
        HStack(spacing: 6) {
            if let feedback = activeFeedback {
                Text(feedback)
                    .font(.caption)
                    .lineLimit(2)
                    .help(feedback)
            }
            Spacer(minLength: 4)
            Button("플래너에게 넘기기", action: onManual)
                .disabled(session.binding == nil || session.status.kind == .pending)
                .font(.caption)
                .buttonStyle(.plain)
                .help("지금 열린 대화를 읽어 새 플래너 프로젝트로 넘깁니다. 입력창 내용은 바꾸지 않습니다.")
        }
        .foregroundColor(palette.textColor)
        .padding(.horizontal, 10)
        .frame(height: BrowserView.footerHeight)
        .background(activeFeedback != nil ? palette.accentSoftColor : palette.cardColor)
        .task(id: refreshToken) { await session.refreshCapability() }
    }
}

struct GlobalAssistantDock: View {
    @ObservedObject var appModel: AppModel
    @ObservedObject private var hanaHost: HanaPanelHost = .shared
    @ObservedObject private var thirdPartyHost: ThirdPartyAIPanelHost
    @ObservedObject var aiStore: AIServiceStore
    @ObservedObject private var navModel: UnifiedNavigationModel = .shared
    #if HTT_HOST
    @ObservedObject private var hostExport: HTDHostExport = .shared
    #endif

    @State private var handoffInFlight = false
    @State private var handoffNonce = UUID()
    @State private var pageContextNonce = UUID()
    @State private var acceptedHandoffSource: (request: String, webView: ObjectIdentifier?, isHome: Bool, url: URL?, originLocation: String)?
    @State private var windowWidth: CGFloat = 860

    @Environment(\.bkPalette) private var palette

    init(appModel: AppModel) {
        self.appModel = appModel
        self.thirdPartyHost = appModel.thirdPartyAIHost
        self.aiStore = appModel.aiServices
    }

    private var model: LoginBrowserModel {
        appModel.browser
    }

    private var isBrowserVisible: Bool {
        #if HTT_HOST
        let hostedToolClear = hostExport.hostedToolID == nil
        #else
        let hostedToolClear = true
        #endif
        let navBrowser = navModel.destination == .browser
        let tabBrowser = appModel.selectedTab == .browser
        return hostedToolClear && navBrowser && tabBrowser
    }

    var isPaneActive: Bool {
        isBrowserVisible && appModel.browser === model
    }

    private var isDockOpen: Bool {
        let isHana = appModel.activeAIPanelIsHana || hanaHost.isPanelOpen
        return isHana ? (appModel.isAIPanelOpen && hanaHost.isPanelOpen) : appModel.isAIPanelOpen
    }

    private var isNativeInputAllowed: Bool {
        guard isDockOpen else { return false }
        guard let keyWindow = NSApp.keyWindow, let mainWindow = NSApp.mainWindow,
              keyWindow === mainWindow, mainWindow.isVisible, NSApp.isActive else { return false }
        return true
    }

    private func currentUILocationKey() -> String {
        var key = "\(navModel.destination)"
        let navMirror = Mirror(reflecting: navModel)
        for child in navMirror.children {
            if let label = child.label?.trimmingCharacters(in: CharacterSet(charactersIn: "_")),
               ["settingsTab", "activeChildIDs", "activechildIDs"].contains(label) {
                key += "/\(child.value)"
            }
        }
        #if HTT_HOST
        key += "+\(hostExport.hostedToolID ?? "")"
        #endif
        key += "+\(appModel.selectedTab)"
        if appModel.selectedTab == .browser {
            key += "/\(model.tabID.uuidString)"
        }
        let appMirror = Mirror(reflecting: appModel)
        for child in appMirror.children {
            if let label = child.label?.trimmingCharacters(in: CharacterSet(charactersIn: "_")),
               ["selectedTabID", "selectedTabId"].contains(label) {
                key += "/\(child.value)"
            }
        }
        if let projectID = appModel.sawWorkspace.selectedProjectID {
            key += "+\(projectID.uuidString)"
        }
        if let serviceID = appModel.aiServices.selectedService.id ?? thirdPartyHost.currentService?.id {
            key += "+\(serviceID)"
        }
        return key
    }

    var body: some View {
        let open = isDockOpen
        let isHanaPanel = appModel.activeAIPanelIsHana || hanaHost.isPanelOpen
        let maxPanel = max(324, windowWidth - 200 - 320 - 16)
        let availableWidth = maxPanel + 116
        let panelWidth = isHanaPanel
            ? hanaHost.effectiveWidth(forAvailableWidth: availableWidth)
            : thirdPartyHost.effectiveWidth(forAvailableWidth: availableWidth)
        let outerWidth = open ? panelWidth : 0

        GeometryReader { _ in
            if open {
                VStack(spacing: 0) {
                    if isHanaPanel {
                        HanaPanelView(
                            host: hanaHost,
                            availableWidth: availableWidth,
                            nativeInputAllowed: { isNativeInputAllowed }
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ThirdPartyAIPanelView(
                            host: thirdPartyHost,
                            service: appModel.aiServices.selectedService,
                            availableWidth: availableWidth,
                            onClose: { appModel.setAIPanelOpen(false) },
                            nativeInputAllowed: { isNativeInputAllowed }
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }

                    if !isHanaPanel && isBrowserVisible {
                        Divider()

                        HStack(spacing: 0) {
                            AIPageContextComposerView(
                                appModel: appModel,
                                tabModel: model,
                                isHana: isHanaPanel,
                                panelWidth: panelWidth,
                                isBrowserVisible: { isBrowserVisible }
                            )
                            .frame(width: panelWidth)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    Divider()
                    if let entrySession = isHanaPanel ? hanaHost.plannerSession : thirdPartyHost.plannerSession {
                        AssistantPlannerEntryBar(
                            session: entrySession,
                            refreshToken: isHanaPanel
                                ? "hana|\(hanaHost.isBridgeReady)"
                                : "\(thirdPartyHost.currentService?.id ?? "")|\(thirdPartyHost.isLoading)",
                            onManual: { startManualAssistantHandoff(entrySession, isHana: isHanaPanel) }
                        )
                    }
                }
                .frame(width: panelWidth)
                .frame(maxHeight: .infinity)
            } else {
                Color.clear
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: outerWidth)
        .frame(maxHeight: .infinity)
        .background(palette.cardColor)
        .overlay(alignment: .leading) {
            if open { Rectangle().fill(palette.borderColor).frame(width: 1) }
        }
        .allowsHitTesting(open)
        .accessibilityHidden(!open)
        .onChange(of: hanaHost.isPanelOpen) { isOpen in
            if !isOpen && appModel.activeAIPanelIsHana && appModel.isAIPanelOpen {
                appModel.setAIPanelOpen(false)
            } else if isOpen && !appModel.isAIPanelOpen {
                appModel.setAIPanelOpen(true)
            }
        }
        .onChange(of: appModel.isAIPanelOpen) { isOpen in
            if isOpen {
                if appModel.activeAIPanelIsHana && !hanaHost.isPanelOpen {
                    hanaHost.isPanelOpen = true
                }
            } else {
                if hanaHost.isPanelOpen {
                    hanaHost.isPanelOpen = false
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResizeNotification)) { note in
            if let win = note.object as? NSWindow,
               win === NSApp.mainWindow || (NSApp.mainWindow == nil && win === NSApp.keyWindow) {
                windowWidth = win.frame.width
            }
        }
        .onAppear {
            if let win = NSApp.mainWindow ?? NSApp.keyWindow {
                windowWidth = win.frame.width
            }
            bindHanaDelegation()
            bindAssistantHandoff()

            hanaHost.onOpenExternalURL = { [weak appModel] url in
                guard let appModel = appModel else { return }
                guard let validatedString = BrowserPreferences.validateWebURL(url.absoluteString) else { return }
                if appModel.tabs.count >= AppModel.maxTabs {
                    appModel.browser.notice = "더 이상 탭을 열 수 없습니다. (최대 \(AppModel.maxTabs)개)"
                    return
                }
                appModel.newTab()?.open(validatedString)
            }
            thirdPartyHost.onOpenExternalURL = { [weak appModel] url in
                guard let appModel = appModel else { return }
                guard let validatedString = BrowserPreferences.validateWebURL(url.absoluteString) else { return }
                if appModel.tabs.count >= AppModel.maxTabs {
                    appModel.browser.notice = "더 이상 탭을 열 수 없습니다. (최대 \(AppModel.maxTabs)개)"
                    return
                }
                appModel.newTab()?.open(validatedString)
            }
        }
        .onDisappear {
            hanaHost.releaseDelegation(owner: appModel.ownerUUID)
            releaseAssistantHandoff()
        }
    }

    private func handoffHanaToPlanner(delegation: HanaDelegationRequest? = nil) {
        func refuse(_ message: String) {
            if let delegation = delegation {
                hanaHost.finishDelegation(delegation, error: message)
            } else {
                hanaHost.statusMessage = message
            }
        }
        guard !handoffInFlight, !hanaHost.isCapturingPlannerHandoff else {
            if delegation != nil { refuse("지금은 일반 브라우저 화면에서만 플래너로 넘길 수 있습니다. 입력은 그대로 둡니다.") }
            return
        }
        let originLocation = currentUILocationKey()
        let sourcePage: LoginBrowserModel? = isBrowserVisible ? appModel.browser : nil
        let tabID = sourcePage?.tabID
        let sourceWV = sourcePage?.webView
        let isHome = sourcePage?.isShowingHome ?? true
        let sourceURL: URL? = (sourcePage == nil || isHome) ? nil : sourcePage?.currentURL
        if let page = sourcePage, !isHome {
            guard let url = sourceURL, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else {
                refuse("현재 페이지가 일반 웹 주소(http/https)가 아니어서 넘길 수 없습니다.")
                return
            }
        }
        let nonce = UUID()
        handoffNonce = nonce
        handoffInFlight = true
        Task { @MainActor in
            defer { if handoffNonce == nonce { handoffInFlight = false } }
            guard let handoff = try? await hanaHost.capturePlannerHandoff(delegation: delegation) else {
                if let delegation = delegation { hanaHost.finishDelegation(delegation, error: nil) }
                return
            }
            @MainActor func sourceUnchanged() -> Bool {
                if Task.isCancelled || handoffNonce != nonce { return false }
                if let page = sourcePage {
                    guard page.tabID == tabID, page.webView === sourceWV, page.isShowingHome == isHome,
                          isHome || page.currentURL == sourceURL else { return false }
                }
                return true
            }
            guard sourceUnchanged(), delegation.map({ hanaHost.isDelegationCurrent($0) }) ?? true else {
                refuse("넘기는 동안 화면이 바뀌어 취소했습니다. 다시 시도해 주세요.")
                return
            }
            let context = (sourcePage == nil || isHome) ? "[현재 활성 웹페이지 없음]\n" + handoff.context : handoff.context
            let locationStillOrigin = (currentUILocationKey() == originLocation)
            guard let pid = appModel.sawWorkspace.acceptHanaHandoff(goal: handoff.goal, context: context, pageURL: sourceURL,
                                                                   delegatedInstruction: delegation?.utterance,
                                                                   present: locationStillOrigin) else {
                refuse("플래너 프로젝트를 만들지 못했습니다.")
                return
            }
            sourceWV?.pauseAllMediaPlayback(completionHandler: nil)
            guard !Task.isCancelled, let runID = appModel.sawWorkspace.session(for: pid).teamRunID else {
                if let delegation = delegation { hanaHost.finishDelegation(delegation, error: nil, accepted: true) }
                return
            }
            if let delegation = delegation {
                hanaHost.registerDelegation(delegation, projectID: pid, runID: runID)
                await hanaHost.acknowledgePlannerHandoff(handoff)
                hanaHost.finishDelegation(delegation, error: nil, accepted: true)
            } else {
                await hanaHost.acknowledgePlannerHandoff(handoff)
            }
        }
    }

    private func handleAssistantHandoff(_ handoff: AssistantWebHandoff, from session: AssistantWebSession) async -> AssistantWebHandoffDecision {
        guard !handoffInFlight else { return .refused("이미 플래너로 넘기는 중입니다.") }
        let originLocation = currentUILocationKey()
        let sourcePage: LoginBrowserModel? = isBrowserVisible ? appModel.browser : nil
        let tabID = sourcePage?.tabID
        let sourceWV = sourcePage?.webView
        let isHome = sourcePage?.isShowingHome ?? true
        let sourceURL: URL? = (sourcePage == nil || isHome) ? nil : sourcePage?.currentURL
        if let page = sourcePage, !isHome {
            guard let url = sourceURL, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else {
                return .refused("현재 페이지가 일반 웹 주소(http/https)가 아니어서 넘길 수 없습니다.")
            }
            guard !SAWWorkspace.hasCredentialQuery(url) else {
                return .refused("현재 페이지 주소에 인증 정보로 보이는 값이 있어 넘기지 않았습니다.")
            }
        }
        handoffInFlight = true
        defer { handoffInFlight = false }
        await Task.yield()
        func sourceUnchanged() -> Bool {
            if Task.isCancelled || session.binding == nil { return false }
            if let page = sourcePage {
                guard page.tabID == tabID, page.webView === sourceWV,
                      page.isShowingHome == isHome, (isHome || page.currentURL == sourceURL) else { return false }
            }
            return true
        }
        guard sourceUnchanged() else {
            return .refused("넘기는 동안 화면이 바뀌어 취소했습니다. 다시 시도해 주세요.")
        }
        guard await session.isHandoffCurrent(handoff), sourceUnchanged() else {
            return .refused("넘기는 동안 대화나 화면이 바뀌어 취소했습니다. 다시 시도해 주세요.")
        }
        let decision = appModel.sawWorkspace.acceptAssistantHandoff(handoff, session: session, pageURL: sourceURL)
        if case .accepted = decision {
            sourceWV?.pauseAllMediaPlayback(completionHandler: nil)
            acceptedHandoffSource = (handoff.requestUUID, sourceWV.map { ObjectIdentifier($0) }, isHome, sourceURL, originLocation)
        }
        return decision
    }

    private func presentAcceptedAssistantHandoff(_ handoff: AssistantWebHandoff, from session: AssistantWebSession) {
        defer { acceptedHandoffSource = nil }
        guard appModel.assistantHandoffOwner == appModel.ownerUUID,
              let source = acceptedHandoffSource, source.request == handoff.requestUUID,
              session.originToken == handoff.identity.originToken, let binding = session.binding,
              binding.serviceID == handoff.identity.serviceID, binding.profileID == handoff.identity.profileID,
              binding.conversationURL() == handoff.identity.conversationURL else { return }
        let workspace = appModel.sawWorkspace
        guard let association = workspace.assistantPlanner.associations.first(where: {
                  $0.identity.requestID == handoff.requestUUID && $0.status == .active
                      && $0.identity.serviceID == binding.serviceID && $0.identity.profileID == binding.profileID }),
              let projectID = UUID(uuidString: association.identity.projectID),
              let runID = UUID(uuidString: association.identity.runID),
              workspace.store.projects.contains(where: { $0.id == projectID && !$0.archived }),
              workspace.store.runs.contains(where: { $0.id == runID && $0.projectID == projectID }) else { return }
        guard currentUILocationKey() == source.originLocation else { return }
        workspace.selectedProjectID = projectID
        appModel.selectedTab = .saw
    }

    private func bindAssistantHandoff() {
        appModel.assistantHandoffOwner = appModel.ownerUUID
        for session in [hanaHost.plannerSession, thirdPartyHost.plannerSession].compactMap({ $0 }) {
            session.onHandoff = { [weak session] handoff in
                guard let session = session else { return .refused("대화창이 바뀌어 넘기지 않았습니다.") }
                return await handleAssistantHandoff(handoff, from: session)
            }
            session.onAcceptedPresentation = { [weak session] handoff in
                guard let session = session else { return }
                presentAcceptedAssistantHandoff(handoff, from: session)
            }
        }
    }

    private func releaseAssistantHandoff() {
        guard appModel.assistantHandoffOwner == appModel.ownerUUID else { return }
        appModel.assistantHandoffOwner = nil
        for session in [hanaHost.plannerSession, thirdPartyHost.plannerSession].compactMap({ $0 }) {
            session.onHandoff = nil
            session.onAcceptedPresentation = nil
        }
    }

    private func startManualAssistantHandoff(_ session: AssistantWebSession?, isHana: Bool) {
        guard let session = session, let binding = session.binding, !isHana || binding.conversationURL() != nil else {
            if isHana {
                handoffHanaToPlanner()
            } else {
                thirdPartyHost.statusMessage = "이 서비스는 플래너 연결을 사용할 수 없어 넘기지 못했습니다."
            }
            return
        }
        Task { @MainActor in _ = await session.captureManually() }
    }

    private func bindHanaDelegation() {
        hanaHost.bindDelegation(owner: appModel.ownerUUID, handler: { request in handoffHanaToPlanner(delegation: request) },
                                pageContext: { request in askHanaAboutCurrentPage(request) })
    }

    private func askHanaAboutCurrentPage(_ request: HanaDelegationRequest) {
        func refuse(_ message: String) {
            hanaHost.finishPageContext(request, error: message)
        }
        guard isBrowserVisible, appModel.browser === model,
              !model.isShowingHome, !model.isLoading, let sourceURL = model.currentURL, let sourceWV = model.webView else {
            refuse("지금은 읽을 수 있는 일반 웹 페이지가 열려 있지 않아 보내지 않았습니다. 입력은 그대로 둡니다.")
            return
        }
        let tabID = model.tabID
        let nonce = UUID()
        pageContextNonce = nonce
        Task { @MainActor in
            let result = await AIPageSnapshotExtractor.capture(tab: model, timeoutSeconds: 8)
            guard !Task.isCancelled, pageContextNonce == nonce, isBrowserVisible,
                  appModel.browser === model, model.tabID == tabID,
                  model.webView === sourceWV, !model.isShowingHome, model.currentURL == sourceURL,
                  hanaHost.isPageContextCurrent(request) else {
                refuse("읽는 동안 페이지나 하나 대화가 바뀌어 보내지 않았습니다. 입력은 그대로 둡니다.")
                return
            }
            let snapshot: AIPageSnapshot
            switch result {
            case .failure(let error):
                refuse((error.errorDescription ?? "페이지를 읽지 못했습니다.") + " 입력은 그대로 둡니다.")
                return
            case .success(let value):
                snapshot = value
            }
            let prompt = AIPagePromptFormatter.format(snapshot: snapshot, question: request.utterance)
            do {
                try await hanaHost.sendPageContextPrompt(prompt, request: request)
                hanaHost.finishPageContext(request, error: nil)
            } catch {
                refuse(((error as? HanaResultQuestionError)?.message ?? "하나로 보내지 못했습니다.") + (error is HanaResultQuestionError ? "" : " 입력은 그대로 둡니다."))
            }
        }
    }
}
