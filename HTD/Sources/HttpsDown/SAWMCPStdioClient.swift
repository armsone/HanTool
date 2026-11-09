import Foundation
import Darwin

struct SAWMCPClientError: Error, LocalizedError {
    enum Kind { case cancelled, busy, invalid, unsupported, schema, protocolError, timeout, process, toolFailed }

    let kind: Kind
    let message: String
    var output: String?
    var mayHaveExecuted: Bool

    init(_ kind: Kind, _ message: String, output: String? = nil, mayHaveExecuted: Bool = false) {
        self.kind = kind
        self.message = message
        self.output = output
        self.mayHaveExecuted = mayHaveExecuted
    }

    var errorDescription: String? { message }
}

// MARK: - Event mailbox (background reader threads -> async consumer)

private enum SAWMCPEvent: @unchecked Sendable {
    case line(String)
    case oversize
    case overflow
    case exit(EngineTaskResult)
    case timeout
    case cancelled
}

private final class SAWMCPMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [SAWMCPEvent] = []
    private var waiter: CheckedContinuation<SAWMCPEvent, Never>?
    private var token = 0
    private var overflowed = false

    func push(_ event: SAWMCPEvent) {
        lock.lock()
        if let current = waiter {
            waiter = nil
            token += 1
            lock.unlock()
            current.resume(returning: event)
            return
        }
        if queue.count >= 512 {
            if !overflowed {
                overflowed = true
                queue.append(.overflow)
            }
        } else {
            queue.append(event)
        }
        lock.unlock()
    }

    func next(timeout: TimeInterval) async -> SAWMCPEvent {
        await withCheckedContinuation { (continuation: CheckedContinuation<SAWMCPEvent, Never>) in
            lock.lock()
            if !queue.isEmpty {
                let event = queue.removeFirst()
                lock.unlock()
                continuation.resume(returning: event)
                return
            }
            waiter = continuation
            token += 1
            let mine = token
            lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + max(timeout, 0.01)) { [weak self] in
                self?.fire(token: mine)
            }
        }
    }

    private func fire(token expected: Int) {
        lock.lock()
        guard let current = waiter, token == expected else {
            lock.unlock()
            return
        }
        waiter = nil
        token += 1
        lock.unlock()
        current.resume(returning: .timeout)
    }
}

// MARK: - Bounded stderr diagnostics (failure context only)

private final class SAWMCPStderrCollector: @unchecked Sendable {
    static let limit = 4_000

    private let lock = NSLock()
    private var text = ""
    private var used = 0

    private static let patterns: [(NSRegularExpression, String)] = [
        ("\u{1B}\\[[0-9;?]*[ -/]*[@-~]", ""),
        ("(?i)(bearer\\s+)[A-Za-z0-9._~+/=-]+", "$1[redacted]"),
        ("(?i)((?:api[_-]?key|token|secret|password|passwd|authorization)\\s*[=:]\\s*)\\S+", "$1[redacted]"),
        ("\\bsk-[A-Za-z0-9_-]{16,}", "[redacted]")
    ].compactMap { pair in (try? NSRegularExpression(pattern: pair.0)).map { ($0, pair.1) } }

    func append(_ rawLine: String) {
        var line = rawLine
        for (regex, template) in Self.patterns {
            line = regex.stringByReplacingMatches(in: line, range: NSRange(line.startIndex..., in: line), withTemplate: template)
        }
        line = String(String.UnicodeScalarView(line.unicodeScalars.compactMap { scalar -> Unicode.Scalar? in
            if scalar == "\t" { return " " }
            if scalar.value < 0x20 || (scalar.value >= 0x7f && scalar.value <= 0x9f) { return nil }
            return scalar
        }))
        guard !line.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        for scalar in (line + "\n").unicodeScalars {
            let width = String(scalar).utf16.count
            if used + width > Self.limit { return }
            text.unicodeScalars.append(scalar)
            used += width
        }
    }

    var snapshot: String {
        lock.lock()
        defer { lock.unlock() }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - One owned server process

private final class SAWMCPSession: @unchecked Sendable {
    static let maxLineBytes = 262_144
    static let processTimeout: TimeInterval = 119

    let mailbox = SAWMCPMailbox()
    private let stderr = SAWMCPStderrCollector()
    private let lock = NSLock()
    private var handle: EngineTaskHandle?
    private var aborted = false
    private var activeID: String?
    private var exitResult: EngineTaskResult?

    func start(launch: SAWToolLaunch, first: Data) {
        let box = mailbox
        let limit = Self.maxLineBytes
        let collector = stderr
        let started = EngineBridge.shared.launch(
            jobId: "saw-mcp-\(UUID().uuidString)", generation: 1,
            executable: launch.executable, arguments: launch.arguments,
            environment: launch.environment, workingDirectory: launch.workingDirectory,
            onDiagnosticLine: { collector.append($0) },
            stdinData: first, timeout: Self.processTimeout, keepStdinOpen: true,
            onLine: { line in
                if line.utf8.count > limit { box.push(.oversize) } else { box.push(.line(line)) }
            },
            onExit: { box.push(.exit($0)) })
        lock.lock()
        handle = started
        let already = aborted
        lock.unlock()
        if already { started.cancel() }
    }

    func send(_ data: Data) -> Bool {
        lock.lock()
        let current = handle
        lock.unlock()
        return current?.sendLine(data) ?? false
    }

    func setActive(_ id: String?) {
        lock.lock()
        activeID = id
        lock.unlock()
    }

    func closeStdin() {
        lock.lock()
        let current = handle
        lock.unlock()
        current?.closeStdin()
    }

    func cancelProcess() {
        lock.lock()
        aborted = true
        let current = handle
        lock.unlock()
        current?.cancel()
    }

    /// notifications/cancelled for the active request, then closeStdin, then EngineHandle.cancel.
    func abort() {
        lock.lock()
        aborted = true
        let current = handle
        let id = activeID
        lock.unlock()
        if let current {
            if let id, let data = SAWMCPStdioClient.cancelNotification(id) { _ = current.sendLine(data) }
            current.closeStdin()
            current.cancel()
        }
        mailbox.push(.cancelled)
    }

    var recordedExit: EngineTaskResult? {
        lock.lock()
        defer { lock.unlock() }
        return exitResult
    }

    func record(_ result: EngineTaskResult) {
        lock.lock()
        exitResult = result
        lock.unlock()
    }

    /// Human-facing premature-exit message: safe base text, exit status when known, bounded sanitized stderr.
    func prematureExitMessage(_ result: EngineTaskResult) -> String {
        var message = "MCP 서버 프로세스가 응답 전에 종료되었습니다."
        if let spawnError = result.spawnError {
            message += " (\(SAWBoundedText.clip(spawnError, limit: 200).text))"
        } else if let signal = result.terminatedBySignal {
            message += " (시그널 \(signal))"
        } else if let code = result.exitCode {
            message += " (종료 코드 \(code))"
        }
        let detail = stderr.snapshot
        if !detail.isEmpty { message += "\n서버 stderr:\n" + detail }
        return message
    }

    /// Cancellation-aware wait for the next event (task cancel wakes the waiter).
    func next(timeout: TimeInterval) async -> SAWMCPEvent {
        await withTaskCancellationHandler {
            await mailbox.next(timeout: timeout)
        } onCancel: { [mailbox] in
            mailbox.push(.cancelled)
        }
    }

    /// Plain wait used during shutdown (ignores cancellation so it cannot spin).
    func waitExit(timeout: TimeInterval) async -> EngineTaskResult? {
        if let known = recordedExit { return known }
        let end = Date().addingTimeInterval(timeout)
        while true {
            let remaining = end.timeIntervalSinceNow
            if remaining <= 0 { return nil }
            switch await mailbox.next(timeout: min(0.25, remaining)) {
            case .exit(let result):
                record(result)
                return result
            default:
                continue
            }
        }
    }
}

// MARK: - JSON helpers and schema subset

private struct SAWJSONLimits {
    let maxBytes: Int
    let maxDepth: Int
    let maxNodes: Int
    static let arguments = SAWJSONLimits(maxBytes: 16_384, maxDepth: 8, maxNodes: 1_024)
    static let wire = SAWJSONLimits(maxBytes: SAWMCPSession.maxLineBytes, maxDepth: 32, maxNodes: 20_000)
}

private enum SAWJSON {
    static func within(_ value: Any, limits: SAWJSONLimits) -> Bool {
        var nodes = 0
        return walk(value, depth: 1, limits: limits, nodes: &nodes)
    }

    private static func walk(_ value: Any, depth: Int, limits: SAWJSONLimits, nodes: inout Int) -> Bool {
        nodes += 1
        if nodes > limits.maxNodes || depth > limits.maxDepth { return false }
        if let dictionary = value as? [String: Any] {
            for (_, child) in dictionary where !walk(child, depth: depth + 1, limits: limits, nodes: &nodes) { return false }
        } else if let array = value as? [Any] {
            for child in array where !walk(child, depth: depth + 1, limits: limits, nodes: &nodes) { return false }
        }
        return true
    }

    static func parseObject(_ text: String, limits: SAWJSONLimits) -> [String: Any]? {
        guard text.utf8.count <= limits.maxBytes,
              let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              within(object, limits: limits) else { return nil }
        return object
    }

    static func compact(_ value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(value) || value is String || value is NSNumber || value is NSNull,
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func isBool(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }
}

/// JSON Schema 2020-12 subset: anything outside it is rejected, never silently ignored.
private enum SAWSchema {
    static let dialect = "https://json-schema.org/draft/2020-12/schema"
    static let metadata: Set<String> = ["$schema", "$id", "$comment", "title", "description", "default", "examples", "deprecated", "readOnly", "writeOnly", "format", "$defs"]
    static let supported: Set<String> = ["type", "properties", "required", "additionalProperties", "items", "enum", "const", "minLength", "maxLength", "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "minItems", "maxItems"]
    static let types: Set<String> = ["object", "array", "string", "number", "integer", "boolean", "null"]

    static func unsupported(_ detail: String) -> SAWMCPClientError {
        SAWMCPClientError(.schema, "지원하지 않는 입력 스키마입니다: \(detail)")
    }

    static func checkRoot(_ schema: [String: Any]) throws {
        guard (schema["type"] as? String) == "object" else { throw unsupported("최상위 type은 object여야 합니다") }
        try check(schema, depth: 0)
    }

    private static func check(_ schema: [String: Any], depth: Int) throws {
        guard depth <= 8 else { throw unsupported("중첩이 너무 깊습니다") }
        for key in schema.keys where !supported.contains(key) && !metadata.contains(key) {
            throw unsupported("키워드 \(SAWBoundedText.clip(key, limit: 40).text)")
        }
        if let dialectValue = schema["$schema"], (dialectValue as? String) != dialect { throw unsupported("$schema 방언") }
        if let type = schema["type"] {
            if let one = type as? String {
                guard types.contains(one) else { throw unsupported("type") }
            } else if let many = type as? [String], !many.isEmpty, many.allSatisfy({ types.contains($0) }) {
                // ok
            } else {
                throw unsupported("type")
            }
        }
        if let properties = schema["properties"] {
            guard let map = properties as? [String: Any] else { throw unsupported("properties") }
            for (_, child) in map {
                guard let sub = child as? [String: Any] else { throw unsupported("properties 항목") }
                try check(sub, depth: depth + 1)
            }
        }
        if let required = schema["required"], (required as? [String]) == nil { throw unsupported("required") }
        if let extra = schema["additionalProperties"] {
            if let sub = extra as? [String: Any] {
                try check(sub, depth: depth + 1)
            } else if !SAWJSON.isBool(extra) {
                throw unsupported("additionalProperties")
            }
        }
        if let items = schema["items"] {
            guard let sub = items as? [String: Any] else { throw unsupported("items") }
            try check(sub, depth: depth + 1)
        }
        if let values = schema["enum"] {
            guard let array = values as? [Any], !array.isEmpty, array.count <= 256 else { throw unsupported("enum") }
        }
        for key in ["minLength", "maxLength", "minItems", "maxItems"] {
            if let raw = schema[key] {
                guard !SAWJSON.isBool(raw), let number = raw as? NSNumber, number.doubleValue >= 0, number.doubleValue == number.doubleValue.rounded() else { throw unsupported(key) }
            }
        }
        for key in ["minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum"] {
            if let raw = schema[key] {
                guard !SAWJSON.isBool(raw), raw is NSNumber else { throw unsupported(key) }
            }
        }
    }

    private static func fail(_ path: String, _ reason: String) -> SAWMCPClientError {
        SAWMCPClientError(.schema, "인자 검증 실패 (\(path)): \(reason)")
    }

    private static func matches(_ value: Any, type: String) -> Bool {
        switch type {
        case "null": return value is NSNull
        case "boolean": return SAWJSON.isBool(value)
        case "string": return value is String
        case "array": return value is [Any]
        case "object": return value is [String: Any]
        case "number": return !SAWJSON.isBool(value) && value is NSNumber
        case "integer":
            guard !SAWJSON.isBool(value), let number = value as? NSNumber else { return false }
            let d = number.doubleValue
            return d.isFinite && d == d.rounded()
        default: return false
        }
    }

    static func validate(_ value: Any, _ schema: [String: Any], path: String) throws {
        if let type = schema["type"] {
            let allowed = (type as? [String]) ?? [type as? String ?? ""]
            guard allowed.contains(where: { matches(value, type: $0) }) else { throw fail(path, "type이 맞지 않습니다") }
        }
        if let values = schema["enum"] as? [Any] {
            let mine = SAWJSON.compact(value)
            guard mine != nil, values.contains(where: { SAWJSON.compact($0) == mine }) else { throw fail(path, "허용된 값이 아닙니다") }
        }
        if let constant = schema["const"], SAWJSON.compact(constant) != SAWJSON.compact(value) {
            throw fail(path, "고정 값과 다릅니다")
        }
        if let text = value as? String {
            let length = text.unicodeScalars.count
            if let n = (schema["minLength"] as? NSNumber)?.intValue, length < n { throw fail(path, "너무 짧습니다") }
            if let n = (schema["maxLength"] as? NSNumber)?.intValue, length > n { throw fail(path, "너무 깁니다") }
        }
        if !SAWJSON.isBool(value), let number = value as? NSNumber {
            let d = number.doubleValue
            if let b = (schema["minimum"] as? NSNumber)?.doubleValue, d < b { throw fail(path, "최솟값 미만입니다") }
            if let b = (schema["maximum"] as? NSNumber)?.doubleValue, d > b { throw fail(path, "최댓값 초과입니다") }
            if let b = (schema["exclusiveMinimum"] as? NSNumber)?.doubleValue, d <= b { throw fail(path, "하한 이하입니다") }
            if let b = (schema["exclusiveMaximum"] as? NSNumber)?.doubleValue, d >= b { throw fail(path, "상한 이상입니다") }
        }
        if let array = value as? [Any] {
            if let n = (schema["minItems"] as? NSNumber)?.intValue, array.count < n { throw fail(path, "항목이 너무 적습니다") }
            if let n = (schema["maxItems"] as? NSNumber)?.intValue, array.count > n { throw fail(path, "항목이 너무 많습니다") }
            if let items = schema["items"] as? [String: Any] {
                for (index, element) in array.enumerated() { try validate(element, items, path: "\(path)[\(index)]") }
            }
        }
        if let object = value as? [String: Any] {
            for key in (schema["required"] as? [String]) ?? [] where object[key] == nil { throw fail(path, "필수 항목 \(SAWBoundedText.clip(key, limit: 40).text) 누락") }
            let properties = schema["properties"] as? [String: Any] ?? [:]
            for (key, child) in object {
                let childPath = "\(path).\(SAWBoundedText.clip(key, limit: 40).text)"
                if let sub = properties[key] as? [String: Any] {
                    try validate(child, sub, path: childPath)
                } else if let extra = schema["additionalProperties"] {
                    if let sub = extra as? [String: Any] {
                        try validate(child, sub, path: childPath)
                    } else if let allowed = extra as? NSNumber, SAWJSON.isBool(allowed), !allowed.boolValue {
                        throw fail(childPath, "허용되지 않은 추가 항목입니다")
                    }
                }
            }
        }
    }
}

// MARK: - Path-like argument values

private enum SAWMCPPaths {
    static func looksLikePath(_ value: String) -> Bool {
        value.hasPrefix("/") || value.hasPrefix("./") || value.hasPrefix("../") || value.hasPrefix("~") || value == "." || value == ".."
            || value.contains("/../") || value.hasSuffix("/..") || value.lowercased().hasPrefix("file:")
    }

    private static func canonical(_ path: String) -> String? {
        guard !path.utf8.contains(0) else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        guard realpath(path, &buffer) != nil else { return nil }
        return String(cString: buffer)
    }

    private static func canonicalAllowingMissing(_ path: String) -> String? {
        var components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var rest: [String] = []
        while true {
            if let real = canonical("/" + components.joined(separator: "/")) {
                if rest.contains(where: { $0 == ".." || $0 == "." }) { return nil }
                return rest.isEmpty ? real : (real == "/" ? "" : real) + "/" + rest.joined(separator: "/")
            }
            guard let last = components.popLast() else { return nil }
            rest.insert(last, at: 0)
        }
    }

    private static func inside(_ path: String, _ root: String) -> Bool {
        path == root || path.hasPrefix(root + "/")
    }

    static func check(_ value: Any, launch: SAWToolLaunch) throws {
        let out = launch.outputDirectory.path
        let parts = out.split(separator: "/").map(String.init)
        var root: String?
        if parts.count > 5, parts[parts.count - 4] == ".HTT-Planner" {
            root = "/" + parts.dropLast(4).joined(separator: "/")
        }
        try walk(value, root: root, out: out)
    }

    private static func walk(_ value: Any, root: String?, out: String) throws {
        if let text = value as? String {
            guard looksLikePath(text) else { return }
            let denied = SAWMCPClientError(.invalid, "경로 인자는 승인된 작업 폴더 또는 이번 실행의 출력 폴더 안이어야 합니다.")
            guard let root, !text.hasPrefix("~"), !text.lowercased().hasPrefix("file:"), text.utf8.count <= 4096, !text.contains("\n") else { throw denied }
            let absolute = text.hasPrefix("/") ? text : root + "/" + text
            guard let real = canonicalAllowingMissing(absolute) else { throw denied }
            let allowed = inside(real, out) || (inside(real, root) && !inside(real, root + "/.HTT-Planner"))
            guard allowed else { throw denied }
        } else if let dictionary = value as? [String: Any] {
            for (_, child) in dictionary { try walk(child, root: root, out: out) }
        } else if let array = value as? [Any] {
            for child in array { try walk(child, root: root, out: out) }
        }
    }
}

// MARK: - Protocol operation

private enum SAWMCPOutcome {
    case result([String: Any])
    case error(Int)
}

private struct SAWMCPToolEntry {
    let name: String
    let description: String
    let schema: [String: Any]?
    let canonical: String?
}

@MainActor
private final class SAWMCPOperation {
    enum Mode { case unknown, modern, legacy }

    let session: SAWMCPSession
    let deadline: Date
    let current: () -> Bool
    var mode = Mode.unknown
    var callSent = false
    private var retired = Set<String>()
    private var chatter = 0

    init(session: SAWMCPSession, deadline: Date, current: @escaping () -> Bool) {
        self.session = session
        self.deadline = deadline
        self.current = current
    }

    private func send(_ object: [String: Any]) throws {
        let data = try SAWMCPStdioClient.encode(object)
        guard session.send(data) else { throw SAWMCPClientError(.process, "MCP 서버 입력 채널에 쓸 수 없습니다.") }
    }

    func negotiate(probeID: String) async throws {
        let probeDeadline = min(deadline, Date().addingTimeInterval(3))
        do {
            switch try await awaitResponse(id: probeID, until: probeDeadline) {
            case .result(let result):
                if let versions = result["supportedVersions"] as? [String], versions.contains(SAWMCPStdioClient.modernVersion) {
                    mode = .modern
                    return
                }
            case .error(let code):
                if code == -32022 {
                    throw SAWMCPClientError(.unsupported, "서버가 이 앱이 지원하는 MCP 프로토콜 버전(\(SAWMCPStdioClient.modernVersion))을 지원하지 않습니다.")
                }
            }
        } catch let error as SAWMCPClientError where error.kind == .timeout {
            // short timeout: fall through to the legacy handshake on the same process
        }
        retired.insert(probeID)
        try await legacyInitialize()
    }

    private func legacyInitialize() async throws {
        let id = UUID().uuidString
        try send(["jsonrpc": "2.0", "id": id, "method": "initialize", "params": [
            "protocolVersion": "2025-11-25",
            "capabilities": [String: Any](),
            "clientInfo": ["name": "HTT-Planner", "version": SAWMCPStdioClient.clientVersion]
        ] as [String: Any]])
        session.setActive(id)
        defer { session.setActive(nil) }
        let outcome = try await awaitResponse(id: id, until: min(deadline, Date().addingTimeInterval(30)))
        guard case .result(let result) = outcome else {
            throw SAWMCPClientError(.protocolError, "MCP 서버가 초기화를 거부했습니다.")
        }
        guard let version = result["protocolVersion"] as? String, SAWMCPStdioClient.legacyVersions.contains(version) else {
            throw SAWMCPClientError(.unsupported, "서버가 지원하는 MCP 프로토콜 버전을 이 앱이 지원하지 않습니다.")
        }
        try send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        mode = .legacy
    }

    /// One request/response on the negotiated protocol. Modern mode carries `_meta` on every request.
    func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        let id = UUID().uuidString
        var payload = params
        if mode == .modern { payload["_meta"] = SAWMCPStdioClient.modernMeta }
        if method == "tools/call" { callSent = true }
        try send(["jsonrpc": "2.0", "id": id, "method": method, "params": payload])
        session.setActive(id)
        defer { session.setActive(nil) }
        let outcome: SAWMCPOutcome
        do {
            outcome = try await awaitResponse(id: id, until: deadline)
        } catch let error as SAWMCPClientError where error.kind == .timeout || error.kind == .cancelled {
            if let data = SAWMCPStdioClient.cancelNotification(id) { _ = session.send(data) }
            retired.insert(id)
            throw error
        }
        switch outcome {
        case .error(let code):
            throw SAWMCPClientError(.protocolError, "MCP 서버가 요청을 오류로 거절했습니다 (코드 \(code)).")
        case .result(let result):
            if let kind = result["resultType"] {
                let text = kind as? String
                if text == "input_required" { throw SAWMCPClientError(.unsupported, "추가 입력이 필요한 MCP 응답은 지원하지 않습니다.") }
                if text != "complete" { throw SAWMCPClientError(.unsupported, "지원하지 않는 MCP 결과 유형입니다.") }
            }
            return result
        }
    }

    private func awaitResponse(id: String, until limit: Date) async throws -> SAWMCPOutcome {
        while true {
            if !current() || Task.isCancelled { throw SAWMCPClientError(.cancelled, "취소되었습니다.") }
            let remaining = limit.timeIntervalSinceNow
            if remaining <= 0 { throw SAWMCPClientError(.timeout, "MCP 서버 응답 시간이 초과되었습니다.") }
            switch await session.next(timeout: min(0.5, remaining)) {
            case .timeout:
                continue
            case .cancelled:
                throw SAWMCPClientError(.cancelled, "취소되었습니다.")
            case .exit(let result):
                session.record(result)
                throw SAWMCPClientError(.process, session.prematureExitMessage(result))
            case .oversize:
                throw SAWMCPClientError(.protocolError, "MCP 서버 출력 한 줄이 너무 큽니다.")
            case .overflow:
                throw SAWMCPClientError(.protocolError, "MCP 서버가 너무 많은 출력을 보냈습니다.")
            case .line(let line):
                if let outcome = try handle(line: line, expecting: id) { return outcome }
            }
        }
    }

    private func handle(line: String, expecting id: String) throws -> SAWMCPOutcome? {
        guard let object = SAWJSON.parseObject(line, limits: .wire), (object["jsonrpc"] as? String) == "2.0" else {
            throw SAWMCPClientError(.protocolError, "MCP 서버 stdout이 올바른 JSON-RPC가 아닙니다.")
        }
        if let method = object["method"] as? String {
            chatter += 1
            guard chatter <= 1_000 else { throw SAWMCPClientError(.protocolError, "MCP 서버 알림이 너무 많습니다.") }
            if let requestID = object["id"], !(requestID is NSNull) {
                // Server-initiated requests: only ping is answered; no roots/sampling/elicitation are advertised.
                if method == "ping" {
                    try send(["jsonrpc": "2.0", "id": requestID, "result": [String: Any]()])
                } else {
                    try send(["jsonrpc": "2.0", "id": requestID, "error": ["code": -32601, "message": "Method not found"] as [String: Any]])
                }
            }
            return nil
        }
        guard let responseID = object["id"] as? String else {
            throw SAWMCPClientError(.protocolError, "MCP 응답 ID가 문자열이 아닙니다.")
        }
        if responseID != id {
            if retired.contains(responseID) { return nil }
            throw SAWMCPClientError(.protocolError, "알 수 없는 MCP 응답 ID를 받았습니다.")
        }
        let hasResult = object["result"] != nil
        let hasError = object["error"] != nil
        guard hasResult != hasError else { throw SAWMCPClientError(.protocolError, "MCP 응답에 result 또는 error가 올바르지 않습니다.") }
        if let result = object["result"] {
            guard let dictionary = result as? [String: Any] else { throw SAWMCPClientError(.protocolError, "MCP result 형식이 올바르지 않습니다.") }
            return .result(dictionary)
        }
        guard let error = object["error"] as? [String: Any], let code = (error["code"] as? NSNumber)?.intValue, !SAWJSON.isBool(error["code"] as Any) else {
            throw SAWMCPClientError(.protocolError, "MCP error 형식이 올바르지 않습니다.")
        }
        return .error(code)
    }

    func fetchTools() async throws -> [SAWMCPToolEntry] {
        var entries: [SAWMCPToolEntry] = []
        var cursor: String?
        for _ in 0..<16 {
            var params: [String: Any] = [:]
            if let cursor { params["cursor"] = cursor }
            let result = try await request("tools/list", params: params)
            guard let tools = result["tools"] as? [Any] else { throw SAWMCPClientError(.protocolError, "tools/list 결과에 tools 배열이 없습니다.") }
            for item in tools {
                guard entries.count < 128 else { throw SAWMCPClientError(.invalid, "MCP 도구가 128개를 초과합니다.") }
                guard let dictionary = item as? [String: Any], let name = dictionary["name"] as? String else {
                    throw SAWMCPClientError(.protocolError, "tools/list 항목 형식이 올바르지 않습니다.")
                }
                let description = SAWBoundedText.clip((dictionary["description"] as? String) ?? "", limit: 1_000).text
                var schema: [String: Any]?
                var canonical: String?
                if let raw = dictionary["inputSchema"] as? [String: Any], SAWJSON.within(raw, limits: .arguments),
                   let text = SAWJSON.compact(raw), text.utf8.count <= 16_384 {
                    schema = raw
                    canonical = text
                }
                entries.append(SAWMCPToolEntry(name: name, description: description, schema: schema, canonical: canonical))
            }
            if let next = result["nextCursor"], !(next is NSNull) {
                guard let text = next as? String, text.utf8.count <= 1_024 else { throw SAWMCPClientError(.protocolError, "nextCursor 형식이 올바르지 않습니다.") }
                if text.isEmpty { return entries }
                cursor = text
            } else {
                return entries
            }
        }
        throw SAWMCPClientError(.invalid, "MCP 도구 목록 페이지가 16개를 초과합니다.")
    }
}

// MARK: - Client

@MainActor
final class SAWMCPStdioClient {
    nonisolated static let modernVersion = "2026-07-28"
    nonisolated static let legacyVersions = ["2025-11-25", "2025-06-18", "2025-03-26"]
    /// Metadata only: outer HTT app version when running as its helper, else this bundle's version, else "unknown".
    nonisolated static let clientVersion: String = {
        func clean(_ value: Any?) -> String? {
            guard let text = value as? String, (1...64).contains(text.utf8.count),
                  text.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5a) || ($0 >= 0x61 && $0 <= 0x7a) || $0 == 0x2e || $0 == 0x2d || $0 == 0x2b }) else { return nil }
            return text
        }
        let key = "CFBundleShortVersionString"
        let url = Bundle.main.bundleURL
        let parts = url.pathComponents
        if parts.count >= 4, url.pathExtension == "app", parts[parts.count - 2] == "Helpers", parts[parts.count - 3] == "Contents",
           parts[parts.count - 4].hasSuffix(".app") {
            let parentURL = url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            if let parent = Bundle(url: parentURL), let id = parent.bundleIdentifier, id.hasPrefix("com.local.screentranslator"),
               let version = clean(parent.object(forInfoDictionaryKey: key)) {
                return version
            }
        }
        return clean(Bundle.main.object(forInfoDictionaryKey: key)) ?? "unknown"
    }()
    nonisolated static let modernMeta: [String: Any] = [
        "io.modelcontextprotocol/protocolVersion": modernVersion,
        "io.modelcontextprotocol/clientInfo": ["name": "HTT-Planner", "version": clientVersion],
        "io.modelcontextprotocol/clientCapabilities": [String: Any]()
    ]
    private static let totalBudget: TimeInterval = 115
    private static let resultLimit = 64_000

    private var session: SAWMCPSession?
    private var generation = 0

    init() {}

    /// Aborts the active server: cancelled notification, closeStdin, process-group cancel. Late results are discarded.
    func cancel() {
        generation += 1
        let active = session
        session = nil
        active?.abort()
    }

    nonisolated static func isValidToolName(_ name: String) -> Bool {
        (1...128).contains(name.utf8.count) && name.utf8.allSatisfy {
            ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5a) || ($0 >= 0x61 && $0 <= 0x7a) || $0 == 0x5f || $0 == 0x2e || $0 == 0x2d
        }
    }

    nonisolated fileprivate static func encode(_ object: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
              data.count <= 65_536 else {
            throw SAWMCPClientError(.invalid, "MCP 요청을 만들 수 없거나 너무 큽니다.")
        }
        return data
    }

    nonisolated fileprivate static func cancelNotification(_ id: String) -> Data? {
        try? encode(["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": id, "reason": "client cancelled"] as [String: Any]])
    }

    func listTools(launch: SAWToolLaunch, isCurrent: @escaping () -> Bool) async throws -> [SAWMCPTool] {
        let entries = try await run(launch: launch, isCurrent: isCurrent) { operation in
            try await operation.fetchTools()
        }
        var seen = Set<String>()
        var tools: [SAWMCPTool] = []
        for entry in entries where Self.isValidToolName(entry.name) && seen.insert(entry.name).inserted {
            guard let schema = entry.schema, let canonical = entry.canonical, (try? SAWSchema.checkRoot(schema)) != nil else { continue }
            tools.append(SAWMCPTool(name: entry.name, toolDescription: entry.description, inputSchemaJSON: canonical))
        }
        return tools
    }

    func callTool(launch: SAWToolLaunch, toolName: String, argumentsJSON: String, expectedSchemaJSON: String, isCurrent: @escaping () -> Bool) async throws -> String {
        guard Self.isValidToolName(toolName) else { throw SAWMCPClientError(.invalid, "MCP 도구 이름이 올바르지 않습니다.") }
        guard let arguments = SAWJSON.parseObject(argumentsJSON, limits: .arguments) else {
            throw SAWMCPClientError(.invalid, "도구 인자는 16KiB, 깊이 8, 노드 1024 이하의 JSON 객체여야 합니다.")
        }
        guard let expected = SAWJSON.parseObject(expectedSchemaJSON, limits: .arguments), let expectedCanonical = SAWJSON.compact(expected) else {
            throw SAWMCPClientError(.schema, "저장된 도구 스키마를 읽을 수 없습니다.")
        }
        try SAWSchema.checkRoot(expected)
        try SAWSchema.validate(arguments, expected, path: "$")
        try SAWMCPPaths.check(arguments, launch: launch)

        return try await run(launch: launch, isCurrent: isCurrent) { operation in
            let entries = try await operation.fetchTools()
            guard let entry = entries.first(where: { $0.name == toolName }) else {
                throw SAWMCPClientError(.invalid, "서버가 요청한 도구를 제공하지 않습니다.")
            }
            guard let actual = entry.schema, let actualCanonical = entry.canonical else {
                throw SAWMCPClientError(.schema, "서버의 도구 스키마가 너무 크거나 올바르지 않습니다.")
            }
            try SAWSchema.checkRoot(actual)
            guard actualCanonical == expectedCanonical else {
                throw SAWMCPClientError(.schema, "서버의 현재 도구 스키마가 허용 시점에 저장된 정의와 다릅니다. 도구 목록을 다시 불러와 주세요.")
            }
            try SAWSchema.validate(arguments, actual, path: "$")
            let result = try await operation.request("tools/call", params: ["name": toolName, "arguments": arguments])
            let rendered = try Self.render(result)
            if rendered.isError { throw SAWMCPClientError(.toolFailed, "MCP 도구가 오류를 반환했습니다.", output: rendered.text) }
            return rendered.text
        }
    }

    private static func render(_ result: [String: Any]) throws -> (text: String, isError: Bool) {
        var parts: [String] = []
        if let content = result["content"] {
            guard let items = content as? [Any] else { throw SAWMCPClientError(.protocolError, "MCP content 형식이 올바르지 않습니다.") }
            for item in items.prefix(64) {
                guard let dictionary = item as? [String: Any], let type = dictionary["type"] as? String else {
                    throw SAWMCPClientError(.protocolError, "MCP content 항목 형식이 올바르지 않습니다.")
                }
                if type == "text" {
                    guard let text = dictionary["text"] as? String else { throw SAWMCPClientError(.protocolError, "MCP text 항목이 올바르지 않습니다.") }
                    parts.append(text)
                } else {
                    parts.append("[\(type == "image" || type == "audio" || type == "resource" || type == "resource_link" ? type : "unknown") 콘텐츠는 표시하지 않습니다]")
                }
            }
        }
        if let structured = result["structuredContent"], !(structured is NSNull), let text = SAWJSON.compact(structured) {
            parts.append("structuredContent: " + text)
        }
        var isError = false
        if let raw = result["isError"], !(raw is NSNull) {
            guard SAWJSON.isBool(raw), let flag = raw as? NSNumber else { throw SAWMCPClientError(.protocolError, "isError 형식이 올바르지 않습니다.") }
            isError = flag.boolValue
        }
        let joined = parts.isEmpty ? "(출력 없음)" : parts.joined(separator: "\n")
        let clipped = SAWBoundedText.clip(joined, limit: resultLimit)
        return (clipped.text + (clipped.truncated ? "\n[출력이 잘렸습니다]" : ""), isError)
    }

    /// Spawns one owned server process, runs `body`, then always closes stdin and waits for a clean group exit.
    private func run<T>(launch: SAWToolLaunch, isCurrent: @escaping () -> Bool, body: (SAWMCPOperation) async throws -> T) async throws -> T {
        guard session == nil else { throw SAWMCPClientError(.busy, "MCP 클라이언트가 이미 사용 중입니다(busy).") }
        let token = generation
        let current: () -> Bool = { [weak self] in
            guard let self else { return false }
            return self.generation == token && isCurrent()
        }
        guard current(), !Task.isCancelled else { throw SAWMCPClientError(.cancelled, "취소되었습니다.") }

        let probeID = UUID().uuidString
        let probe = try Self.encode(["jsonrpc": "2.0", "id": probeID, "method": "server/discover", "params": ["_meta": Self.modernMeta] as [String: Any]])
        let active = SAWMCPSession()
        session = active
        let operation = SAWMCPOperation(session: active, deadline: Date().addingTimeInterval(Self.totalBudget), current: current)
        active.start(launch: launch, first: probe)

        var value: T?
        var failure: Error?
        do {
            try await operation.negotiate(probeID: probeID)
            value = try await body(operation)
        } catch {
            failure = error
        }

        let healthy = failure == nil && current() && !Task.isCancelled
        let exit = await shutdown(active, grace: healthy ? 1.0 : 0.2)
        if session === active { session = nil }

        let stillCurrent = current() && !Task.isCancelled
        if var error = failure as? SAWMCPClientError {
            if operation.callSent, error.kind != .invalid, error.kind != .schema { error.mayHaveExecuted = true }
            if !stillCurrent { throw SAWMCPClientError(.cancelled, "취소되었습니다.", mayHaveExecuted: operation.callSent) }
            throw error
        }
        if let failure {
            if !stillCurrent { throw SAWMCPClientError(.cancelled, "취소되었습니다.", mayHaveExecuted: operation.callSent) }
            throw SAWMCPClientError(.process, "MCP 처리 중 알 수 없는 오류가 발생했습니다.", mayHaveExecuted: operation.callSent)
        }
        // A valid reply is judged by our own state, not by the engine's cancel flag (set by our own grace-time cancel).
        guard stillCurrent else { throw SAWMCPClientError(.cancelled, "취소되었습니다.", mayHaveExecuted: operation.callSent) }
        guard let exit, exit.groupClean, exit.pipesDrained else {
            throw SAWMCPClientError(.process, "MCP 서버 프로세스 정리를 확인하지 못해 결과를 사용하지 않습니다.", mayHaveExecuted: operation.callSent)
        }
        guard let value else { throw SAWMCPClientError(.process, "MCP 결과가 없습니다.") }
        return value
    }

    private func shutdown(_ active: SAWMCPSession, grace: TimeInterval) async -> EngineTaskResult? {
        active.closeStdin()
        if let result = await active.waitExit(timeout: grace) { return result }
        active.cancelProcess()
        return await active.waitExit(timeout: 8)
    }
}
