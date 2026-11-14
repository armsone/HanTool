import AppKit
import Carbon.HIToolbox
import Combine
import HTTHTDCore
import ServiceManagement
import SwiftUI

private final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

private struct MenuBarNetworkRateView: View {
    @ObservedObject private var monitor = NetworkRateMonitor.shared

    var body: some View {
        let upload = NetworkRateMonitor.formatRate(monitor.uploadRate)
        let download = NetworkRateMonitor.formatRate(monitor.downloadRate)

        VStack(alignment: .leading, spacing: 1) {
            rateRow(
                color: .red,
                rate: upload,
                label: "업로드"
            )
            rateRow(
                color: .blue,
                rate: download,
                label: "다운로드"
            )
        }
        .frame(width: 68, height: 22, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Mac 이더넷 및 Wi-Fi 전체 네트워크 속도: 업로드 \(upload.value) \(upload.unit), 다운로드 \(download.value) \(download.unit)"
        )
    }

    private func rateRow(color: Color, rate: (value: String, unit: String), label: String) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 4.5, height: 4.5)
                .accessibilityHidden(true)

            Text(rate.value)
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .foregroundColor(.primary)
                .lineLimit(1)
                .frame(width: 31, alignment: .trailing)

            Text(rate.unit)
                .font(.system(size: 7.5, weight: .regular, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .frame(width: 23, alignment: .leading)
        }
        .accessibilityLabel("\(label): \(rate.value) \(rate.unit)")
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var overlay: OverlayPanelController!
    private let viewModel = AppViewModel()
    private let loginItem = LoginItemManager()
    private let updater = UpdaterManager()
    private var hotKey: GlobalHotKey?
    private var mailHotKey: GlobalHotKey?
    private var browserHotKey: GlobalHotKey?
    private var statusItem: NSStatusItem?
    private var networkRateStatusItem: NSStatusItem?
    private var mainStatusMenu: NSMenu?
    private var networkRateMenu: NSMenu?
    private var networkRateCancellables = Set<AnyCancellable>()
    private var isStatusMenuOpen = false
    private var explicitAppTerminationRequested = false

    private var duplicateLaunchTarget: NSRunningApplication?
    private var duplicateLaunchExit: DispatchWorkItem?
    private var launchFinished = false
    private var duplicateURLForwarded = false
    private var duplicateForwardedURLs: Set<String> = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let ownURL = Bundle.main.bundleURL.standardizedFileURL.resolvingSymlinksInPath()
        duplicateLaunchTarget = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated &&
                $0.bundleURL?.standardizedFileURL.resolvingSymlinksInPath() == ownURL }
            .min { $0.processIdentifier < $1.processIdentifier }
    }

    private func finishDuplicateLaunch() {
        duplicateLaunchExit?.cancel()
        explicitAppTerminationRequested = true
        NSApp.terminate(nil)
    }

    private func forwardDuplicateURLs(_ urls: [URL]) {
        guard let target = duplicateLaunchTarget, !target.isTerminated else { return }
        let valid = EmbeddedBrowser.forwardableWebURLs(urls).filter {
            !duplicateForwardedURLs.contains($0.absoluteString)
        }
        let files = urls.filter { $0.isFileURL && !duplicateForwardedURLs.contains($0.absoluteString) }.prefix(1)
        guard !valid.isEmpty || !files.isEmpty else { return }
        do {
            for url in valid {
                let event = NSAppleEventDescriptor(eventClass: AEEventClass(kInternetEventClass),
                    eventID: AEEventID(kAEGetURL),
                    targetDescriptor: NSAppleEventDescriptor(processIdentifier: target.processIdentifier),
                    returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
                event.setParam(NSAppleEventDescriptor(string: url.absoluteString), forKeyword: AEKeyword(keyDirectObject))
                _ = try event.sendEvent(options: .waitForReply, timeout: 5)
                duplicateForwardedURLs.insert(url.absoluteString)
            }
            if !files.isEmpty {
                let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass),
                    eventID: AEEventID(kAEOpenDocuments),
                    targetDescriptor: NSAppleEventDescriptor(processIdentifier: target.processIdentifier),
                    returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
                let items = NSAppleEventDescriptor.list()
                for (index, url) in files.enumerated() {
                    items.insert(NSAppleEventDescriptor(fileURL: url), at: index + 1)
                }
                event.setParam(items, forKeyword: AEKeyword(keyDirectObject))
                _ = try event.sendEvent(options: .waitForReply, timeout: 5)
                for url in files { duplicateForwardedURLs.insert(url.absoluteString) }
            }
            duplicateURLForwarded = true
        } catch {
            // No URL or account data in diagnostics.
            NSLog("HanTool URL handoff failed status=%ld", (error as NSError).code)
        }
        if launchFinished { finishDuplicateLaunch() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        launchFinished = true
        if let target = duplicateLaunchTarget {
            let argumentURLs = CommandLine.arguments.dropFirst().compactMap { arg -> URL? in
                if let url = URL(string: arg), url.scheme != nil { return url }
                let path = NSString(string: arg).expandingTildeInPath
                if FileManager.default.fileExists(atPath: path) {
                    return URL(fileURLWithPath: path)
                }
                return nil
            }
            if !argumentURLs.isEmpty { forwardDuplicateURLs(argumentURLs) }
            if duplicateURLForwarded { finishDuplicateLaunch(); return }
            target.activate(options: [])
            // The initial OS URL event can follow didFinishLaunching. The
            // secondary stays store/UI-free and exits as soon as it is forwarded.
            let exit = DispatchWorkItem { [weak self] in self?.finishDuplicateLaunch() }
            duplicateLaunchExit = exit
            DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: exit)
            return
        }

        BundledFonts.registerIfNeeded()
        // 원화 환산 환율(번역과 별도): 저장 환율을 읽고, 연결 상태·앱 활성화를 지켜보며 뒤에서 갱신한다.
        ExchangeRateStore.shared.start()
        applyBundleIcon()
        buildMainMenu()

        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: 660, height: 400)
        let initialRegion = NSRect(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.midY - size.height / 2,
            width: size.width,
            height: size.height
        ).integral
        overlay = OverlayPanelController(initialFrame: initialRegion, viewModel: viewModel)
        viewModel.attach(overlay: overlay)
        overlay.onWillHide = { [weak self] in
            self?.viewModel.windowWillHide()
            // 캡처 모드가 끝나면 시작 전에 보이던 같은 HTT 작업 창으로 돌아간다(작업 창이 없었으면 열지 않는다).
            MailWindowCoordinator.shared.captureModeDidEnd()
        }
        viewModel.onHideRequested = { [weak self] in self?.overlay.hide() }
        // 작업 창을 보일 때 캡처 영역이 겹쳐 남지 않도록 코디네이터가 조회·숨김할 수 있게 연결한다.
        MailWindowCoordinator.shared.isCaptureVisible = { [weak self] in self?.overlay.isVisible ?? false }
        MailWindowCoordinator.shared.hideCapture = { [weak self] in self?.overlay.hide() }
        // 작업 창 안의 AI·웹 번역 화면을 보여 주는 동안만 캡처 영역을 취소 없이 내렸다가(진행 중 화면 번역 유지) 끝나면 되돌린다.
        MailWindowCoordinator.shared.concealCapture = { [weak self] in self?.overlay.hide(notifyOnHide: false) }
        MailWindowCoordinator.shared.resumeCapture = { [weak self] in self?.overlay.show(activate: true) }
        // 사용자가 다른 곳으로 이동하거나 창을 닫아 임시 숨김 중이던 캡처를 포기할 때: 숨김 규칙대로 진행 중 화면 번역만 취소한다.
        MailWindowCoordinator.shared.cancelCaptureWork = { [weak self] in self?.viewModel.windowWillHide() }

        buildStatusItem()
        // 서버 현황(CCMB) 모듈 초기화 및 활성화 시 시작 (한툴 버튼 좌측에 밀착 생성)
        CCMBIntegration.shared.setup(updater: updater, loginItem: loginItem)
        CCMBIntegration.shared.startIfEnabled()
        buildNetworkRateStatusItem()

        let hotKey = GlobalHotKey { [weak self] in self?.showOverlay() }
        hotKey.register()
        self.hotKey = hotKey
        if !hotKey.isRegistered {
            viewModel.status = .error(hotKey.statusDescription)
        }

        // 선택한 메일 번역 전역 단축키(⌃⌥⇧⌘M). 화면 번역 단축키와 독립적으로 등록·실패 처리한다.
        // 이 앱을 앞으로 가져오기 전에 Mail의 선택 메시지를 먼저 읽는다(AppModel.translateSelectedMail).
        let mailHotKey = GlobalHotKey(keyCode: UInt32(kVK_ANSI_M), id: GlobalHotKey.mailHotKeyID,
                                      display: GlobalHotKey.mailDisplayString) {
            AppModel.shared.translateSelectedMail()
        }
        mailHotKey.register()
        self.mailHotKey = mailHotKey

        // 브라우저 열기 전역 단축키(⇧⌃⌥⌘B). 다른 앱에서도 HTT 브라우저를 열거나 이미 열려 있으면 앞으로 가져온다.
        // 다른 앱과 키가 겹치면 등록되지 않으며, 그 사실을 상태 메뉴와 경고에 표시한다(다른 앱 설정은 바꾸지 않는다).
        let browserHotKey = GlobalHotKey(keyCode: UInt32(kVK_ANSI_B), id: GlobalHotKey.browserHotKeyID,
                                         display: GlobalHotKey.browserDisplayString) { [weak self] in
            self?.showDockIconForBrowser()
            EmbeddedBrowser.open()
        }
        browserHotKey.register()
        self.browserHotKey = browserHotKey
        if !browserHotKey.isRegistered, case .idle = viewModel.status {
            viewModel.status = .error(browserHotKey.statusDescription)
        }

        // 보조키 더블탭(Command 2회 또는 Shift 2회) 브라우저 호출 감시 시작
        BrowserDoubleTapShortcut.shared.start()
        // 클립보드 히스토리 및 단축키(Shift 유지 + Command 2회 탭) 감시 시작
        ClipboardHistoryStore.shared.start()
        ClipboardHistoryShortcut.shared.start()

        // 메일 번역: Mail › 서비스 메뉴, Mail 위 번역 버튼(기본 켜짐)
        MailWindowCoordinator.shared.start()

        // InputMate 수명주기 시작 (이전은 Coordinator에서 관리)
        InputMateCoordinator.shared.start()
        // Mac 관리(BTN) 활성화 시 수명주기 시작
        BTNIntegration.shared.startIfEnabled()

        DockVisibilityStore.shared.applyInitial()
        loginItem.applyInitialDefaultIfNeeded()
        loginItem.refreshMenuStatus()
        WakeLaunchManager().applyInitialDefaultIfNeeded()
        updater.start()
        // 브라우저 번역 엔진 연결(허용했거나 브라우저 도우미가 실행한 경우에만 연다)
        BrowserIntegration.shared.applicationDidLaunch()
        writeDiagnostics()

        // 콜드 유저 론칭(Dock/Finder/수동 실행): 브라우저 메인 창을 열고 Dock 아이콘을 표시한다.
        // 로그인 항목·잠자기 헬퍼·브라우저 도우미 백그라운드 시작 시에는 메뉴 막대 전용으로 유지한다.
        if !isBackgroundOrLoginLaunch(notification: notification) {
            showDockIconForBrowser()
            MailWindowCoordinator.shared.openBrowserMain()
        }
    }

    /// 업데이트 설치가 예약된 상태에서 HTT 안의 브라우저 다운로드나 작업이 진행 중이면 종료를 멈춘다.
    /// Sparkle은 앱이 종료되는 순간(applicationWillTerminate 이후) 설치를 시작하므로, 그 전인 이 단계에서만 막을 수 있다.
    /// 진행 중인 작업은 자동으로 종료하지 않으며, 작업이 끝나면 정상 종료·설치된다.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let explicit = explicitAppTerminationRequested
        explicitAppTerminationRequested = false
        if isSystemTerminationRequest() { return .terminateNow }
        guard explicit else {
            closeBrowserWindows()
            return .terminateCancel
        }
        guard updater.hasPendingInstall, EmbeddedBrowser.isEmbeddedRunning() else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "한툴 브라우저 작업을 먼저 완료해 주세요"
        alert.informativeText = "업데이트 설치가 예약되어 있어, 한툴을 종료하면 실행 중인 브라우저 다운로드나 작업이 중단될 수 있습니다. 진행 중인 작업이 끝나면 한툴을 다시 종료해 주세요. 브라우저는 자동으로 종료하지 않습니다."
        alert.addButton(withTitle: "확인")
        alert.runModal()
        return .terminateCancel
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let target = duplicateLaunchTarget {
            target.activate(options: [])
            finishDuplicateLaunch()
            return false
        }
        let mouseLoc = NSEvent.mouseLocation
        let screenMaxY = NSScreen.main?.visibleFrame.maxY ?? 0
        let inMenuBar = mouseLoc.y >= screenMaxY

        // 메뉴바 버튼을 클릭 중이거나 메뉴가 열려 있는 중에는 브라우저를 앞으로 띄워 메뉴를 닫지 않는다.
        if isStatusMenuOpen || statusItem?.button?.isHighlighted == true || networkRateStatusItem?.button?.isHighlighted == true {
            return false
        }
        if inMenuBar {
            return false
        }
        if let event = NSApp.currentEvent, (event.type == .leftMouseDown || event.type == .leftMouseUp) {
            if let window = event.window, window.className.contains("StatusBar") {
                return false
            }
        }
        showDockIconForBrowser()
        MailWindowCoordinator.shared.openBrowserMain()
        return true
    }

    /// .eml·이미지·HTML 파일 열기(Finder '다음으로 열기', Dock 아이콘으로 끌어놓기)
    func application(_ application: NSApplication, open urls: [URL]) {
        if duplicateLaunchTarget != nil {
            forwardDuplicateURLs(urls)
            return
        }
        // http/https 주소 및 .html/.htm 파일은 브라우저로 넘기고, 번역 문서(메일/이미지)는 기존 동작을 그대로 유지한다.
        let browserURLs = EmbeddedBrowser.forwardableURLs(urls)
        if !browserURLs.isEmpty {
            showDockIconForBrowser()
            EmbeddedBrowser.open(urls: browserURLs)
        }
        guard let url = urls.first(where: { $0.isFileURL && EmbeddedBrowser.forwardableHTMLFileURL($0) == nil }) else { return }
        AppModel.shared.open(url: url)
        AppModel.shared.showMainWindow()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if duplicateLaunchTarget != nil {
            duplicateLaunchExit?.cancel()
            return
        }
        BrowserDoubleTapShortcut.shared.stop()
        ClipboardHistoryShortcut.shared.stop()
        ClipboardHistoryStore.shared.stop()
        MailWindowCoordinator.shared.prepareForTermination()
        InputMateCoordinator.shared.stop()
        BTNIntegration.shared.stop()
        CCMBIntegration.shared.stop()
        BrowserIntegration.shared.applicationWillTerminate()
        UnifiedBrowserManager.shared.shutdown()
        viewModel.stop()
        AppModel.shared.closeDocument()
        hotKey?.unregister()
        mailHotKey?.unregister()
        browserHotKey?.unregister()
        overlay.stopMonitoring()
        overlay.hide()
    }

    // MARK: - 아이콘

    /// Info.plist의 CFBundleIconFile(AppIcon.icns)과 같은 리소스를 Dock 아이콘에도 명시적으로 적용한다.
    private func applyBundleIcon() {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let image = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = image
        }
    }

    /// 앱 아이콘을 메뉴 막대 크기(18pt)로 축소한 이미지. 여백이 큰 전체 아이콘을 그대로 쓰면 다른
    /// 메뉴 막대 아이콘보다 작아 보이므로, 아이콘의 둥근 사각형 부분만 중앙 크롭해 꽉 채운다.
    private func menuBarIconImage() -> NSImage? {
        guard let icon = NSApp.applicationIconImage else { return nil }
        let size = NSSize(width: 18, height: 18)
        let cropInset: CGFloat = icon.size.width * 0.085 // AppIcon-source.png 실측 여백 비율과 동일
        let sourceRect = NSRect(x: cropInset, y: cropInset,
                                 width: icon.size.width - cropInset * 2,
                                 height: icon.size.height - cropInset * 2)
        let image = NSImage(size: size)
        image.lockFocus()
        icon.draw(in: NSRect(origin: .zero, size: size), from: sourceRect, operation: .sourceOver, fraction: 1)
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    // MARK: - 창 표시/숨김

    /// 화면 번역 캡처 모드 시작: 보이는 HTT 작업 창은 숨기고(닫지 않음) 캡처 영역만 띄운다.
    @objc func showOverlay() {
        MailWindowCoordinator.shared.willBeginCaptureMode()
        overlay.show(activate: true)
    }

    @objc func toggleOverlay() {
        if overlay.isVisible {
            overlay.hide()
        } else {
            showOverlay()
        }
    }

    @objc func hideOverlay() {
        overlay.hide()
    }

    @objc private func performPrimaryAction() {
        if !overlay.isVisible { showOverlay() }
        viewModel.performPrimaryAction()
    }

    // MARK: - 메뉴 막대 상태 항목

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            // 메뉴 막대 아이콘은 SF Symbol 대신 기존 디자인된 앱 아이콘을 그대로 축소해 쓴다(원본 색 유지).
            button.image = menuBarIconImage()
            button.imagePosition = .imageOnly
            button.toolTip = "한툴 (화면 \(GlobalHotKey.displayString) · 메일 \(GlobalHotKey.mailDisplayString) · 브라우저 \(GlobalHotKey.browserDisplayString))"
        }
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        mainStatusMenu = menu
        statusItem = item
    }

    private func buildNetworkRateStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: 68)
        if let button = item.button {
            button.imagePosition = .noImage
            button.title = ""
            let hosting = PassthroughHostingView(rootView: MenuBarNetworkRateView())
            hosting.frame = NSRect(x: 0, y: 0, width: 68, height: 22)
            hosting.autoresizingMask = [.width, .height]
            button.addSubview(hosting)
            button.toolTip = "네트워크 전송률 (Mac 이더넷/Wi-Fi 전체 합산, VPN 제외)"
            button.target = self
            button.action = #selector(handleNetworkRateClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        let rateMenu = NSMenu()
        rateMenu.delegate = self
        rateMenu.autoenablesItems = false
        networkRateMenu = rateMenu
        networkRateStatusItem = item

        NetworkRateMonitor.shared.start()
        setupNetworkRateObservation()
        updateNetworkRateVisibility(location: NetworkRateDisplayStore.shared.location)
    }

    @objc private func handleNetworkRateClick(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || (event?.modifierFlags.contains(.control) == true) {
            if let menu = networkRateMenu {
                sender.isHighlighted = true
                networkRateStatusItem?.popUpMenu(menu)
                sender.isHighlighted = false
            }
        } else {
            openSpeedTest()
        }
    }

    @objc private func openSpeedTest() {
        showDockIconForBrowser()
        MailWindowCoordinator.shared.openBrowserMain()
        let nav = UnifiedNavigationModel.shared
        nav.openSpeedTest(
            appModel: HTDHostExport.shared.appModel,
            clearTool: HTDHostExport.shared.clearHostedTool
        )
    }

    private func setupNetworkRateObservation() {
        NetworkRateDisplayStore.shared.$location
            .receive(on: DispatchQueue.main)
            .sink { [weak self] location in
                self?.updateNetworkRateVisibility(location: location)
            }
            .store(in: &networkRateCancellables)
    }

    private func updateNetworkRateVisibility(location: NetworkRateDisplayLocation) {
        guard let item = networkRateStatusItem else { return }
        switch location {
        case .menuBar:
            item.length = 68
            item.isVisible = true
        case .appTop:
            item.length = 0
            item.isVisible = false
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        if menu === mainStatusMenu || menu === networkRateMenu {
            isStatusMenuOpen = true
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        if menu === mainStatusMenu || menu === networkRateMenu {
            isStatusMenuOpen = false
        }
    }

    /// 메뉴를 열 때마다 현재 상태(창 표시, 주 버튼, 로그인 항목, 업데이트)로 다시 만든다.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === mainStatusMenu || menu === networkRateMenu else { return }
        loginItem.refreshMenuStatus()
        menu.removeAllItems()

        menu.addItem(headerItem())
        menu.addItem(item("한툴 열기", #selector(showHome), symbol: "globe"))
        menu.addItem(item("앱 상태 개요", #selector(showOverview), symbol: "house"))
        menu.addItem(.separator())

        // MARK: 번역
        let overlayVisible = overlay.isVisible
        let screenItem = item(overlayVisible ? "화면 번역 캡처 끝내기" : "화면 번역 캡처 시작", #selector(toggleOverlay),
                               symbol: "text.viewfinder")
        // 전역 단축키는 항상 '보이기'만 수행하므로, 숨기기로 바뀌는 상태에서는 단축키 표기를 붙이지 않는다.
        if !overlayVisible {
            applyKeyEquivalent(screenItem, GlobalHotKey.screenKeyEquivalent, GlobalHotKey.screenModifierMask)
        }
        menu.addItem(screenItem)

        let primary: NSMenuItem
        if viewModel.isExternalRunning {
            primary = item("외부 AI 번역 취소", #selector(cancelExternalTranslation), symbol: "xmark.circle")
            primary.isEnabled = true
        } else if viewModel.isProcessing {
            primary = item("선택 영역 번역 중…", nil, symbol: "camera.viewfinder")
            primary.isEnabled = false
        } else {
            let title = (viewModel.primaryAction == .showOriginal) ? "원문보기" : "선택 영역 번역"
            primary = item(title, #selector(performPrimaryAction), symbol: viewModel.primaryAction.systemImage)
            primary.isEnabled = true
        }
        menu.addItem(primary)

        if viewModel.status != .idle {
            menu.addItem(info(viewModel.status.koreanText))
        }

        let mailItem = item("Mail에서 선택한 메일 번역", #selector(translateSelectedMail), symbol: "envelope")
        applyKeyEquivalent(mailItem, GlobalHotKey.mailKeyEquivalent, GlobalHotKey.mailModifierMask)
        menu.addItem(mailItem)

        let browserItem = item("브라우저 열기", #selector(openEmbeddedBrowser), symbol: "safari")
        applyKeyEquivalent(browserItem, GlobalHotKey.browserKeyEquivalent, GlobalHotKey.browserModifierMask)
        menu.addItem(browserItem)
        menu.addItem(item("기본 브라우저로 설정…", #selector(setAsDefaultBrowser), symbol: "globe"))

        menu.addItem(.separator())

        // MARK: 입력 도우미
        menu.addItem(item("입력 도우미 설정", #selector(showInputSettings), symbol: "keyboard"))

        menu.addItem(.separator())

        // MARK: Mac 관리
        menu.addItem(item("Mac 관리", #selector(showMacManagement), symbol: "desktopcomputer"))
        menu.addItem(item("USB 정리·추출", #selector(showCleanUSB), symbol: "externaldrive"))
        let clipboardItem = item("클립보드", #selector(showClipboardHistory), symbol: "doc.on.clipboard")
        // 독립 전역 제스처이므로 keyEquivalent가 아닌 표시용 주석으로만 덧붙인다.
        let tabStyle = NSMutableParagraphStyle()
        tabStyle.tabStops = [NSTextTab(textAlignment: .right, location: 200)]
        let label = NSMutableAttributedString(string: "클립보드\t", attributes: [.font: NSFont.menuFont(ofSize: 0), .paragraphStyle: tabStyle])
        label.append(NSAttributedString(string: "⇧ + ⌘ 두 번", attributes: [.font: NSFont.menuFont(ofSize: 0), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: tabStyle]))
        clipboardItem.attributedTitle = label
        menu.addItem(clipboardItem)

        menu.addItem(.separator())

        // MARK: 설정 / 업데이트 / 종료
        let settingsItem = item("현재 메뉴 설정…", #selector(showSettings), symbol: "gearshape")
        applyKeyEquivalent(settingsItem, ",", .command)
        menu.addItem(settingsItem)
        let diagnostics = item("권한·연결 상태", nil, symbol: "info.circle")
        diagnostics.submenu = statusMenu()
        menu.addItem(diagnostics)

        if let warning = actionNeededWarningItem() {
            menu.addItem(warning)
        }
        menu.addItem(item("업데이트 확인…", #selector(checkForUpdates), symbol: "arrow.down.circle"))
        menu.addItem(item("한툴 종료", #selector(terminateHanTool(_:)), symbol: "power"))
    }

    /// 앱 아이콘·이름·버전을 보여주는 비활성 머리글 행
    private func headerItem() -> NSMenuItem {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let title = version.isEmpty ? "한툴" : "한툴 v\(version)"
        let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        header.isEnabled = false
        if let icon = NSApp.applicationIconImage {
            let resized = NSImage(size: NSSize(width: 18, height: 18))
            resized.lockFocus()
            icon.draw(in: NSRect(x: 0, y: 0, width: 18, height: 18))
            resized.unlockFocus()
            header.image = resized
            if #available(macOS 27.0, *) {
                header.preferredImageVisibility = .visible
            }
        }
        return header
    }

    /// 실패·조치 필요 상태만 눈에 띄게 올린다(정상일 때는 표시하지 않는다).
    private func actionNeededWarningItem() -> NSMenuItem? {
        let hotKeyFailed = hotKey?.isRegistered == false || mailHotKey?.isRegistered == false || browserHotKey?.isRegistered == false
        let loginNeedsApproval = loginItem.menuStatus == .requiresApproval
        let inputNeedsAccessibility = InputMateCoordinator.shared.settings.preferences.isEnabled &&
            InputMateCoordinator.shared.appState.serviceStatus == .needsAccessibility
        guard hotKeyFailed || loginNeedsApproval || inputNeedsAccessibility else { return nil }

        if inputNeedsAccessibility {
            let warning = item("입력 도우미 손쉬운 사용 권한 필요", #selector(openAccessibilitySettings), symbol: "exclamationmark.triangle")
            warning.isEnabled = true
            return warning
        }

        let text = hotKeyFailed ? "단축키 등록 실패 — 앱 상태 확인" : "로그인 항목 승인 필요"
        let warning = item(text, hotKeyFailed ? nil : #selector(openLoginItemsSettings), symbol: "exclamationmark.triangle")
        warning.isEnabled = !hotKeyFailed
        return warning
    }

    /// 단축키 등록, 로그인 항목, 업데이트의 세부 진단 텍스트(평상시 숨겨둠)
    private func statusMenu() -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        submenu.addItem(info("화면 번역 단축키: \(hotKey?.statusDescription ?? "없음")"))
        submenu.addItem(info("메일 번역 단축키: \(mailHotKey?.statusDescription ?? "없음")"))
        submenu.addItem(info("브라우저 열기 단축키: \(browserHotKey?.statusDescription ?? "없음")"))
        submenu.addItem(.separator())
        submenu.addItem(info("로그인 항목: \(loginItem.lastError ?? loginItem.menuStatusDescription)"))
        if loginItem.menuStatus == .requiresApproval {
            submenu.addItem(item("로그인 항목 설정 열기…", #selector(openLoginItemsSettings), symbol: nil))
        }
        submenu.addItem(.separator())
        submenu.addItem(info("입력 도우미: \(InputMateCoordinator.shared.appState.statusText)"))
        if case .needsAccessibility = InputMateCoordinator.shared.appState.serviceStatus {
            submenu.addItem(item("손쉬운 사용 권한 설정 열기…", #selector(openAccessibilitySettings), symbol: nil))
        }
        submenu.addItem(.separator())
        submenu.addItem(info("Mac 관리: \(BTNIntegration.shared.statusSummary)"))
        submenu.addItem(.separator())
        submenu.addItem(info("업데이트: \(updater.lastCheckResult ?? updater.statusDescription)"))
        let auto = item("자동 업데이트", #selector(toggleAutomaticUpdates), symbol: nil)
        auto.isEnabled = updater.isAvailable
        auto.state = updater.automaticallyUpdates ? .on : .off
        submenu.addItem(auto)
        return submenu
    }

    private func item(_ title: String, _ action: Selector?, target: AnyObject? = nil, symbol: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = action == nil ? nil : (target ?? self)
        item.isEnabled = true
        if let symbol {
            item.image = symbolImage(symbol)
            if #available(macOS 27.0, *) {
                item.preferredImageVisibility = .visible
            }
        }
        return item
    }

    private func info(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func symbolImage(_ name: String) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        image?.isTemplate = true
        return image
    }

    /// 전역 단축키(⌃⌥⇧⌘)와 같은 글자·보조키를 메뉴에도 그대로 보여준다(실제 단축키 의미를 바꾸지 않음).
    private func applyKeyEquivalent(_ item: NSMenuItem, _ key: String, _ mask: NSEvent.ModifierFlags) {
        item.keyEquivalent = key
        item.keyEquivalentModifierMask = mask
    }

    @objc private func translateSelectedMail() {
        AppModel.shared.translateSelectedMail()
    }

    @objc private func showMailWindow() {
        AppModel.shared.showMainWindow()
    }

    @objc private func openMailFile() {
        AppModel.shared.showMainWindow()
        AppModel.shared.showImporter = true
    }

    @objc private func clearMailDocument() {
        AppModel.shared.closeDocument()
    }

    @objc private func toggleMailToolbarButton() {
        if MailToolbarButton.shared.isEnabled {
            MailToolbarButton.shared.disable()
        } else {
            MailToolbarButton.shared.enable()
        }
    }

    // 아래 메뉴 동작은 모두 HTT 메인 창(하나뿐인 일반 창)의 해당 섹션을 연다. 별도 창을 만들지 않는다.

    private func isBackgroundOrLoginLaunch(notification: Notification) -> Bool {
        if BrowserIntegration.shared.launchedByBrowser {
            return true
        }
        let args = CommandLine.arguments
        if args.contains("-login") || args.contains("--login") ||
           args.contains("-background") || args.contains("--background") {
            return true
        }
        if let isDefault = (notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool) ??
                           ((notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? NSNumber)?.boolValue) {
            if !isDefault {
                return true
            }
        }
        if let event = NSAppleEventManager.shared().currentAppleEvent {
            let lginKeyword = AEKeyword(0x6c67696e)
            if event.attributeDescriptor(forKeyword: lginKeyword) != nil ||
               event.paramDescriptor(forKeyword: lginKeyword) != nil {
                return true
            }
        }
        return false
    }

    private func showDockIconForBrowser() {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        applyBundleIcon()
    }

    @objc private func showHome() {
        showDockIconForBrowser()
        MailWindowCoordinator.shared.openBrowserMain()
    }

    @objc private func showOverview() {
        MailWindowCoordinator.shared.showWorkbench(section: .home)
    }

    @objc private func showGuide() {
        MailWindowCoordinator.shared.showWorkbench(section: .help)
    }

    @objc private func showSettings() {
        MailWindowCoordinator.shared.presentWorkbenchPreservingSelection()
        let nav = UnifiedNavigationModel.shared
        nav.openCurrentContextSettings(
            appModel: HTDHostExport.shared.appModel,
            currentToolID: HTDHostExport.shared.hostedToolID,
            selectTool: HTDHostExport.shared.selectToolFromSidebar,
            clearTool: HTDHostExport.shared.clearHostedTool
        )
    }

    @objc private func toggleDockIcon(_ sender: NSMenuItem? = nil) {
        DockVisibilityStore.shared.showDockIcon.toggle()
        sender?.state = DockVisibilityStore.shared.showDockIcon ? .on : .off
    }

    @objc private func selectIconStyle(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let style = HTTIconStyle(rawValue: rawValue) else { return }
        HTTAppearanceStore.shared.iconStyle = style
        if let parentMenu = sender.menu {
            for item in parentMenu.items {
                if let itemRaw = item.representedObject as? String {
                    item.state = (itemRaw == rawValue) ? .on : .off
                }
            }
        }
    }

    @objc private func openEmbeddedBrowser() {
        showDockIconForBrowser()
        EmbeddedBrowser.open()
    }

    @objc private func showBrowserSetup() {
        MailWindowCoordinator.shared.presentWorkbenchPreservingSelection()
        UnifiedNavigationModel.shared.openFeatureSettings(
            for: .browser,
            appModel: HTDHostExport.shared.appModel,
            currentToolID: HTDHostExport.shared.hostedToolID,
            selectTool: HTDHostExport.shared.selectToolFromSidebar,
            clearTool: HTDHostExport.shared.clearHostedTool
        )
    }

    @objc private func showInputSettings() {
        MailWindowCoordinator.shared.presentWorkbenchPreservingSelection()
        UnifiedNavigationModel.shared.openFeatureSettings(
            for: .inputHelper,
            appModel: HTDHostExport.shared.appModel,
            currentToolID: HTDHostExport.shared.hostedToolID,
            selectTool: HTDHostExport.shared.selectToolFromSidebar,
            clearTool: HTDHostExport.shared.clearHostedTool
        )
    }

    @objc private func showMacManagement() {
        MailWindowCoordinator.shared.openBrowserMain()
        UnifiedNavigationModel.shared.selectDestination(
            .macManagement,
            appModel: HTDHostExport.shared.appModel,
            selectTool: HTDHostExport.shared.selectToolFromSidebar,
            clearTool: HTDHostExport.shared.clearHostedTool
        )
    }

    @objc private func showMacManagementSettings() {
        MailWindowCoordinator.shared.presentWorkbenchPreservingSelection()
        UnifiedNavigationModel.shared.openFeatureSettings(
            for: .macManagement,
            appModel: HTDHostExport.shared.appModel,
            currentToolID: HTDHostExport.shared.hostedToolID,
            selectTool: HTDHostExport.shared.selectToolFromSidebar,
            clearTool: HTDHostExport.shared.clearHostedTool
        )
    }

    @objc private func showCleanUSB() {
        MailWindowCoordinator.shared.openBrowserMain()
        UnifiedNavigationModel.shared.selectDestination(
            .usbDrives,
            appModel: HTDHostExport.shared.appModel,
            selectTool: HTDHostExport.shared.selectToolFromSidebar,
            clearTool: HTDHostExport.shared.clearHostedTool
        )
    }

    @objc func showClipboardHistory() {
        // 상태 메뉴 클릭은 앱을 활성화하지 않으므로 패널 활성화 전에 원래 앱·창·입력위치를 캡처 (메뉴 열림 시점에는 AX 질의 없음)
        ClipboardPasteCoordinator.shared.captureOriginTarget()
        ClipboardHistoryPanelController.shared.toggle()
    }

    @objc private func toggleInputMateEnabled() {
        InputMateCoordinator.shared.toggleEnabled()
    }

    @objc private func openAccessibilitySettings() {
        InputMateCoordinator.shared.appState.requestAccessibilityAndRetry()
    }

    @objc private func cancelExternalTranslation() {
        viewModel.cancelExternalTranslation()
    }

    /// ⌘W: HTT 메인 창(하나뿐인 일반 창)이 앞에 있으면 그 창을 닫고(메인 창을 닫으면 메일 내용도 지운다), 아니면 화면 번역 캡처를 끝낸다.
    @objc private func closeFrontWindow() {
        if let key = NSApp.keyWindow, key !== overlay.panel, key.styleMask.contains(.closable) {
            key.performClose(nil)
        } else {
            overlay.hide()
        }
    }

    /// Cmd+Q is a browser-window command, even when no browser window is open.
    @objc private func handleAppQuit(_ sender: Any?) {
        closeBrowserWindows()
    }

    private func closeBrowserWindows() {
        for window in NSApp.windows where MailWindowCoordinator.shared.isWorkbenchWindow(window) {
            if window.isVisible {
                window.performClose(nil)
            }
        }
        UnifiedBrowserManager.shared.terminateBrowserExecution()
    }

    /// Only the explicit status-menu action requests a full application quit.
    @objc private func terminateHanTool(_ sender: Any?) {
        explicitAppTerminationRequested = true
        NSApp.terminate(sender)
    }

    private func isSystemTerminationRequest() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == AEEventID(kAEQuitApplication),
              let reason = event.paramDescriptor(forKeyword: AEKeyword(kAEQuitReason))?.enumCodeValue else {
            return false
        }
        return [OSType(kAEQuitAll), OSType(kAELogOut), OSType(kAEReallyLogOut),
                OSType(kAEShutDown), OSType(kAERestart)].contains(reason)
    }

    @objc private func setAsDefaultBrowser() {
        requestDefaultBrowser(schemes: ["https", "http"])
    }

    private func requestDefaultBrowser(schemes: [String]) {
        guard let scheme = schemes.first else { return }
        NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL,
                                                 toOpenURLsWithScheme: scheme) { [weak self] error in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let error {
                    if (error as NSError).code == NSUserCancelledError { return }
                    let alert = NSAlert()
                    alert.messageText = "기본 브라우저 설정을 완료하지 못했습니다"
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                    return
                }
                self.requestDefaultBrowser(schemes: Array(schemes.dropFirst()))
            }
        }
    }

    @objc private func openLoginItemsSettings() {
        loginItem.openSystemSettings()
    }

    @objc func checkForUpdates() {
        updater.checkForUpdates()
    }

    @objc private func toggleAutomaticUpdates() {
        updater.setAutomaticallyUpdates(!updater.automaticallyUpdates)
    }

    /// HTT 정보: 표준 정보 패널로 version 기능을 표시한다.
    @objc private func showAbout() {
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    // MARK: - 앱 메뉴

    private func buildMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(item("한툴 열기", #selector(showHome), symbol: "globe"))
        appMenu.addItem(item("앱 상태 개요", #selector(showOverview), symbol: "house"))
        appMenu.addItem(item("한툴 정보", #selector(showAbout)))
        appMenu.addItem(item("업데이트 확인…", #selector(checkForUpdates)))
        appMenu.addItem(.separator())
        appMenu.addItem(item("USB 정리·추출", #selector(showCleanUSB)))
        appMenu.addItem(item("클립보드", #selector(showClipboardHistory)))
        appMenu.addItem(item("Mac 상태·정리 항목", #selector(showMacManagement)))
        let settings = NSMenuItem(title: "현재 메뉴 설정…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        let dockItem = NSMenuItem(title: "Dock 아이콘 표시", action: #selector(toggleDockIcon(_:)), keyEquivalent: "")
        dockItem.target = self
        dockItem.state = DockVisibilityStore.shared.showDockIcon ? .on : .off
        appMenu.addItem(dockItem)

        let iconStyleMenu = NSMenu()
        let currentIconStyle = HTTAppearanceStore.shared.iconStyle
        for style in HTTIconStyle.allCases {
            let styleItem = NSMenuItem(title: style.displayName, action: #selector(selectIconStyle(_:)), keyEquivalent: "")
            styleItem.target = self
            styleItem.representedObject = style.rawValue
            styleItem.state = (style == currentIconStyle) ? .on : .off
            iconStyleMenu.addItem(styleItem)
        }
        let iconStyleItem = NSMenuItem(title: "아이콘 스타일", action: nil, keyEquivalent: "")
        iconStyleItem.submenu = iconStyleMenu
        appMenu.addItem(iconStyleItem)
        let browserSettings = NSMenuItem(title: "브라우저 번역", action: #selector(showBrowserSetup), keyEquivalent: "")
        browserSettings.target = self
        appMenu.addItem(browserSettings)
        let inputSettings = NSMenuItem(title: "입력 도우미 설정", action: #selector(showInputSettings), keyEquivalent: "")
        inputSettings.target = self
        appMenu.addItem(inputSettings)
        let macSettings = NSMenuItem(title: "Mac 관리 설정", action: #selector(showMacManagementSettings), keyEquivalent: "")
        macSettings.target = self
        appMenu.addItem(macSettings)
        let guide = NSMenuItem(title: "사용 방법", action: #selector(showGuide), keyEquivalent: "")
        guide.target = self
        appMenu.addItem(guide)
        appMenu.addItem(.separator())
        let quitItem = NSMenuItem(title: "브라우저 창 닫기", action: #selector(handleAppQuit(_:)), keyEquivalent: "q")
        quitItem.target = self
        appMenu.addItem(quitItem)
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // 메일 번역(원래 메일 번역기의 파일 메뉴 항목)
        let mailMenuItem = NSMenuItem()
        let mailMenu = NSMenu(title: "메일")
        let translateMail = NSMenuItem(title: "Mail에서 선택한 메일 번역", action: #selector(translateSelectedMail), keyEquivalent: "t")
        translateMail.keyEquivalentModifierMask = [.command, .shift]
        translateMail.target = self
        mailMenu.addItem(translateMail)
        let openFile = NSMenuItem(title: "파일 열기…", action: #selector(openMailFile), keyEquivalent: "o")
        openFile.target = self
        mailMenu.addItem(openFile)
        mailMenu.addItem(item("메일·이미지 번역 열기", #selector(showMailWindow)))
        mailMenu.addItem(.separator())
        mailMenu.addItem(item("Mail 위 번역 버튼 켜기/끄기", #selector(toggleMailToolbarButton)))
        mailMenu.addItem(.separator())
        let clear = NSMenuItem(title: "현재 내용 지우기", action: #selector(clearMailDocument), keyEquivalent: String(UnicodeScalar(NSBackspaceCharacter)!))
        clear.keyEquivalentModifierMask = [.command]
        clear.target = self
        mailMenu.addItem(clear)
        mailMenuItem.submenu = mailMenu
        mainMenu.addItem(mailMenuItem)

        // 편집: 메일 결과의 텍스트 선택·복사, 외부 AI 로그인 창 입력, 수동 응답 붙여넣기에 필요하다.
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "편집")
        editMenu.addItem(NSMenuItem(title: "실행 취소", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "실행 복귀", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "오려두기", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "복사하기", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "붙여넣기", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "전체 선택", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "윈도우")
        let show = NSMenuItem(title: "화면 번역 캡처 시작", action: #selector(showOverlay), keyEquivalent: "0")
        show.target = self
        windowMenu.addItem(show)
        let hide = NSMenuItem(title: "화면 번역 캡처 끝내기", action: #selector(hideOverlay), keyEquivalent: "")
        hide.target = self
        windowMenu.addItem(hide)
        let close = NSMenuItem(title: "창 닫기", action: #selector(closeFrontWindow), keyEquivalent: "w")
        close.target = self
        windowMenu.addItem(close)
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        let helpMenuItem = NSMenuItem()
        let helpMenu = NSMenu(title: "도움말")
        helpMenu.addItem(item("사용 방법…", #selector(showGuide)))
        helpMenu.addItem(item("한툴 정보", #selector(showAbout)))
        helpMenuItem.submenu = helpMenu
        mainMenu.addItem(helpMenuItem)

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
        NSApp.helpMenu = helpMenu
    }

    // MARK: - 진단 로그 (비밀 정보 없음)

    /// 설치 경로, 버전, 로그인 항목/단축키/업데이터/번역 방식 이름만 기록한다. 화면·메일 내용과 텍스트는 기록하지 않는다.
    private func writeDiagnostics() {
        let info = Bundle.main.infoDictionary ?? [:]
        let lines = [
            "time=\(ISO8601DateFormatter().string(from: Date()))",
            "version=\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))",
            "bundleIdentifier=\(Bundle.main.bundleIdentifier ?? "?")",
            "bundlePath=\(Bundle.main.bundlePath)",
            "executable=\(Bundle.main.executablePath ?? "?")",
            "loginItemStatus=\(loginItem.status.rawValue) \(loginItem.statusDescription)",
            "loginItemPreference=\(loginItem.preference.map { String($0) } ?? "unset")",
            "loginItemError=\(loginItem.lastError ?? "none")",
            "hotKey=\(hotKey?.statusDescription ?? "none")",
            "mailHotKey=\(mailHotKey?.statusDescription ?? "none")",
            "browserHotKey=\(browserHotKey?.statusDescription ?? "none")",
            "mailToolbarButton=\(MailToolbarButton.shared.isEnabled)",
            "translationBackend=\(TranslationBackendStore.shared.backend.rawValue)",
            "browserBridgeEnabled=\(BrowserIntegration.shared.isEnabled) launchedByBrowser=\(BrowserIntegration.shared.launchedByBrowser)",
            "updater=\(updater.statusDescription)",
            "feedURL=\(info["SUFeedURL"] as? String ?? "none")",
            "publicKeyPresent=\(!((info["SUPublicEDKey"] as? String) ?? "").isEmpty)"
        ]
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/ScreenTranslator", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? (lines.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("diagnostics.log"), atomically: true, encoding: .utf8)
    }
}

extension AppDelegate: NSMenuItemValidation {
    /// '현재 내용 지우기'(⌘⌫)는 메인 창의 메일·이미지 번역 섹션이 앞에 있을 때만 동작한다(다른 섹션의 입력 중 실수로 지우지 않게).
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(clearMailDocument) {
            return NSApp.keyWindow.map { MailWindowCoordinator.shared.isMailWindow($0) } ?? false
        }
        return true
    }
}
