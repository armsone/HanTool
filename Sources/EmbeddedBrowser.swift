import AppKit
import Foundation

/// HTT 내부에 통합된 HTTHTDCore 브라우저 모듈 인터페이스.
/// - 기존 NSWorkspace 자식 프로세스 실행 대신 모듈 내부로 직접 라우팅한다.
/// - URL 유효성 검증 및 비공개 플래그 거부를 보존한다.
/// - 기존 호출자 API(open, forwardableWebURLs, isEmbeddedRunning)를 온전히 유지한다.
/// - updater 가드는 활성 브라우저 작업/Planner 유무(hasActiveWork)를 점검하여 진행 중인 작업을 절대 자동 강제 종료하지 않는다.
@MainActor
public enum EmbeddedBrowser {
    public static let bundleIdentifier = "com.hanstree.HttpsDown"

    /// '브라우저 열기'. urls가 있으면 유효성을 확인한 뒤 통합 브라우저 모듈로 전달한다.
    public static func open(urls: [URL] = []) {
        // 주소 전달 시 비공개 플래그(--args) 확인
        if !urls.isEmpty, hasUnsupportedPrivateFlag(CommandLine.arguments) {
            showFailure("비공개 모드 옵션은 지원하지 않아 주소를 전달하지 않았습니다.")
            return
        }

        // 이전 앱 중복 실행 확인 및 마이그레이션 점검
        guard UnifiedBrowserManager.shared.ensureReady() else {
            return
        }

        let validURLs = urls.isEmpty ? [] : forwardableWebURLs(urls)
        MailWindowCoordinator.shared.openBrowserMain(urls: validURLs)
    }

    /// 실행 인자(argv0 제외)에 지원하지 않는 비공개 플래그가 있는지 확인.
    private static func hasUnsupportedPrivateFlag(_ arguments: [String]) -> Bool {
        let flags: Set<String> = ["--private", "-private", "--inprivate"]
        return arguments.dropFirst().contains { flags.contains($0.lowercased()) }
    }

    /// 전달 가능한 웹 주소만 고른다: http/https, 계정 정보·제어 문자 없음, 주소 4096자·호스트 253자 이하,
    /// 앞쪽 64개만 검사해 최대 10개. 그 밖의 스킴(file·mailto 등)은 무시한다.
    public static func forwardableWebURLs(_ urls: [URL]) -> [URL] {
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

    /// 브라우저 모듈 내에서 진행 중인 활성 작업(다운로드/Planner 등)이 있는지 확인 (업데이터 가드용).
    /// 진행 중인 작업이 있으면 업데이트 설치 시 자동 종료하지 않고 사용자에게 완료를 요청한다.
    public static func isEmbeddedRunning() -> Bool {
        UnifiedBrowserManager.shared.hasActiveWork
    }

    private static func showFailure(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "브라우저를 열 수 없습니다"
        alert.informativeText = message
        alert.addButton(withTitle: "확인")
        alert.runModal()
    }
}
