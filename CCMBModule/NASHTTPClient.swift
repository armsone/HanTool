import AppKit
import Foundation
import WebKit

/// 세션 정보 스키마 (GET /api/session)
public struct NASSessionInfo: Equatable, Sendable {
    public let configured: Bool
    public let authenticated: Bool
    public let role: String?

    public init(configured: Bool, authenticated: Bool, role: String?) {
        self.configured = configured
        self.authenticated = authenticated
        self.role = role
    }
}

/// 놀이터 서버 URL 검증 및 정규화
public enum NASURLValidator {
    /// URL을 파싱하고 UI 접미사(/alfred)를 origin으로 정규화하며 역방향 프록시 접두사는 보존합니다.
    public static func normalize(urlString: String) -> URL? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let components = URLComponents(string: trimmed) else { return nil }
        guard let scheme = components.scheme?.lowercased(), (scheme == "https" || scheme == "http") else { return nil }
        guard let host = components.host, !host.isEmpty else { return nil }

        // 루프백이 아닌 경우 HTTPS 필수
        let isLoopback = host == "127.0.0.1" || host == "localhost" || host == "::1" || host == "[::1]"
        if scheme == "http" && !isLoopback {
            return nil
        }

        // URL 내 인증정보, 쿼리, 프래그먼트 거부
        if components.user != nil || components.password != nil || components.query != nil || components.fragment != nil {
            return nil
        }

        var normalized = components
        var path = components.path
        if path == "/alfred" || path == "/alfred/" {
            path = ""
        } else if path.hasSuffix("/") && path.count > 1 {
            path = String(path.dropLast())
        }
        normalized.path = path
        return normalized.url
    }

    /// 사용자 입력 주소의 유효성 검증 및 한국어 안내 문구 반환
    public static func validate(urlString: String) -> (isValid: Bool, message: String?, url: URL?) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return (false, "놀이터 주소를 입력하세요.", nil)
        }

        if !trimmed.contains("://") {
            return (false, "기존 SSH 별칭은 지원되지 않습니다. 실제 놀이터 HTTPS 주소(예: https://...)를 입력하세요.", nil)
        }

        guard let components = URLComponents(string: trimmed) else {
            return (false, "올바른 URL 형식이 아닙니다.", nil)
        }

        guard let scheme = components.scheme?.lowercased(), (scheme == "https" || scheme == "http") else {
            return (false, "HTTPS 주소만 지원됩니다.", nil)
        }

        guard let host = components.host, !host.isEmpty else {
            return (false, "호스트 주소가 필요합니다.", nil)
        }

        let isLoopback = host == "127.0.0.1" || host == "localhost" || host == "::1" || host == "[::1]"
        if scheme == "http" && !isLoopback {
            return (false, "보안을 위해 HTTPS 주소만 사용할 수 있습니다 (로컬 루프백 제외).", nil)
        }

        if components.user != nil || components.password != nil {
            return (false, "주소에 사용자 이름이나 비밀번호를 포함할 수 없습니다.", nil)
        }

        if components.query != nil {
            return (false, "주소에 쿼리(?)를 포함할 수 없습니다.", nil)
        }

        if components.fragment != nil {
            return (false, "주소에 프래그먼트(#)를 포함할 수 없습니다.", nil)
        }

        guard let normalizedURL = normalize(urlString: trimmed) else {
            return (false, "정규화된 주소를 생성할 수 없습니다.", nil)
        }

        return (true, nil, normalizedURL)
    }
}

/// 놀이터 HTTP API 통신 클라이언트 (URLSession 기반 안전한 세션 전송)
public final class NASHTTPClient: @unchecked Sendable {
    public static let shared = NASHTTPClient()

    private let maxOutputBytes = 256 * 1024

    private init() {}

    public static func isValidTarget(_ target: String) -> Bool {
        NASURLValidator.validate(urlString: target).isValid
    }

    public func clearSessionCache() {
        // 캐시 origin 전환 시 메모리 상태 초기화
    }

    /// WKWebsiteDataStore.default에서 해당 대상 origin에 일치하는 쿠키만 추출 (외부 브라우저 쿠키 절대 추출 안 함)
    @MainActor
    public static func cookies(for targetURL: URL) async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
                guard let host = targetURL.host?.lowercased() else {
                    continuation.resume(returning: [])
                    return
                }
                let requestPath = targetURL.path.isEmpty ? "/" : targetURL.path
                let now = Date()
                let matching = cookies.filter { cookie in
                    let domain = cookie.domain.lowercased()
                    let domainMatches: Bool
                    if domain.hasPrefix(".") {
                        // RFC 6265 domain-match: 정확히 일치하거나 점 경계의 하위 호스트
                        let suffix = String(domain.dropFirst())
                        domainMatches = !suffix.isEmpty && (host == suffix || host.hasSuffix(domain))
                    } else {
                        domainMatches = host == domain
                    }
                    guard domainMatches else { return false }
                    // RFC 6265 path-match
                    let cookiePath = cookie.path.isEmpty ? "/" : cookie.path
                    let pathMatches = requestPath == cookiePath
                        || (requestPath.hasPrefix(cookiePath)
                            && (cookiePath.hasSuffix("/") || requestPath.dropFirst(cookiePath.count).first == "/"))
                    guard pathMatches else { return false }
                    if cookie.isSecure && targetURL.scheme?.lowercased() != "https" {
                        return false
                    }
                    if let expires = cookie.expiresDate, expires <= now {
                        return false
                    }
                    return true
                }
                continuation.resume(returning: matching)
            }
        }
    }

    /// 응답 헤더의 Set-Cookie를 WKWebsiteDataStore.default에 안전하게 저장
    @MainActor
    public static func saveCookies(from response: HTTPURLResponse, for targetURL: URL) {
        guard let headerFields = response.allHeaderFields as? [String: String],
              let host = targetURL.host?.lowercased() else { return }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: headerFields, for: targetURL)
        for cookie in cookies {
            let domain = cookie.domain.lowercased()
            // 공유 기본 저장소 보호: 요청 host와 정확히 같은 도메인의 쿠키만 저장 (상위/공용 접미사 도메인 쓰기 금지)
            if domain == host {
                WKWebsiteDataStore.default().httpCookieStore.setCookie(cookie)
            }
        }
    }

    /// 크로스 오리진 쿠키 누출 및 HTTPS->HTTP 다운그레이드를 방지하는 리다이렉트 델리게이트
    private final class ScopedRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        struct Origin: Equatable {
            let scheme: String
            let host: String
            let port: Int
        }

        let allowedOrigin: Origin

        init(origin: Origin) {
            self.allowedOrigin = origin
        }

        /// scheme + 소문자 host + 유효 포트(HTTPS 443 / HTTP 80)로 구성된 정확한 origin
        static func origin(of url: URL) -> Origin? {
            guard let scheme = url.scheme?.lowercased(),
                  scheme == "https" || scheme == "http",
                  let host = url.host?.lowercased(), !host.isEmpty else { return nil }
            return Origin(scheme: scheme, host: host, port: url.port ?? (scheme == "https" ? 443 : 80))
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            guard let nextURL = request.url,
                  nextURL.user == nil, nextURL.password == nil,
                  Self.origin(of: nextURL) == allowedOrigin else {
                completionHandler(nil)
                return
            }
            completionHandler(request)
        }
    }

    /// 기본 HTTP 요청 전송
    private func performRequest(
        endpoint: String,
        queryItems: [URLQueryItem]? = nil,
        targetString: String? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        let target = (targetString ?? CCMBPreferences.shared.serverTarget).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let baseURL = NASURLValidator.normalize(urlString: target) else {
            throw NASFetchError.invalidURL
        }

        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: true)!
        let basePath = components.path
        let fullPath: String
        if basePath.isEmpty || basePath == "/" {
            fullPath = endpoint
        } else {
            fullPath = basePath + endpoint
        }
        components.path = fullPath
        if let queryItems {
            components.queryItems = queryItems
        }

        guard let requestURL = components.url else {
            throw NASFetchError.invalidURL
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 15

        let cookies = await Self.cookies(for: requestURL)
        let headers = HTTPCookie.requestHeaderFields(with: cookies)
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 25

        guard let origin = ScopedRedirectDelegate.origin(of: baseURL) else {
            throw NASFetchError.invalidURL
        }
        let delegate = ScopedRedirectDelegate(origin: origin)
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        var data = Data()
        let response: URLResponse
        do {
            let (bytes, bytesResponse) = try await session.bytes(for: request)
            response = bytesResponse
            if bytesResponse.expectedContentLength > Int64(maxOutputBytes) {
                throw NASFetchError.outputTooLarge
            }
            for try await byte in bytes {
                data.append(byte)
                if data.count > maxOutputBytes {
                    throw NASFetchError.outputTooLarge
                }
            }
        } catch let fetchError as NASFetchError {
            throw fetchError
        } catch is CancellationError {
            throw NASFetchError.cancelled
        } catch let urlError as URLError {
            if urlError.code == .cancelled {
                throw NASFetchError.cancelled
            } else if urlError.code == .timedOut {
                throw NASFetchError.timeout
            } else {
                throw NASFetchError.connectionFailed
            }
        } catch {
            throw NASFetchError.connectionFailed
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NASFetchError.connectionFailed
        }

        await MainActor.run {
            Self.saveCookies(from: httpResponse, for: requestURL)
        }

        if httpResponse.statusCode == 401 {
            throw NASFetchError.loginRequired
        }
        if httpResponse.statusCode == 403 {
            throw NASFetchError.permissionDenied
        }
        if httpResponse.statusCode >= 400 {
            throw NASFetchError.httpError(httpResponse.statusCode)
        }

        return (data, httpResponse)
    }

    /// 세션 정보 조회 (GET /api/session)
    public func fetchSession(target: String? = nil) async throws -> NASSessionInfo {
        let (data, _) = try await performRequest(endpoint: "/api/session", targetString: target)
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw NASFetchError.unreadableResponse
        }
        let configured = object["configured"] as? Bool ?? false
        let authenticated = object["authenticated"] as? Bool ?? false
        let role = object["role"] as? String
        return NASSessionInfo(configured: configured, authenticated: authenticated, role: role)
    }

    /// 스냅샷 조회 (GET /api/ccmb/v2/snapshot)
    public func fetchSnapshot() async throws -> Data {
        let (data, _) = try await performRequest(endpoint: "/api/ccmb/v2/snapshot")
        guard !data.isEmpty else { throw NASFetchError.emptyResponse }
        return data
    }

    /// 작업 상태 카운트 조회 (GET /api/ccmb/task-status)
    public func fetchTaskStatus() async throws -> Data {
        let (data, _) = try await performRequest(endpoint: "/api/ccmb/task-status")
        guard !data.isEmpty else { throw NASFetchError.emptyResponse }
        return data
    }

    /// 히스토리 파일 조회: v3 우선 시도, 실패 시 v2 폴백. 마스터 전용 403은 permission label로 처리.
    func fetchHistory() async throws -> NASHistoryReadResult {
        do {
            let (data, _) = try await performRequest(
                endpoint: "/api/ccmb/files",
                queryItems: [URLQueryItem(name: "name", value: "CCMB-nas-consumption-history-v3.json")]
            )
            if let history = NASHistoryV2Core.parse(data) {
                return .history(history)
            }
        } catch let error as NASFetchError {
            switch error {
            case .permissionDenied:
                return .helperError(NASServiceError(code: "permission_denied", message: "히스토리 조회 권한 없음 (마스터 전용)"))
            case .loginRequired, .cancelled:
                throw error
            default:
                break // 404/미지원 등일 때 v2 폴백 진행
            }
        } catch {
            // 폴백 진행
        }

        do {
            let (data, _) = try await performRequest(
                endpoint: "/api/ccmb/files",
                queryItems: [URLQueryItem(name: "name", value: "CCMB-nas-consumption-history-v2.json")]
            )
            if let history = NASHistoryV2Core.parse(data) {
                return .history(history)
            }
            return .helperError(NASServiceError(code: "unreadable", message: "히스토리 응답 형식 불일치"))
        } catch let error as NASFetchError {
            if case .permissionDenied = error {
                return .helperError(NASServiceError(code: "permission_denied", message: "히스토리 조회 권한 없음 (마스터 전용)"))
            }
            throw error
        }
    }
}

/// 인앱 내장 WKWebView 기반 로그인 창 컨트롤러 (단일 모듈 창 소유, 로그인 완료/창 닫힘 시 세션 갱신)
@MainActor
public final class NASLoginWindowController: NSObject, NSWindowDelegate, WKNavigationDelegate {
    private static var activeController: NASLoginWindowController?

    private let window: NSWindow
    private let webView: WKWebView
    private let targetURL: URL
    private let targetKey: String
    private var onCompletion: @MainActor (Bool) -> Void
    private var isCompleted = false

    /// 활성 로그인 창을 완료 콜백 없이 닫습니다 (대상/소스 변경 등으로 무효화될 때).
    public static func closeActive() {
        guard let existing = activeController else { return }
        existing.isCompleted = true
        activeController = nil
        existing.window.close()
    }

    public static func show(target: String, onCompletion: @escaping @MainActor (Bool) -> Void) {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else { return }
        let key = NASURLValidator.normalize(urlString: trimmed)?.absoluteString ?? trimmed

        if let existing = activeController {
            if existing.targetKey == key {
                existing.onCompletion = onCompletion
                existing.window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                return
            }
            closeActive()
        }

        let controller = NASLoginWindowController(targetURL: url, targetKey: key, onCompletion: onCompletion)
        activeController = controller
        controller.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private init(targetURL: URL, targetKey: String, onCompletion: @escaping @MainActor (Bool) -> Void) {
        self.targetURL = targetURL
        self.targetKey = targetKey
        self.onCompletion = onCompletion

        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.default()

        self.webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 620), configuration: config)

        self.window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 620),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        self.window.title = "놀이터 로그인"
        self.window.center()
        self.window.contentView = webView
        self.window.isReleasedWhenClosed = false

        super.init()
        self.window.delegate = self
        self.webView.navigationDelegate = self

        var request = URLRequest(url: targetURL)
        request.timeoutInterval = 20
        self.webView.load(request)
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !isCompleted else { return }
        Task { @MainActor in
            if let session = try? await NASHTTPClient.shared.fetchSession(target: self.targetURL.absoluteString),
               session.authenticated,
               !self.isCompleted {
                self.isCompleted = true
                self.onCompletion(true)
                self.window.close()
            }
        }
    }

    public func windowWillClose(_ notification: Notification) {
        if !isCompleted {
            isCompleted = true
            Task { @MainActor in
                let session = try? await NASHTTPClient.shared.fetchSession(target: self.targetURL.absoluteString)
                self.onCompletion(session?.authenticated == true)
            }
        }
        if Self.activeController === self {
            Self.activeController = nil
        }
    }
}
