import Foundation

/// 신규 개발 정리 대상 4종에 대한 결정적 정리 정책.
/// 입력(Evidence)을 받아 후보(CleanupCandidate) 목록을 제안하며, 어떤 삭제나 실행도 하지 않는 순수 함수이다.
/// 보존 원칙:
/// - compile 중간물: ModuleCache, Index, Intermediates류 allowlist만. Build/Products, 앱, .xcarchive, 백업, 사용자 자료 제외. 활성 빌드/테스트 시 전면 제외.
/// - worktree: 등록 clean + untracked 0 + ignored 재생성 cache + 다른 ref에 HEAD 보존 + 활성 0 + 명시 완료 증거 필수.
/// - 순수 app 백업: 순수 .app + 서명 유효 + 현행 앱 및 최신 복구본 별도 존재 필수. 현행/복구본 보존.
/// - brew archive: 패키지 설치본 실존하는 완료 archive만. compiler/deps/SDK/runtime/Gradle 9.5 보존.
/// - AVD/userdata/QuickBoot/unavailable iOS: 신규 스캔에서는 기본 보존(후보로 제안하지 않음).
public enum DevelopmentCleanupPolicy {

    public static func propose(_ input: DevelopmentCleanupInput) -> [CleanupCandidate] {
        var candidates: [CleanupCandidate] = []
        candidates.append(contentsOf: compileArtifactCandidates(input))
        candidates.append(contentsOf: worktreeCandidates(input))
        candidates.append(contentsOf: legacyAppBackupCandidates(input))
        candidates.append(contentsOf: homebrewArchiveCandidates(input))

        return candidates.sorted { lhs, rhs in
            if lhs.kind != rhs.kind { return lhs.kind.rawValue < rhs.kind.rawValue }
            return lhs.id < rhs.id
        }
    }

    // MARK: - 1. 전용 compile 중간물 (Xcode)

    private static func compileArtifactCandidates(_ input: DevelopmentCleanupInput) -> [CleanupCandidate] {
        guard let entries = input.compileArtifactEntries else { return [] }
        // 빌드 활동 여부를 모르거나(nil) 빌드·테스트 프로세스가 살아 있으면 전부 제외 (fail closed).
        guard let processes = input.devProcesses else { return [] }
        guard !processes.contains(where: isActiveBuildOrTest) else { return [] }

        return entries.compactMap { entry in
            guard !entry.isProtectedArtifact,
                  entry.filesystemObjectIdentifier != nil else { return nil }

            return CleanupCandidate(
                id: "dev-compile:\(entry.path)",
                kind: .compileArtifacts,
                targetIdentifier: entry.name,
                targetPath: entry.path,
                koreanReason: "Xcode 전용 컴파일 중간물 '\(entry.name)'(\(entry.category))입니다. "
                    + "빌드 산출물(Products, 앱, xcarchive) 및 소스는 안전하게 보존되며, "
                    + "삭제해도 다음 빌드 시 필요하면 다시 생성됩니다.",
                estimatedBytes: entry.sizeBytes ?? 0,
                risk: .low,
                isRecoverable: true,
                recoveryMethod: .userTrash,
                filesystemObjectIdentifier: entry.filesystemObjectIdentifier
            )
        }
    }

    private static func isActiveBuildOrTest(_ process: ClassifiedProcess) -> Bool {
        if process.kind == .test { return true }
        guard process.kind == .xcode else { return false }
        let command = process.snapshot.command.lowercased()
        return command.contains("xcodebuild")
            || command.contains("xcbbuildservice")
            || command.contains("swift-build")
            || command.contains("swift-frontend")
    }

    // MARK: - 2. 작업 사본 (Git worktree)

    private static func worktreeCandidates(_ input: DevelopmentCleanupInput) -> [CleanupCandidate] {
        guard let entries = input.worktreeEntries else { return [] }

        return entries.compactMap { entry in
            // worktree 등록 clean + untracked 0 + ignored 재생성 cache + 다른 ref에 HEAD 보존 + 활성 0 + 명시 완료 증거 필수
            guard entry.isEligibleForRemoval else { return nil }

            let shortCommit = String(entry.headCommitHash.prefix(7))
            let branchDesc = entry.branchName.map { "브랜치 '\($0)'" } ?? "커밋 \(shortCommit)"

            return CleanupCandidate(
                id: "git-worktree:\(entry.path)",
                kind: .completedGitWorktree,
                targetIdentifier: URL(fileURLWithPath: entry.path).lastPathComponent,
                targetPath: entry.path,
                koreanReason: "완료 증거가 확인된 작업 사본(\(branchDesc))입니다. "
                    + "커밋(\(shortCommit))과 Git 이력은 다른 ref에 온전히 보존되어 있으며 "
                    + "미추적 파일과 실행 중인 작업이 없습니다. 정상 git worktree remove로 안전하게 제거합니다.",
                estimatedBytes: entry.sizeBytes ?? 0,
                risk: .medium,
                isRecoverable: true,
                recoveryMethod: .recreatable,
                filesystemObjectIdentifier: entry.filesystemObjectIdentifier
            )
        }
    }

    // MARK: - 3. 과거 설치 순수 앱 백업

    private static func legacyAppBackupCandidates(_ input: DevelopmentCleanupInput) -> [CleanupCandidate] {
        guard let entries = input.appBackupEntries else { return [] }

        return entries.compactMap { entry in
            // 순수 .app + 서명 유효 + 현행 앱/최신 복구본 별도 보존 + 소스/사용자자료 없음 필수
            guard entry.isEligibleForRemoval else { return nil }

            let versionDesc = entry.versionString.map { "v\($0)" } ?? entry.appName
            return CleanupCandidate(
                id: "legacy-app:\(entry.path)",
                kind: .legacyAppBackup,
                targetIdentifier: entry.appName,
                targetPath: entry.path,
                koreanReason: "과거 설치 백업 앱 '\(versionDesc)'입니다. "
                    + "코드 서명이 유효하며 현행 설치 앱과 최신 롤백 복구본이 별도로 보존되어 있습니다. "
                    + "휴지통으로 안전하게 이동합니다.",
                estimatedBytes: entry.sizeBytes ?? 0,
                risk: .medium,
                isRecoverable: true,
                recoveryMethod: .userTrash,
                filesystemObjectIdentifier: entry.filesystemObjectIdentifier
            )
        }
    }

    // MARK: - 4. Homebrew 다운로드 아카이브

    private static func homebrewArchiveCandidates(_ input: DevelopmentCleanupInput) -> [CleanupCandidate] {
        guard let entries = input.homebrewArchiveEntries else { return [] }

        return entries.compactMap { entry in
            // 설치본 실존하는 완료 archive만. metadata/partial/toolchain 제외
            guard entry.isEligibleForRemoval else { return nil }

            return CleanupCandidate(
                id: "brew-archive:\(entry.filename)",
                kind: .homebrewDownloadArchive,
                targetIdentifier: entry.filename,
                targetPath: entry.path,
                koreanReason: "현재 시스템(Cellar)에 정상 설치되어 있는 패키지 '\(entry.formulaName)'의 다운로드 아카이브입니다. "
                    + "설치본과 런타임은 그대로 유지되며, 재설치할 때만 다시 다운로드됩니다. "
                    + "휴지통으로 안전하게 이동합니다.",
                estimatedBytes: entry.sizeBytes ?? 0,
                risk: .low,
                isRecoverable: true,
                recoveryMethod: .userTrash,
                filesystemObjectIdentifier: entry.filesystemObjectIdentifier
            )
        }
    }

    // MARK: - 직전 재검증

    public static func revalidate(
        candidate: CleanupCandidate,
        against freshInput: DevelopmentCleanupInput
    ) -> CleanupRevalidationResult {
        let fresh = propose(freshInput)
        guard let match = fresh.first(where: { $0.id == candidate.id }) else {
            return CleanupRevalidationResult(
                isAllowed: false,
                koreanReason: "최신 확인 결과 개발 정리 안전 조건이 더 이상 충족되지 않아 정리를 중단했습니다."
            )
        }
        guard match.kind == candidate.kind,
              match.targetIdentifier == candidate.targetIdentifier,
              match.targetPath == candidate.targetPath,
              match.filesystemObjectIdentifier == candidate.filesystemObjectIdentifier
        else {
            return CleanupRevalidationResult(
                isAllowed: false,
                koreanReason: "정리 대상 식별자 또는 파일 시스템 identity(dev:ino)가 승인 시점과 달라져 중단했습니다."
            )
        }
        return CleanupRevalidationResult(
            isAllowed: true,
            koreanReason: "최신 확인 결과 안전 조건과 identity가 그대로 유지되고 있습니다."
        )
    }
}
