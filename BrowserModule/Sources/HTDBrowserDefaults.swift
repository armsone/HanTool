import Foundation

/// HTD 브라우저 설정 도메인 보존 (com.hanstree.HttpsDown)
/// HTT_HOST 하에서는 전용 스위트를 반환하여 HTT 기본 도메인과 충돌 없이 독립적으로 보존합니다.
public enum HTDBrowserDefaults {
    public static var standard: UserDefaults {
        #if HTT_HOST
        return UserDefaults(suiteName: "com.hanstree.HttpsDown") ?? UserDefaults.standard
        #else
        return UserDefaults.standard
        #endif
    }
}
