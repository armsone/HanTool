import SwiftUI

/// HTT 메인 창의 사이드바 섹션. 모든 기능이 이 한 창 안에서 목적별로 이동한다.
/// 홈, 메일·이미지 번역, 화면 번역, 브라우저 번역, 입력 도우미, Mac 관리, 사용 방법, 앱 설정으로 구성된다.
public enum SettingsSection: Hashable, CaseIterable, Identifiable {
    case home
    case mail
    case screen
    case browser
    case translationSettings
    case input
    case macManagement
    case macManagementSettings
    case cleanUSB
    case serverStatus
    case serverStatusSettings
    case help
    case general

    public var id: Self { self }

    public var title: String {
        switch self {
        case .home: return "홈"
        case .mail: return "메일 번역"
        case .screen: return "화면 번역"
        case .browser: return "번역 확장"
        case .translationSettings: return "번역 설정"
        case .input: return "입력 도우미"
        case .macManagement, .macManagementSettings: return "Mac 관리"
        case .cleanUSB: return "USB 드라이브"
        case .serverStatus, .serverStatusSettings: return "서버 현황"
        case .help: return "사용 안내"
        case .general: return "브라우저 설정"
        }
    }

    public var iconId: String {
        switch self {
        case .home: return "home"
        case .mail: return "mail"
        case .screen: return "screen"
        case .browser: return "browser"
        case .translationSettings: return "settings"
        case .input: return "edit"
        case .macManagement, .cleanUSB, .serverStatus: return "device_files"
        case .macManagementSettings, .serverStatusSettings: return "settings"
        case .help: return "help"
        case .general: return "settings"
        }
    }

    /// 사이드바 카테고리 묶음
    static let overviewSections: [SettingsSection] = [.home]
    static let translationSections: [SettingsSection] = [.mail, .screen, .browser, .translationSettings]
    static let supportSections: [SettingsSection] = [.help, .general]

}

/// 입력 도우미의 하위 메뉴. 사이드바의 "입력 도우미" 아래에 항상 표시되고, 선택한 페이지가 같은 상세 영역에 나타난다.
public enum InputMatePage: Int, CaseIterable, Identifiable {
    case appLanguage
    case koreanTypo
    case personalDictionary
    case trackpad
    case general

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .appLanguage: return "앱별 입력 언어"
        case .koreanTypo: return "한글 교정 및 번역"
        case .personalDictionary: return "개인 사전"
        case .trackpad: return "트랙패드"
        case .general: return "일반·정보"
        }
    }

    public var symbolName: String {
        switch self {
        case .appLanguage: return "globe"
        case .koreanTypo: return "character.textbox"
        case .personalDictionary: return "character.book.closed"
        case .trackpad: return "hand.raised"
        case .general: return "gearshape"
        }
    }
}

/// 사이드바 목록의 선택 값: 최상위 섹션 또는 입력 도우미 하위 페이지.
private enum SidebarItem: Hashable {
    case section(SettingsSection)
    case inputPage(InputMatePage)
}

/// 메인 창의 현재 섹션과 작업 영역 상태를 보존한다. 창이 열려 있는 동안 메뉴·버튼·서비스 어디서 요청해도 같은 창에서 섹션만 바뀐다.
@MainActor
public final class SettingsSectionStore: ObservableObject {
    public static let shared = SettingsSectionStore()

    @Published public var section: SettingsSection = .home {
        didSet {
            // 사용자가 다른 섹션으로 이동하면 열려 있던 브라우저 화면은 배너로 접고, 돌아가기로 다시 볼 수 있다.
            if section != oldValue {
                showsHostedBrowser = false
                onSectionChanged?()
            }
        }
    }
    /// 섹션이 실제로 바뀔 때마다(사용자 이동·메뉴 모두) 호출 — 코디네이터가 임시로 내린 캡처를 포기하는 데 쓴다.
    var onSectionChanged: (() -> Void)?
    /// 창이 처음 만들어지기 전의 요청도 보존하며, 시트를 닫으면 바인딩이 다시 false로 바뀐다.
    @Published public var showLanguagePackSheet = false
    /// USB 정리·추출 상태를 메인 액터에 유지하여 섹션 이동 간 작업을 보존한다.
    lazy var cleanUSBState = AppState()
    /// 입력 도우미 하위 페이지. 다른 섹션으로 갔다 돌아와도 유지된다.
    @Published public var inputPage: InputMatePage = .appLanguage
    /// 메인 창 안에 올린 AI·웹 번역·로그인 브라우저 화면(여러 개면 마지막이 대표).
    @Published var hostedBrowsers: [AIBIBrowserWindow] = []
    @Published var showsHostedBrowser = false
    /// 웹 번역(메일·화면 요청, 열린 앱 창 없음)이 진행되는 동안의 숨김 웹 보기 호스트와 진행·취소 줄.
    @Published var statusPanel: WebTranslatorStatusPanel?

    var hostedBrowser: AIBIBrowserWindow? { hostedBrowsers.last }

    public init(section: SettingsSection = .home) {
        self.section = section
    }
}

/// HTT 메인 작업 창의 내용 (SettingsView).
/// 지속되는 사이드바와 선택한 작업의 상세 영역으로 구성된다. 메일 번역(ContentView)은 섹션을 바꿔도 사라지지 않는다.
public struct SettingsView: View {
    @ObservedObject public var store: SettingsSectionStore
    public var showsSidebar: Bool = true
    @ObservedObject private var appearance = HTTAppearanceStore.shared
    @Environment(\.colorScheme) private var systemColorScheme

    public init(store: SettingsSectionStore, showsSidebar: Bool = true) {
        self.store = store
        self.showsSidebar = showsSidebar
    }

    private var palette: HTTThemePalette {
        appearance.palette(for: systemColorScheme)
    }

    public var body: some View {
        // NavigationSplitView의 상세 열은 창의 연결된 도구 막대(sceneBridgingOptions = [.toolbars])와 겹쳐
        // 자체 탐색 막대 영역(약 52pt 흐림 띠)을 상세 위쪽에 따로 만들었다. 탐색 컨테이너가 필요 없는 구성이므로
        // 항상 보이는 사이드바와 상세 영역을 HSplitView로 나란히 두고, 창 도구 막대는 AppKit 쪽 하나만 쓴다.
        // showsSidebar가 false인 호스트 도구 모드에서는 바깥 모듈 사이드바를 쓰고 두 번째 사이드바 없이 상세 영역만 렌더링한다.
        Group {
            if showsSidebar {
                HSplitView {
                    sidebarView
                        .frame(minWidth: 190, idealWidth: 210, maxWidth: 250, maxHeight: .infinity)
                    detailView
                        .frame(minWidth: 500, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
                .frame(minWidth: 780, idealWidth: 1040, maxWidth: .infinity,
                       minHeight: 560, idealHeight: 760, maxHeight: .infinity)
            } else {
                detailView
                    .frame(minWidth: 500, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .preferredColorScheme(appearance.effectiveColorScheme(for: systemColorScheme))
    }

    // MARK: - 사이드바 (Sidebar)

    private var sidebarView: some View {
        VStack(spacing: 0) {
            List(selection: Binding<SidebarItem?>(
                get: {
                    if store.section == .input { return .inputPage(store.inputPage) }
                    return .section(store.section)
                },
                set: { newItem in
                    switch newItem {
                    case .section(let section):
                        select(section)
                    case .inputPage(let page):
                        store.inputPage = page
                        select(.input)
                    case nil:
                        break
                    }
                }
            )) {
                Section("개요") {
                    ForEach(SettingsSection.overviewSections) { sidebarRow($0) }
                }
                Section("번역") {
                    ForEach(SettingsSection.translationSections) { sidebarRow($0) }
                }
                Section(SettingsSection.input.title) {
                    ForEach(InputMatePage.allCases) { page in
                        Label(page.title, systemImage: page.symbolName)
                            .font(.body)
                            .tag(SidebarItem.inputPage(page))
                    }
                }
                Section("도구") {
                    sidebarRow(.macManagement)
                    sidebarRow(.macManagementSettings)
                    sidebarRow(.cleanUSB)
                    sidebarRow(.serverStatus)
                    sidebarRow(.serverStatusSettings)
                }
                Section("지원 및 설정") {
                    ForEach(SettingsSection.supportSections) { sidebarRow($0) }
                }
            }
            .listStyle(.sidebar)

            Divider()

            HStack {
                HTTThemeButton()
                Spacer()
                Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                    .font(.caption2)
                    .foregroundStyle(palette.muted)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(palette.card)
        }
        .background(palette.card)
    }

    private func sidebarRow(_ section: SettingsSection) -> some View {
        // 탐색 스택이 없으므로 NavigationLink 대신 List 선택(태그)으로 이동한다. 방향키·VoiceOver 선택은 List가 그대로 처리한다.
        Label {
            Text(section.title)
                .font(.body)
        } icon: {
            HTTIconView(id: section.iconId, size: 18)
        }
        .tag(SidebarItem.section(section))
    }

    /// 사이드바 선택: Mac 관리는 표시 직전에 충돌 상태를 새로 확인한다(별도 창 없음).
    private func select(_ section: SettingsSection) {
        if section == .macManagement || section == .macManagementSettings { BTNIntegration.shared.prepareForDisplay() }
        store.section = section
    }

    // MARK: - 상세 영역 (Detail)

    private var showsBrowser: Bool {
        store.hostedBrowser != nil && store.showsHostedBrowser
    }

    private var isMailFront: Bool {
        store.section == .mail && !showsBrowser
    }

    /// 메일 번역 뷰(번역 세션·숨김 AI 표면·가져오기·알림을 소유)는 항상 한 번만 만들어 두고,
    /// 다른 섹션은 그 위를 불투명하게 덮어 보여 준다. 섹션을 바꿔도 번역 작업과 문서가 끊기지 않는다.
    /// 열린 브라우저 화면(AI 로그인·수동 진행·웹 번역 확인·OAuth 자식)은 모두 항상 붙여 두고 맨 위 하나만 보여 준다.
    /// 모든 층은 항상 같은 자리에 붙어 있는 형제 뷰이고(조건부로 다시 만들지 않아 식별자·웹 보기가 유지된다), 투명도는 쓰지 않는다.
    /// 어느 층이든 실제 크기와 불투명도 그대로이며, 앞에 보이는 층은 자체 불투명 배경으로 아래를 가린다.
    /// 앞뒤 순서는 zIndex로만 바꾼다: 웹 번역 호스트(0) / 메일 뷰와 브라우저 스택(메일이 앞이면 메일 2·스택 1, 브라우저가 앞이면 스택 3·메일 2) / 섹션 내용(4).
    @ViewBuilder
    private var detailView: some View {
        VStack(spacing: 0) {
            if store.statusPanel != nil {
                // 어느 섹션에 있든 웹 번역 진행과 취소가 보이도록 전역 줄로 둔다.
                WebTranslatorPanelContent()
                Divider()
            }
            if let browser = store.hostedBrowser, !store.showsHostedBrowser {
                hostedBrowserBanner(browser)
            }
            ZStack {
                if let panel = store.statusPanel {
                    // 숨김 웹 보기 호스트: 실제 크기로 이 창에 붙어 있고, 자체 불투명 덮개 아래라 보이지 않는다.
                    WebTranslatorStatusHost(panel: panel)
                        .frame(width: AIBIHiddenSurface.viewport.width, height: AIBIHiddenSurface.viewport.height)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .clipped()
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .zIndex(0)
                }
                // 불투명 배경을 가진 메일 뷰: 메일이 앞이면 브라우저 스택을 덮고, 브라우저가 앞이면 스택 아래로 내려간다.
                ContentView(isActive: isMailFront)
                    .modifier(OpaqueCover(background: palette.bg))
                    .clipped()
                    .allowsHitTesting(isMailFront)
                    // 가려진 동안 기본 버튼(Return) 같은 단축키가 메일 번역을 실행하지 않게 한다.
                    .disabled(!isMailFront)
                    .accessibilityHidden(!isMailFront)
                    .zIndex(2)
                hostedBrowserStack
                    .zIndex(showsBrowser ? 3 : 1)
                if !showsBrowser && store.section != .mail {
                    sectionContent
                        .modifier(OpaqueCover(background: palette.bg))
                        .zIndex(4)
                }
            }
        }
    }

    /// 쌓인 모든 브라우저 화면을 안정적인 식별자로 한 번씩만 마운트한다. 부모(예: OAuth 부모 웹 보기)는 자식이 올라와도,
    /// 섹션을 잠시 바꿔도 분리·재생성되지 않고 같은 크기로 붙어 있다. 입력·포커스·접근성은 맨 위 화면만 받는다.
    private var hostedBrowserStack: some View {
        ZStack {
            ForEach(store.hostedBrowsers, id: \.hostID) { browser in
                let active = showsBrowser && browser === store.hostedBrowser
                AIBIHostedBrowserPane(browser: browser, isActive: active)
                    .modifier(OpaqueCover(background: palette.bg))
                    .allowsHitTesting(active)
                    .disabled(!active)
                    .accessibilityHidden(!active)
            }
        }
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch store.section {
        case .home:
            HTTHomeView(settingsStore: store)
        case .mail:
            EmptyView()
        case .screen:
            ScreenTranslationPane()
        case .browser:
            BrowserSetupView(settingsStore: store)
        case .translationSettings:
            AISettingsView(scope: .translation)
        case .input:
            InputMateSettingsView(page: store.inputPage)
        case .macManagement, .macManagementSettings:
            MacManagementPane(store: store)
        case .cleanUSB:
            CleanUSBPane()
                .environmentObject(store.cleanUSBState)
        case .serverStatus:
            CCMBStatusView(onOpenSettings: { store.section = .serverStatusSettings })
        case .serverStatusSettings:
            CCMBSettingsView()
        case .help:
            HTTGuideView(settingsStore: store)
        case .general:
            AISettingsView(scope: .browser)
        }
    }

    private func hostedBrowserBanner(_ browser: AIBIBrowserWindow) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "globe")
            Text("\(browser.title) 화면이 열려 있습니다.")
                .font(.callout)
                .lineLimit(1)
            Spacer()
            Button("돌아가기") { store.showsHostedBrowser = true }
                .buttonStyle(.borderedProminent)
            Button("닫고 작업 취소") { browser.userClose() }
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(palette.warnSoft)
    }
}

/// 아래에 깔린 메일 번역 뷰(숨김 웹 보기 표면 포함)가 비치지 않도록 상세 영역을 불투명하게 덮는다.
private struct OpaqueCover: ViewModifier {
    let background: Color

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background {
                Color(nsColor: .windowBackgroundColor)
                    .overlay(background)
            }
    }
}

// MARK: - Mac 관리

private struct MacManagementPane: View {
    @ObservedObject var store: SettingsSectionStore
    @ObservedObject private var integration = BTNIntegration.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: integration.statusSymbolName)
                    .foregroundStyle(integration.statusColor)
                Text(integration.statusSummary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            Divider()
            if store.section == .macManagement {
                DetailView(model: integration.model)
            } else {
                VStack(spacing: 0) {
                    BTNSettingsView(integration: integration, onShowStatus: { store.section = .macManagement })
                    Divider()
                    AISettingsView(scope: .macManagement)
                }
            }
        }
        .onAppear { integration.prepareForDisplay() }
    }
}

// MARK: - 화면 번역 (임시 캡처 모드 안내와 시작)

private struct ScreenTranslationPane: View {
    @ObservedObject private var appearance = HTTAppearanceStore.shared
    @Environment(\.colorScheme) private var colorScheme

    private var palette: HTTThemePalette {
        appearance.palette(for: colorScheme)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("다른 앱 위에 투명한 캡처 영역을 띄워 그 안의 글자를 번역합니다.", systemImage: "text.viewfinder")
                            .font(.headline)
                        Text("캡처 모드가 시작되면 이 작업 창은 잠시 숨겨지고, 영역의 닫기 버튼이나 Esc로 끝내면 같은 작업 창으로 돌아옵니다. 작업 창과 캡처 영역이 함께 겹쳐 보이지는 않습니다.")
                            .font(.callout)
                            .foregroundStyle(palette.text2)
                        Text("다른 앱을 보는 중이라면 전역 단축키 \(GlobalHotKey.displayString)으로 바로 캡처 모드를 열 수 있습니다(이 경우 끝낸 뒤 작업 창을 자동으로 열지 않습니다).")
                            .font(.callout)
                            .foregroundStyle(palette.text2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
                HStack {
                    Button {
                        MailWindowCoordinator.shared.startCaptureModeFromWorkbench()
                    } label: {
                        Label("캡처 모드 시작", systemImage: "viewfinder")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    Spacer()
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
