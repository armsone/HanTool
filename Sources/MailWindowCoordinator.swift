import AppKit
import SwiftUI

/// HTT의 모든 기능이 쓰는 단 하나의 일반 메인 창(작업 창)과 진입점을 기존 앱 수명주기(AppDelegate) 안에서 관리한다.
/// - 메인 창: 사이드바(홈·메일/이미지 번역·화면 번역·브라우저 번역·입력 도우미·Mac 관리·사용 방법·앱 설정)와 상세 영역.
///   메뉴·홈/가이드 버튼·서비스·Finder 파일 열기·메일 단축키·AI 로그인 화면 모두 이 창에서 섹션만 바꾼다.
///   창을 닫으면 메일 내용을 메모리에서 지우고 창도 해제한다. 앱은 종료하지 않는다.
/// - 화면 번역은 다른 앱 위의 투명 캡처 영역이므로 임시 모드로 다룬다: 시작하면 작업 창을 숨기고,
///   캡처 영역을 닫으면(버튼·Esc) 같은 작업 창으로 돌아온다. 작업 창과 캡처 영역은 함께 보이지 않는다.
/// - AI 로그인·수동 진행·웹 번역 확인 화면(공식 로그인 OAuth 자식 포함)과 웹 번역 진행·취소 줄은 별도 창·패널 없이 이 창 안에 올린다.
///   캡처 중에 이런 화면이 필요해지면 캡처 영역만 취소 없이 잠시 내리고(진행 중 화면 번역은 유지) 작업 창에 보여 준 뒤,
///   마지막 화면이 닫히면 사용자가 다른 곳으로 이동하지 않은 경우에 한해 캡처 모드로 돌아간다.
/// - Mail › 서비스 › '메일 전체 번역' 처리기.
@MainActor
final class MailWindowCoordinator: NSObject, NSWindowDelegate {
    static let shared = MailWindowCoordinator()

    private var workbenchWindow: NSWindow?
    private let store = SettingsSectionStore.shared

    /// NSApp.servicesProvider가 제공자를 보유한다고 가정하지 않고 이 객체가 앱 수명 동안 직접 보유한다.
    private let serviceProvider = MailServiceProvider()

    /// AppDelegate가 연결하는 화면 번역(캡처 영역) 상태 조회·숨김 동작.
    var isCaptureVisible: (() -> Bool)?
    var hideCapture: (() -> Void)?
    /// 캡처 영역을 취소 없이 잠시 내리는 동작(작업 창 안 AI·웹 번역 화면을 보여 주는 동안).
    var concealCapture: (() -> Void)?
    /// 잠시 내렸던 캡처 영역을 다시 보인다(작업 창은 이미 숨겨진 뒤에 호출).
    var resumeCapture: (() -> Void)?
    /// 잠시 내린 캡처를 포기할 때(사용자가 다른 곳으로 이동·창을 닫음) 진행 중 화면 번역을 숨김 규칙대로 취소한다.
    var cancelCaptureWork: (() -> Void)?
    /// 캡처 모드를 시작하기 직전에 작업 창이 보이고 있었는지(있었던 경우에만 끝난 뒤 같은 창으로 복귀).
    private var restoreWorkbenchAfterCapture = false
    /// 캡처 영역이 AI·웹 번역 화면 때문에 잠시 내려가 있는지(마지막 화면이 닫히면 같은 캡처 모드로 복귀).
    private var captureSuspendedForAuxiliary = false
    private var isCaptureResumeScheduled = false
    private var isTerminating = false

    /// 앱 시작 시 1회: 서비스 메뉴 등록과 Mail 번역 버튼(기본 켜짐) 재개. 시작 때 창은 열지 않는다.
    func start() {
        // 사용자가 섹션을 옮기면(사이드바·홈/가이드 버튼·메뉴) 잠시 내린 캡처는 포기한다.
        store.onSectionChanged = { [weak self] in self?.abandonSuspendedCapture() }
        NSApp.servicesProvider = serviceProvider
        NSRegisterServicesProvider(serviceProvider, "HanTool")
        NSUpdateDynamicServices()
        UserDefaults.standard.register(defaults: ["attachedMailTranslationButton": true])
        MailToolbarButton.shared.resumeIfEnabled()
    }

    // MARK: - 메인 창

    /// 메인 창 자체인지(AppModel.isResultWindow 등).
    func isWorkbenchWindow(_ window: NSWindow) -> Bool {
        window === workbenchWindow
    }

    /// 메일 번역 섹션이 앞에 있는 메인 창인지('현재 내용 지우기' 메뉴 유효성).
    func isMailWindow(_ window: NSWindow) -> Bool {
        window === workbenchWindow && store.section == .mail && !store.showsHostedBrowser
    }

    /// 메인 창을 원하는 섹션으로 연다. 이미 열려 있으면 같은 창을 앞으로 가져오고 섹션만 바꾼다.
    func showWorkbench(section: SettingsSection = .home) {
        // 명시적 이동: 잠시 내려 둔 캡처가 있으면 포기(진행 중 화면 번역 취소)하고, 떠 있는 캡처 영역도 먼저 닫는다.
        // 작업 창과 캡처 영역이 겹쳐 보이지 않게, 작업 창을 보이기 전에 캡처 영역을 먼저 닫는다.
        abandonSuspendedCapture()
        dismissCaptureOverlayIfNeeded()
        store.showsHostedBrowser = false
        store.section = section
        if section == .macManagement || section == .macManagementSettings { BTNIntegration.shared.prepareForDisplay() }
        UnifiedBrowserManager.shared.showTool(section: section, inputPage: store.inputPage)
        presentWorkbenchWindow()
    }

    /// 모듈 메인 브라우저 화면을 열고 메인 창을 앞으로 가져온다.
    func openBrowserMain(urls: [URL] = []) {
        abandonSuspendedCapture()
        dismissCaptureOverlayIfNeeded()
        store.showsHostedBrowser = false
        UnifiedBrowserManager.shared.showBrowser(urls: urls)
        presentWorkbenchWindow()
    }

    /// 모듈 내 네이티브 작업 공간(브라우저/Planner 등)이 선택되었을 때(호스트 도구 해제 시) 잠시 내린 캡처를 포기하고 캡처 오버레이를 닫는다.
    func nativeWorkspaceDidSelect() {
        abandonSuspendedCapture()
        dismissCaptureOverlayIfNeeded()
        store.showsHostedBrowser = false
    }

    /// 모듈에서 도구가 선택되었을 때 호스트 섹션을 동기화하고 같은 창을 표시한다.
    func selectSectionFromModule(_ section: SettingsSection) {
        abandonSuspendedCapture()
        dismissCaptureOverlayIfNeeded()
        store.showsHostedBrowser = false
        store.section = section
        if section == .macManagement || section == .macManagementSettings { BTNIntegration.shared.prepareForDisplay() }
        presentWorkbenchWindow()
    }

    /// 모듈에서 입력 도우미 하위 페이지가 선택되었을 때 호스트 상태를 동기화하고 같은 창을 표시한다.
    func selectInputPageFromModule(_ page: InputMatePage) {
        abandonSuspendedCapture()
        dismissCaptureOverlayIfNeeded()
        store.showsHostedBrowser = false
        store.section = .input
        store.inputPage = page
        presentWorkbenchWindow()
    }

    /// 메일 번역 섹션을 연다(서비스·Finder 파일 열기·메일 단축키·메뉴 공통 진입점).
    func showMailWindow() {
        showWorkbench(section: .mail)
    }

    /// 메일 문서를 지우고 같은 메인 창에 남는다(휴지통 이동 뒤 등). 다른 섹션은 닫지 않는다.
    func closeMailDocument() {
        AppModel.shared.closeDocument()
        AppModel.shared.errorMessage = nil
    }

    /// 브라우저 확장의 "언어팩" 버튼이 호출: 브라우저 번역 섹션을 열고 그 안에서 바로 다운로드 시트를 띄운다.
    func openLanguagePackDownload() {
        showWorkbench(section: .browser)
        store.showLanguagePackSheet = true
    }

    /// 기존 메인 창과 선택(store/뷰)을 온전히 보존한 채 창만 전면으로 가져온다.
    func presentWorkbenchPreservingSelection() {
        presentWorkbenchWindow()
    }

    /// forceLayout: 숨김 웹 보기를 붙일 호스트가 이 창에 곧바로 실제 크기로 붙도록 한 번 레이아웃을 끝낸다.
    private func presentWorkbenchWindow(forceLayout: Bool = false) {
        guard !isTerminating else { return }
        let window = workbenchWindow ?? makeWorkbenchWindow()
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        if forceLayout { window.contentView?.layoutSubtreeIfNeeded() }
    }

    private func makeWorkbenchWindow() -> NSWindow {
        let toolRootView = SettingsView(store: store, showsSidebar: false)
            .environmentObject(InputMateCoordinator.shared.appState)
            .environmentObject(InputMateCoordinator.shared.settings)
            .environmentObject(InputMateCoordinator.shared.appInputLanguageStore)
        let toolAnyView = AnyView(toolRootView)

        let controller: NSViewController
        if let browserController = UnifiedBrowserManager.shared.makeMainBrowserViewController(toolView: toolAnyView) {
            controller = browserController
        } else {
            let hosting = NSHostingController(rootView: toolRootView)
            hosting.sceneBridgingOptions = [.toolbars]
            controller = hosting
        }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.contentViewController = controller
        window.title = "한툴"
        window.identifier = NSUserInterfaceItemIdentifier("htt-workbench")
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 780, height: 560)
        window.delegate = self
        window.setContentSize(NSSize(width: 1040, height: 760))
        if !window.setFrameUsingName("HTTWorkbenchWindow") { window.center() }
        window.setFrameAutosaveName("HTTWorkbenchWindow")
        if let toolbar = window.toolbar {
            toolbar.allowsUserCustomization = false
            if #available(macOS 15.0, *) {
                toolbar.allowsDisplayModeCustomization = false
            }
        }
        if AppModel.shared.keepOnTop { window.level = .floating }
        workbenchWindow = window
        return window
    }

    // MARK: - 작업 영역 안의 브라우저 화면(AI 로그인·수동 진행·웹 번역 확인)

    /// 별도 창 대신 메인 창의 작업 영역에 브라우저 화면을 올린다. 웹 보기·세션은 그대로 이어진다.
    /// 이미 쌓인 화면(예: OAuth 부모)은 아래에 붙은 채 유지되고, 새 화면이 맨 위에서만 입력을 받는다.
    /// 캡처 영역이 떠 있으면 진행 중 화면 번역을 취소하지 않고 잠시 내린다.
    func presentHostedBrowser(_ browser: AIBIBrowserWindow) {
        guard !isTerminating else { return }
        concealCaptureForAuxiliaryIfNeeded()
        if !store.hostedBrowsers.contains(where: { $0 === browser }) {
            store.hostedBrowsers.append(browser)
        }
        store.showsHostedBrowser = true
        UnifiedBrowserManager.shared.showTool(section: store.section, inputPage: store.inputPage)
        presentWorkbenchWindow(forceLayout: true)
    }

    /// 화면을 스택에서 뗀다. 아래 화면이 남아 있으면 같은 마운트의 그 화면이 다시 맨 위가 된다(다시 불러오지 않음).
    func dismissHostedBrowser(_ browser: AIBIBrowserWindow) {
        store.hostedBrowsers.removeAll { $0 === browser }
        if store.hostedBrowsers.isEmpty { store.showsHostedBrowser = false }
        scheduleCaptureResumeIfIdle()
    }

    /// 웹 번역 진행 줄: 같은 메인 창 안에 숨김 웹 보기 호스트(불투명 내용 뒤)와 진행·취소 줄을 올린다.
    func presentStatusPanel(_ panel: WebTranslatorStatusPanel) {
        guard !isTerminating else { return }
        concealCaptureForAuxiliaryIfNeeded()
        store.statusPanel = panel
        UnifiedBrowserManager.shared.showTool(section: store.section, inputPage: store.inputPage)
        presentWorkbenchWindow(forceLayout: true)
    }

    func dismissStatusPanel(_ panel: WebTranslatorStatusPanel) {
        guard store.statusPanel === panel else { return }
        store.statusPanel = nil
        scheduleCaptureResumeIfIdle()
    }

    // MARK: 캡처 영역의 임시 숨김과 복귀

    /// 캡처 영역이 떠 있으면 onWillHide(화면 번역 취소) 없이 내린다. 복귀 여부는 captureSuspendedForAuxiliary가 기억한다.
    private func concealCaptureForAuxiliaryIfNeeded() {
        guard isCaptureVisible?() == true else { return }
        captureSuspendedForAuxiliary = true
        concealCapture?()
    }

    /// 사용자가 다른 곳으로 이동하거나 작업 창을 닫음: 잠시 내려 둔 캡처로는 돌아가지 않고 진행 중 화면 번역만 취소한다.
    /// 복귀 표시를 먼저 지워, 취소로 화면이 닫히며 생기는 복귀 검사가 아무 일도 하지 않게 한다.
    private func abandonSuspendedCapture() {
        guard captureSuspendedForAuxiliary else { return }
        captureSuspendedForAuxiliary = false
        restoreWorkbenchAfterCapture = false
        cancelCaptureWork?()
    }

    /// 보조 화면이 모두 닫혔을 때만 다음 실행 루프에서 복귀를 검사한다(닫고 곧바로 새로 여는 교체 중에는 복귀하지 않음).
    private func scheduleCaptureResumeIfIdle() {
        guard captureSuspendedForAuxiliary, !isCaptureResumeScheduled,
              store.hostedBrowsers.isEmpty, store.statusPanel == nil else { return }
        isCaptureResumeScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isCaptureResumeScheduled = false
            self.resumeCaptureIfIdle()
        }
    }

    private func resumeCaptureIfIdle() {
        guard captureSuspendedForAuxiliary, !isTerminating,
              store.hostedBrowsers.isEmpty, store.statusPanel == nil else { return }
        captureSuspendedForAuxiliary = false
        guard isCaptureVisible?() != true else { return }
        // 작업 창과 캡처 영역이 겹치지 않게 작업 창을 먼저 숨긴다(restoreWorkbenchAfterCapture는 그대로 두어 끝난 뒤 원래대로 복귀).
        if let window = workbenchWindow, window.isVisible { window.orderOut(nil) }
        resumeCapture?()
    }

    // MARK: - 화면 번역 캡처 모드(임시 모드)

    /// 작업 창의 '캡처 모드 시작' 버튼: AppDelegate.showOverlay가 작업 창을 숨기고 캡처 영역을 띄운다.
    func startCaptureModeFromWorkbench() {
        (NSApp.delegate as? AppDelegate)?.showOverlay()
    }

    /// 캡처 영역을 띄우기 직전: 보이는 작업 창은 닫지 않고(메일 내용 유지) 숨기고, 끝나면 복귀하도록 기억한다.
    func willBeginCaptureMode() {
        // 사용자가 캡처 모드를 직접 다시 시작함: 이전의 임시 숨김 복귀 예약은 새 캡처로 대체한다.
        captureSuspendedForAuxiliary = false
        guard let window = workbenchWindow, window.isVisible else { return }
        restoreWorkbenchAfterCapture = true
        window.orderOut(nil)
    }

    /// 캡처 영역이 숨겨질 때(닫기 버튼·Esc·메뉴): 시작 때 작업 창이 보이고 있었던 경우에만 같은 창으로 돌아온다.
    func captureModeDidEnd() {
        guard restoreWorkbenchAfterCapture else { return }
        restoreWorkbenchAfterCapture = false
        // 캡처 영역이 완전히 내려간 다음 실행 루프에서 복귀해 겹침과 활성화 반복을 피한다.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isTerminating, let window = self.workbenchWindow,
                  !(self.isCaptureVisible?() ?? false) else { return }
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// 작업 창을 보이기 전: 캡처 영역이 떠 있으면 복귀 예약 없이 숨긴다(진행 중 캡처 작업은 숨김 규칙대로 취소).
    private func dismissCaptureOverlayIfNeeded() {
        restoreWorkbenchAfterCapture = false
        if isCaptureVisible?() == true { hideCapture?() }
    }

    /// 앱 종료 중에는 캡처 영역을 내리면서 작업 창을 다시 띄우지 않는다.
    func prepareForTermination() {
        isTerminating = true
        captureSuspendedForAuxiliary = false
        restoreWorkbenchAfterCapture = false
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === workbenchWindow else { return }
        // 잠시 내려 둔 캡처가 있으면 복귀 없이 포기한다(복귀 표시를 먼저 지운 뒤 화면 번역 취소).
        abandonSuspendedCapture()
        // 열려 있던 브라우저 화면·웹 번역 진행 줄은 사용자가 닫은 것과 같게 취소한다(onUserClose).
        for browser in Array(store.hostedBrowsers) { browser.userClose() }
        store.statusPanel?.userClose()
        store.showsHostedBrowser = false
        restoreWorkbenchAfterCapture = false
        // 메인 창을 닫으면 메일 내용(문서·이미지·번역·외부 AI 실행)을 메모리에서 지운다.
        AppModel.shared.closeDocument()
        AppModel.shared.errorMessage = nil
        // 창 닫기로 인해 브라우저/Planner 모델/컨트롤러가 파괴되지 않도록 윈도우와 컨트롤러를 유지한다.
        // 다음 재열기 시 newWindow 시작 정책이 정상 적용될 수 있도록 실행 탭 상태를 준비한다.
        UnifiedBrowserManager.shared.terminateBrowserExecution()
    }
}

/// Mail 앱 메뉴 › 서비스 › '메일 전체 번역' 처리기.
/// 입력이 없는 서비스라 대지(pasteboard)는 쓰지 않고, Mail에서 선택된 메시지 원본을 AppleScript로 읽는다.
final class MailServiceProvider: NSObject {
    @objc func translateSelectedMessage(_ pboard: NSPasteboard, userData: String?,
                                        error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        // 서비스 응답을 먼저 돌려준 뒤(Mail이 기다리지 않도록) 선택 메시지를 읽는다.
        // 이 시점에는 아직 Mail이 앞에 있으므로, 창을 앞으로 가져오기 전에 선택이 확정된다.
        DispatchQueue.main.async {
            MainActor.assumeIsolated { AppModel.shared.translateSelectedMail() }
        }
    }
}
