import AppKit
import ApplicationServices
import Combine

/// 클립보드 호출용 전역 단축키 감지기.
/// - 단축키: Shift 누른 채 + 동일 Command 2회 탭 (Down → Up → 두 번째 Down 즉시 show).
/// - 기존 BrowserDoubleTapShortcut(브라우저 더블탭)과 완전히 독립된 상태 머신으로 동작.
/// - 일반 키 입력(.keyDown), 마우스 클릭, 또는 Option/Control 등의 다른 보조키 개입 시 즉시 시퀀스 초기화.
/// - 두 번째 Command Down 감지 즉시 클립보드 패널을 띄우고 포커스 부여 (Shift/Command 잔류 상태에서도 팝업 조작 가능).
@MainActor
public final class ClipboardHistoryShortcut: ObservableObject {
    public static let shared = ClipboardHistoryShortcut()

    private let maxTapDuration: TimeInterval = 0.35
    private let maxTapInterval: TimeInterval = 0.35

    @Published public private(set) var isEnabled: Bool = true
    @Published public private(set) var isAccessibilityTrusted: Bool = false

    private enum Phase {
        case idle
        case firstPressed(keyCode: UInt16, timestamp: TimeInterval)
        case firstReleased(keyCode: UInt16, pressTimestamp: TimeInterval, releaseTimestamp: TimeInterval)
        case secondTriggered(keyCode: UInt16)
    }

    private var phase: Phase = .idle
    private var lastHandledEventTimestamp: TimeInterval = 0

    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var localKeyMonitor: Any?
    private var globalKeyMonitor: Any?
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var activationObserver: NSObjectProtocol?

    private var isStarted = false

    private init() {
        checkAccessibility()
    }

    public func checkAccessibility() {
        isAccessibilityTrusted = AXIsProcessTrusted()
    }

    public func start() {
        guard !isStarted else { return }
        isStarted = true
        checkAccessibility()

        // 앱 활성화 시 권한 상태 재확인
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkAccessibility()
            }
        }

        // 1. flagsChanged (Shift, Command 등 보조키 상태 변화 감시)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
        }

        // 2. keyDown (일반 문자 키 입력 발생 시 즉시 무효화)
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.resetGesture()
            return event
        }

        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] _ in
            self?.resetGesture()
        }

        // 3. 마우스 클릭 발생 시 즉시 무효화
        let mouseMask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseMask) { [weak self] event in
            self?.resetGesture()
            return event
        }

        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseMask) { [weak self] _ in
            self?.resetGesture()
        }
    }

    public func stop() {
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

    public func resetGesture() {
        phase = .idle
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        guard isEnabled else {
            resetGesture()
            return
        }

        let timestamp = event.timestamp
        if timestamp == lastHandledEventTimestamp {
            return
        }
        lastHandledEventTimestamp = timestamp

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        let keyCode = event.keyCode

        // 유효한 Command 물리 키코드:
        // 54: 오른쪽 Command, 55: 왼쪽 Command
        // 유효한 Shift 물리 키코드:
        // 56: 왼쪽 Shift, 60: 오른쪽 Shift
        let isCommandKey = (keyCode == 54 || keyCode == 55)
        let isShiftKey = (keyCode == 56 || keyCode == 60)

        // 다른 보조키(Option, Control, CapsLock 등)가 눌렸으면 즉시 무효화
        let nonTargetFlags = flags.subtracting([.shift, .command])
        if !nonTargetFlags.isEmpty {
            resetGesture()
            return
        }

        // 제스처가 유효하려면 Shift가 기본적으로 눌려 있어야 함
        guard flags.contains(.shift) else {
            // Shift가 떼어지면 진행 중이던 제스처 무효화
            resetGesture()
            return
        }

        // Command 키 누름 여부
        let isCommandPressed = flags.contains(.command)

        guard isCommandKey else {
            // Shift 키 자체의 누름/뗌 이벤트거나 다른 키라면 시퀀스 상태 유지 또는 무효화
            if !isShiftKey {
                resetGesture()
            }
            return
        }

        switch phase {
        case .idle:
            if isCommandPressed {
                // Shift 유지 상태에서 동일 Command 최초 누름 (Down 1)
                phase = .firstPressed(keyCode: keyCode, timestamp: timestamp)
            }

        case .firstPressed(let firstCode, let pressTime):
            if !isCommandPressed {
                // Command 뗌 (Up 1)
                if keyCode == firstCode {
                    let duration = timestamp - pressTime
                    if duration <= maxTapDuration {
                        phase = .firstReleased(keyCode: keyCode, pressTimestamp: pressTime, releaseTimestamp: timestamp)
                    } else {
                        // 첫 번째 누름 유지 시간이 너무 길었음
                        resetGesture()
                    }
                } else {
                    resetGesture()
                }
            } else {
                resetGesture()
            }

        case .firstReleased(let firstCode, _, let releaseTime):
            if isCommandPressed {
                // 첫 뗌 이후 동일 Command 두 번째 누름 (Down 2) 즉시 show & focus
                if keyCode == firstCode {
                    let interval = timestamp - releaseTime
                    if interval <= maxTapInterval {
                        phase = .secondTriggered(keyCode: keyCode)
                        // HanTool 활성화 전에 origin target을 즉시 캡처
                        ClipboardPasteCoordinator.shared.captureOriginTarget()
                        ClipboardHistoryPanelController.shared.showAndFocus()
                    } else {
                        // 간격이 너무 길어 새 첫 번째 누름으로 전환
                        phase = .firstPressed(keyCode: keyCode, timestamp: timestamp)
                    }
                } else {
                    resetGesture()
                }
            }

        case .secondTriggered(let secondCode):
            if !isCommandPressed {
                // 두 번째 Command 뗌 (Up 2) -> 중복 show 없이 제스처 초기화
                if keyCode == secondCode {
                    resetGesture()
                } else {
                    resetGesture()
                }
            }
        }
    }
}
