import Foundation
import Combine

/// Which network path a browser view (and the WKWebsiteDataStore behind it) uses.
/// `assist` = the app-only HTTPS connection-assist proxy, `direct` = the system connection.
enum BrowsingRoute: String, Equatable {
    case direct
    case assist

    var label: String { self == .assist ? "연결 도움" : "시스템 연결" }
}

/// A site's explicit choice. "Unset" is the absence of a choice (never stored as a value), so the three states
/// unset / on / off stay distinguishable.
enum SiteRouteChoice: String, Equatable {
    case on
    case off

    var route: BrowsingRoute { self == .on ? .assist : .direct }
}

/// Per-site "HTTPS 연결 도움" for the in-app browser: exact normalized host → on/off, persisted (production only).
///
/// * Exact host only: "a.example.com" never matches "example.com" or "b.a.example.com".
/// * Only public DNS names can carry a choice (the same rule as the proxy's "allow this host" recovery): IP literals,
///   single-label names and local/private suffixes (localhost, .local, .lan, ...) are refused for both on and off, so
///   the proxy's localhost/private policy cannot be reached around, in either direction.
/// * A route a page merely inherited (pop-up from a proxied page, link followed inside a proxied tab) is never written
///   here; only `set(_:forHost:)` from an explicit user action creates a rule.
/// * Isolated runs (`persists == false`) keep rules in memory and never touch UserDefaults.
@MainActor
final class SiteRouteRules: ObservableObject {
    static let defaultsKey = "htd.siteRoute.choices"
    static let maxRules = 500

    enum SetOutcome: Equatable {
        case saved
        case cleared
        case unchanged
        /// Not a public DNS name (IP literal, localhost, local/private suffix, single label, non-ASCII).
        case notRoutable
        case limitReached
    }

    @Published private(set) var choices: [String: SiteRouteChoice]
    private let persists: Bool

    init(persists: Bool) {
        self.persists = persists
        var loaded: [String: SiteRouteChoice] = [:]
        if persists, let stored = UserDefaults.standard.dictionary(forKey: Self.defaultsKey) as? [String: String] {
            for (rawHost, rawChoice) in stored {
                guard let host = Self.normalizedHost(rawHost), Self.isRoutable(host: host),
                      let choice = SiteRouteChoice(rawValue: rawChoice), loaded.count < Self.maxRules else { continue }
                loaded[host] = choice
            }
        }
        self.choices = loaded
    }

    /// Lowercase, trimmed, one trailing dot removed. Nil for anything that is not a plain host name.
    nonisolated static func normalizedHost(_ raw: String?) -> String? {
        guard var host = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !host.isEmpty else { return nil }
        if host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty, host.unicodeScalars.allSatisfy({ $0.isASCII }),
              !host.contains("/"), !host.contains(":"), !host.contains("@"), !host.contains("*"),
              !host.contains(" ") else { return nil }
        return host
    }

    nonisolated static func isRoutable(host: String) -> Bool {
        ConnectionManager.isAllowableHost(host)
    }

    /// Explicit choice for this exact host, nil = unset (and for hosts that can never carry a choice).
    func choice(forHost raw: String?) -> SiteRouteChoice? {
        guard let host = Self.normalizedHost(raw) else { return nil }
        return choices[host]
    }

    /// Sets (on/off) or clears (nil) the explicit choice of one exact host.
    @discardableResult
    func set(_ choice: SiteRouteChoice?, forHost raw: String?) -> SetOutcome {
        guard let host = Self.normalizedHost(raw), Self.isRoutable(host: host) else { return .notRoutable }
        let previous = choices[host]
        guard previous != choice else { return .unchanged }
        guard let choice else {
            choices.removeValue(forKey: host)
            persist()
            return .cleared
        }
        if previous == nil && choices.count >= Self.maxRules { return .limitReached }
        choices[host] = choice
        persist()
        return .saved
    }

    private func persist() {
        guard persists else { return }
        UserDefaults.standard.set(choices.mapValues { $0.rawValue }, forKey: Self.defaultsKey)
    }
}
