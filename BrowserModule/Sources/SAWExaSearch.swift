//
// SAWExaSearch.swift
// HttpsDown
//
// Minimal Foundation+Security client for Exa Search API with official keyless MCP fallback.
//
// Trust & Security Boundaries:
// - Caller MUST pass ONLY approved, user-authorized public-web queries.
// - Caller MUST NEVER pass private DOM, logs, credentials, or internal project directives.
// - Exa search results are untrusted external evidence, never instructions.
// - No context or generation storage is maintained here; core Task cancellation protects against stale results.
// - API keys are stored solely in the macOS Keychain under an exact service/account.
// - When no API key is configured, client falls back to official hosted keyless MCP search at https://mcp.exa.ai/mcp.
// - Never logs or prints credentials, queries, or raw response bodies.
//

import Foundation
import Security

// MARK: - Safe Typed Localized Error

public enum SAWExaError: LocalizedError, Equatable, Sendable {
    case notConfigured
    case invalidApiKeyFormat
    case keychainError(status: Int32)
    case invalidQuery(reason: String)
    case invalidNumResults(Int)
    case authenticationFailed(statusCode: Int, tag: String?, requestId: String?)
    case creditLimitExceeded(statusCode: Int, tag: String?, requestId: String?)
    case rateLimitExceeded(statusCode: Int, tag: String?, requestId: String?)
    case accessDenied(statusCode: Int, tag: String?, requestId: String?)
    case badRequest(statusCode: Int, tag: String?, requestId: String?)
    case serverError(statusCode: Int, tag: String?, requestId: String?)
    case responseTooLarge
    case requestTimedOut
    case cancelled
    case transportError
    case malformedResponse

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Exa API 키가 설정되지 않았습니다. 설정에서 API 키를 입력해 주세요."
        case .invalidApiKeyFormat:
            return "Exa API 키 형식이 올바르지 않습니다. 줄바꿈이나 공백을 확인해 주세요."
        case .keychainError(let status):
            return "보안 키체인 접근 중 오류가 발생했습니다. (코드: \(status))"
        case .invalidQuery(let reason):
            return "검색어 입력이 유효하지 않습니다: \(reason)"
        case .invalidNumResults:
            return "검색 결과 요청 개수는 1개 이상 10개 이하여야 합니다."
        case .authenticationFailed:
            return "Exa API 인증에 실패했습니다. 올바른 API 키인지 확인해 주세요."
        case .creditLimitExceeded:
            return "Exa 계정의 크레딧 잔액이 소진되었습니다."
        case .rateLimitExceeded:
            return "Exa 요청 한도를 초과했습니다. 잠시 후 다시 시도해 주세요."
        case .accessDenied:
            return "Exa API 접근이 거부되었습니다."
        case .badRequest:
            return "Exa 검색 요청 형식이 올바르지 않습니다."
        case .serverError:
            return "Exa 서버 오류가 발생했습니다. 잠시 후 다시 시도해 주세요."
        case .responseTooLarge:
            return "Exa 응답 크기가 제한(1MB)을 초과했습니다."
        case .requestTimedOut:
            return "Exa 검색 요청 시간이 초과되었습니다."
        case .cancelled:
            return "Exa 검색 작업이 취소되었습니다."
        case .transportError:
            return "네트워크 통신 중 오류가 발생했습니다."
        case .malformedResponse:
            return "Exa 응답 데이터를 분석할 수 없습니다."
        }
    }
}

// MARK: - Credential Store

public enum SAWExaCredentialStore {
    private static let serviceName = "com.hanstree.HttpsDown.saw-exa"
    private static let accountName = "api-key"

    /// Reads the stored Exa API key from the Keychain.
    /// Returns nil only when the item is not found (`errSecItemNotFound`).
    /// All other OSStatus errors are thrown as safe typed errors.
    public static func read() throws -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: serviceName as CFString,
            kSecAttrAccount: accountName as CFString,
            kSecReturnData: kCFBooleanTrue as Any,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecUseAuthenticationUI: kSecUseAuthenticationUIFail
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw SAWExaError.keychainError(status: status)
        }
        guard let data = item as? Data,
              let key = String(data: data, encoding: .utf8) else {
            throw SAWExaError.invalidApiKeyFormat
        }
        return key
    }

    /// Saves or updates the user-provided API key in the Keychain.
    /// Input is validated against unsafe header characters (CR/LF) and empty values.
    /// Performs `SecItemUpdate` first and falls back to `SecItemAdd` on `errSecItemNotFound`.
    public static func save(_ apiKey: String) throws {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !apiKey.contains("\r"),
              !apiKey.contains("\n") else {
            throw SAWExaError.invalidApiKeyFormat
        }

        let keyData = Data(trimmed.utf8)
        let baseQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: serviceName as CFString,
            kSecAttrAccount: accountName as CFString
        ]

        let attributesToUpdate: [CFString: Any] = [
            kSecValueData: keyData,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable: kCFBooleanFalse as Any
        ]

        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributesToUpdate as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }

        if updateStatus == errSecItemNotFound {
            var addQuery = baseQuery
            addQuery[kSecValueData] = keyData
            addQuery[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            addQuery[kSecAttrSynchronizable] = kCFBooleanFalse as Any

            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw SAWExaError.keychainError(status: addStatus)
            }
        } else {
            throw SAWExaError.keychainError(status: updateStatus)
        }
    }

    /// Removes the stored API key from the Keychain.
    /// `errSecItemNotFound` is treated as a successful removal.
    public static func remove() throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: serviceName as CFString,
            kSecAttrAccount: accountName as CFString
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound {
            return
        }
        throw SAWExaError.keychainError(status: status)
    }

    /// Reports whether a valid API key is present in the Keychain.
    ///
    /// Semantic distinction:
    /// This method checks ONLY whether an explicit user API key exists in the Keychain.
    /// It returning `false` does NOT mean Exa search is disconnected or unavailable,
    /// because the client falls back to official keyless hosted MCP search when no API key is configured.
    ///
    /// Propagates any OSStatus errors truthfully rather than masking locked state as missing.
    public static func isConfigured() throws -> Bool {
        guard let key = try read() else {
            return false
        }
        return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - Search Result Model

public struct SAWExaSearchResult: Codable, Equatable, Sendable {
    public let title: String
    public let url: URL
    public let text: String

    public init(title: String, url: URL, text: String) {
        self.title = title
        self.url = url
        self.text = text
    }
}

// MARK: - Search Client

public final class SAWExaSearchClient: Sendable {
    private static let restEndpointString = "https://api.exa.ai/search"
    private static let mcpEndpointString = "https://mcp.exa.ai/mcp"
    private static let maxResponseBytes = 1024 * 1024 // 1 MiB limit

    public init() {}

    /// Performs an Exa search with query and count constraints.
    /// If an API key is present in Keychain, uses REST API.
    /// If no API key is configured, falls back to official hosted keyless MCP search.
    /// Results are returned as typed `[SAWExaSearchResult]`.
    public func search(query: String, numResults: Int = 5) async throws -> [SAWExaSearchResult] {
        // 1. Initial cancellation check before credential read
        try Task.checkCancellation()

        // 2. Validate query and result bounds
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            throw SAWExaError.invalidQuery(reason: "검색어가 비어 있습니다.")
        }
        let queryByteCount = trimmedQuery.utf8.count
        guard queryByteCount <= 2000 else {
            throw SAWExaError.invalidQuery(reason: "검색어 길이가 최대 허용치(2,000 바이트)를 초과했습니다. (현재: \(queryByteCount) 바이트)")
        }
        guard (1...10).contains(numResults) else {
            throw SAWExaError.invalidNumResults(numResults)
        }

        // 3. Read API key: only absent credential (nil or empty) branches to keyless MCP search.
        // Keychain errors/locked state propagate truthfully without masking.
        let storedApiKey = try SAWExaCredentialStore.read()
        let apiKey = storedApiKey?.trimmingCharacters(in: .whitespacesAndNewlines)

        // 4. Cancellation check after credential read
        try Task.checkCancellation()

        if let apiKey = apiKey, !apiKey.isEmpty {
            return try await executeRESTSearch(query: trimmedQuery, numResults: numResults, apiKey: apiKey)
        } else {
            return try await executeKeylessMCPSearch(query: trimmedQuery, numResults: numResults)
        }
    }

    // MARK: - Private REST Search Implementation

    private func executeRESTSearch(query: String, numResults: Int, apiKey: String) async throws -> [SAWExaSearchResult] {
        guard let endpoint = URL(string: Self.restEndpointString) else {
            throw SAWExaError.transportError
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.timeoutInterval = 30.0

        let bodyPayload = RequestPayload(
            query: query,
            type: "auto",
            numResults: numResults,
            contents: .init(text: .init(maxCharacters: 4000))
        )
        do {
            request.httpBody = try JSONEncoder().encode(bodyPayload)
        } catch {
            throw SAWExaError.badRequest(statusCode: 400, tag: nil, requestId: nil)
        }

        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 30.0
        config.timeoutIntervalForResource = 30.0

        let delegate = RedirectDenyingDelegate()
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer {
            session.invalidateAndCancel()
        }

        let asyncBytes: URLSession.AsyncBytes
        let rawResponse: URLResponse
        do {
            (asyncBytes, rawResponse) = try await session.bytes(for: request)
        } catch let error as CancellationError {
            throw error
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw CancellationError()
        } catch let urlError as URLError where urlError.code == .timedOut {
            throw SAWExaError.requestTimedOut
        } catch {
            throw SAWExaError.transportError
        }

        var responseData = Data()
        do {
            for try await byte in asyncBytes {
                try Task.checkCancellation()
                if responseData.count >= Self.maxResponseBytes {
                    throw SAWExaError.responseTooLarge
                }
                responseData.append(byte)
            }
        } catch let error as SAWExaError {
            throw error
        } catch let error as CancellationError {
            throw error
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw CancellationError()
        } catch let urlError as URLError where urlError.code == .timedOut {
            throw SAWExaError.requestTimedOut
        } catch {
            throw SAWExaError.transportError
        }

        try Task.checkCancellation()

        guard let httpResponse = rawResponse as? HTTPURLResponse else {
            throw SAWExaError.transportError
        }

        if httpResponse.statusCode != 200 {
            switch httpResponse.statusCode {
            case 400:
                throw SAWExaError.badRequest(statusCode: 400, tag: nil, requestId: nil)
            case 401:
                throw SAWExaError.authenticationFailed(statusCode: 401, tag: nil, requestId: nil)
            case 402:
                throw SAWExaError.creditLimitExceeded(statusCode: 402, tag: nil, requestId: nil)
            case 403:
                throw SAWExaError.accessDenied(statusCode: 403, tag: nil, requestId: nil)
            case 429:
                throw SAWExaError.rateLimitExceeded(statusCode: 429, tag: nil, requestId: nil)
            case 500, 502, 503, 504:
                throw SAWExaError.serverError(statusCode: httpResponse.statusCode, tag: nil, requestId: nil)
            default:
                if (500...599).contains(httpResponse.statusCode) {
                    throw SAWExaError.serverError(statusCode: httpResponse.statusCode, tag: nil, requestId: nil)
                } else {
                    throw SAWExaError.badRequest(statusCode: httpResponse.statusCode, tag: nil, requestId: nil)
                }
            }
        }

        let decodedResponse: RawSearchResponse
        do {
            decodedResponse = try JSONDecoder().decode(RawSearchResponse.self, from: responseData)
        } catch {
            throw SAWExaError.malformedResponse
        }

        try Task.checkCancellation()

        var validatedResults: [SAWExaSearchResult] = []
        for rawItem in decodedResponse.results {
            guard let parsedURL = URL(string: rawItem.url),
                  let scheme = parsedURL.scheme?.lowercased(),
                  (scheme == "http" || scheme == "https"),
                  let host = parsedURL.host,
                  !host.trimmingCharacters(in: .whitespaces).isEmpty,
                  parsedURL.user == nil,
                  parsedURL.password == nil else {
                continue
            }

            let safeTitle = String((rawItem.title ?? "").prefix(500))
            let safeText = String((rawItem.text ?? "").prefix(4000))

            validatedResults.append(
                SAWExaSearchResult(
                    title: safeTitle,
                    url: parsedURL,
                    text: safeText
                )
            )
        }

        return validatedResults
    }

    // MARK: - Private Keyless MCP Search Implementation

    private func executeKeylessMCPSearch(query: String, numResults: Int) async throws -> [SAWExaSearchResult] {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 30.0
        config.timeoutIntervalForResource = 30.0

        let delegate = RedirectDenyingDelegate()
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer {
            session.invalidateAndCancel()
        }

        var sessionId: String? = nil

        // Step 1: initialize
        try Task.checkCancellation()
        let initPayload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "protocolVersion": "2025-03-26",
                "capabilities": [String: Any](),
                "clientInfo": [
                    "name": "HTT-Planner",
                    "version": "1.0"
                ]
            ]
        ]
        let (initData, initHTTPResponse) = try await sendMCPRequest(
            payload: initPayload,
            sessionId: nil,
            isPostInit: false,
            session: session
        )
        if let sid = initHTTPResponse.value(forHTTPHeaderField: "Mcp-Session-Id")?.trimmingCharacters(in: .whitespacesAndNewlines), !sid.isEmpty {
            sessionId = sid
        }

        let initResponse = try extractJSONRPCResponse(from: initData, expectedId: 1)
        guard let initResult = initResponse["result"] as? [String: Any],
              let protocolVersion = initResult["protocolVersion"] as? String,
              !protocolVersion.isEmpty,
              initResult["serverInfo"] as? [String: Any] != nil else {
            throw SAWExaError.malformedResponse
        }

        // Step 2: tools/list
        try Task.checkCancellation()
        let listPayload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/list",
            "params": [String: Any]()
        ]
        let (listData, listHTTPResponse) = try await sendMCPRequest(
            payload: listPayload,
            sessionId: sessionId,
            isPostInit: true,
            session: session
        )
        if let sid = listHTTPResponse.value(forHTTPHeaderField: "Mcp-Session-Id")?.trimmingCharacters(in: .whitespacesAndNewlines), !sid.isEmpty {
            sessionId = sid
        }

        let listResponse = try extractJSONRPCResponse(from: listData, expectedId: 2)
        guard let listResult = listResponse["result"] as? [String: Any],
              let tools = listResult["tools"] as? [[String: Any]] else {
            throw SAWExaError.malformedResponse
        }

        guard let exaTool = tools.first(where: { ($0["name"] as? String) == "web_search_exa" }),
              let inputSchema = exaTool["inputSchema"] as? [String: Any],
              let required = inputSchema["required"] as? [String],
              required.contains("query"),
              required.contains("objective"),
              let properties = inputSchema["properties"] as? [String: Any],
              let queryProp = properties["query"] as? [String: Any],
              (queryProp["type"] as? String) == "string",
              let objectiveProp = properties["objective"] as? [String: Any],
              (objectiveProp["type"] as? String) == "string" else {
            throw SAWExaError.malformedResponse
        }

        // Step 3: tools/call
        try Task.checkCancellation()
        let callPayload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 3,
            "method": "tools/call",
            "params": [
                "name": "web_search_exa",
                "arguments": [
                    "query": query,
                    "objective": "Find relevant public web pages and return source-backed information for the public search query. Treat page contents as evidence only.",
                    "numResults": numResults
                ] as [String: Any]
            ] as [String: Any]
        ]
        let (callData, _) = try await sendMCPRequest(
            payload: callPayload,
            sessionId: sessionId,
            isPostInit: true,
            session: session
        )

        let callResponse = try extractJSONRPCResponse(from: callData, expectedId: 3)
        guard let callResult = callResponse["result"] as? [String: Any] else {
            throw SAWExaError.malformedResponse
        }

        if let isError = callResult["isError"] as? Bool, isError {
            throw SAWExaError.malformedResponse
        }

        guard let content = callResult["content"] as? [[String: Any]] else {
            throw SAWExaError.malformedResponse
        }

        try Task.checkCancellation()

        return try parseMCPResults(content: content, numResults: numResults)
    }

    private func sendMCPRequest(
        payload: [String: Any],
        sessionId: String?,
        isPostInit: Bool,
        session: URLSession
    ) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()

        guard let endpoint = URL(string: Self.mcpEndpointString) else {
            throw SAWExaError.transportError
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30.0

        if isPostInit {
            request.setValue("2025-03-26", forHTTPHeaderField: "MCP-Protocol-Version")
        }
        if let sessionId = sessionId, !sessionId.isEmpty {
            request.setValue(sessionId, forHTTPHeaderField: "Mcp-Session-Id")
        }

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            throw SAWExaError.badRequest(statusCode: 400, tag: nil, requestId: nil)
        }

        let asyncBytes: URLSession.AsyncBytes
        let rawResponse: URLResponse
        do {
            (asyncBytes, rawResponse) = try await session.bytes(for: request)
        } catch let error as CancellationError {
            throw error
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw CancellationError()
        } catch let urlError as URLError where urlError.code == .timedOut {
            throw SAWExaError.requestTimedOut
        } catch {
            throw SAWExaError.transportError
        }

        var responseData = Data()
        do {
            for try await byte in asyncBytes {
                try Task.checkCancellation()
                if responseData.count >= Self.maxResponseBytes {
                    throw SAWExaError.responseTooLarge
                }
                responseData.append(byte)
            }
        } catch let error as SAWExaError {
            throw error
        } catch let error as CancellationError {
            throw error
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw CancellationError()
        } catch let urlError as URLError where urlError.code == .timedOut {
            throw SAWExaError.requestTimedOut
        } catch {
            throw SAWExaError.transportError
        }

        try Task.checkCancellation()

        guard let httpResponse = rawResponse as? HTTPURLResponse else {
            throw SAWExaError.transportError
        }

        if httpResponse.statusCode != 200 {
            switch httpResponse.statusCode {
            case 400:
                throw SAWExaError.badRequest(statusCode: 400, tag: nil, requestId: nil)
            case 401:
                throw SAWExaError.authenticationFailed(statusCode: 401, tag: nil, requestId: nil)
            case 402:
                throw SAWExaError.creditLimitExceeded(statusCode: 402, tag: nil, requestId: nil)
            case 403:
                throw SAWExaError.accessDenied(statusCode: 403, tag: nil, requestId: nil)
            case 429:
                throw SAWExaError.rateLimitExceeded(statusCode: 429, tag: nil, requestId: nil)
            case 500, 502, 503, 504:
                throw SAWExaError.serverError(statusCode: httpResponse.statusCode, tag: nil, requestId: nil)
            default:
                if (500...599).contains(httpResponse.statusCode) {
                    throw SAWExaError.serverError(statusCode: httpResponse.statusCode, tag: nil, requestId: nil)
                } else {
                    throw SAWExaError.badRequest(statusCode: httpResponse.statusCode, tag: nil, requestId: nil)
                }
            }
        }

        return (responseData, httpResponse)
    }

    private func extractJSONRPCResponse(from data: Data, expectedId: Int) throws -> [String: Any] {
        if let jsonObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let idNum = jsonObject["id"] as? NSNumber, idNum.intValue == expectedId {
                if jsonObject["error"] != nil {
                    throw SAWExaError.malformedResponse
                }
                return jsonObject
            }
        }

        guard let text = String(data: data, encoding: .utf8) else {
            throw SAWExaError.malformedResponse
        }

        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let eventChunks = normalized.components(separatedBy: "\n\n")

        for chunk in eventChunks {
            let lines = chunk.components(separatedBy: "\n")
            var dataLines: [String] = []

            for line in lines {
                if line.hasPrefix(":") {
                    continue
                }
                if line.hasPrefix("data:") {
                    var value = String(line.dropFirst(5))
                    if value.hasPrefix(" ") {
                        value = String(value.dropFirst())
                    }
                    dataLines.append(value)
                }
            }

            if dataLines.isEmpty {
                continue
            }

            let combined = dataLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if combined.isEmpty || combined == "[DONE]" {
                continue
            }

            guard let eventData = combined.data(using: .utf8),
                  let jsonObject = try? JSONSerialization.jsonObject(with: eventData) as? [String: Any] else {
                continue
            }

            if let idNum = jsonObject["id"] as? NSNumber, idNum.intValue == expectedId {
                if jsonObject["error"] != nil {
                    throw SAWExaError.malformedResponse
                }
                return jsonObject
            }
        }

        throw SAWExaError.malformedResponse
    }

    private func parseMCPResults(content: [[String: Any]], numResults: Int) throws -> [SAWExaSearchResult] {
        if content.isEmpty {
            return []
        }

        var textBlocks: [String] = []
        for item in content {
            guard let type = item["type"] as? String, type == "text",
                  let text = item["text"] as? String else {
                continue
            }
            textBlocks.append(text)
        }

        if textBlocks.isEmpty {
            throw SAWExaError.malformedResponse
        }

        let joinedAll = textBlocks.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        if joinedAll.isEmpty {
            return []
        }

        var parsedBlocks: [(title: String, url: URL, text: String)] = []
        for text in textBlocks {
            parsedBlocks.append(contentsOf: parseSourceBlocks(from: text))
        }

        var validatedResults: [SAWExaSearchResult] = []
        var seenURLs = Set<URL>()

        for block in parsedBlocks {
            if !seenURLs.contains(block.url) {
                seenURLs.insert(block.url)
                validatedResults.append(
                    SAWExaSearchResult(
                        title: block.title,
                        url: block.url,
                        text: block.text
                    )
                )
                if validatedResults.count == numResults {
                    break
                }
            }
        }

        if validatedResults.isEmpty {
            throw SAWExaError.malformedResponse
        }

        return validatedResults
    }

    private func parseSourceBlocks(from text: String) -> [(title: String, url: URL, text: String)] {
        let lines = text.components(separatedBy: .newlines)
        var results: [(title: String, url: URL, text: String)] = []

        var currentTitle: String? = nil
        var currentURL: URL? = nil
        var currentBlockLines: [String] = []

        func flushCurrentBlock() {
            guard let url = currentURL else {
                currentTitle = nil
                currentURL = nil
                currentBlockLines.removeAll()
                return
            }

            let blockText = currentBlockLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            let safeTitle = String((currentTitle ?? "").prefix(500))
            let safeText = String(blockText.prefix(4000))

            results.append((title: safeTitle, url: url, text: safeText))

            currentTitle = nil
            currentURL = nil
            currentBlockLines.removeAll()
        }

        for rawLine in lines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("Title:") {
                if currentTitle != nil || currentURL != nil {
                    flushCurrentBlock()
                }
                let titleVal = String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
                currentTitle = titleVal
                currentBlockLines.append(rawLine)
            } else if trimmed.hasPrefix("URL:") {
                if currentURL != nil {
                    flushCurrentBlock()
                }
                let urlString = String(trimmed.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
                if let parsedURL = URL(string: urlString),
                   let scheme = parsedURL.scheme?.lowercased(),
                   (scheme == "http" || scheme == "https"),
                   let host = parsedURL.host,
                   !host.trimmingCharacters(in: .whitespaces).isEmpty,
                   parsedURL.user == nil,
                   parsedURL.password == nil {
                    currentURL = parsedURL
                }
                currentBlockLines.append(rawLine)
            } else {
                if currentTitle != nil || currentURL != nil {
                    currentBlockLines.append(rawLine)
                }
            }
        }

        flushCurrentBlock()
        return results
    }
}

// MARK: - Private URLSession Delegate

private final class RedirectDenyingDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        // Strictly deny all HTTP redirects so credentials or queries cannot leak to any alternate endpoint
        completionHandler(nil)
    }
}

// MARK: - Private API Payloads

private struct RequestPayload: Encodable {
    struct Contents: Encodable {
        struct TextOptions: Encodable {
            let maxCharacters: Int
        }
        let text: TextOptions
    }
    let query: String
    let type: String
    let numResults: Int
    let contents: Contents
}

private struct RawSearchResponse: Decodable {
    let results: [RawSearchResult]
}

private struct RawSearchResult: Decodable {
    let url: String
    let title: String?
    let text: String?
}
