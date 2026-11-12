import AppKit
import Foundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

/// 클립보드 항목의 유형 (텍스트 또는 이미지).
public enum ClipboardItemType: String, Codable {
    case text
    case image
}

/// 클립보드에 복사된 단일 레코드.
public struct ClipboardItem: Identifiable, Codable, Equatable {
    public let id: UUID
    public let type: ClipboardItemType
    public var textContent: String?
    public var imageFileName: String?
    public var imageWidth: Int?
    public var imageHeight: Int?
    public var fileSize: Int64?
    public var sha256: String
    public var copiedAt: Date
    public var sourceAppBundleID: String?
    public var sourceAppName: String?

    public init(
        id: UUID = UUID(),
        type: ClipboardItemType,
        textContent: String? = nil,
        imageFileName: String? = nil,
        imageWidth: Int? = nil,
        imageHeight: Int? = nil,
        fileSize: Int64? = nil,
        sha256: String,
        copiedAt: Date = Date(),
        sourceAppBundleID: String? = nil,
        sourceAppName: String? = nil
    ) {
        self.id = id
        self.type = type
        self.textContent = textContent
        self.imageFileName = imageFileName
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.fileSize = fileSize
        self.sha256 = sha256
        self.copiedAt = copiedAt
        self.sourceAppBundleID = sourceAppBundleID
        self.sourceAppName = sourceAppName
    }

    /// 미리보기용 한 줄 제목.
    public var displayTitle: String {
        switch type {
        case .text:
            guard let text = textContent else { return "(빈 텍스트)" }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return "(공백 텍스트)" }
            let firstLine = trimmed.components(separatedBy: .newlines).first ?? trimmed
            return firstLine.trimmingCharacters(in: .whitespaces)
        case .image:
            let w = imageWidth ?? 0
            let h = imageHeight ?? 0
            if w > 0 && h > 0 {
                return "이미지 (\(w) × \(h))"
            }
            return "이미지"
        }
    }

    /// 단어 수 및 글자 수 (텍스트 항목용).
    public var textStats: (words: Int, chars: Int)? {
        guard type == .text, let text = textContent else { return nil }
        let chars = text.count
        let words = text.split { $0.isWhitespace || $0.isNewline }.count
        return (words, chars)
    }
}

/// 클립보드 히스토리 환경설정.
public struct ClipboardHistoryConfig: Codable, Equatable {
    public var maxTextCount: Int = 100          // 10 ~ 1000
    public var maxImageCount: Int = 50          // 10 ~ 500
    public var retentionDays: Int = 30          // 0(영구) 또는 일수
    public var maxDiskUsageMB: Int = 500        // 200 ~ 2000 MB

    public static let `default` = ClipboardHistoryConfig()
}

/// 클립보드 변화를 감시하고 로컬 파일 시스템에 영속화하는 관리자.
@MainActor
public final class ClipboardHistoryStore: ObservableObject {
    public static let shared = ClipboardHistoryStore()

    // MARK: - Constants & Limits
    private let maxSingleImageBytes: Int64 = 100 * 1024 * 1024         // 100 MB 단일 파일 제한
    private let maxDecodedPixelsMemory: Int64 = 256 * 1024 * 1024       // 256 MB 디코딩 메모리 제한
    private let thumbnailMaxDimension: CGFloat = 120                   // 목록 표시용 썸네일 상한

    private let userDefaultsConfigKey = "HanTool_ClipboardHistoryConfig_v1"

    // MARK: - Published State
    @Published public private(set) var items: [ClipboardItem] = []
    @Published public var config: ClipboardHistoryConfig {
        didSet {
            saveConfig()
            enforceLimits()
        }
    }
    @Published public private(set) var isMonitoring: Bool = false

    // MARK: - Storage Paths & Injected Dependencies
    private let baseDirectory: URL
    private let imagesDirectory: URL
    private let metadataURL: URL
    private let pasteboard: NSPasteboard
    private let userDefaults: UserDefaults

    // MARK: - Runtime Tracking
    private var lastObservedChangeCount: Int = 0
    private var pollTimer: Timer?
    private var workspaceObserver: NSObjectProtocol?
    private var isSelfWriting: Bool = false
    private var metadataLoadedSuccessfully: Bool = false

    // 썸네일 인메모리 캐시 (UUID -> NSImage)
    private var thumbnailCache = NSCache<NSUUID, NSImage>()

    public nonisolated static var defaultBaseDirectory: URL {
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: ("~/Library/Application Support" as NSString).expandingTildeInPath)
        return appSupport.appendingPathComponent("HanTool", isDirectory: true)
    }

    internal init(
        baseDirectory: URL = ClipboardHistoryStore.defaultBaseDirectory,
        pasteboard: NSPasteboard = .general,
        userDefaults: UserDefaults = .standard
    ) {
        self.baseDirectory = baseDirectory
        self.imagesDirectory = baseDirectory.appendingPathComponent("ClipboardImages", isDirectory: true)
        self.metadataURL = baseDirectory.appendingPathComponent("clipboard_history.json")
        self.pasteboard = pasteboard
        self.userDefaults = userDefaults

        // 설정 불러오기
        if let savedData = userDefaults.data(forKey: userDefaultsConfigKey),
           let decoded = try? JSONDecoder().decode(ClipboardHistoryConfig.self, from: savedData) {
            self.config = decoded
        } else {
            self.config = .default
        }

        thumbnailCache.countLimit = 200

        setupDirectories()
        loadMetadata()
    }

    // MARK: - Directory Setup
    private func setupDirectories() {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: imagesDirectory, withIntermediateDirectories: true, attributes: nil)
        } catch {
            NSLog("[ClipboardHistoryStore] 디렉터리 생성 실패: %@", error.localizedDescription)
        }
    }

    // MARK: - Lifecycle (Start / Stop)
    public func start() {
        guard !isMonitoring else { return }
        isMonitoring = true

        // 최신 보안 및 프라이버시 지침:
        // 앱 시작 시점에는 현재 클립보드 내용을 수집하지 않고, 오직 현재 changeCount만 기준점으로 기록함.
        // 이후 사용자가 새로 복사하는 시점부터 감시 시작.
        lastObservedChangeCount = pasteboard.changeCount

        // 1. 주기적 폴링 (0.5초)
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkForPasteboardChanges()
            }
        }

        // 2. 앱 전환 시 즉시 1회 확인
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkForPasteboardChanges()
            }
        }

        // 시작 시점 한도 집행 (과거 기간 만료 항목 정리)
        enforceLimits()
    }

    public func stop() {
        guard isMonitoring else { return }
        isMonitoring = false

        pollTimer?.invalidate()
        pollTimer = nil

        if let obs = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            workspaceObserver = nil
        }
    }

    // MARK: - Config Persistence
    private func saveConfig() {
        if let encoded = try? JSONEncoder().encode(config) {
            userDefaults.set(encoded, forKey: userDefaultsConfigKey)
        }
    }

    // MARK: - Pasteboard Polling
    internal func checkForPasteboardChanges() {
        let pasteboard = self.pasteboard
        let currentCount = pasteboard.changeCount

        guard currentCount != lastObservedChangeCount else { return }
        lastObservedChangeCount = currentCount

        // 자체 쓰기(한툴 패널에서 복사)에 의한 changeCount 변경은 히스토리에 다시 쌓지 않음
        if isSelfWriting {
            isSelfWriting = false
            return
        }

        // 민감 클립보드 체크 (패스워드 관리자, 일회용 등)
        if isSensitiveOrTransient(pasteboard: pasteboard) {
            return
        }

        // 내용 인입 시도
        ingestCurrentPasteboard(pasteboard: pasteboard)
    }

    /// 패스워드 매니저 또는 일회용 클립보드 표식 확인 (Best-effort 제외)
    private func isSensitiveOrTransient(pasteboard: NSPasteboard) -> Bool {
        guard let types = pasteboard.types else { return false }
        let sensitiveIdentifiers = [
            "org.nspasteboard.ConcealedType",
            "com.agilebits.onepassword",
            "de.petermaurer.TransientPasteboardType",
            "org.nspasteboard.AutoGeneratedType",
            "PasteboardType(\"org.nspasteboard.TransientType\")",
            "net.culater.mactower.Pinned"
        ]

        for t in types {
            let identifier = t.rawValue
            for s in sensitiveIdentifiers {
                if identifier.localizedCaseInsensitiveContains(s) {
                    return true
                }
            }
        }
        return false
    }

    /// 현재 클립보드 내용을 파싱하여 히스토리에 추가
    private func ingestCurrentPasteboard(pasteboard: NSPasteboard) {
        let sourceApp = NSWorkspace.shared.frontmostApplication
        let bundleID = sourceApp?.bundleIdentifier
        let appName = sourceApp?.localizedName

        // 1. 이미지 우선 확인 (TIFF 또는 PNG)
        if let imgData = readImageDataFromPasteboard(pasteboard) {
            handleImageIngestion(data: imgData, bundleID: bundleID, appName: appName)
            return
        }

        // 2. 텍스트 확인
        if let string = pasteboard.string(forType: .string), !string.isEmpty {
            handleTextIngestion(text: string, bundleID: bundleID, appName: appName)
            return
        }
    }

    private func readImageDataFromPasteboard(_ pasteboard: NSPasteboard) -> Data? {
        if let tiffData = pasteboard.data(forType: .tiff) {
            return tiffData
        }
        if let pngType = NSPasteboard.PasteboardType(UTType.png.identifier) as NSPasteboard.PasteboardType?,
           let pngData = pasteboard.data(forType: pngType) {
            return pngData
        }
        return nil
    }

    // MARK: - Ingestion Handlers
    private func handleTextIngestion(text: String, bundleID: String?, appName: String?) {
        let hash = sha256String(for: text.data(using: .utf8) ?? Data())

        // 중복 검사: 동일 해시가 이미 있으면 타임스탬프 갱신 후 맨 앞으로 이동
        if let existingIndex = items.firstIndex(where: { $0.type == .text && $0.sha256 == hash }) {
            var item = items.remove(at: existingIndex)
            item.copiedAt = Date()
            items.insert(item, at: 0)
            persistMetadataAtomic()
            return
        }

        let newItem = ClipboardItem(
            type: .text,
            textContent: text,
            sha256: hash,
            copiedAt: Date(),
            sourceAppBundleID: bundleID,
            sourceAppName: appName
        )

        items.insert(newItem, at: 0)
        enforceLimits()
        persistMetadataAtomic()
    }

    private func handleImageIngestion(data: Data, bundleID: String?, appName: String?) {
        let byteCount = Int64(data.count)

        // 1. 단일 이미지 용량 검사 (100MB 상한)
        guard byteCount <= maxSingleImageBytes else {
            NSLog("[ClipboardHistoryStore] 이미지 크기(%lld bytes)가 단일 상한을 초과하여 인입을 건너뜁니다.", byteCount)
            return
        }

        // 2. 전체 디코딩 전 메타데이터 사전 검사 (Metadata Preflight)
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil) else {
            return
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any] else {
            return
        }

        let pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let pixelHeight = properties[kCGImagePropertyPixelHeight] as? Int ?? 0

        // 디코딩 메모리 추정치: 폭 × 높이 × 4바이트 (RGBA)
        let estimatedDecodedBytes = Int64(pixelWidth) * Int64(pixelHeight) * 4
        guard estimatedDecodedBytes <= maxDecodedPixelsMemory else {
            NSLog("[ClipboardHistoryStore] 이미지 디코딩 메모리 추정치(%lld bytes)가 256MB를 초과하여 스킵합니다.", estimatedDecodedBytes)
            return
        }

        let hash = sha256String(for: data)

        // 중복 검사: 동일 해시의 이미지가 이미 존재하는 경우 타임스탬프 갱신 후 상단 이동
        if let existingIndex = items.firstIndex(where: { $0.type == .image && $0.sha256 == hash }) {
            var item = items.remove(at: existingIndex)
            item.copiedAt = Date()
            items.insert(item, at: 0)
            persistMetadataAtomic()
            return
        }

        // 이미지 파일 영속화 (앱 소유의 ClipboardImages 폴더에만 저장)
        let fileName = "\(UUID().uuidString).png"
        let fileURL = imagesDirectory.appendingPathComponent(fileName)

        // PNG로 변환하여 저장하거나 원본 바이트 저장
        var savedSuccessfully = false
        if let pngData = convertToPNGData(from: imageSource) {
            do {
                try pngData.write(to: fileURL, options: .atomic)
                savedSuccessfully = true
            } catch {
                NSLog("[ClipboardHistoryStore] 이미지 쓰기 실패: %@", error.localizedDescription)
            }
        } else {
            do {
                try data.write(to: fileURL, options: .atomic)
                savedSuccessfully = true
            } catch {
                NSLog("[ClipboardHistoryStore] 원본 이미지 쓰기 실패: %@", error.localizedDescription)
            }
        }

        guard savedSuccessfully else { return }

        let newItem = ClipboardItem(
            type: .image,
            imageFileName: fileName,
            imageWidth: pixelWidth,
            imageHeight: pixelHeight,
            fileSize: byteCount,
            sha256: hash,
            copiedAt: Date(),
            sourceAppBundleID: bundleID,
            sourceAppName: appName
        )

        items.insert(newItem, at: 0)
        enforceLimits()
        persistMetadataAtomic()
    }

    private func convertToPNGData(from source: CGImageSource) -> Data? {
        guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: - Re-Copy to System Pasteboard
    /// 선택한 항목을 시스템 클립보드에 복사하고 자체 쓰기 플래그를 설정하여 중복 인입 방지.
    public func copyToPasteboard(item: ClipboardItem) {
        isSelfWriting = true
        let pasteboard = self.pasteboard
        pasteboard.clearContents()

        switch item.type {
        case .text:
            if let text = item.textContent {
                pasteboard.setString(text, forType: .string)
            }
        case .image:
            if let fileName = item.imageFileName {
                let fileURL = imagesDirectory.appendingPathComponent(fileName)
                if let image = NSImage(contentsOf: fileURL) {
                    pasteboard.writeObjects([image])
                }
            }
        }

        lastObservedChangeCount = pasteboard.changeCount

        // 방금 복사한 항목을 최상단으로 이동
        if let idx = items.firstIndex(where: { $0.id == item.id }) {
            var updated = items.remove(at: idx)
            updated.copiedAt = Date()
            items.insert(updated, at: 0)
            persistMetadataAtomic()
        }
    }

    // MARK: - Image & Thumbnail Access
    public func imageURL(for item: ClipboardItem) -> URL? {
        guard item.type == .image, let fileName = item.imageFileName else { return nil }
        return imagesDirectory.appendingPathComponent(fileName)
    }

    /// 목록용 지연 로딩 다운샘플링 썸네일 (메모리 절약)
    public func loadThumbnail(for item: ClipboardItem) -> NSImage? {
        guard item.type == .image, let fileName = item.imageFileName else { return nil }
        let nsUUID = item.id as NSUUID
        if let cached = thumbnailCache.object(forKey: nsUUID) {
            return cached
        }

        let fileURL = imagesDirectory.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailMaxDimension,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]

        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let cgThumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        let thumb = NSImage(cgImage: cgThumb, size: NSSize(width: thumbnailMaxDimension, height: thumbnailMaxDimension))
        thumbnailCache.setObject(thumb, forKey: nsUUID)
        return thumb
    }

    // MARK: - Limits & Retention Enforcement
    public func enforceLimits() {
        var currentItems = items
        var removedItems: [ClipboardItem] = []

        // 1. 기간 만료 검사 (retentionDays > 0)
        if config.retentionDays > 0 {
            let cutoffDate = Calendar.current.date(byAdding: .day, value: -config.retentionDays, to: Date()) ?? Date.distantPast
            let expired = currentItems.filter { $0.copiedAt < cutoffDate }
            removedItems.append(contentsOf: expired)
            currentItems.removeAll { $0.copiedAt < cutoffDate }
        }

        // 2. 텍스트 개수 제한
        let textItems = currentItems.filter { $0.type == .text }
        if textItems.count > config.maxTextCount {
            let overflow = textItems.dropFirst(config.maxTextCount)
            let overflowIDs = Set(overflow.map { $0.id })
            removedItems.append(contentsOf: overflow)
            currentItems.removeAll { overflowIDs.contains($0.id) }
        }

        // 3. 이미지 개수 제한
        let imageItems = currentItems.filter { $0.type == .image }
        if imageItems.count > config.maxImageCount {
            let overflow = imageItems.dropFirst(config.maxImageCount)
            let overflowIDs = Set(overflow.map { $0.id })
            removedItems.append(contentsOf: overflow)
            currentItems.removeAll { overflowIDs.contains($0.id) }
        }

        // 4. 전체 디스크 용량 제한 (오래된 이미지부터 FIFO 정리)
        let maxBytes = Int64(config.maxDiskUsageMB) * 1024 * 1024
        var currentBytes: Int64 = currentItems.compactMap { $0.fileSize }.reduce(0, +)

        if currentBytes > maxBytes {
            // 오래된 이미지부터 역순으로 제거
            for it in currentItems.reversed() where it.type == .image {
                if currentBytes <= maxBytes { break }
                let sz = it.fileSize ?? 0
                currentBytes -= sz
                removedItems.append(it)
                currentItems.removeAll { $0.id == it.id }
            }
        }

        // 실제로 변경이 발생한 경우에만 적용
        if currentItems.count != items.count {
            let previousItems = items
            self.items = currentItems
            if persistMetadataAtomic() {
                cleanupFiles(for: removedItems)
            } else {
                self.items = previousItems
            }
        }
    }

    // MARK: - Safe Directory Root Verification
    /// 실제 앱 소유 baseDirectory 아래의 ClipboardImages 디렉터리인지 확인하고 symlink 탈출을 엄격히 차단한 정규화 루트 반환.
    private func safeImagesDirectoryRoot() -> URL? {
        let fm = FileManager.default

        // 1. baseDirectory 자체의 심볼릭 링크 검증
        if let baseIsSymlink = try? baseDirectory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink, baseIsSymlink {
            NSLog("[ClipboardHistoryStore] 안전 검사 실패: baseDirectory가 심볼릭 링크임 %@", baseDirectory.path)
            return nil
        }
        if (try? fm.destinationOfSymbolicLink(atPath: baseDirectory.path)) != nil {
            NSLog("[ClipboardHistoryStore] 안전 검사 실패: baseDirectory 심볼릭 링크 대상 감지 %@", baseDirectory.path)
            return nil
        }

        // 2. imagesDirectory 자체의 심볼릭 링크 검증
        if let imagesIsSymlink = try? imagesDirectory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink, imagesIsSymlink {
            NSLog("[ClipboardHistoryStore] 안전 검사 실패: imagesDirectory가 심볼릭 링크임 %@", imagesDirectory.path)
            return nil
        }
        if (try? fm.destinationOfSymbolicLink(atPath: imagesDirectory.path)) != nil {
            NSLog("[ClipboardHistoryStore] 안전 검사 실패: imagesDirectory 심볼릭 링크 대상 감지 %@", imagesDirectory.path)
            return nil
        }

        // 3. 실제 앱 소유 baseDirectory 아래의 ClipboardImages이고 symlink 탈출 아님을 엄격 확인
        let resolvedBase = baseDirectory.resolvingSymlinksInPath().standardizedFileURL
        let expectedImagesDir = resolvedBase.appendingPathComponent("ClipboardImages", isDirectory: true).standardizedFileURL
        let resolvedImagesDir = imagesDirectory.resolvingSymlinksInPath().standardizedFileURL

        guard resolvedImagesDir.path == expectedImagesDir.path else {
            NSLog("[ClipboardHistoryStore] 안전 검사 실패: imagesDirectory가 baseDirectory 경계를 벗어남 %@", resolvedImagesDir.path)
            return nil
        }
        guard resolvedImagesDir.deletingLastPathComponent().path == resolvedBase.path,
              resolvedImagesDir.lastPathComponent == "ClipboardImages" else {
            NSLog("[ClipboardHistoryStore] 안전 검사 실패: imagesDirectory 상위 경계 불일치")
            return nil
        }

        return resolvedImagesDir
    }

    // MARK: - File Cleanup Safety Rules
    /// 오직 앱 소유의 ClipboardImages 디렉터리 내부 파일만 삭제하며, 유효성 검사 필수.
    private func cleanupFiles(for itemsToClean: [ClipboardItem]) {
        guard let resolvedRoot = safeImagesDirectoryRoot() else {
            NSLog("[ClipboardHistoryStore] 안전 검사 실패: 유효하지 않은 imagesDirectory 루트")
            return
        }
        let fm = FileManager.default

        for item in itemsToClean {
            guard item.type == .image, let fileName = item.imageFileName else { continue }
            thumbnailCache.removeObject(forKey: item.id as NSUUID)

            // 파일 이름 기본 검증: 빈 값, 상위 경로 참조(..), 경로 구분자(/, \) 차단
            guard !fileName.isEmpty,
                  !fileName.contains("/"),
                  !fileName.contains("\\"),
                  fileName != ".",
                  fileName != ".." else {
                NSLog("[ClipboardHistoryStore] 안전 검사 실패: 신뢰할 수 없는 파일 이름 %@", fileName)
                continue
            }

            let targetURL = imagesDirectory.appendingPathComponent(fileName)

            // 심볼릭 링크 여부 검증 (링크 자체 또는 링크 대상을 통한 외부 삭제 차단)
            if let isSymlink = try? targetURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink, isSymlink {
                NSLog("[ClipboardHistoryStore] 안전 검사 실패: 심볼릭 링크 삭제 거부 %@", targetURL.path)
                continue
            }
            if (try? fm.destinationOfSymbolicLink(atPath: targetURL.path)) != nil {
                NSLog("[ClipboardHistoryStore] 안전 검사 실패: 심볼릭 링크 대상 확인됨 %@", targetURL.path)
                continue
            }

            // 실경로(resolved path) 디렉터리 경계 확인
            let resolvedTarget = targetURL.resolvingSymlinksInPath().standardizedFileURL
            guard resolvedTarget.deletingLastPathComponent().path == resolvedRoot.path,
                  resolvedTarget.lastPathComponent == fileName else {
                NSLog("[ClipboardHistoryStore] 안전 검사 실패: 디렉터리 경계 벗어남 %@", resolvedTarget.path)
                continue
            }

            if fm.fileExists(atPath: targetURL.path) {
                do {
                    try fm.removeItem(at: targetURL)
                } catch {
                    NSLog("[ClipboardHistoryStore] 이미지 파일 삭제 실패: %@", error.localizedDescription)
                }
            }
        }
    }

    /// 전체 히스토리 삭제 (시스템 클립보드는 절대 clear하지 않음).
    public func clearAllHistory() {
        let previousItems = items
        items.removeAll()
        if persistMetadataAtomic() {
            cleanupFiles(for: previousItems)
            thumbnailCache.removeAllObjects()
        } else {
            items = previousItems
        }
    }

    /// 단일 항목 삭제
    public func removeItem(id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items[idx]
        items.remove(at: idx)
        if persistMetadataAtomic() {
            cleanupFiles(for: [item])
        } else {
            items.insert(item, at: idx)
        }
    }

    // MARK: - Persistence (Atomic Generation Snapshots)
    @discardableResult
    private func persistMetadataAtomic() -> Bool {
        guard metadataLoadedSuccessfully else {
            NSLog("[ClipboardHistoryStore] 메타데이터 로드 실패 상태이므로 손상 파일 보존을 위해 저장 거부")
            return false
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601

        do {
            let data = try encoder.encode(items)
            try data.write(to: metadataURL, options: .atomic)
            return true
        } catch {
            NSLog("[ClipboardHistoryStore] 메타데이터 원자적 저장 실패: %@", error.localizedDescription)
            return false
        }
    }

    private func loadMetadata() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: metadataURL.path) else {
            metadataLoadedSuccessfully = true
            return
        }

        do {
            let data = try Data(contentsOf: metadataURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let loaded = try decoder.decode([ClipboardItem].self, from: data)
            self.items = loaded
            self.metadataLoadedSuccessfully = true
            // 유효 메타데이터 정상 로드 완료 후 고아 파일 청소 안전하게 수행
            cleanupOrphanFilesSafely()
        } catch {
            // 메타데이터 손상 시 절대 고아 파일을 삭제하지 않고 격리 보존
            metadataLoadedSuccessfully = false
            NSLog("[ClipboardHistoryStore] 메타데이터 로드 실패 (파일 보존됨): %@", error.localizedDescription)
        }
    }

    /// 고아 파일 정리 안전 규칙:
    /// 유효한 메타데이터가 정상 로드된 이후에만 수행하며, ClipboardImages 폴더 내의 미참조 파일만 정리.
    private func cleanupOrphanFilesSafely() {
        guard metadataLoadedSuccessfully else { return }
        guard let resolvedRoot = safeImagesDirectoryRoot() else {
            NSLog("[ClipboardHistoryStore] 안전 검사 실패: 유효하지 않은 imagesDirectory 루트")
            return
        }
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: imagesDirectory.path) else { return }

        let referencedFiles = Set(items.compactMap { $0.imageFileName })

        for file in files {
            if !referencedFiles.contains(file) {
                guard !file.isEmpty, !file.contains("/"), !file.contains("\\"), file != ".", file != ".." else { continue }
                let targetURL = imagesDirectory.appendingPathComponent(file)
                if let isSymlink = try? targetURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink, isSymlink { continue }
                if (try? fm.destinationOfSymbolicLink(atPath: targetURL.path)) != nil { continue }
                let resolvedTarget = targetURL.resolvingSymlinksInPath().standardizedFileURL
                guard resolvedTarget.deletingLastPathComponent().path == resolvedRoot.path,
                      resolvedTarget.lastPathComponent == file else { continue }
                try? fm.removeItem(at: targetURL)
            }
        }
    }

    // MARK: - Helpers
    private func sha256String(for data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
