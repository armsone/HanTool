import AppKit
import Foundation

/// 호스트 앱이 제공사 페이지를 기존 내장 브라우저로 여는 라우터.
@MainActor
public enum HTTCCMBProviderPageRouter {
    public static var openPage: ((URL) -> Void)?
}

enum ProviderUsageWindow {
    @MainActor
    static func show(url: URL, title: String) {
        if let openPage = HTTCCMBProviderPageRouter.openPage {
            openPage(url)
            return
        }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "호스트 앱의 브라우저를 현재 사용할 수 없어 제공사 화면을 열 수 없습니다."
        alert.addButton(withTitle: "확인")
        alert.runModal()
    }
}
