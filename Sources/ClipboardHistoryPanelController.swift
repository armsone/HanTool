import AppKit
import SwiftUI
import Combine

// MARK: - 병기스타일 클립보드 패널 환경설정 (Color / Opacity Live Preferences)

@MainActor
public final class ClipboardPanelPreferences: ObservableObject {
    public static let shared = ClipboardPanelPreferences()

    public static let customColorKey = "clipboardPanelCustomColorHex"
    public static let opacityKey = "clipboardPanelOpacity"
    public static let useCustomColorKey = "clipboardPanelUseCustomColor"

    @Published public var useCustomColor: Bool {
        didSet {
            UserDefaults.standard.set(useCustomColor, forKey: Self.useCustomColorKey)
        }
    }

    @Published public var customColorHex: String {
        didSet {
            UserDefaults.standard.set(customColorHex, forKey: Self.customColorKey)
        }
    }

    @Published public var opacity: Double {
        didSet {
            UserDefaults.standard.set(opacity, forKey: Self.opacityKey)
        }
    }

    private init() {
        self.useCustomColor = UserDefaults.standard.bool(forKey: Self.useCustomColorKey)
        self.customColorHex = UserDefaults.standard.string(forKey: Self.customColorKey) ?? ""
        let storedOpacity = UserDefaults.standard.object(forKey: Self.opacityKey) as? Double
        self.opacity = storedOpacity ?? 1.0
    }

    public func effectiveBackgroundColor(palette: HTTThemePalette) -> Color {
        let baseColor: Color
        if useCustomColor, let parsed = Color(hexString: customColorHex) {
            baseColor = parsed
        } else {
            baseColor = palette.bg
        }
        let clampedOpacity = min(max(opacity, 0.1), 1.0)
        return baseColor.opacity(clampedOpacity)
    }

    /// 사용자 지정 배경색이 테마 팔레트와 명암이 반대일 때 글자 가독성을 위해 기존 light/jarvis 팔레트로 대체한다.
    public func readablePalette(_ palette: HTTThemePalette, themeIsDark: Bool) -> HTTThemePalette {
        guard useCustomColor, let dark = Color.isDarkHex(customColorHex), dark != themeIsDark else { return palette }
        return dark ? .jarvis : .light
    }
}

private extension Color {
    static func isDarkHex(_ hex: String) -> Bool? {
        let c = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard let v = UInt64(c, radix: 16) else { return nil }
        let r, g, b: Double
        switch c.count {
        case 3: (r, g, b) = (Double((v >> 8) * 17), Double((v >> 4 & 0xF) * 17), Double((v & 0xF) * 17))
        case 6: (r, g, b) = (Double(v >> 16), Double(v >> 8 & 0xFF), Double(v & 0xFF))
        case 8: (r, g, b) = (Double(v >> 16 & 0xFF), Double(v >> 8 & 0xFF), Double(v & 0xFF))
        default: return nil
        }
        return (0.299 * r + 0.587 * g + 0.114 * b) / 255.0 < 0.5
    }

    init?(hexString: String) {
        let cleanHex = hexString.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard !cleanHex.isEmpty else { return nil }
        var int: UInt64 = 0
        guard Scanner(string: cleanHex).scanHexInt64(&int) else { return nil }
        let a, r, g, b: UInt64
        switch cleanHex.count {
        case 3:
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            return nil
        }
        self.init(
            .sRGB,
            red: Double(r) / 255.0,
            green: Double(g) / 255.0,
            blue: Double(b) / 255.0,
            opacity: Double(a) / 255.0
        )
    }
}

/// 클립보드 히스토리 패널의 키 윈도우 지원 및 키보드 조작 처리용 커스텀 NSPanel.
final class ClipboardHistoryPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    var onEscapeKey: (() -> Void)?
    var onReturnKey: (() -> Void)?
    var onUpKey: (() -> Void)?
    var onDownKey: (() -> Void)?
    var onNumberShortcut: ((Int) -> Void)?
    /// Space: 목록 키보드 탐색 중이면 true를 반환해 확정으로 소비, 아니면 false(검색 필드의 공백 입력으로 통과).
    var onSpaceKey: (() -> Bool)?
    /// 그 외 일반 문자/삭제 입력(검색 타이핑 재개) 알림.
    var onTypingKey: (() -> Void)?

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

            // 2. 방향키, Return, Esc 처리 (Shift / Cmd 등이 눌려 있어도 확인 및 이동 보장)
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
            case 49 where modifiers.isDisjoint(with: [.command, .control, .option]): // Space
                if onSpaceKey?() == true { return }
                onTypingKey?()
            default:
                if modifiers.isDisjoint(with: [.command, .control, .option]),
                   let chars = event.characters, !chars.isEmpty {
                    onTypingKey?()
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
    // 표시 중에만 등록되는 바깥 클릭 관찰자(local: 우리 앱 다른 창, global: 다른 앱). 이벤트는 소비하지 않는다.
    private var outsideLocalMonitor: Any?
    private var outsideGlobalMonitor: Any?
    private var shownAt: TimeInterval = 0

    private enum CloseReason { case selection, escape, outsideClick, toggle }

    // 뷰 모델 상태
    @Published var searchQuery: String = "" {
        didSet {
            keyboardNavigating = false
            clampSelectedIndex()
        }
    }
    @Published var selectedIndex: Int = 0
    // ↑/↓로 목록을 이동한 뒤에만 true. 표시/검색어 변경/일반 타이핑 재개 시 false → 이때 Space는 검색 공백.
    private var keyboardNavigating = false

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
            self?.close(.escape)
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
        p.onSpaceKey = { [weak self] in
            guard let self, self.keyboardNavigating else { return false }
            self.confirmSelection()
            return true
        }
        p.onTypingKey = { [weak self] in
            self?.keyboardNavigating = false
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
        // 단축키/메뉴 등에서 사전 캡처되지 않은 경우 대비 캡처 보장
        ClipboardPasteCoordinator.shared.captureOriginTargetIfNeeded()
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
        keyboardNavigating = false

        p.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        installOutsideClickObservers(panel: p)
    }

    public func hide() {
        close(.toggle)
    }

    /// 닫힘의 단일 경로: 관찰자 해제 + 즉시 orderOut. 선택 확정은 대상 토큰을 건드리지 않고, 그 외는 취소로 토큰을 무효화한다.
    private func close(_ reason: CloseReason) {
        removeOutsideClickObservers()
        keyboardNavigating = false
        let wasVisible = panel?.isVisible ?? false
        panel?.orderOut(nil)
        switch reason {
        case .selection:
            break
        case .escape:
            let target = ClipboardPasteCoordinator.shared.consumePendingTarget()
            ClipboardPasteCoordinator.shared.cancelPendingPaste()
            if wasVisible, let target = target {
                ClipboardPasteCoordinator.shared.restoreOriginFocus(target)
            }
        case .outsideClick, .toggle:
            ClipboardPasteCoordinator.shared.cancelPendingPaste()
        }
    }

    private func installOutsideClickObservers(panel p: ClipboardHistoryPanel) {
        removeOutsideClickObservers()
        shownAt = ProcessInfo.processInfo.systemUptime
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        outsideLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self, weak p] event in
            MainActor.assumeIsolated {
                guard let self = self, let p = p, event.window !== p, event.timestamp > self.shownAt else { return }
                self.close(.outsideClick)
            }
            return event
        }
        outsideGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self = self, event.timestamp > self.shownAt else { return }
                self.close(.outsideClick)
            }
        }
    }

    private func removeOutsideClickObservers() {
        if let m = outsideLocalMonitor { NSEvent.removeMonitor(m); outsideLocalMonitor = nil }
        if let m = outsideGlobalMonitor { NSEvent.removeMonitor(m); outsideGlobalMonitor = nil }
    }

    public func clampSelectedIndex() {
        let count = filteredItems.count
        if count == 0 {
            selectedIndex = 0
        } else if selectedIndex >= count {
            selectedIndex = count - 1
        } else if selectedIndex < 0 {
            selectedIndex = 0
        }
    }

    public func moveSelection(by delta: Int) {
        let count = filteredItems.count
        guard count > 0 else {
            selectedIndex = 0
            return
        }
        keyboardNavigating = true
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
            close(.escape)
            return
        }

        let item = list[selectedIndex]
        // 1. 시스템 클립보드에 복사 (자기 재복사 억제, 히스토리 순서 보존)
        let copiedChangeCount = ClipboardHistoryStore.shared.copyToPasteboard(item: item)

        // 2. 자동 붙여넣기 대상 확보 (once-consume)
        let target = ClipboardPasteCoordinator.shared.consumePendingTarget()

        // 3. 패널 즉시 닫기 (관찰자 해제, 붙여넣기 토큰은 유지)
        close(.selection)

        // 4. 대상 앱·창·입력위치로 자동 붙여넣기 실행 (타깃 소멸/바뀜/보안입력 시 복사 상태 유지 및 중단)
        if let target = target {
            ClipboardPasteCoordinator.shared.performAutoPaste(target: target, expectedChangeCount: copiedChangeCount, for: item)
        } else if let prev = previousApp {
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
    /// 브라우저 왼쪽 메뉴 '클립보드' 화면에 삽입될 때 true: 행 클릭은 복사만 하고 창 닫기/앱 전환은 하지 않는다.
    var embedded = false
    @ObservedObject var store = ClipboardHistoryStore.shared
    @ObservedObject var appearanceStore = HTTAppearanceStore.shared
    @ObservedObject var panelPrefs = ClipboardPanelPreferences.shared
    @Environment(\.colorScheme) private var systemColorScheme

    private var themeIsDark: Bool {
        appearanceStore.effectiveColorScheme(for: systemColorScheme).map { $0 == .dark } ?? (systemColorScheme == .dark)
    }

    private var palette: HTTThemePalette {
        panelPrefs.readablePalette(appearanceStore.palette(for: systemColorScheme), themeIsDark: themeIsDark)
    }

    private var customScheme: ColorScheme? {
        guard panelPrefs.useCustomColor, let dark = Color.isDarkHex(panelPrefs.customColorHex) else { return nil }
        return dark ? .dark : .light
    }

    var body: some View {
        VStack(spacing: 0) {
            // 1. 상단 전폭 검색창 (높이 52pt, 폰트 26pt Light)
            searchHeaderView
                .frame(height: 52)

            Divider()
                .background(palette.border)

            // 2. 좌우 50:50 분할 본문 영역
            HStack(spacing: 0) {
                // 좌측 목록 (~410pt)
                itemListView
                    .frame(maxWidth: .infinity)

                Rectangle()
                    .fill(palette.border)
                    .frame(width: 1)

                // 우측 미리보기 (~410pt)
                previewPaneView
                    .frame(maxWidth: .infinity)
            }
            .frame(maxHeight: .infinity)
        }
        .background(panelPrefs.effectiveBackgroundColor(palette: palette))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(palette.border2.opacity(0.8), lineWidth: 1)
        )
        .preferredColorScheme(customScheme ?? appearanceStore.effectiveColorScheme(for: systemColorScheme))
    }

    // MARK: - Search Header
    private var searchHeaderView: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 20, weight: .light))
                .foregroundColor(palette.muted)
                .padding(.leading, 16)

            TextField("", text: $controller.searchQuery, prompt: Text("클립보드 검색...").foregroundColor(palette.muted))
                .textFieldStyle(PlainTextFieldStyle())
                .font(.system(size: 26, weight: .light))
                .foregroundColor(palette.text)
                .accentColor(palette.accent)

            if !controller.searchQuery.isEmpty {
                Button(action: { controller.searchQuery = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(palette.muted)
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
                        .foregroundColor(palette.muted)
                    Text(controller.searchQuery.isEmpty ? "클립보드 기록이 없습니다." : "검색 결과가 없습니다.")
                        .font(.system(size: 14))
                        .foregroundColor(palette.muted)
                    Spacer()
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                listItemRow(item: item, index: index, palette: palette)
                                    .id(index)
                                    .onTapGesture {
                                        controller.selectedIndex = index
                                        if embedded {
                                            store.copyToPasteboard(item: item)
                                        } else {
                                            controller.confirmSelection()
                                        }
                                    }
                            }
                        }
                        .padding(.vertical, 4)
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

    private func listItemRow(item: ClipboardItem, index: Int, palette: HTTThemePalette) -> some View {
        let isSelected = (index == controller.selectedIndex)

        return HStack(spacing: 8) {
            // 좌측 선택 마커 (인디케이터 바)
            RoundedRectangle(cornerRadius: 1.5)
                .fill(isSelected ? palette.accent : Color.clear)
                .frame(width: 3, height: 18)
                .padding(.leading, 2)

            // 앱 아이콘 또는 타입 아이콘 (24×24, R5)
            leadingIconView(item: item, palette: palette)
                .frame(width: 24, height: 24)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

            // 1줄 말줄임 제목 (14.5pt) - 반전 없이 조화로운 텍스트 색상
            Text(item.displayTitle)
                .font(.system(size: 14.5, weight: isSelected ? .medium : .regular))
                .foregroundColor(isSelected ? palette.text : palette.text2)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()

            // 우측 단축키 힌트: 선택 행은 ↩ 기호, 상위 1~9는 ⌘1~9
            if isSelected {
                Text("↩")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(palette.text)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(palette.accentSoft)
                    .cornerRadius(4)
            } else if index < 9 {
                Text("⌘\(index + 1)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(palette.muted)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(palette.surface2.opacity(0.6))
                    .cornerRadius(4)
            }
        }
        .padding(.trailing, 10)
        .frame(height: 38)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? palette.accentSoft.opacity(0.35) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(isSelected ? palette.accent.opacity(0.7) : Color.clear, lineWidth: 1.5)
        )
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func leadingIconView(item: ClipboardItem, palette: HTTThemePalette) -> some View {
        if item.type == .image {
            if let thumb = store.loadThumbnail(for: item) {
                Image(nsImage: thumb)
                    .renderingMode(.original)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 14))
                    .foregroundColor(palette.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(palette.surface2)
            }
        } else {
            if let bundleID = item.sourceAppBundleID,
               let icon = appIcon(for: bundleID) {
                Image(nsImage: icon)
                    .renderingMode(.original)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "doc.text")
                    .font(.system(size: 14))
                    .foregroundColor(palette.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(palette.surface2)
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
                    previewContentView(item: item, palette: palette)
                        .id(item.id)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    Divider()
                        .background(palette.border)

                    // 하단 푸터 (단어/글자수 또는 해상도, 복사 시간)
                    previewFooterView(item: item, palette: palette)
                        .frame(height: 32)
                        .padding(.horizontal, 14)
                        .background(palette.card.opacity(0.5))
                }
                .background(palette.card.opacity(0.3))
                .overlay(
                    Rectangle()
                        .stroke(palette.accent.opacity(0.45), lineWidth: 1.5)
                        .allowsHitTesting(false)
                )
            } else {
                VStack {
                    Spacer()
                    Text("항목을 선택하면 미리보기가 표시됩니다.")
                        .font(.system(size: 13.5))
                        .foregroundColor(palette.muted)
                    Spacer()
                }
                .background(palette.card.opacity(0.2))
            }
        }
    }

    @ViewBuilder
    private func previewContentView(item: ClipboardItem, palette: HTTThemePalette) -> some View {
        switch item.type {
        case .text:
            ScrollView(.vertical, showsIndicators: true) {
                Text(item.textContent ?? "")
                    .font(.system(size: 13.5))
                    .foregroundColor(palette.text)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(16)
                    .textSelection(.enabled)
            }
        case .image:
            if let url = store.imageURL(for: item),
               let image = NSImage(contentsOf: url) {
                GeometryReader { geo in
                    Image(nsImage: image)
                        .renderingMode(.original)
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
                        .foregroundColor(palette.muted)
                    Text("이미지를 로드할 수 없습니다.")
                        .font(.system(size: 13))
                        .foregroundColor(palette.muted)
                }
            }
        }
    }

    private func previewFooterView(item: ClipboardItem, palette: HTTThemePalette) -> some View {
        HStack {
            if item.type == .text {
                if let stats = item.textStats {
                    Text("\(stats.words) words; \(stats.chars) chars")
                        .font(.system(size: 11.5))
                        .foregroundColor(palette.text2)
                }
            } else if item.type == .image {
                let w = item.imageWidth ?? 0
                let h = item.imageHeight ?? 0
                let bytes = item.fileSize ?? 0
                let sizeStr = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
                Text("\(w) × \(h)  •  \(sizeStr)")
                    .font(.system(size: 11.5))
                    .foregroundColor(palette.text2)
            }

            Spacer()

            if let appName = item.sourceAppName, !appName.isEmpty {
                Text(appName)
                    .font(.system(size: 11.5))
                    .foregroundColor(palette.muted)
                Text("•")
                    .foregroundColor(palette.border2)
            }

            Text("Copied \(formattedRelativeDate(item.copiedAt))")
                .font(.system(size: 11.5))
                .foregroundColor(palette.text2)
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

/// 브라우저 왼쪽 메뉴 '클립보드' 화면: 저장 목록/미리보기를 보여 주고, 같은 화면에서 설정으로 이동한다.
struct ClipboardHistoryBrowserPane: View {
    @ObservedObject private var appearanceStore = HTTAppearanceStore.shared
    @Environment(\.colorScheme) private var systemColorScheme
    @State private var showingSettings = false

    private var palette: HTTThemePalette {
        appearanceStore.palette(for: systemColorScheme)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("클립보드")
                    .font(.headline)
                    .foregroundColor(palette.text)
                Spacer()
                Button(showingSettings ? "목록 보기" : "설정") {
                    showingSettings.toggle()
                }
                .help(showingSettings ? "저장된 클립보드 목록으로 돌아갑니다" : "클립보드 설정을 엽니다")
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            Divider()
            if showingSettings {
                ClipboardHistorySettingsView()
            } else {
                ClipboardHistoryContentView(controller: ClipboardHistoryPanelController.shared, embedded: true)
                    .onAppear {
                        ClipboardHistoryPanelController.shared.searchQuery = ""
                        ClipboardHistoryPanelController.shared.selectedIndex = 0
                    }
            }
        }
        .background(palette.bg)
    }
}
