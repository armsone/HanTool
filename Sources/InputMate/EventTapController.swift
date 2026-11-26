import AppKit
import ApplicationServices
import OSLog

private let eventTapLogger = Logger(subsystem: "com.local.screentranslator", category: "EventTap")

final class EventTapController {
    var beforeEvent: ((CGEventType, CGEvent, CGEventTapProxy) -> Bool)?
    var onKeyDown: ((CGEvent) -> Bool)?
    var onEmergencyUnlock: (() -> Void)?
    var shouldBlock: ((CGEventType) -> Bool)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var keyboardEventTap: CFMachPort?
    private var keyboardRunLoopSource: CFRunLoopSource?
    private var buttonBlockStates: [Int64: Bool] = [:]

    var isRunning: Bool { eventTap != nil && keyboardEventTap != nil }

    func start() -> Bool {
        guard !isRunning else { return true }

        let types: [CGEventType] = [
            .mouseMoved,
            .leftMouseDown, .leftMouseUp, .leftMouseDragged,
            .rightMouseDown, .rightMouseUp, .rightMouseDragged,
            .otherMouseDown, .otherMouseUp, .otherMouseDragged,
            .scrollWheel,
            .tabletPointer, .tabletProximity
        ]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: trackpadGuardEventCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        let keyboardMask = (CGEventMask(1) << CGEventType.keyDown.rawValue) | (CGEventMask(1) << CGEventType.keyUp.rawValue)
            | (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
        guard let keyboardTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: keyboardMask,
            callback: trackpadGuardEventCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        let keyboardSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, keyboardTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CFRunLoopAddSource(CFRunLoopGetMain(), keyboardSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        CGEvent.tapEnable(tap: keyboardTap, enable: true)
        eventTap = tap
        runLoopSource = source
        keyboardEventTap = keyboardTap
        keyboardRunLoopSource = keyboardSource
        return true
    }

    func stop() {
        if let source = keyboardRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let keyboardEventTap {
            CGEvent.tapEnable(tap: keyboardEventTap, enable: false)
            CFMachPortInvalidate(keyboardEventTap)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        keyboardRunLoopSource = nil
        keyboardEventTap = nil
        runLoopSource = nil
        eventTap = nil
        buttonBlockStates.removeAll()
    }

    fileprivate func handle(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            eventTapLogger.warning("Event tap disabled by system (type: \(type.rawValue, privacy: .public)), re-enabling")
            buttonBlockStates.removeAll()
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            if let keyboardEventTap {
                CGEvent.tapEnable(tap: keyboardEventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        if type == .keyDown {
            let emergencyModifiers: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if keyCode == 53 && event.flags.intersection(emergencyModifiers) == emergencyModifiers {
                onEmergencyUnlock?()
                return Unmanaged.passUnretained(event)
            }
        }

        if beforeEvent?(type, event, proxy) == true {
            return nil
        }

        if type == .keyDown {
            if onKeyDown?(event) == true {
                return nil
            }
            return Unmanaged.passUnretained(event)
        }

        let buttonNumber: Int64?
        switch type {
        case .leftMouseDown, .leftMouseUp:
            buttonNumber = 0
        case .rightMouseDown, .rightMouseUp:
            buttonNumber = 1
        case .otherMouseDown, .otherMouseUp:
            buttonNumber = event.getIntegerValueField(.mouseEventButtonNumber)
        default:
            buttonNumber = nil
        }

        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            let block = shouldBlock?(type) == true
            if let buttonNumber {
                buttonBlockStates[buttonNumber] = block
            }
            return block ? nil : Unmanaged.passUnretained(event)
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            let block = buttonNumber.flatMap { buttonBlockStates.removeValue(forKey: $0) } ?? (shouldBlock?(type) == true)
            return block ? nil : Unmanaged.passUnretained(event)
        default:
            return (shouldBlock?(type) == true) ? nil : Unmanaged.passUnretained(event)
        }
    }
}

private func trackpadGuardEventCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let controller = Unmanaged<EventTapController>.fromOpaque(userInfo).takeUnretainedValue()
    return controller.handle(proxy: proxy, type: type, event: event)
}
