import Foundation

/// 컴파일 중간물 증거.
/// DerivedData의 allowlist(ModuleCache, Index, Intermediates 등)만 후보가 되며,
/// Build/Products, 앱 번들(.app), .xcarchive, 백업, 사용자 자료는 isProtectedArtifact=true로 보호된다.
public struct CompileArtifactEvidence: Sendable, Equatable {
    public var path: String
    public var name: String
    public var category: String
    public var modifiedAt: Date?
    public var sizeBytes: UInt64?
    public var filesystemObjectIdentifier: String?
    public var isProtectedArtifact: Bool
    public var parentProjectPath: String?
    public var isSharedCache: Bool

    public init(
        path: String,
        name: String,
        category: String,
        modifiedAt: Date?,
        sizeBytes: UInt64?,
        filesystemObjectIdentifier: String?,
        isProtectedArtifact: Bool,
        parentProjectPath: String? = nil,
        isSharedCache: Bool = false
    ) {
        self.path = path
        self.name = name
        self.category = category
        self.modifiedAt = modifiedAt
        self.sizeBytes = sizeBytes
        self.filesystemObjectIdentifier = filesystemObjectIdentifier
        self.isProtectedArtifact = isProtectedArtifact
        self.parentProjectPath = parentProjectPath
        self.isSharedCache = isSharedCache
    }
}

/// Git 작업 사본(worktree) 증거.
/// 등록 clean + untracked 0 + ignored 재생성 cache 증명 + 다른 ref의 HEAD 보존 + 활성 0 + 명시 완료 증거가
/// 모두 충족되어야 후보가 된다. 하나라도 불명이면 후보에서 제외(보존)된다.
public struct GitWorktreeEvidence: Sendable, Equatable {
    public var path: String
    public var branchName: String?
    public var headCommitHash: String
    public var isRegistered: Bool
    public var isClean: Bool
    public var untrackedCount: Int
    public var hasOnlyRegenerableIgnored: Bool
    public var headIncludedInOtherRef: Bool
    public var activeProcessCount: Int
    public var hasExplicitCompletionEvidence: Bool
    public var modifiedAt: Date?
    public var sizeBytes: UInt64?
    public var filesystemObjectIdentifier: String?

    public init(
        path: String,
        branchName: String?,
        headCommitHash: String,
        isRegistered: Bool,
        isClean: Bool,
        untrackedCount: Int,
        hasOnlyRegenerableIgnored: Bool,
        headIncludedInOtherRef: Bool,
        activeProcessCount: Int,
        hasExplicitCompletionEvidence: Bool,
        modifiedAt: Date?,
        sizeBytes: UInt64?,
        filesystemObjectIdentifier: String?
    ) {
        self.path = path
        self.branchName = branchName
        self.headCommitHash = headCommitHash
        self.isRegistered = isRegistered
        self.isClean = isClean
        self.untrackedCount = untrackedCount
        self.hasOnlyRegenerableIgnored = hasOnlyRegenerableIgnored
        self.headIncludedInOtherRef = headIncludedInOtherRef
        self.activeProcessCount = activeProcessCount
        self.hasExplicitCompletionEvidence = hasExplicitCompletionEvidence
        self.modifiedAt = modifiedAt
        self.sizeBytes = sizeBytes
        self.filesystemObjectIdentifier = filesystemObjectIdentifier
    }

    /// 모든 안전 조건이 완벽히 충족되었는지 검증.
    public var isEligibleForRemoval: Bool {
        isRegistered
            && isClean
            && untrackedCount == 0
            && hasOnlyRegenerableIgnored
            && headIncludedInOtherRef
            && activeProcessCount == 0
            && hasExplicitCompletionEvidence
            && filesystemObjectIdentifier != nil
    }
}

/// 과거 설치 순수 앱 백업 증거.
/// 순수 .app + 서명 유효(codesign --verify) + 현행 앱과 최신 복구본이 별도 존재할 때만 후보가 된다.
/// 소스 포함, 서명 불명, 사용자 자료 혼재, 현행/최신 복구본은 엄격히 보존된다.
public struct LegacyAppBackupEvidence: Sendable, Equatable {
    public var path: String
    public var appName: String
    public var bundleIdentifier: String?
    public var versionString: String?
    public var buildNumber: String?
    public var isPureAppBundle: Bool
    public var isCodeSignatureValid: Bool
    public var hasSeparateActiveApp: Bool
    public var hasSeparateLatestRecoveryApp: Bool
    public var isCurrentActiveOrLatestRecovery: Bool
    public var containsSourceOrUserData: Bool
    public var modifiedAt: Date?
    public var sizeBytes: UInt64?
    public var filesystemObjectIdentifier: String?

    public init(
        path: String,
        appName: String,
        bundleIdentifier: String?,
        versionString: String?,
        buildNumber: String?,
        isPureAppBundle: Bool,
        isCodeSignatureValid: Bool,
        hasSeparateActiveApp: Bool,
        hasSeparateLatestRecoveryApp: Bool,
        isCurrentActiveOrLatestRecovery: Bool,
        containsSourceOrUserData: Bool,
        modifiedAt: Date?,
        sizeBytes: UInt64?,
        filesystemObjectIdentifier: String?
    ) {
        self.path = path
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.versionString = versionString
        self.buildNumber = buildNumber
        self.isPureAppBundle = isPureAppBundle
        self.isCodeSignatureValid = isCodeSignatureValid
        self.hasSeparateActiveApp = hasSeparateActiveApp
        self.hasSeparateLatestRecoveryApp = hasSeparateLatestRecoveryApp
        self.isCurrentActiveOrLatestRecovery = isCurrentActiveOrLatestRecovery
        self.containsSourceOrUserData = containsSourceOrUserData
        self.modifiedAt = modifiedAt
        self.sizeBytes = sizeBytes
        self.filesystemObjectIdentifier = filesystemObjectIdentifier
    }

    public var isEligibleForRemoval: Bool {
        isPureAppBundle
            && isCodeSignatureValid
            && hasSeparateActiveApp
            && hasSeparateLatestRecoveryApp
            && !isCurrentActiveOrLatestRecovery
            && !containsSourceOrUserData
            && filesystemObjectIdentifier != nil
    }
}

/// Homebrew 다운로드 아카이브 증거.
/// 설치본이 실존하는 패키지의 완료된 다운로드 archive만 후보가 되며,
/// 현재 compiler/deps/SDK/runtime/Gradle 9.5는 보존된다.
/// metadata(.json), checksum(.sha256), partial/incomplete(.incomplete, .download)는 엄격히 제외된다.
public struct HomebrewDownloadArchiveEvidence: Sendable, Equatable {
    public var path: String
    public var filename: String
    public var formulaName: String
    public var version: String
    public var isCompleteArchive: Bool
    public var isInstalledInCellar: Bool
    public var isEssentialToolchain: Bool
    public var modifiedAt: Date?
    public var sizeBytes: UInt64?
    public var filesystemObjectIdentifier: String?

    public init(
        path: String,
        filename: String,
        formulaName: String,
        version: String,
        isCompleteArchive: Bool,
        isInstalledInCellar: Bool,
        isEssentialToolchain: Bool,
        modifiedAt: Date?,
        sizeBytes: UInt64?,
        filesystemObjectIdentifier: String?
    ) {
        self.path = path
        self.filename = filename
        self.formulaName = formulaName
        self.version = version
        self.isCompleteArchive = isCompleteArchive
        self.isInstalledInCellar = isInstalledInCellar
        self.isEssentialToolchain = isEssentialToolchain
        self.modifiedAt = modifiedAt
        self.sizeBytes = sizeBytes
        self.filesystemObjectIdentifier = filesystemObjectIdentifier
    }

    public var isEligibleForRemoval: Bool {
        isCompleteArchive
            && isInstalledInCellar
            && !isEssentialToolchain
            && filesystemObjectIdentifier != nil
    }
}

/// 스캔 중 발견되었으나 보존 원칙에 따라 제외된 대상 기록.
public struct PreservedTargetEvidence: Sendable, Equatable {
    public var path: String
    public var targetKind: String
    public var reason: String

    public init(path: String, targetKind: String, reason: String) {
        self.path = path
        self.targetKind = targetKind
        self.reason = reason
    }
}

/// 신규 개발 정리 관측값 묶음.
/// nil은 수집 실패/확인 불가로 간주하여 fail closed 처리(후보 0).
public struct DevelopmentCleanupInput: Sendable, Equatable {
    public var compileArtifactEntries: [CompileArtifactEvidence]?
    public var worktreeEntries: [GitWorktreeEvidence]?
    public var appBackupEntries: [LegacyAppBackupEvidence]?
    public var homebrewArchiveEntries: [HomebrewDownloadArchiveEvidence]?
    public var preservedTargets: [PreservedTargetEvidence]
    public var devProcesses: [ClassifiedProcess]?
    public var now: Date

    public init(
        compileArtifactEntries: [CompileArtifactEvidence]? = nil,
        worktreeEntries: [GitWorktreeEvidence]? = nil,
        appBackupEntries: [LegacyAppBackupEvidence]? = nil,
        homebrewArchiveEntries: [HomebrewDownloadArchiveEvidence]? = nil,
        preservedTargets: [PreservedTargetEvidence] = [],
        devProcesses: [ClassifiedProcess]? = nil,
        now: Date = Date()
    ) {
        self.compileArtifactEntries = compileArtifactEntries
        self.worktreeEntries = worktreeEntries
        self.appBackupEntries = appBackupEntries
        self.homebrewArchiveEntries = homebrewArchiveEntries
        self.preservedTargets = preservedTargets
        self.devProcesses = devProcesses
        self.now = now
    }
}

/// 경로·심볼릭 링크·identity 다중 계층 검증 도구.
public enum DevelopmentCleanupPathValidator {
    /// 대상 경로가 허용 루트 하위에 안전하게 존재하는지 검증한다.
    /// root / realpath / parentlinks / targetlinks / dev:ino 검사.
    public static func validate(
        path: String,
        allowedRoot: URL,
        expectedObjectIdentifier: String?
    ) -> URL? {
        let target = URL(fileURLWithPath: path).standardizedFileURL
        let root = allowedRoot.standardizedFileURL

        // 1. 단순 경로가 허용 루트 하위인지 확인 (디렉터리 구분자 포함 비교로 형제 접두사 탈출 방지 및 루트 자체 제외)
        let rootPathWithSlash = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard target.path.hasPrefix(rootPathWithSlash) else { return nil }

        // 2. 심볼릭 링크 여부 검사 (대상 자체가 링크이면 거부)
        guard let values = try? target.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isSymbolicLink != true else { return nil }

        // 3. realpath 해석 결과도 허용 루트의 realpath 하위인지 검증 (구분자 포함)
        let resolvedTarget = target.resolvingSymlinksInPath()
        let resolvedRoot = root.resolvingSymlinksInPath()
        let resolvedRootWithSlash = resolvedRoot.path.hasSuffix("/") ? resolvedRoot.path : resolvedRoot.path + "/"
        guard resolvedTarget.path.hasPrefix(resolvedRootWithSlash) else {
            return nil
        }

        // 4. identity (dev:ino) 일치 검사
        guard let expectedObjectIdentifier,
              CleanupPathValidator.filesystemObjectIdentifier(at: target) == expectedObjectIdentifier else {
            return nil
        }

        return target
    }
}
