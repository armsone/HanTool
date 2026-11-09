import SwiftUI
import AppKit
import AVFoundation
import ImageIO
import CryptoKit
import UniformTypeIdentifiers

/// Best-effort LOCAL preview frames (never fetched from the network). Cache key is a hash of the job id and algorithm version.
enum JobThumbnailCache {
    static let maxSide: CGFloat = 336
    static let maxEarlyAttempts = 4

    struct Request: Sendable {
        let jobId: String
        let directory: URL
        let completed: Bool
        let publishedPath: String?
        let manifestPath: String?
        let workDirectory: String?
    }

    /// Bounds concurrent generation and the number of retries per job (memory only).
    actor Gate {
        private var running = 0
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var attempts: [String: Int] = [:]
        private var completedTried: Set<String> = []

        func acquire() async {
            if running < 2 { running += 1; return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func release() {
            if waiters.isEmpty { running -= 1 } else { waiters.removeFirst().resume() }
        }
        /// After the cache was wiped, previews may be generated again (otherwise "tried" markers would block them until relaunch).
        func resetAttempts(keeping ids: Set<String>) {
            attempts = attempts.filter { ids.contains($0.key) }
            completedTried = completedTried.intersection(ids)
        }
        func mayAttempt(_ id: String, completed: Bool) -> Bool {
            if completed { return completedTried.insert(id).inserted }
            let n = attempts[id, default: 0]
            guard n < JobThumbnailCache.maxEarlyAttempts else { return false }
            attempts[id] = n + 1
            return true
        }
    }
    static let gate = Gate()

    /// Bump when the frame selection changes so older cached files are no longer read.
    static let algorithmVersion = "v2-10to95-half"

    static func file(_ dir: URL, _ jobId: String, legacy: Bool = false) -> URL {
        let tag = legacy ? "htd-thumb|" : "htd-thumb|" + algorithmVersion + "|"
        let digest = SHA256.hash(data: Data((tag + jobId).utf8))
        return dir.appendingPathComponent(digest.map { String(format: "%02x", $0) }.joined() + ".jpg")
    }

    static func remove(jobId: String, directory: URL) {
        try? FileManager.default.removeItem(at: file(directory, jobId))
        try? FileManager.default.removeItem(at: file(directory, jobId, legacy: true))
    }

    /// Deletes generated preview files only: `directory` must be the real (non-symlink) "thumbnails" folder, and each
    /// entry must be a regular non-symlink file named exactly like `file(_:_:)` output (64 hex digits + ".jpg").
    /// Previews of `keepJobIds` (active/retryable jobs) are left in place. Returns (files removed, bytes freed).
    static func clearGenerated(directory: URL, keepJobIds: Set<String>) async -> (files: Int, bytes: Int64) {
        let result = await Task.detached(priority: .utility) { () -> (Int, Int64) in
            guard directory.lastPathComponent == "thumbnails" else { return (0, 0) }
            let dir = directory.path
            var dst = stat()
            guard lstat(dir, &dst) == 0, (dst.st_mode & S_IFMT) == S_IFDIR else { return (0, 0) }   // not a symlink either
            let keep = Set(keepJobIds.flatMap { id in
                [file(directory, id).lastPathComponent, file(directory, id, legacy: true).lastPathComponent]
            })
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return (0, 0) }
            var files = 0
            var bytes: Int64 = 0
            for name in names where name.count == 68 && name.hasSuffix(".jpg") && !keep.contains(name) {
                let stem = name.dropLast(4)
                guard stem.allSatisfy({ $0.isASCII && ($0.isNumber || ("a"..."f").contains($0)) }) else { continue }
                let path = (dir as NSString).appendingPathComponent(name)
                var st = stat()
                guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { continue }   // never follow/remove symlinks or folders
                if unlink(path) == 0 { files += 1; bytes += Int64(st.st_size) }
            }
            return (files, bytes)
        }.value
        await gate.resetAttempts(keeping: keepJobIds)
        return (files: result.0, bytes: result.1)
    }

    /// Total size of the previews `clearGenerated` would delete (same folder checks, same name filter, `keepJobIds` excluded,
    /// regular non-symlink files only). Runs off the caller's thread. Returns nil if the folder cannot be read, never a partial sum.
    static func measureGenerated(directory: URL, keepJobIds: Set<String>) async -> Int64? {
        await Task.detached(priority: .utility) { () -> Int64? in
            guard directory.lastPathComponent == "thumbnails" else { return nil }
            let dir = directory.path
            var dst = stat()
            if lstat(dir, &dst) != 0 { return errno == ENOENT ? 0 : nil }
            guard (dst.st_mode & S_IFMT) == S_IFDIR else { return nil }
            let keep = Set(keepJobIds.flatMap { id in
                [file(directory, id).lastPathComponent, file(directory, id, legacy: true).lastPathComponent]
            })
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return nil }
            var bytes: Int64 = 0
            for name in names where name.count == 68 && name.hasSuffix(".jpg") && !keep.contains(name) {
                let stem = name.dropLast(4)
                guard stem.allSatisfy({ $0.isASCII && ($0.isNumber || ("a"..."f").contains($0)) }) else { continue }
                var st = stat()
                guard lstat((dir as NSString).appendingPathComponent(name), &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { continue }
                bytes += Int64(st.st_size)
            }
            return bytes
        }.value
    }

    /// Cached image if present, otherwise one bounded generation attempt. Returns nil when unavailable.
    static func image(for r: Request) async -> CGImage? {
        let cached = file(r.directory, r.jobId)
        if let img = decode(cached) { return img }
        guard await gate.mayAttempt(r.jobId, completed: r.completed) else { return nil }
        await gate.acquire()
        defer { Task { await gate.release() } }
        if Task.isCancelled { return nil }
        guard let source = sourceFile(r) else { return nil }
        guard let img = await generate(source) else { return nil }
        if Task.isCancelled { return nil }
        store(img, to: cached, directory: r.directory)
        return img
    }

    private static func decode(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(src) > 0 else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    private static func store(_ img: CGImage, to url: URL, directory: URL) {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? (data as Data).write(to: url, options: .atomic)
    }

    private static func isRegular(_ path: String) -> Bool {
        var st = stat()
        return stat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG
    }

    private static let mediaExts: Set<String> = ["mp4", "m4v", "mov", "ts", "mkv", "webm"]

    /// Completed: the published file (authorized for this job) or manifest media. Incomplete: only owned
    /// regular non-symlink files inside this job's work directory.
    private static func sourceFile(_ r: Request) -> URL? {
        if r.completed {
            for p in [r.publishedPath, r.manifestPath].compactMap({ $0 }) where p.hasPrefix("/") && isRegular(p) {
                return URL(fileURLWithPath: p)
            }
            return nil
        }
        guard let work = r.workDirectory, work.hasPrefix("/") else { return nil }
        var candidates: [String] = []
        if let m = r.manifestPath { candidates.append(m) }
        if let names = try? FileManager.default.contentsOfDirectory(atPath: work) {
            let media = names.sorted().prefix(64).filter { name in
                var n = name as NSString
                if n.pathExtension.lowercased() == "part" { n = n.deletingPathExtension as NSString }
                return mediaExts.contains(n.pathExtension.lowercased())
            }
            candidates += media.map { (work as NSString).appendingPathComponent($0) }
        }
        for p in candidates.prefix(8) {
            if (try? Publisher.validateOwnedRegularFile(path: p, root: work)) != nil { return URL(fileURLWithPath: p) }
        }
        return nil
    }

    private static func mime(for url: URL) -> String? {
        var n = url.lastPathComponent as NSString
        if n.pathExtension.lowercased() == "part" { n = n.deletingPathExtension as NSString } else { return nil }
        switch n.pathExtension.lowercased() {
        case "mp4", "m4v": return "video/mp4"
        case "mov": return "video/quicktime"
        default: return nil
        }
    }

    /// True when at least 50% of a 16x16 grayscale downsample is very dark (luma < 24/255).
    private static func mostlyBlack(_ img: CGImage) -> Bool {
        let n = 16
        var px = [UInt8](repeating: 0, count: n * n)
        let dark = px.withUnsafeMutableBytes { buf -> Int? in
            guard let ctx = CGContext(data: buf.baseAddress, width: n, height: n, bitsPerComponent: 8,
                                      bytesPerRow: n, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
            ctx.interpolationQuality = .low
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: n, height: n))
            return buf.reduce(0) { $0 + ($1 < 24 ? 1 : 0) }
        }
        guard let dark else { return false }
        return dark * 2 >= n * n
    }

    private static func generate(_ url: URL) async -> CGImage? {
        var options: [String: Any]? = nil
        if url.pathExtension.lowercased() == "part" {
            guard let m = mime(for: url) else { return nil }
            options = ["AVURLAssetOutOfBandMIMETypeKey": m]
        }
        let asset = AVURLAsset(url: url, options: options)
        guard let tracks = try? await asset.loadTracks(withMediaType: .video), !tracks.isEmpty else { return nil }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxSide, height: maxSide)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        return await withTaskGroup(of: CGImage?.self) { group in
            group.addTask {
                await withTaskCancellationHandler {
                    guard let duration = try? await asset.load(.duration).seconds,
                          duration.isFinite, duration > 0 else { return nil }
                    // 10%, 15%, ... 95%: return only the first frame that is not mostly black.
                    for percent in stride(from: 10, through: 95, by: 5) {
                        if Task.isCancelled { return nil }
                        let t = CMTime(seconds: duration * Double(percent) / 100, preferredTimescale: 600)
                        guard let r = try? await generator.image(at: t) else { continue }
                        if !mostlyBlack(r.image) { return r.image }
                    }
                    return nil
                } onCancel: { generator.cancelAllCGImageGeneration() }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

/// Shows a small preview only once an actual image exists; otherwise it renders (and reserves) nothing.
struct JobThumbnailView: View {
    let job: JobRecord
    let directory: URL
    @State private var image: NSImage?

    private var completed: Bool { job.state == .completed || job.state == .completedWithSubtitleFailure }
    private var eligible: Bool {
        completed || [.downloading, .processing, .verifying, .publishing].contains(job.state)
    }
    /// Changes on job, state, source or coarse progress only (not every progress tick).
    private var taskKey: String {
        "\(job.id)|\(job.state.rawValue)|\(Int(job.progressPercent / 20))|\(job.publishedMediaPath ?? "")"
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 84, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .accessibilityHidden(true)
                    .padding(.trailing, 10)
            } else {
                // Zero-size stable anchor so .task mounts while no image exists (no placeholder, no space).
                Color.clear.frame(width: 0, height: 0).accessibilityHidden(true)
            }
        }
        .task(id: taskKey) {
            guard eligible else { return }
            let req = JobThumbnailCache.Request(
                jobId: job.id, directory: directory, completed: completed,
                publishedPath: job.publishedMediaPath, manifestPath: job.manifest?.primaryMediaFile,
                workDirectory: job.workDirectory)
            guard let cg = await JobThumbnailCache.image(for: req), !Task.isCancelled else { return }
            image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }
    }
}
