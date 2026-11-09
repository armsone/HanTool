import AppKit

final class WakeHelperDelegate: NSObject, NSApplicationDelegate {
    private let parentBundleID = "com.local.screentranslator"
    private let preferenceKey = "WakeLaunchEnabledPreference"
    private var isLaunching = false
    private var wakeObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleWake()
        }
    }

    private func handleWake() {
        // 1. 잠자기 깨어남 시점에만 부모 앱 최신 설정 확인
        CFPreferencesAppSynchronize(parentBundleID as CFString)
        let prefValue = CFPreferencesCopyAppValue(preferenceKey as CFString, parentBundleID as CFString)
        if let boolValue = prefValue as? Bool, !boolValue {
            return
        }

        // 2. 헬퍼 번들 URL에서 4단계 상위 디렉터리로 이동하여 HTT.app 위치 도출
        var parentURL = Bundle.main.bundleURL.standardizedFileURL
        for _ in 0..<4 {
            parentURL.deleteLastPathComponent()
        }
        parentURL = parentURL.standardizedFileURL

        // 3. 부모 번들 ID 검증, /Applications 경로 검증, 실행 파일 존재 확인
        guard let parentBundle = Bundle(url: parentURL),
              parentBundle.bundleIdentifier == parentBundleID,
              parentURL.path.hasPrefix("/Applications/"),
              let executableURL = parentBundle.executableURL,
              FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            return
        }

        // 4. 이미 실행 중이거나 실행 진행 중이면 아무 작업도 하지 않음
        let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: parentBundleID)
        guard runningApps.isEmpty, !isLaunching else {
            return
        }

        // 5. 백그라운드에서 조용히 실행
        isLaunching = true
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.createsNewApplicationInstance = false

        NSWorkspace.shared.openApplication(at: parentURL, configuration: config) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.isLaunching = false
            }
        }
    }
}

let app = NSApplication.shared
let delegate = WakeHelperDelegate()
app.delegate = delegate
app.run()
