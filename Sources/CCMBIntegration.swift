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

    // MARK: - 연결 상태
    public enum ConnectionState: Equatable {
        case idle
        case checking
        case connected(authenticated: Bool, role: String?)
        case failed(String)
    }

    // MARK: - 발행 상태
    @Published public private(set) var isEnabled: Bool
    @Published public private(set) var showMenuBar: Bool
    @Published public private(set) var serverTarget: String
    @Published public private(set) var dataSource: String
    @Published public var targetDraft: String {
        didSet {
            if Self.normalizedTarget(oldValue) != Self.normalizedTarget(targetDraft) {
                invalidateAsyncWork(closeLogin: true)
            }
        }
    }
    @Published public private(set) var connectionState: ConnectionState = .idle

    // MARK: - 비동기 작업 무효화 (probe/login)
    private var probeGeneration = 0
    private var loginGeneration = 0
    private var probeTask: Task<Void, Never>?

    /// 진행 중인 probe를 취소하고 이전 세대의 결과 적용을 막습니다. closeLogin이면 로그인 창/콜백도 무효화합니다.
    private func invalidateAsyncWork(closeLogin: Bool) {
        probeGeneration &+= 1
        probeTask?.cancel()
        probeTask = nil
        connectionState = .idle
        if closeLogin {
            loginGeneration &+= 1
            NASLoginWindowController.closeActive()
        }
    }

    private static func normalizedTarget(_ target: String) -> String {
        switch validateTarget(target) {
        case .empty: return ""
        case .valid(let validated): return validated
        case .invalid: return target.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

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
        HTTCCMBProviderPageRouter.openPage = { url in EmbeddedBrowser.open(urls: [url]) }
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
        invalidateAsyncWork(closeLogin: true)

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
        invalidateAsyncWork(closeLogin: true)
        dataSource = source
        UserDefaults.standard.set(source, forKey: Self.dataSourceKey)
        HTTCCMBRuntime.setDataSource(source)
    }

    /// 대상 서버 초안(targetDraft) 검증 및 적용
    @discardableResult
    public func applyTargetDraft() -> Bool {
        let result = Self.validateTarget(targetDraft)
        switch result {
        case .empty:
            invalidateAsyncWork(closeLogin: true)
            serverTarget = ""
            UserDefaults.standard.set("", forKey: Self.serverTargetKey)
            HTTCCMBRuntime.setServerTarget("")
            connectionState = .idle
            return true
        case .valid(let validated):
            serverTarget = validated
            UserDefaults.standard.set(validated, forKey: Self.serverTargetKey)
            HTTCCMBRuntime.setServerTarget(validated)
            checkConnection()
            return true
        case .invalid:
            return false
        }
    }

    // MARK: - 놀이터 서버 연결 및 로그인 제어

    /// 놀이터 서버 세션 상태를 비동기로 확인합니다 (GET /api/session).
    public func checkConnection() {
        invalidateAsyncWork(closeLogin: false)
        let target = targetDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else {
            connectionState = .idle
            return
        }

        let validation = Self.validateTarget(target)
        guard case .valid(let validated) = validation else {
            connectionState = .failed(validation.errorMessage ?? "올바른 놀이터 HTTPS 주소를 입력하세요.")
            return
        }

        connectionState = .checking
        let generation = probeGeneration
        probeTask = Task { @MainActor in
            do {
                let session = try await NASHTTPClient.shared.fetchSession(target: validated)
                guard self.isCurrentProbe(generation, target: validated) else { return }
                self.connectionState = .connected(authenticated: session.authenticated, role: session.role)
                if session.authenticated, self.isAppliedNASTarget(validated) {
                    HTTCCMBRuntime.triggerNASRefresh()
                }
            } catch let error as NASFetchError {
                guard self.isCurrentProbe(generation, target: validated) else { return }
                if case .loginRequired = error {
                    self.connectionState = .connected(authenticated: false, role: nil)
                } else {
                    self.connectionState = .failed(error.label)
                }
            } catch {
                guard self.isCurrentProbe(generation, target: validated) else { return }
                self.connectionState = .failed("연결 실패")
            }
        }
    }

    /// 현재 NAS 소스이며 같은 세대/정규화 대상일 때만 probe 결과를 적용할 수 있습니다.
    private func isCurrentProbe(_ generation: Int, target: String) -> Bool {
        !Task.isCancelled
            && generation == probeGeneration
            && dataSource == Self.sourceNAS
            && Self.normalizedTarget(targetDraft) == target
    }

    /// 적용된(저장된) 대상이 요청 대상과 같고 NAS 소스·활성 상태일 때만 갱신을 트리거할 수 있습니다.
    private func isAppliedNASTarget(_ target: String) -> Bool {
        isEnabled
            && dataSource == Self.sourceNAS
            && Self.normalizedTarget(serverTarget) == Self.normalizedTarget(target)
    }

    /// 내장 브라우저 창을 띄워 사용자가 놀이터 웹 화면에서 직접 로그인하도록 합니다.
    public func openLoginWindow() {
        let raw = (targetDraft.isEmpty ? serverTarget : targetDraft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, dataSource == Self.sourceNAS,
              case .valid(let target) = Self.validateTarget(raw) else { return }

        let generation = loginGeneration
        NASLoginWindowController.show(target: target) { [weak self] success in
            guard let self,
                  generation == self.loginGeneration,
                  self.dataSource == Self.sourceNAS,
                  Self.normalizedTarget(self.targetDraft.isEmpty ? self.serverTarget : self.targetDraft) == target
            else { return }
            if success {
                self.invalidateAsyncWork(closeLogin: false)
                self.connectionState = .connected(authenticated: true, role: nil)
                if self.isAppliedNASTarget(target) {
                    HTTCCMBRuntime.triggerNASRefresh()
                }
            } else {
                self.checkConnection()
            }
        }
    }

    /// 기존 CCMB 원본 대시보드 창 열기
    public func showDashboard() {
        guard isEnabled else { return }
        HTTCCMBRuntime.showDashboard()
    }

    /// 런타임 종료 (호스트 앱 종료 시)
    public func stop() {
        invalidateAsyncWork(closeLogin: true)
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
                self.invalidateAsyncWork(closeLogin: true)
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
            return "놀이터 주소 미설정"
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
            return "놀이터 서버 주소가 설정되지 않았습니다. HTTPS 주소를 입력해 주세요."
        }
        return isRunning ? "놀이터 서버(\(serverTarget))로부터 서버 상태를 수집하고 있습니다." : "놀이터 서버(\(serverTarget)) 연결 준비 중입니다."
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

    /// 놀이터 서버 대상 주소 검증 (HTTPS 필수, 로컬 루프백 제외)
    public static func validateTarget(_ target: String) -> TargetValidationResult {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return .empty
        }

        let result = NASURLValidator.validate(urlString: trimmed)
        if result.isValid, let normalized = result.url {
            return .valid(normalized.absoluteString)
        } else {
            return .invalid(result.message ?? "올바른 놀이터 HTTPS 주소를 입력하세요.")
        }
    }
}
