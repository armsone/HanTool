import AppKit
import Security

/// HTT 안에 함께 들어 있는 번역 브라우저(HTD) 실행.
/// - HTT 앱 안의 Contents/Helpers/HTD.app 한 곳만 실행한다. 다른 위치의 HTD나 소스 폴더는 쓰지 않는다.
/// - 실행 전에 앱 식별자와 같은 개발자 서명(팀)인지, 서명이 온전한지 확인한다.
/// - 이미 HTD가 실행 중이면 새로 띄우지 않고 그 창을 앞으로 가져온다(진행 중인 다운로드 보존).
/// - 설치된 별도 HTD(/Applications)를 복사·수정·삭제하지 않는다.
@MainActor
enum EmbeddedBrowser {
    static let bundleIdentifier = "com.hanstree.HttpsDown"

    private static var appURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/HTD.app", isDirectory: true)
    }

    /// '브라우저 열기'. urls가 있으면 같은 확인을 거친 뒤 HTD로 전달한다(새 인스턴스를 만들지 않는다).
    static func open(urls: [URL] = []) {
        let url = appURL
        // 주소 전달 시 비공개 플래그(--args)는 전달되지 않으므로, 우회되지 않도록 전달 자체를 거부한다.
        if !urls.isEmpty, hasUnsupportedPrivateFlag(CommandLine.arguments) {
            showFailure("비공개 모드 옵션은 지원하지 않아 주소를 전달하지 않았습니다.")
            return
        }
        Task {
            // 서명 검사는 시간이 걸릴 수 있어 화면을 멈추지 않도록 따로 처리한다.
            let problem = await Task.detached(priority: .userInitiated) { verificationProblem(url) }.value
            if let problem {
                showFailure(problem)
                return
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.createsNewApplicationInstance = false
            do {
                if urls.isEmpty {
                    _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
                } else {
                    _ = try await NSWorkspace.shared.open(urls, withApplicationAt: url, configuration: configuration)
                }
            } catch {
                showFailure("브라우저를 시작하지 못했습니다: \(error.localizedDescription)")
            }
        }
    }

    /// 실행 인자(argv0 제외)에 지원하지 않는 비공개 플래그가 있는지.
    private static func hasUnsupportedPrivateFlag(_ arguments: [String]) -> Bool {
        let flags: Set<String> = ["--incognito", "-incognito", "--private", "-private", "--inprivate"]
        return arguments.dropFirst().contains { flags.contains($0.lowercased()) }
    }

    /// 전달 가능한 웹 주소만 고른다: http/https, 계정 정보·제어 문자 없음, 주소 4096자·호스트 253자 이하,
    /// 앞쪽 64개만 검사해 최대 10개. 그 밖의 스킴(file·mailto 등)은 무시한다.
    static func forwardableWebURLs(_ urls: [URL]) -> [URL] {
        var result: [URL] = []
        for url in urls.prefix(64) {
            let text = url.absoluteString
            guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  text.utf8.count <= 4096,
                  !text.unicodeScalars.contains(where: { $0.properties.generalCategory == .control || $0 == " " }),
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  components.user == nil, components.password == nil,
                  let host = components.host, !host.isEmpty, host.utf8.count <= 253 else { continue }
            result.append(url)
            if result.count == 10 { break }
        }
        return result
    }

    /// HTT 안에서 실행 중인 HTD가 있는지(업데이트 설치 전 확인용). 다른 위치의 HTD는 세지 않는다.
    static func isEmbeddedRunning() -> Bool {
        let root = Bundle.main.bundleURL.resolvingSymlinksInPath().path + "/"
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).contains { app in
            guard !app.isTerminated, let path = app.bundleURL?.resolvingSymlinksInPath().path else { return false }
            return path.hasPrefix(root)
        }
    }

    // MARK: - 확인

    private nonisolated static func verificationProblem(_ url: URL) -> String? {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue,
              let bundle = Bundle(url: url) else {
            return "이 HTT에 HTT 브라우저가 들어 있지 않습니다. HTT를 다시 설치하거나 업데이트해 주세요."
        }
        guard bundle.bundleIdentifier == bundleIdentifier else {
            return "HTT 안의 브라우저가 올바른 앱이 아닙니다."
        }
        let root = Bundle.main.bundleURL.resolvingSymlinksInPath().path + "/"
        guard url.resolvingSymlinksInPath().path.hasPrefix(root) else {
            return "HTT 브라우저가 HTT 앱 밖을 가리키고 있어 실행하지 않았습니다."
        }
        if let minimum = bundle.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String {
            let parts = minimum.split(separator: ".").compactMap { Int($0) }
            if let major = parts.first {
                let required = OperatingSystemVersion(
                    majorVersion: major, minorVersion: parts.count > 1 ? parts[1] : 0,
                    patchVersion: parts.count > 2 ? parts[2] : 0)
                if !ProcessInfo.processInfo.isOperatingSystemAtLeast(required) {
                    return "HTT 브라우저는 macOS \(minimum) 이상에서만 쓸 수 있습니다."
                }
            }
        }
        guard let own = ownTeamIdentifier(), let child = teamIdentifier(ofPath: url), own == child else {
            return "HTT 브라우저의 개발자 서명이 HTT와 달라 실행하지 않았습니다."
        }
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(rawValue: 0), &staticCode) == errSecSuccess,
              let code = staticCode else {
            return "HTT 브라우저의 서명 정보를 읽지 못했습니다."
        }
        let flags = SecCSFlags(rawValue: UInt32(kSecCSCheckAllArchitectures | kSecCSStrictValidate))
        guard SecStaticCodeCheckValidityWithErrors(code, flags, nil, nil) == errSecSuccess else {
            return "HTT 브라우저의 코드 서명이 올바르지 않습니다. HTT를 다시 설치해 주세요."
        }
        return nil
    }

    private nonisolated static func ownTeamIdentifier() -> String? {
        var dynamic: SecCode?
        var staticCode: SecStaticCode?
        guard SecCodeCopySelf(SecCSFlags(rawValue: 0), &dynamic) == errSecSuccess, let dynamic,
              SecCodeCopyStaticCode(dynamic, SecCSFlags(rawValue: 0), &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        return teamIdentifier(of: staticCode)
    }

    private nonisolated static func teamIdentifier(ofPath url: URL) -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(rawValue: 0), &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        return teamIdentifier(of: staticCode)
    }

    private nonisolated static func teamIdentifier(of code: SecStaticCode) -> String? {
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: UInt32(kSecCSSigningInformation)), &information) == errSecSuccess,
              let dictionary = information as? [String: Any],
              let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty else { return nil }
        return team
    }

    private static func showFailure(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "브라우저를 열 수 없습니다"
        alert.informativeText = message
        alert.addButton(withTitle: "확인")
        alert.runModal()
    }
}
