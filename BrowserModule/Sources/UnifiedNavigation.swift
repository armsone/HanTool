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
    case usbDrives = "USB 드라이브"
    case server = "서버 현황"
    case clipboardHistory = "클립보드"
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
        case .usbDrives: return "externaldrive"
        case .server: return "chart.bar.xaxis"
        case .clipboardHistory: return "doc.on.clipboard"
        case .settings: return "gearshape"
        case .help: return "questionmark.circle"
        }
    }
}

public enum SettingsHubTab: String, CaseIterable, Identifiable {
    case general = "일반 설정"
    case webSettings = "브라우저"
    case aiConnections = "비서"
    case inputSettings = "입력 도우미"
    case macSettings = "Mac 관리"
    case serverSettings = "서버 현황"
    case downloadSettings = "다운로드"
    case plannerSettings = "플래너"
    case translationSettings = "번역"

    public var id: String { rawValue }
}

public enum SettingsOwner: String, CaseIterable, Identifiable {
    case browser = "브라우저"
    case downloads = "다운로드"
    case planner = "플래너"
    case translation = "번역"
    case inputHelper = "입력 도우미"
    case macManagement = "Mac 관리"
    case server = "서버 현황"
    case ai = "비서"

    public var id: String { rawValue }

    public var correspondingDestination: MainNavDestination {
        switch self {
        case .browser: return .browser
        case .downloads: return .downloads
        case .planner: return .planner
        case .translation: return .translation
        case .inputHelper: return .inputHelper
        case .macManagement: return .macManagement
        case .server: return .server
        case .ai: return .settings
        }
    }

    public var defaultSettingsTab: SettingsHubTab {
        switch self {
        case .browser: return .webSettings
        case .downloads: return .downloadSettings
        case .planner: return .plannerSettings
        case .translation: return .translationSettings
        case .inputHelper: return .inputSettings
        case .macManagement: return .macSettings
        case .server: return .serverSettings
        case .ai: return .aiConnections
        }
    }
}

public enum SettingsLeaf: String, CaseIterable, Identifiable {
    case browserSettings = "browserSettings"
    case downloadSettings = "downloadSettings"
    case plannerSettings = "plannerSettings"
    case translationSettings = "translationSettings"
    case inputSettings = "inputSettings"
    case macSettings = "macSettings"
    case serverSettings = "serverSettings"
    case aiConnections = "aiConnections"

    public var id: String { rawValue }

    public var owner: SettingsOwner {
        switch self {
        case .browserSettings: return .browser
        case .downloadSettings: return .downloads
        case .plannerSettings: return .planner
        case .translationSettings: return .translation
        case .inputSettings: return .inputHelper
        case .macSettings: return .macManagement
        case .serverSettings: return .server
        case .aiConnections: return .ai
        }
    }

    public var legacyTab: SettingsHubTab {
        switch self {
        case .browserSettings: return .webSettings
        case .downloadSettings: return .downloadSettings
        case .plannerSettings: return .plannerSettings
        case .translationSettings: return .translationSettings
        case .inputSettings: return .inputSettings
        case .macSettings: return .macSettings
        case .serverSettings: return .serverSettings
        case .aiConnections: return .aiConnections
        }
    }
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
        ToolCatalogItem(
            id: "clipboardHistory",
            title: "클립보드",
            description: "복사한 텍스트와 이미지 기록을 확인하고 다시 사용합니다",
            iconName: "doc.on.clipboard",
            category: .macManagement,
            hostedToolID: "clipboardHistory"
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

    // Context restoration & active leaf identification
    @Published public var settingsOwner: SettingsOwner? = nil
    @Published public var activeSettingsLeaf: SettingsLeaf? = nil
    @Published public var returnDestination: MainNavDestination? = nil
    @Published public var returnTabSelection: TabSelection? = nil
    @Published public var returnToolID: String? = nil

    public init() {}

    public func syncFromExternal(hostedToolID: String?, selectedTab: TabSelection) {
        if let toolID = hostedToolID {
            switch toolID {
            case "serverStatus":
                destination = .server
                settingsOwner = nil
                activeSettingsLeaf = nil
            case "serverStatusSettings":
                destination = .settings
                settingsTab = .serverSettings
                settingsOwner = .server
                activeSettingsLeaf = .serverSettings
            case "translationSettings":
                destination = .settings
                settingsTab = .translationSettings
                settingsOwner = .translation
                activeSettingsLeaf = .translationSettings
            case "help", "home":
                destination = .help
                settingsOwner = nil
                activeSettingsLeaf = nil
            case "general":
                destination = .settings
                settingsTab = .general
                settingsOwner = .browser
                activeSettingsLeaf = .browserSettings
            case "input.general":
                destination = .settings
                settingsTab = .inputSettings
                settingsOwner = .inputHelper
                activeSettingsLeaf = .inputSettings
            case "macManagementSettings":
                destination = .settings
                settingsTab = .macSettings
                settingsOwner = .macManagement
                activeSettingsLeaf = .macSettings
            case "browser":
                destination = .translation
                activeTranslationChild = "browser"
                settingsOwner = nil
                activeSettingsLeaf = nil
            case "mail", "screen":
                destination = .translation
                activeTranslationChild = toolID
                settingsOwner = nil
                activeSettingsLeaf = nil
            case "input.appLanguage", "input.koreanTypo", "input.personalDictionary", "input.trackpad":
                destination = .inputHelper
                activeInputChild = toolID
                settingsOwner = nil
                activeSettingsLeaf = nil
            case "macManagement":
                destination = .macManagement
                activeMacManagementChild = "macManagement"
                settingsOwner = nil
                activeSettingsLeaf = nil
            case "cleanUSB":
                destination = .usbDrives
                settingsOwner = nil
                activeSettingsLeaf = nil
            case "clipboardHistory":
                destination = .clipboardHistory
                settingsOwner = nil
                activeSettingsLeaf = nil
            default:
                destination = .browser
                settingsOwner = nil
                activeSettingsLeaf = nil
            }
        } else {
            switch selectedTab {
            case .browser:
                destination = .browser
                settingsOwner = nil
                activeSettingsLeaf = nil
            case .ai:
                destination = .settings
                settingsTab = .aiConnections
                settingsOwner = .ai
                activeSettingsLeaf = .aiConnections
            case .saw:
                destination = .planner
                settingsOwner = nil
                activeSettingsLeaf = nil
            case .queue:
                destination = .downloads
                downloadTab = .queue
                settingsOwner = nil
                activeSettingsLeaf = nil
            case .history:
                destination = .downloads
                downloadTab = .history
                settingsOwner = nil
                activeSettingsLeaf = nil
            case .settings:
                destination = .settings
                if settingsOwner == .downloads {
                    settingsTab = .downloadSettings
                    activeSettingsLeaf = .downloadSettings
                } else if settingsOwner == .planner {
                    settingsTab = .plannerSettings
                    activeSettingsLeaf = .plannerSettings
                } else {
                    settingsTab = .webSettings
                    settingsOwner = .browser
                    activeSettingsLeaf = .browserSettings
                }
            case .pageVideos:
                destination = .browser
                settingsOwner = nil
                activeSettingsLeaf = nil
            case .addressSearch:
                destination = .settings
                settingsTab = .webSettings
                settingsOwner = .browser
                activeSettingsLeaf = .browserSettings
            case .speed:
                destination = .browser
                isSpeedTestPresented = true
                settingsOwner = nil
                activeSettingsLeaf = nil
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
            settingsOwner = nil
            activeSettingsLeaf = nil
            appModel.selectedTab = .browser

        case .downloads:
            clearTool()
            settingsOwner = nil
            activeSettingsLeaf = nil
            appModel.selectedTab = (downloadTab == .history ? .history : .queue)

        case .planner:
            clearTool()
            settingsOwner = nil
            activeSettingsLeaf = nil
            appModel.selectedTab = .saw

        case .translation:
            settingsOwner = nil
            activeSettingsLeaf = nil
            selectTool(activeTranslationChild)

        case .inputHelper:
            settingsOwner = nil
            activeSettingsLeaf = nil
            selectTool(activeInputChild)

        case .macManagement:
            settingsOwner = nil
            activeSettingsLeaf = nil
            selectTool(activeMacManagementChild)

        case .usbDrives:
            settingsOwner = nil
            activeSettingsLeaf = nil
            selectTool("cleanUSB")

        case .server:
            settingsOwner = nil
            activeSettingsLeaf = nil
            selectTool("serverStatus")

        case .clipboardHistory:
            settingsOwner = nil
            activeSettingsLeaf = nil
            selectTool("clipboardHistory")

        case .settings:
            applySettingsTab(settingsTab, appModel: appModel, selectTool: selectTool, clearTool: clearTool)

        case .help:
            settingsOwner = nil
            activeSettingsLeaf = nil
            selectTool("help")
        }
    }

    public func selectTranslationChild(
        _ childID: String,
        selectTool: (String) -> Void
    ) {
        self.settingsOwner = nil
        self.activeSettingsLeaf = nil
        self.activeTranslationChild = childID
        self.destination = .translation
        selectTool(childID)
    }

    public func selectInputChild(
        _ childID: String,
        selectTool: (String) -> Void
    ) {
        self.settingsOwner = nil
        self.activeSettingsLeaf = nil
        self.activeInputChild = childID
        self.destination = .inputHelper
        selectTool(childID)
    }

    public func selectMacManagementChild(
        _ childID: String,
        selectTool: (String) -> Void
    ) {
        self.settingsOwner = nil
        self.activeSettingsLeaf = nil
        if childID == "cleanUSB" {
            self.destination = .usbDrives
            selectTool("cleanUSB")
        } else {
            self.activeMacManagementChild = childID
            self.destination = .macManagement
            selectTool(childID)
        }
    }

    public func selectSettingsTab(
        _ tab: SettingsHubTab,
        appModel: AppModel,
        selectTool: (String) -> Void,
        clearTool: () -> Void
    ) {
        self.settingsTab = tab
        self.destination = .settings
        switch tab {
        case .webSettings:
            self.settingsOwner = .browser
            self.activeSettingsLeaf = .browserSettings
        case .downloadSettings:
            self.settingsOwner = .downloads
            self.activeSettingsLeaf = .downloadSettings
        case .plannerSettings:
            self.settingsOwner = .planner
            self.activeSettingsLeaf = .plannerSettings
        case .translationSettings:
            self.settingsOwner = .translation
            self.activeSettingsLeaf = .translationSettings
        case .inputSettings:
            self.settingsOwner = .inputHelper
            self.activeSettingsLeaf = .inputSettings
        case .macSettings:
            self.settingsOwner = .macManagement
            self.activeSettingsLeaf = .macSettings
        case .serverSettings:
            self.settingsOwner = .server
            self.activeSettingsLeaf = .serverSettings
        case .aiConnections:
            self.settingsOwner = .ai
            self.activeSettingsLeaf = .aiConnections
        case .general:
            self.settingsOwner = .browser
            self.activeSettingsLeaf = .browserSettings
        }
        applySettingsTab(tab, appModel: appModel, selectTool: selectTool, clearTool: clearTool)
    }

    public func openFeatureSettings(
        for owner: SettingsOwner,
        appModel: AppModel,
        currentToolID: String? = nil,
        selectTool: (String) -> Void,
        clearTool: () -> Void
    ) {
        // Save current context for return
        if self.destination != .settings {
            self.returnDestination = self.destination
            self.returnTabSelection = appModel.selectedTab
            self.returnToolID = currentToolID
        }
        self.settingsOwner = owner
        let targetTab = owner.defaultSettingsTab
        self.settingsTab = targetTab
        switch targetTab {
        case .webSettings: self.activeSettingsLeaf = .browserSettings
        case .downloadSettings: self.activeSettingsLeaf = .downloadSettings
        case .plannerSettings: self.activeSettingsLeaf = .plannerSettings
        case .translationSettings: self.activeSettingsLeaf = .translationSettings
        case .inputSettings: self.activeSettingsLeaf = .inputSettings
        case .macSettings: self.activeSettingsLeaf = .macSettings
        case .serverSettings: self.activeSettingsLeaf = .serverSettings
        case .aiConnections: self.activeSettingsLeaf = .aiConnections
        case .general: self.activeSettingsLeaf = .browserSettings
        }
        self.destination = .settings
        applySettingsTab(targetTab, appModel: appModel, selectTool: selectTool, clearTool: clearTool)
    }

    public func openAISettings(
        appModel: AppModel,
        currentToolID: String? = nil,
        selectTool: (String) -> Void,
        clearTool: () -> Void
    ) {
        // Save prior context if not already in settings
        if self.destination != .settings {
            self.returnDestination = self.destination
            self.returnTabSelection = appModel.selectedTab
            self.returnToolID = currentToolID
        }
        self.settingsOwner = .ai
        self.activeSettingsLeaf = .aiConnections
        self.settingsTab = .aiConnections
        self.destination = .settings
        applySettingsTab(.aiConnections, appModel: appModel, selectTool: selectTool, clearTool: clearTool)
    }

    public func openCurrentContextSettings(
        appModel: AppModel,
        currentToolID: String? = nil,
        selectTool: (String) -> Void,
        clearTool: () -> Void
    ) {
        let currentOwner: SettingsOwner
        switch self.destination {
        case .browser:
            currentOwner = .browser
        case .downloads:
            currentOwner = .downloads
        case .planner:
            currentOwner = .planner
        case .translation:
            currentOwner = .translation
        case .inputHelper:
            currentOwner = .inputHelper
        case .macManagement:
            currentOwner = .macManagement
        case .server:
            currentOwner = .server
        case .usbDrives:
            currentOwner = .macManagement
        case .clipboardHistory:
            currentOwner = .browser
        case .settings:
            currentOwner = self.settingsOwner ?? .browser
        case .help:
            currentOwner = .browser
        }
        openFeatureSettings(
            for: currentOwner,
            appModel: appModel,
            currentToolID: currentToolID,
            selectTool: selectTool,
            clearTool: clearTool
        )
    }

    public func returnFromSettings(
        appModel: AppModel,
        selectTool: (String) -> Void,
        clearTool: () -> Void
    ) {
        let targetDest = self.returnDestination ?? (self.settingsOwner?.correspondingDestination ?? .browser)
        let priorTab = self.returnTabSelection
        let priorTool = self.returnToolID

        self.destination = targetDest
        self.settingsOwner = nil
        self.activeSettingsLeaf = nil
        self.returnDestination = nil
        self.returnTabSelection = nil
        self.returnToolID = nil

        switch targetDest {
        case .browser:
            clearTool()
            appModel.selectedTab = (priorTab == .browser || priorTab == nil) ? .browser : priorTab!
        case .downloads:
            clearTool()
            appModel.selectedTab = (downloadTab == .history ? .history : .queue)
        case .planner:
            clearTool()
            appModel.selectedTab = .saw
        case .translation:
            if let tool = priorTool, !tool.isEmpty {
                self.activeTranslationChild = tool
                selectTool(tool)
            } else {
                selectTool(activeTranslationChild)
            }
        case .inputHelper:
            if let tool = priorTool, !tool.isEmpty {
                self.activeInputChild = tool
                selectTool(tool)
            } else {
                selectTool(activeInputChild)
            }
        case .macManagement:
            if let tool = priorTool, !tool.isEmpty {
                self.activeMacManagementChild = tool
                selectTool(tool)
            } else {
                selectTool(activeMacManagementChild)
            }
        case .usbDrives:
            selectTool("cleanUSB")
        case .server:
            selectTool("serverStatus")
        case .clipboardHistory:
            selectTool("clipboardHistory")
        case .help:
            selectTool("help")
        case .settings:
            clearTool()
            appModel.selectedTab = .browser
        }
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
        case .serverSettings:
            selectTool("serverStatusSettings")
        case .downloadSettings:
            clearTool()
            appModel.selectedTab = .settings
        case .plannerSettings:
            clearTool()
            appModel.selectedTab = .settings
        case .translationSettings:
            selectTool("translationSettings")
        }
    }

    public func selectDestination(
        _ dest: MainNavDestination,
        appModel: AppModel,
        selectTool: (String) -> Void,
        clearTool: () -> Void
    ) {
        navigateTo(destination: dest, appModel: appModel, selectTool: selectTool, clearTool: clearTool)
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

    public func openSpeedTest(appModel: AppModel, clearTool: () -> Void) {
        clearTool()
        destination = .browser
        appModel.selectedTab = .browser
        isSpeedTestPresented = true
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

            Button("주소 직접 입력", action: onStartWithURL)
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
