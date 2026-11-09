import AppKit
import Carbon
import Combine
import OSLog

@MainActor
final class AppInputLanguageController {
    private let store: AppInputLanguageStore
    private var cancellables = Set<AnyCancellable>()
    private var workspaceObserver: NSObjectProtocol?
    private var inputSourceObserver: NSObjectProtocol?
    private var pendingSwitchTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.local.screentranslator", category: "AppInputLanguage")

    /// Settling delay allowing window manager focus transition and Electron/Chromium text-input client readiness.
    private static let activationSettlingDelayNanoseconds: UInt64 = 120_000_000 // 120ms

    /// Poll interval and overall cap (from activation) while waiting for the target app's focused element.
    private static let readinessPollNanoseconds: UInt64 = 60_000_000 // 60ms
    private static let readinessDeadlineSeconds: TimeInterval = 0.8
    /// Short pause after the synchronous AX query so pending main-queue cancellations run before the guards are repeated.
    private static let recheckNanoseconds: UInt64 = 10_000_000 // 10ms

    private(set) var isStarted: Bool = false
    private(set) var isSuspended: Bool = false

    init(store: AppInputLanguageStore) {
        self.store = store

        store.$isEnabled
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in
                guard let self else { return }
                if enabled {
                    guard self.isStarted, !self.isSuspended else { return }
                    Task { @MainActor [weak self] in
                        self?.applyToCurrentFrontmostApp()
                    }
                } else {
                    self.cancelPendingSwitch()
                }
            }
            .store(in: &cancellables)
    }

    deinit {
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
        }
        if let inputSourceObserver {
            DistributedNotificationCenter.default().removeObserver(inputSourceObserver)
        }
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true

        if workspaceObserver == nil {
            workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                    return
                }
                Task { @MainActor in
                    self?.handleApplicationActivated(app)
                }
            }
        }

        if inputSourceObserver == nil {
            inputSourceObserver = DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    // Manual user switch detected during pending transition; cancel delayed switch to prevent override
                    self.cancelPendingSwitch()
                }
            }
        }

        if !isSuspended && store.isEnabled {
            applyToCurrentFrontmostApp()
        }
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        cancelPendingSwitch()

        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
            self.workspaceObserver = nil
        }
        if let inputSourceObserver {
            DistributedNotificationCenter.default().removeObserver(inputSourceObserver)
            self.inputSourceObserver = nil
        }
    }

    func setSuspended(_ suspended: Bool) {
        guard isSuspended != suspended else { return }
        isSuspended = suspended
        if suspended {
            cancelPendingSwitch()
        } else if isStarted && store.isEnabled {
            applyToCurrentFrontmostApp()
        }
    }

    func cancelPendingSwitch() {
        pendingSwitchTask?.cancel()
        pendingSwitchTask = nil
    }

    private func applyToCurrentFrontmostApp() {
        guard isStarted, !isSuspended, store.isEnabled else { return }
        guard let frontmost = NSWorkspace.shared.frontmostApplication else { return }
        handleApplicationActivated(frontmost)
    }

    private func handleApplicationActivated(_ app: NSRunningApplication) {
        cancelPendingSwitch()

        guard isStarted, !isSuspended, store.isEnabled else { return }
        guard let bundleID = app.bundleIdentifier else { return }
        guard let rule = store.rule(for: bundleID) else { return }

        let targetPID = app.processIdentifier
        let targetBundleID = bundleID
        let expectedSourceID = rule.inputSourceID
        let scheduledAt = ProcessInfo.processInfo.systemUptime

        // Fast-path: if the target source is already active, do not schedule a switch or introduce unnecessary work.
        if let activeID = Self.currentInputSourceID(), activeID == expectedSourceID {
            return
        }

        pendingSwitchTask = Task { @MainActor [weak self] in
            // Bounded delay allowing Electron / multi-process window keying and text-input client readiness
            let deadline = scheduledAt + Self.readinessDeadlineSeconds
            var attempt = 0
            var readinessVerified = false
            while true {
                try? await Task.sleep(nanoseconds: attempt == 0
                    ? Self.activationSettlingDelayNanoseconds
                    : (readinessVerified ? Self.recheckNanoseconds : Self.readinessPollNanoseconds))
                attempt += 1
                guard !Task.isCancelled, let self else { return }

                guard self.isStarted, !self.isSuspended, self.store.isEnabled else { return }

                // Re-check frontmost process, bundle, and active state
                guard let currentFront = NSWorkspace.shared.frontmostApplication,
                      currentFront.processIdentifier == targetPID,
                      currentFront.bundleIdentifier == targetBundleID,
                      currentFront.isActive else {
                    return
                }

                // Re-check rule still exists
                guard let currentRule = self.store.rule(for: targetBundleID),
                      currentRule.inputSourceID == expectedSourceID else {
                    return
                }

                // Re-check if already active (e.g. system restored or user switched)
                if let activeID = Self.currentInputSourceID(), activeID == expectedSourceID {
                    return
                }

                // The user already started typing in this app: selecting an input source now would commit/reset the
                // Hangul composition in flight and split the first syllable (ㄴㅏ중에). Typing means the user is in control
                // of the language, so this automatic switch is dropped instead of retried later in the middle of a word.
                if Self.keyWasPressed(since: scheduledAt) {
                    self.logger.info("Skipped automatic input source switch for \(targetBundleID, privacy: .public): typing started after activation")
                    return
                }

                // Never change the input source while secure event input is active (password fields).
                guard !IsSecureEventInputEnabled() else { return }

                // Hypothesis (not verified): selecting before the target app has a focused text client may leave the app's
                // input client without the change (menu-bar indicator updated, no cursor bubble). With Accessibility
                // already granted, wait (bounded) for a focused editable text element, then repeat every guard above once
                // more before selecting; at the deadline the switch is skipped rather than forced.
                if readinessVerified { break }
                // No permission prompt or change: without it the old bounded 120ms fallback applies (readiness undetectable).
                if !AXIsProcessTrusted() { break }
                if Self.hasFocusedEditableTextElement(pid: targetPID) {
                    readinessVerified = true
                    continue
                }
                if ProcessInfo.processInfo.systemUptime >= deadline {
                    self.logger.info("Skipped automatic input source switch for \(targetBundleID, privacy: .public): no focused text element before deadline")
                    return
                }
            }
            guard let self else { return }

            // Attempt to select target input source; never fallback silently
            let success = Self.select(inputSourceID: expectedSourceID)

            if success {
                self.logger.info("Applied input source \(expectedSourceID, privacy: .public) to \(targetBundleID, privacy: .public)")
            } else {
                self.logger.warning("Target input source \(expectedSourceID, privacy: .public) could not be selected for \(targetBundleID, privacy: .public)")
            }
        }
    }

    /// True when a key was pressed after `uptime` (ProcessInfo.systemUptime). Reads only the session's "seconds since the
    /// last key-down" counter: no event tap, no key contents, no Accessibility query, so it also works for password fields
    /// and without any extra permission.

    /// True when the app's focused element belongs to `pid` and is an editable, non-secure text element (same approach as
    /// FirstWordRecovery.focusedElement/isEditableTextElement). Reads only role/subrole, never text. Caller checks AX trust.
    private static func hasFocusedEditableTextElement(pid: pid_t) -> Bool {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.05)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return false }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.05)
        var elementPID: pid_t = 0
        guard AXUIElementGetPid(element, &elementPID) == .success, elementPID == pid else { return false }
        var role: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
              let roleName = role as? String,
              ["AXTextField", "AXTextArea", "AXComboBox"].contains(roleName) else { return false }
        var subrole: CFTypeRef?
        switch AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole) {
        case .success: return (subrole as? String) != "AXSecureTextField"
        case .noValue, .attributeUnsupported: return true
        default: return false
        }
    }

    private static func keyWasPressed(since uptime: TimeInterval) -> Bool {
        let sinceKeyDown = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
        return sinceKeyDown < ProcessInfo.processInfo.systemUptime - uptime
    }

    static func currentInputSourceID() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }

    @discardableResult
    static func select(inputSourceID: String) -> Bool {
        guard let listRef = TISCreateInputSourceList(nil, false)?.takeRetainedValue() else { return false }
        for item in listRef as NSArray {
            let source = item as! TISInputSource
            guard boolProperty(of: source, key: kTISPropertyInputSourceIsSelectCapable) else { continue }
            guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { continue }
            let id = Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
            if id == inputSourceID {
                return TISSelectInputSource(source) == noErr
            }
        }
        return false
    }

    static func isKoreanInputSourceID(_ id: String) -> Bool {
        id.hasPrefix("com.apple.inputmethod.Korean") && !id.hasSuffix(".Roman")
    }

    private static func boolProperty(of source: TISInputSource, key: CFString) -> Bool {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return false }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(pointer).takeUnretainedValue())
    }
}
