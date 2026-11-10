import SwiftUI
import AppKit
import Combine

fileprivate struct SidebarDividerStyleInstaller: NSViewRepresentable {
    func makeNSView(context: Context) -> StyleInspectorView {
        StyleInspectorView()
    }

    func updateNSView(_ nsView: StyleInspectorView, context: Context) {
        nsView.scheduleInspection()
    }

    final class StyleInspectorView: NSView {
        private weak var observedSplit: NSSplitView?
        private let grip = PlannerNativeResizeHandle()
        private var dragStartPosition: CGFloat?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            setupGrip()
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            setupGrip()
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
            grip.removeFromSuperview()
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                NotificationCenter.default.removeObserver(self)
                grip.removeFromSuperview()
                observedSplit = nil
            } else {
                scheduleInspection()
            }
        }

        func scheduleInspection() {
            DispatchQueue.main.async { [weak self] in
                guard let self = self, let root = self.window?.contentView else { return }
                if let splitView = self.findFirstVerticalSplitView(in: root) {
                    if splitView.dividerStyle != .thick {
                        splitView.dividerStyle = .thick
                        splitView.needsLayout = true
                    }
                    if self.observedSplit !== splitView {
                        if let oldSplit = self.observedSplit {
                            NotificationCenter.default.removeObserver(
                                self,
                                name: NSSplitView.didResizeSubviewsNotification,
                                object: oldSplit
                            )
                        }
                        self.observedSplit = splitView
                        NotificationCenter.default.addObserver(
                            self,
                            selector: #selector(self.splitViewDidResizeSubviews(_:)),
                            name: NSSplitView.didResizeSubviewsNotification,
                            object: splitView
                        )
                    }
                    self.updateGripFrame()
                }
            }
        }

        @objc private func splitViewDidResizeSubviews(_ notification: Notification) {
            updateGripFrame()
        }

        private func setupGrip() {
            grip.onBegan = { [weak self] in
                guard let self = self,
                      let split = self.observedSplit,
                      split.arrangedSubviews.count >= 2 else { return }
                let firstPane = split.arrangedSubviews[0]
                self.dragStartPosition = firstPane.frame.width
            }

            grip.onChanged = { [weak self] delta in
                guard let self = self,
                      let split = self.observedSplit,
                      split.arrangedSubviews.count >= 2,
                      let start = self.dragStartPosition else { return }
                let upperBound = min(260.0, max(200.0, split.bounds.width - split.dividerThickness))
                let target = min(max(start + delta, 200.0), upperBound)
                split.setPosition(target, ofDividerAt: 0)
                split.adjustSubviews()
            }

            grip.onEnded = { [weak self] delta in
                guard let self = self else { return }
                if let split = self.observedSplit,
                   split.arrangedSubviews.count >= 2,
                   let start = self.dragStartPosition {
                    let upperBound = min(260.0, max(200.0, split.bounds.width - split.dividerThickness))
                    let target = min(max(start + delta, 200.0), upperBound)
                    split.setPosition(target, ofDividerAt: 0)
                    split.adjustSubviews()
                }
                self.dragStartPosition = nil
                self.updateGripFrame()
            }
        }

        private func updateGripFrame() {
            guard let split = observedSplit, let container = split.superview else {
                grip.isHidden = true
                return
            }
            guard split.arrangedSubviews.count >= 2 else {
                grip.isHidden = true
                return
            }
            let firstPane = split.arrangedSubviews[0]
            if firstPane.isHidden || firstPane.frame.width <= 0 || split.isSubviewCollapsed(firstPane) {
                grip.isHidden = true
                return
            }
            let dividerThickness = split.dividerThickness
            let dividerCenterX = firstPane.frame.maxX + (dividerThickness / 2.0)
            let gripWidth: CGFloat = 16.0
            let splitRect = NSRect(
                x: dividerCenterX - (gripWidth / 2.0),
                y: 0,
                width: gripWidth,
                height: split.bounds.height
            )
            let parentRect = container.convert(splitRect, from: split)
            if grip.frame != parentRect {
                grip.frame = parentRect
            }
            container.addSubview(grip, positioned: .above, relativeTo: split)
            grip.isHidden = false
        }

        private func findFirstVerticalSplitView(in view: NSView) -> NSSplitView? {
            if let sv = view as? NSSplitView, sv.isVertical {
                return sv
            }
            for subview in view.subviews {
                if let match = findFirstVerticalSplitView(in: subview) {
                    return match
                }
            }
            return nil
        }
    }
}

public struct MainView: View {
    @ObservedObject var appModel: AppModel
    @EnvironmentObject private var appearance: AppearanceStore
    @Environment(\.bkPalette) private var palette
    #if HTT_HOST
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    #else
    @State private var columnVisibility: NavigationSplitViewVisibility = .detailOnly
    #endif
    @State private var hasOpenedSAW: Bool = false
    @State private var projectRevealToken: Int = 0
    @ObservedObject private var adHide = BrowserAdHideManager.shared
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
    var toolView: AnyView? = nil
    @ObservedObject private var navModel = UnifiedNavigationModel.shared

    private var activeQueueCount: Int {
        appModel.jobs.filter { !$0.state.isTerminal || $0.state == .interrupted || $0.state == .selectionChanged }.count
    }

    public init(appModel: AppModel, toolView: AnyView? = nil) {
        self.appModel = appModel
        self.toolView = toolView
    }

    public var body: some View {
        #if HTT_HOST
        let isExpanded = (columnVisibility != .detailOnly)
        HSplitView {
            SidebarView(appModel: appModel, navModel: navModel)
            .frame(minWidth: isExpanded ? 200 : 0,
                   idealWidth: isExpanded ? 220 : 0,
                   maxWidth: isExpanded ? 260 : 0,
                   maxHeight: .infinity)
            .opacity(isExpanded ? 1 : 0)
            .clipped()
            .allowsHitTesting(isExpanded)
            .accessibilityHidden(!isExpanded)

            detailContentView
                .frame(minWidth: 500, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 860, idealWidth: 1120, maxWidth: .infinity,
               minHeight: 560, idealHeight: 760, maxHeight: .infinity)
        .background(SidebarDividerStyleInstaller().frame(width: 0, height: 0).allowsHitTesting(false).accessibilityHidden(true))
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    columnVisibility = (columnVisibility == .detailOnly) ? .all : .detailOnly
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .help(columnVisibility == .detailOnly ? "사이드바 보이기" : "사이드바 가리기")
                .accessibilityLabel(columnVisibility == .detailOnly ? "사이드바 보이기" : "사이드바 가리기")
            }
            if #available(macOS 26.0, *) {
                ToolbarItem(placement: .primaryAction) { browserControlBar }
                    .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .primaryAction) { browserControlBar }
            }
        }
        .sheet(isPresented: $navModel.isSpeedTestPresented) {
            SpeedTestView(appModel: appModel, connection: appModel.connection) {
                navModel.isSpeedTestPresented = false
            }
        }
        .alert(isPresented: $appModel.showingAlert) {
            Alert(
                title: Text("안내"),
                message: Text(appModel.alertMessage ?? ""),
                dismissButton: .default(Text("확인"))
            )
        }
        .onAppear {
            _ = appModel.sawWorkspace
            if appModel.selectedTab == .saw {
                hasOpenedSAW = true
            }
            navModel.syncFromExternal(hostedToolID: hostedToolID, selectedTab: appModel.selectedTab)
        }
        .onReceive(appModel.$selectedTab.dropFirst()) { newTab in
            if newTab == .saw {
                hasOpenedSAW = true
            } else if newTab == .speed {
                navModel.isSpeedTestPresented = true
                clearHostedTool()
                navModel.syncFromExternal(hostedToolID: nil, selectedTab: .browser)
                return
            } else if newTab == .pageVideos {
                appModel.isMediaCandidatePresented = true
                clearHostedTool()
                navModel.syncFromExternal(hostedToolID: nil, selectedTab: .browser)
                return
            } else if newTab == .ai {
                clearHostedTool()
                navModel.syncFromExternal(hostedToolID: nil, selectedTab: .ai)
                return
            }
            navModel.syncFromExternal(hostedToolID: hostedToolID, selectedTab: newTab)
        }
        .onChange(of: appModel.selectedTab) { currentTab in
            if currentTab == .speed || currentTab == .pageVideos {
                appModel.selectedTab = .browser
            }
        }
        .onChange(of: hostExport.hostedToolID) { newID in
            navModel.syncFromExternal(hostedToolID: newID, selectedTab: appModel.selectedTab)
        }
        #else
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(appModel: appModel, navModel: navModel)
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
        } detail: {
            detailContentView
        }
        .background(SidebarDividerStyleInstaller().frame(width: 0, height: 0).allowsHitTesting(false).accessibilityHidden(true))
        .toolbar {
            if #available(macOS 26.0, *) {
                ToolbarItem(placement: .primaryAction) { browserControlBar }
                    .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .primaryAction) { browserControlBar }
            }
        }
        .sheet(isPresented: $navModel.isSpeedTestPresented) {
            SpeedTestView(appModel: appModel, connection: appModel.connection) {
                navModel.isSpeedTestPresented = false
            }
        }
        .alert(isPresented: $appModel.showingAlert) {
            Alert(
                title: Text("안내"),
                message: Text(appModel.alertMessage ?? ""),
                dismissButton: .default(Text("확인"))
            )
        }
        .onAppear {
            _ = appModel.sawWorkspace
            if appModel.selectedTab == .saw {
                hasOpenedSAW = true
            }
            navModel.syncFromExternal(hostedToolID: hostedToolID, selectedTab: appModel.selectedTab)
        }
        .onReceive(appModel.$selectedTab.dropFirst()) { newTab in
            if newTab == .saw {
                hasOpenedSAW = true
            } else if newTab == .speed {
                navModel.isSpeedTestPresented = true
                clearHostedTool()
                navModel.syncFromExternal(hostedToolID: nil, selectedTab: .browser)
                return
            } else if newTab == .pageVideos {
                appModel.isMediaCandidatePresented = true
                clearHostedTool()
                navModel.syncFromExternal(hostedToolID: nil, selectedTab: .browser)
                return
            } else if newTab == .ai {
                clearHostedTool()
                navModel.syncFromExternal(hostedToolID: nil, selectedTab: .ai)
                return
            }
            navModel.syncFromExternal(hostedToolID: hostedToolID, selectedTab: newTab)
        }
        .onChange(of: appModel.selectedTab) { currentTab in
            if currentTab == .speed || currentTab == .pageVideos {
                appModel.selectedTab = .browser
            }
        }
        #endif
    }

    private var detailContentView: some View {
        HStack(spacing: 0) {
            if columnVisibility == .detailOnly {
                CompactSidebarRail(appModel: appModel, navModel: navModel, expand: {
                    columnVisibility = .all
                })
                Divider()
            }
            GeometryReader { proxy in
            VStack(spacing: 0) {
                if navModel.destination == .downloads {
                    DownloadsHubHeaderView(
                        activeTab: $navModel.downloadTab,
                        activeQueueCount: activeQueueCount,
                        onTabChanged: { tab in
                            navModel.selectDownloadTab(tab, appModel: appModel, clearTool: clearHostedTool)
                        },
                        onStartWithURL: {
                            navModel.navigateTo(destination: .browser, appModel: appModel, selectTool: selectTool, clearTool: clearHostedTool)
                            appModel.requestAddressFocus(for: appModel.browser, isExplicit: true)
                        }
                    )
                    Divider()
                    HeaderAddressBar(appModel: appModel)
                    Divider()
                } else if navModel.destination == .settings {
                    SettingsHubHeaderView(
                        activeTab: $navModel.settingsTab,
                        onTabChanged: { tab in
                            navModel.selectSettingsTab(tab, appModel: appModel, selectTool: selectTool, clearTool: clearHostedTool)
                        },
                        onOpenInputTool: { toolID in
                            selectTool(toolID)
                        },
                        onOpenMacManagement: {
                            selectTool("macManagement")
                        },
                        onOpenBrowser: {
                            navModel.navigateTo(destination: .browser, appModel: appModel, selectTool: selectTool, clearTool: clearHostedTool)
                        },
                        onOpenBrowserSetup: {
                            selectTool("browser")
                        }
                    )
                    Divider()
                } else if navModel.destination == .translation {
                    TranslationHeaderView(
                        activeChild: $navModel.activeTranslationChild,
                        onSelectChild: { childID in
                            navModel.selectTranslationChild(childID, selectTool: selectTool)
                        },
                        onOpenWebSettings: {
                            navModel.selectSettingsTab(.webSettings, appModel: appModel, selectTool: selectTool, clearTool: clearHostedTool)
                        }
                    )
                    Divider()
                } else if navModel.destination == .inputHelper {
                    InputHelperHeaderView(
                        activeChild: $navModel.activeInputChild,
                        onSelectChild: { childID in
                            navModel.selectInputChild(childID, selectTool: selectTool)
                        },
                        onOpenInputSettings: {
                            navModel.selectSettingsTab(.inputSettings, appModel: appModel, selectTool: selectTool, clearTool: clearHostedTool)
                        }
                    )
                    Divider()
                } else if navModel.destination == .macManagement {
                    MacManagementHeaderView(
                        activeChild: $navModel.activeMacManagementChild,
                        onSelectChild: { childID in
                            navModel.selectMacManagementChild(childID, selectTool: selectTool)
                        },
                        onOpenMacSettings: {
                            navModel.selectSettingsTab(.macSettings, appModel: appModel, selectTool: selectTool, clearTool: clearHostedTool)
                        }
                    )
                    Divider()
                }

                if let feedback = appModel.dropFeedback {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle.fill")
                            .foregroundColor(palette.accentColor)
                        Text(feedback)
                            .font(.caption)
                            .foregroundColor(palette.textColor)
                        Spacer()
                        Button {
                            appModel.dropFeedback = nil
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption2)
                                .foregroundColor(palette.textColor.opacity(0.7))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("안내 닫기")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(palette.accentSoftColor)
                }
                if let reason = appModel.queueBlockedReason {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundColor(palette.warnColor)
                        Text(reason).font(.caption).foregroundColor(palette.warnInkColor)
                        Spacer()
                        Button("엔진 정리 재확인") { appModel.recheckEngineCleanup() }
                            .buttonStyle(.bordered)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(palette.warnSoftColor)
                }

                ZStack(alignment: .topLeading) {
                    SAWTeamBackgroundHosts(workspace: appModel.sawWorkspace, plannerHostMounted: hasOpenedSAW || navModel.destination == .planner)
                        .allowsHitTesting(false)
                    Rectangle().fill(palette.bgColor)
                        .allowsHitTesting(false)

                    let isBrowserActive = navModel.destination == .browser && hostedToolID == nil
                    BrowserView(appModel: appModel)
                        .frame(width: max(proxy.size.width, 1), alignment: .topLeading)
                        .opacity(isBrowserActive ? 1 : 0)
                        .allowsHitTesting(isBrowserActive)
                        .accessibilityHidden(!isBrowserActive)

                    let isSawActive = navModel.destination == .planner && hostedToolID == nil
                    if hasOpenedSAW || navModel.destination == .planner {
                        SAWView(workspace: appModel.sawWorkspace, projectRevealToken: projectRevealToken) {
                            columnVisibility = .all
                        }
                        .frame(width: max(proxy.size.width, 1), alignment: .topLeading)
                        .opacity(isSawActive ? 1 : 0)
                        .allowsHitTesting(isSawActive)
                        .accessibilityHidden(!isSawActive)
                    }

                    let isAIActive = navModel.destination == .settings && navModel.settingsTab == .aiConnections && hostedToolID == nil
                    AIServiceSettingsView(appModel: appModel)
                        .frame(width: max(proxy.size.width, 1), alignment: .topLeading)
                        .opacity(isAIActive ? 1 : 0)
                        .allowsHitTesting(isAIActive)
                        .accessibilityHidden(!isAIActive)

                    let isDownloadsActive = navModel.destination == .downloads && hostedToolID == nil
                    Group {
                        if navModel.downloadTab == .queue {
                            QueueListView(appModel: appModel)
                        } else {
                            HistoryListView(appModel: appModel)
                        }
                    }
                    .frame(width: max(proxy.size.width, 1), alignment: .topLeading)
                    .opacity(isDownloadsActive ? 1 : 0)
                    .allowsHitTesting(isDownloadsActive)
                    .accessibilityHidden(!isDownloadsActive)

                    let isWebSettingsActive = navModel.destination == .settings && navModel.settingsTab == .webSettings && hostedToolID == nil
                    SettingsView(appModel: appModel)
                        .frame(width: max(proxy.size.width, 1), alignment: .topLeading)
                        .opacity(isWebSettingsActive ? 1 : 0)
                        .allowsHitTesting(isWebSettingsActive)
                        .accessibilityHidden(!isWebSettingsActive)

                    let isHostToolActive = hostedToolID != nil
                    if let hostTool = toolView {
                        hostTool
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(palette.bgColor)
                            .zIndex(isHostToolActive ? 100 : -1)
                            .opacity(isHostToolActive ? 1 : 0)
                            .allowsHitTesting(isHostToolActive)
                            .accessibilityHidden(!isHostToolActive)
                    }
                }
                .frame(width: max(proxy.size.width, 1), alignment: .topLeading)
                .frame(minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
            }
            .frame(width: max(proxy.size.width, 0), height: max(proxy.size.height, 0), alignment: .topLeading)
            .background(palette.bgColor)
            .clipped()
            }
        }
    }

    private var browserControlBar: some View {
        HStack(spacing: 4) {
            PageAudioControls(appModel: appModel)
                .fixedSize()
            Button {
                navModel.isSpeedTestPresented = true
            } label: {
                NetworkRateIndicator()
            }
            .buttonStyle(.plain)
            .accessibilityHint("속도 테스트 열기")
            .help("속도 테스트 열기")

            Button(action: selectDestinationFolder) {
                HStack(spacing: 4) {
                    Text(URL(fileURLWithPath: appModel.destinationFolder).lastPathComponent)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .foregroundColor(palette.textColor)
                .padding(.horizontal, 14)
                .frame(height: 26)
                .fixedSize(horizontal: true, vertical: false)
                .background(Capsule().fill(palette.surfaceColor))
            }
            .buttonStyle(.plain)
            .help("저장 폴더 변경")
            .accessibilityLabel("저장 폴더 변경")

            HStack(spacing: 6) {
                Button {
                    BrowserAdHideManager.shared.toggle(appModel: appModel, model: appModel.browser)
                } label: {
                    Text("광고").fixedSize()
                    .font(.caption.bold())
                    .foregroundColor(adHide.isEditing ? palette.accentColor : palette.textColor)
                }
                .buttonStyle(.plain)
                .help("광고 숨기기 편집: 이 페이지에서 숨길 부분을 드래그하거나, 이미 숨긴 영역(점선)을 클릭해 해제합니다. 선택한 요소만 숨기며(안정적으로 찾을 수 있으면 같은 사이트의 다른 페이지에서도 숨김) 네트워크 요청은 바뀌지 않습니다. 오른쪽 스위치와는 별개입니다.")
                .accessibilityLabel("광고 숨기기 편집")
                Toggle("광고 차단", isOn: Binding(
                    get: { appModel.preferences.adBlockingEnabled },
                    set: { newValue in
                        appModel.preferences.setAdBlockingEnabled(newValue)
                        for tab in appModel.tabs {
                            tab.setAdBlockingEnabled(newValue)
                        }
                    }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .fixedSize()
                    .help("웹 페이지 안의 주요 서드파티 광고 도메인 연결을 차단합니다. 브라우저 화면에만 적용되며 외부 전송이나 추가 다운로드 없이 동작합니다.")
                    .accessibilityLabel("광고 차단")
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(Capsule().fill(palette.surfaceColor))
            .fixedSize()

            ConnectionHelpSwitch(appModel: appModel, connection: appModel.connection)
                .fixedSize()

            BrowserPopupSwitch(appModel: appModel, browser: appModel.browser)
                .fixedSize()


            AIPanelSwitch(appModel: appModel)
                .fixedSize()

            ThemeButton(store: appearance)
                .frame(width: 26, height: 26)
        }
        .padding(4)
        .modifier(BrowserControlBarBackground())
        .fixedSize()
    }

    private func selectDestinationFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "선택"
        panel.directoryURL = URL(fileURLWithPath: appModel.destinationFolder)

        if panel.runModal() == .OK, let chosen = panel.url {
            appModel.setDestinationFolder(chosen.path)
        }
    }
}

// MARK: - Compact sidebar rail

/// Icon-only rail shown when the native sidebar is collapsed (`.detailOnly`). Native 6+2 navigation.
struct CompactSidebarRail: View {
    @ObservedObject var appModel: AppModel
    @ObservedObject var navModel: UnifiedNavigationModel
    var expand: () -> Void
    var onRevealProject: (() -> Void)? = nil
    @Environment(\.bkPalette) private var palette

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

    private static let topDestinations: [MainNavDestination] = [
        .browser, .downloads, .planner, .translation, .inputHelper, .macManagement, .server
    ]
    private static let bottomDestinations: [MainNavDestination] = [
        .settings, .help
    ]

    private var activeQueueCount: Int {
        appModel.jobs.filter { !$0.state.isTerminal || $0.state == .interrupted || $0.state == .selectionChanged }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: expand) {
                Image(systemName: "sidebar.left")
                    .frame(width: 36, height: 32)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .help("사이드바 펼치기")
            .accessibilityLabel("사이드바 펼치기")
            .padding(.top, 8)

            VStack(spacing: 6) {
                ForEach(Self.topDestinations) { dest in
                    railButton(dest)
                }
            }
            .padding(.top, 6)

            Spacer()

            Divider()
                .frame(width: 28)
                .padding(.vertical, 4)

            VStack(spacing: 6) {
                ForEach(Self.bottomDestinations) { dest in
                    railButton(dest)
                }
            }
            .padding(.bottom, 10)
        }
        .frame(width: 56)
        .frame(maxHeight: .infinity)
        .background(palette.cardColor)
        .contentShape(Rectangle())
        .urlDropTarget(appModel: appModel)
    }

    @ViewBuilder
    private func railButton(_ dest: MainNavDestination) -> some View {
        let isSelected = navModel.destination == dest
        Button {
            navModel.navigateTo(
                destination: dest,
                appModel: appModel,
                selectTool: selectTool,
                clearTool: clearHostedTool
            )
        } label: {
            Image(systemName: dest.iconName)
                .font(.system(size: 16))
                .foregroundColor(isSelected ? palette.accentColor : palette.textColor.opacity(0.8))
                .frame(width: 40, height: 36)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isSelected ? palette.accentSoftColor : Color.clear)
                )
                .overlay(alignment: .topTrailing) {
                    if dest == .downloads && activeQueueCount > 0 {
                        Text("\(activeQueueCount)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(palette.accentColor)
                            .padding(.horizontal, 4)
                            .background(Capsule().fill(palette.accentSoftColor))
                    }
                }
        }
        .buttonStyle(.plain)
        .help(dest == .downloads && activeQueueCount > 0 ? "다운로드 (\(activeQueueCount)개 진행 중)" : dest.rawValue)
        .accessibilityLabel(dest == .downloads && activeQueueCount > 0 ? "\(dest.rawValue), 진행 중 \(activeQueueCount)개" : dest.rawValue)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
    }
}
private struct CompactProjectRailSection: View {
    @ObservedObject var workspace: SAWWorkspace
    @ObservedObject var appModel: AppModel
    var onRevealProject: (() -> Void)?
    @Environment(\.bkPalette) private var palette

    #if HTT_HOST
    private func clearHostedTool() { HTDHostExport.shared.clearHostedTool() }
    #else
    private func clearHostedTool() {}
    #endif

    var body: some View {
        VStack(spacing: 4) {
            ForEach(workspace.store.projects.filter { !$0.archived }) { project in
                if let session = workspace.existingSession(for: project.id) {
                    CompactProjectSessionRow(
                        project: project,
                        workspace: workspace,
                        appModel: appModel,
                        session: session,
                        onRevealProject: onRevealProject
                    )
                } else {
                    let isSelected = workspace.selectedProjectID == project.id && appModel.selectedTab == .saw
                    let title = sawDisplayProjectTitle(project)
                    let rawStatus = workspace.runs(for: project.id).first?.status ?? "queued"
                    let status = sawStatusKorean(rawStatus)
                    let summary = meaningfulSummary(session: nil, project: project).components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
                    let tooltipText = "\(sawTestProjectPrefix(project))\(title) · \(status) · \(summary)"
                    Button(action: {
                        clearHostedTool()
                        workspace.selectProject(project.id)
                        appModel.selectedTab = .saw
                        let sess = workspace.session(for: project.id)
                        if sess.tabs.isEmpty { sess.newTab() }
                        onRevealProject?()
                    }) {
                        compactProjectStatusIcon(rawStatus, palette: palette)
                            .frame(width: 40, height: 32)
                            .background(RoundedRectangle(cornerRadius: 6).fill(isSelected ? palette.accentSoftColor : Color.clear))
                    }
                    .buttonStyle(.plain)
                    .help(tooltipText)
                    .accessibilityLabel(tooltipText)
                    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
                }
            }
            Button {
                clearHostedTool()
                appModel.selectedTab = .saw
                let p = workspace.createProject(title: "새 프로젝트", goal: "")
                let sess = workspace.session(for: p.id)
                if sess.tabs.isEmpty { sess.newTab() }
                onRevealProject?()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(palette.textColor.opacity(0.7))
                    .frame(width: 40, height: 32)
                    .background(RoundedRectangle(cornerRadius: 6).strokeBorder(palette.cardColor, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("새 프로젝트")
            .accessibilityLabel("새 프로젝트")
        }
    }
}

@ViewBuilder
private func compactProjectStatusIcon(_ status: String, palette: Palette) -> some View {
    let color = sawStatusColor(status, palette: palette)
    switch status {
    case "running":
        ProgressView()
            .progressViewStyle(.circular)
            .controlSize(.small)
    case "paused", "userControl":
        Image(systemName: "pause.fill")
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(color)
    case "completed":
        Image(systemName: "circle.fill")
            .font(.system(size: 12))
            .foregroundColor(color)
    case "failed", "interrupted", "needsUser":
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 11))
            .foregroundColor(color)
    default:
        Image(systemName: "circle")
            .font(.system(size: 11))
            .foregroundColor(color)
    }
}

private struct CompactProjectSessionRow: View {
    let project: SAWProject
    @ObservedObject var workspace: SAWWorkspace
    @ObservedObject var appModel: AppModel
    @ObservedObject var session: SAWProjectSession
    var onRevealProject: (() -> Void)?
    @Environment(\.bkPalette) private var palette

    #if HTT_HOST
    private func clearHostedTool() { HTDHostExport.shared.clearHostedTool() }
    #else
    private func clearHostedTool() {}
    #endif

    private var isSelected: Bool {
        workspace.selectedProjectID == project.id && appModel.selectedTab == .saw
    }

    private var tooltipText: String {
        let title = sawDisplayProjectTitle(project)
        let kor = sawStatusKorean(session.runStatus)
        let rawSummary = meaningfulSummary(session: session, project: project)
        let summary = rawSummary.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        return "\(sawTestProjectPrefix(project))\(title) · \(kor) · \(summary)"
    }

    var body: some View {
        Button {
            clearHostedTool()
            workspace.selectProject(project.id)
            appModel.selectedTab = .saw
            let sess = workspace.session(for: project.id)
            if sess.tabs.isEmpty { sess.newTab() }
            onRevealProject?()
        } label: {
            compactProjectStatusIcon(session.runStatus, palette: palette)
                .frame(width: 40, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isSelected ? palette.accentSoftColor : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .help(tooltipText)
        .accessibilityLabel(tooltipText)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @ObservedObject var appModel: AppModel
    @ObservedObject var navModel: UnifiedNavigationModel
    @Environment(\.bkPalette) var palette

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

    private static let topDestinations: [MainNavDestination] = [
        .browser, .downloads, .planner, .translation, .inputHelper, .macManagement, .server
    ]
    private static let bottomDestinations: [MainNavDestination] = [
        .settings, .help
    ]

    private var activeQueueCount: Int {
        appModel.jobs.filter { !$0.state.isTerminal || $0.state == .interrupted || $0.state == .selectionChanged }.count
    }

    init(appModel: AppModel, navModel: UnifiedNavigationModel) {
        self.appModel = appModel
        self.navModel = navModel
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 3) {
                ForEach(Self.topDestinations) { dest in
                    sidebarRow(dest)
                }
            }
            .padding(.top, 10)
            .padding(.horizontal, 10)

            Spacer()

            Divider()
                .padding(.horizontal, 10)
                .padding(.vertical, 6)

            VStack(spacing: 3) {
                ForEach(Self.bottomDestinations) { dest in
                    sidebarRow(dest)
                }
            }
            .padding(.bottom, 12)
            .padding(.horizontal, 10)
        }
        .frame(minWidth: 200, maxWidth: 260)
        .frame(maxHeight: .infinity)
        .background(palette.cardColor)
        .contentShape(Rectangle())
        .urlDropTarget(appModel: appModel)
    }

    @ViewBuilder
    private func sidebarRow(_ dest: MainNavDestination) -> some View {
        let isSelected = navModel.destination == dest
        Button {
            navModel.navigateTo(
                destination: dest,
                appModel: appModel,
                selectTool: selectTool,
                clearTool: clearHostedTool
            )
        } label: {
            HStack(spacing: 10) {
                Image(systemName: dest.iconName)
                    .font(.system(size: 15))
                    .frame(width: 20, height: 20)
                    .foregroundColor(isSelected ? palette.accentColor : palette.textColor)

                Text(dest.rawValue)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? palette.accentColor : palette.textColor)
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
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isSelected ? palette.accentSoftColor : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .help(dest == .downloads && activeQueueCount > 0 ? "다운로드 (\(activeQueueCount)개 진행 중)" : dest.rawValue)
        .accessibilityLabel(dest == .downloads && activeQueueCount > 0 ? "\(dest.rawValue), 진행 중 \(activeQueueCount)개" : dest.rawValue)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
    }
}

// MARK: - Header Address Bar

struct HeaderAddressBar: View {
    @ObservedObject var appModel: AppModel
    @ObservedObject var session: SessionManager
    @ObservedObject var connection: ConnectionManager
    @Environment(\.bkPalette) private var palette

    init(appModel: AppModel) {
        self.appModel = appModel
        self.session = appModel.session
        self.connection = appModel.connection
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if appModel.selectedTab != .browser {
                HStack(spacing: 8) {
                    TextField("다운로드할 웹 주소(URL)를 입력하세요", text: $appModel.urlInput)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            appModel.addJobFromInput()
                        }
                        .accessibilityLabel("다운로드할 웹 주소")

                    Button(action: {
                        appModel.addJobFromInput()
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "magnifyingglass")
                            Text("분석")
                        }
                        .padding(.horizontal, 6)
                    }
                    .buttonStyle(.bkProminent)
                    .disabled(appModel.urlInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button(action: { appModel.openLoginWindowFromInput() }) {
                        HStack(spacing: 4) {
                            Image(systemName: "person.badge.key")
                            Text("로그인")
                        }
                    }
                    .buttonStyle(.bordered)
                    .help("앱 안 '브라우저'에서 사이트에 직접 로그인합니다. 주소창에 입력한 주소가 있으면 그 페이지를 엽니다.")
                    .accessibilityLabel("앱 안 브라우저에서 로그인")

                    Button(action: { appModel.pasteLinksFromClipboard() }) {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.on.clipboard")
                            Text("링크 붙여넣기")
                        }
                    }
                    .buttonStyle(.bordered)
                    .help("클립보드에 복사된 웹 주소를 눌렀을 때만 읽어 분석 후 바로 다운로드합니다.")
                    .accessibilityLabel("클립보드의 링크 붙여넣어 분석")
                }

                if session.isAlive {
                    HStack(spacing: 12) {
                        Toggle("이 주소에 로그인 세션 사용", isOn: $appModel.useLoginSessionForInput)
                            .toggleStyle(.checkbox)
                            .font(.caption)
                            .accessibilityLabel("입력한 주소에 앱 전용 로그인 세션 사용")
                        Text("해당 사이트의 로그인 정보만 이 작업에 쓰입니다.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }
            }

            if case .failed = connection.status {
                Text(connection.statusText)
                    .font(.caption2)
                    .foregroundColor(palette.warnColor)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(palette.cardColor)
        .urlDropTarget(appModel: appModel)
    }
}
// MARK: - HTTPS 연결 도움 (the one switch + blocked-connection recovery)

/// The only user control of connection assist: proxy + TLS first-record split together. Shown in the header of
/// the sidebar settings section, with the real helper state next to it (never "사용 중" before the helper is ready with the split).
struct ConnectionHelpSwitch: View {
    @ObservedObject var appModel: AppModel
    @ObservedObject var connection: ConnectionManager
    @Environment(\.bkPalette) var palette

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                Text("우회").fixedSize()
                    .font(.caption.bold())
                    .foregroundColor(palette.textColor)
                Toggle("HTTPS 연결 도움", isOn: Binding(
                    get: { connection.enabled },
                    set: { appModel.setConnectionAssist($0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(.caption.bold())
                    .disabled(appModel.hasActiveRun || appModel.isMeasuringSpeed)
                    .help(appModel.isMeasuringSpeed ? "속도 측정 중에는 연결 방식을 바꿀 수 없습니다."
                          : "켜면 이 앱의 분석·다운로드와 앱 안 브라우저가 앱 전용 연결 경로를 거치고, 첫 TLS 메시지를 나눠 보냅니다. "
                          + "다른 앱이나 시스템 설정은 바꾸지 않습니다. 연결을 바꾸면 페이지가 다시 열리고 로그인 데이터는 유지됩니다. "
                          + "모든 사이트의 접속을 보장하지는 않습니다.")
                    .accessibilityLabel("HTTPS 연결 도움")
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(Capsule().fill(palette.surfaceColor))
        }
        .accessibilityElement(children: .contain)
        .accessibilityValue("HTTPS 연결 도움 상태: \(connection.shortStatus)")
    }
}

struct BrowserPopupSwitch: View {
    @ObservedObject var appModel: AppModel
    @ObservedObject var browser: LoginBrowserModel
    @ObservedObject var permissions = PopupSitePermissions.shared
    @Environment(\.bkPalette) var palette

    private var currentHost: String? {
        guard appModel.selectedTab == .browser,
              appModel.browser === browser,
              !browser.isShowingHome,
              let scheme = browser.popupCommittedURL?.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let rawHost = browser.popupCommittedURL?.host,
              let normalized = PopupSitePermissions.normalizeHost(rawHost) else {
            return nil
        }
        return normalized
    }

    var body: some View {
        let host = currentHost
        HStack(spacing: 6) {
            Text("팝업").fixedSize()
                .font(.caption.bold())
                .foregroundColor(palette.textColor)
            Toggle("팝업 허용", isOn: Binding(
                get: {
                    guard let host = host else { return false }
                    return permissions.isAllowed(host: host)
                },
                set: { allow in
                    guard let host = host, host == currentHost else { return }
                    if allow {
                        permissions.add(input: host)
                    } else {
                        permissions.remove(host: host)
                    }
                }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(host == nil)
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(Capsule().fill(palette.surfaceColor))
        .help("현재 도메인에만 적용되며 새로고침 후 반영됩니다.")
    }
}

struct AIPanelSwitch: View {
    @ObservedObject var appModel: AppModel
    @ObservedObject var aiStore: AIServiceStore
    @ObservedObject private var navModel = UnifiedNavigationModel.shared
    @Environment(\.bkPalette) var palette

    #if HTT_HOST
    private func selectTool(_ id: String) { HTDHostExport.shared.selectToolFromSidebar(id) }
    private func clearHostedTool() { HTDHostExport.shared.clearHostedTool() }
    #else
    private func selectTool(_ id: String) {}
    private func clearHostedTool() {}
    #endif

    init(appModel: AppModel) {
        self.appModel = appModel
        self.aiStore = appModel.aiServices
    }

    private var hasAnyEnabled: Bool {
        !aiStore.enabledServices.isEmpty
    }

    private var selectedName: String {
        hasAnyEnabled ? aiStore.selectedService.name : "사용 안 함"
    }

    var body: some View {
        HStack(spacing: 6) {
            Menu {
                if aiStore.enabledServices.isEmpty {
                    Text("설정 > AI 연결에서 사용할 AI를 켜 주세요")
                        .font(.caption)

                    Divider()
                } else {
                    ForEach(aiStore.enabledServices) { service in
                        Button {
                            chooseService(service.id)
                        } label: {
                            if service.id == aiStore.selectedServiceID {
                                Label(service.name, systemImage: "checkmark")
                            } else {
                                Text(service.name)
                            }
                        }
                    }

                    Divider()
                }

                Button {
                    navModel.selectSettingsTab(.aiConnections, appModel: appModel, selectTool: selectTool, clearTool: clearHostedTool)
                } label: {
                    Label("AI 연결 설정…", systemImage: "gearshape")
                }
            } label: {
                Text("비서").fixedSize()
                    .font(.caption.bold())
                    .foregroundColor(palette.textColor)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("기본 AI 서비스 빠른 선택 (\(selectedName))")
            .accessibilityLabel("기본 AI 서비스 빠른 선택 메뉴 (\(selectedName))")

            Toggle("비서 대화창 (\(selectedName))", isOn: Binding(
                get: { appModel.isAIPanelOpen },
                set: { val in
                    if val && !hasAnyEnabled {
                        navModel.selectSettingsTab(.aiConnections, appModel: appModel, selectTool: selectTool, clearTool: clearHostedTool)
                    } else {
                        appModel.setAIPanelOpen(val)
                    }
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .fixedSize()
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(Capsule().fill(palette.surfaceColor))
        .help(hasAnyEnabled
              ? "비서 대화창을 열거나 닫습니다 (\(selectedName)). 닫아도 대화 내용은 유지됩니다."
              : "켜져 있는 AI 서비스가 없습니다. 클릭하면 설정 > AI 연결로 이동합니다.")
        .accessibilityLabel("비서 대화창 토글 (\(selectedName))")
    }

    private func chooseService(_ id: String) {
        aiStore.selectService(id: id)
        appModel.temporaryShowHanaPanel = false
        appModel.selectedTab = .browser
        appModel.setAIPanelOpen(true)
    }
}

// MARK: - Page Audio Controls

struct PageAudioControls: View {
    @ObservedObject var appModel: AppModel
    @ObservedObject private var audioController = PageAudioController.shared
    @Environment(\.bkPalette) var palette

    var body: some View {
        Menu {
            Button {
                audioController.toggleGlobalMute()
            } label: {
                Text(audioController.isGlobalMuted ? "전체 음소거 해제" : "전체 음소거")
            }
            Divider()
            if audioController.activeAudioEntries.isEmpty {
                Text("재생 중인 페이지 없음")
                    .disabled(true)
            } else {
                ForEach(audioController.activeAudioEntries) { entry in
                    Button {
                        entry.jump(appModel: appModel)
                    } label: {
                        HStack {
                            Text(entry.displayLabel)
                            if entry.isAudible {
                                Text("🔊")
                            } else {
                                Text("🔇")
                            }
                        }
                    }
                    .disabled(!entry.canJump)
                }
            }
        } label: {
            HStack(spacing: 2) {
                Image(systemName: audioController.isGlobalMuted ? "speaker.slash" : "speaker.wave.2")
                    .font(.caption2)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7.5, weight: .bold))
            }
            .foregroundColor(audioController.isGlobalMuted ? palette.warnColor : palette.textColor)
            .padding(.horizontal, 6)
            .frame(height: 26)
            .background(Capsule().fill(palette.surfaceColor))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help((audioController.isGlobalMuted ? "전체 음소거 해제 (재생 유지)" : "모든 웹 페이지 전체 음소거 (재생 유지)") + " · 웹 오디오·통화 소리는 지원되지 않을 수 있습니다")
        .accessibilityLabel("페이지 소리 관리")
        .accessibilityHint(audioController.isGlobalMuted ? "메뉴 열기, 현재 전체 음소거 상태" : "메뉴 열기, 현재 소리 켜짐 상태")
    }
}

struct HanaPanelSwitch: View {
    @ObservedObject var host = HanaPanelHost.shared
    @Environment(\.bkPalette) var palette

    var body: some View {
        HStack(spacing: 6) {
            Text("하나").fixedSize()
                .font(.caption.bold())
                .foregroundColor(palette.textColor)
            Toggle("하나 대화창", isOn: Binding(
                get: { host.isPanelOpen },
                set: { host.isPanelOpen = $0 }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .fixedSize()
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(Capsule().fill(palette.surfaceColor))
        .help("하나 대화창을 열거나 닫습니다. 닫아도 대화 내용은 유지됩니다.")
        .accessibilityLabel("하나 대화창 토글")
    }
}

// MARK: - Browser Control Bar Outer Styling & macOS 26+ Compatibility

private struct BrowserControlBarBackground: ViewModifier {
    @Environment(\.bkPalette) var palette

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(palette.bgColor)
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(palette.cardColor.opacity(0.6), lineWidth: 1)
                        )
                )
        } else {
            content
        }
    }
}

/// Connections the helper refused for one failed job or the current browser page. Only exact hosts refused as
/// "not allowed" get the allow action, and the button allows exactly the hosts listed above it.
struct ConnectionRecoveryBox: View {
    let allowable: [String]
    let omitted: Int
    let others: [ConnectionRecovery.Refusal]
    let busy: Bool
    let problem: String?
    let actionHelp: String
    let action: () -> Void
    @Environment(\.bkPalette) var palette

    // Bounded lines / fixed-height scroll, never fixedSize: this box also sits in the non-scrolling browser column,
    // where an unbounded wrap at the split view's near-zero probe width pushed the whole window content off-screen.
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("HTTPS 연결 도움이 막은 연결", systemImage: "hand.raised.fill")
                .font(.caption.bold())
                .foregroundColor(palette.warnColor)
            if !allowable.isEmpty {
                let hostList = "이번 실행에서 아직 허용하지 않은 주소: " + allowable.joined(separator: ", ")
                if hostList.count > 100 {
                    // Long list: every host stays readable (and selectable) in a short scroll area.
                    ScrollView {
                        Text(hostList)
                            .font(.caption)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 48)
                } else {
                    Text(hostList)
                        .font(.caption)
                        .textSelection(.enabled)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(hostList)
                }
                if omitted > 0 {
                    Text("그 밖의 주소 \(omitted)개는 이 버튼으로 허용하지 않습니다 (설정 및 진단의 차단 목록에서 확인).")
                        .font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            ForEach(others) { r in
                Text("\(r.host): \(r.reason)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .help("\(r.host): \(r.reason)")
            }
            if let problem = problem {
                Text(problem).font(.caption2).foregroundColor(palette.dangerColor).lineLimit(3).help(problem)
            }
            if !allowable.isEmpty {
                HStack(spacing: 8) {
                    let note = "버튼을 누르면 위에 적힌 주소 \(allowable.count)개만 이번 실행 동안 허용합니다. 사이트 전체나 다른 주소는 허용하지 않습니다."
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(note)
                    Button(action: action) {
                        HStack(spacing: 4) {
                            if busy { ProgressView().controlSize(.mini) }
                            Text("허용 후 다시 시도")
                        }
                    }
                    .buttonStyle(.bkProminent)
                    .controlSize(.small)
                    .disabled(busy)
                    .help(actionHelp)
                    .accessibilityLabel("\(allowable.joined(separator: ", ")) 허용 후 다시 시도")
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(palette.warnSoftColor))
    }
}

// MARK: - Queue List View

struct QueueListView: View {
    @ObservedObject var appModel: AppModel
    @Environment(\.bkPalette) var palette

    var queueJobs: [JobRecord] {
        appModel.jobs.filter {
            $0.state != .completed && $0.state != .completedWithSubtitleFailure
        }
    }

    var activeRunningCount: Int {
        appModel.jobs.filter {
            $0.state == .downloading || $0.state == .extracting || $0.state == .verifying || $0.state == .publishing || $0.state == .processing || $0.state == .recording
        }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("진행 \(activeRunningCount) / 동시 최대 \(appModel.maxConcurrentJobs)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("전체 다운로드 시작") {
                    appModel.bulkStartReady()
                }
                .buttonStyle(.bordered)
                .disabled(!appModel.canBulkStartReady)
                .help("화질이 이미 선택된 대기 작업을 모두 시작합니다. 라이브(녹화) 작업은 제외됩니다.")
                .accessibilityLabel("선택 완료된 작업 전체 다운로드 시작")

                Button("대기열 지우기") {
                    appModel.bulkClearQueue()
                }
                .buttonStyle(.bordered)
                .disabled(!appModel.canBulkClear)
                .help("완료된 작업을 제외한 모든 대기열 작업을 삭제합니다.")
                .accessibilityLabel("대기열 전체 지우기")

                Button("브라우저 열기") {
                    appModel.bulkOpenInBrowser()
                }
                .buttonStyle(.bordered)
                .disabled(!appModel.canBulkOpenInBrowser)
                .help("실패하거나 중단된 작업의 원래 페이지 또는 주소를 브라우저 새 탭에서 엽니다.")
                .accessibilityLabel("실패한 작업 브라우저에서 열기")

                Button("다시 시도") {
                    appModel.bulkRetryQueue()
                }
                .buttonStyle(.bordered)
                .disabled(!appModel.canBulkRetry)
                .help("실패하거나 중단된 작업을 다시 시도합니다.")
                .accessibilityLabel("실패한 작업 전체 다시 시도")

                Button("로그 저장") {
                    appModel.exportDiagnostics()
                }
                .buttonStyle(.bordered)
                .disabled(appModel.diagnosticsExportBusy)
                .help("최근 전체 작업의 진단 기록을 ZIP 하나로 저장")
                .accessibilityLabel("진단 로그를 ZIP 파일로 저장")
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 6)

            Divider()

            Group {
                if queueJobs.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "arrow.down.doc")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                        Text("대기 중인 다운로드가 없습니다.")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        Text("상단 주소 입력창에 영상 주소를 입력하고 '다운로드'를 누르면 분석 후 바로 다운로드합니다.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(queueJobs) { job in
                                JobCardView(job: job, appModel: appModel)
                            }
                        }
                        .padding(16)
                    }
                }
            }
        }
        .urlDropTarget(appModel: appModel)
    }
}

// MARK: - Job Card View


struct JobCardView: View {
    let job: JobRecord
    @ObservedObject var appModel: AppModel
    @Environment(\.bkPalette) var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 0) {
                JobThumbnailView(job: job, directory: appModel.thumbnailDirectory)
                    .id(job.id)
                VStack(alignment: .leading, spacing: 4) {
                    Text(job.title)
                        .font(.headline)
                        .lineLimit(2)

                    HStack(spacing: 6) {
                        if job.isLive {
                            Text("실시간")
                                .font(.caption2.bold())
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(palette.dangerSoftColor))
                                .foregroundColor(palette.dangerColor)
                                .accessibilityLabel("실시간 방송")
                        }
                        if job.useLoginSession {
                            Image(systemName: "person.badge.key")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .help("앱 전용 로그인 세션(\(job.loginSite ?? "사이트"))을 사용합니다.")
                                .accessibilityLabel("로그인 세션 사용")
                        }
                        if let extractor = job.extractor {
                            Text(extractor)
                                .font(.caption2.bold())
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(palette.accentSoftColor))
                                .foregroundColor(palette.accentColor)
                        }
                        Text(job.redactedURL)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.trailing, 8)
                Spacer(minLength: 8)

                StateBadgeView(state: job.state)
            }

            if !job.stateMessage.isNilOrEmpty {
                Text(job.stateMessage ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Progress bar
            if job.state == .recording {
                VStack(spacing: 4) {
                    ProgressView(value: job.progressPercent, total: 100.0)
                        .progressViewStyle(.linear)
                        .accessibilityLabel("녹화 시간 진행")
                    HStack {
                        Label("녹화 중 \(formatClock(job.recordedSeconds)) / 최대 \(formatClock(Double(job.recordLimitSeconds)))",
                              systemImage: "record.circle")
                            .font(.caption2)
                            .foregroundColor(palette.dangerColor)
                        Spacer()
                        if job.downloadedBytes > 0 {
                            Text(String(format: "%.1f MB 녹화됨", Double(job.downloadedBytes) / 1048576.0))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } else if job.state.isActive || job.state == .downloading || job.state == .processing || job.state == .verifying {
                VStack(spacing: 4) {
                    ProgressView(value: job.progressPercent, total: 100.0)
                        .progressViewStyle(.linear)
                    HStack {
                        if job.totalBytes > 0 {
                            Text(String(format: "%.1f / %.1f MB", Double(job.downloadedBytes) / 1048576.0, Double(job.totalBytes) / 1048576.0))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if job.speed > 0 {
                            Text(String(format: "%.2f MB/s", job.speed / 1048576.0))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            // Selection Controls (when awaitingSelection)
            if job.state == .awaitingSelection {
                SelectionPanel(job: job, appModel: appModel)
            }

            // Action Buttons
            HStack(spacing: 8) {
                Spacer()

                Button("로그 저장") {
                    appModel.exportDiagnostics(jobId: job.id)
                }
                .buttonStyle(.bordered)
                .disabled(appModel.diagnosticsExportBusy)
                .help("이 작업의 진단 기록만 ZIP 하나로 저장")
                .accessibilityLabel("선택한 작업의 진단 로그만 저장")

                switch job.state {
                case .recording:
                    Button(action: { appModel.finishRecording(jobId: job.id) }) {
                        HStack(spacing: 4) {
                            Image(systemName: "stop.circle.fill")
                            Text("녹화 마치고 저장")
                        }
                    }
                    .buttonStyle(.bkProminent)
                    .help("지금까지 녹화한 구간을 마무리해 저장합니다.")
                    .accessibilityLabel("녹화 마치고 지금까지 녹화한 구간 저장")

                    Button("녹화 취소", role: .destructive) {
                        appModel.cancelJob(jobId: job.id)
                    }
                    .buttonStyle(.bordered)
                    .help("녹화를 멈추고 아무것도 저장하지 않습니다.")
                    .accessibilityLabel("녹화 취소, 저장하지 않음")
                case .extracting, .downloading, .processing, .verifying:
                    if !(job.isLive && job.pendingDownload) {
                        Button("일시 정지") {
                            appModel.pauseJob(jobId: job.id)
                        }
                        .buttonStyle(.bordered)
                    }

                    Button("취소") {
                        appModel.cancelJob(jobId: job.id)
                    }
                    .buttonStyle(.bordered)
                case .publishing:
                    Button("저장 취소") {
                        appModel.cancelJob(jobId: job.id)
                    }
                    .buttonStyle(.bordered)
                case .queued:
                    Button("취소") {
                        appModel.cancelJob(jobId: job.id)
                    }
                    .buttonStyle(.bordered)
                case .awaitingSelection:
                    Button("삭제") {
                        appModel.deleteJob(jobId: job.id, removeFile: false)
                    }
                    .buttonStyle(.bordered)
                case .paused:
                    Button("재개 (처음부터)") {
                        appModel.resumeJob(jobId: job.id)
                    }
                    .buttonStyle(.bkProminent)

                    Button("취소") {
                        appModel.cancelJob(jobId: job.id)
                    }
                    .buttonStyle(.bordered)
                case .cancelled, .failed, .interrupted, .selectionChanged, .verificationIncomplete:
                    Button(job.pendingPublish ? "저장 다시 시도" : "다시 시도") {
                        appModel.retryJob(jobId: job.id)
                    }
                    .buttonStyle(.bkProminent)

                    Button("삭제") {
                        appModel.deleteJob(jobId: job.id, removeFile: false)
                    }
                    .buttonStyle(.bordered)

                    if job.state == .failed {
                        let rawSource = job.browserPageReference ?? job.sourceURL
                        if let source = URL(string: rawSource),
                           ["http", "https"].contains(source.scheme?.lowercased() ?? ""),
                           source.user == nil, source.password == nil,
                           !rawSource.contains("…"), !rawSource.lowercased().contains("%e2%80%a6") {
                            Button("브라우저에서 열기") {
                                appModel.selectedTab = .browser
                                appModel.newTab()?.open(source.absoluteString)
                            }
                            .buttonStyle(.bordered)
                            .help("가능하면 원래 페이지, 없으면 현재 주소를 새 탭에 엽니다.")
                        }
                    }
                case .completed, .completedWithSubtitleFailure:
                    EmptyView()
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(palette.surfaceColor)
                .shadow(color: Color.black.opacity(0.04), radius: 3, x: 0, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(palette.borderColor, lineWidth: 1)
        )
    }
}

// MARK: - Selection Panel

struct SelectionPanel: View {
    let job: JobRecord
    @ObservedObject var appModel: AppModel
    @Environment(\.bkPalette) var palette

    var videoFormats: [MediaFormat] {
        job.availableFormats.filter { $0.isVideoOnly || $0.isMuxed }
    }

    var audioFormats: [MediaFormat] {
        job.availableFormats.filter { $0.isAudioOnly }
    }

    private var videoBinding: Binding<String> {
        Binding(
            get: { job.selectedVideoFormatId ?? "" },
            set: { newVal in
                if let idx = appModel.jobs.firstIndex(where: { $0.id == job.id }) {
                    appModel.jobs[idx].selectedVideoFormatId = newVal.isEmpty ? nil : newVal
                }
            }
        )
    }

    private var audioBinding: Binding<String> {
        Binding(
            get: { job.selectedAudioFormatId ?? "" },
            set: { newVal in
                if let idx = appModel.jobs.firstIndex(where: { $0.id == job.id }) {
                    appModel.jobs[idx].selectedAudioFormatId = newVal.isEmpty ? nil : newVal
                }
            }
        )
    }

    /// One subtitle track per job (manual or auto-generated), so provenance is never silently swapped.
    private var subtitleBinding: Binding<String> {
        Binding(
            get: { job.selectedSubtitleIds.first ?? "" },
            set: { newVal in
                if let idx = appModel.jobs.firstIndex(where: { $0.id == job.id }) {
                    appModel.jobs[idx].selectedSubtitleIds = newVal.isEmpty ? [] : [newVal]
                }
            }
        )
    }

    /// Source format facts (codec/transport/size) plus the final MP4 note.
    private func videoLabel(_ fmt: MediaFormat) -> String {
        var s = "\(fmt.resolutionDisplay) (\(fmt.vcodec ?? fmt.ext))"
        if let p = fmt.protocolLabel { s += " · \(p)" }
        if !job.isLive { s += " - \(fmt.sizeDisplay)" }
        return s + " \(fmt.mp4VideoNote)"
    }

    private func audioLabel(_ fmt: MediaFormat) -> String {
        var s = fmt.acodec ?? fmt.ext
        if let p = fmt.protocolLabel { s += " · \(p)" }
        if !job.isLive { s += " (\(fmt.sizeDisplay))" }
        if !videoFormats.isEmpty, let note = fmt.mp4AudioNote { s += " \(note)" }   // audio-only downloads keep their format
        return s
    }

    private var selectedVideoIsVideoOnly: Bool {
        guard let vid = job.selectedVideoFormatId else { return false }
        return job.availableFormats.first { $0.formatId == vid }?.isVideoOnly ?? false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()

            Text("화질 및 저장 옵션 선택")
                .font(.subheadline.bold())

            // Video Format Picker
            if !videoFormats.isEmpty {
                HStack {
                    Text("영상 화질:")
                        .font(.caption)
                        .frame(width: 70, alignment: .leading)
                    Picker("", selection: videoBinding) {
                        ForEach(videoFormats) { fmt in
                            Text(videoLabel(fmt)).tag(fmt.formatId)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityLabel("영상 화질")
                }
            }

            // Audio Format Picker (separate audio track, or audio-only download when no video exists)
            if !audioFormats.isEmpty && (selectedVideoIsVideoOnly || videoFormats.isEmpty) {
                HStack {
                    Text(videoFormats.isEmpty ? "음원:" : "음성 트랙:")
                        .font(.caption)
                        .frame(width: 70, alignment: .leading)
                    Picker("", selection: audioBinding) {
                        if !videoFormats.isEmpty { Text("기본 최적 오디오").tag("") }
                        ForEach(audioFormats) { fmt in
                            Text(audioLabel(fmt)).tag(fmt.formatId)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityLabel("음성 트랙")
                }
            }

            if !videoFormats.isEmpty {
                Text("영상은 MP4로 저장합니다. 위 코덱은 원본 형식 그대로이며, MP4에 담을 수 있는 코덱은 화질 변화 없이 옮겨 담고 담을 수 없는 트랙(VP9·Opus 등)만 H.264/AAC로 변환합니다. 변환은 영상 길이에 따라 시간이 더 걸리고 재인코딩이라 화질이 조금 달라질 수 있습니다.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if job.isLive {
                HStack {
                    Text("녹화 시간:")
                        .font(.caption)
                        .frame(width: 70, alignment: .leading)
                    Picker("", selection: Binding(
                        get: { job.recordLimitSeconds },
                        set: { appModel.setRecordLimit(jobId: job.id, seconds: $0) })) {
                        ForEach(recordingLimitChoices, id: \.seconds) { choice in
                            Text("최대 \(choice.label)").tag(choice.seconds)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 220)
                    .accessibilityLabel("최대 녹화 시간")
                }
                Text("시작한 시점부터 녹화합니다. 정한 시간이 되거나 '녹화 마치고 저장'을 누르면 그때까지의 구간을 저장합니다.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            // Subtitle Options
            if !job.availableSubtitles.isEmpty {
                HStack {
                    Text("자막:")
                        .font(.caption)
                        .frame(width: 70, alignment: .leading)
                    Picker("", selection: subtitleBinding) {
                        Text("자막 없음").tag("")
                        ForEach(job.availableSubtitles) { sub in
                            Text(sub.displayTitle).tag(sub.id)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }

            if !appModel.hasUsableSourceForStart(job) {
                Text("원본 주소 재입력 필요: 보안을 위해 주소가 저장되지 않아 시작할 수 없습니다. 주소를 다시 입력해 분석해 주세요.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button(action: {
                    appModel.confirmSelectionAndDownload(jobId: job.id)
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: job.isLive ? "record.circle" : "arrow.down.circle.fill")
                        Text(job.isLive ? "녹화 시작" : "다운로드 시작")
                    }
                    .padding(.horizontal, 8)
                }
                .buttonStyle(.bkProminent)
                .disabled(!appModel.hasUsableSourceForStart(job))
                .accessibilityLabel(job.isLive ? "녹화 시작" : "다운로드 시작")
            }
        }
        .padding(10)
        .background(palette.surface2Color)
        .cornerRadius(8)
    }
}

// MARK: - History List View

struct HistoryListView: View {
    @ObservedObject var appModel: AppModel
    @State private var showingClearConfirm = false

    var completedJobs: [JobRecord] {
        appModel.jobs.filter {
            $0.state == .completed || $0.state == .completedWithSubtitleFailure
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Spacer()

                Button("목록지우기") {
                    appModel.bulkClearHistory()
                }
                .buttonStyle(.bordered)
                .disabled(!appModel.canBulkClearHistory)
                .help("완료된 다운로드 기록만 목록에서 지웁니다. 저장된 파일은 그대로 남습니다.")
                .accessibilityLabel("목록지우기")

                Button("파일지우기") {
                    showingClearConfirm = true
                }
                .buttonStyle(.bordered)
                .disabled(!appModel.canBulkClearHistory)
                .help("완료 기록과 저장된 영상·자막 파일을 휴지통으로 옮깁니다.")
                .accessibilityLabel("파일지우기")
                .confirmationDialog(
                    "완료 기록 \(appModel.historyClearableRecordCount)개와 파일 \(appModel.historyPublishedFileCount)개를 지울까요?",
                    isPresented: $showingClearConfirm,
                    titleVisibility: .visible
                ) {
                    Button("파일지우기", role: .destructive) {
                        appModel.bulkClearHistoryWithFiles()
                    }
                    Button("취소", role: .cancel) {}
                } message: {
                    Text("이 기록이 저장한 영상·자막 파일만 휴지통으로 이동하며 휴지통에서 복구할 수 있습니다.")
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 6)

            Divider()

            Group {
                if completedJobs.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "clock")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                        Text("완료된 다운로드 기록이 없습니다.")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(completedJobs) { job in
                                HistoryCardView(job: job, appModel: appModel)
                            }
                        }
                        .padding(16)
                    }
                }
            }
        }
        .urlDropTarget(appModel: appModel)
    }
}

struct HistoryCardView: View {
    let job: JobRecord
    @ObservedObject var appModel: AppModel
    @Environment(\.bkPalette) var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 0) {
                JobThumbnailView(job: job, directory: appModel.thumbnailDirectory)
                    .id(job.id)
                VStack(alignment: .leading, spacing: 4) {
                    Text(job.title)
                        .font(.headline)
                    if let path = job.publishedMediaPath {
                        Text(path)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                StateBadgeView(state: job.state)
            }

            if let manifest = job.manifest, manifest.isRecording == true {
                HStack(spacing: 6) {
                    Text("녹화 구간 저장")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(palette.dangerSoftColor))
                        .foregroundColor(palette.dangerColor)
                    Text("녹화 길이 \(formatClock(manifest.recordedSeconds ?? manifest.duration ?? 0))"
                         + (manifest.recordingEndDescription.map { " · \($0)" } ?? ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("원본 방송 전체가 아니라 녹화한 구간만 저장되었습니다.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let manifest = job.manifest {
                HStack(spacing: 10) {
                    if let fmt = manifest.formatName {
                        Text("형식: \(fmt)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let w = manifest.width, let h = manifest.height {
                        Text("\(w)x\(h)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let dur = manifest.duration {
                        Text(String(format: "%02d:%02d", Int(dur) / 60, Int(dur) % 60))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let basis = manifest.completeness {
                    Text("전송 완전성 근거: \(basis)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if let msg = job.stateMessage, job.state == .completedWithSubtitleFailure {
                Text(msg)
                    .font(.caption)
                    .foregroundColor(palette.warnColor)
            }

            Divider()

            HStack(spacing: 8) {
                Button("열기") {
                    appModel.openFile(jobId: job.id)
                }
                .buttonStyle(.bkProminent)

                Button("Finder에서 보기") {
                    appModel.openInFinder(jobId: job.id)
                }
                .buttonStyle(.bordered)

                Button("주소 복사") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(job.sourceURL, forType: .string)
                    appModel.alertMessage = job.urlWasRedacted
                        ? "보안을 위해 일부가 제거된 주소가 복사되었습니다. 원래 주소와 다를 수 있습니다."
                        : "원본 주소가 클립보드에 복사되었습니다."
                    appModel.showingAlert = true
                }
                .buttonStyle(.bordered)

                Button("로그 저장") {
                    appModel.exportDiagnostics(jobId: job.id)
                }
                .buttonStyle(.bordered)
                .disabled(appModel.diagnosticsExportBusy)
                .help("이 작업의 진단 기록만 ZIP 하나로 저장")
                .accessibilityLabel("선택한 작업의 진단 로그만 저장")

                if job.state == .completedWithSubtitleFailure {
                    Button("자막만 다시 받기") {
                        appModel.retrySubtitleOnly(jobId: job.id)
                    }
                    .buttonStyle(.bordered)
                }

                Spacer()

                Menu("삭제...") {
                    Button("기록만 삭제") {
                        appModel.deleteJob(jobId: job.id, removeFile: false)
                    }
                    Button("파일도 함께 휴지통으로 이동", role: .destructive) {
                        appModel.deleteJob(jobId: job.id, removeFile: true)
                    }
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(palette.surfaceColor)
                .shadow(color: Color.black.opacity(0.04), radius: 3, x: 0, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(palette.borderColor, lineWidth: 1)
        )
    }
}

// MARK: - Settings & Diagnostics View

struct SettingsView: View {
    @ObservedObject var appModel: AppModel
    @Environment(\.bkPalette) var palette

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Section: Address search & shortcuts
                GroupBox("주소창·검색") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("브라우저 주소창에서 사이트 이름·단축어·검색어를 통한 빠른 탐색 및 길찾기 설정을 관리합니다.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        AddressSearchSettingsView(store: appModel.preferences.addressSearch)
                            .frame(minHeight: 280, maxHeight: 420)
                    }
                    .padding(8)
                }

                // Section: Browser translation extension
                GroupBox("번역 확장 연동") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Safari, Chrome, Whale 등 외부 브라우저와 한툴 번역 엔진을 연결하는 확장 프로그램 연동 설정입니다.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Button("번역 확장 프로그램 설정 열기 ↗") {
                            #if HTT_HOST
                            HTDHostExport.shared.showTool("browser")
                            #endif
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("브라우저 번역 확장 프로그램 연동 화면을 엽니다.")
                    }
                    .padding(8)
                }

                // Section 1b: Video queue concurrency & fragment concurrency
                GroupBox("다운로드") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("동시에 처리할 동영상 개수:")
                                .font(.subheadline.bold())
                            Spacer()
                            Stepper("\(appModel.maxConcurrentJobs)개", value: $appModel.maxConcurrentJobs, in: 1...8)
                                .accessibilityLabel("동시에 처리할 동영상 개수")
                        }
                        Text("동시에 처리할 동영상 수입니다 (1~8개, 기본값 3개). 값을 낮추면 다음 시작부터 적용되며 이미 실행 중인 동영상은 중단되지 않습니다.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        Divider()

                        Text("조각 수신 자동 최적화")
                            .font(.subheadline.bold())
                        Text("HLS·DASH 조각 영상은 동시 수신 1개로 시작해, 실제 측정한 전체 수신 속도가 의미 있게 빨라질 때만 1개씩 늘립니다. 속도가 나아지지 않거나 오류가 나면 직전의 안정된 개수로 돌아가 더 늘리지 않습니다. 짧은 영상은 측정할 자료가 부족해 1개로 끝날 수 있습니다. 일반 단일 파일과 실시간 녹화에는 적용되지 않습니다.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(8)
                }

                // Section 2: Connection assist
                ConnectionSettingsSection(appModel: appModel, connection: appModel.connection)

                // Section 3: Login session
                LoginSettingsSection(appModel: appModel, session: appModel.session)

                // Section 3a: Cache cleanup
                CacheSettingsSection(appModel: appModel)

                // Section 3b: Popups & Redirection
                PopupSitePermissionsSection()

                // Section 5: Engine status & diagnostics (below actionable groups)
                GroupBox("엔진 상태 및 진단") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("전체 엔진 상태:")
                                .font(.subheadline.bold())
                            if !appModel.engineHealth.checked {
                                Label("확인 중...", systemImage: "hourglass")
                                    .foregroundStyle(.secondary)
                            } else if appModel.engineHealth.healthy {
                                Label("정상 작동 가능", systemImage: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                            } else {
                                Label(appModel.engineHealth.failureReason ?? "점검 필요", systemImage: "exclamationmark.triangle.fill")
                                    .foregroundColor(palette.warnColor)
                            }
                        }

                        Divider()

                        let h = appModel.engineHealth
                        LabeledContent("엔진 분류", value: h.engineType)
                        LabeledContent("Python 실행기", value: h.pythonPath)
                        LabeledContent("Python 버전", value: h.pythonVersion.isEmpty ? "확인 중" : h.pythonVersion)
                        LabeledContent("yt-dlp", value: h.ytdlpAvailable ? "사용 가능 (버전 \(h.ytdlpVersion))" : "미설치/로드 실패")
                        LabeledContent("FFmpeg", value: h.ffmpegAvailable ? "\(h.ffmpegVersion) · \(h.ffmpegPath ?? "")" : "미설치")
                        LabeledContent("ffprobe", value: h.ffprobeAvailable ? (h.ffprobePath ?? "사용 가능") : "미설치")
                        LabeledContent("Deno (JS 런타임)", value: h.denoAvailable ? "\(h.denoVersion) · \(h.denoPath ?? "")" : "미설치 (일부 사이트에서 필요)")
                        LabeledContent("EJS (yt-dlp-ejs)", value: h.ejsAvailable ? "설치됨" : "미설치 (일부 사이트에서 필요)")
                        Text(BrowserExtensionManager.embeddingHTTApp != nil
                             ? "통합 한툴이 엔진, yt-dlp, FFmpeg, ffprobe, Deno를 하나의 번들로 함께 제공합니다. 별도로 내려받거나 설치할 필요가 없으며, 이 번들의 업데이트는 한툴 메뉴의 '업데이트 확인…'으로 합니다."
                             : "독립 실행 중입니다. 엔진은 자동으로 업데이트되거나 설치되지 않으며, 필요한 도구는 직접 준비해야 합니다.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        HStack {
                            Spacer()
                            Button("엔진 상태 다시 확인") {
                                appModel.refreshEngineHealth()
                            }
                            .buttonStyle(.bordered)
                        }
                        Text("앱에 문제가 생겼을 때 개발자에게 보여 줄 진단 정보를 ZIP 파일 하나로 저장합니다. 단계·오류 종류·도구 버전 같은 기록만 담기고 영상, 제목, 파일 이름, 주소의 경로·쿼리, 로그인 정보는 담기지 않습니다. 저장만 하며 자동으로 전송하지 않습니다.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(8)
                }

                GroupBox("명령줄로 사이트 열기") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("터미널에서 아래 명령으로 사이트를 바로 엽니다.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        HStack {
                            Text(#"open -a "/Applications/HanTool.app" "https://www.youtube.com""#)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                            Spacer()
                            Button("복사") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(#"open -a "/Applications/HanTool.app" "https://www.youtube.com""#, forType: .string)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(8)
                }

                // Section 4: About
                GroupBox("\(AppIdentity.displayName) 정보") {
                    VStack(alignment: .leading, spacing: 6) {
                        let shortVer = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.9.1"
                        let buildNum = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "20"
                        let buildStamp = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String)
                            ?? (Bundle.main.infoDictionary?["HTDBuildStamp"] as? String)
                            ?? (Bundle.main.infoDictionary?["BarobogiBuildStamp"] as? String)
                            ?? buildNum
                        LabeledContent("버전", value: "\(shortVer) (\(buildNum))")
                        LabeledContent("빌드", value: buildStamp)
#if HTT_HOST
                        LabeledContent("배포 형태", value: "한툴 통합 기능")
#else
                        LabeledContent("배포 형태", value: "한툴 통합 브라우저")
#endif
                        LabeledContent("저작권", value: "Copyright © 2026 Hanstree")
                    }
                    .padding(8)
                }
            }
            .padding(20)
        }
        .urlDropTarget(appModel: appModel)
    }
}

// MARK: - Cache cleanup settings

struct CacheSettingsSection: View {
    @ObservedObject var appModel: AppModel

    var body: some View {
        GroupBox("캐시") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("브라우저 캐시, 미리보기 이미지, 즐겨찾기 아이콘")
                        .font(.subheadline.bold())
                    Spacer()
                    if appModel.isClearingCache { ProgressView().controlSize(.small) }
                    Button("캐시 정리") { appModel.clearCaches() }
                        .disabled(appModel.isClearingCache)
                        .accessibilityLabel("캐시 정리")
                }
                HStack(spacing: 6) {
                    Text("정리 가능한 앱 생성 캐시(미리보기 이미지·즐겨찾기 아이콘)")
                    if appModel.isMeasuringCache {
                        ProgressView().controlSize(.small)
                    } else if let bytes = appModel.measuredCacheBytes {
                        Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)).bold()
                    } else {
                        Text("확인할 수 없음").bold()
                    }
                }
                .font(.caption)
                Text("브라우저(WebKit) HTTP 캐시도 함께 정리되지만, 크기를 확인할 공개 방법이 없어 위 용량에는 포함되지 않습니다. 진행 중이거나 다시 시도할 수 있는 작업의 미리보기는 계산과 정리에서 제외됩니다.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let message = appModel.cacheCleanupMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("앱 안 브라우저가 저장한 임시 웹 캐시, 목록의 미리보기 이미지, 시작 화면 즐겨찾기의 저장된 아이콘·대표 색상만 지웁니다. 로그인·쿠키·사이트 저장 데이터, 다운로드한 파일, 기록, 작업 폴더는 지우지 않으며 진행 중이거나 다시 시도할 수 있는 작업의 미리보기도 남겨 둡니다. 사이트는 다음에 열 때 필요한 것만 다시 받습니다.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
        }
        .onAppear { appModel.refreshCacheUsage() }
    }
}

// MARK: - Connection assist settings

struct ConnectionSettingsSection: View {
    @ObservedObject var appModel: AppModel
    @ObservedObject var connection: ConnectionManager
    @Environment(\.bkPalette) var palette

    var body: some View {
        GroupBox("HTTPS 연결 도움") {
            VStack(alignment: .leading, spacing: 8) {
                Text("켜고 끄기는 왼쪽 메뉴 아래 '설정'의 'HTTPS 연결 도움' 스위치 하나로 합니다. 여기서는 상태와 진단만 보여 줍니다.")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    switch connection.status {
                    case .off:
                        Label(connection.statusText, systemImage: "network").foregroundStyle(.secondary)
                    case .starting:
                        Label(connection.statusText, systemImage: "hourglass").foregroundStyle(.secondary)
                    case .ready:
                        Label(connection.statusText, systemImage: "checkmark.shield.fill").foregroundColor(.green)
                    case .failed:
                        Label(connection.statusText, systemImage: "exclamationmark.triangle.fill").foregroundColor(palette.warnColor)
                    }
                    Spacer()
                    if connection.enabled {
                        Button("다시 시작") { appModel.restartConnectionAssist() }
                            .disabled(appModel.hasActiveRun || appModel.isMeasuringSpeed)
                            .accessibilityLabel("연결 도움 다시 시작")
                    }
                }
                .font(.caption)

                Text("켜면 이 앱의 분석·다운로드·녹화와 앱 안 브라우저의 연결이 앱 안에서만 동작하는 전용 연결 경로를 거치고, 각 HTTPS 연결의 첫 TLS 메시지(ClientHello)를 두 조각으로 나눠 보냅니다. 다른 앱이나 시스템 네트워크 설정은 바꾸지 않습니다. 사용자가 연 사이트와 그 사이트가 쓰는 알려진 주소만 연결합니다. 다운로드 작업과 브라우저에서 필요한 공개 추가 서버가 막히면 그 정확한 주소만 자동으로 허용하고 다시 시도합니다(시도당 최대 \(AppModel.autoRecoveryMaxRounds)회·서버 \(AppModel.autoRecoveryMaxHosts)개). 자동 복구가 불가능한 경우 그 이유를 명확히 표시합니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("일부 네트워크에서 접속이 나아질 수 있지만 모든 사이트의 접속을 보장하지는 않습니다. 인증서 확인 등 보안 검사는 그대로입니다. 앱 안 브라우저는 http:// 페이지도 같은 연결 경로로 열 수 있지만 암호화되지 않으므로 중요한 정보는 입력하지 마세요. 분석·다운로드·녹화에는 http:// 주소를 쓸 수 없습니다(자동으로 https로 바꾸지 않음). 진행 중인 작업이 있으면 바꿀 수 없습니다.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if connection.enabled {
                    LabeledContent("첫 TLS 메시지 나눠 보내기",
                                   value: connection.splitConfirmed ? "적용 중 (연결 도움이 확인함)" : "확인 전")
                        .font(.caption)
                    if !connection.splitFallbacks.isEmpty {
                        DisclosureGroup("나눠 보내지 않고 그대로 전달한 연결 \(connection.splitFallbacks.reduce(0) { $0 + $1.count })개") {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(connection.splitFallbacks) { f in
                                    Text("\(f.host)\(f.count > 1 ? " ×\(f.count)" : ""): \(f.reason)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.caption)
                    }
                }

                if connection.enabled {
                    Divider()
                    HStack {
                        Text("차단된 연결").font(.subheadline.bold())
                        Spacer()
                        if !connection.blocked.isEmpty {
                            Button("목록 비우기") { connection.clearBlocked() }
                                .accessibilityLabel("차단된 연결 목록 비우기")
                        }
                    }
                    if connection.blocked.isEmpty {
                        Text("차단된 연결이 없습니다.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        BlockedHostsList(connection: connection)
                        Text("허용은 이번 실행 동안만 유지됩니다. 앱을 다시 열면 처음 상태로 돌아갑니다.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if !connection.allowedDomains.isEmpty {
                        DisclosureGroup("이번 세션에 허용된 사이트 \(connection.allowedDomains.count)개") {
                            Text(connection.allowedDomains.joined(separator: ", "))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.caption)
                    }
                }
            }
            .padding(8)
        }
    }
}

// MARK: - Login session settings

struct LoginSettingsSection: View {
    @ObservedObject var appModel: AppModel
    @ObservedObject var session: SessionManager

    var body: some View {
        GroupBox("전용 로그인") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(session.isAlive ? "로그인 세션 열림" : "로그인 세션 없음",
                          systemImage: session.isAlive ? "person.crop.circle.badge.checkmark" : "person.crop.circle")
                        .font(.subheadline.bold())
                    Spacer()
                    Button("브라우저 열기") { appModel.openLoginWindow() }
                        .accessibilityLabel("앱 안 브라우저 열기")
                    Button("세션 지우기", role: .destructive) { appModel.clearLoginSession() }
                        .accessibilityLabel("로그인 세션 지우기")
                }
                if session.isAlive && !session.visitedSites.isEmpty {
                    Text("이번 세션에서 연 사이트: \(session.visitedSites.joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("로그인은 앱 안 '브라우저'에서 직접 합니다. 사파리·크롬 등 브라우저의 쿠키나 키체인은 읽지 않으며, 로그인은 이 앱 전용 저장소에 남아 앱을 종료해도 유지되며 '세션 지우기'로만 지워집니다. 작업에는 그 작업 주소의 사이트 로그인 정보만 전달됩니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("'세션 열림'은 로그인 창이 열렸다는 뜻일 뿐, 사이트에 로그인되었다는 확인은 아닙니다. 로그인 여부는 사이트 화면에서 확인해 주세요.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
        }
    }
}

// MARK: - Popups & Redirection Settings

struct PopupSitePermissionsSection: View {
    @ObservedObject var permissions = PopupSitePermissions.shared
    @Environment(\.bkPalette) var palette
    @State private var inputHost = ""
    @State private var inputError: String?

    var body: some View {
        GroupBox("팝업 및 리디렉션") {
            VStack(alignment: .leading, spacing: 10) {
                Text("사용자가 클릭하지 않아도 창을 자동으로 띄우는(window.open) 사이트를 관리합니다. 사용자가 직접 클릭한 링크나 버튼은 허용 목록과 관계없이 언제나 정상 작동합니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("안내: 일반 HTTP(S) 리디렉션은 기존 HTTPS 연결 정책을 그대로 따르며 우회되지 않습니다. 팝업 창이 열리더라도 HTTPS 연결 도움 등 네트워크 보안 검사는 동일하게 적용됩니다.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    TextField("예: https://aagag.com/ 또는 aagag.com", text: $inputHost)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { addSite() }

                    Button("추가") {
                        addSite()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(inputHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if let err = inputError {
                    Text(err)
                        .font(.caption2)
                        .foregroundColor(palette.warnColor)
                }

                Divider()

                HStack {
                    Text("자동 팝업 허용 목록 (\(permissions.allowedHosts.count)개)")
                        .font(.subheadline.bold())
                    Spacer()
                }

                if permissions.allowedHosts.isEmpty {
                    Text("허용된 사이트가 없습니다. 기본적으로 모든 자동 팝업 창이 차단됩니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(permissions.allowedHosts, id: \.self) { host in
                            HStack {
                                Text(host)
                                    .font(.caption.monospaced())
                                Spacer()
                                Button(role: .destructive) {
                                    permissions.remove(host: host)
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.caption2)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .accessibilityLabel("\(host) 허용 삭제")
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
            .padding(8)
        }
    }

    private func addSite() {
        inputError = nil
        let trimmed = inputHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let result = permissions.add(input: trimmed)
        if result.success {
            inputHost = ""
            inputError = nil
        } else {
            inputError = "유효하지 않거나 모호한 웹 주소입니다. 정확한 HTTP(S) 도메인을 입력해 주세요 (예: https://aagag.com/ 또는 aagag.com)."
        }
    }
}

// MARK: - State Badge View

struct StateBadgeView: View {
    let state: JobState
    @Environment(\.bkPalette) var palette

    var color: Color {
        switch state {
        case .completed: return .green
        case .completedWithSubtitleFailure: return .teal
        case .recording: return palette.dangerColor
        case .downloading, .extracting, .verifying, .publishing, .processing: return palette.accentColor
        case .awaitingSelection: return .purple
        case .queued: return palette.mutedColor
        case .paused: return palette.warnColor
        case .cancelled, .interrupted: return palette.mutedColor
        case .selectionChanged, .verificationIncomplete: return palette.warnColor
        case .failed: return palette.dangerColor
        }
    }

    var body: some View {
        Text(state.displayName)
            .font(.caption2.bold())
            .foregroundColor(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(color.opacity(0.12)))
    }
}

extension Optional where Wrapped == String {
    var isNilOrEmpty: Bool {
        return self == nil || self?.isEmpty == true
    }
}
