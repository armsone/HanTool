import AppKit
import Combine
import Foundation
import SwiftUI
import HTTHTDCore

/// HTT 루트 호스트와 HTTHTDCore 모듈 간의 단일 창·통합 사이드바·도구 라우팅 브리지.
@MainActor
public final class UnifiedBrowserManager {
    public static let shared = UnifiedBrowserManager()

    private var isUpdatingFromModule = false
    private var isUpdatingFromHost = false
    private var isSyncingTheme = false
    private var isInitialized = false
    private var hostedToolCancellable: AnyCancellable?
    private var themeCancellable: AnyCancellable?

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
            setupThemeSynchronization()
            syncTheme()
            subscribeToHostedToolChanges()
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

    /// 현재 호스트 테마를 모듈에 동기화
    public func syncTheme() {
        syncTheme(HTTAppearanceStore.shared.theme)
    }

    private func syncTheme(_ theme: HTTTheme) {
        guard isInitialized, !isSyncingTheme else { return }
        isSyncingTheme = true
        defer { isSyncingTheme = false }
        let rawTheme = theme.rawValue
        HTDHostExport.shared.setTheme(rawTheme)
    }

    /// 루트 HTTAppearanceStore와 모듈 HTDHostExport 간의 양방향 테마 동기화 설정
    private func setupThemeSynchronization() {
        HTDHostExport.shared.onThemeChanged = { [weak self] rawValue in
            guard let self = self, !self.isSyncingTheme else { return }
            let mappedTheme = HTTTheme.from(storedString: rawValue)
            if HTTAppearanceStore.shared.theme != mappedTheme {
                self.isSyncingTheme = true
                HTTAppearanceStore.shared.theme = mappedTheme
                self.isSyncingTheme = false
            }
        }

        guard themeCancellable == nil else { return }
        themeCancellable = HTTAppearanceStore.shared.$theme
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] theme in
                self?.syncTheme(theme)
            }
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
