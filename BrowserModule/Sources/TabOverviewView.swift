import SwiftUI
import AppKit
import WebKit

/// Content-area overview of all open browser tabs with real WKWebView snapshots, search filter, and keyboard navigation.
struct TabOverviewView: View {
    @ObservedObject var appModel: AppModel
    @ObservedObject private var audioController = PageAudioController.shared
    @ObservedObject private var bookmarkAppearance = BookmarkAppearanceManager.shared
    @Environment(\.bkPalette) private var palette

    @State private var searchText: String = ""
    @FocusState private var searchFocused: Bool
    @State private var keyMonitor: Any?

    private var filteredTabs: [LoginBrowserModel] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return appModel.tabs }
        return appModel.tabs.filter { tab in
            let title = tab.tabTitle.isEmpty ? "새 탭" : tab.tabTitle
            if title.localizedCaseInsensitiveContains(query) { return true }
            if tab.pageTitle.localizedCaseInsensitiveContains(query) { return true }
            if let urlStr = tab.currentURL?.absoluteString, urlStr.localizedCaseInsensitiveContains(query) { return true }
            if let host = tab.currentURL?.host, host.localizedCaseInsensitiveContains(query) { return true }
            if tab.address.localizedCaseInsensitiveContains(query) { return true }
            if tab.isShowingHome && ("시작 화면".localizedCaseInsensitiveContains(query) || "새 탭".localizedCaseInsensitiveContains(query)) {
                return true
            }
            return false
        }
    }

    private let gridColumns = [
        GridItem(.adaptive(minimum: 220, maximum: 290), spacing: 14)
    ]

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            contentGrid
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.bgColor)
        .onAppear {
            appModel.refreshTabOverviewThumbnails()
            installKeyMonitor()
            DispatchQueue.main.async {
                searchFocused = true
            }
        }
        .onDisappear {
            removeKeyMonitor()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("열린 탭 전체보기")
    }

    private var headerBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(palette.accentColor)
                Text("열린 탭 전체보기")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(palette.textColor)
                Text("\(appModel.tabs.count)/\(AppModel.maxTabs)")
                    .font(.caption.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(palette.accentSoftColor))
                    .foregroundColor(palette.accentColor)
                    .accessibilityLabel("열린 탭 \(appModel.tabs.count)개, 최대 \(AppModel.maxTabs)개")
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(palette.mutedColor)
                TextField("탭 제목 또는 주소 검색", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(palette.textColor)
                    .focused($searchFocused)
                    .onSubmit {
                        selectPrimaryTabAndExit()
                    }
                    .accessibilityLabel("탭 제목 또는 주소 검색")
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(palette.mutedColor)
                    }
                    .buttonStyle(.plain)
                    .help("검색어 지우기")
                    .accessibilityLabel("검색어 지우기")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(minWidth: 180, maxWidth: 320)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(palette.surfaceColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(palette.borderColor, lineWidth: 1)
            )

            Spacer()

            Button {
                if appModel.tabs.count < AppModel.maxTabs {
                    if let created = appModel.newTab() {
                        appModel.selectTab(created.tabID)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                    Text("새 탭")
                        .font(.system(size: 12, weight: .medium))
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(appModel.tabs.count >= AppModel.maxTabs)
            .help(appModel.tabs.count >= AppModel.maxTabs ? "더 이상 탭을 열 수 없습니다 (최대 \(AppModel.maxTabs)개)" : "새 탭 열기 (⌘T)")
            .accessibilityLabel("새 탭 열기")

            Button {
                appModel.setTabOverviewPresented(false)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                    Text("현재 탭으로 돌아가기")
                        .font(.system(size: 12, weight: .medium))
                }
            }
            .buttonStyle(.bkProminent)
            .controlSize(.small)
            .keyboardShortcut(.cancelAction)
            .help("탭 전체보기 닫기 (Esc)")
            .accessibilityLabel("탭 전체보기 닫고 현재 탭으로 돌아가기")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(palette.cardColor)
    }

    @ViewBuilder
    private var contentGrid: some View {
        let tabs = filteredTabs
        if tabs.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 28))
                    .foregroundColor(palette.mutedColor)
                Text("검색 조건에 맞는 열린 탭이 없습니다.")
                    .font(.subheadline.bold())
                    .foregroundColor(palette.textColor)
                Text("다른 검색어를 입력하거나 검색어를 지워 전체 탭(\(appModel.tabs.count)개)을 확인하세요.")
                    .font(.caption)
                    .foregroundColor(palette.mutedColor)
                if !searchText.isEmpty {
                    Button("검색어 지우기") {
                        searchText = ""
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
        } else {
            ScrollView {
                LazyVGrid(columns: gridColumns, spacing: 14) {
                    ForEach(tabs, id: \.tabID) { tab in
                        TabOverviewCard(
                            appModel: appModel,
                            tab: tab,
                            isCurrentTab: tab.tabID == appModel.selectedTabID,
                            thumbnail: appModel.tabThumbnail(for: tab),
                            audioController: audioController,
                            bookmarkAppearance: bookmarkAppearance
                        )
                    }
                }
                .padding(16)
            }
        }
    }

    private func selectPrimaryTabAndExit() {
        let tabs = filteredTabs
        guard !tabs.isEmpty else { return }
        if let currentMatch = tabs.first(where: { $0.tabID == appModel.selectedTabID }) {
            let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                appModel.selectTabFromOverview(currentMatch.tabID)
                return
            }
        }
        appModel.selectTabFromOverview(tabs[0].tabID)
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard appModel.isTabOverviewPresented, appModel.selectedTab == .browser else { return event }
            guard let window = event.window, window === NSApp.keyWindow else { return event }
            if let editor = window.firstResponder as? NSTextView, editor.hasMarkedText() {
                return event
            }
            let modifiers = event.modifierFlags.intersection([.command, .control, .option])
            guard modifiers.isEmpty else { return event }
            switch event.keyCode {
            case 53: // Escape
                appModel.setTabOverviewPresented(false)
                return nil
            case 36, 76: // Return / Enter
                selectPrimaryTabAndExit()
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }
}

private struct TabOverviewCard: View {
    @ObservedObject var appModel: AppModel
    @ObservedObject var tab: LoginBrowserModel
    let isCurrentTab: Bool
    let thumbnail: NSImage?
    @ObservedObject var audioController: PageAudioController
    @ObservedObject var bookmarkAppearance: BookmarkAppearanceManager
    @Environment(\.bkPalette) private var palette

    @State private var isHovering = false
    @State private var isCloseHovering = false

    private var displayTitle: String {
        if tab.isShowingHome {
            return tab.tabTitle.isEmpty ? "새 탭 (시작 화면)" : tab.tabTitle
        }
        if !tab.tabTitle.isEmpty { return tab.tabTitle }
        if !tab.pageTitle.isEmpty { return tab.pageTitle }
        return tab.currentURL?.host ?? "새 탭"
    }

    private var displayDomain: String {
        if tab.isShowingHome {
            return "시작 화면"
        }
        if let host = tab.currentURL?.host, !host.isEmpty {
            return host
        }
        if let urlStr = tab.currentURL?.absoluteString, !urlStr.isEmpty {
            return urlStr
        }
        let addr = tab.address.trimmingCharacters(in: .whitespacesAndNewlines)
        return addr.isEmpty ? "열린 페이지 없음" : addr
    }

    private var canCloseCard: Bool {
        appModel.tabs.count > 1 || !tab.isShowingHome
    }

    var body: some View {
        let audioState = audioController.audioState(for: tab.webView)
        let cardShape = RoundedRectangle(cornerRadius: 10)

        ZStack(alignment: .topTrailing) {
            Button {
                appModel.selectTabFromOverview(tab.tabID)
            } label: {
                VStack(alignment: .leading, spacing: 0) {
                    thumbnailSection
                        .frame(height: 136)
                        .frame(maxWidth: .infinity)
                        .clipped()

                    Divider()

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            faviconView(size: 13)

                            Text(displayTitle)
                                .font(.system(size: 12.5, weight: isCurrentTab ? .semibold : .medium))
                                .foregroundColor(palette.textColor)
                                .lineLimit(1)
                                .truncationMode(.tail)

                            Spacer(minLength: 4)

                            if audioState == .playingAudible {
                                Image(systemName: "speaker.wave.2.fill")
                                    .font(.system(size: 10))
                                    .foregroundColor(palette.accentColor)
                                    .help("오디오 재생 중")
                            } else if audioState == .playingMuted {
                                Image(systemName: "speaker.slash.fill")
                                    .font(.system(size: 10))
                                    .foregroundColor(palette.warnColor)
                                    .help("오디오 음소거")
                            }

                            if isCurrentTab {
                                Text("현재 탭")
                                    .font(.system(size: 10, weight: .bold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(palette.accentSoftColor))
                                    .foregroundColor(palette.accentColor)
                            }
                        }

                        Text(displayDomain)
                            .font(.system(size: 11))
                            .foregroundColor(palette.mutedColor)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(palette.cardColor)
                }
                .background(palette.cardColor)
                .clipShape(cardShape)
                .overlay(
                    cardShape
                        .stroke(
                            isCurrentTab ? palette.accentColor : (isHovering ? palette.border2Color : palette.borderColor),
                            lineWidth: isCurrentTab ? 2.0 : 1.0
                        )
                )
                .contentShape(cardShape)
            }
            .buttonStyle(.plain)
            .contentShape(cardShape)
            .onHover { isHovering = $0 }
            .help("\(displayTitle) — \(displayDomain)")
            .accessibilityLabel("\(displayTitle), \(displayDomain)")
            .accessibilityValue(isCurrentTab ? "현재 탭" : "")
            .accessibilityAddTraits(isCurrentTab ? [.isSelected] : [])

            if canCloseCard {
                Button {
                    appModel.closeTab(tab.tabID)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(isCloseHovering ? palette.textColor : palette.mutedColor)
                        .frame(width: 22, height: 22)
                        .background(
                            Circle()
                                .fill(isCloseHovering ? palette.surface2Color : palette.cardColor.opacity(0.92))
                        )
                        .overlay(
                            Circle()
                                .stroke(palette.borderColor, lineWidth: 0.75)
                        )
                }
                .buttonStyle(.plain)
                .padding(7)
                .onHover { isCloseHovering = $0 }
                .help("탭 닫기")
                .accessibilityLabel("탭 닫기: \(displayTitle)")
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var thumbnailSection: some View {
        if let thumbnail = thumbnail, !tab.isShowingHome {
            GeometryReader { geo in
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                    .clipped()
            }
            .background(palette.surfaceColor)
        } else {
            VStack(spacing: 6) {
                if tab.isShowingHome {
                    Image(systemName: "house")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundColor(isCurrentTab ? palette.accentColor : palette.mutedColor)
                    Text("시작 화면")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(palette.text2Color)
                } else if tab.isLoading {
                    ProgressView()
                        .controlSize(.small)
                    Text("페이지 불러오는 중…")
                        .font(.system(size: 11))
                        .foregroundColor(palette.mutedColor)
                } else {
                    faviconView(size: 22)
                    Text(displayDomain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(palette.text2Color)
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                    Text("미리보기 준비 전")
                        .font(.system(size: 10))
                        .foregroundColor(palette.mutedColor)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(palette.surfaceColor)
        }
    }

    @ViewBuilder
    private func faviconView(size: CGFloat) -> some View {
        let urlString = tab.currentURL?.absoluteString ?? ""
        Group {
            if tab.isShowingHome {
                Image(systemName: "house")
                    .font(.system(size: size))
                    .foregroundColor(isCurrentTab ? palette.accentColor : palette.mutedColor)
            } else if !urlString.isEmpty, let favicon = bookmarkAppearance.appearance(for: urlString)?.favicon {
                Image(nsImage: favicon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size + 2, height: size + 2)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            } else {
                Image(systemName: "globe")
                    .font(.system(size: size))
                    .foregroundColor(isCurrentTab ? palette.accentColor : palette.mutedColor)
            }
        }
        .frame(width: size + 2, height: size + 2)
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
}
