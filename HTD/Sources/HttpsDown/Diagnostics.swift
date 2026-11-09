import Foundation
import Darwin

// Diagnostic trace: a small, typed, whitelist-only record of what the app and engine decided (phase, tuning,
// failure class, process outcome). Nothing here ever serializes a payload, message, detail, stderr, request,
// context or job object: every field is built fresh from validated enums, bounded numbers or sanitized tokens.

// MARK: - Vocabulary

enum DiagStage: String { case extract, download, record, publish }
enum DiagKind: String { case phase, tuning, failure, outcome }
enum DiagPhase: String {
    case extracting, downloading, verifying, converting, recording, processing, publishing, published, other
}
enum DiagTerminal: String {
    case extractCompleted, selectionChanged, verificationIncomplete, verificationFailed, error, verified, missing
}
enum DiagErrorCategory: String {
    case http, tls, proxy, dns, network, timeout, incomplete, unsupported, resource, filesystem, process, other
}
enum DiagProtocol: String {
    case http, https, m3u8, m3u8_native, http_dash_segments, http_dash_segments_generator
    case rtmp, rtsp, ism, f4m, mhtml, ftp, websocket_frag
}

/// Proxy helper refusal codes (the helper's fixed vocabulary); anything else is recorded as `other`.
enum DiagRefusalCode: String {
    case notAllowed = "not_allowed", privateAddress = "private_address", dnsFailed = "dns_failed"
    case connectFailed = "connect_failed", plainHTTP = "plain_http", badTarget = "bad_target", badHost = "bad_host", other
}

/// Finite product enum for Server response header; anything else/arbitrary string is mapped to `other`.
enum DiagServerProduct: String {
    case nginx, apache, cloudflare, envoy, AmazonS3, other
}

enum DiagRequestOptionsScope: String {
    case selectedFormatOptions = "selected-format-options"
    case requestOptions = "request-options"
}

enum DiagFailureStage: String {
    case extraction, download
}

/// Whitelist-only error HTTP response metadata from actual HTTPError.response (no URLs, headers, body, or tokens).
struct DiagHttpResponse: Equatable {
    var contentType: String?
    var server: DiagServerProduct?
    var retryAfterSeconds: Int?
    var cfMitigated: String?

    static let allowedContentTypes: Set<String> = [
        "text/html", "text/plain", "text/xml", "application/json", "application/xml",
        "application/xhtml+xml", "application/octet-stream", "application/vnd.apple.mpegurl",
        "application/x-mpegurl", "application/dash+xml", "video/mp4", "video/webm",
        "audio/mp4", "audio/webm", "image/jpeg", "image/png", "image/gif", "image/webp"
    ]

    init(contentType: String? = nil, server: DiagServerProduct? = nil, retryAfterSeconds: Int? = nil, cfMitigated: String? = nil) {
        self.contentType = contentType
        self.server = server
        self.retryAfterSeconds = retryAfterSeconds
        self.cfMitigated = cfMitigated
    }

    init?(json d: Any?) {
        guard let d = d as? [String: Any] else { return nil }
        if let ct = d["contentType"] as? String, Self.allowedContentTypes.contains(ct) {
            self.contentType = ct
        }
        if let s = d["server"] as? String, let prod = DiagServerProduct(rawValue: s) {
            self.server = prod
        }
        if let ra = Diag.int(d["retryAfterSeconds"], 0...86400) {
            self.retryAfterSeconds = ra
        }
        if let cf = d["cfMitigated"] as? String, cf == "challenge" {
            self.cfMitigated = cf
        }
        if contentType == nil && server == nil && retryAfterSeconds == nil && cfMitigated == nil {
            return nil
        }
    }

    var json: [String: Any] {
        var d: [String: Any] = [:]
        if let ct = contentType { d["contentType"] = ct }
        if let s = server { d["server"] = s.rawValue }
        if let ra = retryAfterSeconds { d["retryAfterSeconds"] = ra }
        if let cf = cfMitigated { d["cfMitigated"] = cf }
        return d
    }
}

/// Header presence flags only (never values) for selected-format or top-level request options.
struct DiagRequestOptions: Equatable {
    var scope: DiagRequestOptionsScope?
    var referer: Bool?
    var origin: Bool?
    var cookie: Bool?
    var userAgent: Bool?

    init(scope: DiagRequestOptionsScope? = nil, referer: Bool? = nil, origin: Bool? = nil, cookie: Bool? = nil, userAgent: Bool? = nil) {
        self.scope = scope
        self.referer = referer
        self.origin = origin
        self.cookie = cookie
        self.userAgent = userAgent
    }

    init?(json d: Any?) {
        guard let d = d as? [String: Any] else { return nil }
        if let sc = d["scope"] as? String, let s = DiagRequestOptionsScope(rawValue: sc) {
            self.scope = s
        }
        self.referer = Diag.bool(d["referer"])
        self.origin = Diag.bool(d["origin"])
        self.cookie = Diag.bool(d["cookie"])
        self.userAgent = Diag.bool(d["userAgent"])
        if scope == nil && referer == nil && origin == nil && cookie == nil && userAgent == nil {
            return nil
        }
    }

    var json: [String: Any] {
        var d: [String: Any] = [:]
        if let s = scope { d["scope"] = s.rawValue }
        if let r = referer { d["referer"] = r }
        if let o = origin { d["origin"] = o }
        if let c = cookie { d["cookie"] = c }
        if let u = userAgent { d["userAgent"] = u }
        return d
    }
}

/// Typed snapshot of safe HTTP failure diagnostics: error response metadata, request header flags, and stage.
public enum DiagDiscoveryReason: String, Codable, Equatable {
    case none
    case ambiguous
    case unbounded
    case unreachable
    case unsupported
    case unsafe
    case assist
    case browserRequired = "browser_required"
}

public enum DiagDiscoveryTerminal: String, Codable, Equatable {
    case none
    case ambiguous
    case unbounded
    case unreachable
    case unsupported
    case unsafe
    case assist
    case browserRequired = "browser_required"
    case found
    case error
}

public enum DiagDiscoveryStage: String, Codable, Equatable {
    case page
    case frame
    case scan
    case candidateHead = "candidate_head"
    case candidateGet = "candidate_get"
    case manifest
    case references
    case formatParse = "format_parse"
    case terminal
}

public enum DiagDiscoveryResult: String, Codable, Equatable {
    case ok
    case error
    case none
    case hls
    case media
    case other
    case rejected
    case limit
    case found
    case ambiguous
    case unbounded
    case unreachable
    case unsupported
    case unsafe
    case assist
    case browserRequired = "browser_required"
}

public enum DiagDiscoveryMime: String, Codable, Equatable {
    case html
    case hls
    case json
    case media
    case image
    case other
    case unknown
}

public enum DiagDiscoveryError: String, Codable, Equatable {
    case http
    case dns
    case tls
    case proxy
    case timeout
    case network
    case unsafe
    case other
}

public struct DiagDiscoveryCounts: Codable, Equatable {
    public let frames: Int
    public let candidates: Int
    public let probes: Int
    public let networkErrors: Int
    public let rejected: Int
    public let truncated: Bool

    public init(frames: Int = 0, candidates: Int = 0, probes: Int = 0, networkErrors: Int = 0, rejected: Int = 0, truncated: Bool = false) {
        self.frames = max(0, min(4, frames))
        self.candidates = max(0, min(64, candidates))
        self.probes = max(0, min(12, probes))
        self.networkErrors = max(0, min(32, networkErrors))
        self.rejected = max(0, min(64, rejected))
        self.truncated = truncated
    }

    init?(json d: Any?) {
        guard let raw = d as? [String: Any] else {
            self.init()
            return
        }
        let f = (Diag.int(raw["frames"], -1_000_000...1_000_000) ?? 0)
        let c = (Diag.int(raw["candidates"], -1_000_000...1_000_000) ?? 0)
        let p = (Diag.int(raw["probes"], -1_000_000...1_000_000) ?? 0)
        let ne = (Diag.int(raw["networkErrors"], -1_000_000...1_000_000) ?? 0)
        let r = (Diag.int(raw["rejected"], -1_000_000...1_000_000) ?? 0)
        let tr = (Diag.bool(raw["truncated"]) ?? false)
        self.init(frames: f, candidates: c, probes: p, networkErrors: ne, rejected: r, truncated: tr)
    }

    var json: [String: Any] {
        [
            "frames": frames,
            "candidates": candidates,
            "probes": probes,
            "networkErrors": networkErrors,
            "rejected": rejected,
            "truncated": truncated
        ]
    }
}

public struct DiagDiscoveryHTML: Codable, Equatable {
    public let tagsSeen: Int
    public let srcSeen: Int
    public let nonemptySrcSeen: Int
    public let parseError: Bool
    public let inputTruncated: Bool?

    public init(tagsSeen: Int, srcSeen: Int, nonemptySrcSeen: Int, parseError: Bool, inputTruncated: Bool? = nil) {
        self.tagsSeen = max(0, min(64, tagsSeen))
        self.srcSeen = max(0, min(64, srcSeen))
        self.nonemptySrcSeen = max(0, min(64, nonemptySrcSeen))
        self.parseError = parseError
        self.inputTruncated = inputTruncated
    }

    public init?(raw: [String: Any]) {
        guard let tags = Diag.int(raw["tagsSeen"], 0...64),
              let src = Diag.int(raw["srcSeen"], 0...64),
              let nonempty = Diag.int(raw["nonemptySrcSeen"], 0...64),
              let parseErr = Diag.bool(raw["parseError"]) else {
            return nil
        }
        self.tagsSeen = tags
        self.srcSeen = src
        self.nonemptySrcSeen = nonempty
        self.parseError = parseErr
        if let rawTrunc = raw["inputTruncated"] {
            guard let trunc = Diag.bool(rawTrunc) else { return nil }
            self.inputTruncated = trunc
        } else {
            self.inputTruncated = nil
        }
    }

    public var json: [String: Any] {
        var dict: [String: Any] = [
            "tagsSeen": tagsSeen,
            "srcSeen": srcSeen,
            "nonemptySrcSeen": nonemptySrcSeen,
            "parseError": parseError
        ]
        if let inputTruncated = inputTruncated {
            dict["inputTruncated"] = inputTruncated
        }
        return dict
    }
}

public struct DiagDiscoveryScan: Codable, Equatable {
    public let iframeTags: Int
    public let mediaTags: Int
    public let dataAttributes: Int
    public let scriptValues: Int
    public let empty: Int
    public let scheme: Int
    public let tooLong: Int
    public let notURLLike: Int
    public let invalid: Int
    public let accepted: Int
    public let html: DiagDiscoveryHTML?

    public init(iframeTags: Int = 0, mediaTags: Int = 0, dataAttributes: Int = 0, scriptValues: Int = 0,
                empty: Int = 0, scheme: Int = 0, tooLong: Int = 0, notURLLike: Int = 0, invalid: Int = 0, accepted: Int = 0,
                html: DiagDiscoveryHTML? = nil) {
        self.iframeTags = max(0, min(64, iframeTags))
        self.mediaTags = max(0, min(64, mediaTags))
        self.dataAttributes = max(0, min(64, dataAttributes))
        self.scriptValues = max(0, min(64, scriptValues))
        self.empty = max(0, min(64, empty))
        self.scheme = max(0, min(64, scheme))
        self.tooLong = max(0, min(64, tooLong))
        self.notURLLike = max(0, min(64, notURLLike))
        self.invalid = max(0, min(64, invalid))
        self.accepted = max(0, min(64, accepted))
        self.html = html
    }

    init?(json d: Any?) {
        guard let raw = d as? [String: Any] else { return nil }
        self.init(
            iframeTags: Diag.int(raw["iframeTags"], -1_000_000...1_000_000) ?? 0,
            mediaTags: Diag.int(raw["mediaTags"], -1_000_000...1_000_000) ?? 0,
            dataAttributes: Diag.int(raw["dataAttributes"], -1_000_000...1_000_000) ?? 0,
            scriptValues: Diag.int(raw["scriptValues"], -1_000_000...1_000_000) ?? 0,
            empty: Diag.int(raw["empty"], -1_000_000...1_000_000) ?? 0,
            scheme: Diag.int(raw["scheme"], -1_000_000...1_000_000) ?? 0,
            tooLong: Diag.int(raw["tooLong"], -1_000_000...1_000_000) ?? 0,
            notURLLike: Diag.int(raw["notURLLike"], -1_000_000...1_000_000) ?? 0,
            invalid: Diag.int(raw["invalid"], -1_000_000...1_000_000) ?? 0,
            accepted: Diag.int(raw["accepted"], -1_000_000...1_000_000) ?? 0,
            html: (raw["html"] as? [String: Any]).flatMap { DiagDiscoveryHTML(raw: $0) }
        )
    }

    var json: [String: Any] {
        var dict: [String: Any] = [
            "iframeTags": iframeTags,
            "mediaTags": mediaTags,
            "dataAttributes": dataAttributes,
            "scriptValues": scriptValues,
            "empty": empty,
            "scheme": scheme,
            "tooLong": tooLong,
            "notURLLike": notURLLike,
            "invalid": invalid,
            "accepted": accepted
        ]
        if let html = html {
            dict["html"] = html.json
        }
        return dict
    }
}

public struct DiagDiscoveryStep: Codable, Equatable {
    public let stage: DiagDiscoveryStage
    public let result: DiagDiscoveryResult
    public let depth: Int?
    public let httpStatus: Int?
    public let mime: DiagDiscoveryMime?
    public let error: DiagDiscoveryError?
    public let scan: DiagDiscoveryScan?

    public init(stage: DiagDiscoveryStage, result: DiagDiscoveryResult, depth: Int? = nil, httpStatus: Int? = nil, mime: DiagDiscoveryMime? = nil, error: DiagDiscoveryError? = nil, scan: DiagDiscoveryScan? = nil) {
        self.stage = stage
        self.result = result
        if let d = depth, d >= 0 && d <= 2 {
            self.depth = d
        } else {
            self.depth = nil
        }
        if let s = httpStatus, s >= 100 && s <= 599 {
            self.httpStatus = s
        } else {
            self.httpStatus = nil
        }
        self.mime = mime
        self.error = error
        self.scan = stage == .scan ? scan : nil
    }

    init?(json d: Any?) {
        guard let raw = d as? [String: Any], let sRaw = raw["stage"] as? String, let stage = DiagDiscoveryStage(rawValue: sRaw), let rRaw = raw["result"] as? String, let result = DiagDiscoveryResult(rawValue: rRaw) else {
            return nil
        }
        let d: Int?
        if let rawDepth = raw["depth"] {
            let val = (Diag.int(rawDepth, 0...2) ?? -1)
            d = (val >= 0 && val <= 2) ? val : nil
        } else {
            d = nil
        }
        let hs: Int?
        if let rawStatus = raw["httpStatus"] {
            let val = (Diag.int(rawStatus, 100...599) ?? -1)
            hs = (val >= 100 && val <= 599) ? val : nil
        } else {
            hs = nil
        }
        let m = (raw["mime"] as? String).flatMap { DiagDiscoveryMime(rawValue: $0) }
        let e = (raw["error"] as? String).flatMap { DiagDiscoveryError(rawValue: $0) }
        let sc = raw["scan"].flatMap { DiagDiscoveryScan(json: $0) }
        self.init(stage: stage, result: result, depth: d, httpStatus: hs, mime: m, error: e, scan: sc)
    }

    var json: [String: Any] {
        var d: [String: Any] = ["stage": stage.rawValue, "result": result.rawValue]
        if let dp = depth { d["depth"] = dp }
        if let hs = httpStatus { d["httpStatus"] = hs }
        if let m = mime { d["mime"] = m.rawValue }
        if let e = error { d["error"] = e.rawValue }
        if let sc = scan { d["scan"] = sc.json }
        return d
    }
}

public struct DiagDiscoveryDetails: Codable, Equatable {
    public let version: Int
    public let terminal: DiagDiscoveryTerminal?
    public let lastStage: DiagDiscoveryStage?
    public let lastCompletedStage: DiagDiscoveryStage?
    public let counts: DiagDiscoveryCounts
    public let steps: [DiagDiscoveryStep]

    public init(version: Int = 1, terminal: DiagDiscoveryTerminal? = nil, lastStage: DiagDiscoveryStage? = nil, lastCompletedStage: DiagDiscoveryStage? = nil, counts: DiagDiscoveryCounts = DiagDiscoveryCounts(), steps: [DiagDiscoveryStep] = []) {
        self.version = 1
        self.terminal = terminal
        self.lastStage = lastStage
        self.lastCompletedStage = lastCompletedStage
        self.counts = counts
        self.steps = Array(steps.prefix(24))
    }

    init?(json d: Any?) {
        guard let raw = d as? [String: Any] else { return nil }
        let ver = (raw["version"] as? Int) ?? 1
        let term = (raw["terminal"] as? String).flatMap { DiagDiscoveryTerminal(rawValue: $0) }
        let ls = (raw["lastStage"] as? String).flatMap { DiagDiscoveryStage(rawValue: $0) }
        let lcs = (raw["lastCompletedStage"] as? String).flatMap { DiagDiscoveryStage(rawValue: $0) }
        let rawStepsList = raw["steps"] as? [Any] ?? []
        let isTruncated = rawStepsList.count > 24
        let baseCnts = DiagDiscoveryCounts(json: raw["counts"]) ?? DiagDiscoveryCounts()
        let cnts = DiagDiscoveryCounts(frames: baseCnts.frames, candidates: baseCnts.candidates, probes: baseCnts.probes, networkErrors: baseCnts.networkErrors, rejected: baseCnts.rejected, truncated: isTruncated || baseCnts.truncated)
        var selectedItems: [Any] = []
        if rawStepsList.count > 24 {
            let first23 = Array(rawStepsList.prefix(23))
            let lastItem = rawStepsList.last
            let lastIsTerminal: Bool
            if let lastDict = lastItem as? [String: Any], let st = lastDict["stage"] as? String, st == "terminal" {
                lastIsTerminal = true
            } else {
                lastIsTerminal = false
            }
            selectedItems = first23 + (lastIsTerminal ? [lastItem!] : [rawStepsList[23]])
        } else {
            selectedItems = rawStepsList
        }
        var parsedSteps: [DiagDiscoveryStep] = []
        for item in selectedItems.prefix(24) {
            if let s = DiagDiscoveryStep(json: item) {
                parsedSteps.append(s)
            }
        }
        let safeLastCompleted = (lcs?.rawValue == "terminal") ? nil : lcs
        self.init(version: ver, terminal: term, lastStage: ls, lastCompletedStage: safeLastCompleted, counts: cnts, steps: parsedSteps)
    }

    var json: [String: Any] {
        var d: [String: Any] = ["version": version, "counts": counts.json, "steps": steps.map { $0.json }]
        if let t = terminal { d["terminal"] = t.rawValue }
        if let ls = lastStage { d["lastStage"] = ls.rawValue }
        if let lcs = lastCompletedStage { d["lastCompletedStage"] = lcs.rawValue }
        return d
    }
}

struct DiagHttpEvidence: Equatable {
    var httpResponse: DiagHttpResponse?
    var requestOptions: DiagRequestOptions?
    var failureStage: DiagFailureStage?
    var discoveryReason: DiagDiscoveryReason?
    var discovery: DiagDiscoveryDetails?

    init(httpResponse: DiagHttpResponse? = nil, requestOptions: DiagRequestOptions? = nil, failureStage: DiagFailureStage? = nil, discoveryReason: DiagDiscoveryReason? = nil, discovery: DiagDiscoveryDetails? = nil) {
        self.httpResponse = httpResponse
        self.requestOptions = requestOptions
        self.failureStage = failureStage
        self.discoveryReason = discoveryReason
        self.discovery = discovery
    }

    init?(json d: Any?) {
        guard let raw = d as? [String: Any] else { return nil }
        let root = (raw["httpEvidence"] as? [String: Any]) ?? raw
        self.httpResponse = DiagHttpResponse(json: root["httpResponse"])
        self.requestOptions = DiagRequestOptions(json: root["requestOptions"])
        if let stage = root["failureStage"] as? String {
            self.failureStage = DiagFailureStage(rawValue: stage)
        }
        if let reason = root["discoveryReason"] as? String {
            self.discoveryReason = DiagDiscoveryReason(rawValue: reason)
        }
        self.discovery = DiagDiscoveryDetails(json: root["discovery"])
        if httpResponse == nil && requestOptions == nil && failureStage == nil && discoveryReason == nil && discovery == nil {
            return nil
        }
    }

    var json: [String: Any] {
        var d: [String: Any] = [:]
        if let hr = httpResponse { d["httpResponse"] = hr.json }
        if let ro = requestOptions { d["requestOptions"] = ro.json }
        if let fs = failureStage { d["failureStage"] = fs.rawValue }
        if let dr = discoveryReason { d["discoveryReason"] = dr.rawValue }
        if let disc = discovery { d["discovery"] = disc.json }
        return d
    }
}

/// Presence flags only (never values or counts) of what a run asked for / what its submitted context really carried.
struct DiagAttachment: Equatable {
    var proxy = false
    var referrer = false
    var session = false
    var userAgent = false

    init(proxy: Bool, referrer: Bool, session: Bool, userAgent: Bool) {
        self.proxy = proxy; self.referrer = referrer; self.session = session; self.userAgent = userAgent
    }

    /// Actual presence, derived from the exact engine context object (session cookies and nested `session.userAgent`).
    init(context: [String: Any]) {
        func filled(_ value: Any?) -> Bool { (value as? String).map { !$0.isEmpty } ?? false }
        let session = context["session"] as? [String: Any]
        self.init(proxy: filled(context["proxy"]), referrer: filled(context["referer"]),
                  session: !((session?["cookies"] as? [Any]) ?? []).isEmpty, userAgent: filled(session?["userAgent"]))
    }

    init?(json d: Any?) {
        guard let d = d as? [String: Any], let proxy = Diag.bool(d["proxy"]), let referrer = Diag.bool(d["referrer"]),
              let session = Diag.bool(d["session"]), let userAgent = Diag.bool(d["userAgent"]) else { return nil }
        self.init(proxy: proxy, referrer: referrer, session: session, userAgent: userAgent)
    }

    var json: [String: Any] { ["proxy": proxy, "referrer": referrer, "session": session, "userAgent": userAgent] }
}

/// Minimal facts about the current job, handed over only when an event is captured (raw; sanitized by the store).
struct DiagContext {
    var host: String?
    var extractor: String?
    var proto: String?
    var pageHost: String?
    var frameHost: String?
    var requestHost: String?
    var requested: DiagAttachment?
    var attached: DiagAttachment?
    var refusalHost: String?
    var refusalCode: String?
    var httpEvidence: DiagHttpEvidence?
}

// MARK: - Validation helpers

enum Diag {
    static let schemaVersion = 1
    static let knownErrorCodes: Set<String> = [
        "assist_http_unsupported", "engine_missing", "session_mismatch", "extract_failed", "extract_empty",
        "playlist_unsupported", "browser_required", "live_upcoming", "drm", "live_protocol", "no_formats", "bad_request",
        "download_failed", "no_output", "engine_exception", "bad_command", "publish_failed", "subtitle_publish_failed"
    ]

    static func int(_ value: Any?, _ range: ClosedRange<Int>) -> Int? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        guard d.isFinite, d == d.rounded(), d >= Double(range.lowerBound), d <= Double(range.upperBound) else { return nil }
        return Int(d)
    }

    static func rate(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        guard d.isFinite, d >= 0, d <= 1e12 else { return nil }
        return (d * 10).rounded() / 10
    }

    static func bool(_ value: Any?) -> Bool? {
        guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
        return n.boolValue
    }

    static func uuid(_ value: Any?) -> String? {
        guard let s = value as? String, s.count == 36, let u = UUID(uuidString: s) else { return nil }
        return u.uuidString.lowercased()
    }

    static func errorCode(_ raw: String?) -> String {
        guard let raw = raw, knownErrorCodes.contains(raw) else { return "other" }
        return raw
    }
}

enum DiagSanitize {
    /// Host only (URL.host: no userinfo, port, path or query), strict DNS-name/IP characters.
    static func host(_ raw: String?) -> String? {
        guard let h = raw?.lowercased(), !h.isEmpty, h.count <= 253 else { return nil }
        var labelLength = 0
        var previous: Character = "."
        for c in h {
            if c == "." {
                if labelLength == 0 || previous == "-" { return nil }
                labelLength = 0
            } else if (c >= "a" && c <= "z") || (c >= "0" && c <= "9") {
                labelLength += 1
            } else if c == "-" {
                if labelLength == 0 { return nil }
                labelLength += 1
            } else {
                return nil
            }
            if labelLength > 63 { return nil }
            previous = c
        }
        return labelLength == 0 || previous == "-" ? nil : h
    }

    /// DNS host only (no IP address, strict RFC 1123 DNS name).
    static func dnsHost(_ raw: String?) -> String? {
        guard let h = host(raw) else { return nil }
        guard h.contains(where: { $0 >= "a" && $0 <= "z" }) else { return nil }
        if let lastLabel = h.split(separator: ".").last, lastLabel.allSatisfy({ $0 >= "0" && $0 <= "9" }) {
            return nil
        }
        return h
    }

    /// First numeric dotted version in a tool's version text (never the whole line or any path).
    static func version(_ raw: String?) -> String? {
        guard let raw = raw, !raw.isEmpty, raw.count <= 400,
              let re = try? NSRegularExpression(pattern: "[0-9]{1,4}(?:\\.[0-9]{1,4}){1,3}") else { return nil }
        let ns = raw as NSString
        guard let m = re.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: m.range)
    }

    /// CFBundleVersion as a plain build number (digits only, at most 6).
    static func buildNumber(_ raw: String?) -> String? {
        guard let raw = raw, (1...6).contains(raw.count), raw.allSatisfy({ $0 >= "0" && $0 <= "9" }) else { return nil }
        return raw
    }

    /// A key of the bundled SupportedSites registeredExtractors, or the fixed Generic fallback; anything else is dropped.
    static func extractor(_ raw: String?) -> String? {
        guard let raw = raw, !raw.isEmpty, raw.count <= 60 else { return nil }
        let lower = raw.lowercased()
        if let canonical = DiagRegistry.extractors[lower] { return canonical }
        return lower == "generic" ? "Generic" : nil
    }

    static func proto(_ raw: String?) -> DiagProtocol? {
        guard let raw = raw else { return nil }
        return DiagProtocol(rawValue: raw)
    }

    static func phase(_ raw: String?) -> DiagPhase {
        guard let raw = raw else { return .other }
        return DiagPhase(rawValue: raw) ?? .other
    }

    /// Format identifier: strict bounded alphabet (alphanumerics, hyphen, underscore, dot),
    /// max 32 chars, rejecting token-like opaque values and query/path/secret markers.
    static func formatId(_ raw: String?) -> String? {
        guard let s = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !s.isEmpty, s.count <= 32 else { return nil }
        guard s.allSatisfy({ ($0 >= "a" && $0 <= "z") || ($0 >= "A" && $0 <= "Z") || ($0 >= "0" && $0 <= "9") || $0 == "-" || $0 == "_" || $0 == "." }) else {
            return nil
        }
        let lower = s.lowercased()
        let forbidden = ["token", "auth", "secret", "cookie", "session", "key", "sig", "pass", "bearer"]
        if forbidden.contains(where: { lower.contains($0) }) { return nil }
        if s.count >= 24 && s.allSatisfy({ ($0 >= "a" && $0 <= "f") || ($0 >= "A" && $0 <= "F") || ($0 >= "0" && $0 <= "9") }) {
            return nil
        }
        return s
    }
}

/// registeredExtractors of the bundled Resources/SupportedSites.json (lowercased key → canonical key).
enum DiagRegistry {
    static let extractors: [String: String] = load()

    private static func load() -> [String: String] {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("SupportedSites.json"),
              let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
              size > 0, size <= 16 << 20,
              let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let list = root["registeredExtractors"] else { return [:] }
        var names: [String] = []
        if let strings = list as? [String] {
            names = strings
        } else if let objects = list as? [[String: Any]] {
            for o in objects {
                if let n = ["key", "extractor", "name", "id"].compactMap({ o[$0] as? String }).first { names.append(n) }
            }
        } else if let dict = list as? [String: Any] {
            names = Array(dict.keys)
        }
        var out: [String: String] = [:]
        for n in names where n.count <= 60 && !n.isEmpty
            && n.unicodeScalars.allSatisfy({ ($0.value < 128) && (CharacterSet.alphanumerics.contains($0) || $0 == "_") }) {
            out[n.lowercased()] = n
        }
        return out
    }
}

// MARK: - Records

struct DiagTuning: Equatable {
    enum Phase: String { case baseline, trial, hold }
    enum Reason: String { case baseline, trial, rollback, stable, resourceLimit, other }

    var phase: Phase
    var current: Int
    var stable: Int
    var pool: Int
    var reason: Reason
    var resource: Bool
    var rollback: Bool
    var retryUsed: Bool
    var fuse: Bool
    var baselineRate: Double
    var trialRate: Double

    /// Strict: exactly the engine's fixed keys with valid values, else nil (unknown keys are never read).
    init?(payload: Any?) {
        guard let d = payload as? [String: Any],
              let phase = Phase(rawValue: d["phase"] as? String ?? ""),
              let current = Diag.int(d["current"], 1...64), let stable = Diag.int(d["stable"], 1...64),
              let pool = Diag.int(d["pool"], 1...64),
              let reason = Reason(rawValue: d["reason"] as? String ?? ""),
              let resource = Diag.bool(d["resource"]), let rollback = Diag.bool(d["rollback"]),
              let retryUsed = Diag.bool(d["retryUsed"]), let fuse = Diag.bool(d["fuse"]),
              let baselineRate = Diag.rate(d["baselineRate"]), let trialRate = Diag.rate(d["trialRate"]) else { return nil }
        self.phase = phase; self.current = current; self.stable = stable; self.pool = pool; self.reason = reason
        self.resource = resource; self.rollback = rollback; self.retryUsed = retryUsed; self.fuse = fuse
        self.baselineRate = baselineRate; self.trialRate = trialRate
    }

    /// What counts as a decision change (rates alone never do).
    var changeKey: String { "\(phase.rawValue)|\(current)|\(stable)|\(reason.rawValue)|\(resource)|\(rollback)|\(retryUsed)" }

    var json: [String: Any] {
        ["phase": phase.rawValue, "current": current, "stable": stable, "pool": pool, "reason": reason.rawValue,
         "resource": resource, "rollback": rollback, "retryUsed": retryUsed, "fuse": fuse,
         "baselineRate": baselineRate, "trialRate": trialRate]
    }
}

struct DiagOutcome: Equatable {
    var exitCode: Int?
    var timedOut = false
    var cancelled = false
    var groupClean = false
    var pipesDrained = false
    var readyHandshake = false
    var spawnFailed = false
    var signaled = false

    init(result: EngineTaskResult) {
        exitCode = result.exitCode.flatMap { (0...255).contains(Int($0)) ? Int($0) : nil }
        timedOut = result.timedOut
        cancelled = result.cancelled
        groupClean = result.groupClean
        pipesDrained = result.pipesDrained
        readyHandshake = result.readyHandshake
        spawnFailed = result.spawnError != nil
        signaled = result.terminatedBySignal != nil
    }

    init?(json d: Any?) {
        guard let d = d as? [String: Any] else { return nil }
        exitCode = Diag.int(d["exitCode"], 0...255)
        timedOut = Diag.bool(d["timedOut"]) ?? false
        cancelled = Diag.bool(d["cancelled"]) ?? false
        groupClean = Diag.bool(d["groupClean"]) ?? false
        pipesDrained = Diag.bool(d["pipesDrained"]) ?? false
        readyHandshake = Diag.bool(d["readyHandshake"]) ?? false
        spawnFailed = Diag.bool(d["spawnFailed"]) ?? false
        signaled = Diag.bool(d["signaled"]) ?? false
    }

    var json: [String: Any] {
        var d: [String: Any] = ["timedOut": timedOut, "cancelled": cancelled, "groupClean": groupClean,
                                "pipesDrained": pipesDrained, "readyHandshake": readyHandshake,
                                "spawnFailed": spawnFailed, "signaled": signaled]
        if let exitCode = exitCode { d["exitCode"] = exitCode }
        return d
    }
}

struct DiagEvent: Equatable {
    var time: Int
    var kind: DiagKind
    /// Random local diagnostic id of the job (never the original job id).
    var job: String
    var attempt: Int
    var stage: DiagStage
    var phase: DiagPhase?
    var host: String?
    var extractor: String?
    var proto: DiagProtocol?
    var tuning: DiagTuning?
    var errorCategory: DiagErrorCategory?
    var errorCode: String?
    var httpStatus: Int?
    var terminal: DiagTerminal?
    var outcome: DiagOutcome?
    /// `host` is the host of the job's registered address; these are the browser's top page / chosen frame hosts.
    var pageHost: String?
    var frameHost: String?
    /// Host that actually answered the failing HTTP request (typed, from the engine; only with an http category).
    var requestHost: String?
    var requested: DiagAttachment?
    var attached: DiagAttachment?
    var refusalHost: String?
    var refusalCode: DiagRefusalCode?
    var httpEvidence: DiagHttpEvidence?

    init(time: Int, kind: DiagKind, job: String, attempt: Int, stage: DiagStage) {
        self.time = time; self.kind = kind; self.job = job; self.attempt = attempt; self.stage = stage
    }

    /// Decode AND revalidate every field of a stored/edited record; unknown keys and raw strings are ignored.
    init?(json d: [String: Any]) {
        guard Diag.int(d["v"], Diag.schemaVersion...Diag.schemaVersion) != nil,
              let time = Diag.int(d["t"], 1_000_000_000...4_000_000_000),
              let kind = DiagKind(rawValue: d["kind"] as? String ?? ""),
              let job = Diag.uuid(d["job"]),
              let attempt = Diag.int(d["attempt"], 0...9999),
              let stage = DiagStage(rawValue: d["stage"] as? String ?? "") else { return nil }
        self.init(time: time, kind: kind, job: job, attempt: attempt, stage: stage)
        phase = (d["phase"] as? String).flatMap { DiagPhase(rawValue: $0) }
        host = DiagSanitize.host(d["host"] as? String)
        extractor = DiagSanitize.extractor(d["extractor"] as? String)
        proto = DiagSanitize.proto(d["proto"] as? String)
        tuning = d["tuning"].flatMap { DiagTuning(payload: $0) }
        if let e = d["error"] as? [String: Any] {
            errorCategory = DiagErrorCategory(rawValue: e["category"] as? String ?? "")
            errorCode = (e["code"] as? String).map(Diag.errorCode)
            httpStatus = Diag.int(e["httpStatus"], 100...599)
            requestHost = DiagSanitize.dnsHost(e["requestHost"] as? String)
        }
        terminal = (d["terminal"] as? String).flatMap { DiagTerminal(rawValue: $0) }
        outcome = d["outcome"].flatMap { DiagOutcome(json: $0) }
        pageHost = DiagSanitize.host(d["pageHost"] as? String)
        frameHost = DiagSanitize.host(d["frameHost"] as? String)
        requested = DiagAttachment(json: d["requested"])
        attached = DiagAttachment(json: d["attached"])
        if let r = d["refusal"] as? [String: Any] {
            refusalHost = DiagSanitize.host(r["host"] as? String)
            refusalCode = DiagRefusalCode(rawValue: r["code"] as? String ?? "") ?? .other
        }
        httpEvidence = DiagHttpEvidence(json: d["httpEvidence"])
    }

    var json: [String: Any] {
        var d: [String: Any] = ["v": Diag.schemaVersion, "t": time, "kind": kind.rawValue, "job": job,
                                "attempt": attempt, "stage": stage.rawValue]
        if let phase = phase { d["phase"] = phase.rawValue }
        if let host = host { d["host"] = host }
        if let extractor = extractor { d["extractor"] = extractor }
        if let proto = proto { d["proto"] = proto.rawValue }
        if let tuning = tuning { d["tuning"] = tuning.json }
        if errorCategory != nil || errorCode != nil || httpStatus != nil || requestHost != nil {
            var e: [String: Any] = [:]
            if let h = requestHost { e["requestHost"] = h }
            if let c = errorCategory { e["category"] = c.rawValue }
            if let c = errorCode { e["code"] = c }
            if let s = httpStatus { e["httpStatus"] = s }
            d["error"] = e
        }
        if let terminal = terminal { d["terminal"] = terminal.rawValue }
        if let outcome = outcome { d["outcome"] = outcome.json }
        if let pageHost = pageHost { d["pageHost"] = pageHost }
        if let frameHost = frameHost { d["frameHost"] = frameHost }
        if let requested = requested { d["requested"] = requested.json }
        if let attached = attached { d["attached"] = attached.json }
        if refusalHost != nil || refusalCode != nil {
            var r: [String: Any] = [:]
            if let h = refusalHost { r["host"] = h }
            if let c = refusalCode { r["code"] = c.rawValue }
            d["refusal"] = r
        }
        if let he = httpEvidence { d["httpEvidence"] = he.json }
        return d
    }

    /// One JSONL line (with newline), or nil when it would exceed the per-line bound.
    func line() -> Data? {
        guard var data = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]),
              data.count < DiagnosticsDisk.maxLineBytes else { return nil }
        data.append(0x0A)
        return data
    }
}

// MARK: - Disk (two known files, bounded, owner-only)

/// `<storeDirectory>/Diagnostics/trace-current.jsonl` + `trace-previous.jsonl`. No directory scan, no watcher.
/// All I/O is confined to one serial queue; every open is O_NOFOLLOW and the opened file must be a regular,
/// single-link file owned by us.
final class DiagnosticsDisk: @unchecked Sendable {
    static let maxFileBytes = 1 << 20
    static let maxFileEvents = 600
    static let maxLineBytes = 4096

    private let directory: String
    private let currentPath: String
    private let previousPath: String
    private let queue = DispatchQueue(label: "htd.diagnostics.disk", qos: .utility)
    private var lines = 0
    private var bytes = 0
    private var needsLeadingNewline = false
    private var failureLogged = false

    init(directory: URL) {
        self.directory = directory.path
        currentPath = directory.appendingPathComponent("trace-current.jsonl").path
        previousPath = directory.appendingPathComponent("trace-previous.jsonl").path
    }

    private func logFailureOnce() {
        guard !failureLogged else { return }
        failureLogged = true
        NSLog("[HttpsDown] diagnostics log unavailable")
    }

    private func prepareDirectory() -> Bool {
        if mkdir(directory, 0o700) != 0 && errno != EEXIST { return false }
        var st = stat()
        guard lstat(directory, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == geteuid() else { return false }
        if (st.st_mode & 0o777) != 0o700 { _ = chmod(directory, 0o700) }
        return true
    }

    private func openOwned(_ path: String, flags: Int32) -> (fd: Int32, size: Int)? {
        let fd = open(path, flags | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard fd >= 0 else { return nil }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == geteuid(), st.st_nlink == 1 else {
            close(fd)
            return nil
        }
        return (fd, Int(st.st_size))
    }

    /// Valid records of one file (oldest first) plus its line count / byte size; nil when the path is unusable.
    private func readFile(_ path: String) -> (events: [DiagEvent], lines: Int, bytes: Int, endsWithNewline: Bool)? {
        var st = stat()
        if lstat(path, &st) != 0 { return ([], 0, 0, true) }   // absent
        guard let opened = openOwned(path, flags: O_RDONLY), opened.size <= Self.maxFileBytes + Self.maxLineBytes else {
            _ = unlink(path)   // our own known log name: a symlink/oversized/foreign entry is removed, never followed
            return nil
        }
        defer { close(opened.fd) }
        var buffer = [UInt8](repeating: 0, count: opened.size)
        var offset = 0
        while offset < opened.size {
            let n = buffer.withUnsafeMutableBytes { read(opened.fd, $0.baseAddress! + offset, opened.size - offset) }
            if n > 0 { offset += n } else if n < 0 && errno == EINTR { continue } else { break }
        }
        var events: [DiagEvent] = []
        var count = 0
        for part in buffer[0..<offset].split(separator: 0x0A, omittingEmptySubsequences: true) {
            count += 1
            guard part.count < Self.maxLineBytes,
                  let object = (try? JSONSerialization.jsonObject(with: Data(part))) as? [String: Any],
                  let event = DiagEvent(json: object) else { continue }
            events.append(event)
        }
        return (events, count, offset, offset == 0 || buffer[offset - 1] == 0x0A)
    }

    /// Recent valid records (previous file first), at most `limit`; also seeds the append counters.
    func loadRecent(limit: Int) -> [DiagEvent] {
        guard prepareDirectory() else { logFailureOnce(); return [] }
        var all: [DiagEvent] = []
        if let previous = readFile(previousPath) { all += previous.events }
        if let current = readFile(currentPath) {
            all += current.events
            lines = current.lines
            bytes = current.bytes
            needsLeadingNewline = !current.endsWithNewline
        }
        return Array(all.suffix(limit))
    }

    func append(_ line: Data) {
        queue.async { [self] in
            guard prepareDirectory() else { logFailureOnce(); return }
            if lines >= Self.maxFileEvents || bytes + line.count > Self.maxFileBytes {
                _ = unlink(previousPath)
                _ = rename(currentPath, previousPath)
                lines = 0
                bytes = 0
                needsLeadingNewline = false
            }
            guard let opened = openOwned(currentPath, flags: O_WRONLY | O_APPEND | O_CREAT) else {
                logFailureOnce()
                return
            }
            defer { close(opened.fd) }
            _ = fchmod(opened.fd, 0o600)
            var payload = line
            if needsLeadingNewline { payload.insert(0x0A, at: 0) }
            let ok = payload.withUnsafeBytes { raw -> Bool in
                var offset = 0
                while offset < raw.count {
                    let n = write(opened.fd, raw.baseAddress! + offset, raw.count - offset)
                    if n > 0 { offset += n } else if n < 0 && errno == EINTR { continue } else { return false }
                }
                return true
            }
            if ok {
                lines += 1
                bytes += payload.count
                needsLeadingNewline = false
            } else {
                logFailureOnce()
            }
        }
    }
}

// MARK: - Store (memory ring + disk)

@MainActor
final class DiagnosticsStore {
    nonisolated static let maxEvents = 500
    private static let maxTrackedJobs = 256

    private struct JobTrace {
        var id: String
        var generation: Int
        var lastPhase: DiagPhase?
        var lastTuningKey: String?
    }

    private let disk: DiagnosticsDisk
    private(set) var events: [DiagEvent] = []
    private var traces: [String: JobTrace] = [:]
    private var traceOrder: [String] = []

    init(directory: URL) {
        disk = DiagnosticsDisk(directory: directory)
        events = disk.loadRecent(limit: Self.maxEvents)
    }

    func snapshot() -> [DiagEvent] { Array(events.suffix(Self.maxEvents)) }

    public func traceJobId(jobId: String, generation: Int) -> String? {
        guard let t = traces[jobId], t.generation == generation else { return nil }
        return t.id
    }

    public func hasTraceLinkage(jobId: String, generation: Int) -> Bool {
        traceJobId(jobId: jobId, generation: generation) != nil
    }

    private func trace(jobId: String, generation: Int) -> JobTrace {
        if var t = traces[jobId] {
            if t.generation != generation {
                t.generation = generation
                t.lastPhase = nil
                t.lastTuningKey = nil
                traces[jobId] = t
            }
            return t
        }
        let t = JobTrace(id: UUID().uuidString.lowercased(), generation: generation)
        traces[jobId] = t
        traceOrder.append(jobId)
        if traceOrder.count > Self.maxTrackedJobs {
            traces[traceOrder.removeFirst()] = nil
        }
        return t
    }

    private func make(_ kind: DiagKind, jobId: String, generation: Int, stage: DiagStage, context: DiagContext) -> DiagEvent {
        let t = trace(jobId: jobId, generation: generation)
        var e = DiagEvent(time: Int(Date().timeIntervalSince1970), kind: kind, job: t.id,
                          attempt: max(0, min(generation, 9999)), stage: stage)
        e.host = DiagSanitize.host(context.host)
        e.extractor = DiagSanitize.extractor(context.extractor)
        e.proto = DiagSanitize.proto(context.proto)
        e.pageHost = DiagSanitize.host(context.pageHost)
        e.frameHost = DiagSanitize.host(context.frameHost)
        e.requested = context.requested
        e.attached = context.attached
        return e
    }

    /// Append only after the whitelist struct exists.
    private func record(_ event: DiagEvent) {
        events.append(event)
        if events.count > Self.maxEvents { events.removeFirst(events.count - Self.maxEvents) }
        if let line = event.line() { disk.append(line) }
    }

    func notePhase(jobId: String, generation: Int, stage: DiagStage, phase raw: String, context: DiagContext) {
        let phase = DiagSanitize.phase(raw)
        var t = trace(jobId: jobId, generation: generation)
        guard t.lastPhase != phase else { return }
        t.lastPhase = phase
        traces[jobId] = t
        var e = make(.phase, jobId: jobId, generation: generation, stage: stage, context: context)
        e.phase = phase
        record(e)
    }

    func noteTuning(jobId: String, generation: Int, stage: DiagStage, tuning raw: Any?, context: DiagContext) {
        guard let tuning = DiagTuning(payload: raw) else { return }
        var t = trace(jobId: jobId, generation: generation)
        guard t.lastTuningKey != tuning.changeKey else { return }
        t.lastTuningKey = tuning.changeKey
        traces[jobId] = t
        var e = make(.tuning, jobId: jobId, generation: generation, stage: stage, context: context)
        e.tuning = tuning
        record(e)
    }

    func noteFailure(jobId: String, generation: Int, stage: DiagStage, code: String?, category: String?,
                     httpStatus: Any?, tuning raw: Any?, context: DiagContext) {
        var e = make(.failure, jobId: jobId, generation: generation, stage: stage, context: context)
        e.errorCode = code.map(Diag.errorCode)
        e.errorCategory = category.flatMap { DiagErrorCategory(rawValue: $0) } ?? .other
        e.httpStatus = Diag.int(httpStatus, 100...599)
        if e.errorCategory == .http { e.requestHost = DiagSanitize.dnsHost(context.requestHost) }
        e.tuning = DiagTuning(payload: raw)
        if let host = DiagSanitize.host(context.refusalHost) {
            e.refusalHost = host
            e.refusalCode = DiagRefusalCode(rawValue: context.refusalCode ?? "") ?? .other
        }
        e.httpEvidence = context.httpEvidence
        record(e)
    }

    func noteOutcome(jobId: String, generation: Int, stage: DiagStage, terminal: String?, result: EngineTaskResult,
                     context: DiagContext) {
        var e = make(.outcome, jobId: jobId, generation: generation, stage: stage, context: context)
        e.terminal = terminal.flatMap { DiagTerminal(rawValue: $0) } ?? .missing
        e.outcome = DiagOutcome(result: result)
        record(e)
    }
}

// MARK: - Queue Snapshot DTOs

public struct DiagHttpEvidenceSummary: Encodable {
    public let stage: String?
    public let server: String?
    public let contentType: String?
    public let retryAfterSeconds: Int?
    public let cfMitigated: String?
    public let requestScope: String?
    public let hasReferer: Bool?
    public let hasOrigin: Bool?
    public let hasCookie: Bool?
    public let hasUserAgent: Bool?
    public let discoveryReason: String?
    public let discovery: DiagDiscoveryDetails?

    init(evidence: DiagHttpEvidence) {
        self.stage = evidence.failureStage?.rawValue
        self.server = evidence.httpResponse?.server?.rawValue
        self.contentType = evidence.httpResponse?.contentType
        self.retryAfterSeconds = evidence.httpResponse?.retryAfterSeconds
        self.cfMitigated = evidence.httpResponse?.cfMitigated
        self.requestScope = evidence.requestOptions?.scope?.rawValue
        self.hasReferer = evidence.requestOptions?.referer
        self.hasOrigin = evidence.requestOptions?.origin
        self.hasCookie = evidence.requestOptions?.cookie
        self.hasUserAgent = evidence.requestOptions?.userAgent
        self.discoveryReason = evidence.discoveryReason?.rawValue
        self.discovery = evidence.discovery
    }
}

public struct DiagnosticsQueueItem: Encodable {
    public let jobId: String?
    public let frameHost: String?
    public let id: String?
    public let traceLinked: Bool
    public let state: String
    public let generation: Int
    public let sourceHost: String?
    public let pageHost: String?
    public let fromBrowser: Bool
    public let safeBrowserPageReference: String?
    public let extractor: String?
    public let selectedFormatIds: [String]
    public let ext: String?
    public let protocolName: String?
    public let resolution: String?
    public let filesize: Int64?
    public let progressPercent: Double?
    public let speedBytesPerSec: Double?
    public let downloadedBytes: Int64?
    public let totalBytes: Int64?
    public let isLive: Bool
    public let recordLimitSeconds: Int?
    public let pendingDownload: Bool
    public let pendingPublish: Bool
    public let pendingRetry: Bool
    public let helperEnabled: Bool
    public let latestFailureHttpStatus: Int?
    public let latestFailureCategory: String?
    public let latestFailureCode: String?
    public let latestFailureStage: String?
    public let latestHttpEvidence: DiagHttpEvidenceSummary?

    public init(
        jobId: String?,
        frameHost: String?,
        id: String?,
        traceLinked: Bool,
        state: String,
        generation: Int,
        sourceHost: String?,
        pageHost: String?,
        fromBrowser: Bool,
        safeBrowserPageReference: String?,
        extractor: String?,
        selectedFormatIds: [String],
        ext: String?,
        protocolName: String?,
        resolution: String?,
        filesize: Int64?,
        progressPercent: Double?,
        speedBytesPerSec: Double?,
        downloadedBytes: Int64?,
        totalBytes: Int64?,
        isLive: Bool,
        recordLimitSeconds: Int?,
        pendingDownload: Bool,
        pendingPublish: Bool,
        pendingRetry: Bool,
        helperEnabled: Bool,
        latestFailureHttpStatus: Int?,
        latestFailureCategory: String?,
        latestFailureCode: String?,
        latestFailureStage: String?,
        latestHttpEvidence: DiagHttpEvidenceSummary?
    ) {
        self.jobId = jobId.flatMap { UUID(uuidString: $0)?.uuidString.lowercased() }
        self.frameHost = DiagSanitize.dnsHost(frameHost)
        self.id = id
        self.traceLinked = traceLinked
        self.state = state
        self.generation = generation
        self.sourceHost = DiagSanitize.dnsHost(sourceHost)
        self.pageHost = DiagSanitize.dnsHost(pageHost)
        self.fromBrowser = fromBrowser
        self.safeBrowserPageReference = safeBrowserPageReference
        self.extractor = extractor
        self.selectedFormatIds = selectedFormatIds
        self.ext = ext
        self.protocolName = protocolName
        self.resolution = resolution
        self.filesize = filesize
        self.progressPercent = progressPercent
        self.speedBytesPerSec = speedBytesPerSec
        self.downloadedBytes = downloadedBytes
        self.totalBytes = totalBytes
        self.isLive = isLive
        self.recordLimitSeconds = recordLimitSeconds
        self.pendingDownload = pendingDownload
        self.pendingPublish = pendingPublish
        self.pendingRetry = pendingRetry
        self.helperEnabled = helperEnabled
        self.latestFailureHttpStatus = latestFailureHttpStatus
        self.latestFailureCategory = latestFailureCategory
        self.latestFailureCode = latestFailureCode
        self.latestFailureStage = latestFailureStage
        self.latestHttpEvidence = latestHttpEvidence
    }
}

public struct DiagnosticsQueueSnapshot: Encodable {
    public static let maxSnapshotRows = 1000
    public static let maxManifestBytes = 1 << 20

    public let totalCount: Int
    public let includedCount: Int
    public let truncatedCount: Int
    public let isTruncated: Bool
    public let items: [DiagnosticsQueueItem]

    public init(
        totalCount: Int,
        includedCount: Int,
        truncatedCount: Int,
        isTruncated: Bool,
        items: [DiagnosticsQueueItem]
    ) {
        self.totalCount = totalCount
        self.includedCount = includedCount
        self.truncatedCount = truncatedCount
        self.isTruncated = isTruncated
        self.items = items
    }
}

// MARK: - Connection Failures Snapshot DTOs

enum DiagConnectionFailureCategory: String, Encodable {
    case policy
    case network
    case other
}

struct DiagnosticsConnectionFailureItem: Encodable {
    let host: String
    let code: String
    let category: String
    let port: Int?
    let count: Int
    let lastSeen: Int
    let isBrowserClient: Bool

    init(
        host: String,
        code: String,
        category: String,
        port: Int?,
        count: Int,
        lastSeen: Int,
        isBrowserClient: Bool
    ) {
        self.host = host
        self.code = code
        self.category = category
        self.port = port
        self.count = count
        self.lastSeen = lastSeen
        self.isBrowserClient = isBrowserClient
    }
}

struct DiagnosticsConnectionFailuresSnapshot: Encodable {
    static let maxSnapshotRows = 100

    let totalCount: Int
    let includedCount: Int
    let truncatedCount: Int
    let invalidCount: Int
    let suppressedCount: Int
    let isTruncated: Bool
    let items: [DiagnosticsConnectionFailureItem]

    init(
        totalCount: Int,
        includedCount: Int,
        truncatedCount: Int,
        invalidCount: Int = 0,
        suppressedCount: Int? = nil,
        isTruncated: Bool,
        items: [DiagnosticsConnectionFailureItem]
    ) {
        self.totalCount = totalCount
        self.includedCount = includedCount
        self.truncatedCount = truncatedCount
        self.invalidCount = invalidCount
        self.suppressedCount = suppressedCount ?? invalidCount
        self.isTruncated = isTruncated
        self.items = items
    }
}

// MARK: - Export (JSON manifest + JSONL trace → one ZIP)

struct DiagnosticsManifest: Encodable {
    struct App: Encodable { let version: String?; let build: String?; let arch: String }
    struct System: Encodable { let osVersion: String }
    struct Runtime: Encodable {
        let python: String?
        let ytdlp: String?
        let ffmpeg: String?
        let deno: String?
        let healthChecked: Bool
        let healthy: Bool
    }
    struct Config: Encodable { let connectionHelp: Bool; let runtimeMode: String }

    let schema = Diag.schemaVersion
    let generatedAt: Int
    let app: App
    let system: System
    let runtime: Runtime
    let config: Config
    let traceFile = DiagnosticsExporter.traceName
    let reportFile = DiagnosticsExporter.reportName
    let traceEvents: Int
    let traceEventLimit = DiagnosticsStore.maxEvents
    let queue: DiagnosticsQueueSnapshot?
    let connectionFailures: DiagnosticsConnectionFailuresSnapshot?
}

enum DiagnosticsExporter {
    static let manifestName = "manifest.json"
    static let traceName = "trace.jsonl"
    static let reportName = "report.html"
    private static let reportMaxRows = 40
    private static let reportMaxQueueRows = 100

    static func suggestedFileName() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "HTD-diagnostics-\(f.string(from: Date())).zip"
    }

    static func traceData(_ events: [DiagEvent]) -> Data {
        var out = Data()
        for e in events.suffix(DiagnosticsStore.maxEvents) {
            if let line = e.line() { out.append(line) }
        }
        return out
    }

    private static func escape(_ raw: String) -> String {
        var out = ""
        for c in raw {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(c)
            }
        }
        return out
    }

    private static func categoryLabel(_ c: DiagErrorCategory?) -> String {
        switch c {
        case .http: return "HTTP 응답"
        case .tls: return "TLS"
        case .proxy: return "연결 도움(프록시)"
        case .dns: return "DNS"
        case .network: return "네트워크"
        case .timeout: return "시간 초과"
        case .incomplete: return "불완전"
        case .unsupported: return "지원 안 됨"
        case .resource: return "자원"
        case .filesystem: return "파일 시스템"
        case .process: return "프로세스"
        case .other: return "기타"
        case nil: return "기록 없음"
        }
    }

    private static func stageLabel(_ s: DiagStage) -> String {
        switch s {
        case .extract: return "분석"
        case .download: return "다운로드"
        case .record: return "녹화"
        case .publish: return "저장"
        }
    }

    private static func attachmentLabel(_ requested: DiagAttachment?, _ attached: DiagAttachment?) -> String {
        guard let r = requested, let a = attached else { return "기록 없음" }
        func yn(_ v: Bool) -> String { v ? "예" : "아니오" }
        return [("프록시", r.proxy, a.proxy), ("리퍼러", r.referrer, a.referrer),
                ("인증 쿠키", r.session, a.session), ("UA", r.userAgent, a.userAgent)]
            .map { "\($0.0) 요청 \(yn($0.1)) / 엔진 전달 \(yn($0.2))" }.joined(separator: " · ")
    }

    /// Korean overview built only from the sanitized typed events and bounded current queue snapshot
    /// (every dynamic string is escaped; no unallowlisted links, scripts, or external resources).
    static func reportData(_ events: [DiagEvent], queue: DiagnosticsQueueSnapshot? = nil) -> Data {
        let failures = events.filter { $0.kind == .failure }.suffix(reportMaxRows).reversed()
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var rows = ""
        for e in failures {
            let httpRespLabel: String = {
                guard let hr = e.httpEvidence?.httpResponse else { return "기록 없음" }
                var items: [String] = []
                if let s = hr.server { items.append("서버: \(s.rawValue)") }
                if let ct = hr.contentType { items.append("타입: \(ct)") }
                if let ra = hr.retryAfterSeconds { items.append("재시도: \(ra)초") }
                if let cf = hr.cfMitigated { items.append("CF방어: \(cf)") }
                return items.isEmpty ? "기록 없음" : items.joined(separator: " · ")
            }()

            let reqOptsLabel: String = {
                guard let ro = e.httpEvidence?.requestOptions else { return "기록 없음" }
                func yn(_ v: Bool?) -> String {
                    switch v {
                    case true: return "있음"
                    case false: return "없음"
                    case nil: return "기록 없음"
                    }
                }
                let scopeStr: String
                switch ro.scope {
                case .selectedFormatOptions: scopeStr = "선택 형식 옵션"
                case .requestOptions: scopeStr = "요청 옵션"
                case nil: scopeStr = "기록 없음"
                }
                return "범위: \(scopeStr) · Referer: \(yn(ro.referer)) · Origin: \(yn(ro.origin)) · Cookie: \(yn(ro.cookie)) · UA: \(yn(ro.userAgent))"
            }()

            let failureStageLabel: String = {
                guard let fs = e.httpEvidence?.failureStage else { return "기록 없음" }
                switch fs {
                case .extraction: return "분석"
                case .download: return "다운로드"
                }
            }()

            let cells: [String] = [
                f.string(from: Date(timeIntervalSince1970: TimeInterval(e.time))),
                stageLabel(e.stage) + " · 시도 \(e.attempt)",
                failureStageLabel,
                e.pageHost ?? "기록 없음", e.frameHost ?? "기록 없음", e.host ?? "기록 없음", e.requestHost ?? "기록 없음",
                categoryLabel(e.errorCategory) + (e.errorCode.map { " (\($0))" } ?? ""),
                e.httpStatus.map { "HTTP \($0)" } ?? "기록 없음",
                httpRespLabel,
                e.proto?.rawValue ?? "기록 없음",
                attachmentLabel(e.requested, e.attached),
                reqOptsLabel,
                e.refusalHost.map { "\($0) (\(e.refusalCode?.rawValue ?? "other"))" } ?? "기록 없음"
            ]
            rows += "<tr>" + cells.map { "<td>\(escape($0))</td>" }.joined() + "</tr>\n"
        }
        let head = [
            "시각", "단계·시도", "진단 실패 단계", "방문한 사이트", "프레임", "작업 주소 호스트", "실제 응답 호스트",
            "오류 분류(코드)", "HTTP 상태", "HTTP 응답 메타데이터", "프로토콜",
            "브라우저 맥락 첨부", "선택 형식 요청 옵션", "연결 도움이 막은 호스트"
        ]
        let failureBody = failures.isEmpty
            ? "<p>기록된 실패가 없습니다.</p>"
            : "<table><tr>" + head.map { "<th>\(escape($0))</th>" }.joined() + "</tr>\n" + rows + "</table>"

        // Current queue section:
        let queueSection: String
        if let q = queue {
            var qRows = ""
            let displayedItems = q.items.prefix(reportMaxQueueRows)
            for item in displayedItems {
                let idText: String
                if item.traceLinked, let tid = item.id {
                    idText = tid
                } else if let tid = item.id {
                    idText = "\(tid) (미연결)"
                } else {
                    idText = "추적 연계 없음"
                }

                let pageRefHtml: String
                if let ref = item.safeBrowserPageReference {
                    if ref.hasPrefix("https://") {
                        pageRefHtml = "<a href=\"\(escape(ref))\">\(escape(ref))</a>"
                    } else {
                        pageRefHtml = escape(ref)
                    }
                } else if item.fromBrowser {
                    pageRefHtml = "기록 없음 (이전 작업은 복구 불가)"
                } else {
                    pageRefHtml = "해당 없음"
                }

                let failureSummary: String
                if let status = item.latestFailureHttpStatus {
                    let codePart = item.latestFailureCode.map { " (\($0))" } ?? ""
                    let stagePart = item.latestFailureStage.map { " [\($0)]" } ?? ""
                    failureSummary = "HTTP \(status)\(codePart)\(stagePart)"
                } else if let cat = item.latestFailureCategory {
                    failureSummary = "오류 (\(cat))"
                } else {
                    failureSummary = "실패 없음"
                }

                let qCells: [String] = [
                    escape((item.jobId ?? "기록 없음") + " / " + idText),
                    escape(item.state),
                    "\(item.generation)세대",
                    escape(item.sourceHost ?? "기록 없음"),
                    escape(item.pageHost ?? (item.fromBrowser ? "브라우저" : "기록 없음")),
                    pageRefHtml,
                    escape(failureSummary)
                ]
                qRows += "<tr>" + qCells.map { "<td>\($0)</td>" }.joined() + "</tr>\n"
            }

            let qHead = ["작업 ID / 진단 추적 ID", "상태", "세대", "등록 호스트", "방문 사이트", "안전한 원본 페이지 참조", "최근 실패"]
            let qTable = displayedItems.isEmpty
                ? "<p>대기열에 등록된 작업이 없습니다.</p>"
                : "<table><tr>" + qHead.map { "<th>\(escape($0))</th>" }.joined() + "</tr>\n" + qRows + "</table>"

            let truncNote: String
            if q.isTruncated || q.items.count > reportMaxQueueRows {
                let shown = min(q.items.count, reportMaxQueueRows)
                truncNote = "<p>대기열 총 \(q.totalCount)건 중 상위 \(shown)건을 표시합니다 (나머지는 생략됨). 상세 스냅샷과 생략 건수는 manifest.json을 확인하세요.</p>"
            } else {
                truncNote = ""
            }

            queueSection = """
            <h2>현재 대기열 상태 (총 \(q.totalCount)건 / 스냅샷 \(q.includedCount)건)</h2>
            <p>보안 정책상 실제 미디어 주소·제목·본문·비밀값은 제외되며, 검증된 안전한 원본 브라우저 페이지 주소만 표시됩니다. 이전 버전에서 등록된 브라우저 작업의 원본 페이지 주소는 복구할 수 없습니다.</p>
            \(qTable)
            \(truncNote)
            """
        } else {
            queueSection = ""
        }

        let html = """
        <!DOCTYPE html>
        <html lang="ko"><head><meta charset="utf-8"><title>HTD 진단 요약</title>
        <style>body{font-family:-apple-system,sans-serif;margin:16px}table{border-collapse:collapse;font-size:13px;margin-bottom:20px}th,td{border:1px solid #bbb;padding:4px 8px;text-align:left;vertical-align:top}th{background:#eee}h2{font-size:15px;margin-top:20px;margin-bottom:8px}a{color:#0066cc;word-break:break-all}</style>
        </head><body>
        <h1>HTD 진단 요약</h1>
        <p>동일한 로그 저장 ZIP에 보관된 현재 대기열 스냅샷, 최근 추적 이벤트 최대 \(DiagnosticsStore.maxEvents)건과 최근 실패 요약 최대 \(reportMaxRows)건(최신순)이 함께 포함되며, 현재 대기열 작업뿐만 아니라 이전 실패 기록도 함께 표시될 수 있습니다. 주소 전체 경로·쿼리·제목·본문·로그인 비밀값은 기록되지 않으며, 알 수 없는 항목은 '기록 없음'으로 표시됩니다. HTTP 상태는 실제 수신된 숫자 코드만 기록하며 원인을 임의로 추론하지 않습니다. '작업 주소 호스트'는 등록된 작업 주소의 호스트이며, 실제 오류 응답을 준 호스트는 '실제 응답 호스트'입니다(개인정보 보호를 위해 IP 주소는 제외되고 검증된 DNS 호스트명만 기록됨). '브라우저 맥락 첨부'는 앱이 엔진 실행 요청에 전달한 브라우저 컨텍스트이며, '선택 형식 요청 옵션'은 다운로더가 선택된 미디어 형식에 적용한 헤더 옵션 존재 여부로 서로 구분됩니다. 두 항목 모두 실제 헤더가 전송되었음을 증명하지 않습니다. 자세한 내용은 trace.jsonl 및 manifest.json을 참고하세요.</p>
        \(queueSection)
        <h2>최근 실패 요약</h2>
        \(failureBody)
        </body></html>
        """
        return Data(html.utf8)
    }

    /// Versions are reduced to numeric strings; health paths and failure reasons are never read.
    @MainActor
    static func manifestData(
        health: EngineHealthStatus,
        connectionHelp: Bool,
        runtimeMode: String,
        eventCount: Int,
        queue: DiagnosticsQueueSnapshot? = nil,
        connectionFailures: [ConnectionManager.BlockedHost] = []
    ) -> Data {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let info = Bundle.main.infoDictionary
        #if arch(arm64)
        let arch = "arm64"
        #elseif arch(x86_64)
        let arch = "x86_64"
        #else
        let arch = "other"
        #endif

        var validFailures: [DiagnosticsConnectionFailureItem] = []
        var invalidFailureCount = 0
        for raw in connectionFailures {
            guard let host = DiagSanitize.dnsHost(raw.host) else {
                invalidFailureCount += 1
                continue
            }
            let refusalCode = DiagRefusalCode(rawValue: raw.code) ?? .other
            let category: String
            switch refusalCode {
            case .dnsFailed, .connectFailed:
                category = DiagConnectionFailureCategory.network.rawValue
            case .notAllowed, .privateAddress, .plainHTTP, .badTarget, .badHost:
                category = DiagConnectionFailureCategory.policy.rawValue
            case .other:
                category = DiagConnectionFailureCategory.other.rawValue
            }
            let port: Int? = (1...65535).contains(raw.port) ? raw.port : nil
            let count = max(1, raw.count)
            let t = raw.lastSeen.timeIntervalSince1970
            let lastSeen = t.isFinite ? Int(max(0, min(t, 4_102_444_800))) : 0
            let isBrowserClient = (raw.client == ConnectionManager.browserClient)

            validFailures.append(DiagnosticsConnectionFailureItem(
                host: host,
                code: refusalCode.rawValue,
                category: category,
                port: port,
                count: count,
                lastSeen: lastSeen,
                isBrowserClient: isBrowserClient
            ))
        }

        let initialFailureRows = min(validFailures.count, DiagnosticsConnectionFailuresSnapshot.maxSnapshotRows)
        let initialFailureItems = Array(validFailures.prefix(initialFailureRows))
        let initialFailureTruncated = validFailures.count - initialFailureItems.count
        var currentFailures: DiagnosticsConnectionFailuresSnapshot? = DiagnosticsConnectionFailuresSnapshot(
            totalCount: connectionFailures.count,
            includedCount: initialFailureItems.count,
            truncatedCount: initialFailureTruncated,
            invalidCount: invalidFailureCount,
            suppressedCount: invalidFailureCount,
            isTruncated: initialFailureTruncated > 0,
            items: initialFailureItems
        )

        func makeManifest(
            with queueSnapshot: DiagnosticsQueueSnapshot?,
            failuresSnapshot: DiagnosticsConnectionFailuresSnapshot?
        ) -> DiagnosticsManifest {
            DiagnosticsManifest(
                generatedAt: Int(Date().timeIntervalSince1970),
                app: .init(version: DiagSanitize.version(info?["CFBundleShortVersionString"] as? String),
                           build: DiagSanitize.buildNumber(info?["CFBundleVersion"] as? String),
                           arch: arch),
                system: .init(osVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"),
                runtime: .init(python: DiagSanitize.version(health.pythonVersion),
                               ytdlp: DiagSanitize.version(health.ytdlpVersion),
                               ffmpeg: DiagSanitize.version(health.ffmpegVersion),
                               deno: DiagSanitize.version(health.denoVersion),
                               healthChecked: health.checked, healthy: health.healthy),
                config: .init(connectionHelp: connectionHelp,
                              runtimeMode: ["bundled", "development", "invalid"].contains(runtimeMode) ? runtimeMode : "invalid"),
                traceEvents: eventCount,
                queue: queueSnapshot,
                connectionFailures: failuresSnapshot)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        var currentQueue = queue
        while true {
            let manifest = makeManifest(with: currentQueue, failuresSnapshot: currentFailures)
            if let data = try? encoder.encode(manifest) {
                if data.count <= DiagnosticsQueueSnapshot.maxManifestBytes {
                    return data
                }
                if let q = currentQueue, !q.items.isEmpty {
                    let newCount = q.items.count / 2
                    let newItems = Array(q.items.prefix(newCount))
                    let newTruncated = q.totalCount - newItems.count
                    currentQueue = DiagnosticsQueueSnapshot(
                        totalCount: q.totalCount,
                        includedCount: newItems.count,
                        truncatedCount: newTruncated,
                        isTruncated: newTruncated > 0,
                        items: newItems
                    )
                    continue
                }
                if let f = currentFailures, !f.items.isEmpty {
                    let newCount = f.items.count / 2
                    let newItems = Array(f.items.prefix(newCount))
                    let newTruncated = validFailures.count - newItems.count
                    currentFailures = DiagnosticsConnectionFailuresSnapshot(
                        totalCount: f.totalCount,
                        includedCount: newItems.count,
                        truncatedCount: newTruncated,
                        invalidCount: f.invalidCount,
                        suppressedCount: f.suppressedCount,
                        isTruncated: newTruncated > 0,
                        items: newItems
                    )
                    continue
                }
                return data
            } else {
                return Data("{}".utf8)
            }
        }
    }

    private static func writeNew(_ path: String, _ data: Data) -> Bool {
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return data.withUnsafeBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n > 0 { offset += n } else if n < 0 && errno == EINTR { continue } else { return false }
            }
            return true
        }
    }

    /// Blocking (call off the main thread). Builds the ZIP in a private temp dir from the three prepared buffers
    /// (fixed generic entry names, `zip -j -X`: no paths, no extra attributes), then replaces `destination`
    /// atomically only once the archive is complete. Removes only the files it created.
    static func writeZip(manifest: Data, trace: Data, report: Data, destination: URL) -> Bool {
        guard destination.isFileURL, destination.pathExtension.lowercased() == "zip" else { return false }
        let temp = (NSTemporaryDirectory() as NSString).appendingPathComponent("htd-diag-" + UUID().uuidString)
        guard mkdir(temp, 0o700) == 0 else { return false }
        let manifestPath = temp + "/" + manifestName
        let tracePath = temp + "/" + traceName
        let reportPath = temp + "/" + reportName
        let zipPath = temp + "/out.zip"
        var staged: String?
        defer {
            _ = unlink(manifestPath); _ = unlink(tracePath); _ = unlink(reportPath); _ = unlink(zipPath)
            _ = rmdir(temp)
            if let staged = staged { _ = unlink(staged) }
        }
        guard writeNew(manifestPath, manifest), writeNew(tracePath, trace), writeNew(reportPath, report) else { return false }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-j", "-X", "-q", "out.zip", manifestName, traceName, reportName]
        process.currentDirectoryURL = URL(fileURLWithPath: temp, isDirectory: true)
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        var st = stat()
        guard process.terminationStatus == 0, lstat(zipPath, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG,
              st.st_size > 0 else { return false }

        // Same directory as the destination → rename(2) is an atomic replace; a failure leaves the old file alone.
        let stagedPath = destination.deletingLastPathComponent().path + "/.htd-diagnostics-" + UUID().uuidString + ".tmp"
        staged = stagedPath
        guard let archive = FileManager.default.contents(atPath: zipPath), writeNew(stagedPath, archive) else { return false }
        guard rename(stagedPath, destination.path) == 0 else { return false }
        staged = nil
        return true
    }
}
