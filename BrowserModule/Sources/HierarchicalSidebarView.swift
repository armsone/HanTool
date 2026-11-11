import SwiftUI
import AppKit

struct HierarchicalSidebarView: View {
    @ObservedObject var appModel: AppModel
    @ObservedObject var navModel: UnifiedNavigationModel
    var onRequestDownloadInput: () -> Void
    @ObservedObject private var workspace: SAWWorkspace
    @Environment(\.bkPalette) private var palette
    @ObservedObject private var audioController = PageAudioController.shared

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
        .server
    ]

    private static let bottomDestinations: [MainNavDestination] = [
        .settings,
        .help
    ]

    private var activeQueueCount: Int {
        appModel.jobs.filter { !$0.state.isTerminal || $0.state == .interrupted || $0.state == .selectionChanged }.count
    }

    init(
        appModel: AppModel,
        navModel: UnifiedNavigationModel,
        onRequestDownloadInput: @escaping () -> Void
    ) {
        self.appModel = appModel
        self.navModel = navModel
        self.onRequestDownloadInput = onRequestDownloadInput
        self._workspace = ObservedObject(wrappedValue: appModel.sawWorkspace)
    }

    var body: some View {
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

            Divider()
                .padding(.horizontal, 10)
                .padding(.vertical, 6)

            VStack(spacing: 3) {
                ForEach(Self.bottomDestinations) { dest in
                    destinationNode(dest)
                }
            }
            .padding(.bottom, 12)
            .padding(.horizontal, 8)
        }
        .frame(minWidth: 200, maxWidth: 260)
        .frame(maxHeight: .infinity)
        .background(palette.cardColor)
        .contentShape(Rectangle())
        .urlDropTarget(appModel: appModel)
        .onAppear {
            revealParentIfNeeded(navModel.destination)
        }
        .onChange(of: navModel.destination) { newDest in
            revealParentIfNeeded(newDest)
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

    private func isExpandable(_ dest: MainNavDestination) -> Bool {
        switch dest {
        case .browser, .downloads, .planner, .translation, .inputHelper, .settings:
            return true
        default:
            return false
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

    @ViewBuilder
    private func destinationNode(_ dest: MainNavDestination) -> some View {
        let hasChildren = isExpandable(dest)
        let isExpanded = hasChildren && expandedDestinations.contains(dest)
        let isDestSelected = (navModel.destination == dest)

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
        case .settings:
            settingsChildren
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var browserChildren: some View {
        VStack(spacing: 2) {
            ForEach(appModel.tabs, id: \.tabID) { tab in
                let isTabSelected = (navModel.destination == .browser && tab.tabID == appModel.selectedTabID)
                let audioState = audioController.audioState(for: tab.webView)
                HStack(spacing: 2) {
                    Button {
                        appModel.selectTab(tab.tabID)
                        navModel.navigateTo(
                            destination: .browser,
                            appModel: appModel,
                            selectTool: selectTool,
                            clearTool: clearHostedTool
                        )
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: tab.isShowingHome ? "house" : "globe")
                                .font(.system(size: 11))
                                .foregroundColor(isTabSelected ? palette.accentColor : palette.mutedColor)

                            Text(tab.tabTitle)
                                .font(.system(size: 12, weight: isTabSelected ? .semibold : .regular))
                                .foregroundColor(isTabSelected ? palette.accentColor : palette.textColor)
                                .lineLimit(1)

                            Spacer(minLength: 0)

                            if audioState == .playingAudible {
                                Image(systemName: "speaker.wave.2.fill")
                                    .font(.caption2)
                                    .foregroundColor(palette.accentColor)
                            } else if audioState == .playingMuted {
                                Image(systemName: "speaker.slash.fill")
                                    .font(.caption2)
                                    .foregroundColor(palette.warnColor)
                            }
                        }
                        .padding(.leading, 26)
                        .padding(.trailing, 4)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(tab.tabTitle)
                    .accessibilityLabel("탭: \(tab.tabTitle)")
                    .accessibilityAddTraits(isTabSelected ? [.isButton, .isSelected] : [.isButton])

                    if appModel.tabs.count > 1 {
                        Button {
                            appModel.closeTab(tab.tabID)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9))
                                .foregroundColor(palette.mutedColor)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 4)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("탭 닫기")
                        .accessibilityLabel("탭 닫기: \(tab.tabTitle)")
                        .accessibilityAddTraits(.isButton)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isTabSelected ? palette.accentSoftColor : Color.clear)
                )
                .overlay(alignment: .bottom) {
                    if tab.isLoading {
                        GeometryReader { geo in
                            palette.accentColor
                                .frame(width: geo.size.width * CGFloat(max(0, min(1, tab.progress))), height: 1.5)
                        }
                        .frame(height: 1.5)
                        .allowsHitTesting(false)
                    }
                }
            }

            Button {
                if appModel.tabs.count < AppModel.maxTabs {
                    if let created = appModel.newTab() {
                        appModel.selectTab(created.tabID)
                    }
                    navModel.navigateTo(
                        destination: .browser,
                        appModel: appModel,
                        selectTool: selectTool,
                        clearTool: clearHostedTool
                    )
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .bold))
                    Text("새 탭")
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
            .disabled(appModel.tabs.count >= AppModel.maxTabs)
            .help("새 탭")
            .accessibilityLabel("새 탭 열기")
            .accessibilityAddTraits(.isButton)
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
        }
    }

    @ViewBuilder
    private var settingsChildren: some View {
        let tabs: [(tab: SettingsHubTab, icon: String)] = [
            (.general, "gearshape"),
            (.webSettings, "globe"),
            (.aiConnections, "sparkles"),
            (.inputSettings, "keyboard"),
            (.macSettings, "desktopcomputer"),
            (.serverSettings, "chart.bar.xaxis")
        ]
        VStack(spacing: 2) {
            ForEach(tabs, id: \.tab) { item in
                let isSelected = (navModel.destination == .settings && navModel.settingsTab == item.tab)
                Button {
                    navModel.selectSettingsTab(
                        item.tab,
                        appModel: appModel,
                        selectTool: selectTool,
                        clearTool: clearHostedTool
                    )
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: item.icon)
                            .font(.system(size: 11))
                            .foregroundColor(isSelected ? palette.accentColor : palette.mutedColor)
                        Text(item.tab.rawValue)
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
                .help(item.tab.rawValue)
                .accessibilityLabel("설정: \(item.tab.rawValue)")
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
            }
        }
    }
}
