import Foundation

/// 신규 개발 정리 대상 4종(컴파일 중간물, 완료된 Git worktree, 과거 앱 백업, Homebrew 다운로드 아카이브)에 대한
/// 실행기.
///
/// 안전 원칙:
/// 1. 실행 직전 fresh 근거 수집 및 정책 재검증(DevelopmentCleanupPolicy.revalidate) 수행.
/// 2. 승인 시점의 identity(dev:ino), 크기, 수정 시각 및 활성 프로세스를 재확인하여 변경 시 차단(.blocked).
/// 3. worktree: 정상 /usr/bin/git worktree remove만 사용 (--force, branch 삭제, 재귀 삭제, 셸 사용 금지).
/// 4. 파일 대상: FileManager.default.trashItem만 사용 (영구 삭제 폴백 금지, root/realpath/symlink 검증 필수).
/// 5. toolchain/SDK/Gradle/현행 앱/미완료 변경은 보존.
enum DevelopmentCleanupExecutor {

    static func execute(_ candidate: CleanupCandidate) -> CleanupExecutionResult {
        // 1. 신선한 근거 수집 및 정책 재검증
        let freshInput = DevelopmentCleanupCollector.collect(measureSizes: false)
        let validation = DevelopmentCleanupPolicy.revalidate(candidate: candidate, against: freshInput)
        guard validation.isAllowed else {
            return result(candidate, .blocked, validation.koreanReason)
        }

        switch candidate.kind {
        case .compileArtifacts:
            return executeCompileArtifact(candidate, freshInput: freshInput)
        case .completedGitWorktree:
            return executeGitWorktree(candidate, freshInput: freshInput)
        case .legacyAppBackup:
            return executeLegacyAppBackup(candidate, freshInput: freshInput)
        case .homebrewDownloadArchive:
            return executeHomebrewArchive(candidate, freshInput: freshInput)
        default:
            return result(candidate, .blocked, "개발 정리 실행기가 지원하지 않는 대상 종류입니다.")
        }
    }

    // MARK: - 1. 컴파일 중간물 정리

    private static func executeCompileArtifact(
        _ candidate: CleanupCandidate,
        freshInput: DevelopmentCleanupInput
    ) -> CleanupExecutionResult {
        guard let path = candidate.targetPath else {
            return result(candidate, .blocked, "대상 경로가 지정되지 않았습니다.")
        }

        let allowedRoot = CleanupEvidenceCollector.derivedDataRoot
        guard let validatedURL = DevelopmentCleanupPathValidator.validate(
            path: path,
            allowedRoot: allowedRoot,
            expectedObjectIdentifier: candidate.filesystemObjectIdentifier
        ) else {
            return result(candidate, .blocked, "DerivedData 허용 경로 또는 파일 식별자(dev:ino) 검증에 실패했습니다.")
        }

        // 활성 빌드 또는 테스트 프로세스 재확인
        if let processes = freshInput.devProcesses {
            let hasActiveBuildOrTest = processes.contains { p in
                if p.kind == .test { return true }
                guard p.kind == .xcode else { return false }
                let cmd = p.snapshot.command.lowercased()
                return cmd.contains("xcodebuild") || cmd.contains("xcbbuildservice")
                    || cmd.contains("swift-build") || cmd.contains("swift-frontend")
            }
            if hasActiveBuildOrTest {
                return result(candidate, .blocked, "활성 빌드 또는 테스트 프로세스가 실행 중이어서 중간물 정리를 중단했습니다.")
            }
        }

        // 산출물(Products, 앱, .xcarchive) 보호 재확인
        let lowerPath = validatedURL.path.lowercased()
        if lowerPath.contains("/products/") || lowerPath.hasSuffix(".app") || lowerPath.hasSuffix(".xcarchive") {
            return result(candidate, .blocked, "빌드 산출물(Products, 앱, xcarchive)은 보호 대상이므로 정리할 수 없습니다.")
        }

        // 휴지통으로 이동 (영구 삭제 폴백 없음)
        do {
            var trashedURL: NSURL?
            try FileManager.default.trashItem(at: validatedURL, resultingItemURL: &trashedURL)
            return result(
                candidate,
                .cleaned,
                "컴파일 중간물을 휴지통으로 안전하게 이동했습니다. 필요 시 다음 빌드에서 다시 생성됩니다."
            )
        } catch {
            return result(candidate, .failed, "휴지통으로 이동하지 못했습니다: \(error.localizedDescription)")
        }
    }

    // MARK: - 2. 완료된 Git worktree 정리

    private static func executeGitWorktree(
        _ candidate: CleanupCandidate,
        freshInput: DevelopmentCleanupInput
    ) -> CleanupExecutionResult {
        guard let path = candidate.targetPath else {
            return result(candidate, .blocked, "worktree 경로가 지정되지 않았습니다.")
        }

        let targetURL = URL(fileURLWithPath: path).standardizedFileURL

        // 1. 심볼릭 링크 및 파일 식별자 검증
        guard let devIno = CleanupPathValidator.filesystemObjectIdentifier(at: targetURL),
              devIno == candidate.filesystemObjectIdentifier else {
            return result(candidate, .blocked, "worktree 경로가 존재하지 않거나 파일 식별자(dev:ino)가 변경되었습니다.")
        }

        let values = try? targetURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values?.isDirectory == true, values?.isSymbolicLink != true else {
            return result(candidate, .blocked, "worktree 대상이 디렉터리가 아니거나 심볼릭 링크입니다.")
        }

        // 2. 부모 Git 저장소 식별
        guard let parentRepo = DevelopmentCleanupCollector.findParentGitRepository(forWorktreePath: path) else {
            return result(candidate, .blocked, "worktree의 원본 Git 저장소를 찾을 수 없습니다.")
        }

        // 메인 리포지토리 자체 삭제 방지
        if targetURL.path == parentRepo.standardizedFileURL.path {
            return result(candidate, .blocked, "메인 Git 리포지토리 루트는 작업 사본 정리 대상이 될 수 없습니다.")
        }

        // 3. 실행 직전 worktree 등록 및 clean 상태 최종 재확인
        guard let statusOutput = ControlledCommand.run(
            executable: "/usr/bin/git",
            arguments: ["-C", path, "status", "--porcelain=v1"],
            timeout: 10
        ), statusOutput.status == 0 else {
            return result(candidate, .blocked, "worktree 상태 확인에 실패하여 정리를 중단했습니다.")
        }

        let statusText = statusOutput.output
        let lines = statusText.components(separatedBy: .newlines).filter { !$0.isEmpty }
        let hasUntracked = lines.contains { $0.hasPrefix("??") }
        let hasDirty = lines.contains { !$0.hasPrefix("??") && !$0.hasPrefix("!!") }

        guard !hasUntracked && !hasDirty else {
            return result(candidate, .blocked, "worktree에 미추적 파일 또는 변경 사항이 존재하여 정리를 중단했습니다.")
        }

        // 4. 정상 `git worktree remove <path>` 명령으로만 실행 (--force, branch 삭제, rm -rf 금지)
        guard let removeCommand = ControlledCommand.run(
            executable: "/usr/bin/git",
            arguments: ["-C", parentRepo.path, "worktree", "remove", path],
            timeout: 60
        ) else {
            return result(candidate, .failed, "git worktree remove 프로세스를 실행하지 못했습니다.")
        }

        guard removeCommand.status == 0 else {
            let detail = removeCommand.output.trimmingCharacters(in: .whitespacesAndNewlines)
            return result(
                candidate,
                .failed,
                detail.isEmpty ? "git worktree remove 실행 중 오류가 발생했습니다." : detail
            )
        }

        return result(
            candidate,
            .cleaned,
            "완료된 Git 작업 사본을 정상적으로 제거했습니다. 커밋과 브랜치 이력은 Git 저장소에 안전하게 보존됩니다."
        )
    }

    // MARK: - 3. 과거 순수 앱 백업 정리

    private static func executeLegacyAppBackup(
        _ candidate: CleanupCandidate,
        freshInput: DevelopmentCleanupInput
    ) -> CleanupExecutionResult {
        guard let path = candidate.targetPath else {
            return result(candidate, .blocked, "앱 백업 경로가 지정되지 않았습니다.")
        }

        let targetURL = URL(fileURLWithPath: path).standardizedFileURL

        // .app 확장자 확인
        guard targetURL.pathExtension == "app" else {
            return result(candidate, .blocked, ".app 번들이 아니어서 정리를 중단했습니다.")
        }

        // 심볼릭 링크 및 식별자 확인
        guard let devIno = CleanupPathValidator.filesystemObjectIdentifier(at: targetURL),
              devIno == candidate.filesystemObjectIdentifier else {
            return result(candidate, .blocked, "앱 번들 파일 식별자(dev:ino)가 변경되어 정리를 중단했습니다.")
        }

        let values = try? targetURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values?.isDirectory == true, values?.isSymbolicLink != true else {
            return result(candidate, .blocked, "앱 번들이 디렉터리가 아니거나 심볼릭 링크입니다.")
        }

        // 코드 서명 유효성 재확인
        guard let codesignResult = ControlledCommand.run(
            executable: "/usr/bin/codesign",
            arguments: ["--verify", "--deep", "--strict", path],
            timeout: 20
        ), codesignResult.status == 0 else {
            return result(candidate, .blocked, "코드 서명이 유효하지 않거나 검증에 실패하여 정리를 중단했습니다.")
        }

        // 소스 코드 또는 사용자 데이터 포함 여부 재확인
        if checkForSourceOrUserData(url: targetURL) {
            return result(candidate, .blocked, "앱 번들 내부에서 소스 코드 또는 사용자 데이터가 발견되어 보존을 위해 중단했습니다.")
        }

        // 휴지통으로 이동 (영구 삭제 폴백 없음)
        do {
            var trashedURL: NSURL?
            try FileManager.default.trashItem(at: targetURL, resultingItemURL: &trashedURL)
            return result(
                candidate,
                .cleaned,
                "과거 설치 백업 앱을 휴지통으로 이동했습니다. 필요 시 Finder 휴지통에서 복원할 수 있습니다."
            )
        } catch {
            return result(candidate, .failed, "휴지통으로 이동하지 못했습니다: \(error.localizedDescription)")
        }
    }

    // MARK: - 4. Homebrew 다운로드 아카이브 정리

    private static func executeHomebrewArchive(
        _ candidate: CleanupCandidate,
        freshInput: DevelopmentCleanupInput
    ) -> CleanupExecutionResult {
        guard let path = candidate.targetPath else {
            return result(candidate, .blocked, "아카이브 경로가 지정되지 않았습니다.")
        }

        let allowedRoot = DevelopmentCleanupCollector.homebrewDownloadsRoot
        guard let validatedURL = DevelopmentCleanupPathValidator.validate(
            path: path,
            allowedRoot: allowedRoot,
            expectedObjectIdentifier: candidate.filesystemObjectIdentifier
        ) else {
            return result(candidate, .blocked, "Homebrew 다운로드 폴더 또는 파일 식별자(dev:ino) 검증에 실패했습니다.")
        }

        let filename = validatedURL.lastPathComponent

        // 메타데이터, 체크섬, 불완전 다운로드 제외 재확인
        if filename.hasSuffix(".json") || filename.hasSuffix(".sha256") ||
            filename.hasSuffix(".incomplete") || filename.hasSuffix(".download") ||
            filename.hasSuffix(".crdownload") {
            return result(candidate, .blocked, "메타데이터 또는 불완전한 다운로드 파일은 정리 대상이 아닙니다.")
        }

        // 휴지통으로 이동 (영구 삭제 폴백 없음)
        do {
            var trashedURL: NSURL?
            try FileManager.default.trashItem(at: validatedURL, resultingItemURL: &trashedURL)
            return result(
                candidate,
                .cleaned,
                "Homebrew 다운로드 아카이브를 휴지통으로 이동했습니다. 설치본은 시스템에 유지되며 필요 시 다시 다운로드됩니다."
            )
        } catch {
            return result(candidate, .failed, "휴지통으로 이동하지 못했습니다: \(error.localizedDescription)")
        }
    }

    private static func checkForSourceOrUserData(url: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return false }

        let forbiddenExtensions: Set<String> = ["swift", "c", "m", "h", "cpp", "java", "kt", "git"]
        for case let fileURL as URL in enumerator {
            if forbiddenExtensions.contains(fileURL.pathExtension.lowercased()) {
                return true
            }
        }
        return false
    }

    private static func result(
        _ candidate: CleanupCandidate,
        _ status: CleanupExecutionStatus,
        _ message: String
    ) -> CleanupExecutionResult {
        CleanupExecutionResult(candidate: candidate, status: status, message: message)
    }
}
