import SwiftUI
import AppKit
import WebKit

/// "브라우저" tab: a compact tab strip above the active tab's page. Observes the AppModel, so a tab change always
/// hands the pane the new active model; its video list is the "이 페이지의 영상" tab.
struct BrowserView: View {
    static let footerHeight: CGFloat = 28
    static let headerHeight: CGFloat = 44 // Aligned with one-row Hana assistant header at 400pt width.
    @ObservedObject var appModel: AppModel
    @Environment(\.bkPalette) private var palette

    init(appModel: AppModel) {
        self.appModel = appModel
    }

    var body: some View {
        BrowserPane(appModel: appModel, model: appModel.browser)
            .background(palette.cardColor)
    }
}

private struct BrowserHomeQuickActionRow: View {
    @ObservedObject var appModel: AppModel
    @ObservedObject var model: LoginBrowserModel
    @Environment(\.bkPalette) private var palette

    var body: some View {
        HStack(spacing: 10) {
            Button {
                appModel.requestAddressFocus(for: model, isExplicit: true)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                    Text("주소창·검색")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(palette.textColor)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(palette.surface2Color))
            }
            .buttonStyle(.plain)
            .help("주소 입력창으로 바로 이동합니다")
            .accessibilityLabel("주소창·검색")

            #if HTT_HOST
            Button {
                HTDHostExport.shared.selectToolFromSidebar("screen")
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "viewfinder")
                        .font(.system(size: 11))
                    Text("화면 번역")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(palette.textColor)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(palette.surface2Color))
            }
            .buttonStyle(.plain)
            .help("화면 번역 도구를 엽니다")
            .accessibilityLabel("화면 번역")
            #endif

            Button {
                #if HTT_HOST
                HTDHostExport.shared.clearHostedTool()
                #endif
                UnifiedNavigationModel.shared.navigateTo(
                    destination: .planner,
                    appModel: appModel,
                    selectTool: { _ in },
                    clearTool: {
                        #if HTT_HOST
                        HTDHostExport.shared.clearHostedTool()
                        #endif
                    }
                )
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "checklist")
                        .font(.system(size: 11))
                    Text("플래너")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(palette.textColor)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(palette.surface2Color))
            }
            .buttonStyle(.plain)
            .help("플래너를 엽니다")
            .accessibilityLabel("플래너")

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(palette.cardColor)
        .overlay(Divider(), alignment: .bottom)
    }
}
/// The active tab's page: address bar, status, banners, home or WebView, bottom bar (the former whole browser screen).
struct BrowserPane: View {
    @ObservedObject var appModel: AppModel
    @ObservedObject var model: LoginBrowserModel
    @ObservedObject var connection: ConnectionManager
    @ObservedObject var session: SessionManager
    @ObservedObject var siteRoutes: SiteRouteRules
    @ObservedObject var browsingConnection: ConnectionManager
    @ObservedObject var preferences: BrowserPreferences
    @ObservedObject var addressStore: AddressSearchStore
    @StateObject private var addressFlow = AddressRouteFlow()
    @State private var showGoogleAutofill = false
    @State private var showSiteCredentialSheet = false
    @ObservedObject var extensions: BrowserExtensionManager
    @EnvironmentObject private var appearance: AppearanceStore
    @Environment(\.bkPalette) private var palette
    @ObservedObject private var screenshotManager = BrowserScreenshotManager.shared
    @State private var showingHomeSettings = false
    @State private var showingCacheSettings = false
    @AppStorage(AutoShorts.storageKey) private var autoShortsEnabled = true
    @State private var showingPopupSettings = false
    @State private var showingAdManagement = false
    @FocusState private var addressFocused: Bool
    @State private var fieldFocused = false
    @State private var pickerHovering = false
    @State private var pickerSelection = 0
    /// Address text the picker must stay hidden for: text the app itself put in the field (navigation, focus gain,
    /// a finished choice, Esc). Only text that differs from it was typed or pasted by the user.
    @State private var pickerSuppressedText: String? = nil
    @State private var pickerKeyMonitor: Any?
    @StateObject private var webPageAgent = WebPageAgentCoordinator()
    let plannerSession: SAWProjectSession?

    init(appModel: AppModel, model: LoginBrowserModel, plannerSession: SAWProjectSession? = nil) {
        self.appModel = appModel
        self.model = model
        self.plannerSession = plannerSession
        self.connection = appModel.connection
        self.session = appModel.session
        self.siteRoutes = appModel.siteRoutes
        self.browsingConnection = appModel.browsingConnection
        self.preferences = appModel.preferences
        self.addressStore = appModel.preferences.addressSearch
        self.extensions = appModel.extensions
    }

    var isPaneActive: Bool {
        if let ps = plannerSession {
            return appModel.selectedTab == .saw && ps.workspace.selectedProjectID == ps.projectID && ps.selectedTabID == model.tabID
        }
        let isBrowserContext = appModel.selectedTab == .browser || appModel.selectedTab == .speed || appModel.selectedTab == .pageVideos
        return isBrowserContext && appModel.browser === model
    }

    private var sessionModeMismatch: Bool {
        guard session.isAlive, session.hasPrimaryStore else { return false }
        let current: Int? = connection.enabled ? connection.generation : nil
        return session.proxyGeneration != current
    }

    private var isCurrentURLBookmarked: Bool {
        guard let url = model.currentURL?.absoluteString else { return false }
        return preferences.isBookmarked(url: url)
    }

    private func toggleBookmark() {
        guard let url = model.currentURL?.absoluteString else { return }
        if isCurrentURLBookmarked {
            if preferences.removeBookmark(url: url) {
                model.notice = "즐겨찾기를 해제했습니다."
            }
        } else {
            let title = model.pageTitle.isEmpty ? (model.currentURL?.host ?? "웹 페이지") : model.pageTitle
            if preferences.addBookmark(url: url, title: title) {
                model.notice = "즐겨찾기에 추가했습니다."
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
                .zIndex(1)   // the address search picker hangs below the toolbar over the page
            if sessionModeMismatch {
                banner("연결 방식이 바뀌었습니다. 지금 세션은 이전 연결 방식으로 만들어졌습니다. '세션 지우기' 후 다시 열어 주세요.",
                       ink: palette.warnInkColor, fill: palette.warnSoftColor)
            }
            if let text = model.modeNotice { banner(text, ink: palette.warnInkColor, fill: palette.warnSoftColor) }
            if model.directRetryOffer != nil {
                HStack {
                    Button("일반 연결로 한 번 다시 열기") { model.retryOnceDirect() }
                        .font(.caption)
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(palette.warnSoftColor)
            }
            if let text = model.notice { banner(text, ink: palette.textColor, fill: palette.accentSoftColor) }
            if let text = model.adWallNotice { banner(text, ink: palette.warnInkColor, fill: palette.warnSoftColor) }
            if let err = model.lastError { banner(err, ink: palette.dangerColor, fill: palette.dangerSoftColor) }
            if let text = extensions.problemText { banner(text, ink: palette.dangerColor, fill: palette.dangerSoftColor) }
            if let text = extensions.notice { banner(text, ink: palette.textColor, fill: palette.accentSoftColor) }
            if let prefErr = preferences.errorMessage, prefErr != model.lastError {
                banner(prefErr, ink: palette.dangerColor, fill: palette.dangerSoftColor)
            }
            if let captureStatus = screenshotManager.captureStatus {
                HStack(spacing: 8) {
                    if !screenshotManager.isPreviewing { ProgressView().controlSize(.small) }
                    Text(captureStatus)
                        .font(.caption)
                        .foregroundColor(palette.textColor)
                    Spacer()
                    Button("취소") {
                        screenshotManager.cancelCapture()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(palette.accentSoftColor)
            }
            if connection.enabled && (model.recoveryInProgress || model.recoveryProblem != nil || hasUnallowableRefusals) { recoveryPanel }

            Divider()
            GeometryReader { geo in
                HStack(spacing: 0) {
                    Group {
                        if model.isShowingHome {
                            VStack(spacing: 0) {
                                BrowserHomeQuickActionRow(appModel: appModel, model: model)
                                BrowserHomeView(appModel: appModel, model: model, preferences: preferences, onOpenNewTab: { target in
                                    guard let validated = BrowserPreferences.validateWebURL(target),
                                          let url = URL(string: validated) else { return }
                                    if let ps = plannerSession {
                                        ps.newTab(url: url)
                                    } else {
                                        if appModel.tabs.count >= AppModel.maxTabs {
                                            appModel.browser.notice = "더 이상 탭을 열 수 없습니다. (최대 \(AppModel.maxTabs)개)"
                                            return
                                        }
                                        appModel.newTab(explicitURL: true)?.open(validated)
                                    }
                                })
                            }
                        } else {
                            pageArea
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(palette.bgColor)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            bottomStatusBar
        }
        .background(palette.cardColor)
        .onAppear {
            model.activate()
            webPageAgent.syncContext(tab: model)
        }
        // A 길찾기 lookup belongs to the tab it was started in: leaving that tab or this screen drops it.
        .onChange(of: model.tabID) { _, _ in
            addressFlow.cancel()
            webPageAgent.syncContext(tab: model)
        }
        .onChange(of: appModel.selectedTab) { _, selection in
            if !isPaneActive {
                addressFocused = false
                fieldFocused = false
                pickerHovering = false
                addressFlow.cancel()
                webPageAgent.teardown()
            } else {
                webPageAgent.syncContext(tab: model)
                consumeAddressFocusRequest()
            }
        }
        .onDisappear {
            addressFlow.cancel()
            webPageAgent.teardown()
        }
        .sheet(isPresented: Binding(get: { addressFlow.isPresented },
                                    set: { if !$0 { addressFlow.cancel() } })) {
            AddressRouteSheet(flow: addressFlow)
                .byungkiThemed(palette)
        }
        .sheet(isPresented: $showingCacheSettings) {
            BrowserCacheSettingsSheet(appModel: appModel) {
                showingCacheSettings = false
            }
            .byungkiThemed(palette)
        }
        .sheet(isPresented: $showingPopupSettings) {
            BrowserPopupSettingsSheet {
                showingPopupSettings = false
            }
            .byungkiThemed(palette)
        }
        .sheet(isPresented: $showingAdManagement) {
            BrowserAdManagementSheet(appModel: appModel, model: model, preferences: preferences) {
                showingAdManagement = false
            }
            .byungkiThemed(palette)
        }
        .sheet(isPresented: $showingHomeSettings) {
            BrowserHomeSettingsSheet(preferences: preferences, model: model) {
                showingHomeSettings = false
            }
            .byungkiThemed(palette)
        }
        .sheet(isPresented: $showGoogleAutofill) {
            GoogleAutofillSheet(fillNow: { if let wv = model.webView { model.googleFill.fillNow(in: wv) } },
                                arm: { model.armGoogleFill() })
            .byungkiThemed(palette)
        }
        .sheet(isPresented: $showSiteCredentialSheet) {
            SiteCredentialManagementSheet(model: model)
                .byungkiThemed(palette)
        }
    }

    /// The page itself keeps the system appearance, so the theme never changes how a site renders.
    private func keepSystemAppearance(_ wv: WKWebView) {
        let name: NSAppearance.Name = appearance.systemIsDark ? .darkAqua : .aqua
        if wv.appearance?.name != name { wv.appearance = NSAppearance(named: name) }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            navigationGroup

            addressBarGroup

            primaryActionGroup

            secondaryOverflowMenu
        }
        .padding(.horizontal, 10)
        .frame(height: BrowserView.headerHeight)
    }

    private var navigationGroup: some View {
        HStack(spacing: 3) {
            Button { model.goBack() } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .disabled(model.isShowingHome || !model.canGoBack)
            .help("뒤로")
            .accessibilityLabel("뒤로 가기")

            Button { model.goForward() } label: {
                Image(systemName: "chevron.right")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .disabled(model.isShowingHome || !model.canGoForward)
            .help("앞으로")
            .accessibilityLabel("앞으로 가기")

            Button {
                if model.isLoading { model.stopLoading() } else { model.reload() }
            } label: {
                Image(systemName: model.isLoading ? "xmark" : "arrow.clockwise")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .disabled(model.isShowingHome || model.webView == nil)
            .help(model.isLoading ? "불러오기 중지" : "새로 고침")
            .accessibilityLabel(model.isLoading ? "불러오기 중지" : "새로 고침")

            Button { model.goHome(); appModel.requestAddressFocus(for: model) } label: {
                Image(systemName: "house")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help("시작 화면으로 이동")
            .accessibilityLabel("시작 화면으로 이동")

            Button(action: toggleBookmark) {
                Image(systemName: isCurrentURLBookmarked ? "star.fill" : "star")
                    .foregroundColor(isCurrentURLBookmarked ? .yellow : palette.textColor)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .disabled(model.isShowingHome || model.currentURL == nil)
            .help(isCurrentURLBookmarked ? "즐겨찾기 해제" : "현재 페이지를 즐겨찾기에 추가")
            .accessibilityLabel(isCurrentURLBookmarked ? "즐겨찾기 해제" : "현재 페이지를 즐겨찾기에 추가")
        }
        .foregroundColor(palette.textColor)
    }

    private var addressBarGroup: some View {
        HStack(spacing: 4) {
            TextField("주소, 검색, 명령어", text: $model.address)
                .textFieldStyle(.roundedBorder)
                .focused($addressFocused)
                .onSubmit { submitAddressField() }
                .onChange(of: model.address) { _, newValue in
                    pickerSelection = 0
                    if !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       model.notice == "클립보드에 주소가 없습니다." {
                        model.notice = nil
                    }
                    if !addressFocused { pickerSuppressedText = newValue }
                }
                .onChange(of: addressFocused) { _, focused in
                    fieldFocused = focused
                    if focused { pickerSuppressedText = model.address }
                }
                .onChange(of: model.currentURL) { _, _ in pickerSuppressedText = model.address }
                .onChange(of: model.isShowingHome) { _, _ in pickerSuppressedText = model.address }
                .onAppear { installPickerKeyMonitor(); consumeAddressFocusRequest() }
                .onDisappear { removePickerKeyMonitor() }
                .onChange(of: appModel.addressFocusRequest) { _, _ in consumeAddressFocusRequest() }
                .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in consumeAddressFocusRequest() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in consumeAddressFocusRequest() }
                .overlay(alignment: .topLeading) {
                    if slashListVisible {
                        AddressSlashPicker(choices: slashChoices,
                                           selection: $pickerSelection,
                                           onHover: { pickerHovering = $0 },
                                           onChoose: { chooseSlash($0) })
                            .offset(y: 28)
                            .frame(maxWidth: 420)
                    } else if addressPickerVisible {
                        AddressSearchPicker(query: pickerQuery ?? "",
                                            selection: $pickerSelection,
                                            onHover: { pickerHovering = $0 },
                                            onChoose: { chooseSearch($0) })
                            .offset(y: 28)
                            .frame(maxWidth: 420)
                    }
                }
                .accessibilityLabel("사이트 주소")

            Button("열기") { submitAddressField() }
                .buttonStyle(.bkProminent)
                .controlSize(.small)
                .highPriorityGesture(
                    LongPressGesture(minimumDuration: 0.5)
                        .exclusively(before: TapGesture())
                        .onEnded { result in
                            switch result {
                            case .first(true):
                                model.address = ""
                                let pasted = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                                if pasted.isEmpty {
                                    model.notice = "클립보드에 주소가 없습니다."
                                } else {
                                    model.address = pasted
                                    pickerSelection = 0   // a pasted search phrase goes straight to the default engine
                                    runAddressCommand()
                                }
                            case .second:
                                submitAddressField()
                            default:
                                break
                            }
                        }
                )
                .help("짧게 누르면 주소 열기, 길게 누르면 클립보드 주소 붙여 넣고 바로 열기")
                .accessibilityLabel("주소 열기")
                .accessibilityHint("짧게 누르면 주소 열기, 길게 누르면 클립보드 주소 붙여 넣고 바로 열기")

            siteRouteControl
        }
        .frame(minWidth: 160, maxWidth: .infinity)
    }

    private var addressCommand: AddressCommand {
        AddressCommandResolver.resolve(model.address, store: addressStore)
    }

    /// The search words while the field text is an ordinary search (the Google / 네이버 / YouTube choice).
    private var pickerQuery: String? {
        if case .pickEngine(let query) = addressCommand { return query }
        return nil
    }

    private var addressPickerVisible: Bool {
        guard fieldFocused || pickerHovering else { return false }
        return model.address != pickerSuppressedText && pickerQuery != nil && slashChoices.isEmpty
    }

    /// Rows of the `/` command list for the current field text (empty when the text is not a `/` prefix).
    private var slashChoices: [SlashChoice] {
        AddressCommandResolver.slashChoices(model.address, store: addressStore)
    }

    private var slashListVisible: Bool {
        guard fieldFocused || pickerHovering else { return false }
        return model.address != pickerSuppressedText && !slashChoices.isEmpty
    }

    /// Writes the chosen name and a space into the field and keeps typing there; nothing is opened yet.
    private func chooseSlash(_ index: Int) {
        let choices = slashChoices
        guard choices.indices.contains(index) else { return }
        pickerHovering = false
        pickerSelection = 0
        model.address = choices[index].insertion
        pickerSuppressedText = model.address
        addressFocused = true
    }

    private func submitAddressField() {
        runAddressCommand()
    }

    /// Enter / 열기: a web address opens as before; a known name, `이름 검색어` or a route command is carried out;
    /// ordinary search words go to the highlighted engine; empty input does nothing.
    private func runAddressCommand() {
        let rawInput = model.address.trimmingCharacters(in: .whitespacesAndNewlines)
        let aliases = ["플래너", "플레너", "플래너에게", "플레너에게"]
        var matchedAlias: String? = nil
        var remainder = ""

        for alias in aliases {
            if rawInput == alias {
                matchedAlias = alias
                remainder = ""
                break
            } else if rawInput.hasPrefix(alias + ":") {
                matchedAlias = alias
                remainder = String(rawInput.dropFirst(alias.count + 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            } else if rawInput.hasPrefix(alias + " ") {
                matchedAlias = alias
                remainder = String(rawInput.dropFirst(alias.count + 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }

        if let _ = matchedAlias {
            finishAddressEntry()
            model.address = model.currentURL?.absoluteString ?? ""

            appModel.selectedTab = .saw
            let workspace = appModel.sawWorkspace
            workspace.ensureUsableContext()

            guard let projectID = workspace.selectedProjectID else { return }
            let session = workspace.session(for: projectID)

            if remainder.isEmpty {
                session.showingPlannerSurface = true
                return
            }

            if session.runStatus == "running" {
                session.sendUserMessage(remainder)
            } else if session.runStatus == "queued" && (session.project?.goal.isEmpty ?? true) {
                session.startRun(goal: remainder)
            } else {
                let lines = remainder.components(separatedBy: "\n")
                let firstLine = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "새 프로젝트"
                let title = String(firstLine.prefix(40))
                let newProject = workspace.createProject(title: title, goal: remainder)
                workspace.selectProject(newProject.id)
                let newSession = workspace.session(for: newProject.id)
                newSession.startRun(goal: remainder)
            }
            return
        }

        if !slashChoices.isEmpty {   // a `/` list is showing: Enter picks a row, it is never a search for "/…"
            chooseSlash(pickerSelection)
            return
        }
        switch addressCommand {
        case .empty:
            break
        case .open(let text):
            model.open(text)
        case .openURL(let url):
            finishAddressEntry()
            model.open(url.absoluteString)
        case .openAI:
            if let ps = plannerSession {
                finishAddressEntry()
                model.address = model.isShowingHome ? "" : (model.currentURL?.absoluteString ?? "")
                ps.showingPlannerSurface = true
                return
            }
            finishAddressEntry()
            model.address = model.isShowingHome ? "" : (model.currentURL?.absoluteString ?? "")
            appModel.temporaryShowHanaPanel = false
            if appModel.aiServices.enabledServices.isEmpty {
                appModel.selectedTab = .ai
                model.notice = "상단 비서 메뉴 > 설정에서 사용할 AI를 켜 주세요."
            } else {
                appModel.setAIPanelOpen(true)
            }
        case .hana(let question, let fresh):
            if let ps = plannerSession {
                ps.composerDraft = question
                ps.showingPlannerSurface = true
                finishAddressEntry()
                return
            }
            model.address = model.isShowingHome ? "" : (model.currentURL?.absoluteString ?? "")
            finishAddressEntry()
            appModel.temporaryShowHanaPanel = true
            if appModel.aiServices.selectedService.isHana {
                appModel.setAIPanelOpen(true)
                HanaPanelHost.shared.submitAddressCommand(question: question, fresh: fresh)
            } else {
                appModel.setAIPanelOpen(true)
                HanaPanelHost.shared.submitAddressCommand(question: question, fresh: fresh)
                model.notice = "하나 전용 질문이므로 하나 대화창으로 연결했습니다. (현재 기본 AI: \(appModel.aiServices.selectedService.name))"
            }
        case .hanaWindow:
            model.address = model.isShowingHome ? "" : (model.currentURL?.absoluteString ?? "")
            finishAddressEntry()
            openExternalHanaWindow()
        case .route(let request):
            finishAddressEntry()
            addressFlow.start(request, owner: model, appModel: appModel)
        case .pickEngine:
            chooseSearch(pickerSelection)
        case .invalid(let message):
            model.notice = message
        }
    }

    private func finishAddressEntry() {
        pickerSuppressedText = model.address
        pickerHovering = false
        addressFocused = false
    }

    private func openExternalHanaWindow() {
        var components = URLComponents()
        components.scheme = "x-alfred-playground"
        components.host = "ask"
        components.queryItems = [URLQueryItem(name: "text", value: "")]
        guard let url = components.url else {
            model.notice = "하나 외부 창 주소를 생성할 수 없습니다."
            return
        }
        guard NSWorkspace.shared.urlForApplication(toOpen: url) != nil else {
            model.notice = "하나 전용 창 앱이 설치되어 있지 않거나 연결 프로그램을 찾을 수 없습니다."
            return
        }
        if !NSWorkspace.shared.open(url) {
            model.notice = "하나 전용 창을 열지 못했습니다."
        }
    }

    private func chooseSearch(_ index: Int) {
        let engines = SearchEngine.allCases
        guard engines.indices.contains(index), let query = pickerQuery,
              let url = engines[index].url(for: query, store: addressStore) else { return }
        finishAddressEntry()
        model.open(url.absoluteString)
    }

    /// Arrow / Return / Esc for the picker. Runs before the field editor, so keys that belong to an IME
    /// composition (marked text) are left alone.
    private func installPickerKeyMonitor() {
        guard pickerKeyMonitor == nil else { return }
        pickerKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard isPaneActive else { return event }
            guard slashListVisible || addressPickerVisible, fieldFocused,
                  let window = event.window, window === NSApp.keyWindow,
                  let editor = window.firstResponder as? NSTextView, editor.isFieldEditor,
                  !editor.hasMarkedText(),
                  event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return event }
            let slash = slashListVisible
            let count = slash ? slashChoices.count : SearchEngine.allCases.count
            switch event.keyCode {
            case 126: pickerSelection = (pickerSelection + count - 1) % count; return nil
            case 125: pickerSelection = (pickerSelection + 1) % count; return nil
            case 36, 76:
                if slash { chooseSlash(pickerSelection) } else { chooseSearch(pickerSelection) }
                return nil
            case 53:
                pickerSuppressedText = model.address
                return nil
            default: return event
            }
        }
    }

    /// Focus the address field once, after the view is attached. A request for a newly created tab applies even when
    /// a custom start page loads; a revisit applies only to an empty built-in home. The deferred focus is dropped if
    /// the tab changed, a newer navigation began (logical attempt differs), the field was focused, or another text
    /// editor owns the keyboard. While the app/window is not active the request stays pending and is retried when
    /// the app or window becomes active/key (no polling); metadata or URL changes never create a request.
    private func consumeAddressFocusRequest() {
        guard isPaneActive else { return }
        guard let request = appModel.addressFocusRequest, request.tabID == model.tabID else { return }
        guard NSApp.isActive, NSApp.keyWindow != nil else { return }
        // A retained window can keep FocusState true after its native editor lost focus.
        // Only an explicit browser-open request resets it before the existing deferred focus.
        if request.isExplicit { addressFocused = false }
        DispatchQueue.main.async {
            guard isPaneActive else { return }
            guard NSApp.isActive, let window = NSApp.keyWindow else { return }
            guard appModel.addressFocusRequest == request else { return }
            appModel.clearAddressFocusRequest()
            let canFocus = request.isExplicit || request.isNewTab || (model.isShowingHome && model.address.isEmpty)
            let textPass = request.isExplicit || !(window.firstResponder is NSTextView)
            guard isPaneActive, model.tabID == request.tabID,
                  request.attemptId == nil || request.attemptId == model.logicalAttemptId,
                  canFocus, !addressFocused, textPass else { return }
            addressFocused = true
        }
    }

    private func removePickerKeyMonitor() {
        if let m = pickerKeyMonitor { NSEvent.removeMonitor(m) }
        pickerKeyMonitor = nil
    }

    /// Per-site "HTTPS 연결 도움" for the page this tab shows. Clicking sets an explicit on/off for this exact host
    /// (opposite of what the page uses now); the menu can also clear the choice (back to the global default).
    private var siteRouteControl: some View {
        let host = model.routeSubjectHost
        let routable = host.map { SiteRouteRules.isRoutable(host: $0) } ?? false
        let choice = siteRoutes.choice(forHost: host)
        let pageRoute = model.viewRoute
        let effective = choice?.route ?? pageRoute
        let waiting = choice != nil && choice?.route != pageRoute
        let inherited = choice == nil && pageRoute != appModel.defaultRoute
        return Menu {
            if let host {
                Text("사이트: \(host)")
                Text(choice == nil ? "저장된 설정 없음 (기본값: 연결 도움 \(appModel.defaultRoute == .assist ? "켜짐" : "꺼짐"))"
                     : "저장된 설정: 연결 도움 \(choice == .on ? "켜짐" : "꺼짐")")
                Text("이 탭의 연결: \(pageRoute.label)\(inherited ? " (열어 준 페이지에서 이어받음, 저장되지 않음)" : "")\(waiting ? " — 설정은 다음 이동부터 적용" : "")")
                Divider()
            }
            Button(choice == .on ? "✓ 이 사이트는 연결 도움 켜기" : "이 사이트는 연결 도움 켜기") { model.setSiteRoute(.on) }
            Button(choice == .off ? "✓ 이 사이트는 연결 도움 끄기" : "이 사이트는 연결 도움 끄기") { model.setSiteRoute(.off) }
            Button("설정 지우기 (기본값 따르기)") { model.setSiteRoute(nil) }
                .disabled(choice == nil)
            if pageRoute == .assist, !connection.enabled, browsingConnection.isFailed {
                Divider()
                Button("이 사이트용 연결 도움 다시 시작") { appModel.restartBrowsingAssist() }
            }
        } label: {
            Image(systemName: effective == .assist ? "network.badge.shield.half.filled" : "network")
                .foregroundColor(waiting ? palette.warnColor : (effective == .assist ? Color.green : palette.textColor))
                .frame(width: 22, height: 22)
        } primaryAction: {
            model.setSiteRoute(effective == .assist ? .off : .on)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(host == nil || !routable)
        .help(host == nil ? "열린 페이지가 없습니다."
              : !routable ? "IP 주소, localhost, 내부망 주소에는 사이트별 연결 설정을 쓸 수 없습니다."
              : "이 사이트(\(host ?? ""))만 HTTPS 연결 도움을 \(effective == .assist ? "끄려면" : "켜려면") 누르세요. 현재: \(effective == .assist ? "켜짐" : "꺼짐")")
        .accessibilityLabel("이 사이트의 HTTPS 연결 도움: \(effective == .assist ? "켜짐" : "꺼짐")")
    }

    private var primaryActionGroup: some View {
        HStack(spacing: 6) {
            Menu {
                Button {
                    BrowserScreenshotManager.shared.captureVisibleArea(appModel: appModel, model: model)
                } label: {
                    Label("영역 캡처", systemImage: "camera")
                }
                .disabled(model.isShowingHome || model.webView == nil || screenshotManager.isCapturing)

                Button {
                    BrowserScreenshotManager.shared.captureFullPage(appModel: appModel, model: model)
                } label: {
                    Label("전체 페이지 스크롤 캡처", systemImage: "doc.viewfinder")
                }
                .disabled(model.isShowingHome || model.webView == nil || screenshotManager.isCapturing)
            } label: {
                Image(systemName: "camera")
                    .frame(width: 22, height: 22)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(model.isShowingHome || model.webView == nil)
            .help("화면 캡처")
            .accessibilityLabel("화면 캡처")

            ExtensionActionButton(manager: extensions)
                .fixedSize()
                .foregroundStyle(palette.textColor)

            Button(action: {
                appModel.isMediaCandidatePresented.toggle()
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down.circle")
                    Text("페이지 영상")
                    if !model.candidates.isEmpty {
                        Text("\(model.candidates.count)")
                            .font(.caption2.bold())
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(palette.accentSoftColor))
                            .foregroundColor(palette.accentColor)
                    }
                }
                .foregroundStyle(palette.textColor)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .help("현재 페이지의 영상 후보 목록을 확인합니다. 링크를 끌어다 놓아 바로 다운로드할 수도 있습니다.")
            .accessibilityLabel("현재 페이지의 영상 목록 확인 (링크 끌어다 놓기 지원)")
            .urlDropTarget(appModel: appModel)
            .popover(isPresented: $appModel.isMediaCandidatePresented, arrowEdge: .bottom) {
                MediaCandidatePanel(appModel: appModel, model: appModel.browser) {
                    appModel.isMediaCandidatePresented = false
                }
                .frame(width: 350, height: 460)
                .id(appModel.browser.tabID)
            }
        }
    }

    private var secondaryOverflowMenu: some View {
        Menu {
            Menu {
                Button {
                    model.showBuiltInHome()
                } label: {
                    Label("시작 화면 열기", systemImage: "house")
                }
                Button(action: toggleBookmark) {
                    Label(isCurrentURLBookmarked ? "즐겨찾기 해제" : "현재 페이지 즐겨찾기 추가",
                          systemImage: isCurrentURLBookmarked ? "star.fill" : "star")
                }
                .disabled(model.isShowingHome || model.currentURL == nil)
                Divider()
                if preferences.bookmarks.isEmpty {
                    Text("저장된 즐겨찾기 없음")
                } else {
                    ForEach(preferences.categories) { cat in
                        let items = preferences.bookmarks.filter { $0.categoryID == cat.id }
                        if !items.isEmpty {
                            Menu(cat.name) {
                                ForEach(items) { item in
                                    Button(item.title) { model.open(item.url) }
                                }
                            }
                        }
                    }
                    let uncategorized = preferences.bookmarks.filter { $0.categoryID == nil }
                    if !uncategorized.isEmpty {
                        Menu("미분류") {
                            ForEach(uncategorized) { item in
                                Button(item.title) { model.open(item.url) }
                            }
                        }
                    }
                }
            } label: {
                Label("즐겨찾기", systemImage: "bookmark")
            }

            Button {
                if let ps = plannerSession {
                    ps.showingPlannerSurface.toggle()
                } else {
                    appModel.toggleAIPanel()
                }
            } label: {
                let name = appModel.aiServices.selectedService.name
                Label(appModel.isAIPanelOpen ? "AI (\(name)) 대화창 닫기" : "AI (\(name)) 대화창 열기", systemImage: "sparkles")
            }

            Divider()

            Button {
                showGoogleAutofill = true
            } label: {
                Label("Google 계정 자동 입력 설정…", systemImage: "key")
            }

            Button {
                showSiteCredentialSheet = true
            } label: {
                Label("사이트별 로그인 계정 관리…", systemImage: "person.badge.key")
            }

            Divider()

            Menu {
                Text("확장 상태: \(extensions.statusText)")
                if !extensions.issues.isEmpty {
                    Text("확장 문제: \(extensions.issues.prefix(2).joined(separator: ", "))")
                }
                Divider()
                if extensions.isSupported {
                    if extensions.isConnected {
                        Button("업데이트 다시 불러오기") { extensions.reload() }
                        Button(extensions.isEnabled ? "연결 끄기" : "연결 켜기") {
                            extensions.setEnabled(!extensions.isEnabled)
                        }
                    } else if extensions.registeredAppPath != nil {
                        Button("업데이트 다시 불러오기") { extensions.reload() }
                            .disabled(extensions.status == .loading)
                        Button(extensions.isEnabled ? "연결 끄기" : "연결 켜기") {
                            extensions.setEnabled(!extensions.isEnabled)
                        }
                    }
                    if !extensions.isInsideHTT {
                        Button("한툴 번역 확장 연결…") { extensions.chooseAppAndConnect() }
                            .disabled(extensions.status == .loading)
                        if extensions.installedAppAvailable {
                            Button("설치된 한툴 연결 (\(BrowserExtensionManager.installedAppPath))") {
                                extensions.connectInstalledApp()
                            }
                            .disabled(extensions.status == .loading)
                        }
                    }
                    if extensions.registeredAppPath != nil && !extensions.isInsideHTT {
                        Divider()
                        Button("확장 등록 제거") { extensions.removeRegistration() }
                    }
                }
            } label: {
                Label("번역 확장 설정 및 진단", systemImage: "character.bubble")
            }

            Divider()

            Toggle(isOn: Binding(
                get: { appModel.preferences.mouseGesturesEnabled },
                set: { appModel.preferences.setMouseGesturesEnabled($0) }
            )) {
                Label("마우스 제스처", systemImage: "hand.draw")
            }

            Toggle(isOn: Binding(
                get: { appModel.preferences.autoRetryTLS },
                set: { appModel.setBrowserAutoRetryTLS($0) }
            )) {
                Label("HTTPS 첫 연결 자동 재시도 (켬 기본)", systemImage: "arrow.triangle.2.circlepath")
            }
            .help("기본으로 켜져 있습니다. 연결 도움 안에서만 동작하며, 나눠 보낸 첫 TLS 메시지에 서버가 아무 응답 없이 연결만 끊으면, 같은 서버 주소로 나누지 않은 같은 메시지를 한 번만 다시 보냅니다. 사이트별 연결 선택은 바꾸지 않으며, 요청·로그인 정보는 다시 보내지 않습니다.")
            Text("나눠 보내기 연결에만 적용 · 사이트별 연결 선택은 그대로")

            if AutoShorts.isBundledInHTT {
                Toggle(isOn: $autoShortsEnabled) {
                    Label("YouTube 쇼츠 자동 넘김", systemImage: "film")
                }
                .onChange(of: autoShortsEnabled) { enabled in
                    for tab in appModel.tabs where AutoShorts.isShortsURL(tab.webView?.url) || AutoShorts.isYouTubeHost(tab.webView?.url?.host) {
                        tab.webView?.evaluateJavaScript("window.__htdAutoShorts?.setEnabled(\(enabled));", completionHandler: nil)
                    }
                }
            }

            Button {
                showingCacheSettings = true
            } label: {
                Label("캐시 정리…", systemImage: "externaldrive.badge.xmark")
            }

            Button {
                showingPopupSettings = true
            } label: {
                Label("팝업·리디렉션…", systemImage: "rectangle.on.rectangle.slash")
            }

            Button {
                showingAdManagement = true
            } label: {
                Label("광고 차단 관리…", systemImage: "shield.lefthalf.filled")
            }

            Button {
                showingHomeSettings = true
            } label: {
                Label("시작 페이지 설정…", systemImage: "gearshape")
            }

            Divider()

            // Login continuity snapshots belong to the primary store only (nothing is copied between route stores).
            if model.usesPrimaryStore, let committedURL = model.popupCommittedURL, model.webView?.url == committedURL,
               let scheme = committedURL.scheme?.lowercased(), scheme == "https",
               let host = committedURL.host, !host.isEmpty {
                Toggle(isOn: Binding(
                    get: { session.isLoginContinuityEnabled(forHost: host) },
                    set: { session.setLoginContinuityEnabled($0, forHost: host) }
                )) {
                    Label("앱 재시작 후에도 이 사이트 로그인 유지", systemImage: "arrow.clockwise.circle")
                }
            }

            Button(role: .destructive) {
                appModel.clearLoginSession()
                model.notice = "로그인 세션을 지웠습니다. 주소를 다시 열면 새 세션으로 시작합니다."
            } label: {
                Label("로그인 세션 지우기", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .frame(width: 22, height: 22)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("더보기 (즐겨찾기, Google 자동 입력, 번역 진단, 세션 관리 등)")
        .accessibilityLabel("브라우저 추가 기능 및 설정 더보기")
    }

    @ViewBuilder
    private var pageArea: some View {
        if let wv = model.webView {
            // Keyed by instance: a WebView replaced for a new session is never left showing the old one.
            LoginWebViewRepresentable(webView: wv, nativeInputAllowed: {
                isPaneActive
            })
                .id(ObjectIdentifier(wv))
                .onAppear { keepSystemAppearance(wv) }
                .onChange(of: appearance.systemIsDark) { _, _ in keepSystemAppearance(wv) }
        } else {
            VStack(spacing: 10) {
                if connection.enabled && connection.isStarting {
                    ProgressView().controlSize(.small)
                    Text("연결 도움을 준비하는 중입니다...").foregroundStyle(.secondary)
                } else {
                    Image(systemName: "globe").font(.system(size: 36)).foregroundStyle(.secondary)
                    Text("위 주소창에 사이트 주소를 넣고 '열기'를 누르세요.")
                        .foregroundStyle(.secondary)
                    Text("영상을 재생하면 '이 페이지의 영상' 목록에 나타나고, 'MP4로 저장'으로 받을 수 있습니다.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("로그인은 사이트 화면에서 직접 진행하세요. 로그인 상태는 이 앱 전용 세션으로 보관됩니다. (Google 계정 비밀번호 자동 입력은 더보기 메뉴에서 설정할 수 있습니다.)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding()
        }
    }

    private var bottomStatusBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                if model.isShowingHome {
                    Image(systemName: "house.fill")
                        .foregroundColor(palette.accentColor)
                        .accessibilityLabel("시작 화면")
                    Text("시작 화면")
                        .font(.caption.bold())
                        .lineLimit(1)
                } else if let url = model.currentURL {
                    let secure = url.scheme == "https" && model.secureContent
                    Image(systemName: secure ? "lock.fill" : "lock.open")
                        .foregroundColor(secure ? .green : palette.warnColor)
                        .accessibilityLabel(secure ? "암호화된 연결" : "암호화되지 않은 내용 포함")
                    Text(secure ? "암호화된 연결" : "암호화되지 않은 내용 포함")
                        .font(.caption2.bold())
                        .foregroundColor(secure ? palette.text2Color : palette.warnColor)
                        .lineLimit(1)
                    Text(url.host ?? "")
                        .font(.caption.bold())
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(model.pageTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else {
                    Text("열린 페이지 없음")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .help(pageStatusHelp)
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 8)

            HStack(spacing: 5) {
                Image(systemName: session.isAlive ? "shield.lefthalf.filled" : "shield")
                    .foregroundColor(palette.mutedColor)
                    .accessibilityHidden(true)
                Text(sessionStatusText)
                    .font(.caption2)
                    .foregroundColor(palette.text2Color)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .help(sessionHint)
            .accessibilityLabel("세션 상태: \(sessionStatusText)")
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .frame(height: BrowserView.footerHeight)
    }

    private var pageStatusHelp: String {
        if model.isShowingHome {
            return "시작 화면"
        } else if let url = model.currentURL {
            let secureText = (url.scheme == "https" && model.secureContent) ? "암호화된 연결" : "암호화되지 않은 내용 포함"
            let host = url.host ?? ""
            if model.pageTitle.isEmpty {
                return "\(secureText) - \(host)"
            } else {
                return "\(secureText) - \(host): \(model.pageTitle)"
            }
        } else {
            return "열린 페이지 없음"
        }
    }

    private var sessionStatusText: String {
        session.isAlive
            ? "전용 로그인 세션 활성 (앱 종료 후에도 유지, 이 앱 전용)"
            : "로그인 세션 없음 (사이트 화면에서 직접 로그인 시 보관)"
    }

    private let sessionHint = "이 브라우저의 로그인은 이 앱 전용으로 저장되어 앱을 종료해도 유지되고, '세션 지우기'를 누를 때만 지워집니다. 사파리·크롬 등 다른 브라우저의 로그인 정보는 쓰지 않습니다."

    private func banner(_ text: String, ink: Color, fill: Color) -> some View {
        Text(text)
            .font(.caption)
            .foregroundColor(ink)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(fill)
    }

    /// Refusals of this browser's connections since the current page started loading (not jobs, not older pages).
    private var pageRefusals: [ConnectionManager.BlockedHost] {
        connection.refusals(forClient: ConnectionManager.browserClient, since: model.pageStartedAt)
    }

    private func isSafetyPolicyViolation(_ refusal: ConnectionManager.BlockedHost) -> Bool {
        guard !refusal.canAllow else { return false }
        let c = refusal.code.lowercased()
        if c == "dns_failed" || c == ".dns_failed" || c == "connect_failed" || c == ".connect_failed"
            || c == "networkfailed" || c == "network_failed" || c == "network_error" {
            return false
        }
        return true
    }

    private var currentMainPageHost: String? {
        if let host = model.currentURL?.host?.trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty {
            return host.lowercased()
        }
        let raw = model.address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        let parsed = URL(string: raw) ?? URL(string: "https://" + raw)
        guard let host = parsed?.host?.trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty else {
            return nil
        }
        return host.lowercased()
    }

    private var unallowablePolicyRefusals: [ConnectionManager.BlockedHost] {
        guard let mainHost = currentMainPageHost else { return [] }
        return pageRefusals.filter { refusal in
            isSafetyPolicyViolation(refusal) && refusal.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == mainHost
        }
    }

    private var hasUnallowableRefusals: Bool {
        !unallowablePolicyRefusals.isEmpty
    }

    @ViewBuilder
    private var recoveryPanel: some View {
        if model.recoveryInProgress {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(model.recoveryStatus ?? "추가 주소 연결을 자동으로 적용하고 페이지를 다시 불러오는 중...")
                    .font(.caption)
                    .foregroundColor(palette.textColor)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(palette.accentSoftColor)
        } else if let problem = model.recoveryProblem {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(palette.warnColor)
                Text(problem)
                    .font(.caption)
                    .foregroundColor(palette.warnInkColor)
                    .lineLimit(2)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(palette.warnSoftColor)
        } else if hasUnallowableRefusals {
            let others = unallowablePolicyRefusals
            let reasonText = others.prefix(2).map { "\($0.host): \($0.reason)" }.joined(separator: ", ")
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill").foregroundColor(palette.warnColor)
                Text("한툴 연결 도움의 연결 제한: \(reasonText)")
                    .font(.caption)
                    .foregroundColor(palette.warnInkColor)
                    .lineLimit(2)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(palette.warnSoftColor)
        }
    }
}

/// Side list of video candidates found on the current page.
struct MediaCandidatePanel: View {
    @ObservedObject var appModel: AppModel
    @ObservedObject var model: LoginBrowserModel
    @Environment(\.bkPalette) var palette
    let onClose: () -> Void

    private var ordered: [MediaCandidate] {
        model.candidates.filter { $0.supported } + model.candidates.filter { !$0.supported }
    }

    private var activePageTitle: String {
        if model.isShowingHome || model.webView == nil {
            return "시작 화면 (웹페이지 없음)"
        }
        return model.pageTitle.isEmpty ? (model.currentURL?.host ?? "웹 페이지") : model.pageTitle
    }

    private var activePageURLString: String {
        if model.isShowingHome || model.webView == nil {
            return "한툴 시작 화면"
        }
        return model.currentURL?.absoluteString ?? ""
    }

    /// Shown while the only clue is a player hint (no address yet): searching vs. manual next step, never a failure.
    private var waitingNote: some View {
        let searching = model.discoveryPhase == .searching
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if searching { ProgressView().controlSize(.small) }
                Text(searching ? "영상 주소를 찾는 중입니다..." : "아직 받을 수 있는 주소를 찾지 못했습니다.")
                    .font(.caption.bold())
            }
            Text(searching
                 ? "플레이어를 재생하면 목록이 자동으로 갱신됩니다. 준비에 시간이 걸릴 수 있습니다."
                 : "재생 후 '다시 찾기'(위 버튼)를 누르거나 위 '영상 찾아받기'를 눌러 보세요. 재생하면 목록은 계속 자동 갱신됩니다.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header: Title, URL, and Close Button
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(activePageTitle)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(palette.textColor)
                        .lineLimit(1)
                    Text(activePageURLString)
                        .font(.system(size: 11))
                        .foregroundColor(palette.mutedColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(palette.mutedColor)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("닫기 (Esc)")
                .accessibilityLabel("후보 패널 닫기")
            }
            .padding(10)

            Divider()

            // Actions row: analyze, save all, rescan
            HStack(spacing: 6) {
                Button("영상 찾아받기") { model.analyzePage() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(model.isShowingHome || model.currentURL == nil || !["http", "https"].contains(model.currentURL?.scheme?.lowercased() ?? ""))
                    .help("이 페이지 전체를 분석한 뒤 기본 화질로 바로 다운로드합니다. 목록에 영상이 없을 때 써 보세요. 진행은 다운로드 > 진행 중 화면에서 봅니다.")
                    .accessibilityLabel("현재 페이지를 분석해 즉시 다운로드 시작")

                Spacer()

                Button("전체를 다운로드로 보내기") { model.saveAllCandidates() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(model.webView == nil || model.isShowingHome || model.bulkSendableCandidates.isEmpty)
                    .help("지원되는 현재 목록의 영상을 하나씩 '대기열'로 보냅니다. 이미 추가한 영상과 받을 수 없는 항목은 제외됩니다.")
                    .accessibilityLabel("현재 목록의 영상을 모두 다운로드로 보내기")

                Button { model.rescan() } label: { Image(systemName: "arrow.triangle.2.circlepath") }
                    .buttonStyle(.borderless)
                    .disabled(model.webView == nil || model.isShowingHome)
                    .help("목록을 비우고 다시 찾기")
                    .accessibilityLabel("영상 목록 다시 찾기")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider()

            if model.isShowingHome || model.webView == nil || model.currentURL == nil {
                VStack(spacing: 10) {
                    Image(systemName: "house")
                        .font(.system(size: 28))
                        .foregroundColor(palette.mutedColor)
                    Text("현재 화면은 웹페이지가 아닙니다.")
                        .font(.subheadline.bold())
                        .foregroundColor(palette.textColor)
                    Text("웹페이지를 탐색 중일 때 이 화면에서 영상 후보를 확인하고 다운로드할 수 있습니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    HStack(spacing: 8) {
                        Button("주소창으로 이동") {
                            onClose()
                            appModel.requestAddressFocus(for: model, isExplicit: true)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)

                        Button("다운로드 관리 이동") {
                            onClose()
                            UnifiedNavigationModel.shared.navigateTo(
                                destination: .downloads,
                                appModel: appModel,
                                selectTool: { _ in },
                                clearTool: {}
                            )
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(16)
            } else {
                if let problem = model.discoveryProblem {
                    Text(problem).font(.caption).foregroundColor(palette.warnColor).padding(10)
                }
                if model.candidates.isEmpty {
                    VStack(spacing: 8) {
                        if model.isLoading {
                            ProgressView().controlSize(.small)
                            Text("페이지를 불러오는 중입니다...").font(.caption).foregroundStyle(.secondary)
                        } else if model.discoveryPhase == .searching {
                            ProgressView().controlSize(.small)
                            Text("영상 주소를 찾는 중입니다...").font(.caption).foregroundStyle(.secondary)
                            Text("플레이어를 재생하면 목록이 자동으로 갱신됩니다. 준비에 시간이 걸릴 수 있습니다.")
                                .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        } else {
                            Image(systemName: "film").font(.system(size: 26)).foregroundStyle(.secondary)
                            Text("아직 받을 수 있는 영상 주소를 찾지 못했습니다.")
                                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            Text("영상을 재생하면 목록이 자동으로 갱신됩니다. 재생 후 '다시 찾기'(위 버튼)를 누르거나 위 '영상 찾아받기'를 눌러 보세요.")
                                .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(10)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            if !model.candidates.contains(where: { $0.supported }) {
                                waitingNote
                            }
                            ForEach(ordered) { c in
                                MediaCandidateRow(candidate: c, appModel: appModel, model: model)
                            }
                        }
                        .padding(10)
                    }
                }
            }

            Divider()
            Text("목록은 페이지에서 찾은 영상 주소 '후보'입니다. 실제로 받을 수 있는지는 받은 뒤 파일을 검사해 확인하고, 항상 MP4로 저장합니다. DRM으로 보호된 영상은 받을 수 없습니다.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
        }
        .frame(minWidth: 340, maxWidth: 360)
    }
}

struct MediaCandidateRow: View {
    let candidate: MediaCandidate
    @ObservedObject var appModel: AppModel
    @ObservedObject var model: LoginBrowserModel
    @Environment(\.bkPalette) var palette

    private var queuedJob: JobRecord? {
        guard let id = model.queuedJobs[candidate.id] else { return nil }
        return appModel.jobs.first { $0.id == id }
    }

    /// A player hint without an address stays neutral ("찾는 중" → "주소 미확인"); it is never labelled as a failure.
    private var typeText: String {
        guard candidate.kind == .blob, model.discoveryPhase == .settled else { return candidate.typeLabel }
        return "주소 미확인"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(candidate.title).font(.caption.bold()).lineLimit(2)
            HStack(spacing: 5) {
                Text(typeText)
                    .font(.caption2.bold())
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(candidate.supported ? palette.accentSoftColor : palette.surface2Color))
                    .foregroundColor(candidate.supported ? palette.accentColor : palette.text2Color)
                Text(candidate.frameLabel).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(candidate.displaySource).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            if candidate.supported {
                if candidate.kind == .hls || candidate.kind == .dash {
                    Text("화질이 여러 개면 '대기열'에서 고릅니다.").font(.caption2).foregroundStyle(.secondary)
                }
                HStack {
                    if let job = queuedJob {
                        StateBadgeView(state: job.state)
                    }
                    Spacer()
                    Button(queuedJob == nil ? "MP4로 저장" : "대기열 보기") {
                        if queuedJob == nil { model.saveCandidate(candidate) } else { appModel.selectedTab = .queue }
                    }
                    .buttonStyle(.bkProminent)
                    .controlSize(.small)
                    .accessibilityLabel(queuedJob == nil ? "\(candidate.title) MP4로 저장" : "대기열에서 진행 상황 보기")
                }
            } else {
                Text(model.discoveryPhase == .searching
                     ? "플레이어가 준비되는 중입니다. 재생하면 받을 수 있는 주소가 목록에 자동으로 추가됩니다."
                     : "이 플레이어에서 받을 수 있는 주소는 아직 찾지 못했습니다. 재생 후 '다시 찾기'나 '현재 페이지 분석'을 써 보세요.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(palette.surfaceColor))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.borderColor, lineWidth: 1))
    }
}

/// Cache cleanup settings, reusing the same section as the main Settings screen.
struct BrowserCacheSettingsSheet: View {
    @ObservedObject var appModel: AppModel
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    CacheSettingsSection(appModel: appModel)
                }
                .padding(20)
            }
            Divider()
            HStack {
                Spacer()
                Button("닫기", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 360, idealHeight: 420)
    }
}

/// Popup/redirect site permissions, reusing the same section as the main Settings screen.
struct BrowserPopupSettingsSheet: View {
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    PopupSitePermissionsSection()
                }
                .padding(20)
            }
            Divider()
            HStack {
                Spacer()
                Button("닫기", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 400, idealHeight: 480)
    }
}

/// 광고 차단 관리: global status, this tab's effective stage, built-in domain rule count, and the saved hide rules.
/// Lists only host names, counts and a sanitized selector summary (never page URLs/hashes/titles).
struct BrowserAdManagementSheet: View {
    @ObservedObject var appModel: AppModel
    @ObservedObject var model: LoginBrowserModel
    @ObservedObject var preferences: BrowserPreferences
    @ObservedObject private var screenshotManager = BrowserScreenshotManager.shared
    @Environment(\.bkPalette) private var palette
    var onClose: () -> Void

    private enum ClearTarget: Identifiable {
        case host(String)
        case legacy(String)
        var id: String {
            switch self {
            case .host(let h): return "h:" + h
            case .legacy(let k): return "k:" + k
            }
        }
    }

    @State private var pendingClear: ClearTarget?
    @State private var resultText: String?

    private var busy: Bool { screenshotManager.captureStatus != nil }
    private var currentHost: String? { BrowserPreferences.adHideSiteHost(model.webView?.url) }
    private var currentKey: String? { BrowserPreferences.adHidePageKey(model.webView?.url) }

    private var sortedSites: [AdHideSiteRule] { preferences.adHideSiteRules.sorted { $0.host < $1.host } }
    private var sortedPages: [AdHideRule] {
        preferences.adHideRules.sorted { $0.updatedAt != $1.updatedAt ? $0.updatedAt > $1.updatedAt : $0.key < $1.key }
    }

    private var tabStatus: (title: String, why: String) {
        let blocker = BrowserAdBlocker.shared
        if !preferences.adBlockingEnabled {
            return ("꺼짐", "전역 광고 차단 스위치가 꺼져 있어 모든 탭에 적용되지 않습니다.")
        }
        switch model.effectiveAdBlockMode {
        case .full:
            if blocker.isSettled(.full), blocker.compiledList(.full) == nil {
                return ("기본(정상)", "기본 규칙 목록을 불러오지 못해 지금은 도메인 차단이 적용되지 않습니다.")
            }
            return ("기본(정상)", "이 탭은 내장 서드파티 도메인 규칙 전체를 사용합니다.")
        case .reduced:
            return ("축소", "이 탭의 현재 사이트에서 광고 차단 감지 안내가 확인되어, 감지에 자주 쓰이는 도메인 규칙만 이 탭에서 임시로 뺐습니다. 사이트를 벗어나면 기본으로 돌아옵니다.")
        case .off:
            return ("이 탭에서 꺼짐", "이 탭의 현재 사이트에서 광고 차단 해제 요청이 계속 확인되어 이 탭에서만 도메인 규칙을 껐습니다. 전역 설정은 바뀌지 않으며 사이트를 벗어나면 기본으로 돌아옵니다.")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    statusSection
                    Divider()
                    hideRulesSection
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                if let resultText = resultText {
                    Text(resultText).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button("닫기", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(minWidth: 520, idealWidth: 580, maxWidth: 720, minHeight: 400, idealHeight: 520, maxHeight: 680)
        .confirmationDialog(
            clearTitle,
            isPresented: Binding(get: { pendingClear != nil }, set: { if !$0 { pendingClear = nil } }),
            titleVisibility: .visible,
            presenting: pendingClear
        ) { target in
            Button("모두 삭제", role: .destructive) { clear(target) }
            Button("취소", role: .cancel) {}
        } message: { _ in
            Text("삭제하면 열려 있는 탭에서 해당 요소가 다시 보입니다.")
        }
    }

    private var clearTitle: String {
        switch pendingClear {
        case .host(let h): return "\(h)의 숨김 규칙을 모두 삭제할까요?"
        case .legacy: return "이 이전 페이지 규칙을 모두 삭제할까요?"
        case nil: return ""
        }
    }

    private var statusSection: some View {
        let status = tabStatus
        return VStack(alignment: .leading, spacing: 8) {
            Text("광고 차단 상태").font(.headline)
            row("전역 광고 차단", preferences.adBlockingEnabled ? "켜짐" : "꺼짐")
            row("현재 탭", model.isShowingHome ? "시작 화면 (페이지 없음) · \(status.title)" : status.title)
            Text(status.why).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            row("내장 도메인 규칙", "서드파티 광고 도메인 \(BrowserAdBlocker.adDomains.count)개 (축소 단계 \(BrowserAdBlocker.reducedAdDomains.count)개)")
            Text("목록에 있는 도메인으로의 서드파티 연결만 막습니다. 모든 광고나 추적을 막는다는 뜻은 아닙니다.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
            Text(value).fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
    }

    private var hideRulesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("직접 숨긴 영역").font(.headline)
            Text("‘광고’ 버튼으로 숨긴 요소입니다. 주소나 페이지 내용은 표시하지 않고 사이트 이름과 요소 모양 요약만 보여 줍니다.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if sortedSites.isEmpty && sortedPages.isEmpty {
                Text("저장된 숨김 규칙이 없습니다.").foregroundStyle(.secondary)
            }
            ForEach(sortedSites, id: \.host) { site in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(site.host).font(.subheadline.weight(.semibold))
                        if site.host == currentHost { badge("현재 탭") }
                        Text("사이트 전체 · \(site.entries.count)개").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("사이트 규칙 모두 삭제", role: .destructive) { pendingClear = .host(site.host) }
                            .controlSize(.small).disabled(busy)
                    }
                    ForEach(site.entries, id: \.selector) { entry in
                        itemRow(summary: Self.selectorSummary(entry.selector),
                                scope: entry.ident == nil || entry.slot != nil ? "이 사이트의 모든 페이지" : "이 사이트의 모든 페이지 · 같은 광고 iframe이 있을 때만") {
                            deleteSiteEntry(host: site.host, selector: entry.selector)
                        }
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(palette.surfaceColor))
            }
            ForEach(Array(sortedPages.enumerated()), id: \.element.key) { index, page in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("이전 페이지 규칙 \(index + 1)").font(.subheadline.weight(.semibold))
                        if page.key == currentKey { badge("현재 페이지") }
                        Text("이전 방식 · 주소를 알 수 없음 · \(page.selectors.count)개").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("규칙 모두 삭제", role: .destructive) { pendingClear = .legacy(page.key) }
                            .controlSize(.small).disabled(busy)
                    }
                    ForEach(page.selectors, id: \.self) { selector in
                        itemRow(summary: Self.selectorSummary(selector), scope: "해당 한 페이지에서만") {
                            deletePageSelector(key: page.key, selector: selector)
                        }
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(palette.surfaceColor))
            }
            if busy {
                Text("화면 캡처 중에는 삭제할 수 없습니다.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text).font(.caption2)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(palette.accentSoftColor))
    }

    private func itemRow(summary: String, scope: String, delete: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text(summary).font(.system(.callout, design: .monospaced)).lineLimit(2)
                Text(scope).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("삭제", role: .destructive, action: delete).controlSize(.small).disabled(busy)
        }
    }

    // MARK: Deletion (saved through the existing preference setters, which roll back on a failed write)

    private func deleteSiteEntry(host: String, selector: String) {
        let current = preferences.adHideSiteEntries(forHost: host)
        guard current.contains(where: { $0.selector == selector }) else { return }
        finish(preferences.setAdHideSiteEntries(current.filter { $0.selector != selector }, forHost: host))
    }

    private func deletePageSelector(key: String, selector: String) {
        let current = preferences.adHideSelectors(forKey: key)
        guard current.contains(selector) else { return }
        finish(preferences.setAdHideSelectors(current.filter { $0 != selector }, forKey: key))
    }

    private func clear(_ target: ClearTarget) {
        switch target {
        case .host(let host): finish(preferences.setAdHideSiteEntries([], forHost: host))
        case .legacy(let key): finish(preferences.setAdHideSelectors([], forKey: key))
        }
        pendingClear = nil
    }

    private func finish(_ saved: Bool) {
        if saved {
            BrowserAdHideManager.shared.refreshAfterRuleChange(tabs: appModel.tabs)
            resultText = "삭제했습니다. 열려 있는 탭에는 남은 규칙만 다시 적용했습니다."
        } else {
            resultText = "저장하지 못해 변경하지 않았습니다."
        }
    }

    /// `tag#id.class` of the element itself plus path depth; names are shortened and long digit runs masked,
    /// so nothing page-specific beyond a generic element shape is shown.
    static func selectorSummary(_ selector: String) -> String {
        let parts = selector.components(separatedBy: " > ")
        var last = parts.last ?? selector
        let positional = last.contains(":nth-of-type")
        if let r = last.range(of: ":") { last = String(last[..<r.lowerBound]) }
        var out = ""
        var token = ""
        func flush() {
            guard !token.isEmpty else { return }
            let masked = token.replacingOccurrences(of: "[0-9]{3,}", with: "#", options: .regularExpression)
            out += masked.count > 24 ? String(masked.prefix(24)) + "…" : masked
            token = ""
        }
        for ch in last {
            if ch == "#" || ch == "." { flush() }
            token.append(ch)
        }
        flush()
        if out.isEmpty { out = "요소" }
        return out + " · 경로 \(parts.count)단계" + (positional ? " · 위치 기준" : "")
    }
}


// MARK: - Address bar search picker

enum SearchEngine: CaseIterable {
    case google, naver, youtube

    var title: String {
        switch self {
        case .google: return "Google"
        case .naver: return "네이버"
        case .youtube: return "YouTube"
        }
    }

    var serviceID: String {
        switch self {
        case .google: return "google"
        case .naver: return "naver"
        case .youtube: return "youtube"
        }
    }

    /// HTTPS search URL from the service's search address in 주소창·검색 settings (built-in address if it is
    /// disabled or invalid); the query is percent-encoded once, as a single value.
    @MainActor func url(for query: String, store: AddressSearchStore) -> URL? {
        AddressTemplate.url(store.pickerTemplate(forServiceID: serviceID), query: query)
    }
}

enum AddressInput {
    enum Kind { case url, search, empty }

    static func searchQuery(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `.url` goes straight to `model.open` (which keeps rejecting non-http(s) schemes); only plain text with no
    /// address shape becomes `.search`. Single everyday words ("뉴스", "apple") are searches, not hosts.
    static func classify(_ text: String) -> Kind {
        let t = searchQuery(text)
        if t.isEmpty { return .empty }
        if t.contains("://") { return .url }          // explicit scheme: never sent to a search engine
        if t.rangeOfCharacter(from: .whitespacesAndNewlines) != nil { return .search }
        if t.contains("@") && t.contains(".") { return .url }   // userinfo-style address: never leak it into a search
        // host[:port][/path?query#fragment]
        let hostPort = String(t.prefix { !"/?#".contains($0) })
        if hostPort.hasPrefix("[") { return hostPort.contains("]") ? .url : .search }   // IPv6 literal
        var host = hostPort
        var hasPort = false
        if let colon = hostPort.lastIndex(of: ":") {
            let port = hostPort[hostPort.index(after: colon)...]
            guard !port.isEmpty, port.allSatisfy({ $0.isASCII && $0.isNumber }) else { return .search }
            host = String(hostPort[..<colon]); hasPort = true
        }
        guard !host.isEmpty else { return .search }
        let lower = host.lowercased()
        if lower == "localhost" { return .url }
        let labels = lower.split(separator: ".", omittingEmptySubsequences: false)
        if labels.count == 4, labels.allSatisfy({ !$0.isEmpty && $0.count <= 3 && $0.allSatisfy { $0.isASCII && $0.isNumber } }) {
            return .url   // IPv4
        }
        if labels.count >= 2,
           labels.allSatisfy({ !$0.isEmpty && !$0.hasPrefix("-") && !$0.hasSuffix("-")
                              && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" } }),
           let tld = labels.last, tld.count >= 2, tld.allSatisfy({ $0.isLetter || $0 == "-" }) {
            return .url
        }
        return hasPort ? .url : .search   // host:port (intranet name, dev server)
    }
}

private struct AddressSearchPicker: View {
    let query: String
    @Binding var selection: Int
    let onHover: (Bool) -> Void
    let onChoose: (Int) -> Void
    @Environment(\.bkPalette) private var palette

    private var shown: String {
        query.split(whereSeparator: { $0.isNewline }).joined(separator: " ")
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(SearchEngine.allCases.enumerated()), id: \.offset) { index, engine in
                HStack(spacing: 8) {
                    icon(engine)
                    Text(label(engine))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundColor(palette.textColor)
                    Spacer(minLength: 4)
                    if index == selection {
                        Image(systemName: "return").font(.caption).foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(index == selection ? palette.accentSoftColor : Color.clear)
                .contentShape(Rectangle())
                .onTapGesture { onChoose(index) }
                .onHover { if $0 { selection = index } }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
            }
        }
        .background(palette.cardColor)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.35), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        .onHover(perform: onHover)
    }

    private func label(_ engine: SearchEngine) -> String {
        switch engine {
        case .google: return "Google에서 '\(shown)' 검색"
        case .naver: return "네이버에서 '\(shown)' 검색"
        case .youtube: return "YouTube에서 '\(shown)' 검색"
        }
    }

    @ViewBuilder private func icon(_ engine: SearchEngine) -> some View {
        let shape = RoundedRectangle(cornerRadius: 4)
        switch engine {
        case .google:
            Text("G").font(.system(size: 13, weight: .bold)).foregroundColor(Color(red: 0.26, green: 0.52, blue: 0.96))
                .frame(width: 20, height: 20).background(shape.fill(Color.white)).overlay(shape.stroke(Color.secondary.opacity(0.3), lineWidth: 0.5))
        case .naver:
            Text("N").font(.system(size: 13, weight: .heavy)).foregroundColor(.white)
                .frame(width: 20, height: 20).background(shape.fill(Color(red: 0.01, green: 0.78, blue: 0.35)))
        case .youtube:
            Image(systemName: "play.fill").font(.system(size: 9)).foregroundColor(.white)
                .frame(width: 20, height: 20).background(shape.fill(Color.red))
        }
    }
}

/// The `/` list under the address field: compact, shows all rows without scrolling.
private struct AddressSlashPicker: View {
    let choices: [SlashChoice]
    @Binding var selection: Int
    let onHover: (Bool) -> Void
    let onChoose: (Int) -> Void
    @Environment(\.bkPalette) private var palette

    private static let rowHeight: CGFloat = 28

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(choices.enumerated()), id: \.element.id) { index, choice in
                HStack(spacing: 8) {
                    Text(choice.name)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundColor(palette.textColor)
                    Text(choice.hint)
                        .font(.caption)
                        .lineLimit(1)
                        .foregroundColor(palette.mutedColor)
                    Spacer(minLength: 4)
                    if index == selection {
                        Image(systemName: "return").font(.caption).foregroundColor(palette.mutedColor)
                    }
                }
                .padding(.horizontal, 8)
                .frame(height: Self.rowHeight)
                .background(index == selection ? palette.accentSoftColor : Color.clear)
                .contentShape(Rectangle())
                .onTapGesture { onChoose(index) }
                .onHover { if $0 { selection = index } }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .id(index)
            }
        }
        .background(palette.cardColor)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(palette.border2Color, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        .onHover(perform: onHover)
    }
}
