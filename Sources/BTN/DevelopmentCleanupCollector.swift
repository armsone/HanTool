import Foundation

/// 신규 개발 저장공간 정리(컴파일 중간물, 완료된 Git worktree, 과거 앱 백업, Homebrew 다운로드 아카이브)에 대한
/// 정밀 증거 수집기.
///
/// BoundedCommandRunner(/usr/bin/git, /usr/bin/codesign, /usr/bin/du)와 FileManager만 사용하며
/// 셸 문자열을 사용하지 않는다. 수집 실패는 nil 또는 보존 플래그로 남아 정책이 안전하게 거부(fail closed)하도록 한다.
public enum DevelopmentCleanupCollector {

    public static let homebrewDownloadsRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/Homebrew/downloads", isDirectory: true)

    public static let homebrewCellarRoot = URL(fileURLWithPath: "/opt/homebrew/Cellar", isDirectory: true)
    public static let homebrewIntelCellarRoot = URL(fileURLWithPath: "/usr/local/Cellar", isDirectory: true)

    public static let derivedDataRoot = CleanupEvidenceCollector.derivedDataRoot

    /// 필수 보존해야 하는 툴체인/런타임 식별자 키워드 (Homebrew 및 SDK 보존용).
    public static let essentialToolchainKeywords: Set<String> = [
        "llvm", "clang", "swift", "rust", "go", "python", "node", "openjdk",
        "java", "gradle", "kotlin", "ruby", "perl", "gcc", "binutils", "cmake"
    ]

    /// 컴파일 중간물 allowlist 디렉터리 이름 (소문자).
    public static let compileArtifactAllowlistNames: Set<String> = [
        "modulecache", "modulecache.noindex",
        "index.noindex", "compilationcache", "compilationcache.noindex",
        "intermediates.noindex", "symbolcache", "symbolcache.noindex",
        "sdkstatcaches", "sdkstatcaches.noindex"
    ]

    public static var defaultGitRepositories: [URL] {
        let gitDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("git", isDirectory: true)
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: gitDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return items.filter { item in
            FileManager.default.fileExists(atPath: item.appendingPathComponent(".git").path)
        }
    }

    public static var defaultAppBackupRoots: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent("Backups", isDirectory: true),
            home.appendingPathComponent("Downloads", isDirectory: true),
            home.appendingPathComponent("Desktop", isDirectory: true)
        ]
        return candidates.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    public static func findParentGitRepository(forWorktreePath path: String) -> URL? {
        guard let result = ReadOnlyCommand.run(
            executable: "/usr/bin/git",
            arguments: ["-C", path, "rev-parse", "--git-common-dir"],
            timeout: 10
        ), result.status == 0,
              let text = String(data: result.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        let commonDirURL = URL(fileURLWithPath: text, relativeTo: URL(fileURLWithPath: path)).standardizedFileURL
        if commonDirURL.lastPathComponent == ".git" {
            return commonDirURL.deletingLastPathComponent()
        }
        return commonDirURL
    }

    /// 전체 증거를 수집하여 정책 입력(DevelopmentCleanupInput)을 생성한다.
    public static func collect(
        gitRepositories: [URL] = [],
        appBackupRoots: [URL] = [],
        measureSizes: Bool = true
    ) -> DevelopmentCleanupInput {
        let devProcesses = ProcessCollector.collectOptional().map(ProcessClassifier.classifyAll)

        var preservedTargets: [PreservedTargetEvidence] = []
        let effectiveRepos = gitRepositories.isEmpty ? defaultGitRepositories : gitRepositories
        let effectiveBackups = appBackupRoots.isEmpty ? defaultAppBackupRoots : appBackupRoots

        // 1. 컴파일 중간물 증거 수집
        let compileEntries = collectCompileArtifacts(at: derivedDataRoot, preserved: &preservedTargets)

        // 2. Git worktree 증거 수집
        let worktreeEntries = collectGitWorktrees(
            repositories: effectiveRepos,
            devProcesses: devProcesses,
            preserved: &preservedTargets
        )

        // 3. 앱 백업 증거 수집
        let appBackupEntries = collectAppBackups(roots: effectiveBackups, preserved: &preservedTargets)

        // 4. Homebrew 다운로드 아카이브 수집
        let brewEntries = collectHomebrewArchives(preserved: &preservedTargets)

        // 5. AVD / QuickBoot / unavailable 기기 보존 기록
        recordEmulatorPreservation(preserved: &preservedTargets)

        var input = DevelopmentCleanupInput(
            compileArtifactEntries: compileEntries,
            worktreeEntries: worktreeEntries,
            appBackupEntries: appBackupEntries,
            homebrewArchiveEntries: brewEntries,
            preservedTargets: preservedTargets,
            devProcesses: devProcesses,
            now: Date()
        )

        guard measureSizes else { return input }

        // 정책 통과 후보의 정확한 크기 측정 (du -sk)
        measureCandidateSizes(&input)

        return input
    }

    // MARK: - 1. 컴파일 중간물 수집

    private static func collectCompileArtifacts(
        at root: URL,
        preserved: inout [PreservedTargetEvidence]
    ) -> [CompileArtifactEvidence]? {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        guard let directChildren = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var results: [CompileArtifactEvidence] = []

        for item in directChildren {
            let lowerName = item.lastPathComponent.lowercased()
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey])

            // 심볼릭 링크는 무조건 제외
            guard values?.isSymbolicLink != true else {
                preserved.append(PreservedTargetEvidence(path: item.path, targetKind: "CompileArtifact", reason: "심볼릭 링크는 대상에서 제외"))
                continue
            }

            // A. 최상위 공유 캐시 (ModuleCache, Index.noindex 등)
            if compileArtifactAllowlistNames.contains(lowerName) {
                let devIno = CleanupPathValidator.filesystemObjectIdentifier(at: item)
                results.append(CompileArtifactEvidence(
                    path: item.standardizedFileURL.path,
                    name: item.lastPathComponent,
                    category: "공유 컴파일 캐시",
                    modifiedAt: values?.contentModificationDate,
                    sizeBytes: nil,
                    filesystemObjectIdentifier: devIno,
                    isProtectedArtifact: false,
                    parentProjectPath: nil,
                    isSharedCache: true
                ))
                continue
            }

            // B. 개별 프로젝트 폴더 내부의 중간물 탐색
            guard values?.isDirectory == true else { continue }
            inspectProjectIntermediates(projectURL: item, results: &results, preserved: &preserved)
        }

        return results
    }

    private static func inspectProjectIntermediates(
        projectURL: URL,
        results: inout [CompileArtifactEvidence],
        preserved: inout [PreservedTargetEvidence]
    ) {
        // 프로젝트 하위에서 Intermediates.noindex, Index.noindex 등 allowlist 대상만 검색
        guard let projectChildren = try? FileManager.default.contentsOfDirectory(
            at: projectURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for child in projectChildren {
            let childName = child.lastPathComponent.lowercased()

            // Build/Products 폴더나 앱, xcarchive는 절대 중간물 후보가 되지 않음
            if childName == "build" {
                let productsURL = child.appendingPathComponent("Products")
                if FileManager.default.fileExists(atPath: productsURL.path) {
                    preserved.append(PreservedTargetEvidence(
                        path: productsURL.path,
                        targetKind: "BuildProducts",
                        reason: "빌드 산출물(Products)은 보호 대상"
                    ))
                }
                let intermediatesURL = child.appendingPathComponent("Intermediates.noindex")
                if FileManager.default.fileExists(atPath: intermediatesURL.path) {
                    let devIno = CleanupPathValidator.filesystemObjectIdentifier(at: intermediatesURL)
                    let modDate = (try? intermediatesURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                    results.append(CompileArtifactEvidence(
                        path: intermediatesURL.standardizedFileURL.path,
                        name: "Intermediates.noindex",
                        category: "빌드 중간물",
                        modifiedAt: modDate,
                        sizeBytes: nil,
                        filesystemObjectIdentifier: devIno,
                        isProtectedArtifact: false,
                        parentProjectPath: projectURL.path,
                        isSharedCache: false
                    ))
                }
            } else if compileArtifactAllowlistNames.contains(childName) {
                let devIno = CleanupPathValidator.filesystemObjectIdentifier(at: child)
                let modDate = (try? child.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                results.append(CompileArtifactEvidence(
                    path: child.standardizedFileURL.path,
                    name: child.lastPathComponent,
                    category: "프로젝트 인덱스/캐시",
                    modifiedAt: modDate,
                    sizeBytes: nil,
                    filesystemObjectIdentifier: devIno,
                    isProtectedArtifact: false,
                    parentProjectPath: projectURL.path,
                    isSharedCache: false
                ))
            }
        }
    }

    // MARK: - 2. Git worktree 수집

    private static func collectGitWorktrees(
        repositories: [URL],
        devProcesses: [ClassifiedProcess]?,
        preserved: inout [PreservedTargetEvidence]
    ) -> [GitWorktreeEvidence]? {
        guard !repositories.isEmpty else { return [] }

        var results: [GitWorktreeEvidence] = []

        for repo in repositories {
            guard let worktreeOutput = ReadOnlyCommand.run(
                executable: "/usr/bin/git",
                arguments: ["-C", repo.path, "worktree", "list", "--porcelain"],
                timeout: 15
            ), worktreeOutput.status == 0,
                  let text = String(data: worktreeOutput.data, encoding: .utf8) else {
                continue
            }

            let blocks = text.components(separatedBy: "\n\n")
            for block in blocks where !block.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard let evidence = parseWorktreeBlock(
                    block: block,
                    repo: repo,
                    devProcesses: devProcesses,
                    preserved: &preserved
                ) else {
                    continue
                }
                results.append(evidence)
            }
        }

        return results
    }

    private static func parseWorktreeBlock(
        block: String,
        repo: URL,
        devProcesses: [ClassifiedProcess]?,
        preserved: inout [PreservedTargetEvidence]
    ) -> GitWorktreeEvidence? {
        var path: String?
        var headCommit: String?
        var branchRef: String?

        for line in block.components(separatedBy: .newlines) {
            if line.hasPrefix("worktree ") {
                path = String(line.dropFirst(9))
            } else if line.hasPrefix("HEAD ") {
                headCommit = String(line.dropFirst(5))
            } else if line.hasPrefix("branch ") {
                branchRef = String(line.dropFirst(7))
            }
        }

        guard let wtPath = path, let commit = headCommit else { return nil }
        let wtURL = URL(fileURLWithPath: wtPath)

        // 메인 리포지토리 루트 자체는 worktree 삭제 후보가 될 수 없음
        if wtURL.standardizedFileURL.path == repo.standardizedFileURL.path {
            return nil
        }

        // branch 이름 정규화: refs/heads/ prefix 제거
        let normalizedBranch: String?
        if let ref = branchRef {
            if ref.hasPrefix("refs/heads/") {
                normalizedBranch = String(ref.dropFirst(11))
            } else {
                normalizedBranch = ref
            }
        } else {
            normalizedBranch = nil
        }

        // status 확인: 일반 dirty 및 untracked 확인
        guard let statusOutput = ReadOnlyCommand.run(
            executable: "/usr/bin/git",
            arguments: ["-C", wtPath, "status", "--porcelain=v1"],
            timeout: 10
        ), statusOutput.status == 0,
              let statusText = String(data: statusOutput.data, encoding: .utf8) else {
            preserved.append(PreservedTargetEvidence(path: wtPath, targetKind: "Worktree", reason: "git status 수집 실패"))
            return nil
        }

        let lines = statusText.components(separatedBy: .newlines).filter { !$0.isEmpty }
        let untracked = lines.filter { $0.hasPrefix("??") }.count
        let dirty = lines.filter { !$0.hasPrefix("??") && !$0.hasPrefix("!!") }.count > 0

        // ignored 파일 검증: status --porcelain=v1 --ignored 로 확인
        let hasOnlyRegenerableIgnored = checkIgnoredArtifacts(wtPath: wtPath)

        // HEAD 커밋이 현재 branch 외 다른 지속 ref에 포함되어 있는지 확인
        let headInOtherRef = isHeadContainedInOtherRef(repo: repo, headCommit: commit, currentBranch: normalizedBranch)

        // worktree 경로 하위에서 실행 중인 프로세스 확인 (cwd 또는 명령행 경로)
        let activeProcessCount = countActiveProcessesInWorktree(wtPath: wtPath, devProcesses: devProcesses)

        let devIno = CleanupPathValidator.filesystemObjectIdentifier(at: wtURL)
        let modDate = (try? wtURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate

        // 명시적 완료 증거: clean, untracked == 0, HEAD 다른 ref 보존, 활성 프로세스 0, regenerable ignored 확인
        let hasExplicitCompletionEvidence = headInOtherRef && !dirty && untracked == 0 && (activeProcessCount == 0) && hasOnlyRegenerableIgnored

        return GitWorktreeEvidence(
            path: wtPath,
            branchName: normalizedBranch,
            headCommitHash: commit,
            isRegistered: true,
            isClean: !dirty,
            untrackedCount: untracked,
            hasOnlyRegenerableIgnored: hasOnlyRegenerableIgnored,
            headIncludedInOtherRef: headInOtherRef,
            activeProcessCount: activeProcessCount,
            hasExplicitCompletionEvidence: hasExplicitCompletionEvidence,
            modifiedAt: modDate,
            sizeBytes: nil,
            filesystemObjectIdentifier: devIno
        )
    }

    private static func checkIgnoredArtifacts(wtPath: String) -> Bool {
        guard let result = ReadOnlyCommand.run(
            executable: "/usr/bin/git",
            arguments: ["-C", wtPath, "status", "--porcelain=v1", "--ignored"],
            timeout: 10
        ), result.status == 0,
              let text = String(data: result.data, encoding: .utf8) else {
            return false
        }
        let ignoredLines = text.components(separatedBy: .newlines)
            .filter { $0.hasPrefix("!! ") }
            .map { String($0.dropFirst(3)).trimmingCharacters(in: .whitespaces) }

        // ignored 파일이 없으면 재생성 문제 없음 (true)
        if ignoredLines.isEmpty { return true }

        // 재생성 가능한 알려진 캐시/중간물 디렉터리 및 확장자 확인
        let regenerablePrefixes = [
            ".build/", "build/", "DerivedData/", "node_modules/", "Pods/",
            "target/", ".gradle/"
        ]
        let regenerableExtensions: Set<String> = [
            "o", "a", "dylib", "so", "class", "pyc", "swp", "DS_Store"
        ]

        for item in ignoredLines {
            let matchesPrefix = regenerablePrefixes.contains { item.hasPrefix($0) }
            let ext = URL(fileURLWithPath: item).pathExtension.lowercased()
            let matchesExt = regenerableExtensions.contains(ext)
            if !matchesPrefix && !matchesExt {
                return false
            }
        }
        return true
    }

    private static func countActiveProcessesInWorktree(
        wtPath: String,
        devProcesses: [ClassifiedProcess]?
    ) -> Int {
        let standardizedWt = URL(fileURLWithPath: wtPath).standardizedFileURL.path

        // 판정 불가(프로세스 수집 실패, lsof 실패/timeout/오류)는 활성 1로 두어 보존한다.
        guard let processes = devProcesses else { return 1 }

        // devProcesses에서 명령행이나 인자에 worktree 경로를 포함하는 프로세스 검사
        var count = processes.filter { $0.snapshot.command.contains(standardizedWt) }.count

        // lsof를 통해 해당 worktree 디렉터리 내 열린 파일/cwd를 사용하는 프로세스 조회 (읽기 전용, timeout 5초)
        // lsof는 열린 파일이 없으면 출력 없이 status 1을 반환하지만 권한 거부/오류도 status 1일 수 있다.
        // stderr를 stdout과 합쳐 받아, 합친 출력이 완전히 비어 있는 status 1만 정상 비활동 0으로 인정한다.
        guard let lsofResult = BoundedCommandRunner.run(
            executable: "/usr/sbin/lsof",
            arguments: ["-t", "+D", standardizedWt],
            timeout: 5,
            includeStandardError: true
        ), let text = String(data: lsofResult.data, encoding: .utf8) else { return max(count, 1) }

        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let pids = lines.filter { line in line.allSatisfy { $0.isASCII && $0.isNumber } }
        // PID가 아닌 줄(경고, 권한 거부, 오류 메시지)은 조회가 불완전하다는 뜻이므로 보존한다.
        let hasNonPidOutput = pids.count != lines.count

        switch lsofResult.status {
        case 0 where !pids.isEmpty && !hasNonPidOutput:
            count += pids.count
        case 1 where lines.isEmpty:
            break
        default:
            return max(count + pids.count, 1)
        }

        return count
    }

    private static func isHeadContainedInOtherRef(
        repo: URL,
        headCommit: String,
        currentBranch: String?
    ) -> Bool {
        guard let result = ReadOnlyCommand.run(
            executable: "/usr/bin/git",
            arguments: ["-C", repo.path, "branch", "--contains", headCommit],
            timeout: 10
        ), result.status == 0,
              let text = String(data: result.data, encoding: .utf8) else {
            return false
        }
        // git branch --contains 출력: "* branch1", "+ branch2", "  branch3", "(HEAD detached at ...)"
        let branches = text.components(separatedBy: .newlines)
            .map { line -> String in
                var trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                    trimmed = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                }
                return trimmed
            }
            .filter { !$0.isEmpty && !$0.hasPrefix("(") } // detached 헤드 표시 등 제외

        // 현재 브랜치 외에 다른 지속 브랜치에도 커밋이 남아있는지 정확 일치(!=)로 확인
        let otherBranches = branches.filter { branch in
            guard let current = currentBranch else {
                // detached HEAD: 다른 유효 지속 branch가 없으면 안전하게 false(보존)
                return true
            }
            return branch != current
        }
        return !otherBranches.isEmpty
    }

    // MARK: - 3. 앱 백업 수집

    private static func collectAppBackups(
        roots: [URL],
        preserved: inout [PreservedTargetEvidence]
    ) -> [LegacyAppBackupEvidence]? {
        guard !roots.isEmpty else { return [] }
        var candidates: [AppBackupCandidate] = []
        var seenPaths = Set<String>()

        for root in roots {
            guard let items = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for item in items where item.pathExtension == "app" {
                guard seenPaths.insert(item.standardizedFileURL.path).inserted,
                      let candidate = inspectAppBackup(url: item, preserved: &preserved) else { continue }
                candidates.append(candidate)
            }
        }

        // 같은 bundleID 그룹에서 서명이 유효하고 version/build가 모두 확인되는 사본만 비교 기준이 된다.
        // 최고 version/build 사본(동률 포함)과 version/build 미확인 사본은 서로를 근거로 삭제될 수 없게 보호한다.
        var results: [LegacyAppBackupEvidence] = []
        for candidate in candidates {
            let group = candidates.filter { $0.bundleID == candidate.bundleID }
            let known = group.filter { $0.versionKey != nil }
            let isUnknown = candidate.versionKey == nil
            let hasNewerSignedCopy = !isUnknown && known.contains { other in
                other.path != candidate.path && isVersionKeyNewer(other.versionKey!, than: candidate.versionKey!)
            }
            let isLatestOrUnknown = !hasNewerSignedCopy

            let path = candidate.path
            let hasSeparateActiveApp = candidate.activeAppURL != nil
                && candidate.activeAppURL?.standardizedFileURL.path != path
            let isInstalledCopy = candidate.activeAppURL?.standardizedFileURL.path == path
            let isCurrentActiveOrLatestRecovery = isInstalledCopy || isLatestOrUnknown

            if !hasSeparateActiveApp || !hasNewerSignedCopy || isCurrentActiveOrLatestRecovery {
                preserved.append(PreservedTargetEvidence(
                    path: path,
                    targetKind: "AppBackup",
                    reason: "현행 설치본 부재, 더 높은 서명 복구본 부재, 최신/동률/버전 미확인 (active=\(hasSeparateActiveApp), newerRecovery=\(hasNewerSignedCopy), protected=\(isCurrentActiveOrLatestRecovery))"
                ))
            }

            results.append(LegacyAppBackupEvidence(
                path: path,
                appName: candidate.url.deletingPathExtension().lastPathComponent,
                bundleIdentifier: candidate.bundleID,
                versionString: candidate.shortVersion ?? candidate.build,
                buildNumber: candidate.build,
                isPureAppBundle: true,
                isCodeSignatureValid: true,
                hasSeparateActiveApp: hasSeparateActiveApp,
                hasSeparateLatestRecoveryApp: hasNewerSignedCopy,
                isCurrentActiveOrLatestRecovery: isCurrentActiveOrLatestRecovery,
                containsSourceOrUserData: false,
                modifiedAt: (try? candidate.url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                sizeBytes: nil,
                filesystemObjectIdentifier: CleanupPathValidator.filesystemObjectIdentifier(at: candidate.url)
            ))
        }
        return results
    }

    private struct AppBackupCandidate {
        let url: URL
        let path: String
        let bundleID: String
        let shortVersion: String?
        let build: String?
        let activeAppURL: URL?

        /// version과 build가 모두 있어야 비교 가능. 하나라도 없으면 미확인(보존).
        var versionKey: (version: String, build: String)? {
            guard let shortVersion, let build, !shortVersion.isEmpty, !build.isEmpty else { return nil }
            return (shortVersion, build)
        }
    }

    private static func isVersionKeyNewer(
        _ lhs: (version: String, build: String),
        than rhs: (version: String, build: String)
    ) -> Bool {
        let versionOrder = lhs.version.compare(rhs.version, options: .numeric)
        if versionOrder != .orderedSame { return versionOrder == .orderedDescending }
        return lhs.build.compare(rhs.build, options: .numeric) == .orderedDescending
    }

    private static func inspectAppBackup(
        url: URL,
        preserved: inout [PreservedTargetEvidence]
    ) -> AppBackupCandidate? {
        let path = url.standardizedFileURL.path

        // 서명 검증
        guard let codesignResult = ReadOnlyCommand.run(
            executable: "/usr/bin/codesign",
            arguments: ["--verify", "--deep", "--strict", path],
            timeout: 20
        ), codesignResult.status == 0 else {
            preserved.append(PreservedTargetEvidence(path: path, targetKind: "AppBackup", reason: "코드 서명 검증 실패 또는 서명 없음"))
            return nil
        }

        // 소스 파일이나 임의의 사용자 자료가 번들 안에 혼재되어 있는지 확인
        let hasSourceOrUserData = checkForSourceOrUserData(url: url)
        if hasSourceOrUserData {
            preserved.append(PreservedTargetEvidence(path: path, targetKind: "AppBackup", reason: "소스 코드 또는 사용자 데이터 포함"))
            return nil
        }

        // Info.plist 파싱하여 bundleIdentifier, versionString, buildNumber 추출
        let plistURL = url.appendingPathComponent("Contents/Info.plist")
        guard FileManager.default.fileExists(atPath: plistURL.path),
              let plistData = try? Data(contentsOf: plistURL),
              let plistObj = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
              let bundleID = plistObj["CFBundleIdentifier"] as? String,
              !bundleID.isEmpty else {
            preserved.append(PreservedTargetEvidence(path: path, targetKind: "AppBackup", reason: "CFBundleIdentifier 조회 실패 또는 없음"))
            return nil
        }

        // /Applications 및 /System/Applications 에서 동일 bundle ID를 가진 현행 설치 앱 확인
        return AppBackupCandidate(
            url: url,
            path: path,
            bundleID: bundleID,
            shortVersion: plistObj["CFBundleShortVersionString"] as? String,
            build: plistObj["CFBundleVersion"] as? String,
            activeAppURL: findActiveInstalledApp(bundleIdentifier: bundleID)
        )
    }

    private static func findActiveInstalledApp(bundleIdentifier: String) -> URL? {
        let appDirs = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        ]

        for appDir in appDirs {
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: appDir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for item in contents where item.pathExtension == "app" {
                let infoPlist = item.appendingPathComponent("Contents/Info.plist")
                guard let data = try? Data(contentsOf: infoPlist),
                      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                      let bid = plist["CFBundleIdentifier"] as? String,
                      bid == bundleIdentifier else { continue }
                return item
            }
        }
        return nil
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

    // MARK: - 4. Homebrew 아카이브 수집

    private static func collectHomebrewArchives(
        preserved: inout [PreservedTargetEvidence]
    ) -> [HomebrewDownloadArchiveEvidence]? {
        let root = homebrewDownloadsRoot
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var results: [HomebrewDownloadArchiveEvidence] = []

        for item in children {
            let filename = item.lastPathComponent

            // metadata, checksum, incomplete/partial 파일은 엄격히 제외
            if filename.hasSuffix(".json") || filename.hasSuffix(".sha256") ||
                filename.hasSuffix(".incomplete") || filename.hasSuffix(".download") ||
                filename.hasSuffix(".crdownload") {
                preserved.append(PreservedTargetEvidence(
                    path: item.path,
                    targetKind: "HomebrewDownload",
                    reason: "메타데이터 또는 불완전한 다운로드 파일은 제외"
                ))
                continue
            }

            // 파일명에서 패키지 이름 추출 파싱 (예: formula--version.bottle.tar.gz 또는 formula-version)
            let parsed = parseFormulaNameAndVersion(from: filename)
            let formulaName = parsed.formula
            let version = parsed.version

            // 필수 툴체인/런타임 검사 (보존 대상)
            let isToolchain = isToolchainPackage(formulaName: formulaName)
            if isToolchain {
                preserved.append(PreservedTargetEvidence(
                    path: item.path,
                    targetKind: "HomebrewDownload",
                    reason: "핵심 개발 툴체인/런타임(\(formulaName)) 아카이브는 보존"
                ))
            }

            // Cellar에 실제 설치본이 존재하는지 확인
            let isInstalled = checkCellarInstallation(formulaName: formulaName)

            let devIno = CleanupPathValidator.filesystemObjectIdentifier(at: item)
            let modDate = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate

            results.append(HomebrewDownloadArchiveEvidence(
                path: item.standardizedFileURL.path,
                filename: filename,
                formulaName: formulaName,
                version: version,
                isCompleteArchive: true,
                isInstalledInCellar: isInstalled,
                isEssentialToolchain: isToolchain,
                modifiedAt: modDate,
                sizeBytes: nil,
                filesystemObjectIdentifier: devIno
            ))
        }

        return results
    }

    private static func parseFormulaNameAndVersion(from filename: String) -> (formula: String, version: String) {
        let parts = filename.components(separatedBy: "--")
        if parts.count >= 2 {
            let formula = parts[0]
            let rest = parts[1]
            return (formula, rest)
        }
        return (filename, "unknown")
    }

    private static func isToolchainPackage(formulaName: String) -> Bool {
        let lower = formulaName.lowercased()
        return essentialToolchainKeywords.contains { lower.contains($0) }
    }

    private static func checkCellarInstallation(formulaName: String) -> Bool {
        let optURL = homebrewCellarRoot.appendingPathComponent(formulaName)
        if FileManager.default.fileExists(atPath: optURL.path) { return true }
        let intelURL = homebrewIntelCellarRoot.appendingPathComponent(formulaName)
        return FileManager.default.fileExists(atPath: intelURL.path)
    }

    // MARK: - 5. AVD / QuickBoot / unavailable 기기 보존

    private static func recordEmulatorPreservation(preserved: inout [PreservedTargetEvidence]) {
        preserved.append(PreservedTargetEvidence(
            path: "Android AVD userdata / QuickBoot",
            targetKind: "AndroidEmulator",
            reason: "신규 개발 스캔 보존 원칙: AVD userdata, 암호화 상태, SD카드, QuickBoot 스냅샷은 기본 보존"
        ))
        preserved.append(PreservedTargetEvidence(
            path: "CoreSimulator unavailable iOS devices",
            targetKind: "iOSSimulator",
            reason: "신규 개발 스캔 보존 원칙: 런타임 미설치 기기는 기본 보존 (기존 명시 수동 정리 기능만 유지)"
        ))
    }

    // MARK: - 크기 측정

    private static func measureCandidateSizes(_ input: inout DevelopmentCleanupInput) {
        let candidates = DevelopmentCleanupPolicy.propose(input)
        let paths = Set(candidates.compactMap { $0.targetPath })
        guard !paths.isEmpty else { return }

        var sizes: [String: UInt64] = [:]
        for path in paths {
            sizes[path] = measurePathBytes(path: path)
        }

        if let compiles = input.compileArtifactEntries {
            input.compileArtifactEntries = compiles.map { entry in
                var u = entry
                if let s = sizes[entry.path] { u.sizeBytes = s }
                return u
            }
        }
        if let worktrees = input.worktreeEntries {
            input.worktreeEntries = worktrees.map { entry in
                var u = entry
                if let s = sizes[entry.path] { u.sizeBytes = s }
                return u
            }
        }
        if let backups = input.appBackupEntries {
            input.appBackupEntries = backups.map { entry in
                var u = entry
                if let s = sizes[entry.path] { u.sizeBytes = s }
                return u
            }
        }
        if let archives = input.homebrewArchiveEntries {
            input.homebrewArchiveEntries = archives.map { entry in
                var u = entry
                if let s = sizes[entry.path] { u.sizeBytes = s }
                return u
            }
        }
    }

    private static func measurePathBytes(path: String) -> UInt64 {
        guard let result = ReadOnlyCommand.run(
            executable: "/usr/bin/du",
            arguments: ["-sk", path],
            timeout: 30
        ), result.status == 0,
              let output = String(data: result.data, encoding: .utf8),
              let kilobytes = UInt64(output.split(whereSeparator: \.isWhitespace).first ?? "")
        else { return 0 }
        return kilobytes * 1024
    }
}
