import Foundation

public enum CCMBPaths {
    public static let appSupportURL: URL = {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("HTT")
            .appendingPathComponent("CCMB")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }()

    public static let diagnosticsDirectoryURL: URL = {
        let url = appSupportURL.appendingPathComponent("diagnostics")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }()

    public static let snapshotURL: URL = {
        appSupportURL.appendingPathComponent("usage-v1.json")
    }()
}

public final class CCMBPreferences: @unchecked Sendable {
    public static let shared = CCMBPreferences()

    public static let suiteName = "com.hanstree.htt.ccmb"
    private static let legacySuiteName = "com.codex.creditmenubar"

    public let defaults: UserDefaults

    public init(defaults: UserDefaults = UserDefaults(suiteName: suiteName) ?? .standard) {
        self.defaults = defaults
        migrateVisualPreferencesOnce()
    }

    /// Copies only visual preferences (theme, opacity, pinned scale) from legacy CCMB domain once if not set,
    /// leaving the legacy domain unchanged. Does NOT migrate enabling or sharing flags.
    private func migrateVisualPreferencesOnce() {
        guard !defaults.bool(forKey: "didMigrateVisualPreferencesV1") else { return }
        defaults.set(true, forKey: "didMigrateVisualPreferencesV1")
        guard let legacy = UserDefaults(suiteName: Self.legacySuiteName) else { return }

        let visualKeys = [
            "usagePanelThemeV1",
            "usagePanelTheme",
            "usagePanelOpacity",
            "panelOpacity",
            "pinnedUsagePanelContentScaleV2"
        ]
        for key in visualKeys {
            if defaults.object(forKey: key) == nil, let value = legacy.object(forKey: key) {
                defaults.set(value, forKey: key)
            }
        }
    }

    public var serverTarget: String {
        get { defaults.string(forKey: "serverTarget") ?? "" }
        set { defaults.set(newValue, forKey: "serverTarget") }
    }

    public var dataCollectionSource: String {
        get { defaults.string(forKey: "dataCollectionSourcePreference") ?? "nas" }
        set { defaults.set(newValue, forKey: "dataCollectionSourcePreference") }
    }

    public static let nasServiceCacheDefaultsKey = "nasFourServiceCacheV1"
    public static let nasHistoryV2DefaultsKey = "nasConsumptionHistoryV2"

    public func clearNASCaches() {
        defaults.removeObject(forKey: Self.nasServiceCacheDefaultsKey)
        defaults.removeObject(forKey: Self.nasHistoryV2DefaultsKey)
        NASHTTPClient.shared.clearSessionCache()
    }
}
