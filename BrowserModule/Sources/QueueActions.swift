import Foundation
import AppKit
import Darwin

@MainActor
extension AppModel {

    // MARK: - Eligibility Checkers

    public var canBulkClear: Bool {
        jobs.contains { $0.state != .completed && $0.state != .completedWithSubtitleFailure }
    }

    public var canBulkClearHistory: Bool {
        jobs.contains { $0.state == .completed || $0.state == .completedWithSubtitleFailure }
    }

    public var canBulkRetry: Bool {
        jobs.contains { isRetryEligibleState($0.state) }
    }

    public var canBulkOpenInBrowser: Bool {
        jobs.contains { isRetryEligibleState($0.state) }
    }

    /// Finite (non-live) VOD jobs waiting for selection whose current selection already yields a valid download spec.
    /// Same checks as the per-item "다운로드 시작" button; live/recording intent is never included.
    /// Stays clickable while any finite waiting job exists so the click can explain why nothing started.
    public var canBulkStartReady: Bool {
        jobs.contains { isBulkStartCandidate($0) }
    }

    /// Shared per-item/bulk/backend guard: a redacted or invalid stored source can never be re-downloaded.
    func hasUsableSourceForStart(_ job: JobRecord) -> Bool {
        !job.urlWasRedacted && isValidRuntimeSourceURL(job.sourceURL)
    }

    // MARK: - Bulk Actions

    /// Starts every ready, finite VOD job through the existing per-item confirm path.
    /// IDs are snapshotted first; processQueue is pumped once afterwards (maxConcurrentJobs still applies).
    public func bulkStartReady() {
        let candidates = jobs.filter { isBulkStartCandidate($0) }
        let staleCount = candidates.filter { !hasUsableSourceForStart($0) }.count
        let targetIds = candidates.filter { isBulkStartReady($0) }.map(\.id)
        let unselectedCount = candidates.count - staleCount - targetIds.count
        var reasons: [String] = []
        if staleCount > 0 { reasons.append("원본 주소 재입력 필요 \(staleCount)개") }
        if unselectedCount > 0 { reasons.append("화질/음원 선택 필요 \(unselectedCount)개") }
        guard !targetIds.isEmpty else {
            setDropFeedback("시작할 수 있는 작업이 없습니다. (" + reasons.joined(separator: ", ") + ")")
            return
        }

        performQueueBatch {
            for id in targetIds {
                // Re-validate against the live record: the job may have changed since the snapshot.
                guard let job = jobs.first(where: { $0.id == id }), isBulkStartReady(job) else { continue }
                confirmSelectionAndDownload(jobId: id)
            }
        }

        let startedCount = targetIds.filter { id in
            jobs.first(where: { $0.id == id })?.state != .awaitingSelection
        }.count
        let skippedCount = targetIds.count - startedCount
        if skippedCount > 0 { reasons.append("상태 변경 \(skippedCount)개") }
        if !reasons.isEmpty {
            setDropFeedback("\(startedCount)개 작업을 다운로드 대기열에 넣었습니다. (제외: " + reasons.joined(separator: ", ") + ")")
        } else {
            setDropFeedback("\(startedCount)개 작업을 다운로드 대기열에 넣었습니다.")
        }
    }

    /// Explicit "링크 붙여넣기" click only: reads the general pasteboard once (URL objects, else plain string),
    /// validates through URLDropValidator and hands the result to the normal analysis pipeline.
    /// The typed address field is left untouched and clipboard content is never echoed or logged.
    public func pasteLinksFromClipboard() {
        let pasteboard = NSPasteboard.general
        var raw: [String] = []
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            for url in urls.prefix(URLDropValidator.maxDropURLs) {
                if let valid = URLDropValidator.validateSingleURL(url.absoluteString) {
                    raw.append(valid)
                }
            }
        }
        if raw.isEmpty, let text = pasteboard.string(forType: .string) {
            raw = URLDropValidator.parseCandidateText(text)
        }

        var seen = Set<String>()
        var unique: [String] = []
        for url in raw where seen.insert(url).inserted {
            unique.append(url)
            if unique.count >= URLDropValidator.maxDropURLs { break }
        }

        guard !unique.isEmpty else {
            setDropFeedback("클립보드에 붙여넣을 수 있는 웹 주소(http/https)가 없습니다.")
            return
        }
        let added = addJobs(from: unique)
        if added == 0 {
            setDropFeedback("클립보드의 주소를 추가하지 못했습니다.")
        }
    }

    /// Deletes all jobs in the queue except completed jobs.
    /// Preserves publisher cancellation and process cleanup via deleteJob.
    public func bulkClearQueue() {
        let targetJobs = jobs.filter {
            $0.state != .completed && $0.state != .completedWithSubtitleFailure
        }
        let targetIds = targetJobs.map(\.id)
        guard !targetIds.isEmpty else {
            setDropFeedback("삭제할 대기열 작업이 없습니다.")
            return
        }

        performQueueBatch {
            for id in targetIds {
                deleteJob(jobId: id, removeFile: false, suppressAlert: true)
            }
        }

        let remainingIds = Set(jobs.map(\.id))
        let skippedCount = targetIds.filter { remainingIds.contains($0) }.count
        let deletedCount = targetIds.count - skippedCount

        if skippedCount > 0 {
            setDropFeedback("\(deletedCount)개 작업을 대기열에서 지웠습니다. (\(skippedCount)개 제외)")
        } else {
            setDropFeedback("\(deletedCount)개 작업을 대기열에서 지웠습니다.")
        }
    }

    /// Deletes all completed jobs from history without deleting downloaded files.
    public func bulkClearHistory() {
        let targetJobs = jobs.filter {
            $0.state == .completed || $0.state == .completedWithSubtitleFailure
        }
        let targetIds = targetJobs.map(\.id)
        guard !targetIds.isEmpty else {
            setDropFeedback("삭제할 완료 기록이 없습니다.")
            return
        }

        performQueueBatch {
            for id in targetIds {
                deleteJob(jobId: id, removeFile: false, suppressAlert: true)
            }
        }

        let remainingIds = Set(jobs.map(\.id))
        let skippedCount = targetIds.filter { remainingIds.contains($0) }.count
        let deletedCount = targetIds.count - skippedCount

        if skippedCount > 0 {
            setDropFeedback("\(deletedCount)개 완료 기록을 목록에서 지웠습니다. (\(skippedCount)개 제외)")
        } else {
            setDropFeedback("\(deletedCount)개 완료 기록을 목록에서 지웠습니다.")
        }
    }

    /// Completed jobs without a running task: the only jobs "clear history" may touch.
    private var clearableHistoryJobs: [JobRecord] {
        jobs.filter {
            ($0.state == .completed || $0.state == .completedWithSubtitleFailure) && !hasActiveRun(jobId: $0.id)
        }
    }

    private func publishedPaths(of job: JobRecord) -> [String] {
        [job.publishedMediaPath].compactMap { $0 } + job.publishedSubtitlePaths
    }

    /// Number of distinct published files the "records + files to Trash" choice would consider (for the confirmation text).
    public var historyPublishedFileCount: Int {
        Set(clearableHistoryJobs.flatMap(publishedPaths(of:)).map(Self.referenceKey(forPath:))).count
    }

    /// Comparison-only key: standardized absolute path with symlinks resolved. Never used to decide what to trash.
    private static func referenceKey(forPath path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Number of completed records "파일지우기" would clear (for the confirmation text).
    public var historyClearableRecordCount: Int { clearableHistoryJobs.count }

    /// Clears completed records and moves only their published files (media + subtitles) to the Trash (recoverable).
    /// A path is trashed only if it is a regular, non-symlink file owned by us, directly recorded as published by a
    /// selected job, and located inside that job's own destination folder (Publisher.validateOwnedRegularFile).
    /// Files still referenced by non-selected jobs are kept. Missing files count as done. A job whose file cannot be
    /// trashed keeps its record. Source URLs and work directories are never touched.
    public func bulkClearHistoryWithFiles() {
        let targets = clearableHistoryJobs
        guard !targets.isEmpty else {
            setDropFeedback("삭제할 완료 기록이 없습니다.")
            return
        }
        let targetIds = Set(targets.map(\.id))
        let keptPaths = Set(jobs.filter { !targetIds.contains($0.id) }.flatMap(publishedPaths(of:)).map(Self.referenceKey(forPath:)))
        var trashed = Set<String>()
        var failedPaths = Set<String>()
        var clearIds: [String] = []
        var failedJobs = 0
        var firstError: String?
        var trashedCount = 0

        for job in targets {
            var jobOK = true
            for path in publishedPaths(of: job) {
                let key = Self.referenceKey(forPath: path)
                if trashed.contains(key) || keptPaths.contains(key) { continue }
                if failedPaths.contains(key) { jobOK = false; continue }
                do {
                    try Publisher.validateOwnedRegularFile(path: path, root: job.destinationFolder)
                    try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
                    trashed.insert(key)
                    trashedCount += 1
                } catch PublishError.sourceNotFound {
                    // validateOwnedRegularFile maps every lstat failure to sourceNotFound; only a real
                    // ENOENT/ENOTDIR counts as missing. Anything else keeps the record with an error.
                    var st = stat()
                    if lstat(path, &st) == 0 {
                        failedPaths.insert(key)
                        jobOK = false
                        if firstError == nil {
                            firstError = "\((path as NSString).lastPathComponent): 파일 상태를 확인할 수 없습니다."
                        }
                    } else if errno == ENOENT || errno == ENOTDIR {
                        trashed.insert(key)
                    } else {
                        let code = errno
                        failedPaths.insert(key)
                        jobOK = false
                        if firstError == nil {
                            firstError = "\((path as NSString).lastPathComponent): \(String(cString: strerror(code)))"
                        }
                    }
                } catch {
                    failedPaths.insert(key)
                    jobOK = false
                    if firstError == nil {
                        firstError = "\((path as NSString).lastPathComponent): \(error.localizedDescription)"
                    }
                }
            }
            if jobOK { clearIds.append(job.id) } else { failedJobs += 1 }
        }

        performQueueBatch {
            for id in clearIds {
                deleteJob(jobId: id, removeFile: false, suppressAlert: true)
            }
        }

        if failedJobs > 0 {
            setDropFeedback("\(clearIds.count)개 기록을 지우고 파일 \(trashedCount)개를 휴지통으로 옮겼습니다. 파일을 옮기지 못한 \(failedJobs)개 기록은 남겼습니다. (\(firstError ?? "알 수 없는 오류"))")
        } else {
            setDropFeedback("\(clearIds.count)개 완료 기록을 지우고 파일 \(trashedCount)개를 휴지통으로 옮겼습니다.")
        }
    }

    /// Retries failed, interrupted, cancelled, selectionChanged, or verificationIncomplete jobs.
    /// Excludes active, completed, queued, awaitingSelection, and paused jobs.
    /// Skips redacted URLs unless pendingPublish reusable output exists in the work directory.
    public func bulkRetryQueue() {
        let targetJobs = jobs.filter { isRetryEligibleState($0.state) }
        guard !targetJobs.isEmpty else {
            setDropFeedback("다시 시도할 수 있는 작업이 없습니다.")
            return
        }

        var retriedCount = 0
        var skippedCount = 0

        for job in targetJobs {
            let canReusePendingPublish: Bool = {
                guard job.pendingPublish,
                      job.publishedMediaPath == nil || job.runMode == .subtitlesOnly,
                      let media = job.manifest?.primaryMediaFile ?? job.manifest?.subtitleFiles.first?.path,
                      let work = job.workDirectory else {
                    return false
                }
                return (try? Publisher.validateOwnedRegularFile(path: media, root: work)) != nil
            }()

            if canReusePendingPublish {
                retryJob(jobId: job.id)
                retriedCount += 1
            } else {
                guard !job.urlWasRedacted, isValidRuntimeSourceURL(job.sourceURL) else {
                    skippedCount += 1
                    continue
                }
                retryJob(jobId: job.id)
                retriedCount += 1
            }
        }

        if retriedCount > 0 {
            if skippedCount > 0 {
                setDropFeedback("\(retriedCount)개 작업을 다시 시도합니다. (\(skippedCount)개 제외)")
            } else {
                setDropFeedback("\(retriedCount)개 작업을 다시 시도합니다.")
            }
        } else {
            if skippedCount > 0 {
                setDropFeedback("다시 시도할 수 있는 유효한 작업이 없습니다. (\(skippedCount)개 제외)")
            } else {
                setDropFeedback("다시 시도할 수 있는 작업이 없습니다.")
            }
        }
    }

    /// Opens original page references or valid source URLs in browser tabs for failed/retry-case jobs.
    /// Prioritizes validated browserPageReference, then validated retryPageURL, then current valid sourceURL.
    public func bulkOpenInBrowser() {
        let targetJobs = jobs.filter { isRetryEligibleState($0.state) }
        guard !targetJobs.isEmpty else {
            setDropFeedback("브라우저에서 열 수 있는 실패 또는 중단된 작업이 없습니다.")
            return
        }

        var seenURLs = Set<String>()
        var urlsToOpen: [String] = []
        var skippedCount = 0

        for job in targetJobs {
            if let resolved = resolveBrowserURL(for: job) {
                let canonical = URL(string: resolved)?.absoluteString ?? resolved
                if seenURLs.insert(canonical).inserted {
                    urlsToOpen.append(canonical)
                }
            } else {
                skippedCount += 1
            }
        }

        var openedCount = 0
        for url in urlsToOpen {
            if let tab = newTab(explicitURL: true) {
                tab.open(url)
                openedCount += 1
            }
        }

        if openedCount > 0 {
            selectedTab = .browser
            if skippedCount > 0 {
                setDropFeedback("브라우저에서 \(openedCount)개 주소를 열었습니다. (\(skippedCount)개 제외)")
            } else {
                setDropFeedback("브라우저에서 \(openedCount)개 주소를 열었습니다.")
            }
        } else {
            if skippedCount > 0 {
                setDropFeedback("브라우저에서 열 수 있는 주소가 없습니다. (\(skippedCount)개 제외)")
            } else {
                setDropFeedback("브라우저에서 열 수 있는 주소가 없습니다.")
            }
        }
    }

    // MARK: - Private Helpers

    private func isBulkStartCandidate(_ job: JobRecord) -> Bool {
        job.state == .awaitingSelection && !job.isLive && job.runMode != .subtitlesOnly
    }

    private func isBulkStartReady(_ job: JobRecord) -> Bool {
        guard isBulkStartCandidate(job),
              hasUsableSourceForStart(job),
              makeDownloadSpec(job: job, outputDir: "/") != nil else {
            return false
        }
        return true
    }

    private func isRetryEligibleState(_ state: JobState) -> Bool {
        switch state {
        case .failed, .interrupted, .selectionChanged, .verificationIncomplete, .cancelled:
            return true
        case .queued, .extracting, .awaitingSelection, .downloading, .recording,
             .processing, .verifying, .publishing, .completed, .completedWithSubtitleFailure, .paused:
            return false
        }
    }

    private func resolveBrowserURL(for job: JobRecord) -> String? {
        // Priority 1: Validated browserPageReference
        if let ref = job.browserPageReference,
           let valid = validateSafeRetryPageURL(ref, fromBrowser: false, hasPageProvenance: true) {
            return valid
        }

        // Priority 2: Validated retryPageURL
        if let ref = job.retryPageURL,
           let valid = validateSafeRetryPageURL(ref, fromBrowser: job.fromBrowser, hasPageProvenance: true) {
            return valid
        }

        // Priority 3: Current unredacted valid sourceURL
        // Known media or fromBrowser jobs without original page reference must be skipped
        if job.fromBrowser || isKnownMediaURL(job.sourceURL) {
            return nil
        }

        guard !job.urlWasRedacted, isValidRuntimeSourceURL(job.sourceURL) else {
            return nil
        }

        return job.sourceURL
    }

    private func isValidRuntimeSourceURL(_ raw: String) -> Bool {
        guard !raw.isEmpty, raw.count <= 4096 else { return false }
        if raw.contains("…") || raw.lowercased().contains("%e2%80%a6") { return false }
        if hasControlCharacters(raw) { return false }

        guard let comps = URLComponents(string: raw),
              let scheme = comps.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = comps.host, !host.isEmpty else {
            return false
        }

        if comps.user != nil || comps.password != nil { return false }
        if let u = comps.percentEncodedUser, !u.isEmpty { return false }
        if let p = comps.percentEncodedPassword, !p.isEmpty { return false }

        return true
    }

    private func hasControlCharacters(_ s: String) -> Bool {
        if s.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
            return true
        }
        let lower = s.lowercased()
        var idx = lower.startIndex
        while let percentRange = lower[idx...].range(of: "%") {
            let hexStart = percentRange.upperBound
            if let hexEnd = lower.index(hexStart, offsetBy: 2, limitedBy: lower.endIndex) {
                let hexStr = String(lower[hexStart..<hexEnd])
                if let val = UInt8(hexStr, radix: 16), (val < 0x20 || val == 0x7F) {
                    return true
                }
                idx = hexEnd
            } else {
                break
            }
        }
        return false
    }

    private func isKnownMediaURL(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString) else { return false }
        let ext = url.pathExtension.lowercased()
        let mediaExtensions: Set<String> = [
            "mp4", "m4v", "m4a", "m4s", "mp3", "aac", "flac", "ogg", "wav", "webm",
            "mkv", "avi", "mov", "wmv", "flv", "ts", "m2ts", "m3u8", "m3u", "mpd",
            "f4m", "ism", "manifest"
        ]
        return mediaExtensions.contains(ext)
    }
}
