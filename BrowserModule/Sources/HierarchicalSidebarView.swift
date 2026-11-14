import SwiftUI
import AppKit

struct HierarchicalSidebarView: View {
    @ObservedObject var appModel: AppModel
    @ObservedObject var navModel: UnifiedNavigationModel
    var onRequestDownloadInput: () -> Void
    var isCompact: Bool
    var onToggleSidebar: (() -> Void)?
    @ObservedObject private var workspace: SAWWorkspace
    @Environment(\.bkPalette) private var palette
    @ObservedObject private var audioController = PageAudioController.shared
    @ObservedObject private var bookmarkAppearance = BookmarkAppearanceManager.shared

    #if HTT_HOST
    @ObservedObject private var hostExport = HTDHostExport.shared
    private var hostedToolID: String? { hostExport.hostedToolID }
    private func selectTool(_ id: String) { hostExport.selectToolFromSidebar(id) }
    private func clearHostedTool() { hostExport.clearHostedTool() }
    #else
    private var hostedToolID: String? { nil }
    private func selectTool(_ id: String) {}
    private func clearHostedTool() {}
    #endif

    @State private var expandedDestinations: Set<MainNavDestination> = [.browser]

    private static let topDestinations: [MainNavDestination] = [
        .browser,
        .downloads,
        .planner,
        .translation,
        .inputHelper,
        .macManagement,
        .usbDrives,
        .server,
        .clipboardHistory
    ]

    private static let bottomDestinations: [MainNavDestination] = [
        .help
    ]

    private var headerButtonSize: CGFloat { isCompact ? 24 : 28 }

    private var activeQueueCount: Int {
        appModel.jobs.filter { !$0.state.isTerminal || $0.state == .interrupted || $0.state == .selectionChanged }.count
    }

    init(
        appModel: AppModel,
        navModel: UnifiedNavigationModel,
        onRequestDownloadInput: @escaping () -> Void,
        isCompact: Bool = false,
        onToggleSidebar: (() -> Void)? = nil
    ) {
        self.appModel = appModel
        self.navModel = navModel
        self.onRequestDownloadInput = onRequestDownloadInput
        self.isCompact = isCompact
        self.onToggleSidebar = onToggleSidebar
        self._workspace = ObservedObject(wrappedValue: appModel.sawWorkspace)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let onToggleSidebar {
                HStack(spacing: 0) {
                    Button(action: onToggleSidebar) {
                        Image(systemName: "sidebar.left")
                            .frame(width: headerButtonSize, height: 28)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isCompact ? "사이드바 펼치기" : "사이드바 접기")
                    .help(isCompact ? "사이드바 펼치기" : "사이드바 접기")
                    Spacer(minLength: 0)
                    // 전체 펼침/접힘: 펼친 상태·접힌 레일 모두 같은 expansion state만 토글(사이드바 폭은 변경하지 않음)
                    Button(action: toggleAllExpanded) {
                        Image(systemName: allExpanded ? "minus" : "plus")
                            .frame(width: headerButtonSize, height: 28)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(allExpanded ? "모두 접기" : "모두 펼치기")
                    .help(allExpanded ? "모두 접기" : "모두 펼치기")
                }
                .padding(.horizontal, isCompact ? 3 : 8)
                .frame(height: BrowserView.headerHeight)
                Divider()
            }
            if isCompact {
                compactRailBody
            } else {
                fullTreeBody
            }
        }
        .frame(maxHeight: .infinity)
        .background(palette.cardColor)
        .contentShape(Rectangle())
        .urlDropTarget(appModel: appModel)
        .onAppear {
            revealParentIfNeeded(navModel.destination)
            revealSettingsOwnerParentIfNeeded()
        }
        .onChange(of: navModel.destination) { newDest in
            revealParentIfNeeded(newDest)
            revealSettingsOwnerParentIfNeeded()
        }
        .onChange(of: navModel.settingsOwner) { _ in
            revealSettingsOwnerParentIfNeeded()
        }
        .onChange(of: appModel.selectedTabID) { _ in
            if navModel.destination == .browser {
                revealParentIfNeeded(.browser)
            }
        }
        .onChange(of: workspace.selectedProjectID) { _ in
            if navModel.destination == .planner {
                revealParentIfNeeded(.planner)
            }
        }
        .onChange(of: navModel.downloadTab) { _ in
            if navModel.destination == .downloads {
                revealParentIfNeeded(.downloads)
            }
        }
        .onChange(of: navModel.activeTranslationChild) { _ in
            if navModel.destination == .translation {
                revealParentIfNeeded(.translation)
            }
        }
        .onChange(of: navModel.activeInputChild) { _ in
            if navModel.destination == .inputHelper {
                revealParentIfNeeded(.inputHelper)
            }
        }
        .onChange(of: navModel.settingsTab) { _ in
            if navModel.destination == .settings {
                revealParentIfNeeded(.settings)
            }
        }
    }

    private var fullTreeBody: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 3) {
                    ForEach(Self.topDestinations) { dest in
                        destinationNode(dest)
                    }
                }
                .padding(.top, 10)
                .padding(.horizontal, 8)
            }

            SidebarUsageSection()
            helpFooter
        }
        .frame(minWidth: 200, maxWidth: 260)
    }

    private var compactRailBody: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 6) {
                    ForEach(Self.topDestinations) { dest in
                        compactDestinationItem(dest)
                    }
                }
                .padding(.top, 10)
                .padding(.horizontal, 4)
            }

            SidebarUsageCompact()
            helpFooter
        }
        .frame(minWidth: 55, maxWidth: 68)
    }

    private var helpFooter: some View {
        VStack(spacing: 0) {
            Divider()
            Button {
                navModel.navigateTo(destination: .help, appModel: appModel,
                    selectTool: selectTool, clearTool: clearHostedTool)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: MainNavDestination.help.iconName)
                    if !isCompact { Text(MainNavDestination.help.rawValue) }
                    if !isCompact { Spacer(minLength: 0) }
                }
                .font(.caption)
                .foregroundColor(palette.textColor)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity)
                .frame(height: BrowserView.footerHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(MainNavDestination.help.rawValue)
        }
    }

    @ViewBuilder
    private func compactDestinationItem(_ dest: MainNavDestination) -> some View {
        let isDestDirectSelected = (navModel.destination == dest)
        let isSettingsOwnerSelected = (navModel.destination == .settings && navModel.settingsOwner?.correspondingDestination == dest)
        let isDestSelected = isDestDirectSelected || isSettingsOwnerSelected

        let hasChildren = isExpandable(dest)
        let isExpanded = hasChildren && expandedDestinations.contains(dest)

        VStack(spacing: 3) {
          HStack(spacing: 0) {
            if hasChildren {
                Button {
                    toggleExpanded(dest)
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(palette.mutedColor)
                        .frame(width: 10, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "접기" : "펼치기")
                .accessibilityLabel("\(dest.rawValue) \(isExpanded ? "접기" : "펼치기")")
                .accessibilityAddTraits(.isButton)
            } else {
                Spacer().frame(width: 10)
            }
            Button {
                navModel.navigateTo(
                    destination: dest,
                    appModel: appModel,
                    selectTool: selectTool,
                    clearTool: clearHostedTool
                )
                if isExpandable(dest) {
                    expandedDestinations.insert(dest)
                }
            } label: {
                ZStack(alignment: .topTrailing) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isDestSelected ? palette.accentSoftColor : Color.clear)
                        .frame(width: 34, height: 40)

                    Image(systemName: dest.iconName)
                        .font(.system(size: 15))
                        .foregroundColor(isDestSelected ? palette.accentColor : palette.textColor)
                        .frame(width: 34, height: 40)

                    if dest == .downloads && activeQueueCount > 0 {
                        Text("\(activeQueueCount)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(palette.accentColor))
                            .offset(x: -2, y: 2)
                    }
                }
                .frame(width: 34, height: 40)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(dest == .downloads && activeQueueCount > 0 ? "\(dest.rawValue) (\(activeQueueCount)개 진행 중)" : dest.rawValue)
            .accessibilityLabel(dest == .downloads && activeQueueCount > 0 ? "\(dest.rawValue), 진행 중 \(activeQueueCount)개" : dest.rawValue)
            .accessibilityAddTraits(isDestSelected ? [.isButton, .isSelected] : [.isButton])
          }

            if isExpanded {
                compactDestinationChildren(dest)
            }
        }
    }

    /// 접힌 레일의 하위 항목: 펼친 레이아웃과 같은 expansion state/같은 navModel 동작을 아이콘+툴팁으로 표시한다.
    @ViewBuilder
    private func compactLeaf(icon: String, label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(selected ? palette.accentColor : palette.mutedColor)
                .frame(width: 32, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(selected ? palette.accentSoftColor : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : [.isButton])
    }

    @ViewBuilder
    private func compactSettingsLeaf(for owner: SettingsOwner, label: String) -> some View {
        compactLeaf(icon: "gearshape", label: label,
                    selected: navModel.destination == .settings && navModel.settingsOwner == owner) {
            navModel.openFeatureSettings(
                for: owner,
                appModel: appModel,
                currentToolID: hostedToolID,
                selectTool: selectTool,
                clearTool: clearHostedTool
            )
        }
    }

    @ViewBuilder
    private func compactDestinationChildren(_ dest: MainNavDestination) -> some View {
        VStack(spacing: 2) {
            switch dest {
            case .browser:
                compactSettingsLeaf(for: .browser, label: "브라우저 설정")
            case .downloads:
                compactLeaf(icon: "arrow.down.circle",
                            label: activeQueueCount > 0 ? "진행 중, \(activeQueueCount)개" : "진행 중",
                            selected: navModel.destination == .downloads && navModel.downloadTab == .queue) {
                    navModel.selectDownloadTab(.queue, appModel: appModel, clearTool: clearHostedTool)
                }
                compactLeaf(icon: "clock", label: "완료 기록",
                            selected: navModel.destination == .downloads && navModel.downloadTab == .history) {
                    navModel.selectDownloadTab(.history, appModel: appModel, clearTool: clearHostedTool)
                }
                compactLeaf(icon: "doc.on.clipboard", label: "링크 붙여넣고 받기", selected: false) {
                    navModel.selectDownloadTab(.queue, appModel: appModel, clearTool: clearHostedTool)
                    appModel.pasteLinksFromClipboard()
                }
                compactLeaf(icon: "link.badge.plus", label: "주소 직접 입력", selected: false) {
                    navModel.selectDownloadTab(.queue, appModel: appModel, clearTool: clearHostedTool)
                    onRequestDownloadInput()
                }
                compactSettingsLeaf(for: .downloads, label: "다운로드 설정")
            case .planner:
                ForEach(workspace.store.projects.filter { !$0.archived }) { proj in
                    compactLeaf(icon: "folder", label: "프로젝트: \(proj.title)",
                                selected: navModel.destination == .planner && proj.id == workspace.selectedProjectID) {
                        workspace.selectProject(proj.id)
                        let targetSess = workspace.session(for: proj.id)
                        if targetSess.tabs.isEmpty {
                            targetSess.newTab()
                        }
                        navModel.navigateTo(
                            destination: .planner,
                            appModel: appModel,
                            selectTool: selectTool,
                            clearTool: clearHostedTool
                        )
                    }
                }
                compactSettingsLeaf(for: .planner, label: "플래너 설정")
            case .translation:
                ForEach(["mail", "screen", "browser"], id: \.self) { id in
                    let item = ["mail": ("메일 번역", "envelope"), "screen": ("화면 번역", "viewfinder"), "browser": ("번역 확장", "puzzlepiece.extension")][id]!
                    compactLeaf(icon: item.1, label: item.0,
                                selected: navModel.destination == .translation && navModel.activeTranslationChild == id) {
                        navModel.selectTranslationChild(id, selectTool: selectTool)
                    }
                }
                compactSettingsLeaf(for: .translation, label: "번역 설정")
            case .inputHelper:
                ForEach(["input.appLanguage", "input.koreanTypo", "input.personalDictionary", "input.trackpad"], id: \.self) { id in
                    let item = ["input.appLanguage": ("앱별 언어 전환", "character.bubble"), "input.koreanTypo": ("한글 오타 교정", "pencil.and.outline"),
                                "input.personalDictionary": ("개인 사전", "book"), "input.trackpad": ("트랙패드 잠금", "hand.raised")][id]!
                    compactLeaf(icon: item.1, label: item.0,
                                selected: navModel.destination == .inputHelper && navModel.activeInputChild == id) {
                        navModel.selectInputChild(id, selectTool: selectTool)
                    }
                }
                compactSettingsLeaf(for: .inputHelper, label: "입력 도우미 설정")
            case .macManagement:
                ForEach(["macManagement", "cleanUSB"], id: \.self) { id in
                    let item = ["macManagement": ("Mac 관리", "desktopcomputer"), "cleanUSB": ("USB 드라이브 정리", "externaldrive")][id]!
                    compactLeaf(icon: item.1, label: item.0,
                                selected: navModel.destination == .macManagement && navModel.activeMacManagementChild == id) {
                        navModel.selectMacManagementChild(id, selectTool: selectTool)
                    }
                }
                compactSettingsLeaf(for: .macManagement, label: "Mac 관리 설정")
            case .server:
                compactSettingsLeaf(for: .server, label: "서버 현황 설정")
            default:
                EmptyView()
            }
        }
        .padding(.leading, 10)
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private func tabIconView(tab: LoginBrowserModel, size: CGFloat = 11) -> some View {
        let urlString = tab.currentURL?.absoluteString ?? ""
        Group {
            if tab.isShowingHome {
                Image(systemName: "house")
                    .font(.system(size: size))
                    .foregroundColor(navModel.destination == .browser && tab.tabID == appModel.selectedTabID ? palette.accentColor : palette.mutedColor)
            } else if !urlString.isEmpty, let favicon = bookmarkAppearance.appearance(for: urlString)?.favicon {
                Image(nsImage: favicon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size + 2, height: size + 2)
                    .clipShape(RoundedRectangle(cornerRadius: 2))
            } else {
                Image(systemName: "globe")
                    .font(.system(size: size))
                    .foregroundColor(navModel.destination == .browser && tab.tabID == appModel.selectedTabID ? palette.accentColor : palette.mutedColor)
            }
        }
        .onAppear {
            if !tab.isShowingHome && !urlString.isEmpty {
                bookmarkAppearance.loadIfNeeded(for: urlString)
            }
        }
        .task(id: urlString) {
            if !tab.isShowingHome && !urlString.isEmpty {
                bookmarkAppearance.loadIfNeeded(for: urlString)
            }
        }
    }

    private func isExpandable(_ dest: MainNavDestination) -> Bool {
        switch dest {
        case .browser, .downloads, .planner, .translation, .inputHelper, .macManagement, .server:
            return true
        default:
            return false
        }
    }

    private var expandableDestinations: Set<MainNavDestination> {
        Set((Self.topDestinations + Self.bottomDestinations).filter { isExpandable($0) })
    }

    private var allExpanded: Bool {
        expandableDestinations.isSubset(of: expandedDestinations)
    }

    private func toggleAllExpanded() {
        if allExpanded {
            expandedDestinations.subtract(expandableDestinations)
        } else {
            expandedDestinations.formUnion(expandableDestinations)
        }
    }

    private func toggleExpanded(_ dest: MainNavDestination) {
        if expandedDestinations.contains(dest) {
            expandedDestinations.remove(dest)
        } else {
            expandedDestinations.insert(dest)
        }
    }

    private func revealParentIfNeeded(_ dest: MainNavDestination) {
        if isExpandable(dest) && !expandedDestinations.contains(dest) {
            expandedDestinations.insert(dest)
        }
    }

    private func revealSettingsOwnerParentIfNeeded() {
        if navModel.destination == .settings, let owner = navModel.settingsOwner {
            let parentDest = owner.correspondingDestination
            if isExpandable(parentDest) && !expandedDestinations.contains(parentDest) {
                expandedDestinations.insert(parentDest)
            }
        }
    }

    @ViewBuilder
    private func destinationNode(_ dest: MainNavDestination) -> some View {
        let hasChildren = isExpandable(dest)
        let isExpanded = hasChildren && expandedDestinations.contains(dest)
        let isDestDirectSelected = (navModel.destination == dest)
        let isSettingsOwnerSelected = (navModel.destination == .settings && navModel.settingsOwner?.correspondingDestination == dest)
        let isDestSelected = isDestDirectSelected || isSettingsOwnerSelected

        VStack(spacing: 1) {
            HStack(spacing: 4) {
                if hasChildren {
                    Button {
                        toggleExpanded(dest)
                    } label: {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(palette.mutedColor)
                            .frame(width: 16, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(isExpanded ? "접기" : "펼치기")
                    .accessibilityLabel("\(dest.rawValue) \(isExpanded ? "접기" : "펼치기")")
                    .accessibilityAddTraits(.isButton)
                } else {
                    Spacer()
                        .frame(width: 16)
                }

                Button {
                    navModel.navigateTo(
                        destination: dest,
                        appModel: appModel,
                        selectTool: selectTool,
                        clearTool: clearHostedTool
                    )
                    if hasChildren && !isExpanded {
                        expandedDestinations.insert(dest)
                    }
                    if dest == .planner {
                        revealParentIfNeeded(.planner)
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: dest.iconName)
                            .font(.system(size: 14))
                            .frame(width: 18, height: 18)
                            .foregroundColor(isDestSelected ? palette.accentColor : palette.textColor)

                        Text(dest.rawValue)
                            .font(.system(size: 13, weight: isDestSelected ? .semibold : .regular))
                            .foregroundColor(isDestSelected ? palette.accentColor : palette.textColor)
                            .lineLimit(1)

                        Spacer()

                        if dest == .downloads && activeQueueCount > 0 {
                            Text("\(activeQueueCount)")
                                .font(.caption.bold())
                                .foregroundColor(palette.accentColor)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(palette.accentSoftColor))
                        }
                    }
                    .padding(.vertical, 5)
                    .padding(.trailing, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(dest == .downloads && activeQueueCount > 0 ? "\(dest.rawValue) (\(activeQueueCount)개 진행 중)" : dest.rawValue)
                .accessibilityLabel(dest == .downloads && activeQueueCount > 0 ? "\(dest.rawValue), 진행 중 \(activeQueueCount)개" : dest.rawValue)
                .accessibilityAddTraits(isDestSelected ? [.isButton, .isSelected] : [.isButton])
            }
            .padding(.leading, 4)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isDestSelected ? palette.accentSoftColor : Color.clear)
            )

            if isExpanded {
                destinationChildren(dest)
                    .padding(.bottom, 2)
            }
        }
    }

    @ViewBuilder
    private func destinationChildren(_ dest: MainNavDestination) -> some View {
        switch dest {
        case .browser:
            browserChildren
        case .downloads:
            downloadsChildren
        case .planner:
            plannerChildren
        case .translation:
            translationChildren
        case .inputHelper:
            inputHelperChildren
        case .macManagement:
            macManagementChildren
        case .server:
            serverChildren
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var browserChildren: some View {
        VStack(spacing: 2) {
            featureSettingsLeaf(for: .browser, label: "브라우저 설정")
        }
    }

    @ViewBuilder
    private var downloadsChildren: some View {
        VStack(spacing: 2) {
            let isQueueSelected = (navModel.destination == .downloads && navModel.downloadTab == .queue)
            Button {
                navModel.selectDownloadTab(.queue, appModel: appModel, clearTool: clearHostedTool)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 11))
                        .foregroundColor(isQueueSelected ? palette.accentColor : palette.mutedColor)
                    Text("진행 중")
                        .font(.system(size: 12, weight: isQueueSelected ? .semibold : .regular))
                        .foregroundColor(isQueueSelected ? palette.accentColor : palette.textColor)
                    Spacer()
                    if activeQueueCount > 0 {
                        Text("\(activeQueueCount)")
                            .font(.caption2.bold())
                            .foregroundColor(palette.accentColor)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(palette.accentSoftColor))
                    }
                }
                .padding(.leading, 26)
                .padding(.trailing, 8)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isQueueSelected ? palette.accentSoftColor : Color.clear)
            )
            .accessibilityLabel(activeQueueCount > 0 ? "진행 중, \(activeQueueCount)개" : "진행 중")
            .accessibilityAddTraits(isQueueSelected ? [.isButton, .isSelected] : [.isButton])

            let isHistorySelected = (navModel.destination == .downloads && navModel.downloadTab == .history)
            Button {
                navModel.selectDownloadTab(.history, appModel: appModel, clearTool: clearHostedTool)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "clock")
                        .font(.system(size: 11))
                        .foregroundColor(isHistorySelected ? palette.accentColor : palette.mutedColor)
                    Text("완료 기록")
                        .font(.system(size: 12, weight: isHistorySelected ? .semibold : .regular))
                        .foregroundColor(isHistorySelected ? palette.accentColor : palette.textColor)
                    Spacer()
                }
                .padding(.leading, 26)
                .padding(.trailing, 8)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHistorySelected ? palette.accentSoftColor : Color.clear)
            )
            .accessibilityLabel("완료 기록")
            .accessibilityAddTraits(isHistorySelected ? [.isButton, .isSelected] : [.isButton])

            Button {
                navModel.selectDownloadTab(.queue, appModel: appModel, clearTool: clearHostedTool)
                appModel.pasteLinksFromClipboard()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 10))
                    Text("링크 붙여넣고 받기")
                        .font(.system(size: 11))
                    Spacer()
                }
                .foregroundColor(palette.mutedColor)
                .padding(.leading, 26)
                .padding(.trailing, 8)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("클립보드의 주소로 다운로드를 시작합니다")
            .accessibilityLabel("링크 붙여넣고 받기")
            .accessibilityAddTraits(.isButton)

            Button {
                navModel.selectDownloadTab(.queue, appModel: appModel, clearTool: clearHostedTool)
                onRequestDownloadInput()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "link.badge.plus")
                        .font(.system(size: 10))
                    Text("주소 직접 입력")
                        .font(.system(size: 11))
                    Spacer()
                }
                .foregroundColor(palette.mutedColor)
                .padding(.leading, 26)
                .padding(.trailing, 8)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("주소를 직접 입력하여 다운로드합니다")
            .accessibilityLabel("주소 직접 입력")
            .accessibilityAddTraits(.isButton)

            featureSettingsLeaf(for: .downloads, label: "다운로드 설정")
        }
    }

    @ViewBuilder
    private var plannerChildren: some View {
        let activeProjects = workspace.store.projects.filter { !$0.archived }
        VStack(spacing: 2) {
            if activeProjects.isEmpty {
                Text("진행 중인 프로젝트가 없습니다.")
                    .font(.system(size: 11))
                    .foregroundColor(palette.mutedColor)
                    .padding(.leading, 26)
                    .padding(.trailing, 8)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(activeProjects) { proj in
                    let isProjectSelected = (navModel.destination == .planner && proj.id == workspace.selectedProjectID)
                    Button {
                        workspace.selectProject(proj.id)
                        let targetSess = workspace.session(for: proj.id)
                        if targetSess.tabs.isEmpty {
                            targetSess.newTab()
                        }
                        navModel.navigateTo(
                            destination: .planner,
                            appModel: appModel,
                            selectTool: selectTool,
                            clearTool: clearHostedTool
                        )
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "folder")
                                .font(.system(size: 11))
                                .foregroundColor(isProjectSelected ? palette.accentColor : palette.mutedColor)
                            Text(proj.title)
                                .font(.system(size: 12, weight: isProjectSelected ? .semibold : .regular))
                                .foregroundColor(isProjectSelected ? palette.accentColor : palette.textColor)
                                .lineLimit(1)
                            Spacer()
                        }
                        .padding(.leading, 26)
                        .padding(.trailing, 8)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(isProjectSelected ? palette.accentSoftColor : Color.clear)
                    )
                    .help(proj.title)
                    .accessibilityLabel("프로젝트: \(proj.title)")
                    .accessibilityAddTraits(isProjectSelected ? [.isButton, .isSelected] : [.isButton])
                }
            }

            featureSettingsLeaf(for: .planner, label: "플래너 설정")
        }
    }

    @ViewBuilder
    private var translationChildren: some View {
        let items: [(id: String, label: String, icon: String)] = [
            ("mail", "메일 번역", "envelope"),
            ("screen", "화면 번역", "viewfinder"),
            ("browser", "번역 확장", "puzzlepiece.extension")
        ]
        VStack(spacing: 2) {
            ForEach(items, id: \.id) { item in
                let isSelected = (navModel.destination == .translation && navModel.activeTranslationChild == item.id)
                Button {
                    navModel.selectTranslationChild(item.id, selectTool: selectTool)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: item.icon)
                            .font(.system(size: 11))
                            .foregroundColor(isSelected ? palette.accentColor : palette.mutedColor)
                        Text(item.label)
                            .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                            .foregroundColor(isSelected ? palette.accentColor : palette.textColor)
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(.leading, 26)
                    .padding(.trailing, 8)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isSelected ? palette.accentSoftColor : Color.clear)
                )
                .help(item.label)
                .accessibilityLabel(item.label)
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
            }

            featureSettingsLeaf(for: .translation, label: "번역 설정")
        }
    }

    @ViewBuilder
    private var inputHelperChildren: some View {
        let items: [(id: String, label: String, icon: String)] = [
            ("input.appLanguage", "앱별 언어 전환", "character.bubble"),
            ("input.koreanTypo", "한글 오타 교정", "pencil.and.outline"),
            ("input.personalDictionary", "개인 사전", "book"),
            ("input.trackpad", "트랙패드 잠금", "hand.raised")
        ]
        VStack(spacing: 2) {
            ForEach(items, id: \.id) { item in
                let isSelected = (navModel.destination == .inputHelper && navModel.activeInputChild == item.id)
                Button {
                    navModel.selectInputChild(item.id, selectTool: selectTool)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: item.icon)
                            .font(.system(size: 11))
                            .foregroundColor(isSelected ? palette.accentColor : palette.mutedColor)
                        Text(item.label)
                            .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                            .foregroundColor(isSelected ? palette.accentColor : palette.textColor)
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(.leading, 26)
                    .padding(.trailing, 8)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isSelected ? palette.accentSoftColor : Color.clear)
                )
                .help(item.label)
                .accessibilityLabel(item.label)
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
            }

            featureSettingsLeaf(for: .inputHelper, label: "입력 도우미 설정")
        }
    }

    @ViewBuilder
    private var macManagementChildren: some View {
        let items: [(id: String, label: String, icon: String)] = [
            ("macManagement", "Mac 관리", "desktopcomputer"),
            ("cleanUSB", "USB 드라이브 정리", "externaldrive")
        ]
        VStack(spacing: 2) {
            ForEach(items, id: \.id) { item in
                let isSelected = (navModel.destination == .macManagement && navModel.activeMacManagementChild == item.id)
                Button {
                    navModel.selectMacManagementChild(item.id, selectTool: selectTool)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: item.icon)
                            .font(.system(size: 11))
                            .foregroundColor(isSelected ? palette.accentColor : palette.mutedColor)
                        Text(item.label)
                            .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                            .foregroundColor(isSelected ? palette.accentColor : palette.textColor)
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(.leading, 26)
                    .padding(.trailing, 8)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isSelected ? palette.accentSoftColor : Color.clear)
                )
                .help(item.label)
                .accessibilityLabel(item.label)
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
            }

            featureSettingsLeaf(for: .macManagement, label: "Mac 관리 설정")
        }
    }

    @ViewBuilder
    private var serverChildren: some View {
        VStack(spacing: 2) {
            featureSettingsLeaf(for: .server, label: "서버 현황 설정")
        }
    }

    @ViewBuilder
    private func featureSettingsLeaf(for owner: SettingsOwner, label: String) -> some View {
        let isSettingsSelected = (navModel.destination == .settings && navModel.settingsOwner == owner)
        Button {
            navModel.openFeatureSettings(
                for: owner,
                appModel: appModel,
                currentToolID: hostedToolID,
                selectTool: selectTool,
                clearTool: clearHostedTool
            )
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "gearshape")
                    .font(.system(size: 11))
                    .foregroundColor(isSettingsSelected ? palette.accentColor : palette.mutedColor)
                Text(label)
                    .font(.system(size: 12, weight: isSettingsSelected ? .semibold : .regular))
                    .foregroundColor(isSettingsSelected ? palette.accentColor : palette.textColor)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.leading, 26)
            .padding(.trailing, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSettingsSelected ? palette.accentSoftColor : Color.clear)
        )
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSettingsSelected ? [.isButton, .isSelected] : [.isButton])
    }
}
