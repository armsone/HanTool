import SwiftUI
import AppKit
import Combine

/// HTD 임베디드 호스트 익스포트 파사드 (HTTHTDCore)
///
/// HTT와 동일 프로세스 내 단일 메인 윈도우로 통합될 때 브라우저 뷰 컨트롤러를 생성하고
/// 테마, 수명주기, URL 열기, 호스트 도구 선택 상태를 중재합니다.
@MainActor
public final class HTDHostExport: ObservableObject {
    public static let shared = HTDHostExport()

    public let appModel: AppModel
    let appearance: AppearanceStore

    @Published public private(set) var hostedToolID: String? = nil

    public var onToolSelected: ((String) -> Void)? = nil
    public var onThemeChanged: ((String) -> Void)? = nil
    public var hostedTranslationControl: ((String) -> AnyView?)? = nil
    public var hostedFeatureSettings: ((String) -> AnyView?)? = nil

    private var cachedController: NSViewController? = nil
    private var themeCancellable: AnyCancellable? = nil

    private init() {
        ExternalURLCoordinator.shared.ingestLaunchArguments(CommandLine.arguments)
        self.appModel = AppModel()
        self.appearance = AppearanceStore()
        self.themeCancellable = appearance.$choice
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] choice in
                self?.onThemeChanged?(choice.rawValue)
            }
    }

    /// 호스트 메인 윈도우용 브라우저 뷰 컨트롤러 생성 (단일 인스턴스 캐싱)
    ///
    /// - Parameters:
    ///   - toolView: 호스트 도구가 선택되었을 때 상세 영역 위에 표시될 오버레이 AnyView
    ///   - onToolSelected: 사이드바에서 호스트 도구가 선택되었을 때 호출되는 라우트 콜백
    public func makeMainBrowserViewController(
        toolView: AnyView,
        onToolSelected: @escaping (String) -> Void
    ) -> NSViewController {
        self.onToolSelected = onToolSelected

        if let existing = cachedController {
            return existing
        }

        appearance.startObservingSystem()

        let rootView = MainView(appModel: appModel, toolView: toolView)
            .background(MainWindowKeyMonitor(appModel: appModel))
            .background(
                AILoginProbeSurfaceView()
                    .frame(width: 800, height: 680)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            )
            .modifier(AppearanceThemingModifier(appearance: appearance))
            .onAppear { [weak appearance] in
                appearance?.startObservingSystem()
            }
            .frame(minWidth: 860, idealWidth: 1120, minHeight: 560, idealHeight: 760)

        let controller = NSHostingController(rootView: rootView)
        self.cachedController = controller
        return controller
    }

    /// 브라우저 뷰로 전환하고 선택적으로 주소들을 엽니다.
    public func showBrowser(urls: [URL] = []) {
        if cachedController?.view.window?.isVisible != true && appModel.isAIPanelOpen {
            HanaPanelHost.shared.setPreferredWidth(HanaPanelHost.defaultWidth)
            appModel.thirdPartyAIHost.setPreferredWidth(ThirdPartyAIPanelHost.defaultWidth)
        }
        if self.hostedToolID != nil {
            cachedController?.view.window?.makeFirstResponder(nil)
        }
        self.hostedToolID = nil
        self.appModel.selectedTab = .browser
        UnifiedNavigationModel.shared.syncFromExternal(hostedToolID: nil, selectedTab: .browser)
        if !urls.isEmpty {
            ExternalURLCoordinator.shared.receive(urls)
        } else {
            // Keep the launch/new-tab request: its nil attempt binding survives
            // the first page activation before the window is attached.
            let pending = appModel.addressFocusRequest
            if pending?.tabID != appModel.browser.tabID || pending?.isNewTab != true {
                appModel.requestAddressFocus(for: appModel.browser, isExplicit: true)
            }
        }
    }

    /// 호스트 코드에서 프로그래밍 방식으로 도구를 선택 표시합니다.
    /// A visible browser toggles its assistant; each state restores its own input focus.
    /// Retained closed windows take the ordinary browser-open path instead.
    public func showAssistantIfBrowserVisible() -> Bool {
        guard let window = cachedController?.view.window, window.isVisible,
              !window.isMiniaturized, hostedToolID == nil,
              appModel.selectedTab == .browser,
              UnifiedNavigationModel.shared.destination == .browser else { return false }
        if appModel.isAIPanelOpen {
            appModel.setAIPanelOpen(false)
            appModel.requestAddressFocus(for: appModel.browser, isExplicit: true)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return true
        }
        appModel.clearAddressFocusRequest()
        if !appModel.isAIPanelOpen {
            if appModel.aiServices.enabledServices.isEmpty {
                appModel.temporaryShowHanaPanel = true
            }
            appModel.setAIPanelOpen(true)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, window.isVisible, window.isKeyWindow,
                  window.attachedSheet == nil, self.appModel.isAIPanelOpen else { return }
            if self.appModel.activeAIPanelIsHana {
                let host = HanaPanelHost.shared
                guard host.webView.window === window,
                      HanaPanelHost.isTrustedAlfredURL(host.webView.url) else { return }
                window.makeFirstResponder(host.webView)
                // Focus only; preserve the draft and never read or submit it.
                host.webView.evaluateJavaScript("""
                (() => { const input = document.getElementById('afInput');
                  if (input instanceof HTMLTextAreaElement && !input.disabled && !input.readOnly) {
                    input.focus(); return true;
                  } return false; })()
                """, completionHandler: nil)
            } else {
                let webView = self.appModel.thirdPartyAIHost.webView
                if webView.window === window { window.makeFirstResponder(webView) }
            }
        }
        return true
    }

    /// (호스트 재귀 호출 방지를 위해 onToolSelected 콜백은 트리거하지 않습니다)
    public func showTool(_ id: String) {
        if self.hostedToolID != id {
            cachedController?.view.window?.makeFirstResponder(nil)
        }
        self.hostedToolID = id
        UnifiedNavigationModel.shared.syncFromExternal(hostedToolID: id, selectedTab: appModel.selectedTab)
    }

    /// 사이드바에서 사용자가 호스트 도구를 클릭했을 때 호출됩니다.
    public func selectToolFromSidebar(_ id: String) {
        if self.hostedToolID != id {
            cachedController?.view.window?.makeFirstResponder(nil)
        }
        self.hostedToolID = id
        self.onToolSelected?(id)
    }

    /// 호스트 도구 선택을 해제하고 네이티브 브라우저/작업 공간 뷰를 노출합니다.
    public func clearHostedTool() {
        if self.hostedToolID != nil {
            cachedController?.view.window?.makeFirstResponder(nil)
        }
        self.hostedToolID = nil
    }

    /// 호스트 종료 시 자식 프로세스(엔진, ffmpeg, deno 등)를 안전하게 정리합니다.
    public func shutdown() {
        appModel.shutdown()
    }

    /// 현재 진행 중인 백그라운드 다운로드나 활성 플래너 작업이 있는지 확인합니다.
    public var hasActiveWork: Bool {
        let activeJobs = appModel.jobs.contains { job in
            !job.state.isTerminal && job.state != .paused
        }
        return activeJobs || appModel.hasActiveRun
    }

    /// 호스트의 원본 테마 문자열을 모듈의 ThemeChoice에 매핑하여 적용합니다.
    public func setTheme(_ raw: String) {
        let lower = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let choice: ThemeChoice
        switch lower {
        case "light", "라이트":
            choice = .light
        case "friday", "프라이데이":
            choice = .friday
        case "jarvis", "자비스", "dark", "다크":
            choice = .jarvis
        case "ultron", "울트론":
            choice = .ultron
        default:
            choice = .auto
        }
        appearance.select(choice)
    }
}

/// AppearanceStore 관찰을 통해 테마 및 시스템 외형 변경을 뷰 트리에 반응형으로 전파하는 모디파이어
@MainActor
private struct AppearanceThemingModifier: ViewModifier {
    @ObservedObject var appearance: AppearanceStore

    func body(content: Content) -> some View {
        content
            .environmentObject(appearance)
            .byungkiThemed(appearance.palette)
    }
}
