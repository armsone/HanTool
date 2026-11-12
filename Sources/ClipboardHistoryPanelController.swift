import AppKit
import SwiftUI
import Combine

/// 클립보드 히스토리 패널의 키 윈도우 지원 및 키보드 조작 처리용 커스텀 NSPanel.
final class ClipboardHistoryPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    var onEscapeKey: (() -> Void)?
    var onReturnKey: (() -> Void)?
    var onUpKey: (() -> Void)?
    var onDownKey: (() -> Void)?
    var onNumberShortcut: ((Int) -> Void)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])

            // 1. Command + 1~9 단축키 처리
            if modifiers == .command {
                if let characters = event.charactersIgnoringModifiers,
                   let num = Int(characters), (1...9).contains(num) {
                    onNumberShortcut?(num)
                    return
                }
            }

            // 2. 단독 방향키 및 Esc, Return 처리
            if modifiers.isEmpty {
                switch event.keyCode {
                case 53: // Esc
                    onEscapeKey?()
                    return
                case 36, 76: // Return / Enter
                    onReturnKey?()
                    return
                case 126: // Up Arrow
                    onUpKey?()
                    return
                case 125: // Down Arrow
                    onDownKey?()
                    return
                default:
                    break
                }
            }
        }
        super.sendEvent(event)
    }
}

/// 클립보드 히스토리 플로팅 창 관리자.
@MainActor
public final class ClipboardHistoryPanelController: NSObject, ObservableObject {
    public static let shared = ClipboardHistoryPanelController()

    // 820×580pt (약 1146:846 비율)
    private let panelSize = NSSize(width: 820, height: 580)

    private var panel: ClipboardHistoryPanel?
    private var previousApp: NSRunningApplication?

    // 뷰 모델 상태
    @Published var searchQuery: String = ""
    @Published var selectedIndex: Int = 0

    public var isVisible: Bool {
        panel?.isVisible ?? false
    }

    private override init() {
        super.init()
    }

    private func createPanelIfNeeded() -> ClipboardHistoryPanel {
        if let existing = panel {
            return existing
        }

        let p = ClipboardHistoryPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isMovableByWindowBackground = true

        let rootView = ClipboardHistoryContentView(controller: self)
        let hosting = NSHostingView(rootView: rootView)
        hosting.autoresizingMask = [.width, .height]
        p.contentView = hosting

        p.onEscapeKey = { [weak self] in
            self?.hide()
        }
        p.onReturnKey = { [weak self] in
            self?.confirmSelection()
        }
        p.onUpKey = { [weak self] in
            self?.moveSelection(by: -1)
        }
        p.onDownKey = { [weak self] in
            self?.moveSelection(by: 1)
        }
        p.onNumberShortcut = { [weak self] number in
            self?.selectAndConfirm(number: number)
        }

        self.panel = p
        return p
    }

    public func toggle() {
        if isVisible {
            hide()
        } else {
            showAndFocus()
        }
    }

    public func showAndFocus() {
        // 단축키 실행 전 최상단 활성 앱 기억
        previousApp = NSWorkspace.shared.frontmostApplication

        let p = createPanelIfNeeded()

        // 화면 중앙에 배치
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.midX - panelSize.width / 2
            let y = screenFrame.midY - panelSize.height / 2
            p.setFrame(NSRect(x: x, y: y, width: panelSize.width, height: panelSize.height), display: true)
        }

        // 검색어 및 선택 초기화
        searchQuery = ""
        selectedIndex = 0

        p.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func hide() {
        panel?.orderOut(nil)
    }

    public func moveSelection(by delta: Int) {
        let count = filteredItems.count
        guard count > 0 else { return }
        var next = selectedIndex + delta
        if next < 0 { next = 0 }
        if next >= count { next = count - 1 }
        selectedIndex = next
    }

    public func selectAndConfirm(number: Int) {
        let index = number - 1
        let list = filteredItems
        guard index >= 0 && index < list.count else { return }
        selectedIndex = index
        confirmSelection()
    }

    public func confirmSelection() {
        let list = filteredItems
        guard selectedIndex >= 0 && selectedIndex < list.count else {
            hide()
            return
        }

        let item = list[selectedIndex]
        // 1. 시스템 클립보드에 복사
        ClipboardHistoryStore.shared.copyToPasteboard(item: item)

        // 2. 패널 닫기
        hide()

        // 3. 이전 활성 앱으로 포커스 복귀 (자동 붙여넣기는 하지 않고 수동 붙여넣기 유도)
        if let prev = previousApp {
            prev.activate(options: .activateIgnoringOtherApps)
        }
    }

    public var filteredItems: [ClipboardItem] {
        let all = ClipboardHistoryStore.shared.items
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty {
            return all
        }
        return all.filter { item in
            if let text = item.textContent, text.localizedCaseInsensitiveContains(q) {
                return true
            }
            if let appName = item.sourceAppName, appName.localizedCaseInsensitiveContains(q) {
                return true
            }
            if item.type == .image && "image 이미지".localizedCaseInsensitiveContains(q) {
                return true
            }
            return false
        }
    }
}

// MARK: - SwiftUI View for Clipboard History Panel
struct ClipboardHistoryContentView: View {
    @ObservedObject var controller: ClipboardHistoryPanelController
    @ObservedObject var store = ClipboardHistoryStore.shared

    // 시각 기준 색상: 청록 블루그레이 #6c909c, 선택 하이라이트 #496b76
    private let primaryBgColor = Color(red: 0x6c / 255.0, green: 0x90 / 255.0, blue: 0x9c / 255.0)
    private let selectedHighlightColor = Color(red: 0x49 / 255.0, green: 0x6b / 255.0, blue: 0x76 / 255.0)
    private let borderInsetStrokeColor = Color.white.opacity(0.18)

    var body: some View {
        VStack(spacing: 0) {
            // 1. 상단 전폭 검색창 (높이 52pt, 폰트 26pt Light)
            searchHeaderView
                .frame(height: 52)

            Divider()
                .background(Color.black.opacity(0.12))

            // 2. 좌우 50:50 분할 본문 영역
            HStack(spacing: 0) {
                // 좌측 목록 (~410pt)
                itemListView
                    .frame(maxWidth: .infinity)

                Rectangle()
                    .fill(Color.black.opacity(0.1))
                    .frame(width: 1)

                // 우측 미리보기 (~410pt)
                previewPaneView
                    .frame(maxWidth: .infinity)
            }
            .frame(maxHeight: .infinity)
        }
        .background(primaryBgColor)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(borderInsetStrokeColor, lineWidth: 1)
        )
    }

    // MARK: - Search Header
    private var searchHeaderView: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 20, weight: .light))
                .foregroundColor(.white.opacity(0.7))
                .padding(.leading, 16)

            TextField("", text: $controller.searchQuery, prompt: Text("클립보드 검색...").foregroundColor(.white.opacity(0.4)))
                .textFieldStyle(PlainTextFieldStyle())
                .font(.system(size: 26, weight: .light))
                .foregroundColor(.white)
                .accentColor(.white)

            if !controller.searchQuery.isEmpty {
                Button(action: { controller.searchQuery = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.white.opacity(0.6))
                        .font(.system(size: 16))
                }
                .buttonStyle(PlainButtonStyle())
                .padding(.trailing, 16)
            } else {
                Spacer().frame(width: 16)
            }
        }
    }

    // MARK: - Left Item List
    private var itemListView: some View {
        let items = controller.filteredItems

        return Group {
            if items.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 32, weight: .light))
                        .foregroundColor(.white.opacity(0.5))
                    Text(controller.searchQuery.isEmpty ? "클립보드 기록이 없습니다." : "검색 결과가 없습니다.")
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.6))
                    Spacer()
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                listItemRow(item: item, index: index)
                                    .id(index)
                                    .onTapGesture {
                                        controller.selectedIndex = index
                                    }
                            }
                        }
                    }
                    .onChange(of: controller.selectedIndex) { newIdx in
                        withAnimation(.easeInOut(duration: 0.1)) {
                            proxy.scrollTo(newIdx, anchor: .center)
                        }
                    }
                }
            }
        }
    }

    private func listItemRow(item: ClipboardItem, index: Int) -> some View {
        let isSelected = (index == controller.selectedIndex)

        return HStack(spacing: 10) {
            // 앱 아이콘 또는 타입 아이콘 (24×24, R5)
            leadingIconView(item: item)
                .frame(width: 24, height: 24)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

            // 1줄 말줄임 제목 (14.5pt)
            Text(item.displayTitle)
                .font(.system(size: 14.5, weight: isSelected ? .medium : .regular))
                .foregroundColor(.white)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()

            // 우측 단축키 힌트: 선택 행은 ↩ 기호, 상위 1~9는 ⌘1~9
            if isSelected {
                Text("↩")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.2))
                    .cornerRadius(4)
            } else if index < 9 {
                Text("⌘\(index + 1)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.6))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.15))
                    .cornerRadius(4)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(isSelected ? selectedHighlightColor : Color.clear)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func leadingIconView(item: ClipboardItem) -> some View {
        if item.type == .image {
            if let thumb = store.loadThumbnail(for: item) {
                Image(nsImage: thumb)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.8))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.2))
            }
        } else {
            if let bundleID = item.sourceAppBundleID,
               let icon = appIcon(for: bundleID) {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "doc.text")
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.8))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.2))
            }
        }
    }

    private func appIcon(for bundleID: String) -> NSImage? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return nil
    }

    // MARK: - Right Preview Pane
    private var previewPaneView: some View {
        let items = controller.filteredItems
        let selectedItem: ClipboardItem? = {
            guard controller.selectedIndex >= 0 && controller.selectedIndex < items.count else {
                return nil
            }
            return items[controller.selectedIndex]
        }()

        return Group {
            if let item = selectedItem {
                VStack(spacing: 0) {
                    // 미리보기 본문 (텍스트 또는 이미지)
                    previewContentView(item: item)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    Divider()
                        .background(Color.black.opacity(0.1))

                    // 하단 푸터 (단어/글자수 또는 해상도, 복사 시간)
                    previewFooterView(item: item)
                        .frame(height: 32)
                        .padding(.horizontal, 14)
                        .background(Color.black.opacity(0.08))
                }
            } else {
                VStack {
                    Spacer()
                    Text("항목을 선택하면 미리보기가 표시됩니다.")
                        .font(.system(size: 13.5))
                        .foregroundColor(.white.opacity(0.5))
                    Spacer()
                }
            }
        }
    }

    @ViewBuilder
    private func previewContentView(item: ClipboardItem) -> some View {
        switch item.type {
        case .text:
            ScrollView(.vertical, showsIndicators: true) {
                Text(item.textContent ?? "")
                    .font(.system(size: 13.5))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(16)
                    .textSelection(.enabled)
            }
        case .image:
            if let url = store.imageURL(for: item),
               let image = NSImage(contentsOf: url) {
                GeometryReader { geo in
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(
                            width: max(0, geo.size.width - 32),
                            height: max(0, geo.size.height - 32)
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "photo")
                        .font(.system(size: 36))
                        .foregroundColor(.white.opacity(0.4))
                    Text("이미지를 로드할 수 없습니다.")
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.6))
                }
            }
        }
    }

    private func previewFooterView(item: ClipboardItem) -> some View {
        HStack {
            if item.type == .text {
                if let stats = item.textStats {
                    Text("\(stats.words) words; \(stats.chars) chars")
                        .font(.system(size: 11.5))
                        .foregroundColor(.white.opacity(0.7))
                }
            } else if item.type == .image {
                let w = item.imageWidth ?? 0
                let h = item.imageHeight ?? 0
                let bytes = item.fileSize ?? 0
                let sizeStr = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
                Text("\(w) × \(h)  •  \(sizeStr)")
                    .font(.system(size: 11.5))
                    .foregroundColor(.white.opacity(0.7))
            }

            Spacer()

            if let appName = item.sourceAppName, !appName.isEmpty {
                Text(appName)
                    .font(.system(size: 11.5))
                    .foregroundColor(.white.opacity(0.6))
                Text("•")
                    .foregroundColor(.white.opacity(0.4))
            }

            Text("Copied \(formattedRelativeDate(item.copiedAt))")
                .font(.system(size: 11.5))
                .foregroundColor(.white.opacity(0.7))
        }
    }

    private func formattedRelativeDate(_ date: Date) -> String {
        let calendar = Calendar.autoupdatingCurrent
        let now = Date()
        let startToday = calendar.startOfDay(for: now)
        let startTarget = calendar.startOfDay(for: date)
        let dayDiff = calendar.dateComponents([.day], from: startTarget, to: startToday).day ?? 0

        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "ko_KR")
        timeFormatter.dateFormat = "HH:mm"

        let timeStr = timeFormatter.string(from: date)

        if dayDiff == 0 {
            return timeStr
        } else if dayDiff == 1 {
            return "어제 \(timeStr)"
        } else {
            let fullFormatter = DateFormatter()
            fullFormatter.locale = Locale(identifier: "ko_KR")
            fullFormatter.dateFormat = "MM/dd(EEE) HH:mm"
            return fullFormatter.string(from: date)
        }
    }
}
