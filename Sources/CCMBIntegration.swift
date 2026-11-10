import AppKit
import Foundation
import HTTCCMB

/// HTT 호스트와 CCMB 서버 현황 모듈(HTTCCMB) 간의 수명주기 및 설정 연결 객체.
/// - 기본 상태는 완전 비활성화(OFF), 메뉴 막대 요약 표시 비활성화(OFF), 대상 서버 비어 있음(""), 수집 소스 NAS("nas").
/// - 모듈 패널의 '종료'는 서버 현황 기능만 비활성화하고, '재시작'은 모니터링 런타임만 재시작하여 HTT 전체 작업을 보호한다.
/// - 로그인 시 자동 실행은 HTT 기존 LoginItemManager를 통해 일원화하며 CCMB 자체 LaunchAgent는 설치하지 않는다.
@MainActor
public final class CCMBIntegration: ObservableObject {
    public static let shared = CCMBIntegration()

    // MARK: - UserDefaults 키
    public static let enabledKey = "ccmbEnabled"
    public static let showMenuBarKey = "ccmbShowMenuBar"
    public static let serverTargetKey = "ccmbServerTarget"
    public static let dataSourceKey = "ccmbDataSource"

    // MARK: - 지원 데이터 소스 상수
    public static let sourceNAS = "nas"
    public static let sourceLocalMac = "localMac"

    // MARK: - 발행 상태
    @Published public private(set) var isEnabled: Bool
    @Published public private(set) var showMenuBar: Bool
    @Published public private(set) var serverTarget: String
    @Published public private(set) var dataSource: String
    @Published public var targetDraft: String

    // MARK: - 외부 호스트 매니저 약한 참조
    private weak var updater: UpdaterManager?
    private weak var loginItem: LoginItemManager?

    // MARK: - 초기화
    private init() {
        let defaults = UserDefaults.standard
        let savedEnabled = defaults.bool(forKey: Self.enabledKey)
        let savedShowMenuBar = defaults.bool(forKey: Self.showMenuBarKey)
        let savedTarget = defaults.string(forKey: Self.serverTargetKey) ?? ""
        let savedSource = defaults.string(forKey: Self.dataSourceKey) ?? Self.sourceNAS

        self.isEnabled = savedEnabled
        self.showMenuBar = savedShowMenuBar
        self.serverTarget = savedTarget
        self.dataSource = savedSource
        self.targetDraft = savedTarget
    }

    // MARK: - 호스트 초기 설정 주입
    func setup(updater: UpdaterManager?, loginItem: LoginItemManager?) {
        self.updater = updater
        self.loginItem = loginItem
    }

    // MARK: - 수명주기 제어

    /// 앱 시작 시 저장된 설정이 활성화(true)인 경우에만 런타임을 구동한다.
    public func startIfEnabled() {
        guard isEnabled else { return }
        configureModuleSettings()
        startRuntime()
    }

    /// 모니터링 기능 켜기/끄기
    public func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)

        if enabled {
            configureModuleSettings()
            startRuntime()
        } else {
            HTTCCMBRuntime.stop()
        }
    }

    /// 메뉴 막대 요약 표시 여부 토글 (기능 전체 중단 없이 메뉴 항목만 보이거나 숨김)
    public func setShowMenuBar(_ visible: Bool) {
        showMenuBar = visible
        UserDefaults.standard.set(visible, forKey: Self.showMenuBarKey)
        if isEnabled {
            HTTCCMBRuntime.setMenuBarVisible(visible)
        }
    }

    /// 데이터 소스 전환 ("nas" 또는 "localMac")
    public func setDataSource(_ source: String) {
        guard source == Self.sourceNAS || source == Self.sourceLocalMac else { return }
        dataSource = source
        UserDefaults.standard.set(source, forKey: Self.dataSourceKey)
        HTTCCMBRuntime.setDataSource(source)

        if isEnabled {
            restartRuntime()
        }
    }

    /// 대상 서버 초안(targetDraft) 검증 및 적용
    @discardableResult
    public func applyTargetDraft() -> Bool {
        let result = Self.validateTarget(targetDraft)
        switch result {
        case .empty:
            serverTarget = ""
            UserDefaults.standard.set("", forKey: Self.serverTargetKey)
            HTTCCMBRuntime.setServerTarget("")
            if isEnabled {
                restartRuntime()
            }
            return true
        case .valid(let validated):
            serverTarget = validated
            UserDefaults.standard.set(validated, forKey: Self.serverTargetKey)
            HTTCCMBRuntime.setServerTarget(validated)
            if isEnabled {
                restartRuntime()
            }
            return true
        case .invalid:
            return false
        }
    }

    /// 기존 CCMB 원본 대시보드 창 열기
    public func showDashboard() {
        guard isEnabled else { return }
        HTTCCMBRuntime.showDashboard()
    }

    /// 런타임 종료 (호스트 앱 종료 시)
    public func stop() {
        HTTCCMBRuntime.stop()
    }

    /// 런타임 안전 재시작 (설정 변경 또는 CCMB 패널 내부 재시작 요청 시)
    public func restartRuntime() {
        guard isEnabled else { return }
        HTTCCMBRuntime.stop()
        configureModuleSettings()
        startRuntime()
    }

    // MARK: - 모듈 설정 및 런타임 구동 헬퍼

    private func configureModuleSettings() {
        HTTCCMBRuntime.setDataSource(dataSource)
        HTTCCMBRuntime.setServerTarget(serverTarget)
    }

    private func startRuntime() {
        let callbacks = HTTCCMBRuntime.HostCallbacks(
            onCheckForUpdates: { [weak self] in
                self?.updater?.checkForUpdates()
            },
            onQuit: { [weak self] in
                // 중요: CCMB 패널의 '종료'는 HTT 전체가 아닌 서버 모니터링 기능만 끈다.
                self?.setEnabled(false)
            },
            onRestart: { [weak self] in
                // 중요: CCMB 패널의 '재시작'은 HTT 전체가 아닌 서버 모니터링 런타임만 재시작한다.
                self?.restartRuntime()
            },
            onLaunchAtLogin: { [weak self] enabled in
                // 중요: CCMB LaunchAgent 설치를 차단하고 HTT 공식 LoginItemManager를 통해서만 등록/해제한다.
                self?.loginItem?.setEnabled(enabled)
            },
            isLaunchAtLoginEnabled: { [weak self] in
                self?.loginItem?.status == .enabled
            },
            onDataSourceChanged: { [weak self] newSource in
                guard let self, self.dataSource != newSource else { return }
                self.dataSource = newSource
                UserDefaults.standard.set(newSource, forKey: Self.dataSourceKey)
            }
        )
        HTTCCMBRuntime.start(showMenuBar: showMenuBar, callbacks: callbacks)
    }

    // MARK: - 상태 조회

    public var isRunning: Bool {
        HTTCCMBRuntime.isRunning
    }

    public var statusSummary: String {
        guard isEnabled else { return "꺼짐" }
        if dataSource == Self.sourceLocalMac {
            return isRunning ? "실행 중 (이 Mac)" : "대기 중 (이 Mac)"
        }
        if serverTarget.isEmpty {
            return "대상 미설정"
        }
        return isRunning ? "실행 중 (\(serverTarget))" : "대기 중 (\(serverTarget))"
    }

    public var statusDescription: String {
        guard isEnabled else {
            return "서버 현황 모니터링이 비활성화되어 있습니다."
        }
        if dataSource == Self.sourceLocalMac {
            return isRunning ? "이 Mac의 AI 사용량을 확인하고 있습니다." : "이 Mac의 AI 사용량 조회 준비 중입니다."
        }
        if serverTarget.isEmpty {
            return "대상 서버가 설정되지 않았습니다. SSH 호스트를 입력해 주세요."
        }
        return isRunning ? "SSH 호스트(\(serverTarget))로부터 서버 상태를 수집하고 있습니다." : "SSH 호스트(\(serverTarget)) 연결 준비 중입니다."
    }

    // MARK: - 대상 서버 입력 검증

    public enum TargetValidationResult: Equatable {
        case empty
        case valid(String)
        case invalid(String)

        public var isValid: Bool {
            switch self {
            case .empty, .valid: return true
            case .invalid: return false
            }
        }

        public var errorMessage: String? {
            switch self {
            case .empty, .valid: return nil
            case .invalid(let msg): return msg
            }
        }
    }

    /// 엄격한 SSH 대상 검증:
    /// - 빈 값은 미설정(연결 시도 없음) 상태로 허용
    /// - 첫 글자 영문/숫자, 이후 영문·숫자·마침표(.)·하이픈(-)·밑줄(_)만 허용 (최대 253자)
    /// - 옵션 주입 방지(선행 하이픈 차단), 공백/제어문자 차단, HTTP/SSH URL 스키마 및 슬래시 차단
    public static func validateTarget(_ target: String) -> TargetValidationResult {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return .empty
        }

        if target != trimmed || target.contains(where: { $0.isWhitespace || $0.isNewline }) {
            return .invalid("공백이나 줄바꿈 문자는 포함할 수 없습니다.")
        }

        if target.hasPrefix("-") {
            return .invalid("SSH 옵션 주입 방지를 위해 하이픈(-)으로 시작할 수 없습니다.")
        }

        if target.contains("://") || target.contains("/") {
            return .invalid("URL 스키마(http://, ssh://)나 슬래시는 지원되지 않습니다. SSH 호스트 별칭 또는 호스트명을 입력하세요.")
        }

        if target.count > 253 {
            return .invalid("호스트 대상은 최대 253자까지 가능합니다.")
        }

        let pattern = "^[A-Za-z0-9][A-Za-z0-9._-]{0,252}$"
        let predicate = NSPredicate(format: "SELF MATCHES %@", pattern)
        if !predicate.evaluate(with: target) {
            return .invalid("첫 글자는 영문 또는 숫자여야 하며, 영문, 숫자, 마침표(.), 하이픈(-), 밑줄(_)만 사용할 수 있습니다.")
        }

        return .valid(target)
    }
}
