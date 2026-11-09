import Foundation
import Darwin
import CryptoKit

@_silgen_name("renameatx_np")
private func sys_renameatx_np(_ fromfd: Int32, _ from: UnsafePointer<CChar>, _ tofd: Int32, _ to: UnsafePointer<CChar>, _ flags: UInt32) -> Int32

public enum PublishError: LocalizedError {
    case sourceNotFound(String)
    case unsafeSource(String)
    case destinationNotWritable(String)
    case copyFailed(String)
    case renameFailed(String)
    case tooManyNameCollisions
    case cancelledBeforePublish

    public var errorDescription: String? {
        switch self {
        case .sourceNotFound(let what):
            return "임시 생성된 원본 파일을 찾을 수 없습니다 (\(what))."
        case .unsafeSource(let why):
            return "안전하지 않은 산출물이라 저장하지 않았습니다: \(why)"
        case .destinationNotWritable(let name):
            return "저장 폴더에 쓸 수 없습니다: \(name)"
        case .copyFailed(let reason):
            return "다른 볼륨으로의 안전 복사에 실패했습니다: \(reason)"
        case .renameFailed(let reason):
            return "저장 폴더로의 이름 확정에 실패했습니다: \(reason)"
        case .tooManyNameCollisions:
            return "같은 이름의 파일이 너무 많아 번호를 붙일 수 없습니다."
        case .cancelledBeforePublish:
            return "저장이 확정되기 전에 취소되었습니다. 받은 파일은 작업 폴더에 보존됩니다."
        }
    }
}

/// Serializes "cancel" against "commit": once the first exclusive rename into the destination has succeeded,
/// a later cancel request is refused instead of racing the already-published file.
public final class PublishControl {
    public enum CancelOutcome { case accepted, alreadyCommitted }

    private let lock = NSLock()
    private var cancelRequested = false
    private var committed = false

    public init() {}

    public var isCancelRequested: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelRequested
    }

    public var isCommitted: Bool {
        lock.lock(); defer { lock.unlock() }
        return committed
    }

    public func requestCancel() -> CancelOutcome {
        lock.lock(); defer { lock.unlock() }
        if committed { return .alreadyCommitted }
        cancelRequested = true
        return .accepted
    }

    /// Runs the (single syscall) commit operation unless a cancel was accepted first.
    func attemptCommit(_ operation: () -> Int32) -> Int32? {
        lock.lock(); defer { lock.unlock() }
        if cancelRequested { return nil }
        let r = operation()
        if r == 0 { committed = true }
        return r
    }
}

public struct PublishResult {
    public var publishedMediaPath: String?
    public var publishedSubtitlePaths: [String]
    public var failedSubtitleLangs: [String]
}

/// Write-ahead record of what a publish intends to do, so a crash can be reconciled instead of duplicated.
struct PublishJournal: Codable {
    struct Entry: Codable {
        var role: String          // media | subtitle
        var source: String
        var size: Int64
        var stage: String?        // staging file name inside the destination (cross-volume)
        var target: String?       // final file name currently being attempted / committed
        var phase: String         // planned | staged | renaming | committed
    }
    var jobId: String
    var generation: Int
    var destination: String       // real path
    var entries: [Entry]
}

public enum ReconcileOutcome {
    case committed(media: String?, subtitles: [String])
    case notCommitted
}

public typealias RenameFunction = (_ fromFd: Int32, _ from: String, _ toFd: Int32, _ to: String, _ flags: UInt32) -> Int32

public final class Publisher {
    private static let publishLock = NSLock()
    private static let renameExcl: UInt32 = 0x4
    private static let stagePrefix = ".httpsdown-stage-"
    private static let chunk = 4 * 1024 * 1024

    static let systemRename: RenameFunction = { fromFd, from, toFd, to, flags in
        from.withCString { f in to.withCString { t in sys_renameatx_np(fromFd, f, toFd, t, flags) } }
    }

    // MARK: Validation helpers

    static func realPath(_ path: String) -> String? {
        guard let r = realpath(path, nil) else { return nil }
        defer { free(r) }
        return String(cString: r)
    }

    /// The path must be a real, singly-linked regular file owned by us, whose real parent lies inside `root`.
    @discardableResult
    public static func validateOwnedRegularFile(path: String, root: String) throws -> Int64 {
        guard path.hasPrefix("/") else { throw PublishError.unsafeSource("절대 경로가 아닙니다") }
        var st = stat()
        guard lstat(path, &st) == 0 else { throw PublishError.sourceNotFound((path as NSString).lastPathComponent) }
        guard (st.st_mode & S_IFMT) == S_IFREG else { throw PublishError.unsafeSource("일반 파일이 아니거나 심볼릭 링크입니다") }
        guard st.st_uid == geteuid() else { throw PublishError.unsafeSource("소유자가 다릅니다") }
        guard st.st_nlink == 1 else { throw PublishError.unsafeSource("하드링크로 연결된 파일입니다") }
        guard let realRoot = realPath(root),
              let realParent = realPath((path as NSString).deletingLastPathComponent),
              realParent == realRoot || realParent.hasPrefix(realRoot + "/") else {
            throw PublishError.unsafeSource("작업 폴더 밖의 경로입니다")
        }
        return Int64(st.st_size)
    }

    static func sanitizeStem(_ raw: String, maxBytes: Int = 200) -> String {
        var s = ""
        for scalar in raw.unicodeScalars {
            if scalar.value < 0x20 || scalar.value == 0x7F || scalar == "/" || scalar == "\\" || scalar == ":" {
                s.append("-")
            } else {
                s.unicodeScalars.append(scalar)
            }
        }
        s = s.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".")))
        if s.isEmpty { s = "download" }
        while s.utf8.count > maxBytes { s.removeLast() }
        return s
    }

    static func sanitizeExt(_ raw: String) -> String {
        let e = raw.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        return String(e.prefix(8))
    }

    private static func candidate(_ stem: String, _ counter: Int, _ ext: String) -> String {
        let base = counter == 0 ? stem : "\(stem) (\(counter))"
        return ext.isEmpty ? base : "\(base).\(ext)"
    }

    // MARK: Journal

    private static func writeJournal(_ journal: PublishJournal, to url: URL) {
        if let data = try? JSONEncoder().encode(journal) {
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: Publish

    /// Publishes the verified media (and sidecar subtitles) exclusively into the destination folder.
    /// Never overwrites; same-name collisions get " (1)", " (2)" ... Cross-volume moves are copied into a staging
    /// file on the destination volume, verified (size + SHA-256 re-read) and then renamed exclusively.
    /// The source and any pre-existing user file are never deleted on failure.
    public static func publish(
        manifest: OutputManifest,
        destinationFolder: String,
        workRoot: String,
        journalURL: URL,
        jobId: String,
        generation: Int,
        existingBaseName: String? = nil,
        control: PublishControl,
        rename: RenameFunction? = nil
    ) throws -> PublishResult {
        publishLock.lock()
        defer { publishLock.unlock() }
        let renameFn = rename ?? systemRename
        if control.isCancelRequested { throw PublishError.cancelledBeforePublish }

        guard let destReal = realPath(destinationFolder) else { throw PublishError.destinationNotWritable("폴더 없음") }
        var dst = stat()
        guard stat(destReal, &dst) == 0, (dst.st_mode & S_IFMT) == S_IFDIR, access(destReal, W_OK) == 0 else {
            throw PublishError.destinationNotWritable((destinationFolder as NSString).lastPathComponent)
        }

        var entries: [PublishJournal.Entry] = []
        var mediaSource: String?
        if existingBaseName == nil {
            guard let media = manifest.primaryMediaFile else { throw PublishError.sourceNotFound("미지정") }
            let size = try validateOwnedRegularFile(path: media, root: workRoot)
            if let expected = manifest.primarySize, expected != size {
                throw PublishError.unsafeSource("검증 이후 파일 크기가 바뀌었습니다")
            }
            mediaSource = media
            entries.append(.init(role: "media", source: media, size: size, stage: nil, target: nil, phase: "planned"))
        }
        var subtitleSources: [SubtitleFile] = []
        for sub in manifest.subtitleFiles {
            if let size = try? validateOwnedRegularFile(path: sub.path, root: workRoot), size == sub.size {
                subtitleSources.append(sub)
                entries.append(.init(role: "subtitle", source: sub.path, size: size, stage: nil, target: nil, phase: "planned"))
            }
        }
        guard !entries.isEmpty else { throw PublishError.sourceNotFound("게시할 파일 없음") }

        var journal = PublishJournal(jobId: jobId, generation: generation, destination: destReal, entries: entries)
        writeJournal(journal, to: journalURL)

        let destFd = open(destReal, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard destFd >= 0 else { throw PublishError.destinationNotWritable("폴더를 열 수 없음") }
        defer { close(destFd) }

        var chosenStem = existingBaseName ?? ""
        var mediaPath: String?
        var entryIndex = 0

        if let media = mediaSource {
            let url = URL(fileURLWithPath: media)
            let name = try commitEntry(
                index: entryIndex, journal: &journal, journalURL: journalURL,
                sourcePath: media, sourceSize: journal.entries[entryIndex].size,
                stem: sanitizeStem(url.deletingPathExtension().lastPathComponent),
                ext: sanitizeExt(url.pathExtension), destFd: destFd, control: control, rename: renameFn)
            mediaPath = destReal + "/" + name
            chosenStem = ext(name).isEmpty ? name : String(name.dropLast(ext(name).count + 1))
            entryIndex += 1
        }

        var publishedSubs: [String] = []
        var failedLangs: [String] = []
        for sub in subtitleSources {
            defer { entryIndex += 1 }
            let lang = String(sub.lang.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }.prefix(24))
            do {
                let name = try commitEntry(
                    index: entryIndex, journal: &journal, journalURL: journalURL,
                    sourcePath: sub.path, sourceSize: sub.size,
                    stem: sanitizeStem("\(chosenStem).\(lang.isEmpty ? "und" : lang)"),
                    ext: sanitizeExt(sub.ext), destFd: destFd, control: control, rename: renameFn)
                publishedSubs.append(destReal + "/" + name)
            } catch PublishError.cancelledBeforePublish where mediaPath == nil {
                throw PublishError.cancelledBeforePublish   // nothing committed yet (subtitle-only retry)
            } catch {
                failedLangs.append(sub.lang)
            }
        }
        if mediaPath == nil && publishedSubs.isEmpty { throw PublishError.renameFailed("자막을 저장하지 못했습니다") }
        return PublishResult(publishedMediaPath: mediaPath, publishedSubtitlePaths: publishedSubs, failedSubtitleLangs: failedLangs)
    }

    private static func ext(_ name: String) -> String { (name as NSString).pathExtension }

    /// Exclusive rename with numbering; falls back to a verified staging copy on EXDEV. Returns the final file name.
    private static func commitEntry(
        index: Int,
        journal: inout PublishJournal,
        journalURL: URL,
        sourcePath: String,
        sourceSize: Int64,
        stem: String,
        ext: String,
        destFd: Int32,
        control: PublishControl,
        rename: RenameFunction
    ) throws -> String {
        let sourceURL = URL(fileURLWithPath: sourcePath)
        guard let srcDirReal = realPath(sourceURL.deletingLastPathComponent().path) else {
            throw PublishError.sourceNotFound("작업 폴더")
        }
        let srcDirFd = open(srcDirReal, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard srcDirFd >= 0 else { throw PublishError.sourceNotFound("작업 폴더") }
        defer { close(srcDirFd) }
        let srcName = sourceURL.lastPathComponent

        var stageName: String? = nil
        var counter = 0
        while counter < 500 {
            if control.isCancelRequested {
                if let s = stageName { unlinkat(destFd, s, 0) }
                throw PublishError.cancelledBeforePublish
            }
            let name = candidate(stem, counter, ext)
            journal.entries[index].target = name
            journal.entries[index].phase = "renaming"
            writeJournal(journal, to: journalURL)

            var savedErrno: Int32 = 0
            let fromFd = stageName == nil ? srcDirFd : destFd
            let from = stageName ?? srcName
            guard let r = control.attemptCommit({
                let rc = rename(fromFd, from, destFd, name, renameExcl)
                savedErrno = errno
                return rc
            }) else {
                if let s = stageName { unlinkat(destFd, s, 0) }
                throw PublishError.cancelledBeforePublish
            }

            if r == 0 {
                if stageName != nil { unlinkat(srcDirFd, srcName, 0) }   // our own work file; staging copy is now the result
                journal.entries[index].phase = "committed"
                writeJournal(journal, to: journalURL)
                return name
            }
            if savedErrno == EEXIST {
                counter += 1
                continue
            }
            if savedErrno == EXDEV, stageName == nil {
                stageName = try copyToStage(sourcePath: sourcePath, expectedSize: sourceSize, destFd: destFd, control: control)
                journal.entries[index].stage = stageName
                journal.entries[index].phase = "staged"
                writeJournal(journal, to: journalURL)
                continue
            }
            if let s = stageName { unlinkat(destFd, s, 0) }
            throw PublishError.renameFailed(String(cString: strerror(savedErrno)))
        }
        if let s = stageName { unlinkat(destFd, s, 0) }
        throw PublishError.tooManyNameCollisions
    }

    private static func copyToStage(sourcePath: String, expectedSize: Int64, destFd: Int32, control: PublishControl) throws -> String {
        let stage = stagePrefix + UUID().uuidString
        let sfd = open(sourcePath, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard sfd >= 0 else { throw PublishError.sourceNotFound("원본 열기 실패") }
        defer { close(sfd) }
        var sst = stat()
        guard fstat(sfd, &sst) == 0, (sst.st_mode & S_IFMT) == S_IFREG, Int64(sst.st_size) == expectedSize else {
            throw PublishError.unsafeSource("복사 직전 원본이 바뀌었습니다")
        }
        let dfd = openat(destFd, stage, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard dfd >= 0 else { throw PublishError.copyFailed("스테이징 파일 생성 실패") }

        func fail(_ reason: String, cancelled: Bool = false) -> PublishError {
            close(dfd)
            unlinkat(destFd, stage, 0)   // only our own staging file
            return cancelled ? .cancelledBeforePublish : .copyFailed(reason)
        }

        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: chunk)
        var total: Int64 = 0
        while true {
            if control.isCancelRequested { throw fail("", cancelled: true) }
            let n = read(sfd, &buffer, buffer.count)
            if n < 0 { if errno == EINTR { continue }; throw fail("읽기 오류") }
            if n == 0 { break }
            buffer.withUnsafeBytes { hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[0..<n])) }
            var off = 0
            while off < n {
                let w = buffer.withUnsafeBytes { write(dfd, $0.baseAddress!.advanced(by: off), n - off) }
                if w < 0 { if errno == EINTR { continue }; throw fail("쓰기 오류 (\(String(cString: strerror(errno))))") }
                off += w
            }
            total += Int64(n)
        }
        guard total == expectedSize else { throw fail("복사 크기 불일치 (\(total) != \(expectedSize))") }
        fsync(dfd)
        fchmod(dfd, 0o644)
        close(dfd)

        // Verify what actually landed on the destination volume.
        let vfd = openat(destFd, stage, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard vfd >= 0 else { unlinkat(destFd, stage, 0); throw PublishError.copyFailed("복사본 재열기 실패") }
        defer { close(vfd) }
        var vst = stat()
        guard fstat(vfd, &vst) == 0, Int64(vst.st_size) == expectedSize else {
            unlinkat(destFd, stage, 0)
            throw PublishError.copyFailed("복사본 크기 불일치")
        }
        var verify = SHA256()
        while true {
            if control.isCancelRequested { unlinkat(destFd, stage, 0); throw PublishError.cancelledBeforePublish }
            let n = read(vfd, &buffer, buffer.count)
            if n < 0 { if errno == EINTR { continue }; unlinkat(destFd, stage, 0); throw PublishError.copyFailed("복사본 읽기 오류") }
            if n == 0 { break }
            buffer.withUnsafeBytes { verify.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[0..<n])) }
        }
        guard Array(hasher.finalize()) == Array(verify.finalize()) else {
            unlinkat(destFd, stage, 0)
            throw PublishError.copyFailed("복사본 해시가 원본과 다릅니다")
        }
        return stage
    }

    // MARK: Crash reconciliation

    /// Decides, after an interrupted publish, what actually reached the destination.
    /// Exclusive rename means a name we asked for only exists because of us if the source is gone
    /// (or, for a crash between staging-rename and source removal, the contents are byte-identical).
    public static func reconcile(journalURL: URL) -> ReconcileOutcome {
        guard let data = try? Data(contentsOf: journalURL),
              let journal = try? JSONDecoder().decode(PublishJournal.self, from: data) else {
            return .notCommitted
        }
        let destFd = open(journal.destination, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard destFd >= 0 else { return .notCommitted }
        defer { close(destFd) }

        var mediaCommitted: String?
        var subsCommitted: [String] = []
        var hasMedia = false

        for entry in journal.entries {
            if entry.role == "media" { hasMedia = true }
            if let stage = entry.stage, stage.hasPrefix(stagePrefix) {
                var st = stat()
                if fstatat(destFd, stage, &st, AT_SYMLINK_NOFOLLOW) == 0 {
                    unlinkat(destFd, stage, 0)   // rename never happened; drop only our staging file
                    continue
                }
            }
            var committedPath: String?
            if let target = entry.target, entry.phase == "committed" || entry.phase == "renaming" || entry.phase == "staged" {
                var tst = stat()
                let targetExists = fstatat(destFd, target, &tst, AT_SYMLINK_NOFOLLOW) == 0 && (tst.st_mode & S_IFMT) == S_IFREG
                var sst = stat()
                let sourceExists = lstat(entry.source, &sst) == 0
                if entry.phase == "committed" && targetExists {
                    committedPath = journal.destination + "/" + target
                } else if targetExists && Int64(tst.st_size) == entry.size {
                    if !sourceExists {
                        committedPath = journal.destination + "/" + target
                    } else if filesIdentical(sourcePath: entry.source, destFd: destFd, name: target) {
                        unlink(entry.source)
                        committedPath = journal.destination + "/" + target
                    }
                }
            }
            if entry.role == "media" {
                mediaCommitted = committedPath
            } else if let p = committedPath {
                subsCommitted.append(p)
            }
        }
        if hasMedia {
            guard let media = mediaCommitted else { return .notCommitted }
            return .committed(media: media, subtitles: subsCommitted)
        }
        return subsCommitted.isEmpty ? .notCommitted : .committed(media: nil, subtitles: subsCommitted)
    }

    private static func filesIdentical(sourcePath: String, destFd: Int32, name: String) -> Bool {
        let a = open(sourcePath, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        let b = openat(destFd, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        defer { if a >= 0 { close(a) }; if b >= 0 { close(b) } }
        guard a >= 0, b >= 0 else { return false }
        var bufA = [UInt8](repeating: 0, count: 1 << 20)
        var bufB = [UInt8](repeating: 0, count: 1 << 20)
        while true {
            let na = read(a, &bufA, bufA.count)
            var nb = 0
            while nb < na {
                let r = read(b, &bufB[nb], na - nb)
                if r <= 0 { return false }
                nb += r
            }
            if na < 0 { return false }
            if na == 0 { return read(b, &bufB, 1) == 0 }
            if bufA[0..<na] != bufB[0..<na] { return false }
        }
    }
}
