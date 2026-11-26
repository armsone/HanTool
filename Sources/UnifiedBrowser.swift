import AppKit
import Combine
import Foundation
import SwiftUI
import HTTHTDCore
import HTTThemeCore

/// HTT 루트 호스트와 HTTHTDCore 모듈 간의 단일 창·통합 사이드바·도구 라우팅 브리지.
@MainActor
public final class UnifiedBrowserManager {
    public static let shared = UnifiedBrowserManager()

    private var isUpdatingFromModule = false
    private var isUpdatingFromHost = false
    private var isInitialized = false
    private var hostedToolCancellable: AnyCancellable?

    private init() {}

    /// 브라우저 작업 공간 및 HTDHostExport 초기화 전 오프라인 마이그레이션과 레거시 프로세스 부재를 확인한다.
    public func ensureReady() -> Bool {
        if !isInitialized {
            let result = BrowserDataMigration.performMigrationIfNeeded()
            switch result {
            case .alreadyDone, .freshInstall, .migrated:
                break
            case .blockedLegacyRunning:
                return false
            case .failed(let reason):
                let alert = NSAlert()
                alert.messageText = "브라우저 자료를 옮기지 못했습니다"
                alert.informativeText = "기존 원본 자료는 안전하게 보존되어 있습니다. 아래 원인을 해결한 후 다시 시도해 주세요.\n\n원인: \(reason)"
                alert.alertStyle = .warning
                alert.addButton(withTitle: "확인")
                alert.runModal()
                return false
            }
            if BrowserDataMigration.isLegacyAppRunning() {
                BrowserDataMigration.showLegacyRunningAlert()
                return false
            }
            isInitialized = true
            subscribeToHostedToolChanges()
            // 브라우저 구성(AppModel)이 만들어진 다음 차례에 계정 테마를 읽는다.
            DispatchQueue.main.async { HTTThemeCenter.shared.requestAccountRefresh() }
        }
        return true
    }

    /// 모듈이 소유한 캐시된 단일 컨트롤러(내부에 통합 바깥 사이드바 + 브라우저/Planner + 주입된 단일 불투명 toolView 포함)를 반환한다.
    public func makeMainBrowserViewController(toolView: AnyView) -> NSViewController? {
        guard ensureReady() else { return nil }
        HTDHostExport.shared.hostedTranslationControl = { id in
            guard id == "mail" || id == "screen" else { return nil }
            return AnyView(HostedTranslationToolbarButton(context: id))
        }
        HTDHostExport.shared.hostedFeatureSettings = { key in
            guard key == "browser" else { return nil }
            return AnyView(AISettingsView(scope: .browser))
        }
        HTDHostExport.shared.hostedImageTextRecognizer = { image in
            let regions = try await ImageTextRecognizer.recognize(image, assetID: "page-view")
            return regions.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: "\n")
        }
        return HTDHostExport.shared.makeMainBrowserViewController(toolView: toolView) { [weak self] toolID in
            self?.handleToolSelectedFromModule(toolID)
        }
    }

    /// 호스트에서 모듈로 특정 도구 표시를 요청한다. (재귀 호출 방지)
    public func showTool(section: SettingsSection, inputPage: InputMatePage = .appLanguage) {
        guard ensureReady() else { return }
        guard !isUpdatingFromModule else { return }
        isUpdatingFromHost = true
        defer { isUpdatingFromHost = false }

        let toolID = Self.toolID(for: section, inputPage: inputPage)
        HTDHostExport.shared.showTool(toolID)
    }

    /// Reuse the existing shortcut action without changing its key detector.
    public func showAssistantIfBrowserVisible() -> Bool {
        guard isInitialized else { return false }
        return HTDHostExport.shared.showAssistantIfBrowserVisible()
    }

    /// 호스트에서 모듈 메인 브라우저 경로 열기를 요청한다.
    public func showBrowser(urls: [URL] = []) {
        guard ensureReady() else { return }
        HTDHostExport.shared.showBrowser(urls: urls)
    }

    /// 모듈의 바깥 사이드바/레일에서 도구가 선택되었을 때의 콜백 처리. (재귀 호출 방지)
    private func handleToolSelectedFromModule(_ toolID: String) {
        guard !isUpdatingFromHost else { return }
        isUpdatingFromModule = true
        defer { isUpdatingFromModule = false }

        switch toolID {
        case "home":
            MailWindowCoordinator.shared.selectSectionFromModule(.home)
        case "mail":
            MailWindowCoordinator.shared.selectSectionFromModule(.mail)
        case "screen":
            MailWindowCoordinator.shared.selectSectionFromModule(.screen)
        case "browser":
            MailWindowCoordinator.shared.selectSectionFromModule(.browser)
        case "translationSettings":
            MailWindowCoordinator.shared.selectSectionFromModule(.translationSettings)
        case "input.appLanguage":
            MailWindowCoordinator.shared.selectInputPageFromModule(.appLanguage)
        case "input.koreanTypo":
            MailWindowCoordinator.shared.selectInputPageFromModule(.koreanTypo)
        case "input.personalDictionary":
            MailWindowCoordinator.shared.selectInputPageFromModule(.personalDictionary)
        case "input.trackpad":
            MailWindowCoordinator.shared.selectInputPageFromModule(.trackpad)
        case "input.general":
            MailWindowCoordinator.shared.selectInputPageFromModule(.general)
        case "macManagement":
            MailWindowCoordinator.shared.selectSectionFromModule(.macManagement)
        case "macManagementSettings":
            MailWindowCoordinator.shared.selectSectionFromModule(.macManagementSettings)
        case "cleanUSB":
            MailWindowCoordinator.shared.selectSectionFromModule(.cleanUSB)
        case "serverStatus":
            MailWindowCoordinator.shared.selectSectionFromModule(.serverStatus)
        case "serverStatusSettings":
            MailWindowCoordinator.shared.selectSectionFromModule(.serverStatusSettings)
        case "clipboardHistory":
            MailWindowCoordinator.shared.selectSectionFromModule(.clipboardHistory)
        case "help":
            MailWindowCoordinator.shared.selectSectionFromModule(.help)
        case "general":
            MailWindowCoordinator.shared.selectSectionFromModule(.general)
        default:
            break
        }
    }

    /// 호스트 섹션 및 입력 페이지를 모듈 고정 도구 식별자 규격으로 변환
    public static func toolID(for section: SettingsSection, inputPage: InputMatePage) -> String {
        switch section {
        case .home: return "home"
        case .mail: return "mail"
        case .screen: return "screen"
        case .browser: return "browser"
        case .translationSettings: return "translationSettings"
        case .input:
            switch inputPage {
            case .appLanguage: return "input.appLanguage"
            case .koreanTypo: return "input.koreanTypo"
            case .personalDictionary: return "input.personalDictionary"
            case .trackpad: return "input.trackpad"
            case .general: return "input.general"
            }
        case .macManagement: return "macManagement"
        case .macManagementSettings: return "macManagementSettings"
        case .cleanUSB: return "cleanUSB"
        case .serverStatus: return "serverStatus"
        case .serverStatusSettings: return "serverStatusSettings"
        case .clipboardHistory: return "clipboardHistory"
        case .help: return "help"
        case .general: return "general"
        }
    }

    /// 모듈 내 진행 중인 활성 다운로드 또는 Planner 작업 존재 여부 (업데이터 종료 방지용)
    public var hasActiveWork: Bool {
        guard isInitialized else { return false }
        return HTDHostExport.shared.hasActiveWork
    }

    /// 앱 종료 시 모듈 정상 셧다운
    public func shutdown() {
        guard isInitialized else { return }
        HTDHostExport.shared.shutdown()
    }

    /// Cmd+Q 브라우저 종료 시 브라우저 페이지/웹뷰/미디어 실행을 완전히 종료하고 초기 상태로 되돌린다.
    public func terminateBrowserExecution() {
        guard isInitialized else { return }
        HTDHostExport.shared.terminateBrowserExecution()
    }

    /// 계정 테마를 읽고 쓰는 통로(하나 웹 세션). 브라우저 자료 준비가 끝나지 않았으면 아직 만들지 않는다.
    public func accountThemeTransport() -> HTTAccountThemeTransport? {
        guard isInitialized || BrowserDataMigration.isReadyWithoutPrompt else { return nil }
        return HTDThemeSync.transport()
    }

    /// 모듈 내 도구 선택 상태를 관찰하여 도구가 해제(nil)되고 네이티브 작업 공간으로 전환될 때 캡처 중단 상태를 정리한다.
    private func subscribeToHostedToolChanges() {
        guard hostedToolCancellable == nil else { return }
        hostedToolCancellable = HTDHostExport.shared.$hostedToolID
            .dropFirst()
            .removeDuplicates()
            .sink { toolID in
                if toolID == nil {
                    MailWindowCoordinator.shared.nativeWorkspaceDidSelect()
                }
            }
    }
}
