import AppKit
import Carbon.HIToolbox
import Combine
import HTTHTDCore
import ServiceManagement
import SwiftUI

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
    private var networkRateCancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
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
                                         display: GlobalHotKey.browserDisplayString) {
            EmbeddedBrowser.open()
        }
        browserHotKey.register()
        self.browserHotKey = browserHotKey
        if !browserHotKey.isRegistered, case .idle = viewModel.status {
            viewModel.status = .error(browserHotKey.statusDescription)
        }

        // 보조키 더블탭(Command 2회 또는 Shift 2회) 브라우저 호출 감시 시작
        BrowserDoubleTapShortcut.shared.start()

        // 메일 번역: Mail › 서비스 메뉴, Mail 위 번역 버튼(기본 켜짐)
        MailWindowCoordinator.shared.start()

        // InputMate 수명주기 시작 (이전은 Coordinator에서 관리)
        InputMateCoordinator.shared.start()
        // Mac 관리(BTN) 활성화 시 수명주기 시작
        BTNIntegration.shared.startIfEnabled()

        DockVisibilityStore.shared.applyInitial()
        loginItem.applyInitialDefaultIfNeeded()
        WakeLaunchManager().applyInitialDefaultIfNeeded()
        updater.start()
        // 서버 현황(CCMB) 모듈 초기화 및 활성화 시 시작
        CCMBIntegration.shared.setup(updater: updater, loginItem: loginItem)
        CCMBIntegration.shared.startIfEnabled()
        // 브라우저 번역 엔진 연결(허용했거나 브라우저 도우미가 실행한 경우에만 연다)
        BrowserIntegration.shared.applicationDidLaunch()
        writeDiagnostics()

        // 모든 실행 경로(콜드/수동/로그인/브라우저)에서 화면 번역 창은 자동으로 띄우지 않는다.
        // 메뉴·단축키에서만 화면 번역 창을 연다. Dock/Finder 재실행도 숨김 상태를 유지한다.
    }

    /// 업데이트 설치가 예약된 상태에서 HTT 안의 브라우저 다운로드나 작업이 진행 중이면 종료를 멈춘다.
    /// Sparkle은 앱이 종료되는 순간(applicationWillTerminate 이후) 설치를 시작하므로, 그 전인 이 단계에서만 막을 수 있다.
    /// 진행 중인 작업은 자동으로 종료하지 않으며, 작업이 끝나면 정상 종료·설치된다.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
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
        MailWindowCoordinator.shared.openBrowserMain()
        return true
    }

    /// .eml·이미지 파일 열기(Finder '다음으로 열기', Dock 아이콘으로 끌어놓기)
    func application(_ application: NSApplication, open urls: [URL]) {
        // http/https 주소는 HTT 안의 브라우저로 넘기고, 파일 열기는 기존 동작을 그대로 유지한다.
        let webURLs = EmbeddedBrowser.forwardableWebURLs(urls)
        if !webURLs.isEmpty { EmbeddedBrowser.open(urls: webURLs) }
        guard let url = urls.first(where: { $0.isFileURL }) else { return }
        AppModel.shared.open(url: url)
        AppModel.shared.showMainWindow()
    }

    func applicationWillTerminate(_ notification: Notification) {
        BrowserDoubleTapShortcut.shared.stop()
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
            button.toolTip = "한툴 (화면 \(GlobalHotKey.displayString) · 메일 \(GlobalHotKey.mailDisplayString) · 브라우저 \(GlobalHotKey.browserDisplayString))"
        }
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        statusItem = item

        NetworkRateMonitor.shared.start()
        setupNetworkRateObservation()
    }

    private func setupNetworkRateObservation() {
        Publishers.CombineLatest3(
            NetworkRateDisplayStore.shared.$location,
            NetworkRateMonitor.shared.$uploadRate,
            NetworkRateMonitor.shared.$downloadRate
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] location, upload, download in
            self?.updateStatusItemRate(location: location, upload: upload, download: download)
        }
        .store(in: &networkRateCancellables)
    }

    private func updateStatusItemRate(location: NetworkRateDisplayLocation, upload: Double, download: Double) {
        guard let item = statusItem, let button = item.button else { return }
        switch location {
        case .menuBar:
            item.length = NSStatusItem.variableLength
            button.imagePosition = .imageLeading
            let up = NetworkRateMonitor.formatRate(upload)
            let down = NetworkRateMonitor.formatRate(download)
            let text = "▲\(up.value)\(up.unit) ▼\(down.value)\(down.unit)"
            let attr = NSAttributedString(
                string: text,
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
                ]
            )
            button.attributedTitle = attr
        case .appTop:
            item.length = NSStatusItem.squareLength
            button.imagePosition = .imageOnly
            button.attributedTitle = NSAttributedString(string: "")
            button.title = ""
        }
    }

    /// 메뉴를 열 때마다 현재 상태(창 표시, 주 버튼, 로그인 항목, 업데이트)로 다시 만든다.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusItem?.menu else { return }
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

        menu.addItem(.separator())

        // MARK: 입력 도우미
        let isInputEnabled = InputMateCoordinator.shared.settings.preferences.isEnabled
        let inputToggle = item(
            isInputEnabled ? "입력 도우미 끄기" : "입력 도우미 켜기",
            #selector(toggleInputMateEnabled),
            symbol: isInputEnabled ? "keyboard" : "pause.circle"
        )
        menu.addItem(inputToggle)

        menu.addItem(.separator())

        // MARK: Mac 관리
        menu.addItem(item("USB 정리·추출", #selector(showCleanUSB), symbol: "externaldrive"))

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
        menu.addItem(item("한툴 종료", #selector(NSApplication.terminate(_:)), target: NSApp, symbol: "power"))
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
        let loginNeedsApproval = loginItem.status == .requiresApproval
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
        submenu.addItem(info("로그인 항목: \(loginItem.lastError ?? loginItem.statusDescription)"))
        if loginItem.status == .requiresApproval {
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

    @objc private func showHome() {
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
        appMenu.addItem(NSMenuItem(title: "한툴 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
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
