import AppKit
import ApplicationServices
import Carbon
import Combine

/// 클립보드 패널 열기 직전의 활성 앱·창·입력위치 원본 상태 정보.
public struct PasteTargetOrigin: Equatable {
    public let processIdentifier: pid_t
    public let bundleIdentifier: String?
    public let appName: String?
    public let windowElement: AXUIElement?
    public let focusedElement: AXUIElement?
    public let isSecureInput: Bool
    public let caretRange: CFRange?
    public let capturedAt: Date

    public init(
        processIdentifier: pid_t,
        bundleIdentifier: String?,
        appName: String?,
        windowElement: AXUIElement?,
        focusedElement: AXUIElement?,
        isSecureInput: Bool,
        caretRange: CFRange? = nil,
        capturedAt: Date = Date()
    ) {
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.windowElement = windowElement
        self.focusedElement = focusedElement
        self.isSecureInput = isSecureInput
        self.caretRange = caretRange
        self.capturedAt = capturedAt
    }

    public static func == (lhs: PasteTargetOrigin, rhs: PasteTargetOrigin) -> Bool {
        return lhs.processIdentifier == rhs.processIdentifier &&
               lhs.bundleIdentifier == rhs.bundleIdentifier &&
               lhs.isSecureInput == rhs.isSecureInput &&
               lhs.capturedAt == rhs.capturedAt
    }
}

/// 자동 붙여넣기 및 포커스 복원 코디네이터.
/// - 클립보드 패널 열기 직전 origin을 캡처하고, 확정 시 원래 앱·창·입력위치로 포커스를 복원해 ⌘V를 자동 전송.
/// - 대상 소멸/바뀜/포커스 복원 실패/보안 입력 시 다른 앱에 붙여넣지 않고 안전하게 중단하며 상태 기록.
/// - 텍스트 내용이나 비밀번호 값을 절대 조회하거나 로그에 남기지 않음.
@MainActor
public final class ClipboardPasteCoordinator: ObservableObject {
    public static let shared = ClipboardPasteCoordinator()

    public enum PasteStatus: Equatable {
        case idle
        case copiedOnly(reason: SkipReason)
        case pasteScheduled(pid: pid_t, appName: String?)
        case pasteCompleted(pid: pid_t)
        case pasteFailed(reason: FailureReason)
    }

    public enum SkipReason: Equatable {
        case accessibilityPermissionDenied
        case targetTerminated
        case secureInputDetected
        case noTargetCaptured
        case clipboardChanged
        case targetNotEditable
        case modifiersHeld
    }

    public enum FailureReason: Equatable {
        case targetAppNotActive(expectedPID: pid_t, actualPID: pid_t?)
        case eventPostFailed
    }

    @Published public private(set) var lastStatus: PasteStatus = .idle
    @Published public private(set) var lastStatusMessage: String = ""

    private var pendingTarget: PasteTargetOrigin?
    /// 진행 중 붙여넣기 시도의 토큰. 선택 확정은 새 토큰을 발급하고, Escape/바깥 클릭 취소만 토큰을 무효화한다.
    private var pasteGeneration = 0

    private init() {}

    // MARK: - Origin Target Capture

    /// 클립보드 창이 포커스를 가져가기 직전에 호출되어 원본 대상 앱·창·엘리먼트를 바인딩.
    public func captureOriginTarget() {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            pendingTarget = nil
            return
        }

        let pid = frontApp.processIdentifier
        guard pid > 0 else {
            pendingTarget = nil
            return
        }

        let appName = frontApp.localizedName
        let bundleID = frontApp.bundleIdentifier

        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.25)
        let windowElement = copyAttributeElement(element: appElement, attribute: kAXFocusedWindowAttribute as CFString)
        let focusedElement = copyAttributeElement(element: appElement, attribute: kAXFocusedUIElementAttribute as CFString)
        let isSecure = checkIsSecure(element: focusedElement)

        self.pendingTarget = PasteTargetOrigin(
            processIdentifier: pid,
            bundleIdentifier: bundleID,
            appName: appName,
            windowElement: windowElement,
            focusedElement: focusedElement,
            isSecureInput: isSecure,
            caretRange: focusedElement.flatMap { copyCaretRange($0) },
            capturedAt: Date()
        )
    }

    /// 아직 캡처되지 않은 경우에만 현재 활성 앱을 캡처.
    public func captureOriginTargetIfNeeded() {
        if pendingTarget == nil {
            captureOriginTarget()
        }
    }

    /// 캡처된 대상을 1회 소비(once-consume)하여 반환.
    public func consumePendingTarget() -> PasteTargetOrigin? {
        let target = pendingTarget
        pendingTarget = nil
        return target
    }

    /// 보류 중인 대상을 명시적으로 해제 (ESC 취소 등).
    public func clearPendingTarget() {
        pendingTarget = nil
    }

    /// 취소(Escape/바깥 클릭): 대기 중인 대상과 아직 실행 전인 붙여넣기 재시도를 모두 무효화. 선택 확정 경로는 호출하지 않는다.
    public func cancelPendingPaste() {
        pendingTarget = nil
        pasteGeneration &+= 1
    }

    /// Escape 취소 후 원래 앱·창·입력 위치로 포커스만 복원(복사·붙여넣기 없음). 복원 불가 시 아무것도 하지 않는다.
    public func restoreOriginFocus(_ target: PasteTargetOrigin) {
        guard AXIsProcessTrusted(),
              let app = NSRunningApplication(processIdentifier: target.processIdentifier), !app.isTerminated else { return }
        NSApp.yieldActivation(to: app)
        app.activate(from: NSRunningApplication.current, options: [])
        restoreFocus(target)
    }

    // MARK: - Auto-Paste Execution

    /// 전송 직전 대상 검증 입력값 (AX 값 본문은 포함하지 않음).
    struct GuardSnapshot {
        var trusted = true
        var terminated = false
        var frontPID: pid_t?
        var targetPID: pid_t
        var windowMatches = false
        var elementMatches = false
        var secure = false
        var editable = false
        var caretMatches = true
        var changeCountMatches = true
        var modifiersHeld = false
    }

    enum GuardDecision: Equatable {
        case proceed
        case retry
        case skip(SkipReason)
        case fail(FailureReason)
    }

    /// 즉시 중단(hard) 조건은 retry 없이 fail-closed, 포커스 복원 지연/수정키 누름만 bounded retry.
    static func decide(_ s: GuardSnapshot) -> GuardDecision {
        if !s.trusted { return .skip(.accessibilityPermissionDenied) }
        if s.terminated { return .skip(.targetTerminated) }
        if !s.changeCountMatches { return .skip(.clipboardChanged) }
        if s.secure { return .skip(.secureInputDetected) }
        if s.frontPID != s.targetPID || !s.windowMatches || !s.elementMatches || !s.caretMatches {
            return .retry
        }
        if !s.editable { return .skip(.targetNotEditable) }
        if s.modifiersHeld { return .retry }
        return .proceed
    }

    private static let maxPasteAttempts = 20
    private static let pasteAttemptInterval: TimeInterval = 0.05

    /// 항목 선택 확정 시 캡처된 대상에게 포커스를 복원하고 1회성 자동 붙여넣기를 수행.
    /// expectedChangeCount: 자기 재복사 직후의 pasteboard changeCount. 대기 중 외부 복사가 끼면 붙여넣지 않음.
    public func performAutoPaste(target: PasteTargetOrigin, expectedChangeCount: Int, for item: ClipboardItem) {
        guard AXIsProcessTrusted() else {
            setSkipped(.accessibilityPermissionDenied)
            return
        }
        guard let targetApp = NSRunningApplication(processIdentifier: target.processIdentifier),
              !targetApp.isTerminated else {
            setSkipped(.targetTerminated)
            return
        }
        // 창/입력요소를 캡처하지 못한 대상에는 PID만으로 붙여넣지 않음
        guard target.windowElement != nil, target.focusedElement != nil else {
            setSkipped(.noTargetCaptured)
            return
        }
        if target.isSecureInput || IsSecureEventInputEnabled() {
            setSkipped(.secureInputDetected)
            return
        }

        NSApp.yieldActivation(to: targetApp)
        targetApp.activate(from: NSRunningApplication.current, options: [])
        lastStatus = .pasteScheduled(pid: target.processIdentifier, appName: target.appName)
        pasteGeneration &+= 1
        attemptPaste(target: target, expectedChangeCount: expectedChangeCount, attempt: 0, restored: false, generation: pasteGeneration)
    }

    private func attemptPaste(target: PasteTargetOrigin, expectedChangeCount: Int, attempt: Int, restored: Bool, generation: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pasteAttemptInterval) { [weak self] in
            guard let self = self, generation == self.pasteGeneration else { return }
            let front = NSWorkspace.shared.frontmostApplication
            var didRestore = restored

            // 대상 앱이 실제로 활성화된 뒤 창/입력요소/캐럿을 1회 복원
            if !didRestore, front?.processIdentifier == target.processIdentifier {
                self.restoreFocus(target)
                didRestore = true
            }

            let snap = self.makeSnapshot(target: target, front: front, expectedChangeCount: expectedChangeCount)
            switch Self.decide(snap) {
            case .proceed:
                switch self.postPasteEventToPid(target.processIdentifier, expectedChangeCount: expectedChangeCount) {
                case .clipboardChanged:
                    self.setSkipped(.clipboardChanged)
                case .posted:
                    self.lastStatus = .pasteCompleted(pid: target.processIdentifier)
                    self.lastStatusMessage = "붙여넣기 완료"
                case .failed:
                    self.lastStatus = .pasteFailed(reason: .eventPostFailed)
                    self.lastStatusMessage = "붙여넣기 이벤트 전송 실패 (클립보드 복사 완료)"
                }
            case .skip(let reason):
                self.setSkipped(reason)
            case .fail(let reason):
                self.lastStatus = .pasteFailed(reason: reason)
                self.lastStatusMessage = "붙여넣기를 중단했습니다. (클립보드 복사 완료)"
            case .retry:
                if attempt + 1 < Self.maxPasteAttempts {
                    self.attemptPaste(target: target, expectedChangeCount: expectedChangeCount, attempt: attempt + 1, restored: didRestore, generation: generation)
                } else if snap.frontPID != target.processIdentifier || !snap.windowMatches || !snap.elementMatches || !snap.caretMatches {
                    self.lastStatus = .pasteFailed(reason: .targetAppNotActive(expectedPID: target.processIdentifier, actualPID: snap.frontPID))
                    self.lastStatusMessage = "대상 입력 위치 복원 실패: 붙여넣지 않고 중단했습니다. (클립보드 복사 완료)"
                } else {
                    self.setSkipped(.modifiersHeld)
                }
            }
        }
    }

    private func setSkipped(_ reason: SkipReason) {
        lastStatus = .copiedOnly(reason: reason)
        switch reason {
        case .accessibilityPermissionDenied: lastStatusMessage = "손쉬운 사용 권한이 필요합니다. (클립보드 복사 완료)"
        case .targetTerminated: lastStatusMessage = "대상 앱이 종료되었습니다. (클립보드 복사 완료)"
        case .secureInputDetected: lastStatusMessage = "보안 입력 필드에서는 자동 붙여넣기가 제한됩니다. (클립보드 복사 완료)"
        case .noTargetCaptured: lastStatusMessage = "붙여넣을 입력 위치를 확인하지 못했습니다. (클립보드 복사 완료)"
        case .clipboardChanged: lastStatusMessage = "클립보드가 바뀌어 붙여넣지 않았습니다."
        case .targetNotEditable: lastStatusMessage = "편집할 수 없는 위치라 붙여넣지 않았습니다. (클립보드 복사 완료)"
        case .modifiersHeld: lastStatusMessage = "수정키가 눌려 있어 붙여넣지 않았습니다. (클립보드 복사 완료)"
        }
    }

    private func restoreFocus(_ target: PasteTargetOrigin) {
        if let win = target.windowElement {
            AXUIElementPerformAction(win, kAXRaiseAction as CFString)
        }
        if let focused = target.focusedElement {
            AXUIElementSetAttributeValue(focused, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            if var range = target.caretRange, let value = AXValueCreate(.cfRange, &range) {
                AXUIElementSetAttributeValue(focused, kAXSelectedTextRangeAttribute as CFString, value)
            }
        }
    }

    private func makeSnapshot(target: PasteTargetOrigin, front: NSRunningApplication?, expectedChangeCount: Int) -> GuardSnapshot {
        var s = GuardSnapshot(targetPID: target.processIdentifier)
        s.trusted = AXIsProcessTrusted()
        s.terminated = NSRunningApplication(processIdentifier: target.processIdentifier)?.isTerminated ?? true
        s.frontPID = front?.processIdentifier
        s.modifiersHeld = !CGEventSource.flagsState(.combinedSessionState)
            .isDisjoint(with: [.maskShift, .maskAlternate, .maskControl])
        s.secure = IsSecureEventInputEnabled()

        let app = AXUIElementCreateApplication(target.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.25)
        let win = copyAttributeElement(element: app, attribute: kAXFocusedWindowAttribute as CFString)
        let focused = copyAttributeElement(element: app, attribute: kAXFocusedUIElementAttribute as CFString)
        if let win = win, let want = target.windowElement { s.windowMatches = CFEqual(win, want) }
        if let focused = focused, let want = target.focusedElement {
            s.elementMatches = CFEqual(focused, want)
            if s.elementMatches {
                if checkIsSecure(element: focused) { s.secure = true }
                s.editable = isEditable(focused)
                if let wantRange = target.caretRange {
                    if let now = copyCaretRange(focused) {
                        s.caretMatches = now.location == wantRange.location && now.length == wantRange.length
                    } else {
                        s.caretMatches = false
                    }
                }
            }
        }
        // 블로킹될 수 있는 AX 질의가 모두 끝난 뒤 판정 (질의 중 외부 복사 포착)
        s.changeCountMatches = ClipboardHistoryStore.shared.pasteboardChangeCount == expectedChangeCount
        return s
    }

    // MARK: - Synthetic Paste Event

    private enum PostResult { case posted, clipboardChanged, failed }

    private func postPasteEventToPid(_ pid: pid_t, expectedChangeCount: Int) -> PostResult {
        // privateState: 물리 수정키 상태가 합성 이벤트에 섞이지 않도록 격리, 플래그는 ⌘ 하나로 명시
        let source = CGEventSource(stateID: .privateState)
        // 0x09: kVK_ANSI_V
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) else {
            return .failed
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        // 전송 직전 최종 재확인: 이후 외부 복사가 끼어들 틈 없이 바로 post (불일치 시 덮어쓰기/재시도 없음)
        guard ClipboardHistoryStore.shared.pasteboardChangeCount == expectedChangeCount else { return .clipboardChanged }
        keyDown.postToPid(pid)
        keyUp.postToPid(pid)
        return .posted
    }

    // MARK: - AX Helpers (No Text Value Query)

    private func copyAttributeString(element: AXUIElement, attribute: CFString) -> String? {
        var valueRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &valueRef)
        guard result == .success, let val = valueRef else { return nil }
        return val as? String
    }

    private func copyAttributeElement(element: AXUIElement, attribute: CFString) -> AXUIElement? {
        var valueRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &valueRef)
        guard result == .success, let val = valueRef else { return nil }
        if CFGetTypeID(val) == AXUIElementGetTypeID() {
            return (val as! AXUIElement)
        }
        return nil
    }

    /// 선택 범위(위치/길이)만 조회. 텍스트 값은 읽지 않음.
    private func copyCaretRange(_ element: AXUIElement) -> CFRange? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &ref) == .success,
              let val = ref, CFGetTypeID(val) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(val as! AXValue, .cfRange, &range) else { return nil }
        return range
    }

    /// 값 자체를 읽지 않고 settable 여부로 편집 가능 판단.
    private func isEditable(_ element: AXUIElement) -> Bool {
        for attr in [kAXValueAttribute, kAXSelectedTextAttribute] {
            var settable: DarwinBoolean = false
            if AXUIElementIsAttributeSettable(element, attr as CFString, &settable) == .success, settable.boolValue {
                return true
            }
        }
        return false
    }

    private func checkIsSecure(element: AXUIElement?) -> Bool {
        if IsSecureEventInputEnabled() {
            return true
        }
        guard let element = element else { return false }
        if let subrole = copyAttributeString(element: element, attribute: kAXSubroleAttribute as CFString),
           subrole == "AXSecureTextField" {
            return true
        }
        if let role = copyAttributeString(element: element, attribute: kAXRoleAttribute as CFString),
           role == "AXSecureTextField" {
            return true
        }
        return false
    }
}
