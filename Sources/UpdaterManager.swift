import AppKit
import Sparkle

/// Sparkle 2 표준 업데이터(SPUStandardUpdaterController) 래퍼.
/// - 빌드 시 Resources/UpdatePublicKey.txt(공개키만)를 Info.plist의 SUPublicEDKey로 넣는다.
///   공개키나 HTTPS 피드 주소가 없으면 업데이터를 시작하지 않고 그 이유를 그대로 표시한다
///   (무결성 검증 없이 업데이트하지 않음).
/// - 피드가 아직 게시되지 않아(404 등) 확인에 실패하면 '업데이트 없음'이 아니라 오류로 기록한다.
@MainActor
final class UpdaterManager: NSObject, SPUUpdaterDelegate {
    private var controller: SPUStandardUpdaterController?
    private(set) var statusDescription = "초기화 전"
    private(set) var lastCheckResult: String?

    var isAvailable: Bool { controller != nil }

    var canCheckForUpdates: Bool {
        controller?.updater.canCheckForUpdates ?? false
    }

    var automaticallyUpdates: Bool {
        guard let updater = controller?.updater else { return false }
        return updater.automaticallyChecksForUpdates && updater.automaticallyDownloadsUpdates
    }

    func start() {
        let info = Bundle.main.infoDictionary ?? [:]
        let publicKey = (info["SUPublicEDKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let feed = (info["SUFeedURL"] as? String) ?? ""

        guard !publicKey.isEmpty else {
            statusDescription = "비활성: 업데이트 서명 공개키가 빌드에 포함되지 않았습니다"
            return
        }
        guard let url = URL(string: feed), url.scheme == "https" else {
            statusDescription = "비활성: HTTPS 업데이트 피드 주소가 없습니다"
            return
        }

        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        do {
            try controller.updater.start()
            self.controller = controller
            statusDescription = "사용 가능"
        } catch {
            statusDescription = "업데이터 시작 실패: \(error.localizedDescription)"
        }
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    func setAutomaticallyUpdates(_ enabled: Bool) {
        guard let updater = controller?.updater else { return }
        updater.automaticallyChecksForUpdates = enabled
        updater.automaticallyDownloadsUpdates = enabled
    }

    // MARK: - SPUUpdaterDelegate

    /// 업데이트가 내려받아져 설치(종료 시 설치 포함)될 수 있는 상태인지. AppDelegate의 종료 확인이 사용한다.
    private(set) var hasPendingInstall = false

    private var pendingInstall: (() -> Void)?
    private var terminationObserver: NSObjectProtocol?

    /// 업데이트 설치 전에 HTT 안의 브라우저가 실행 중이면, 받는 중인 파일을 잃지 않도록
    /// 브라우저가 종료될 때까지 설치를 미룬다. 브라우저를 대신 종료하지 않는다.
    nonisolated func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        MainActor.assumeIsolated {
            // 브라우저가 실행 중이면 항상 보류한다. 이미 보류 중이면 최신 설치 핸들러 하나만 남기고(안내·감시는 한 번만) 계속 보류한다.
            guard EmbeddedBrowser.isEmbeddedRunning() else {
                // 보류 중이던 이전 핸들러는 이번 호출이 대신하므로 버린다(설치가 두 번 시작되지 않게).
                if let observer = terminationObserver { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
                terminationObserver = nil
                pendingInstall = nil
                return false
            }
            if pendingInstall != nil {
                pendingInstall = installHandler
                return true
            }
            pendingInstall = installHandler
            terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.pendingInstall != nil, !EmbeddedBrowser.isEmbeddedRunning() else { return }
                    self.finishPostponedInstall()
                }
            }
            let alert = NSAlert()
            alert.messageText = "한툴 브라우저를 종료하면 업데이트를 이어서 설치합니다"
            alert.informativeText = "한툴 브라우저가 실행 중이라 설치를 잠시 미뤘습니다. 받는 중인 파일이 있으면 끝난 뒤 브라우저를 종료해 주세요. 브라우저는 자동으로 종료하지 않습니다."
            alert.addButton(withTitle: "확인")
            alert.runModal()
            // 안내를 보는 사이 HTD가 이미 종료됐다면 바로 이어서 설치한다.
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    if !EmbeddedBrowser.isEmbeddedRunning() { self?.finishPostponedInstall() }
                }
            }
            return true
        }
    }

    /// 자동 다운로드된 업데이트가 '종료 시 설치'로 예약될 때. 직접 설치를 맡지 않고(false) Sparkle 일정은 그대로 둔다.
    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        MainActor.assumeIsolated { hasPendingInstall = true }
        return false
    }

    nonisolated func updater(_ updater: SPUUpdater, didExtractUpdate item: SUAppcastItem) {
        MainActor.assumeIsolated { hasPendingInstall = true }
    }

    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        MainActor.assumeIsolated { hasPendingInstall = true }
    }

    private func finishPostponedInstall() {
        if let observer = terminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        terminationObserver = nil
        let handler = pendingInstall
        pendingInstall = nil
        handler?()
    }

    nonisolated func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        // 사용자가 설치를 취소한 경우에만 예약을 해제한다. '최신 버전' 등 다른 결과는 이미 예약된 설치를 취소하지 않는다.
        if let error = error as NSError?, error.domain == SUSparkleErrorDomain, error.code == Int(SUError.installationCanceledError.rawValue) {
            MainActor.assumeIsolated { self.hasPendingInstall = false }
        }
        let message: String
        if let error = error as NSError? {
            if error.domain == SUSparkleErrorDomain && error.code == Int(SUError.noUpdateError.rawValue) {
                message = "최신 버전입니다"
            } else {
                message = "확인 실패: \(error.localizedDescription)"
            }
        } else {
            message = "확인 완료"
        }
        MainActor.assumeIsolated {
            self.lastCheckResult = message
        }
    }
}
