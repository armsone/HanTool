import Foundation
import Combine

/// Manages persistent exact-site allowlist for automatic popups (window.open without user gesture).
///
/// Follows HTD security rules:
/// - Accepts pasted URL or hostname.
/// - Validates and normalizes HTTP(S) host (lowercase, trimmed, ASCII/punycode, no empty or wildcard or regex).
/// - Exact matching: "aagag.com" does NOT match "sub.aagag.com".
/// - Persistent via UserDefaults (htd.popupAllowlist.hosts), initially empty (no pre-authorized entries).
public final class PopupSitePermissions: ObservableObject {
    public static let shared = PopupSitePermissions()

    public static let storageKey = "htd.popupAllowlist.hosts"

    @Published public private(set) var allowedHosts: [String] = []

    public init() {
        load()
    }

    public func load() {
        let stored = UserDefaults.standard.stringArray(forKey: Self.storageKey) ?? []
        // Clean and ensure unique sorted
        var valid: [String] = []
        for raw in stored {
            if let host = Self.normalizeHost(raw), !valid.contains(host) {
                valid.append(host)
            }
        }
        valid.sort()
        self.allowedHosts = valid
    }

    private func persist() {
        UserDefaults.standard.set(allowedHosts, forKey: Self.storageKey)
    }

    /// Normalizes input string (URL or hostname) into an exact HTTP(S) host.
    /// Rejects non-HTTP(S) schemes, ambiguous schemes, path-only, ports (or strips standard/handles ports),
    /// IP addresses or wildcards/regex patterns if ambiguous.
    /// Returns nil if invalid or ambiguous.
    public static func normalizeHost(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Disallow wildcard or path traversal characters in raw input
        if trimmed.contains("*") || trimmed.contains("?") || trimmed.contains(" ") {
            return nil
        }

        var candidate = trimmed
        // If scheme is present, check scheme
        if let colonIndex = candidate.firstIndex(of: ":") {
            let scheme = String(candidate[..<colonIndex]).lowercased()
            if scheme == "http" || scheme == "https" {
                // Must start with http:// or https://
                guard candidate.lowercased().hasPrefix("http://") || candidate.lowercased().hasPrefix("https://") else {
                    return nil
                }
            } else {
                // Unsupported scheme (e.g. javascript:, ftp:, data:, file:)
                return nil
            }
        } else {
            // No scheme provided: prepend https:// to parse host via URLComponents
            candidate = "https://" + candidate
        }

        guard let components = URLComponents(string: candidate),
              let rawHost = components.host,
              !rawHost.isEmpty else {
            return nil
        }

        // Host validation
        let host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !host.isEmpty else { return nil }

        // Disallow characters not permitted in hostnames
        if host.contains("/") || host.contains("\\") || host.contains("@") || host.contains(":") {
            return nil
        }

        // Check for valid hostname characters (standard ASCII domain characters or punycode)
        // Must contain valid DNS characters
        let allowedCharSet = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-._")
        guard CharacterSet(charactersIn: host).isSubset(of: allowedCharSet) else {
            return nil
        }

        // Cannot start or end with dot or hyphen
        if host.hasPrefix(".") || host.hasSuffix(".") || host.hasPrefix("-") || host.hasSuffix("-") {
            return nil
        }

        // Must contain at least one dot or be localhost (require a dot or valid host to avoid ambiguous single-word entries)
        if !host.contains(".") && host != "localhost" {
            return nil
        }

        // Labels cannot be empty (no consecutive dots)
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        for label in labels {
            if label.isEmpty || label.hasPrefix("-") || label.hasSuffix("-") {
                return nil
            }
        }

        return host
    }

    /// Attempts to add a site to the allowlist.
    /// Returns true if successfully normalized and added (or already present), false if invalid.
    @discardableResult
    public func add(input: String) -> (success: Bool, normalizedHost: String?) {
        guard let host = Self.normalizeHost(input) else {
            return (false, nil)
        }
        if !allowedHosts.contains(host) {
            allowedHosts.append(host)
            allowedHosts.sort()
            persist()
        }
        return (true, host)
    }

    /// Removes an exact host from the allowlist.
    public func remove(host: String) {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let idx = allowedHosts.firstIndex(of: normalized) {
            allowedHosts.remove(at: idx)
            persist()
        }
    }

    /// Exact matching test: returns true if `host` is in the allowed list.
    /// Subdomains are NOT automatically allowed unless explicitly in the list.
    public func isAllowed(host: String?) -> Bool {
        guard let raw = host else { return false }
        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !clean.isEmpty else { return false }
        return allowedHosts.contains(clean)
    }

    /// Checks if a top-level URL is permitted to trigger automatic popups.
    public func isAllowed(url: URL?) -> Bool {
        guard let url = url, let host = url.host else { return false }
        return isAllowed(host: host)
    }
}
