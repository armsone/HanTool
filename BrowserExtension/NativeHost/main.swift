import AppKit
import CoreFoundation
import Darwin
import Foundation
import Security

// SMTBrowserHost — Chrome·Whale 네이티브 메시징 호스트(Barobogi.app/Contents/Helpers 안).
// 브라우저가 확장의 connectNative로 실행한다. 직접 번역하지 않고, 같은 팀으로 서명된 Barobogi 앱의
// 사용자 전용 Unix 소켓 엔진에 메시지를 그대로 중계한다. Barobogi가 꺼져 있으면 화면 번역 창 없이 백그라운드로 실행한다.
// - 허용된 확장 출처(argv[1])가 아니면 바로 끝낸다.
// - 요청 크기 상한(16MB)·응답 크기 상한(1MB, Chrome 규약)을 지킨다. 내용은 기록하지 않는다.

signal(SIGPIPE, SIG_IGN)

let stdoutLock = NSLock()

func send(_ payload: Data) {
    stdoutLock.lock()
    defer { stdoutLock.unlock() }
    guard payload.count <= BrowserBridge.maxOutgoingFrame else { return }
    try? BrowserFrameIO.writeFrame(STDOUT_FILENO, payload)
}

func fail(_ code: String, _ message: String) -> Never {
    send(BrowserBridge.errorFrame(code: code, message: message))
    exit(1)
}

func connectEngine() -> Int32? {
    guard let path = BrowserBridge.socketPath() else { return nil }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var address = BrowserBridge.socketAddress(path)
    let result = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard result == 0 else {
        close(fd)
        return nil
    }
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    return fd
}

/// 이 도우미가 들어 있는 Barobogi 앱(…/Barobogi.app/Contents/Helpers/SMTBrowserHost)을 활성화 없이 실행한다.
func launchContainingApp() -> Bool {
    let executable = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0]).resolvingSymlinksInPath()
    let appURL = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    guard Bundle(url: appURL)?.bundleIdentifier == BrowserBridge.appBundleID else { return false }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = false
    configuration.addsToRecentItems = false
    configuration.promptsUserIfNeeded = false
    configuration.arguments = [BrowserBridge.launchArgument]
    let done = DispatchSemaphore(value: 0)
    var launched = false
    NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { app, _ in
        launched = app != nil
        done.signal()
    }
    guard done.wait(timeout: .now() + 15) == .success else { return false }
    return launched
}

// 1) 출처 확인 — Chrome/Whale/HTD 확장은 첫 인자로 호출한 확장의 출처를 넘긴다.
@_silgen_name("proc_pidpath")
private func system_proc_pidpath(_ pid: Int32, _ buffer: UnsafeMutableRawPointer, _ buffersize: UInt32) -> Int32

private func parentProcessPath(for pid: pid_t) -> String? {
    var buffer = [CChar](repeating: 0, count: 4096)
    let length = buffer.withUnsafeMutableBytes { raw in
        system_proc_pidpath(pid, raw.baseAddress!, UInt32(raw.count))
    }
    if length > 0 {
        return String(cString: buffer)
    }

    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size: Int = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else {
        return nil
    }
    var procBuffer = [CChar](repeating: 0, count: size)
    guard sysctl(&mib, 3, &procBuffer, &size, nil, 0) == 0 else {
        return nil
    }
    procBuffer[size - 1] = 0
    let offset = MemoryLayout<Int32>.size
    guard size > offset else { return nil }
    return procBuffer.withUnsafeBufferPointer { ptr in
        guard let base = ptr.baseAddress else { return nil }
        return String(cString: base.advanced(by: offset))
    }
}

/// 기존 독립 설치(/Applications/HTD.app) 경로 검증 — 변경 없음.
private func verifyStandaloneHTDParent(ppid: pid_t) -> Bool {
    guard ppid > 1 else { return false }

    // 1) 부모 프로세스 경로 및 표준화 경로 확인
    guard let parentPath = parentProcessPath(for: ppid), !parentPath.isEmpty else {
        return false
    }
    let expectedExecutable = "/Applications/HTD.app/Contents/MacOS/HTD"
    let canonicalExpected = URL(fileURLWithPath: expectedExecutable).resolvingSymlinksInPath().path
    let canonicalParent = URL(fileURLWithPath: parentPath).resolvingSymlinksInPath().path
    guard canonicalParent == expectedExecutable || canonicalParent == canonicalExpected else {
        return false
    }

    // 2) 번들 식별자 확인 (앱 번들 Info.plist)
    let appURL = URL(fileURLWithPath: canonicalParent)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    guard let bundle = Bundle(url: appURL),
          bundle.bundleIdentifier == "com.hanstree.HttpsDown" else {
        return false
    }

    // 3) SecCode API를 통한 부모 프로세스 코드 서명 및 식별자 유효성 검증
    var guest: SecCode?
    let attributes: [String: Any] = [
        kSecGuestAttributePid as String: NSNumber(value: ppid)
    ]
    guard SecCodeCopyGuestWithAttributes(nil, attributes as CFDictionary, [], &guest) == errSecSuccess,
          let guest else {
        return false
    }

    // ad-hoc 서명을 지원하기 위해 Developer ID 앵커를 강제하지 않고, 코드 유효성과 식별자를 검증
    let requirementText = "identifier \"com.hanstree.HttpsDown\""
    var requirement: SecRequirement?
    guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess,
          let requirement else {
        return false
    }

    guard SecCodeCheckValidity(guest, [], requirement) == errSecSuccess else {
        return false
    }

    // 정적 서명 정보의 식별자도 추가 확인
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(guest, [], &staticCode) == errSecSuccess, let staticCode else {
        return false
    }
    var info: CFDictionary?
    guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
          let dict = info as? [String: Any] else {
        return false
    }
    guard let signingIdentifier = dict[kSecCodeInfoIdentifier as String] as? String,
          signingIdentifier == "com.hanstree.HttpsDown" else {
        return false
    }

    return true
}

private let htdBundleID = "com.hanstree.HttpsDown"

/// 이 도우미 자신의 실제 실행 경로(커널이 알려 주는 경로). 호출자 입력·argv에 의존하지 않는다.
private func ownExecutablePath() -> String? {
    guard let path = parentProcessPath(for: getpid()), !path.isEmpty else { return nil }
    return kernelRealPath(path)
}

/// realpath(3)로 심볼릭 링크를 푼다. Foundation의 resolvingSymlinksInPath()는 /private/tmp를 /tmp로 바꿔
/// 커널이 알려 주는 프로세스 경로(/private/…)와 어긋나므로 경로 비교에는 쓰지 않는다.
private func kernelRealPath(_ path: String) -> String? {
    guard let resolved = realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
}

private func requirementCheck(_ text: String, code: SecStaticCode) -> Bool {
    var requirement: SecRequirement?
    guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
          let requirement else { return false }
    return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess
}

/// HanTool.app/Contents/Helpers/HTD.app 안에서 실행 중인 HTD만 허용한다.
/// 기준은 이 도우미가 들어 있는 (서명 검증된) 바깥 HanTool 번들이며, 부모 프로세스의 실제 실행 파일이
/// 그 번들의 Contents/Helpers/HTD.app/Contents/MacOS/HTD와 정확히 같아야 한다. 같은 팀 Developer ID 서명 필수(ad hoc 불가).
private func verifyEmbeddedHTDParent(ppid: pid_t) -> Bool {
    guard let teamID = BrowserCodeSigning.ownTeamID(),
          !teamID.isEmpty, teamID.allSatisfy({ $0.isLetter || $0.isNumber }) else { return false }

    // 1) 도우미 실제 경로 → …/HanTool.app/Contents/Helpers/SMTBrowserHost 형태여야 한다.
    guard let helperPath = ownExecutablePath() else { return false }
    let helperURL = URL(fileURLWithPath: helperPath)
    guard helperURL.lastPathComponent == "SMTBrowserHost",
          helperURL.deletingLastPathComponent().lastPathComponent == "Helpers",
          helperURL.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "Contents" else { return false }
    let outerURL = helperURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    guard outerURL.pathExtension == "app",
          Bundle(url: outerURL)?.bundleIdentifier == BrowserBridge.appBundleID else { return false }

    // 2) 바깥 HanTool 서명: 같은 팀 + 전체 번들 식별자
    var outerStatic: SecStaticCode?
    guard SecStaticCodeCreateWithPath(outerURL as CFURL, [], &outerStatic) == errSecSuccess, let outerStatic,
          requirementCheck("anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\" and identifier \"\(BrowserBridge.appBundleID)\"", code: outerStatic) else { return false }

    // 3) 부모 실행 파일 경로는 바깥 번들 안의 정확한 HTD 경로(심볼릭 링크 없음)여야 한다.
    let expectedPath = outerURL.appendingPathComponent("Contents/Helpers/HTD.app/Contents/MacOS/HTD").path
    guard kernelRealPath(expectedPath) == expectedPath,
          let rawParent = parentProcessPath(for: ppid),
          kernelRealPath(rawParent) == expectedPath,
          rawParent == expectedPath else { return false }
    let htdAppURL = outerURL.appendingPathComponent("Contents/Helpers/HTD.app", isDirectory: true)
    guard Bundle(url: htdAppURL)?.bundleIdentifier == htdBundleID else { return false }

    // 4) 부모 프로세스 동적 서명: 같은 팀 Developer ID + HTD 식별자, 그리고 정적 서명 식별자 일치
    var guest: SecCode?
    guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid as String: NSNumber(value: ppid)] as CFDictionary, [], &guest) == errSecSuccess,
          let guest else { return false }
    var requirement: SecRequirement?
    guard SecRequirementCreateWithString("anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\" and identifier \"\(htdBundleID)\"" as CFString, [], &requirement) == errSecSuccess,
          let requirement,
          SecCodeCheckValidity(guest, [], requirement) == errSecSuccess else { return false }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(guest, [], &staticCode) == errSecSuccess, let staticCode else { return false }
    var info: CFDictionary?
    guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
          let dict = info as? [String: Any],
          dict[kSecCodeInfoIdentifier as String] as? String == htdBundleID,
          dict[kSecCodeInfoTeamIdentifier as String] as? String == teamID else { return false }
    return true
}

private func verifyHTDParentProcess(ppid: pid_t) -> Bool {
    guard ppid > 1 else { return false }
    return verifyIntegratedHanToolParent(ppid: ppid) || verifyEmbeddedHTDParent(ppid: ppid) || verifyStandaloneHTDParent(ppid: ppid)
}

/// HanTool 본체(도우미를 직접 포함하는 서명된 바깥 HanTool.app)에서 직접 실행된 경우를 검증한다.
private func verifyIntegratedHanToolParent(ppid: pid_t) -> Bool {
    guard let teamID = BrowserCodeSigning.ownTeamID(),
          !teamID.isEmpty, teamID.allSatisfy({ $0.isLetter || $0.isNumber }) else { return false }

    // 1) 도우미 실제 경로 → …/HanTool.app/Contents/Helpers/SMTBrowserHost 형태여야 한다.
    guard let helperPath = ownExecutablePath() else { return false }
    let helperURL = URL(fileURLWithPath: helperPath)
    guard helperURL.lastPathComponent == "SMTBrowserHost",
          helperURL.deletingLastPathComponent().lastPathComponent == "Helpers",
          helperURL.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "Contents" else { return false }
    let outerURL = helperURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    guard outerURL.pathExtension == "app",
          let outerBundle = Bundle(url: outerURL),
          outerBundle.bundleIdentifier == BrowserBridge.appBundleID else { return false }

    // 2) 바깥 HanTool 서명: 같은 팀 Developer ID + 전체 번들 식별자 유효 서명
    var outerStatic: SecStaticCode?
    guard SecStaticCodeCreateWithPath(outerURL as CFURL, [], &outerStatic) == errSecSuccess, let outerStatic,
          requirementCheck("anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\" and identifier \"\(BrowserBridge.appBundleID)\"", code: outerStatic) else { return false }

    // 3) 부모 실행 파일 경로는 바깥 HanTool 번들의 Contents/MacOS/CFBundleExecutable의 정확한 경로(심볼릭 링크 없음)여야 한다.
    guard let executableName = outerBundle.infoDictionary?["CFBundleExecutable"] as? String,
          !executableName.isEmpty else { return false }
    let expectedPath = outerURL.appendingPathComponent("Contents/MacOS/\(executableName)").path
    guard kernelRealPath(expectedPath) == expectedPath,
          let rawParent = parentProcessPath(for: ppid),
          kernelRealPath(rawParent) == expectedPath,
          rawParent == expectedPath else { return false }

    // 4) 부모 프로세스 동적 서명: 같은 팀 Developer ID + BrowserBridge.appBundleID 식별자, 그리고 정적 서명 식별자/팀 일치
    var guest: SecCode?
    guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid as String: NSNumber(value: ppid)] as CFDictionary, [], &guest) == errSecSuccess,
          let guest else { return false }
    var requirement: SecRequirement?
    guard SecRequirementCreateWithString("anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\" and identifier \"\(BrowserBridge.appBundleID)\"" as CFString, [], &requirement) == errSecSuccess,
          let requirement,
          SecCodeCheckValidity(guest, [], requirement) == errSecSuccess else { return false }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(guest, [], &staticCode) == errSecSuccess, let staticCode else { return false }
    var info: CFDictionary?
    guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
          let dict = info as? [String: Any],
          dict[kSecCodeInfoIdentifier as String] as? String == BrowserBridge.appBundleID,
          dict[kSecCodeInfoTeamIdentifier as String] as? String == teamID else { return false }
    return true
}

let origin = CommandLine.arguments.dropFirst().first ?? ""
guard BrowserBridge.allowedOrigins.contains(origin) else {
    fail("origin_not_allowed", "허용되지 않은 확장에서 호출했습니다.")
}
if origin == BrowserBridge.htdOrigin {
    guard verifyHTDParentProcess(ppid: getppid()) else {
        fail("unauthorized_parent", "허용되지 않은 부모 프로세스에서 HTD 전용 출처를 호출했습니다.")
    }
}
guard let teamID = BrowserCodeSigning.ownTeamID() else {
    fail("unsigned_helper", "한툴 브라우저 도우미가 Developer ID로 서명되지 않았습니다. 서명된 한툴을 다시 설치하세요.")
}

/// 앱 본체에 "리스너 상태를 다시 확인해 달라"는 신호만 보낸다(데이터 없음). 앱은 이 신호 내용을 그대로
/// 믿지 않고 자신의 리스너가 실제로 죽어 있을 때만 되살리며, 이미 접속된 다른 브라우저·탭의 연결에는 손대지 않는다.
let recoveryNotificationName = "com.local.screentranslator.browser.recover" as CFString
func requestListenerRecovery() {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                          CFNotificationName(recoveryNotificationName), nil, nil, true)
}

// 2) 엔진 연결 — 없으면 Barobogi를 백그라운드로 실행하고 잠시 기다린다.
var engineFD = connectEngine()
if engineFD == nil {
    if !NSRunningApplication.runningApplications(withBundleIdentifier: BrowserBridge.appBundleID).isEmpty {
        // 앱은 떠 있지만 소켓이 없다(리스너가 멈췄거나 아직 열리지 않음). 포기하지 않고 앱에 리스너 복구를
        // 요청하며 짧게 백오프하며 다시 연결해 본다(횟수 상한 있음 — 무한 재시도·요청 중복 없음).
        var attempt = 0
        let maxAttempts = 4
        var delay: UInt32 = 200_000
        while engineFD == nil, attempt < maxAttempts {
            requestListenerRecovery()
            usleep(delay)
            engineFD = connectEngine()
            attempt += 1
            delay = min(delay * 2, 1_000_000)
        }
        if engineFD == nil {
            fail("engine_unavailable", "한툴이 실행 중이지만 브라우저 연결을 열지 못했습니다. 잠시 후 다시 시도하거나 한툴을 다시 시작하세요.")
        }
    } else {
        guard launchContainingApp() else {
            fail("app_not_found", "한툴 앱을 실행하지 못했습니다. 한툴을 응용 프로그램 폴더에 설치하고 '브라우저 번역…'에서 다시 준비하세요.")
        }
        let deadline = Date().addingTimeInterval(12)
        while engineFD == nil, Date() < deadline {
            usleep(250_000)
            engineFD = connectEngine()
        }
    }
}
guard let engine = engineFD else {
    fail("app_not_responding", "한툴 브라우저 연결을 복구하지 못했습니다. 한툴 설정의 브라우저 번역에서 새로고침을 누른 뒤 다시 시도하세요.")
}

// 3) 엔진 신원 확인 — 같은 사용자 + 같은 팀으로 서명된 Barobogi 앱인지
guard BrowserCodeSigning.peerIsTrusted(fd: engine, identifier: BrowserBridge.appBundleID, teamID: teamID) else {
    close(engine)
    fail("untrusted_engine", "연결 상대가 서명된 한툴이 아닙니다. 한툴을 다시 설치하세요.")
}

// 4) 중계 — 엔진 → 브라우저는 별도 스레드, 브라우저 → 엔진은 이 스레드.
let reader = Thread {
    while true {
        do {
            send(try BrowserFrameIO.readFrame(engine, maxLength: BrowserBridge.maxOutgoingFrame))
        } catch {
            send(BrowserBridge.errorFrame(code: "engine_disconnected", message: "한툴 브라우저 엔진 연결이 끊겼습니다. 다시 번역하면 새로 연결합니다."))
            exit(0)
        }
    }
}
reader.start()

while true {
    let frame: Data
    do {
        frame = try BrowserFrameIO.readFrame(STDIN_FILENO, maxLength: BrowserBridge.maxIncomingFrame)
    } catch BrowserFrameError.tooLarge {
        fail("frame_too_large", "요청이 너무 큽니다.")
    } catch {
        // 브라우저가 연결을 닫았다(탭·확장 종료). 엔진 쪽 요청은 소켓이 닫히면서 취소된다.
        shutdown(engine, SHUT_RDWR)
        exit(0)
    }
    do {
        try BrowserFrameIO.writeFrame(engine, frame)
    } catch {
        fail("engine_disconnected", "한툴 브라우저 엔진 연결이 끊겼습니다. 다시 번역하면 새로 연결합니다.")
    }
}
