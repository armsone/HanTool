import Foundation
import WebKit

/// One video address seen on the current page of the app's browser. A candidate is a hint, not proof that the media
/// is complete or downloadable; the engine still checks the final file. URLs stay in memory only.
struct MediaCandidate: Identifiable, Equatable {
    enum Kind: String {
        case file, hls, dash, element, blob
    }

    enum ObservationSource: String {
        case resource, element, navigation
    }

    let id: String
    /// nil for `.blob`: a player hint only (MediaSource playback cannot be fetched outside the page). It is neither a
    /// failure nor downloadable; a real address may still show up as the player prepares.
    let url: URL?
    let kind: Kind
    let title: String
    /// Top-level page the candidate was found on (Referer context for the job).
    let pageURL: URL
    let isMainFrame: Bool
    let frameHost: String
    /// Document URL of the embedding frame (native `WKFrameInfo.request.url`), http(s) only; nil for the main frame or
    /// when unusable. Only the Referer source for the job; `pageURL` stays the page/session owner.
    var frameURL: URL? = nil
    var observationSource: ObservationSource = .navigation
    /// Browser session + document generation at discovery; selection is refused once either changed.
    let sessionToken: Int
    let generation: Int

    var supported: Bool { kind != .blob && url != nil }

    var typeLabel: String {
        switch kind {
        case .file:
            let ext = url?.pathExtension.uppercased() ?? ""
            return ext.isEmpty ? "영상 파일" : "\(ext) 파일"
        case .hls: return "HLS 스트림"
        case .dash: return "DASH 스트림"
        case .element: return "재생 중인 영상"
        case .blob: return "영상 주소 찾는 중"
        }
    }

    /// Shown in the UI: host and file name only (no query, no signed path tokens).
    var displaySource: String {
        guard let url = url else { return "플레이어 준비 중 (받을 주소는 아직 확인 전)" }
        let host = url.host ?? ""
        let name = url.lastPathComponent
        let shortName = name.count > 40 ? String(name.prefix(37)) + "…" : name
        return persistableURL(url.absoluteString).redacted || name.isEmpty || name == "/"
            ? host : "\(host) · \(redactPersistedText(shortName))"
    }

    var frameLabel: String { isMainFrame ? "이 페이지" : "포함된 프레임 (\(frameHost))" }
}

enum MediaDiscovery {
    static let worldName = "HttpsDownMedia"
    static let handlerName = "hdMedia"
    static let maxCandidates = 60
    static let maxItemsPerMessage = 60
    static let maxURLLength = 4096

    private static let fileExtensions: Set<String> = ["mp4", "m4v", "mov", "webm", "mkv"]
    private static let imageExtensions: Set<String> = ["gif", "png", "jpg", "jpeg", "webp", "avif", "svg", "bmp", "ico", "heic"]
    private static let adMarkers = ["doubleclick", "googlesyndication", "googleadservices", "adservice", "imasdk",
                                    "adsystem", "adnxs", "taboola", "outbrain", "/ad/", "/ads/", "/vast/"]

    /// Video MIME types trusted for direct main-frame navigations (the response itself is the media).
    static func kind(forMIME mime: String?) -> MediaCandidate.Kind? {
        guard let m = mime?.lowercased() else { return nil }
        if m.contains("mpegurl") { return .hls }
        if m == "application/dash+xml" { return .dash }
        if ["video/mp4", "video/webm", "video/quicktime", "video/x-m4v", "video/x-matroska"].contains(m) { return .file }
        return nil
    }

    /// The discovery script, loaded from the app bundle (or the source tree when run from it). nil = not available.
    static func scriptSource() -> String? {
        var paths: [String] = []
        if let res = Bundle.main.resourceURL?.appendingPathComponent("MediaDiscovery.js").path { paths.append(res) }
        paths.append((FileManager.default.currentDirectoryPath as NSString).appendingPathComponent("Resources/MediaDiscovery.js"))
        for p in paths {
            if let data = FileManager.default.contents(atPath: p), data.count < 64_000,
               let s = String(data: data, encoding: .utf8) { return s }
        }
        return nil
    }

    /// Re-validates one reported address natively (the script is not trusted): http/https only, no images or ad
    /// resources, bounded size, kind re-derived from the address unless it came from a <video> element.
    static func validate(rawURL: String, reportedKind: String, source: String) -> (URL, MediaCandidate.Kind)? {
        guard rawURL.count <= maxURLLength, var comps = URLComponents(string: rawURL),
              let scheme = comps.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = comps.host, !host.isEmpty, comps.user == nil, comps.password == nil else { return nil }
        comps.fragment = nil
        guard let url = comps.url else { return nil }
        let ext = url.pathExtension.lowercased()
        let lower = url.absoluteString.lowercased()
        if imageExtensions.contains(ext) || adMarkers.contains(where: { lower.contains($0) }) { return nil }
        let kind: MediaCandidate.Kind
        let fromElement = source == "element"
        if ext == "m3u8" || (fromElement && reportedKind == "hls") { kind = .hls }
        else if ext == "mpd" || (fromElement && reportedKind == "dash") { kind = .dash }
        else if fileExtensions.contains(ext) || (fromElement && reportedKind == "file") { kind = .file }
        else if fromElement { kind = .element }
        else { return nil }   // resource entries count only with a recognisable media extension
        return (url, kind)
    }

    /// Referer for the bound media request, like a browser's default policy (strict-origin-when-cross-origin):
    /// same origin → page address without fragment/userinfo; cross origin → origin only; https → http → none.
    static func referer(page: URL, media: URL) -> String? {
        guard let ps = page.scheme?.lowercased(), ps == "http" || ps == "https", let ph = page.host,
              let ms = media.scheme?.lowercased(), media.host != nil else { return nil }
        if ps == "https" && ms == "http" { return nil }
        guard var comps = URLComponents(url: page, resolvingAgainstBaseURL: false) else { return nil }
        comps.fragment = nil
        comps.user = nil
        comps.password = nil
        guard let pageClean = comps.string, pageClean != media.absoluteString else { return nil }
        let sameOrigin = ps == ms && ph.lowercased() == media.host?.lowercased() && page.port == media.port
        if sameOrigin { return pageClean.count <= 2048 ? pageClean : nil }
        return "\(ps)://\(ph)" + (page.port.map { ":\($0)" } ?? "") + "/"
    }
}

/// Message endpoint registered only in the isolated discovery world. Holds the model weakly so the user content
/// controller never keeps a closed browser or an old session alive.
@MainActor
final class MediaScriptHandler: NSObject, WKScriptMessageHandler {
    weak var model: LoginBrowserModel?
    let sessionToken: Int

    init(model: LoginBrowserModel, sessionToken: Int) {
        self.model = model
        self.sessionToken = sessionToken
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        model?.receiveMediaMessage(message, sessionToken: sessionToken)
    }
}
