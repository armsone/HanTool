import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - URL Drop Validation

public enum URLDropValidator {
    public static let maxDropURLs = 10
    public static let maxURLLength = 4096
    /// Validates an individual URL string according to HttpsDown ingestion rules:
    /// - Only http or https scheme (reject file, javascript, data, blob, etc.)
    /// - Must have a valid non-empty host (no spaces, length bounded)
    /// - Reject credential-bearing links (userinfo / password)
    /// - Reject ambiguous/plain text containing unencoded whitespace or newlines
    public static func validateSingleURL(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxURLLength else { return nil }

        // Refuse strings with spaces or tabs (ambiguous text or sentences)
        guard !trimmed.contains(" ") && !trimmed.contains("\t") else { return nil }
        guard !trimmed.contains("\n") && !trimmed.contains("\r") else { return nil }

        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              !url.isFileURL else { return nil }

        guard let host = url.host, !host.isEmpty, host.count <= 253 else { return nil }

        // Reject credential-bearing links
        if url.user != nil || url.password != nil { return nil }
        if let comps = URLComponents(string: trimmed), (comps.user != nil || comps.password != nil) {
            return nil
        }

        return trimmed
    }

    /// Parses a candidate text string which might contain one or multiple URLs separated by newlines.
    /// If the text contains any non-URL words or sentences (plain paragraph), it refuses the entire string.
    public static func parseCandidateText(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxURLLength * 2 else { return [] }

        let lines = trimmed.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else { return [] }

        var result: [String] = []
        for line in lines {
            guard let valid = validateSingleURL(line) else {
                // If any non-empty line is not a valid URL, treat as arbitrary text/paragraph and refuse
                return []
            }
            result.append(valid)
            if result.count >= maxDropURLs { break }
        }
        return result
    }
}

// MARK: - URL Drop Handler

public enum URLDropHandler {
    /// Loads candidate URLs from item providers, deduplicates them while preserving stable order,
    /// bounds item count, and enqueues valid jobs or posts nonmodal feedback.
    public static func handleDrop(providers: [NSItemProvider], appModel: AppModel) -> Bool {
        guard !providers.isEmpty else { return false }

        let eligibleProviders = Array(providers.prefix(URLDropValidator.maxDropURLs))
        var canHandle = false
        for provider in eligibleProviders {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                continue
            }
            if provider.canLoadObject(ofClass: URL.self) || provider.canLoadObject(ofClass: String.self) {
                canHandle = true
                break
            }
        }

        guard canHandle else {
            DispatchQueue.main.async {
                appModel.setDropFeedback("유효한 웹 주소(http/https)만 추가할 수 있습니다.")
            }
            return true
        }

        let group = DispatchGroup()
        let lock = NSLock()
        var extractedItems: [(index: Int, candidates: [String])] = []
        var rejectedCount = 0

        for (index, provider) in eligibleProviders.enumerated() {
            // Explicitly filter out local files and standalone image items
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                lock.lock()
                rejectedCount += 1
                lock.unlock()
                continue
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) &&
               !provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                lock.lock()
                rejectedCount += 1
                lock.unlock()
                continue
            }

            group.enter()
            if provider.canLoadObject(ofClass: URL.self) {
                _ = provider.loadObject(ofClass: URL.self) { object, _ in
                    var handled = false
                    if let url = object as? URL, !url.isFileURL {
                        // Never trust metadata.title as URL: extract only absoluteString
                        if let valid = URLDropValidator.validateSingleURL(url.absoluteString) {
                            lock.lock()
                            extractedItems.append((index: index, candidates: [valid]))
                            lock.unlock()
                            handled = true
                        }
                    }
                    if !handled && provider.canLoadObject(ofClass: String.self) {
                        _ = provider.loadObject(ofClass: String.self) { strObj, _ in
                            if let str = strObj as? String {
                                let urls = URLDropValidator.parseCandidateText(str)
                                lock.lock()
                                if !urls.isEmpty {
                                    extractedItems.append((index: index, candidates: urls))
                                } else {
                                    rejectedCount += 1
                                }
                                lock.unlock()
                            } else {
                                lock.lock()
                                rejectedCount += 1
                                lock.unlock()
                            }
                            group.leave()
                        }
                    } else {
                        if !handled {
                            lock.lock()
                            rejectedCount += 1
                            lock.unlock()
                        }
                        group.leave()
                    }
                }
            } else if provider.canLoadObject(ofClass: String.self) {
                _ = provider.loadObject(ofClass: String.self) { object, _ in
                    if let str = object as? String {
                        let urls = URLDropValidator.parseCandidateText(str)
                        lock.lock()
                        if !urls.isEmpty {
                            extractedItems.append((index: index, candidates: urls))
                        } else {
                            rejectedCount += 1
                        }
                        lock.unlock()
                    } else {
                        lock.lock()
                        rejectedCount += 1
                        lock.unlock()
                    }
                    group.leave()
                }
            } else {
                lock.lock()
                rejectedCount += 1
                lock.unlock()
                group.leave()
            }
        }

        group.notify(queue: .main) {
            MainActor.assumeIsolated {
            extractedItems.sort { $0.index < $1.index }
            var uniqueURLs: [String] = []
            var seen = Set<String>()

            for item in extractedItems {
                for url in item.candidates {
                    if !seen.contains(url) {
                        seen.insert(url)
                        uniqueURLs.append(url)
                    }
                    if uniqueURLs.count >= URLDropValidator.maxDropURLs { break }
                }
                if uniqueURLs.count >= URLDropValidator.maxDropURLs { break }
            }

            if !uniqueURLs.isEmpty {
                appModel.addJobs(from: uniqueURLs)
                if rejectedCount > 0 || uniqueURLs.count < providers.count {
                    appModel.setDropFeedback("일부 주소 또는 지원하지 않는 항목은 제외되었습니다.")
                }
            } else {
                appModel.setDropFeedback("유효한 웹 주소(http/https)만 추가할 수 있습니다.")
            }
            }
        }

        return true
    }
}

// MARK: - ViewModifier & View Extension

public struct URLDropTargetModifier: ViewModifier {
    @ObservedObject var appModel: AppModel
    @State private var isTargeted = false
    @Environment(\.bkPalette) private var palette

    public init(appModel: AppModel) {
        self.appModel = appModel
    }

    public func body(content: Content) -> some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(palette.accentColor, lineWidth: isTargeted ? 2 : 0)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(palette.accentSoftColor.opacity(isTargeted ? 0.25 : 0))
                    )
                    .allowsHitTesting(false)
                    .animation(.easeInOut(duration: 0.15), value: isTargeted)
            )
            .accessibilityElement(children: .contain)
            .accessibilityLabel("웹 주소를 끌어다 놓아 분석 시작")
            .onDrop(of: [UTType.url, UTType.utf8PlainText, UTType.plainText], isTargeted: $isTargeted) { providers in
                return URLDropHandler.handleDrop(providers: providers, appModel: appModel)
            }
    }
}

public extension View {
    func urlDropTarget(appModel: AppModel) -> some View {
        modifier(URLDropTargetModifier(appModel: appModel))
    }
}
