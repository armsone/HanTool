import AppKit
import ApplicationServices
import Combine

/// HTD 브라우저를 두 번 눌러 호출하는 보조키 종류.
enum BrowserDoubleTapModifier: String, CaseIterable, Identifiable {
    case off = "off"
    case command = "command"
    case shift = "shift"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .command:
            return "Command 두 번"
        case .shift:
            return "Shift 두 번"
        case .off:
            return "사용 안 함"
        }
    }
}

/// HTD 브라우저 호출용 전역 보조키 2회 연속 탭 제스처 감지기.
/// - 기본값은 Command 두 번(왼쪽 또는 오른쪽 단독), Shift 두 번으로 변경 가능.
/// - 기존 ⇧⌃⌥⌘B 조합 단축키를 건드리지 않으며 손쉬운 사용 권한 우회나 강제 요청을 하지 않음.
/// - NSEvent local/global .flagsChanged 및 .keyDown, .leftMouseDown 등을 감시하여 순수한 보조키 더블탭만 인식.
@MainActor
final class BrowserDoubleTapShortcut: ObservableObject {
    static let shared = BrowserDoubleTapShortcut()

    private let userDefaultsKey = "BrowserDoubleTapModifier"
    private let maxTapDuration: TimeInterval = 0.35
    private let maxTapInterval: TimeInterval = 0.35

    @Published var selectedModifier: BrowserDoubleTapModifier {
        didSet {
            UserDefaults.standard.set(selectedModifier.rawValue, forKey: userDefaultsKey)
            resetGesture()
        }
    }

    @Published private(set) var isAccessibilityTrusted: Bool = false

    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var localKeyMonitor: Any?
    private var globalKeyMonitor: Any?
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?

    private var activationObserver: NSObjectProtocol?

    // 제스처 상태 추적
    private enum GesturePhase {
        case idle
        case firstPressed(keyCode: UInt16, timestamp: TimeInterval)
        case firstReleased(keyCode: UInt16, pressTimestamp: TimeInterval, releaseTimestamp: TimeInterval)
        case secondPressed(keyCode: UInt16, firstPressTimestamp: TimeInterval, firstReleaseTimestamp: TimeInterval, secondPressTimestamp: TimeInterval)
    }

    private var phase: GesturePhase = .idle
    private var lastHandledEventTimestamp: TimeInterval = -1.0
    private var isStarted = false

    private init() {
        let saved = UserDefaults.standard.string(forKey: userDefaultsKey)
        self.selectedModifier = saved.flatMap(BrowserDoubleTapModifier.init(rawValue:)) ?? .command
        self.isAccessibilityTrusted = AXIsProcessTrusted()
    }

    func updateAccessibilityStatus() {
        isAccessibilityTrusted = AXIsProcessTrusted()
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        updateAccessibilityStatus()

        // 앱 활성화 시점에 권한 상태 갱신
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateAccessibilityStatus()
        }

        // 1. flagsChanged (보조키 누름/뗌 감지)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
        }

        // 2. keyDown (일반 키 입력, ⌘C 등 조합 키 누름 시 제스처 즉시 무효화)
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.resetGesture()
            return event
        }

        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] _ in
            self?.resetGesture()
        }

        // 3. 마우스 클릭 시 제스처 무효화
        let mouseMask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseMask) { [weak self] event in
            self?.resetGesture()
            return event
        }

        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseMask) { [weak self] _ in
            self?.resetGesture()
        }
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false

        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        if let m = localKeyMonitor { NSEvent.removeMonitor(m); localKeyMonitor = nil }
        if let m = globalKeyMonitor { NSEvent.removeMonitor(m); globalKeyMonitor = nil }
        if let m = localMouseMonitor { NSEvent.removeMonitor(m); localMouseMonitor = nil }
        if let m = globalMouseMonitor { NSEvent.removeMonitor(m); globalMouseMonitor = nil }

        if let obs = activationObserver {
            NotificationCenter.default.removeObserver(obs)
            activationObserver = nil
        }

        resetGesture()
    }

    func resetGesture() {
        phase = .idle
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        guard selectedModifier != .off else {
            resetGesture()
            return
        }

        // local/global 모니터가 동일 이벤트를 중복 처리하지 않도록 방지
        let timestamp = event.timestamp
        if timestamp == lastHandledEventTimestamp {
            return
        }
        lastHandledEventTimestamp = timestamp

        let keyCode = event.keyCode

        // 유효한 물리 키코드 확인:
        // Command: 54 (오른쪽 Command), 55 (왼쪽 Command)
        // Shift: 56 (왼쪽 Shift), 60 (오른쪽 Shift)
        let isValidKey: Bool
        let targetFlag: NSEvent.ModifierFlags

        switch selectedModifier {
        case .command:
            isValidKey = (keyCode == 54 || keyCode == 55)
            targetFlag = .command
        case .shift:
            isValidKey = (keyCode == 56 || keyCode == 60)
            targetFlag = .shift
        case .off:
            resetGesture()
            return
        }

        guard isValidKey else {
            // 다른 보조키(Option, Control, CapsLock 등)가 눌렸거나 다른 키코드면 시퀀스 무효화
            resetGesture()
            return
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isPressed = flags.contains(targetFlag)

        // 대상 보조키 이외에 다른 보조키(Option, Control 등)가 함께 켜져 있는지 확인
        // (단일 보조키 단독 조작만 유효)
        let nonTargetFlags = flags.subtracting(targetFlag)
        if !nonTargetFlags.isEmpty {
            resetGesture()
            return
        }

        switch phase {
        case .idle:
            if isPressed {
                phase = .firstPressed(keyCode: keyCode, timestamp: timestamp)
            }

        case .firstPressed(let firstCode, let pressTime):
            if !isPressed {
                if keyCode == firstCode {
                    let duration = timestamp - pressTime
                    if duration <= maxTapDuration {
                        phase = .firstReleased(keyCode: keyCode, pressTimestamp: pressTime, releaseTimestamp: timestamp)
                    } else {
                        // 너무 길게 누르고 있었음 (길게 누름 무효화)
                        resetGesture()
                    }
                } else {
                    // 다른 키코드 뗌 (예: 왼쪽 Command 누르고 오른쪽 Command 뗌 등)
                    resetGesture()
                }
            } else {
                // 이미 눌려있는 상태에서 또 다른 누름(예: 다른 쪽 동시 누름 등)
                resetGesture()
            }

        case .firstReleased(let firstCode, let pressTime1, let releaseTime1):
            if isPressed {
                if keyCode == firstCode {
                    let interval = timestamp - releaseTime1
                    if interval <= maxTapInterval {
                        phase = .secondPressed(
                            keyCode: keyCode,
                            firstPressTimestamp: pressTime1,
                            firstReleaseTimestamp: releaseTime1,
                            secondPressTimestamp: timestamp
                        )
                    } else {
                        // 1차 탭 뗌과 2차 탭 누름 사이 간격이 너무 긺 -> 새로운 1차 누름으로 취급
                        phase = .firstPressed(keyCode: keyCode, timestamp: timestamp)
                    }
                } else {
                    // 다른 물리키 누름 -> 새 1차 누름으로 시작
                    phase = .firstPressed(keyCode: keyCode, timestamp: timestamp)
                }
            } else {
                // 릴리즈 상태에서 알 수 없는 뗌 이벤트
                resetGesture()
            }

        case .secondPressed(let secondCode, _, _, let pressTime2):
            if !isPressed {
                if keyCode == secondCode {
                    let duration = timestamp - pressTime2
                    // 2차 누름 지속시간 확인
                    if duration <= maxTapDuration {
                        // 2회 완전한 누름+뗌 완료!
                        // 3연타 방지 및 단일 실행 보장을 위해 먼저 초기화 후 실행
                        resetGesture()
                        triggerBrowserOpen()
                    } else {
                        resetGesture()
                    }
                } else {
                    resetGesture()
                }
            } else {
                resetGesture()
            }
        }
    }

    private func triggerBrowserOpen() {
        EmbeddedBrowser.open()
    }
}
