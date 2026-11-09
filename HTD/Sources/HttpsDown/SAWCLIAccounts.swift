// Sources/HttpsDown/SAWCLIAccounts.swift
import Foundation
import Darwin
import CryptoKit

public struct SAWCLIAccount: Identifiable, Equatable {
    public let id: String
    public let providerID: String // "chatgpt", "claude", "gemini"
    public let label: String      // e.g. "Codex 1", "Claude 2", "Gemini 3"
    public let profileHome: String
    public let principalKey: String
    public let lockPaths: [String]
    public let isDefault: Bool

    public func environment(base: [String: String]) -> [String: String] {
        var env = base
        let scrub = [
            "OPENAI_API_KEY", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN",
            "CLAUDE_CODE_OAUTH_TOKEN", "GOOGLE_API_KEY", "GEMINI_API_KEY",
            "CODEX_HOME", "CLAUDE_CONFIG_DIR", "GEMINI_HOME"
        ]
        for key in scrub { env.removeValue(forKey: key) }

        switch providerID {
        case "chatgpt":
            env["CODEX_HOME"] = profileHome
        case "claude":
            if !isDefault { env["CLAUDE_CONFIG_DIR"] = profileHome }
        case "gemini":
            if profileHome != NSHomeDirectory() {
                env["HOME"] = profileHome
            }
        default:
            break
        }

        var path = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let standardUserDirs = ["~/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"].map {
            ($0 as NSString).expandingTildeInPath
        }
        for dir in standardUserDirs where !path.contains(dir) {
            path = "\(dir):\(path)"
        }
        env["PATH"] = path
        return env
    }
}

public enum SAWCLIFailureKind: String {
    case cancelled
    case busy
    case authentication
    case rateLimit
    case policy
    case invalidOutput
    case runtime
}

public final class SAWCLIAccountLease {
    public let fileDescriptors: [Int32]
    private var isReleased = false
    private let lock = NSLock()

    public init(fileDescriptors: [Int32]) {
        self.fileDescriptors = fileDescriptors
    }

    public func release() {
        lock.lock()
        defer { lock.unlock() }
        guard !isReleased else { return }
        isReleased = true
        for fd in fileDescriptors {
            close(fd)
        }
    }

    deinit {
        release()
    }
}

public enum SAWCLIAccounts {
    public static func classify(exitCode: Int32?, cancelled: Bool, timedOut: Bool, text: String) -> SAWCLIFailureKind {
        if cancelled { return .cancelled }
        let lower = text.lowercased()
        if exitCode == 75 || lower.contains("account_busy") || lower.contains("profile_busy") {
            return .busy
        }
        let typedQuotaPatterns = [
            "\\busage_limit_reached\\b",
            "\\binsufficient_quota\\b",
            "\\bquota_exceeded\\b",
            "\\bmodel_capacity_exhausted\\b"
        ]
        var hasTypedQuota = false
        for pattern in typedQuotaPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
               regex.firstMatch(in: lower, options: [], range: NSRange(location: 0, length: lower.utf16.count)) != nil {
                hasTypedQuota = true
                break
            }
        }
        if hasTypedQuota {
            return .rateLimit
        }
        if lower.contains("403") || lower.contains("permission_denied") || lower.contains("policy") || lower.contains("refusal") {
            return .policy
        }
        if lower.contains("authentication required") || lower.contains("not authenticated") || lower.contains("auth_error") || lower.contains("401") || lower.contains("not logged in") || lower.contains("please login") || lower.contains("authentication_required") || lower.contains("unauthenticated") || lower.contains("invalid_grant") || lower.contains("login required") {
            return .authentication
        }
        if lower.contains("429") || lower.contains("rate_limit") || lower.contains("rate limit") || lower.contains("usage limit") || lower.contains("quota exhausted") || lower.contains("resource_exhausted") {
            return .rateLimit
        }
        if lower.contains("invalid_json") || lower.contains("schema_violation") || lower.contains("invalid json") {
            return .invalidOutput
        }
        if timedOut || (exitCode != nil && exitCode != 0) || lower.contains("timeout") || lower.contains("runtime") {
            return .runtime
        }
        return .runtime
    }

    public static func acquire(_ account: SAWCLIAccount) -> SAWCLIAccountLease? {
        var opened: [Int32] = []
        let appSupportLocks = (("~/Library/Application Support/HttpsDown/CLIAccountLocks") as NSString).expandingTildeInPath
        let wrapperLocks = (("~/.local/state/gemini-accounts/locks") as NSString).expandingTildeInPath

        for path in account.lockPaths {
            let parent = (path as NSString).deletingLastPathComponent
            if parent == appSupportLocks {
                try? FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                guard canonicalOwnedDir(path: parent, require0700: true) != nil else { return nil }
            } else if parent == wrapperLocks {
                var st = stat()
                guard lstat(parent, &st) == 0,
                      (st.st_mode & S_IFMT) == S_IFDIR,
                      st.st_uid == getuid(),
                      (st.st_mode & 0o077) == 0 else {
                    cleanup(opened)
                    return nil
                }
            } else {
                cleanup(opened)
                return nil
            }

            let fd = open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else {
                cleanup(opened)
                return nil
            }

            var st = stat()
            guard fstat(fd, &st) == 0,
                  st.st_uid == getuid(),
                  (st.st_mode & S_IFMT) == S_IFREG,
                  st.st_nlink == 1,
                  (st.st_mode & 0o077) == 0 else {
                close(fd)
                cleanup(opened)
                return nil
            }

            if flock(fd, LOCK_EX | LOCK_NB) != 0 {
                close(fd)
                cleanup(opened)
                return nil
            }
            opened.append(fd)
        }
        return SAWCLIAccountLease(fileDescriptors: opened)
    }

    public static func discover(providerID: String) -> [SAWCLIAccount] {
        var results: [SAWCLIAccount] = []
        let fm = FileManager.default
        let appSupportLocks = (("~/Library/Application Support/HttpsDown/CLIAccountLocks") as NSString).expandingTildeInPath
        let wrapperLocks = (("~/.local/state/gemini-accounts/locks") as NSString).expandingTildeInPath

        switch providerID {
        case "chatgpt":
            let nodePaths = ["/opt/homebrew/opt/node/bin/node", "/usr/local/opt/node/bin/node", "/usr/local/bin/node"]
            let scriptPaths = ["/opt/homebrew/lib/node_modules/@openai/codex/bin/codex.js", "/usr/local/lib/node_modules/@openai/codex/bin/codex.js"]
            let hasNode = nodePaths.contains { fm.isExecutableFile(atPath: $0) }
            let hasScript = scriptPaths.contains { fm.fileExists(atPath: $0) }
            if hasNode && hasScript {
                let defaultHome = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? (("~/.codex" as NSString).expandingTildeInPath)
                if let canonical = canonicalOwnedDir(path: defaultHome) {
                    let principal = "chatgpt:unverified"
                    let lock = "\(appSupportLocks)/chatgpt-\(sha256Hex(principal).prefix(24)).lock"
                    results.append(SAWCLIAccount(
                        id: "codex-default",
                        providerID: "chatgpt",
                        label: "Codex 1",
                        profileHome: canonical,
                        principalKey: principal,
                        lockPaths: [lock],
                        isDefault: true
                    ))
                }
            }
            discoverPrepared(provider: "codex", appProvider: "chatgpt", results: &results)

        case "claude":
            let claudeBin = (("~/.local/bin/claude") as NSString).expandingTildeInPath
            if fm.isExecutableFile(atPath: claudeBin) {
                let defaultHome = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] ?? (("~/.claude" as NSString).expandingTildeInPath)
                if let canonical = canonicalOwnedDir(path: defaultHome) {
                    let principal = "claude:unverified"
                    let lock = "\(appSupportLocks)/claude-\(sha256Hex(principal).prefix(24)).lock"
                    results.append(SAWCLIAccount(
                        id: "claude-default",
                        providerID: "claude",
                        label: "Claude 1",
                        profileHome: canonical,
                        principalKey: principal,
                        lockPaths: [lock],
                        isDefault: true
                    ))
                }
            }
            discoverPrepared(provider: "claude", appProvider: "claude", results: &results)

        case "gemini":
            let configPath = (("~/.local/state/gemini-accounts/config.json") as NSString).expandingTildeInPath
            if let data = safeMetadata(path: configPath),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let hostID = json["host_id"] as? String,
               let accountsV3 = json["accounts_v3"] as? [String: Any],
               let list = accountsV3["accounts"] as? [[String: Any]],
               let workers = json["workers"] as? [String: [String: Any]] {
                var seenWorkers = Set<String>()
                let profilesRoot = (("~/.local/share/gemini-profiles") as NSString).expandingTildeInPath
                for acc in list {
                    guard let id = acc["id"] as? String,
                          let numStr = id.hasPrefix("account") ? String(id.dropFirst("account".count)) : nil,
                          let num = Int(numStr), (1...99).contains(num), id == "account\(num)",
                          (acc["enabled"] as? Bool) == true,
                          let workerRef = acc["worker_ref"] as? String,
                          let worker = workers[workerRef],
                          !seenWorkers.contains(workerRef) else { continue }

                    let kind = worker["kind"] as? String ?? ""
                    let rawHome = (worker["home"] as? String ?? "") as NSString
                    let expandedHome = rawHome.expandingTildeInPath
                    let resolvedHome: String?
                    if kind == "native" {
                        resolvedHome = (expandedHome == NSHomeDirectory()) ? canonicalOwnedDir(path: expandedHome) : nil
                    } else if kind == "mac-folder" {
                        resolvedHome = canonicalOwnedDir(path: expandedHome, allowedPrefix: profilesRoot, require0700: true)
                    } else {
                        resolvedHome = nil
                    }
                    guard let home = resolvedHome else { continue }
                    seenWorkers.insert(workerRef)

                    let principal: String
                    if let emailHash = acc["email_sha256"] as? String, isHex64(emailHash) {
                        principal = "gemini:\(emailHash)"
                    } else {
                        principal = "gemini:unverified"
                    }

                    let credHash = String(sha256Hex("\(hostID)\0\(workerRef)").prefix(24))
                    let execHash = String(sha256Hex(id).prefix(24))
                    let localLock = "\(appSupportLocks)/gemini-\(sha256Hex(principal).prefix(24)).lock"
                    let locks = [
                        localLock,
                        "\(wrapperLocks)/cred-\(credHash).lock",
                        "\(wrapperLocks)/account-execution-\(execHash).lock"
                    ]
                    let isDef = (id == "account1" || workerRef == "native")
                    results.append(SAWCLIAccount(
                        id: id,
                        providerID: "gemini",
                        label: "Gemini \(num)",
                        profileHome: home,
                        principalKey: principal,
                        lockPaths: locks,
                        isDefault: isDef
                    ))
                }
            } else {
                let agyBin = (("~/.local/bin/agy") as NSString).expandingTildeInPath
                if fm.isExecutableFile(atPath: agyBin),
                   let canonical = canonicalOwnedDir(path: NSHomeDirectory()) {
                    let principal = "gemini:unverified"
                    let lock = "\(appSupportLocks)/gemini-\(sha256Hex(principal).prefix(24)).lock"
                    results.append(SAWCLIAccount(
                        id: "account1",
                        providerID: "gemini",
                        label: "Gemini 1",
                        profileHome: canonical,
                        principalKey: principal,
                        lockPaths: [lock],
                        isDefault: true
                    ))
                }
            }
        default:
            break
        }

        var unique: [SAWCLIAccount] = []
        var seenHomes = Set<String>()
        var seenKnownPrincipals = Set<String>()
        for acc in results {
            guard !seenHomes.contains(acc.profileHome) else { continue }
            if !acc.principalKey.hasSuffix(":unverified") {
                guard !seenKnownPrincipals.contains(acc.principalKey) else { continue }
                seenKnownPrincipals.insert(acc.principalKey)
            }
            seenHomes.insert(acc.profileHome)
            unique.append(acc)
        }
        return unique
    }

    private static func discoverPrepared(provider: String, appProvider: String, results: inout [SAWCLIAccount]) {
        let prepPath = (("~/.local/state/gemini-accounts/prepared-accounts.json") as NSString).expandingTildeInPath
        guard let data = safeMetadata(path: prepPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["accounts"] as? [[String: Any]] else { return }

        let appSupportLocks = (("~/Library/Application Support/HttpsDown/CLIAccountLocks") as NSString).expandingTildeInPath
        let wrapperLocks = (("~/.local/state/gemini-accounts/locks") as NSString).expandingTildeInPath
        let rootPrefix = (("~/.local/share/\(provider)-profiles") as NSString).expandingTildeInPath

        for acc in list {
            guard (acc["provider"] as? String) == provider,
                  let id = acc["id"] as? String,
                  let numStr = id.hasPrefix(provider) ? String(id.dropFirst(provider.count)) : nil,
                  let num = Int(numStr), (2...99).contains(num), id == "\(provider)\(num)",
                  let rawHome = acc["home"] as? String else { continue }

            let expectedPath = "\(rootPrefix)/\(id)"
            let expandedHome = (rawHome as NSString).expandingTildeInPath
            guard expandedHome == expectedPath,
                  let canonical = canonicalOwnedDir(path: expandedHome, allowedPrefix: rootPrefix, require0700: true) else { continue }

            let principal: String
            if let ver = acc["verification"] as? [String: Any],
               let idSha = ver["identity_sha256"] as? String,
               isHex64(idSha) {
                principal = "\(appProvider):\(idSha)"
            } else {
                principal = "\(appProvider):unverified"
            }

            let pHash = String(sha256Hex(principal).prefix(24))
            let localLock = "\(appSupportLocks)/\(appProvider)-\(pHash).lock"
            let locks = [
                localLock,
                "\(wrapperLocks)/provider-\(id).lock",
                "\(wrapperLocks)/\(provider)-principal-\(pHash).lock"
            ]
            let label = (provider == "codex" ? "Codex" : "Claude") + " \(num)"
            results.append(SAWCLIAccount(
                id: id,
                providerID: appProvider,
                label: label,
                profileHome: canonical,
                principalKey: principal,
                lockPaths: locks,
                isDefault: false
            ))
        }
    }

    private static func cleanup(_ fds: [Int32]) {
        for fd in fds {
            flock(fd, LOCK_UN)
            close(fd)
        }
    }

    private static func sha256Hex(_ string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func isHex64(_ s: String) -> Bool {
        s.count == 64 && s.allSatisfy { $0.isHexDigit }
    }

    private static func safeMetadata(path: String) -> Data? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFREG,
              st.st_uid == getuid(),
              st.st_nlink == 1,
              st.st_size >= 0,
              st.st_size <= 1024 * 1024 else { return nil }
        let size = Int(st.st_size)
        if size == 0 { return Data() }
        var data = Data(count: size)
        let bytesRead = data.withUnsafeMutableBytes { buf in
            read(fd, buf.baseAddress, size)
        }
        guard bytesRead == size else { return nil }
        return data
    }

    private static func canonicalOwnedDir(path: String, allowedPrefix: String? = nil, require0700: Bool = false) -> String? {
        guard let real = realpath(path, nil) else { return nil }
        defer { free(real) }
        let canonical = String(cString: real)
        let standardized = (path as NSString).standardizingPath
        guard standardized == canonical else { return nil }
        if let prefix = allowedPrefix {
            guard let realPrefix = realpath(prefix, nil) else { return nil }
            defer { free(realPrefix) }
            let canonicalPrefix = String(cString: realPrefix)
            guard canonical == canonicalPrefix || canonical.hasPrefix(canonicalPrefix + "/") else { return nil }
        }
        var st = stat()
        guard lstat(canonical, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFDIR,
              st.st_uid == getuid() else { return nil }
        if require0700 && (st.st_mode & 0o077) != 0 { return nil }
        return canonical
    }
}

