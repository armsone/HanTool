import Foundation
import ServiceManagement

/// SMAppService.loginItem 기반 '잠자기에서 깨어나면 HTT 실행' 백그라운드 헬퍼 관리자.
/// - /Applications에 설치된 경우에만 등록한다.
/// - 최초 실행 시 기본값(켜짐)으로 1회 등록(이미 등록/승인대기 시 건너뜀).
/// - 사용자가 설정에서 명시적으로 바꿀 때만 register/unregister를 호출한다.
@MainActor
final class WakeLaunchManager {
    static let helperIdentifier = "com.local.screentranslator.wake-helper"
    private static let preferenceKey = "WakeLaunchEnabledPreference"
    private let service = SMAppService.loginItem(identifier: WakeLaunchManager.helperIdentifier)
    private(set) var lastError: String?

    var isInstalledInApplications: Bool {
        Bundle.main.bundleURL.standardizedFileURL.path.hasPrefix("/Applications/")
    }

    var status: SMAppService.Status { service.status }

    /// 사용자의 명시적 선택 (설정된 적 없으면 기본값 true)
    var isPreferenceEnabled: Bool {
        if let stored = UserDefaults.standard.object(forKey: Self.preferenceKey) as? Bool {
            return stored
        }
        return true
    }

    /// 사용자의 마지막 명시적 선택(최초 실행 전에는 nil)
    var preference: Bool? {
        UserDefaults.standard.object(forKey: Self.preferenceKey) as? Bool
    }

    var statusDescription: String {
        if !isInstalledInApplications {
            return "/Applications에 설치된 앱에서만 사용할 수 있습니다"
        }
        switch service.status {
        case .enabled: return "켜짐"
        case .requiresApproval: return "승인 필요: 시스템 설정 > 일반 > 로그인 항목에서 허용하세요"
        case .notRegistered: return "꺼짐"
        case .notFound: return "등록 정보를 찾을 수 없음"
        @unknown default: return "알 수 없는 상태"
        }
    }

    /// 실행 시 1회 호출. 최초 실행이면 기본값(켜짐)으로 한 번만 등록한다.
    func applyInitialDefaultIfNeeded() {
        guard isInstalledInApplications else { return }
        guard preference == nil else { return }
        UserDefaults.standard.set(true, forKey: Self.preferenceKey)
        UserDefaults.standard.synchronize()
        if service.status != .enabled && service.status != .requiresApproval {
            register()
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard isInstalledInApplications else { return }
        UserDefaults.standard.set(enabled, forKey: Self.preferenceKey)
        UserDefaults.standard.synchronize()
        if enabled {
            if service.status != .enabled {
                register()
            }
        } else {
            if service.status != .notRegistered {
                unregister()
            }
        }
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private func register() {
        do {
            try service.register()
            lastError = nil
        } catch {
            lastError = "잠자기 깨어남 헬퍼 등록 실패: \(error.localizedDescription)"
        }
    }

    private func unregister() {
        do {
            try service.unregister()
            lastError = nil
        } catch {
            lastError = "잠자기 깨어남 헬퍼 해제 실패: \(error.localizedDescription)"
        }
    }
}
