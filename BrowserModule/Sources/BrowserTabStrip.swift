import SwiftUI
import AppKit
import WebKit

/// Horizontal browser tab row hosted in the window title bar toolbar (beside the traffic lights).
/// The address/navigation toolbar stays in BrowserView directly below.
public struct BrowserTabStrip: View {
    public static let tabStripHeight: CGFloat = 30
    /// 타이틀바(툴바) 전체 높이와 탭 상단 여백: 탭 상단 y는 유지하고 하단만 아래 주소줄까지 늘린다.
    public static let titlebarHeight: CGFloat = 52
    public static let tabTopInset: CGFloat = 12
    static let tabBottomExtension: CGFloat = titlebarHeight - tabTopInset - tabStripHeight
    @ObservedObject var appModel: AppModel
    /// 창 좌표 기준: 사이드바 오른쪽 경계(탭 시작 x)와 우측 기존 컨트롤 시작 x(탭 끝 한계)
    let sidebarEdgeX: CGFloat
    let rightLimitX: CGFloat
    @State private var itemMinX: CGFloat = 0
    @Environment(\.bkPalette) private var palette
    @ObservedObject private var audioController = PageAudioController.shared
    @ObservedObject private var bookmarkAppearance = BookmarkAppearanceManager.shared

    public init(appModel: AppModel, sidebarEdgeX: CGFloat = 0, rightLimitX: CGFloat = 0) {
        self.appModel = appModel
        self.sidebarEdgeX = sidebarEdgeX
        self.rightLimitX = rightLimitX
    }

    /// 툴바가 배치한 위치가 사이드바 경계보다 왼쪽이면 그만큼만 오른쪽으로 밀어 사이드바 위로 침범하지 않게 한다.
    private var leadingInset: CGFloat { max(0, sidebarEdgeX - itemMinX) }
    private var stripWidth: CGFloat? {
        guard rightLimitX > 0 else { return nil }
        return max(160, rightLimitX - itemMinX)
    }

    public var body: some View {
        HStack(alignment: .bottom, spacing: 4) {
            Color.clear.frame(width: leadingInset, height: 1)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(appModel.tabs, id: \.tabID) { tab in
                        BrowserTabItem(
                            appModel: appModel,
                            tab: tab,
                            isSelected: tab.tabID == appModel.selectedTabID,
                            audioController: audioController,
                            bookmarkAppearance: bookmarkAppearance
                        )
                    }
                }
            }
            newTabButton
                .padding(.bottom, Self.tabBottomExtension + 3)
        }
        // 남은 폭 안에서만 스크롤/축소해 우측 기존 컨트롤이 » 오버플로로 밀리지 않게 한다.
        .frame(width: stripWidth)
        .frame(minWidth: stripWidth == nil ? 240 : nil, idealWidth: stripWidth == nil ? 720 : nil, maxWidth: stripWidth == nil ? .infinity : nil)
        .frame(height: Self.titlebarHeight, alignment: .bottom)
        .background(WindowMinXReader(minX: $itemMinX).allowsHitTesting(false))
    }

    private var newTabButton: some View {
        Button {
            if appModel.tabs.count < AppModel.maxTabs {
                if let created = appModel.newTab() {
                    appModel.selectTab(created.tabID)
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(palette.mutedColor)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(palette.surfaceColor.opacity(0.6))
                )
        }
        .buttonStyle(.plain)
        .disabled(appModel.tabs.count >= AppModel.maxTabs)
        .help(appModel.tabs.count >= AppModel.maxTabs ? "더 이상 탭을 열 수 없습니다 (최대 \(AppModel.maxTabs)개)" : "새 탭 (⌘T)")
        .accessibilityLabel("새 탭 열기")
    }
}

/// A single tab item in the top horizontal tab strip.
private struct BrowserTabItem: View {
    @ObservedObject var appModel: AppModel
    @ObservedObject var tab: LoginBrowserModel
    let isSelected: Bool
    @ObservedObject var audioController: PageAudioController
    @ObservedObject var bookmarkAppearance: BookmarkAppearanceManager
    @Environment(\.bkPalette) private var palette
    @State private var isHovering = false
    @State private var isCloseHovering = false

    private var tabShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: 8, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: 8)
    }

    var body: some View {
        let audioState = audioController.audioState(for: tab.webView)

        Button {
            if !isSelected {
                appModel.selectTab(tab.tabID)
            }
        } label: {
            HStack(spacing: 6) {
                tabFaviconView(size: 12)

                Text(tab.tabTitle.isEmpty ? "새 탭" : tab.tabTitle)
                    .font(.system(size: 11.5, weight: isSelected ? .medium : .regular))
                    .foregroundColor(isSelected ? palette.textColor : palette.textColor.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 2)

                if audioState == .playingAudible {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 8))
                        .foregroundColor(palette.accentColor)
                } else if audioState == .playingMuted {
                    Image(systemName: "speaker.slash.fill")
                        .font(.system(size: 8))
                        .foregroundColor(palette.warnColor)
                }

                if appModel.tabs.count > 1 {
                    Button {
                        appModel.closeTab(tab.tabID)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(isCloseHovering ? palette.textColor : palette.mutedColor)
                            .frame(width: 16, height: 16)
                            .background(
                                Circle()
                                    .fill(isCloseHovering ? palette.surfaceColor : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                    .onHover { isCloseHovering = $0 }
                    .help("탭 닫기 (⌘W)")
                    .accessibilityLabel("탭 닫기: \(tab.tabTitle)")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: BrowserTabStrip.tabStripHeight)
            .padding(.bottom, BrowserTabStrip.tabBottomExtension)
            .frame(minWidth: 90, idealWidth: 160, maxWidth: 220)
            .contentShape(tabShape)
        }
        .buttonStyle(.plain)
        .background(
            tabShape
                .fill(isSelected ? palette.cardColor : (isHovering ? palette.surfaceColor.opacity(0.5) : Color.clear))
        )
        .overlay(
            // 활성 탭: 위쪽 모서리만 둥글고 아래는 열려 아래 주소 툴바(cardColor)와 이어짐
            tabShape
                .stroke(isSelected ? palette.borderColor.opacity(0.35) : Color.clear, lineWidth: 0.5)
                .mask(Rectangle().padding(.bottom, 1))
        )
        .overlay(alignment: .bottom) {
            if tab.isLoading {
                GeometryReader { geo in
                    palette.accentColor
                        .frame(width: geo.size.width * CGFloat(max(0, min(1, tab.progress))), height: 2)
                }
                .frame(height: 2)
                .allowsHitTesting(false)
            }
        }
        .onHover { isHovering = $0 }
        .help(tab.tabTitle)
        .accessibilityLabel("탭: \(tab.tabTitle)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
        .contextMenu {
            Button("새 탭") {
                if appModel.tabs.count < AppModel.maxTabs {
                    if let created = appModel.newTab() {
                        appModel.selectTab(created.tabID)
                    }
                }
            }
            .disabled(appModel.tabs.count >= AppModel.maxTabs)

            if appModel.tabs.count > 1 {
                Button("탭 닫기") {
                    appModel.closeTab(tab.tabID)
                }
            }
        }
    }

    @ViewBuilder
    private func tabFaviconView(size: CGFloat) -> some View {
        let urlString = tab.currentURL?.absoluteString ?? ""
        Group {
            if tab.isShowingHome {
                Image(systemName: "house")
                    .font(.system(size: size))
                    .foregroundColor(isSelected ? palette.accentColor : palette.mutedColor)
            } else if !urlString.isEmpty, let favicon = bookmarkAppearance.appearance(for: urlString)?.favicon {
                Image(nsImage: favicon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size + 2, height: size + 2)
                    .clipShape(RoundedRectangle(cornerRadius: 2))
            } else {
                Image(systemName: "globe")
                    .font(.system(size: size))
                    .foregroundColor(isSelected ? palette.accentColor : palette.mutedColor)
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

/// 뷰의 창 좌표 minX를 보고한다(툴바 항목의 실제 배치 x 측정용).
private struct WindowMinXReader: NSViewRepresentable {
    @Binding var minX: CGFloat

    final class Probe: NSView {
        var onChange: ((CGFloat) -> Void)?
        override func layout() {
            super.layout()
            guard window != nil else { return }
            let x = convert(bounds, to: nil).minX
            DispatchQueue.main.async { [weak self] in self?.onChange?(x) }
        }
    }

    func makeNSView(context: Context) -> Probe {
        let v = Probe()
        v.onChange = { x in if abs(x - minX) > 0.5 { minX = x } }
        return v
    }

    func updateNSView(_ nsView: Probe, context: Context) {
        nsView.onChange = { x in if abs(x - minX) > 0.5 { minX = x } }
        nsView.needsLayout = true
    }
}
