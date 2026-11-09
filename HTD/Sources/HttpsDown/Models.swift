import Foundation

/// 사용자에게 보이는 앱 이름. HTT.app 안에 들어 있을 때는 HTT의 번역 브라우저로 보이고,
/// 단독 실행 때는 기존 HTD 이름을 그대로 쓴다. 번들 식별자와 데이터 경로는 바뀌지 않는다.
enum AppIdentity {
    /// 검증된 바깥 HTT.app 안에서 실행 중인지(BrowserExtensionManager.embeddingHTTApp과 같은 기준).
    static let isEmbedded: Bool = BrowserExtensionManager.embeddingHTTApp != nil
    static var displayName: String { isEmbedded ? "HTT 브라우저" : "HTD" }
}

public enum JobState: String, Codable, CaseIterable {
    case queued
    case extracting
    case awaitingSelection
    case downloading
    case recording
    case processing
    case verifying
    case publishing
    case completed
    case completedWithSubtitleFailure
    case paused
    case interrupted
    case cancelled
    case selectionChanged
    case verificationIncomplete
    case failed

    public var displayName: String {
        switch self {
        case .queued: return "대기 중"
        case .extracting: return "정보 분석 중"
        case .awaitingSelection: return "화질/자막 선택"
        case .downloading: return "다운로드 중"
        case .recording: return "녹화 중"
        case .processing: return "후처리/변환 중"
        case .verifying: return "미디어 무결성 검증 중"
        case .publishing: return "목적지 저장 중"
        case .completed: return "저장 완료"
        case .completedWithSubtitleFailure: return "저장 완료 (자막 실패)"
        case .paused: return "일시 정지"
        case .interrupted: return "중단됨 (비정상 종료)"
        case .cancelled: return "취소됨"
        case .selectionChanged: return "선택 변경 차단됨"
        case .verificationIncomplete: return "검증 불완전 (저장 안 함)"
        case .failed: return "오류 실패"
        }
    }

    public var isTerminal: Bool {
        switch self {
        case .completed, .completedWithSubtitleFailure, .cancelled, .failed, .interrupted, .selectionChanged, .verificationIncomplete:
            return true
        default:
            return false
        }
    }

    public var isActive: Bool {
        switch self {
        case .extracting, .downloading, .recording, .processing, .verifying, .publishing:
            return true
        default:
            return false
        }
    }
}

public struct MediaFormat: Identifiable, Codable, Hashable {
    public var id: String { formatId }
    public let formatId: String
    public let ext: String
    /// Raw engine values: nil = unknown, "none" = explicitly absent.
    public let vcodec: String?
    public let acodec: String?
    public let width: Int?
    public let height: Int?
    public let fps: Double?
    public let filesize: Int64?
    public let tbr: Double?
    public let formatNote: String?
    public let protocolName: String?

    /// Short transport label for the quality picker (DASH/HLS are ordinary choices, not hidden).
    public var protocolLabel: String? {
        guard let p = protocolName else { return nil }
        if p.hasPrefix("http_dash_segments") { return "DASH" }
        if p.hasPrefix("m3u8") { return "HLS" }
        return nil
    }

    public var isAudioOnly: Bool { vcodec == "none" && acodec != "none" }
    public var isVideoOnly: Bool { acodec == "none" && vcodec != "none" }
    /// Video+audio in one stream, including streams whose codecs are not reported.
    public var isMuxed: Bool { !isAudioOnly && !isVideoOnly && !(vcodec == "none" && acodec == "none") }

    /// Codecs the engine stream-copies into the final MP4 (mirrors Engine/mp4.py). nil = codec not reported yet.
    private static func fitsMP4(_ codec: String?) -> Bool? {
        guard let c = codec?.lowercased(), !c.isEmpty else { return nil }
        if c == "none" { return true }
        let copyable = ["avc1", "avc3", "h264", "hev1", "hvc1", "h265", "hevc", "av01", "av1",
                        "mp4a", "aac", "mp3", "ac-3", "ac3", "ec-3", "eac3", "flac", "alac"]
        return copyable.contains { c.hasPrefix($0) }
    }

    /// Final output for a video choice: always MP4; only tracks MP4 cannot carry are converted (H.264/AAC).
    public var mp4VideoNote: String {
        switch (Self.fitsMP4(vcodec) == false, Self.fitsMP4(acodec) == false) {
        case (true, true): return "→ MP4 (H.264/AAC 변환)"
        case (true, false): return "→ MP4 (H.264 변환)"
        case (false, true): return "→ MP4 (AAC 변환)"
        default: return "→ MP4"
        }
    }

    /// Separate audio track muxed into the MP4 video: converted to AAC when MP4 cannot carry it.
    public var mp4AudioNote: String? { Self.fitsMP4(acodec) == false ? "→ AAC 변환" : nil }

    public var resolutionDisplay: String {
        if let h = height {
            if let f = fps, f > 30 {
                return "\(h)p\(Int(f))"
            }
            return "\(h)p"
        }
        if isAudioOnly {
            return "오디오 전용"
        }
        return formatNote ?? ext
    }

    public var sizeDisplay: String {
        guard let size = filesize, size > 0 else { return "크기 미정" }
        let mb = Double(size) / (1024.0 * 1024.0)
        if mb >= 1000.0 {
            return String(format: "%.1f GB", mb / 1024.0)
        }
        return String(format: "%.1f MB", mb)
    }
}

public struct SubtitleOption: Identifiable, Codable, Hashable {
    public var id: String { "\(lang)_\(isAuto ? "auto" : "manual")" }
    public let lang: String
    public let name: String?
    public let isAuto: Bool

    public var displayTitle: String {
        let title = name ?? lang
        return isAuto ? "\(title) (자동 생성)" : "\(title) (제작 자막)"
    }
}

public struct SubtitleFile: Codable, Hashable {
    public var path: String
    public var lang: String
    public var isAuto: Bool
    public var ext: String
    public var size: Int64
}

public struct OutputManifest: Codable {
    public var primaryMediaFile: String?
    public var primarySize: Int64?
    public var subtitleFiles: [SubtitleFile] = []
    public var formatName: String?
    public var duration: Double?
    public var width: Int?
    public var height: Int?
    public var vcodec: String?
    public var acodec: String?
    /// Human-readable evidence for why the transfer is believed complete.
    public var completeness: String?
    public var subtitlesFailed: Bool = false
    public var subtitleError: String?
    /// Live recording: only the captured portion was saved ("녹화 구간 저장"), never the whole broadcast.
    public var isRecording: Bool?
    public var recordedSeconds: Double?
    /// user | limit | ended
    public var recordingEndReason: String?

    public init() {}

    public var recordingEndDescription: String? {
        switch recordingEndReason {
        case "user": return "직접 녹화를 마침"
        case "limit": return "정한 녹화 시간 도달"
        case "ended": return "방송 종료"
        default: return nil
        }
    }
}

/// Recording length choices (seconds). 30 minutes is the default.
public let recordingLimitChoices: [(seconds: Int, label: String)] = [
    (600, "10분"), (1800, "30분"), (3600, "1시간"), (7200, "2시간"), (14400, "4시간"), (43200, "12시간 (최대)")
]

public func formatClock(_ seconds: Double) -> String {
    let s = max(0, Int(seconds))
    if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
    return String(format: "%02d:%02d", s / 60, s % 60)
}

public enum RunMode: String, Codable {
    case full
    case subtitlesOnly
}

/// '속도 측정' (memory only, never persisted). Unknown metrics stay nil: a failed or cut phase is never shown as 0.
public struct SpeedTestState: Equatable {
    public enum Phase: String {
        case idle, preparing, connect, latency, download, upload, finished, failed, cancelled, unavailable
    }
    public var phase: Phase = .idle
    public var message = ""
    /// Connection path of this measurement (the app's current mode when it started).
    public var viaHelper = false
    public var latencyMs: Double?
    public var latencySamples = 0
    public var downloadMbps: Double?
    public var downloadPartial = false
    public var uploadMbps: Double?
    /// Rate of the sample in flight (live display only, never the result).
    public var liveMbps: Double?
    public var bytesUsed: Int64 = 0
    public var seconds: Double?
    public var failure: String?

    public var isRunning: Bool { [.preparing, .connect, .latency, .download, .upload].contains(phase) }
    /// Bounds of Engine/speed.py, shown to the user before and during the test.
    public static let byteCapMiB = 24
    public static let durationHint = "약 20~30초"
}

public struct JobRecord: Identifiable, Codable {
    public let id: String
    public var generation: Int
    /// Runtime: the exact address the user entered. Persisted only in redacted form (see `encode`).
    public var sourceURL: String
    /// True when `sourceURL` was loaded from disk with query/userinfo/opaque segments removed.
    public var urlWasRedacted: Bool = false
    /// Privately persisted safe public page reference (0600 store only) for retrying failed page jobs across restarts.
    public var retryPageURL: String? = nil
    /// Privately persisted safe public browser page reference (0600 store only) distinct from download source.
    public var browserPageReference: String? = nil
    public var title: String
    public var extractor: String?
    public var mediaId: String?
    public var duration: Double?
    public var state: JobState
    public var stateMessage: String?

    public var availableFormats: [MediaFormat] = []
    public var availableSubtitles: [SubtitleOption] = []

    public var selectedVideoFormatId: String?
    public var selectedAudioFormatId: String?
    public var selectedSubtitleIds: [String] = []

    /// A download (not extraction) is the next step when the queue picks this job.
    public var pendingDownload: Bool = false
    /// Verified output exists in the work folder but was not (provably) published yet.
    public var pendingPublish: Bool = false
    public var runMode: RunMode = .full

    public var progressPercent: Double = 0.0
    public var downloadedBytes: Int64 = 0
    public var totalBytes: Int64 = 0
    public var speed: Double = 0.0
    public var eta: Double = 0.0
    public var phase: String = ""

    public var destinationFolder: String
    public var workDirectory: String?
    public var publishedMediaPath: String?
    public var publishedSubtitlePaths: [String] = []
    public var manifest: OutputManifest?

    /// Live broadcast (recorded, never "downloaded whole"); separate from ordinary VOD.
    public var isLive: Bool = false
    public var liveStatus: String?
    /// Chosen recording bound in seconds (the user can also finish earlier).
    public var recordLimitSeconds: Int = 1800
    /// Runtime display only.
    public var recordedSeconds: Double = 0
    /// The user attached the app's own login session to this job. Only this flag and the bound site (a domain name)
    /// are persisted; cookies are fetched from the live session at run time and never stored.
    public var useLoginSession: Bool = false
    public var loginSite: String?
    /// Chosen from a video candidate in the app's browser. Persisted as a flag only.
    public var fromBrowser: Bool = false
    /// Effective route ("assist"/"direct") of the browser tab this job was queued from, captured once at enqueue
    /// (including a route the tab merely inherited). Optional additive key: older files simply lack it. A job only
    /// runs while this equals the app's global route; it is never recomputed and no other store's cookies are used.
    public var sourceRoute: String?
    /// Runtime only (never persisted): Referer of the page the candidate was found on, sent with this job's requests.
    public var pageReferer: String?
    /// Hostnames only (validated by `DiagSanitize.host`) of the browser's top page and of the chosen embedded frame, for
    /// the diagnostic trace. Never a URL, path or Referer.
    public var pageHost: String?
    public var frameHost: String?
    /// Runtime only: one-shot intent of a newly added link: after analysis, download with the default selection without another click.
    public var autoConfirm: Bool = false

    public var createdAt: Date
    public var updatedAt: Date

    public var redactedURL: String { persistableURL(sourceURL).url }

    public init(
        id: String = UUID().uuidString,
        generation: Int = 1,
        sourceURL: String,
        destinationFolder: String,
        title: String = "주소 분석 준비 중..."
    ) {
        self.id = id
        self.generation = generation
        self.sourceURL = sourceURL
        self.destinationFolder = destinationFolder
        self.title = title
        self.state = .queued
        self.stateMessage = "다운로드 대기열에 추가되었습니다."
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    private enum CodingKeys: String, CodingKey {
        case id, generation, sourceURL, urlWasRedacted, title, extractor, mediaId, duration, state, stateMessage
        case availableFormats, availableSubtitles, selectedVideoFormatId, selectedAudioFormatId, selectedSubtitleIds
        case pendingDownload, pendingPublish, runMode
        case progressPercent, downloadedBytes, totalBytes, speed, eta, phase
        case destinationFolder, workDirectory, publishedMediaPath, publishedSubtitlePaths, manifest, createdAt, updatedAt
        case isLive, liveStatus, recordLimitSeconds, useLoginSession, loginSite, fromBrowser, pageHost, frameHost, sourceRoute
        case retryPageURL, browserPageReference
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        generation = try c.decodeIfPresent(Int.self, forKey: .generation) ?? 1
        sourceURL = try c.decode(String.self, forKey: .sourceURL)
        urlWasRedacted = try c.decodeIfPresent(Bool.self, forKey: .urlWasRedacted) ?? false
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        extractor = try c.decodeIfPresent(String.self, forKey: .extractor)
        mediaId = try c.decodeIfPresent(String.self, forKey: .mediaId)
        duration = try c.decodeIfPresent(Double.self, forKey: .duration)
        state = try c.decode(JobState.self, forKey: .state)
        stateMessage = try c.decodeIfPresent(String.self, forKey: .stateMessage)
        availableFormats = try c.decodeIfPresent([MediaFormat].self, forKey: .availableFormats) ?? []
        availableSubtitles = try c.decodeIfPresent([SubtitleOption].self, forKey: .availableSubtitles) ?? []
        selectedVideoFormatId = try c.decodeIfPresent(String.self, forKey: .selectedVideoFormatId)
        selectedAudioFormatId = try c.decodeIfPresent(String.self, forKey: .selectedAudioFormatId)
        selectedSubtitleIds = try c.decodeIfPresent([String].self, forKey: .selectedSubtitleIds) ?? []
        pendingDownload = try c.decodeIfPresent(Bool.self, forKey: .pendingDownload) ?? false
        pendingPublish = try c.decodeIfPresent(Bool.self, forKey: .pendingPublish) ?? false
        runMode = try c.decodeIfPresent(RunMode.self, forKey: .runMode) ?? .full
        progressPercent = try c.decodeIfPresent(Double.self, forKey: .progressPercent) ?? 0
        downloadedBytes = try c.decodeIfPresent(Int64.self, forKey: .downloadedBytes) ?? 0
        totalBytes = try c.decodeIfPresent(Int64.self, forKey: .totalBytes) ?? 0
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? 0
        eta = try c.decodeIfPresent(Double.self, forKey: .eta) ?? 0
        phase = try c.decodeIfPresent(String.self, forKey: .phase) ?? ""
        destinationFolder = try c.decode(String.self, forKey: .destinationFolder)
        workDirectory = try c.decodeIfPresent(String.self, forKey: .workDirectory)
        publishedMediaPath = try c.decodeIfPresent(String.self, forKey: .publishedMediaPath)
        publishedSubtitlePaths = try c.decodeIfPresent([String].self, forKey: .publishedSubtitlePaths) ?? []
        manifest = try c.decodeIfPresent(OutputManifest.self, forKey: .manifest)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        isLive = try c.decodeIfPresent(Bool.self, forKey: .isLive) ?? false
        liveStatus = try c.decodeIfPresent(String.self, forKey: .liveStatus)
        recordLimitSeconds = try c.decodeIfPresent(Int.self, forKey: .recordLimitSeconds) ?? 1800
        useLoginSession = try c.decodeIfPresent(Bool.self, forKey: .useLoginSession) ?? false
        loginSite = try c.decodeIfPresent(String.self, forKey: .loginSite)
        fromBrowser = try c.decodeIfPresent(Bool.self, forKey: .fromBrowser) ?? false
        sourceRoute = try c.decodeIfPresent(String.self, forKey: .sourceRoute)
        pageHost = DiagSanitize.host(try c.decodeIfPresent(String.self, forKey: .pageHost))
        frameHost = DiagSanitize.host(try c.decodeIfPresent(String.self, forKey: .frameHost))
        let decodedRetry = try c.decodeIfPresent(String.self, forKey: .retryPageURL)
        if let rawRetry = decodedRetry,
           let validated = validateSafeRetryPageURL(rawRetry, fromBrowser: fromBrowser, hasPageProvenance: true),
           isConsistentReference(retryURL: validated, sourceURL: sourceURL) {
            sourceURL = validated
            retryPageURL = validated
            urlWasRedacted = false
        } else {
            retryPageURL = nil
        }
        let decodedBrowserPage = try c.decodeIfPresent(String.self, forKey: .browserPageReference)
        if let rawBrowserPage = decodedBrowserPage,
           let validated = validateSafeRetryPageURL(rawBrowserPage, fromBrowser: false, hasPageProvenance: true) {
            browserPageReference = validated
        } else {
            browserPageReference = nil
        }
    }

    /// Persisted form never contains the private address: only a redacted copy plus a flag.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        let persisted = persistableURL(sourceURL)
        try c.encode(id, forKey: .id)
        try c.encode(generation, forKey: .generation)
        try c.encode(persisted.url, forKey: .sourceURL)
        try c.encode(persisted.redacted || urlWasRedacted, forKey: .urlWasRedacted)
        try c.encode(redactPersistedText(title), forKey: .title)
        try c.encodeIfPresent(extractor, forKey: .extractor)
        try c.encodeIfPresent(mediaId, forKey: .mediaId)
        try c.encodeIfPresent(duration, forKey: .duration)
        try c.encode(state, forKey: .state)
        try c.encodeIfPresent(stateMessage.map(redactPersistedText), forKey: .stateMessage)
        try c.encode(availableFormats, forKey: .availableFormats)
        try c.encode(availableSubtitles, forKey: .availableSubtitles)
        try c.encodeIfPresent(selectedVideoFormatId, forKey: .selectedVideoFormatId)
        try c.encodeIfPresent(selectedAudioFormatId, forKey: .selectedAudioFormatId)
        try c.encode(selectedSubtitleIds, forKey: .selectedSubtitleIds)
        try c.encode(pendingDownload, forKey: .pendingDownload)
        try c.encode(pendingPublish, forKey: .pendingPublish)
        try c.encode(runMode, forKey: .runMode)
        try c.encode(progressPercent, forKey: .progressPercent)
        try c.encode(downloadedBytes, forKey: .downloadedBytes)
        try c.encode(totalBytes, forKey: .totalBytes)
        try c.encode(speed, forKey: .speed)
        try c.encode(eta, forKey: .eta)
        try c.encode(phase, forKey: .phase)
        try c.encode(destinationFolder, forKey: .destinationFolder)
        try c.encodeIfPresent(workDirectory, forKey: .workDirectory)
        try c.encodeIfPresent(publishedMediaPath, forKey: .publishedMediaPath)
        try c.encode(publishedSubtitlePaths, forKey: .publishedSubtitlePaths)
        try c.encodeIfPresent(manifest, forKey: .manifest)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(isLive, forKey: .isLive)
        try c.encodeIfPresent(liveStatus, forKey: .liveStatus)
        try c.encode(recordLimitSeconds, forKey: .recordLimitSeconds)
        try c.encode(useLoginSession, forKey: .useLoginSession)
        try c.encodeIfPresent(loginSite, forKey: .loginSite)
        try c.encode(fromBrowser, forKey: .fromBrowser)
        try c.encodeIfPresent(sourceRoute, forKey: .sourceRoute)
        try c.encodeIfPresent(DiagSanitize.host(pageHost), forKey: .pageHost)
        try c.encodeIfPresent(DiagSanitize.host(frameHost), forKey: .frameHost)
        if let ref = retryPageURL,
           let valid = validateSafeRetryPageURL(ref, fromBrowser: fromBrowser, hasPageProvenance: true),
           isConsistentReference(retryURL: valid, sourceURL: sourceURL) {
            try c.encode(valid, forKey: .retryPageURL)
        }
        if let pageRef = browserPageReference,
           let valid = validateSafeRetryPageURL(pageRef, fromBrowser: false, hasPageProvenance: true) {
            try c.encode(valid, forKey: .browserPageReference)
        }
    }
}

public struct EngineHealthStatus: Codable {
    public var healthy: Bool = false
    public var checked: Bool = false
    public var pythonPath: String = ""
    public var pythonVersion: String = ""
    public var ytdlpAvailable: Bool = false
    public var ytdlpVersion: String = ""
    public var ffmpegAvailable: Bool = false
    public var ffmpegPath: String? = nil
    public var ffmpegVersion: String = ""
    public var ffprobeAvailable: Bool = false
    public var ffprobePath: String? = nil
    public var denoAvailable: Bool = false
    public var denoPath: String? = nil
    public var denoVersion: String = ""
    public var ejsAvailable: Bool = false
    public var failureReason: String? = nil
    public var engineType: String = "개발용 로컬 엔진 스택 (개발 환경 전용 - GPL 포함)"
    public var lastChecked: Date? = nil

    public init() {}
}

// MARK: - Site scope

/// Second-level public suffixes that commonly hold registrations (no full Public Suffix List is bundled).
private let multiLabelSuffixes: Set<String> = [
    "co.kr", "or.kr", "ne.kr", "go.kr", "ac.kr", "re.kr", "pe.kr", "ms.kr", "hs.kr", "es.kr", "sc.kr", "kg.kr",
    "co.jp", "ne.jp", "or.jp", "ac.jp", "go.jp", "co.uk", "org.uk", "ac.uk", "gov.uk", "me.uk",
    "com.au", "net.au", "org.au", "edu.au", "com.br", "com.cn", "net.cn", "org.cn", "com.tw", "com.hk",
    "co.nz", "co.in", "com.sg", "com.mx", "com.tr", "co.za", "com.ar"
]

/// The site a host belongs to (eTLD+1 approximation). Used to bind login cookies and connection-assist policy to the
/// site the user explicitly chose. Returns nil for IP literals and single-label names.
public func siteDomain(forHost rawHost: String) -> String? {
    let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
    guard host.contains("."), !host.contains(":"), host.rangeOfCharacter(from: CharacterSet.letters) != nil else { return nil }
    let labels = host.split(separator: ".").map(String.init)
    guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }) else { return nil }
    let lastTwo = labels.suffix(2).joined(separator: ".")
    if multiLabelSuffixes.contains(lastTwo) {
        return labels.count >= 3 ? labels.suffix(3).joined(separator: ".") : nil
    }
    return lastTwo
}

public func siteDomain(forURL urlString: String) -> String? {
    guard let host = URLComponents(string: urlString)?.host else { return nil }
    return siteDomain(forHost: host)
}

// MARK: - Redaction helpers

private func isOpaqueSegment(_ s: Substring) -> Bool {
    guard s.count >= 24 else { return false }
    return s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
}

private func isCanonicalTwitchClipPath(scheme: String?, host: String?, port: Int?, hadUserInfo: Bool, segments: [Substring]) -> Bool {
    guard !hadUserInfo else { return false }
    guard let s = scheme?.lowercased(), s == "https" || s == "http" else { return false }
    guard let h = host?.lowercased(), h == "clips.twitch.tv" else { return false }
    if s == "https" {
        guard port == nil || port == 443 else { return false }
    } else {
        guard port == nil || port == 80 else { return false }
    }
    guard (segments.count == 2 && segments[0].isEmpty && !segments[1].isEmpty)
            || (segments.count == 3 && segments[0].isEmpty && !segments[1].isEmpty && segments[2].isEmpty) else {
        return false
    }
    let slug = segments[1]
    guard slug.count <= 100 else { return false }
    return slug.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
}

/// Address safe to write to disk: no userinfo, fragment, opaque path tokens or (non-trivial) query.
/// `redacted == true` means the stored address can no longer reproduce the original request.
public func persistableURL(_ urlString: String) -> (url: String, redacted: Bool) {
    guard var comps = URLComponents(string: urlString), comps.host != nil else {
        return ("[잘못된 주소]", true)
    }
    var redacted = false
    let hadUserInfo = comps.user != nil || comps.password != nil
    if hadUserInfo {
        comps.user = nil
        comps.password = nil
        redacted = true
    }
    if comps.fragment != nil {
        comps.fragment = nil
        redacted = true
    }
    let segments = comps.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false)
    let isTwitchClip = isCanonicalTwitchClipPath(scheme: comps.scheme, host: comps.host, port: comps.port, hadUserInfo: hadUserInfo, segments: segments)
    if !isTwitchClip && segments.contains(where: isOpaqueSegment) {
        comps.percentEncodedPath = segments.map { isOpaqueSegment($0) ? "%E2%80%A6" : String($0) }.joined(separator: "/")
        redacted = true
    }
    if let items = comps.queryItems, !items.isEmpty {
        let allowedKeys: Set<String> = ["v", "id"]
        let harmless = items.allSatisfy { item in
            guard allowedKeys.contains(item.name), let value = item.value, value.count <= 40 else { return false }
            return value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
        }
        if !harmless {
            comps.percentEncodedQuery = nil
            redacted = true
        }
    }
    return (comps.string ?? "[잘못된 주소]", redacted)
}

/// Exact known public normal-page routes (https, no query/userinfo/fragment, standard port, digits only id):
/// yadongtv114.com/posts/<digits>, yagong98.com/posts/<digits>, mingky20.com/movie/<digits>.
public func isKnownModelsPageRoute(_ urlString: String) -> Bool {
    guard urlString.count <= 256, urlString.allSatisfy({ $0.isASCII && $0 != "%" && $0 != "?" && $0 != "#" && $0 != "@" }),
          let comps = URLComponents(string: urlString),
          comps.scheme == "https", comps.user == nil, comps.password == nil,
          comps.query == nil, comps.fragment == nil,
          comps.port == nil || comps.port == 443,
          let host = comps.host, host == host.lowercased() else { return false }
    let routes: [String: String] = ["yadongtv114.com": "posts", "yagong98.com": "posts", "mingky20.com": "movie"]
    guard let word = routes[host] else { return false }
    let parts = comps.percentEncodedPath.components(separatedBy: "/")
    guard parts.count == 3, parts[0].isEmpty, parts[1] == word else { return false }
    let id = parts[2]
    return !id.isEmpty && id.count <= 20 && id.allSatisfy { $0 >= "0" && $0 <= "9" }
}

/// Strict public YouTube watch reference: `https://www.youtube.com/watch?v=<11 ASCII URL-safe chars>` and nothing else.
public func canonicalYouTubeWatchURL(videoID: String?) -> String? {
    guard let id = videoID, id.utf8.count == 11,
          id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) else { return nil }
    return "https://www.youtube.com/watch?v=\(id)"
}

private func youTubeWatchComponents(_ raw: String) -> URLComponents? {
    guard raw.count <= 4096, let c = URLComponents(string: raw),
          let scheme = c.scheme?.lowercased(), scheme == "https" || scheme == "http",
          c.user == nil, c.password == nil, c.port == nil || c.port == (scheme == "https" ? 443 : 80),
          let host = c.host?.lowercased(), ["youtube.com", "www.youtube.com", "m.youtube.com"].contains(host),
          c.path == "/watch" else { return nil }
    return c
}

/// A YouTube watch address (any known host, tracking parameters allowed) reduced to its canonical reference.
/// Only the video id survives; every other parameter, userinfo and fragment is discarded.
public func canonicalYouTubeWatchURL(from raw: String) -> String? {
    guard let c = youTubeWatchComponents(raw) else { return nil }
    let ids = (c.queryItems ?? []).filter { $0.name == "v" }
    guard ids.count == 1 else { return nil }
    return canonicalYouTubeWatchURL(videoID: ids[0].value)
}

/// A YouTube watch source whose query may already have been redacted away by the job store.
public func isYouTubeWatchSource(_ raw: String) -> Bool { youTubeWatchComponents(raw) != nil }

/// Validates an address for safe persistence as an optional retry page reference in the 0600 job store.
/// Narrow policy: public DNS-like host, http(s), standard port, no credentials/userinfo/fragment/controls,
/// no media extensions/paths, no forbidden path components (media/key/token/auth/session/login/api/cdn/stream/segment/manifest),
/// no fromBrowser media jobs; only the observed public Wiki article and Yas item-page routes are eligible.
public func validateSafeRetryPageURL(
    _ urlString: String,
    fromBrowser: Bool = false,
    hasPageProvenance: Bool = false
) -> String? {
    guard !fromBrowser else { return nil }
    guard !urlString.isEmpty, urlString.count <= 4096 else { return nil }
    if canonicalYouTubeWatchURL(from: urlString) == urlString { return urlString }
    guard !urlString.contains(where: { $0.isASCII && ($0.asciiValue! < 32 || $0.asciiValue! == 127) }) else { return nil }

    guard let comps = URLComponents(string: urlString),
          let scheme = comps.scheme?.lowercased(),
          (scheme == "https" || scheme == "http"),
          let rawHost = comps.host else {
        return nil
    }

    // No credentials, no userinfo, no fragment (do not strip; reject if present)
    guard comps.user == nil, comps.password == nil, comps.fragment == nil else { return nil }
    if let user = comps.percentEncodedUser, !user.isEmpty { return nil }
    if let pass = comps.percentEncodedPassword, !pass.isEmpty { return nil }
    if comps.percentEncodedFragment != nil { return nil }

    // Standard port check
    if let port = comps.port {
        if scheme == "https" && port != 443 { return nil }
        if scheme == "http" && port != 80 { return nil }
    }

    // Host validation: bounded ASCII DNS labels, reject local/private-special suffixes, literal/numeric/hex-IP style hosts
    guard !rawHost.contains(":"), !rawHost.contains("@"), !rawHost.contains("["), !rawHost.contains("]") else { return nil }
    let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
    guard rawHost.lowercased() == host, !host.isEmpty, host.count <= 253, host.allSatisfy({ $0.isASCII }) else { return nil }

    // Only these observed public article routes may retain identifiers that the normal store redacts.
    let pageSegments = comps.path.components(separatedBy: "/")
    let knownWikiPage = scheme == "https" && host == "19wiki16.com"
        && pageSegments.count == 3 && pageSegments[0].isEmpty && pageSegments[1] == "한국"
        && !pageSegments[2].isEmpty && comps.query == nil
    let query = comps.queryItems ?? []
    let knownYasPage = scheme == "https" && host == "yasyadong04.tv" && comps.path == "/"
        && query.count == 2
        && query.contains { $0.name == "_Action" && $0.value == "items" }
        && query.contains { item in
            guard item.name == "items_id", let value = item.value, !value.isEmpty, value.count <= 32 else { return false }
            return value.allSatisfy { $0 >= "0" && $0 <= "9" }
        }
    let knownModelsPage = isKnownModelsPageRoute(urlString)
    guard knownWikiPage || knownYasPage || knownModelsPage else { return nil }

    let privateSpecialSuffixes = [
        ".localhost", ".local", ".internal", ".lan", ".home", ".home.arpa", ".arpa", ".test", ".invalid", ".onion"
    ]
    for suffix in privateSpecialSuffixes {
        if host == suffix.dropFirst() || host.hasSuffix(suffix) {
            return nil
        }
    }

    let labels = host.split(separator: ".", omittingEmptySubsequences: false)
    guard labels.count >= 2 else { return nil }
    for label in labels {
        guard !label.isEmpty, label.count <= 63 else { return nil }
        guard let first = label.first, let last = label.last,
              first.isASCII && (first.isLetter || first.isNumber),
              last.isASCII && (last.isLetter || last.isNumber) else { return nil }
        guard label.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return nil }
        if label.hasPrefix("0x") || label.hasPrefix("0X") { return nil }
    }

    guard host.contains(where: { $0.isASCII && $0.isLetter }) else { return nil }
    guard let tld = labels.last, let tldFirst = tld.first, tldFirst.isLetter, !tld.allSatisfy({ $0.isNumber }) else {
        return nil
    }

    // Disallowed extensions: media manifest, video, audio, image, subtitle, and segment
    let disallowedExtensions: Set<String> = [
        "mp4", "m4v", "m4a", "m4s", "mp3", "aac", "flac", "ogg", "wav", "webm", "mkv", "avi", "mov", "wmv", "flv", "ts", "m2ts",
        "m3u8", "m3u", "mpd", "f4m", "ism", "manifest",
        "key", "seg", "segment", "part", "chunk",
        "jpg", "jpeg", "png", "gif", "webp", "bmp", "svg", "ico",
        "vtt", "srt", "ass", "sub"
    ]

    // Forbidden path components: MUST reject media/key/token/auth/session/login/api/cdn/stream/segment/manifest
    let forbiddenPathComponents: Set<String> = [
        "media", "key", "token", "auth", "session", "login", "api", "cdn", "stream", "segment", "manifest"
    ]

    let segments = comps.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false)
    for seg in segments {
        let decodedSeg = (seg.removingPercentEncoding ?? String(seg)).lowercased()
        if decodedSeg.isEmpty { continue }

        let segBase = (decodedSeg as NSString).deletingPathExtension
        let segExt = (decodedSeg as NSString).pathExtension

        if forbiddenPathComponents.contains(decodedSeg) || forbiddenPathComponents.contains(segBase) {
            return nil
        }
        if !segExt.isEmpty && disallowedExtensions.contains(segExt) {
            return nil
        }
        if decodedSeg.hasSuffix(".m3u8") || decodedSeg.hasSuffix(".mpd") || decodedSeg == "manifest" {
            return nil
        }
    }

    // Explicit route keywords
    let explicitRouteKeywords: Set<String> = [
        "view", "post", "watch", "video", "videos", "article", "board", "read", "detail", "content", "entry", "p", "bbs"
    ]
    let hasExplicitPageRoute = segments.contains { seg in
        let decoded = (seg.removingPercentEncoding ?? String(seg)).lowercased()
        let base = (decoded as NSString).deletingPathExtension
        return explicitRouteKeywords.contains(decoded) || explicitRouteKeywords.contains(base)
    }

    // Canonical 36-char hex/dash UUID check (bare 32-hex is rejected)
    let hasCanonicalUUIDSegment = segments.contains { seg in
        let decoded = (seg.removingPercentEncoding ?? String(seg)).lowercased()
        guard decoded.count == 36 else { return false }
        let parts = decoded.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 5,
              parts[0].count == 8,
              parts[1].count == 4,
              parts[2].count == 4,
              parts[3].count == 4,
              parts[4].count == 12 else {
            return false
        }
        return decoded.allSatisfy { ($0 >= "0" && $0 <= "9") || ($0 >= "a" && $0 <= "f") || $0 == "-" }
    }

    // Query validation
    if let items = comps.queryItems, !items.isEmpty {
        var queryMap: [String: String] = [:]
        var seenKeys = Set<String>()

        for item in items {
            let k = item.name.lowercased()
            // Reject duplicates case-insensitively BEFORE dictionary assignment
            if seenKeys.contains(k) {
                return nil
            }
            seenKeys.insert(k)

            guard let v = item.value, !v.isEmpty else { return nil }
            queryMap[k] = v
        }

        let keys = Set(queryMap.keys)

        // Require COMPLETE explicit families, not any single key or mixed extra keys
        if keys == Set(["_action", "items_id"]) {
            let act = queryMap["_action"]!
            guard act.count <= 32, act.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) else { return nil }
            let allowedActions: Set<String> = ["items"]
            guard allowedActions.contains(act.lowercased()) else { return nil }

            let itemsId = queryMap["items_id"]!
            guard itemsId.count <= 32, itemsId.allSatisfy({ $0 >= "0" && $0 <= "9" }) else { return nil }
            return urlString
        } else if keys == Set(["bo_table", "wr_id"]) {
            let bo = queryMap["bo_table"]!
            guard bo.count <= 64, bo.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) else { return nil }

            let wr = queryMap["wr_id"]!
            guard wr.count <= 32, wr.allSatisfy({ $0 >= "0" && $0 <= "9" }) else { return nil }
            return urlString
        } else if keys == Set(["id"]) {
            let idVal = queryMap["id"]!
            guard idVal.count <= 64, idVal.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) else { return nil }
            guard hasPageProvenance || hasExplicitPageRoute else { return nil }
            return urlString
        } else if keys == Set(["v"]) {
            let vVal = queryMap["v"]!
            guard vVal.count <= 64, vVal.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) else { return nil }
            guard hasPageProvenance || hasExplicitPageRoute else { return nil }
            return urlString
        } else {
            // Unknown keys, partial families, or mixed extra keys rejected
            return nil
        }
    } else {
        // No query: must feature canonical 36-char UUID with page provenance or explicit page route
        if hasCanonicalUUIDSegment && knownWikiPage {
            return urlString
        }
        if knownModelsPage {
            return urlString
        }
    }

    return nil
}

public func isConsistentReference(retryURL: String, sourceURL: String) -> Bool {
    if canonicalYouTubeWatchURL(from: retryURL) == retryURL, isYouTubeWatchSource(sourceURL) {
        // The stored source may have lost (or never had) its query; a present id must still match.
        let sourceID = canonicalYouTubeWatchURL(from: sourceURL)
        return sourceID == nil ? !sourceURL.contains("v=") : sourceID == retryURL
    }
    guard retryURL == sourceURL || persistableURL(retryURL).url == sourceURL else { return false }
    guard let rComps = URLComponents(string: retryURL),
          let sComps = URLComponents(string: sourceURL),
          let rScheme = rComps.scheme?.lowercased(),
          let sScheme = sComps.scheme?.lowercased(),
          rScheme == sScheme,
          let rHost = rComps.host?.lowercased(),
          let sHost = sComps.host?.lowercased(),
          rHost == sHost else { return false }

    let rPort = rComps.port ?? (rScheme == "https" ? 443 : (rScheme == "http" ? 80 : 0))
    let sPort = sComps.port ?? (sScheme == "https" ? 443 : (sScheme == "http" ? 80 : 0))
    guard rPort == sPort else { return false }

    let rSegments = rComps.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false)
    let sSegments = sComps.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false)
    guard rSegments.count == sSegments.count else { return false }
    for (r, s) in zip(rSegments, sSegments) {
        if s == "%E2%80%A6" || s == "…" { continue }
        if r != s { return false }
    }
    return true
}

/// Defence in depth for free text (titles, status messages) that reaches the job store.
public func redactPersistedText(_ text: String) -> String {
    var out = text
    let patterns: [(String, String)] = [
        ("[A-Za-z][A-Za-z0-9+.\\-]*://[^\\s\"'<>)\\]]+", "[주소]"),
        ("(?i)\\b(authorization|cookie|set-cookie)\\s*[:=]\\s*[^\\r\\n]+", "$1: [가림]"),
        ("(?i)\\bbearer\\s+[A-Za-z0-9._~+/=\\-]+", "Bearer [가림]"),
        ("\\b[A-Za-z0-9_\\-+/=]{32,}\\b", "[가림]")
    ]
    for (pattern, template) in patterns {
        if let re = try? NSRegularExpression(pattern: pattern) {
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: template)
        }
    }
    return out
}
