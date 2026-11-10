import SwiftUI
import AppKit

// MARK: - Navigation Destinations

public enum MainNavDestination: String, CaseIterable, Identifiable {
    case browser = "브라우저"
    case downloads = "다운로드"
    case planner = "플래너"
    case translation = "번역"
    case inputHelper = "입력 도우미"
    case macManagement = "Mac 관리"
    case server = "서버 현황"
    case settings = "설정"
    case help = "사용 안내"

    public var id: String { rawValue }

    public var iconName: String {
        switch self {
        case .browser: return "globe"
        case .downloads: return "arrow.down.circle"
        case .planner: return "checklist"
        case .translation: return "character.book.closed"
        case .inputHelper: return "keyboard"
        case .macManagement: return "desktopcomputer"
        case .server: return "chart.bar.xaxis"
        case .settings: return "gearshape"
        case .help: return "questionmark.circle"
        }
    }
}

public enum SettingsHubTab: String, CaseIterable, Identifiable {
    case general = "일반 설정"
    case webSettings = "웹 설정"
    case aiConnections = "AI 연결"
    case inputSettings = "입력 설정"
    case macSettings = "Mac 관리 설정"

    public var id: String { rawValue }
}

public enum DownloadHubTab: String, CaseIterable, Identifiable {
    case queue = "진행 중"
    case history = "완료기록"

    public var id: String { rawValue }
}

// MARK: - Tools Catalog

public enum ToolGroupCategory: String, CaseIterable, Identifiable {
    case translation = "번역"
    case inputHelper = "입력 도우미"
    case macManagement = "Mac 관리"
    case webTools = "웹 도구"

    public var id: String { rawValue }
}

public struct ToolCatalogItem: Identifiable {
    public let id: String
    public let title: String
    public let description: String
    public let iconName: String
    public let category: ToolGroupCategory
    public let isNativeTab: Bool
    public let nativeTab: TabSelection?
    public let hostedToolID: String?

    public init(
        id: String,
        title: String,
        description: String,
        iconName: String,
        category: ToolGroupCategory,
        isNativeTab: Bool = false,
        nativeTab: TabSelection? = nil,
        hostedToolID: String? = nil
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.iconName = iconName
        self.category = category
        self.isNativeTab = isNativeTab
        self.nativeTab = nativeTab
        self.hostedToolID = hostedToolID ?? (isNativeTab ? nil : id)
    }
}

public enum ToolCatalog {
    public static let allTools: [ToolCatalogItem] = [
        // 번역
        ToolCatalogItem(
            id: "mail",
            title: "메일·이미지 번역",
            description: "메일이나 이미지의 내용을 번역합니다",
            iconName: "envelope",
            category: .translation,
            hostedToolID: "mail"
        ),
        ToolCatalogItem(
            id: "screen",
            title: "화면 번역",
            description: "화면에서 번역할 영역을 선택합니다",
            iconName: "viewfinder",
            category: .translation,
            hostedToolID: "screen"
        ),
        ToolCatalogItem(
            id: "browser",
            title: "번역 확장 연동",
            description: "브라우저 번역 확장을 연결합니다",
            iconName: "puzzlepiece.extension",
            category: .translation,
            hostedToolID: "browser"
        ),

        // 입력 도우미
        ToolCatalogItem(
            id: "input.appLanguage",
            title: "앱별 언어 전환",
            description: "앱마다 사용할 입력 언어를 정합니다",
            iconName: "character.bubble",
            category: .inputHelper,
            hostedToolID: "input.appLanguage"
        ),
        ToolCatalogItem(
            id: "input.koreanTypo",
            title: "한글 오타 교정",
            description: "입력한 문장의 오타를 교정합니다",
            iconName: "pencil.and.outline",
            category: .inputHelper,
            hostedToolID: "input.koreanTypo"
        ),
        ToolCatalogItem(
            id: "input.personalDictionary",
            title: "개인 사전",
            description: "자주 쓰는 단어와 변환 규칙을 관리합니다",
            iconName: "book",
            category: .inputHelper,
            hostedToolID: "input.personalDictionary"
        ),
        ToolCatalogItem(
            id: "input.trackpad",
            title: "트랙패드 잠금",
            description: "키보드 입력 중 오작동을 방지합니다",
            iconName: "hand.raised",
            category: .inputHelper,
            hostedToolID: "input.trackpad"
        ),

        // Mac 관리
        ToolCatalogItem(
            id: "macManagement",
            title: "Mac 관리",
            description: "시스템 상태 확인 및 개발 캐시·저장 공간을 정리합니다",
            iconName: "desktopcomputer",
            category: .macManagement,
            hostedToolID: "macManagement"
        ),
        ToolCatalogItem(
            id: "cleanUSB",
            title: "USB 드라이브 정리",
            description: "외장 USB 드라이브의 숨김 파일을 정리하고 안전하게 추출합니다",
            iconName: "externaldrive",
            category: .macManagement,
            hostedToolID: "cleanUSB"
        ),

        // 웹 도구
        ToolCatalogItem(
            id: "pageVideos",
            title: "이 페이지의 영상",
            description: "열린 웹페이지의 영상을 찾습니다",
            iconName: "film",
            category: .webTools,
            isNativeTab: true,
            nativeTab: .pageVideos
        ),
        ToolCatalogItem(
            id: "addressSearch",
            title: "주소창·검색",
            description: "주소 입력과 검색 기능을 확인합니다",
            iconName: "magnifyingglass",
            category: .webTools,
            isNativeTab: true,
            nativeTab: .addressSearch
        ),
        ToolCatalogItem(
            id: "speed",
            title: "속도측정",
            description: "네트워크 속도와 연결 상태를 측정합니다",
            iconName: "speedometer",
            category: .webTools,
            isNativeTab: true,
            nativeTab: .speed
        )
    ]

    public static func tools(in category: ToolGroupCategory) -> [ToolCatalogItem] {
        allTools.filter { $0.category == category }
    }

    public static func item(for id: String) -> ToolCatalogItem? {
        allTools.first { $0.id == id || $0.hostedToolID == id }
    }
}

// MARK: - Navigation Coordinator

@MainActor
public final class UnifiedNavigationModel: ObservableObject {
    public static let shared = UnifiedNavigationModel()

    @Published public var destination: MainNavDestination = .browser
    @Published public var settingsTab: SettingsHubTab = .general
    @Published public var downloadTab: DownloadHubTab = .queue
    @Published public var activeTranslationChild: String = "mail"
    @Published public var activeInputChild: String = "input.appLanguage"
    @Published public var activeMacManagementChild: String = "macManagement"
    @Published public var isSpeedTestPresented: Bool = false

    // Compatibility shims for legacy calls
    @Published public var isToolsHubRoot: Bool = false
    @Published public var activeToolLeafID: String? = nil

    public init() {}

    public func syncFromExternal(hostedToolID: String?, selectedTab: TabSelection) {
        if let toolID = hostedToolID {
            switch toolID {
            case "serverStatus":
                destination = .server
            case "help", "home":
                destination = .help
            case "general":
                destination = .settings
                settingsTab = .general
            case "input.general":
                destination = .settings
                settingsTab = .inputSettings
            case "macManagementSettings":
                destination = .settings
                settingsTab = .macSettings
            case "browser":
                destination = .settings
                settingsTab = .webSettings
            case "mail", "screen":
                destination = .translation
                activeTranslationChild = toolID
            case "input.appLanguage", "input.koreanTypo", "input.personalDictionary", "input.trackpad":
                destination = .inputHelper
                activeInputChild = toolID
            case "macManagement", "cleanUSB":
                destination = .macManagement
                activeMacManagementChild = toolID
            default:
                destination = .browser
            }
        } else {
            switch selectedTab {
            case .browser:
                destination = .browser
            case .ai:
                destination = .settings
                settingsTab = .aiConnections
            case .saw:
                destination = .planner
            case .queue:
                destination = .downloads
                downloadTab = .queue
            case .history:
                destination = .downloads
                downloadTab = .history
            case .settings:
                destination = .settings
                settingsTab = .webSettings
            case .pageVideos:
                destination = .browser
            case .addressSearch:
                destination = .settings
                settingsTab = .webSettings
            case .speed:
                destination = .browser
                isSpeedTestPresented = true
            }
        }
    }

    public func navigateTo(
        destination dest: MainNavDestination,
        appModel: AppModel,
        selectTool: (String) -> Void,
        clearTool: () -> Void
    ) {
        self.destination = dest
        switch dest {
        case .browser:
            clearTool()
            appModel.selectedTab = .browser

        case .downloads:
            clearTool()
            appModel.selectedTab = (downloadTab == .history ? .history : .queue)

        case .planner:
            clearTool()
            appModel.selectedTab = .saw

        case .translation:
            selectTool(activeTranslationChild)

        case .inputHelper:
            selectTool(activeInputChild)

        case .macManagement:
            selectTool(activeMacManagementChild)

        case .server:
            selectTool("serverStatus")

        case .settings:
            applySettingsTab(settingsTab, appModel: appModel, selectTool: selectTool, clearTool: clearTool)

        case .help:
            selectTool("help")
        }
    }

    public func selectTranslationChild(
        _ childID: String,
        selectTool: (String) -> Void
    ) {
        self.activeTranslationChild = childID
        self.destination = .translation
        selectTool(childID)
    }

    public func selectInputChild(
        _ childID: String,
        selectTool: (String) -> Void
    ) {
        self.activeInputChild = childID
        self.destination = .inputHelper
        selectTool(childID)
    }

    public func selectMacManagementChild(
        _ childID: String,
        selectTool: (String) -> Void
    ) {
        self.activeMacManagementChild = childID
        self.destination = .macManagement
        selectTool(childID)
    }

    public func selectSettingsTab(
        _ tab: SettingsHubTab,
        appModel: AppModel,
        selectTool: (String) -> Void,
        clearTool: () -> Void
    ) {
        self.settingsTab = tab
        self.destination = .settings
        applySettingsTab(tab, appModel: appModel, selectTool: selectTool, clearTool: clearTool)
    }

    private func applySettingsTab(
        _ tab: SettingsHubTab,
        appModel: AppModel,
        selectTool: (String) -> Void,
        clearTool: () -> Void
    ) {
        switch tab {
        case .general:
            selectTool("general")
        case .webSettings:
            clearTool()
            appModel.selectedTab = .settings
        case .aiConnections:
            clearTool()
            if appModel.selectedTab != .ai {
                appModel.selectedTab = .ai
            }
        case .inputSettings:
            selectTool("input.general")
        case .macSettings:
            selectTool("macManagementSettings")
        }
    }

    public func selectDownloadTab(_ tab: DownloadHubTab, appModel: AppModel, clearTool: () -> Void) {
        self.downloadTab = tab
        self.destination = .downloads
        clearTool()
        switch tab {
        case .queue:
            appModel.selectedTab = .queue
        case .history:
            appModel.selectedTab = .history
        }
    }

    public func openToolItem(
        _ item: ToolCatalogItem,
        appModel: AppModel,
        selectTool: (String) -> Void,
        clearTool: () -> Void
    ) {
        if item.category == .translation {
            selectTranslationChild(item.id, selectTool: selectTool)
        } else if item.category == .inputHelper {
            selectInputChild(item.id, selectTool: selectTool)
        } else if item.category == .macManagement {
            selectMacManagementChild(item.id, selectTool: selectTool)
        } else if item.id == "speed" {
            destination = .browser
            appModel.selectedTab = .browser
            isSpeedTestPresented = true
        } else if item.id == "pageVideos" {
            destination = .browser
            appModel.selectedTab = .browser
            appModel.isMediaCandidatePresented = true
        } else if item.id == "addressSearch" {
            selectSettingsTab(.webSettings, appModel: appModel, selectTool: selectTool, clearTool: clearTool)
        } else if let toolID = item.hostedToolID {
            selectTool(toolID)
        }
    }

    public func backToToolsHub(clearTool: () -> Void) {
        clearTool()
    }
}

// MARK: - Tools Hub View

public struct ToolsHubView: View {
    @Environment(\.bkPalette) private var palette
    @State private var searchText: String = ""

    public var onSelectTool: (ToolCatalogItem) -> Void
    public var onOpenHome: () -> Void
    public var onOpenSettings: () -> Void
    public var onOpenServer: () -> Void

    public init(
        onSelectTool: @escaping (ToolCatalogItem) -> Void,
        onOpenHome: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void,
        onOpenServer: @escaping () -> Void
    ) {
        self.onSelectTool = onSelectTool
        self.onOpenHome = onOpenHome
        self.onOpenSettings = onOpenSettings
        self.onOpenServer = onOpenServer
    }

    private var filteredTools: [ToolCatalogItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if query.isEmpty { return ToolCatalog.allTools }
        return ToolCatalog.allTools.filter {
            $0.title.lowercased().contains(query) || $0.description.lowercased().contains(query)
        }
    }

    private func toolsForCategory(_ category: ToolGroupCategory) -> [ToolCatalogItem] {
        filteredTools.filter { $0.category == category }
    }

    public var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 22) {
                // Topline
                HStack(alignment: .center, spacing: 18) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("도구")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundColor(palette.textColor)
                        Text("필요한 기능을 골라 시작하세요.")
                            .font(.subheadline)
                            .foregroundColor(palette.mutedColor)
                    }

                    Spacer()

                    // Search field
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(palette.mutedColor)
                            .font(.system(size: 13))
                        TextField("기능 찾기", text: $searchText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                        if !searchText.isEmpty {
                            Button {
                                searchText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(palette.mutedColor)
                                    .font(.system(size: 12))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .frame(width: 220)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(palette.surfaceColor)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(palette.borderColor, lineWidth: 1)
                    )
                }

                // Independent 홈 요약 shortcut card
                Button(action: onOpenHome) {
                    HStack(spacing: 14) {
                        Image(systemName: "house")
                            .font(.system(size: 20))
                            .foregroundColor(palette.accentColor)
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(palette.accentSoftColor))

                        VStack(alignment: .leading, spacing: 3) {
                            Text("홈 요약")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(palette.textColor)
                            Text("번역·입력 도우미·Mac 관리 상태를 한눈에")
                                .font(.system(size: 12))
                                .foregroundColor(palette.mutedColor)
                        }

                        Spacer()

                        Text("열기 →")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(palette.accentColor)
                    }
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 9)
                            .fill(palette.surfaceColor)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 9)
                            .stroke(palette.borderColor, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .help("홈 요약 — 번역·입력 도우미·Mac 관리 상태를 한눈에 확인")
                .accessibilityLabel("홈 요약 열기")

                // Tool Groups
                ForEach(ToolGroupCategory.allCases) { category in
                    let items = toolsForCategory(category)
                    if !items.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 8) {
                                Text(category.rawValue)
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(palette.textColor)
                                Text("\(items.count)개 기능")
                                    .font(.system(size: 11))
                                    .foregroundColor(palette.mutedColor)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(palette.surface2Color))
                                Spacer()
                            }

                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 10)], spacing: 10) {
                                ForEach(items) { tool in
                                    ToolCardButton(tool: tool, palette: palette) {
                                        onSelectTool(tool)
                                    }
                                }
                            }
                        }
                    }
                }

                // Spacer line & note
                HStack(spacing: 8) {
                    Text("상세 옵션은")
                        .font(.system(size: 12))
                        .foregroundColor(palette.mutedColor)
                    Button("설정") {
                        onOpenSettings()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Text("에서 · 서버 현황은")
                        .font(.system(size: 12))
                        .foregroundColor(palette.mutedColor)
                    Button("서버 현황") {
                        onOpenServer()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Text("에서 바로 확인합니다.")
                        .font(.system(size: 12))
                        .foregroundColor(palette.mutedColor)
                }
                .padding(.top, 10)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(palette.bgColor)
    }
}

private struct ToolCardButton: View {
    let tool: ToolCatalogItem
    let palette: Palette
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: tool.iconName)
                    .font(.system(size: 16))
                    .foregroundColor(palette.accentColor)
                    .frame(width: 26, height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(palette.accentSoftColor)
                    )
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 3) {
                    Text(tool.title)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(palette.textColor)
                        .lineLimit(1)
                    Text(tool.description)
                        .font(.system(size: 11))
                        .foregroundColor(palette.mutedColor)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(11)
            .frame(minHeight: 68, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHovering ? palette.surface2Color : palette.surfaceColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isHovering ? palette.accentColor : palette.borderColor, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(tool.title + " — " + tool.description)
        .accessibilityLabel(tool.title)
    }
}

// MARK: - Purpose Workspace Header Views

public struct TranslationHeaderView: View {
    @Binding public var activeChild: String
    @Environment(\.bkPalette) private var palette
    public var onSelectChild: (String) -> Void
    public var onOpenWebSettings: () -> Void

    public init(
        activeChild: Binding<String>,
        onSelectChild: @escaping (String) -> Void,
        onOpenWebSettings: @escaping () -> Void
    ) {
        self._activeChild = activeChild
        self.onSelectChild = onSelectChild
        self.onOpenWebSettings = onOpenWebSettings
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("번역")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(palette.textColor)
                Text("메일·이미지 번역과 화면 번역을 바로 실행합니다.")
                    .font(.system(size: 12))
                    .foregroundColor(palette.mutedColor)
            }

            Spacer()

            HStack(spacing: 4) {
                let options: [(id: String, title: String)] = [
                    ("mail", "메일·이미지 번역"),
                    ("screen", "화면 번역")
                ]
                ForEach(options, id: \.id) { opt in
                    let isSelected = activeChild == opt.id
                    Button {
                        activeChild = opt.id
                        onSelectChild(opt.id)
                    } label: {
                        Text(opt.title)
                            .font(.system(size: 12, weight: isSelected ? .bold : .regular))
                            .foregroundColor(isSelected ? palette.onAccentColor : palette.textColor)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(isSelected ? palette.accentColor : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(opt.title)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .padding(3)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(palette.surface2Color)
            )

            Button("번역 확장 연동 설정 ↗") {
                onOpenWebSettings()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("설정 > 웹 설정에서 브라우저 번역 확장 프로그램을 연동합니다.")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(palette.cardColor)
    }
}

public struct InputHelperHeaderView: View {
    @Binding public var activeChild: String
    @Environment(\.bkPalette) private var palette
    public var onSelectChild: (String) -> Void
    public var onOpenInputSettings: () -> Void

    public init(
        activeChild: Binding<String>,
        onSelectChild: @escaping (String) -> Void,
        onOpenInputSettings: @escaping () -> Void
    ) {
        self._activeChild = activeChild
        self.onSelectChild = onSelectChild
        self.onOpenInputSettings = onOpenInputSettings
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Upper row: Title & description
            VStack(alignment: .leading, spacing: 2) {
                Text("입력 도우미")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(palette.textColor)
                Text("앱별 언어 전환, 오타 교정, 사전, 트랙패드 잠금을 관리합니다.")
                    .font(.system(size: 12))
                    .foregroundColor(palette.mutedColor)
            }

            // Lower row: Four function tabs + input settings button
            HStack(alignment: .center, spacing: 12) {
                ScrollView(.horizontal, showsIndicators: true) {
                    HStack(spacing: 4) {
                        let options: [(id: String, title: String)] = [
                            ("input.appLanguage", "앱별 언어 전환"),
                            ("input.koreanTypo", "한글 오타 교정"),
                            ("input.personalDictionary", "개인 사전"),
                            ("input.trackpad", "트랙패드 잠금")
                        ]
                        ForEach(options, id: \.id) { opt in
                            let isSelected = activeChild == opt.id
                            Button {
                                activeChild = opt.id
                                onSelectChild(opt.id)
                            } label: {
                                Text(opt.title)
                                    .font(.system(size: 12, weight: isSelected ? .bold : .regular))
                                    .foregroundColor(isSelected ? palette.onAccentColor : palette.textColor)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(isSelected ? palette.accentColor : Color.clear)
                                    )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(opt.title)
                            .accessibilityAddTraits(isSelected ? .isSelected : [])
                        }
                    }
                    .padding(3)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(palette.surface2Color)
                    )
                }

                Spacer()

                Button("입력 설정 ↗") {
                    onOpenInputSettings()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("설정 > 입력 설정으로 이동합니다.")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(palette.cardColor)
    }
}

public struct MacManagementHeaderView: View {
    @Binding public var activeChild: String
    @Environment(\.bkPalette) private var palette
    public var onSelectChild: (String) -> Void
    public var onOpenMacSettings: () -> Void

    public init(
        activeChild: Binding<String>,
        onSelectChild: @escaping (String) -> Void,
        onOpenMacSettings: @escaping () -> Void
    ) {
        self._activeChild = activeChild
        self.onSelectChild = onSelectChild
        self.onOpenMacSettings = onOpenMacSettings
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Mac 관리")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(palette.textColor)
                Text("시스템 상태 확인, 개발 캐시 정리 및 외장 USB 정리를 수행합니다.")
                    .font(.system(size: 12))
                    .foregroundColor(palette.mutedColor)
            }

            Spacer()

            HStack(spacing: 4) {
                let options: [(id: String, title: String)] = [
                    ("macManagement", "Mac 관리"),
                    ("cleanUSB", "USB 드라이브 정리")
                ]
                ForEach(options, id: \.id) { opt in
                    let isSelected = activeChild == opt.id
                    Button {
                        activeChild = opt.id
                        onSelectChild(opt.id)
                    } label: {
                        Text(opt.title)
                            .font(.system(size: 12, weight: isSelected ? .bold : .regular))
                            .foregroundColor(isSelected ? palette.onAccentColor : palette.textColor)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(isSelected ? palette.accentColor : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(opt.title)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .padding(3)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(palette.surface2Color)
            )

            Button("Mac 관리 설정 ↗") {
                onOpenMacSettings()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("설정 > Mac 관리 설정으로 이동합니다.")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(palette.cardColor)
    }
}

// MARK: - Settings Hub Header View

public struct SettingsHubHeaderView: View {
    @Binding public var activeTab: SettingsHubTab
    @Environment(\.bkPalette) private var palette

    public var onTabChanged: (SettingsHubTab) -> Void
    public var onOpenInputTool: (String) -> Void
    public var onOpenMacManagement: () -> Void
    public var onOpenBrowser: () -> Void
    public var onOpenBrowserSetup: () -> Void

    public init(
        activeTab: Binding<SettingsHubTab>,
        onTabChanged: @escaping (SettingsHubTab) -> Void,
        onOpenInputTool: @escaping (String) -> Void,
        onOpenMacManagement: @escaping () -> Void,
        onOpenBrowser: @escaping () -> Void,
        onOpenBrowserSetup: @escaping () -> Void = {}
    ) {
        self._activeTab = activeTab
        self.onTabChanged = onTabChanged
        self.onOpenInputTool = onOpenInputTool
        self.onOpenMacManagement = onOpenMacManagement
        self.onOpenBrowser = onOpenBrowser
        self.onOpenBrowserSetup = onOpenBrowserSetup
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Topline
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("설정")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(palette.textColor)
                    Text("실행할 작업과 구분해, 상세 옵션을 한곳에 모았습니다.")
                        .font(.system(size: 12))
                        .foregroundColor(palette.mutedColor)
                }
                Spacer()
            }

            // 5 Segmented Tabs
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(SettingsHubTab.allCases) { tab in
                        let isSelected = activeTab == tab
                        Button {
                            activeTab = tab
                            onTabChanged(tab)
                        } label: {
                            Text(tab.rawValue)
                                .font(.system(size: 12, weight: isSelected ? .bold : .regular))
                                .foregroundColor(isSelected ? palette.onAccentColor : palette.textColor)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(isSelected ? palette.accentColor : Color.clear)
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(tab.rawValue)
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                }
                .padding(3)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(palette.surface2Color)
                )
            }

            // Contextual quick jump buttons
            if activeTab == .inputSettings {
                HStack(spacing: 6) {
                    Text("입력 도우미 바로가기:")
                        .font(.system(size: 11))
                        .foregroundColor(palette.mutedColor)
                    Button("앱별 언어 전환") { onOpenInputTool("input.appLanguage") }
                        .buttonStyle(.bordered).controlSize(.mini)
                    Button("한글 오타 교정") { onOpenInputTool("input.koreanTypo") }
                        .buttonStyle(.bordered).controlSize(.mini)
                    Button("개인 사전") { onOpenInputTool("input.personalDictionary") }
                        .buttonStyle(.bordered).controlSize(.mini)
                    Button("트랙패드 잠금") { onOpenInputTool("input.trackpad") }
                        .buttonStyle(.bordered).controlSize(.mini)
                }
                .padding(.top, 2)
            } else if activeTab == .macSettings {
                HStack(spacing: 6) {
                    Button("Mac 관리 도구 열기 ↗") { onOpenMacManagement() }
                        .buttonStyle(.bordered).controlSize(.small)
                }
                .padding(.top, 2)
            } else if activeTab == .webSettings {
                HStack(spacing: 6) {
                    Button("브라우저 열기 ↗") { onOpenBrowser() }
                        .buttonStyle(.bordered).controlSize(.small)
                    Button("번역 확장 프로그램 설정 ↗") { onOpenBrowserSetup() }
                        .buttonStyle(.bordered).controlSize(.small)
                }
                .padding(.top, 2)
            } else if activeTab == .aiConnections {
                HStack(spacing: 6) {
                    Text("브라우저 상단 비서 대화창에서 사용할 AI 서비스를 설정합니다.")
                        .font(.system(size: 11))
                        .foregroundColor(palette.mutedColor)
                }
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(palette.cardColor)
    }
}

// MARK: - Downloads Hub Header View

public struct DownloadsHubHeaderView: View {
    @Binding public var activeTab: DownloadHubTab
    public var activeQueueCount: Int
    @Environment(\.bkPalette) private var palette

    public var onTabChanged: (DownloadHubTab) -> Void
    public var onStartWithURL: () -> Void

    public init(
        activeTab: Binding<DownloadHubTab>,
        activeQueueCount: Int = 0,
        onTabChanged: @escaping (DownloadHubTab) -> Void,
        onStartWithURL: @escaping () -> Void
    ) {
        self._activeTab = activeTab
        self.activeQueueCount = activeQueueCount
        self.onTabChanged = onTabChanged
        self.onStartWithURL = onStartWithURL
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("다운로드")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(palette.textColor)
                Text("진행 중인 작업과 완료기록을 한곳에서 확인합니다.")
                    .font(.system(size: 12))
                    .foregroundColor(palette.mutedColor)
            }

            Spacer()

            // 2 Tabs
            HStack(spacing: 4) {
                ForEach(DownloadHubTab.allCases) { tab in
                    let isSelected = activeTab == tab
                    Button {
                        activeTab = tab
                        onTabChanged(tab)
                    } label: {
                        HStack(spacing: 5) {
                            Text(tab.rawValue)
                                .font(.system(size: 12, weight: isSelected ? .bold : .regular))
                            if tab == .queue && activeQueueCount > 0 {
                                Text("\(activeQueueCount)")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(isSelected ? palette.onAccentColor : palette.accentColor)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(
                                        Capsule().fill(isSelected ? Color.white.opacity(0.3) : palette.accentSoftColor)
                                    )
                            }
                        }
                        .foregroundColor(isSelected ? palette.onAccentColor : palette.textColor)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(isSelected ? palette.accentColor : Color.clear)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(tab.rawValue)
                }
            }
            .padding(3)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(palette.surface2Color)
            )

            Button("주소로 시작", action: onStartWithURL)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(palette.cardColor)
    }
}

// MARK: - Tool Leaf Breadcrumb Bar

public struct ToolLeafBreadcrumbBar: View {
    public let leafTitle: String
    public let leafID: String
    public var onBack: () -> Void
    public var onOpenSettings: () -> Void
    @Environment(\.bkPalette) private var palette

    public init(
        leafTitle: String,
        leafID: String,
        onBack: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void
    ) {
        self.leafTitle = leafTitle
        self.leafID = leafID
        self.onBack = onBack
        self.onOpenSettings = onOpenSettings
    }

    public var body: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .bold))
                    Text("도구")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundColor(palette.accentColor)
            }
            .buttonStyle(.plain)
            .help("도구 목록으로 돌아가기")

            Image(systemName: "chevron.right")
                .font(.system(size: 10))
                .foregroundColor(palette.mutedColor)

            Text(leafTitle)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(palette.textColor)

            Spacer()

            if leafID.hasPrefix("input.") {
                Button("입력 설정") { onOpenSettings() }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
            } else if leafID == "macManagement" || leafID == "cleanUSB" {
                Button("Mac 관리 설정") { onOpenSettings() }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
            } else if leafID == "browser" {
                Button("웹 설정") { onOpenSettings() }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(palette.cardColor)
    }
}
