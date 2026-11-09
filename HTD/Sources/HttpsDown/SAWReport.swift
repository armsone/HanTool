import Foundation
import WebKit

public enum SAWReport {
    public static func shouldCreate(goal: String, instructions: [String] = []) -> Bool {
        let negativeKeywords = ["보고서 만들지마", "보고서 만들지 마", "보고서 필요없", "보고서 없이", "no report"]
        for inst in instructions.reversed() {
            let lower = inst.lowercased()
            for neg in negativeKeywords {
                if lower.contains(neg) { return false }
            }
        }
        let lowerGoal = goal.lowercased()
        for neg in negativeKeywords {
            if lowerGoal.contains(neg) { return false }
        }

        let positiveKeywords = ["알아봐", "알아 봐", "조사", "리서치", "연구", "보고서", "뉴스", "research", "report", "news"]
        for inst in instructions {
            let lower = inst.lowercased()
            for pos in positiveKeywords {
                if lower.contains(pos) { return true }
            }
        }
        for pos in positiveKeywords {
            if lowerGoal.contains(pos) { return true }
        }
        return false
    }

    public static func requiresSources(goal: String, instructions: [String] = []) -> Bool {
        let negativeKeywords = ["보고서 만들지마", "보고서 만들지 마", "보고서 필요없", "보고서 없이", "no report"]
        for inst in instructions.reversed() {
            let lower = inst.lowercased()
            for neg in negativeKeywords {
                if lower.contains(neg) { return false }
            }
        }
        let lowerGoal = goal.lowercased()
        for neg in negativeKeywords {
            if lowerGoal.contains(neg) { return false }
        }

        let sourceKeywords = ["알아봐", "알아 봐", "조사", "리서치", "연구", "뉴스", "research", "news"]
        // Newest instruction wins: an explicit "no re-research" phrase only cancels its own
        // negative phrase; any remaining positive request in the same text is preserved.
        for inst in instructions.reversed() {
            let (stripped, hadNoRepeat) = stripNoRepeatResearch(inst.lowercased())
            for kw in sourceKeywords {
                if stripped.contains(kw) { return true }
            }
            if hadNoRepeat { return false }
        }
        let (strippedGoal, _) = stripNoRepeatResearch(lowerGoal)
        for kw in sourceKeywords {
            if strippedGoal.contains(kw) { return true }
        }
        return false
    }

    /// Removes only bounded trusted "do not research again" phrases so their "조사" substring
    /// is not mistaken for a positive request.
    private static func stripNoRepeatResearch(_ lower: String) -> (text: String, removed: Bool) {
        let patterns = [
            "재조사\\s*불필요",
            "재조사\\s*(?:가|는|도)?\\s*필요\\s*없(?:어요|어|다|고|음|습니다|요)?",
            "재조사\\s*하지\\s*(?:마|말)(?:세요|라|아|고|요)?"
        ]
        var text = lower
        var removed = false
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            if regex.firstMatch(in: text, range: range) != nil {
                removed = true
                text = regex.stringByReplacingMatches(in: text, range: range, withTemplate: " ")
            }
        }
        return (text, removed)
    }

    public static func baseReportsDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("HttpsDown", isDirectory: true)
            .appendingPathComponent("PlannerReports", isDirectory: true)
    }

    public static func projectReportsDirectory(projectID: UUID) -> URL {
        return baseReportsDirectory().appendingPathComponent(projectID.uuidString, isDirectory: true)
    }

    public static func isReportArtifact(_ artifact: SAWArtifact) -> Bool {
        guard artifact.filename.hasSuffix(".html") else { return false }
        let fileURLString = artifact.fileURL
        guard !fileURLString.isEmpty else { return false }

        let baseDir = baseReportsDirectory().standardizedFileURL
        let basePath = baseDir.path.hasSuffix("/") ? baseDir.path : baseDir.path + "/"
        let url = URL(fileURLWithPath: fileURLString).standardizedFileURL
        let path = url.path

        guard path.hasPrefix(basePath) else { return false }
        let relative = String(path.dropFirst(basePath.count))
        let components = relative.split(separator: "/")
        guard components.count == 2 else { return false }
        guard UUID(uuidString: String(components[0])) != nil else { return false }
        let filePart = String(components[1])
        guard filePart.hasSuffix(".html") else { return false }
        let uuidPart = String(filePart.dropLast(5))
        return UUID(uuidString: uuidPart) != nil
    }

    public static func validatedURL(_ artifact: SAWArtifact, projectID: UUID) -> URL? {
        guard isReportArtifact(artifact) else { return nil }
        let baseDir = baseReportsDirectory().standardizedFileURL
        let projectDir = projectReportsDirectory(projectID: projectID).standardizedFileURL
        let fileURL = URL(fileURLWithPath: artifact.fileURL).standardizedFileURL

        let fm = FileManager.default

        var isBaseDir: ObjCBool = false
        if fm.fileExists(atPath: baseDir.path, isDirectory: &isBaseDir) {
            guard isBaseDir.boolValue else { return nil }
            do {
                let attrs = try fm.attributesOfItem(atPath: baseDir.path)
                if let fileType = attrs[.type] as? FileAttributeType, fileType == .typeSymbolicLink || fileType != .typeDirectory {
                    return nil
                }
            } catch {
                return nil
            }
        }

        var isProjDir: ObjCBool = false
        guard fm.fileExists(atPath: projectDir.path, isDirectory: &isProjDir), isProjDir.boolValue else {
            return nil
        }
        do {
            let attrs = try fm.attributesOfItem(atPath: projectDir.path)
            if let fileType = attrs[.type] as? FileAttributeType, fileType == .typeSymbolicLink || fileType != .typeDirectory {
                return nil
            }
        } catch {
            return nil
        }

        guard fileURL.deletingLastPathComponent().path == projectDir.path else { return nil }
        guard projectDir.lastPathComponent == projectID.uuidString else { return nil }

        let resolvedURL = fileURL.resolvingSymlinksInPath()
        let resolvedProjectDir = projectDir.resolvingSymlinksInPath()
        guard resolvedURL.deletingLastPathComponent().path == resolvedProjectDir.path else { return nil }
        guard resolvedProjectDir.lastPathComponent == projectID.uuidString else { return nil }

        let filename = fileURL.lastPathComponent
        guard filename.hasSuffix(".html"), UUID(uuidString: String(filename.dropLast(5))) != nil else { return nil }
        guard resolvedURL.lastPathComponent == filename else { return nil }

        var isFileDir: ObjCBool = false
        guard fm.fileExists(atPath: fileURL.path, isDirectory: &isFileDir), !isFileDir.boolValue else {
            return nil
        }
        do {
            let attrs = try fm.attributesOfItem(atPath: fileURL.path)
            guard let fileType = attrs[.type] as? FileAttributeType, fileType == .typeRegular else {
                return nil
            }
        } catch {
            return nil
        }

        return resolvedURL
    }

    /// Bounded plain-text read of the `report-content` section of a report this app created.
    /// The caller must already have confirmed the artifact is registered by the user's selection.
    public static func referenceText(artifact: SAWArtifact, projectID: UUID) throws -> (text: String, isTruncated: Bool) {
        func fail(_ code: Int, _ message: String) -> NSError {
            NSError(domain: "SAWReport", code: code, userInfo: [NSLocalizedDescriptionKey: message])
        }
        guard let url = validatedURL(artifact, projectID: projectID) else {
            throw fail(20, "참고 보고서 파일 경로를 확인할 수 없습니다.")
        }
        let maxBytes = 1_048_576
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = (attrs[.size] as? NSNumber)?.intValue, size <= maxBytes else {
            throw fail(21, "참고 보고서가 읽을 수 있는 크기(1MB)를 넘었습니다.")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maxBytes + 1) ?? Data()
        guard data.count <= maxBytes else {
            throw fail(21, "참고 보고서가 읽을 수 있는 크기(1MB)를 넘었습니다.")
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw fail(22, "참고 보고서가 올바른 UTF-8 문서가 아닙니다.")
        }
        let openTag = "<div class=\"report-content\">"
        guard let open = html.range(of: openTag),
              let close = html.range(of: "</div>", range: open.upperBound..<html.endIndex) else {
            throw fail(23, "참고 보고서의 구조를 알 수 없습니다.")
        }
        let text = SAWReportContent.plainText(fromSafeHTML: String(html[open.upperBound..<close.lowerBound]))

        let limit = 4000
        guard text.utf16.count > limit else { return (text, false) }
        var end = text.utf16.index(text.utf16.startIndex, offsetBy: limit)
        while end > text.startIndex, end.samePosition(in: text) == nil {
            end = text.utf16.index(before: end)
        }
        return (String(text[..<end]), true)
    }

    public static func create(
        projectID: UUID,
        runID: UUID?,
        title: String,
        content: String,
        sourceURLs: [URL],
        evidenceAppendix: String? = nil
    ) throws -> SAWArtifact {
        let fm = FileManager.default
        let baseDir = baseReportsDirectory().standardizedFileURL
        let projectDir = projectReportsDirectory(projectID: projectID).standardizedFileURL

        var isBaseDir: ObjCBool = false
        if fm.fileExists(atPath: baseDir.path, isDirectory: &isBaseDir) {
            guard isBaseDir.boolValue else {
                throw NSError(domain: "SAWReport", code: 1, userInfo: [NSLocalizedDescriptionKey: "PlannerReports exists and is not a directory"])
            }
            let attrs = try fm.attributesOfItem(atPath: baseDir.path)
            if let fileType = attrs[.type] as? FileAttributeType, fileType == .typeSymbolicLink || fileType != .typeDirectory {
                throw NSError(domain: "SAWReport", code: 2, userInfo: [NSLocalizedDescriptionKey: "PlannerReports must not be a symbolic link"])
            }
        }

        var isProjDir: ObjCBool = false
        if fm.fileExists(atPath: projectDir.path, isDirectory: &isProjDir) {
            guard isProjDir.boolValue else {
                throw NSError(domain: "SAWReport", code: 3, userInfo: [NSLocalizedDescriptionKey: "Project directory exists and is not a directory"])
            }
            let attrs = try fm.attributesOfItem(atPath: projectDir.path)
            if let fileType = attrs[.type] as? FileAttributeType, fileType == .typeSymbolicLink || fileType != .typeDirectory {
                throw NSError(domain: "SAWReport", code: 4, userInfo: [NSLocalizedDescriptionKey: "Project directory must not be a symbolic link"])
            }
        }

        try fm.createDirectory(at: projectDir, withIntermediateDirectories: true, attributes: [
            FileAttributeKey.posixPermissions: 0o700
        ])

        let baseAttrsAfter = try fm.attributesOfItem(atPath: baseDir.path)
        if let fileType = baseAttrsAfter[.type] as? FileAttributeType, fileType == .typeSymbolicLink || fileType != .typeDirectory {
            throw NSError(domain: "SAWReport", code: 5, userInfo: [NSLocalizedDescriptionKey: "PlannerReports must not be a symbolic link"])
        }
        let projAttrsAfter = try fm.attributesOfItem(atPath: projectDir.path)
        if let fileType = projAttrsAfter[.type] as? FileAttributeType, fileType == .typeSymbolicLink || fileType != .typeDirectory {
            throw NSError(domain: "SAWReport", code: 6, userInfo: [NSLocalizedDescriptionKey: "Project directory must not be a symbolic link"])
        }

        let resolvedBase = baseDir.resolvingSymlinksInPath()
        let resolvedProj = projectDir.resolvingSymlinksInPath()
        guard resolvedProj.deletingLastPathComponent().path == resolvedBase.path,
              resolvedProj.lastPathComponent == projectID.uuidString else {
            throw NSError(domain: "SAWReport", code: 7, userInfo: [NSLocalizedDescriptionKey: "Project directory path escapes canonical base"])
        }

        let reportID = UUID()
        let filename = "\(reportID.uuidString).html"
        let fileURL = projectDir.appendingPathComponent(filename, isDirectory: false).standardizedFileURL
        guard fileURL.deletingLastPathComponent().path == projectDir.path else {
            throw NSError(domain: "SAWReport", code: 8, userInfo: [NSLocalizedDescriptionKey: "File target escapes project directory"])
        }

        var validURLs: [URL] = []
        var seenURLs = Set<String>()
        for url in sourceURLs {
            guard let scheme = url.scheme?.lowercased(), (scheme == "http" || scheme == "https"),
                  let host = url.host, !host.isEmpty,
                  url.user == nil, url.password == nil else {
                continue
            }
            let key = url.absoluteString
            if !seenURLs.contains(key) {
                seenURLs.insert(key)
                validURLs.append(url)
            }
        }

        let rendered = try SAWReportContent.render(content, appendix: evidenceAppendix)
        let htmlString = documentHTML(
            title: title.isEmpty ? "보고서" : title,
            bodyHTML: rendered.bodyHTML,
            sourceURLs: validURLs
        )
        let htmlData = Data(htmlString.utf8)
        let maxBytes = 1_048_576 // 1MiB limit
        if htmlData.count > maxBytes {
            throw NSError(
                domain: "SAWReport",
                code: 9,
                userInfo: [NSLocalizedDescriptionKey: "보고서가 저장 가능한 크기(1MB)를 넘었습니다. 전체 답변은 대화 기록에 보존됩니다."]
            )
        }

        try htmlData.write(to: fileURL, options: .withoutOverwriting)
        try fm.setAttributes([FileAttributeKey.posixPermissions: 0o600], ofItemAtPath: fileURL.path)

        return SAWArtifact(
            id: reportID,
            title: title.isEmpty ? "보고서" : title,
            filename: filename,
            fileURL: fileURL.path,
            format: "html",
            createdAt: Date(),
            byteCount: htmlData.count,
            runID: runID,
            contentDigest: nil
        )
    }

    /// Shared report document: `bodyHTML` must be `SAWReportContent` output. The footer lists only
    /// `sourceURLs` (the app's observed sources), never links found in the body.
    static func documentHTML(title: String, bodyHTML: String, sourceURLs: [URL]) -> String {
        var validURLs: [URL] = []
        var seenURLs = Set<String>()
        for url in sourceURLs {
            guard let scheme = url.scheme?.lowercased(), (scheme == "http" || scheme == "https"),
                  let host = url.host, !host.isEmpty,
                  url.user == nil, url.password == nil else {
                continue
            }
            if seenURLs.insert(url.absoluteString).inserted { validURLs.append(url) }
        }

        let escapeHTML = SAWReportContent.escape
        let escapedTitle = escapeHTML(title.isEmpty ? "보고서" : title)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy년 M월 d일 HH:mm"
        let koreanDateString = formatter.string(from: Date())

        let sourcesHTML: String
        if validURLs.isEmpty {
            sourcesHTML = "<div class=\"no-sources\">확인된 웹 출처 없음</div>"
        } else {
            var items: [String] = []
            for u in validURLs {
                let href = escapeHTML(u.absoluteString)
                let host = escapeHTML(u.host ?? u.absoluteString)
                items.append("<li><a href=\"\(href)\" target=\"_blank\" rel=\"noopener noreferrer\">\(host)</a> <span class=\"source-url\">(\(href))</span></li>")
            }
            sourcesHTML = "<ul class=\"sources-list\">" + items.joined() + "</ul>"
        }

        return """
<!DOCTYPE html>
<html lang="ko">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'none'; connect-src 'none'; img-src 'none'; style-src 'unsafe-inline'; form-action 'none'; base-uri 'none'; frame-src 'none';">
<title>\(escapedTitle)</title>
<style>
body {
    background-color: #ffffff;
    color: #111827;
    font-family: -apple-system, BlinkMacSystemFont, "Apple SD Gothic Neo", "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
    margin: 0;
    padding: 36px 24px;
    display: flex;
    justify-content: center;
}
.page-container {
    max-width: 900px;
    width: 100%;
}
h1 {
    font-size: 22px;
    font-weight: 700;
    margin: 0 0 8px 0;
    line-height: 1.35;
    color: #111827;
}
.meta-info {
    font-size: 13px;
    color: #6b7280;
    margin-bottom: 20px;
    padding-bottom: 12px;
    border-bottom: 1px solid #e5e7eb;
}
.notice-label {
    font-size: 12px;
    color: #9ca3af;
    margin-bottom: 24px;
}
.report-content {
    font-size: 15px;
    line-height: 1.75;
    word-break: break-word;
    color: #1f2937;
    margin-bottom: 36px;
}
.report-content h2 { font-size: 18px; line-height: 1.4; margin: 24px 0 8px; color: #111827; }
.report-content h3 { font-size: 16px; line-height: 1.4; margin: 20px 0 6px; color: #111827; }
.report-content h4 { font-size: 15px; line-height: 1.4; margin: 16px 0 6px; color: #111827; }
.report-content p { margin: 0 0 12px; }
.report-content ul, .report-content ol { margin: 0 0 12px; padding-left: 22px; }
.report-content li { margin-bottom: 4px; }
.report-content a { color: #2563eb; text-decoration: underline; }
.report-content table { display: block; max-width: 100%; overflow-x: auto; border-collapse: collapse; margin: 12px 0 18px; font-size: 14px; line-height: 1.55; }
.report-content th, .report-content td { border: 1px solid #d1d5db; padding: 8px 10px; text-align: left; vertical-align: top; min-width: 96px; }
.report-content th { background: #f3f4f6; font-weight: 600; color: #111827; }
.report-content code { font-family: ui-monospace, Menlo, monospace; font-size: 13px; background: #f3f4f6; padding: 1px 4px; border-radius: 3px; }
.report-content pre { background: #f3f4f6; padding: 12px; overflow-x: auto; white-space: pre; border-radius: 6px; margin: 0 0 12px; }
.report-content pre code { background: none; padding: 0; }
.sources-section {
    margin-top: 36px;
    padding-top: 18px;
    border-top: 1px solid #e5e7eb;
}
.sources-title {
    font-size: 14px;
    font-weight: 600;
    margin-bottom: 10px;
    color: #374151;
}
.sources-list {
    font-size: 13px;
    color: #4b5563;
    padding-left: 20px;
    margin: 0;
}
.sources-list li {
    margin-bottom: 6px;
}
.sources-list a {
    color: #2563eb;
    text-decoration: underline;
}
.source-url {
    color: #6b7280;
    font-size: 12px;
}
.no-sources {
    font-size: 13px;
    color: #6b7280;
    font-style: italic;
}
</style>
</head>
<body>
<div class="page-container">
    <h1>\(escapedTitle)</h1>
    <div class="meta-info">
        작성일시: \(koreanDateString)
    </div>
    <div class="notice-label">
        AI 작성 · 사실관계는 출처와 함께 확인해 주세요.
    </div>
    <div class="report-content">\(bodyHTML)</div>
    <div class="sources-section">
        <div class="sources-title">확인된 출처</div>
        \(sourcesHTML)
    </div>
</div>
</body>
</html>
"""
    }
}

@MainActor
extension SAWProjectSession {
    public func openReport(_ artifact: SAWArtifact) {
        guard let validated = SAWReport.validatedURL(artifact, projectID: projectID) else {
            workspace.store.appendChatMessage(
                projectID: projectID,
                message: SAWChatMessage(
                    sender: "assistant",
                    text: "보고서 파일을 열 수 없습니다.",
                    artifact: nil,
                    status: "error",
                    runID: artifact.runID
                )
            )
            return
        }
        if let matchingTab = tabs.first(where: { $0.currentURL == validated }) {
            selectedTabID = matchingTab.tabID
            _ = matchingTab.openPlannerReport(artifact)
            return
        }
        let tab = newTab(url: nil)
        let success = tab.openPlannerReport(artifact)
        if !success {
            workspace.store.appendChatMessage(
                projectID: projectID,
                message: SAWChatMessage(
                    sender: "assistant",
                    text: "보고서 열기에 실패했습니다.",
                    artifact: nil,
                    status: "error",
                    runID: artifact.runID
                )
            )
        }
    }

    func observedReportSourceURLs(runID: UUID?) -> [URL] {
        var collectedURLs: [URL] = []
        var seen = Set<String>()

        do {
            for (urlStr, _) in reportObservedSources {
                if let url = URL(string: urlStr),
                   let scheme = url.scheme?.lowercased(), (scheme == "http" || scheme == "https"),
                   let host = url.host, !host.isEmpty,
                   url.user == nil, url.password == nil {
                    if !seen.contains(url.absoluteString) {
                        seen.insert(url.absoluteString)
                        collectedURLs.append(url)
                    }
                }
            }
        }

        if let assignments = project?.teamAssignments {
            for assignment in assignments {
                if assignment.runID == runID && assignment.status == .completed && assignment.result?.error == nil {
                    if let sources = assignment.result?.sourceURLs {
                        for urlStr in sources {
                            if let url = URL(string: urlStr),
                               let scheme = url.scheme?.lowercased(), (scheme == "http" || scheme == "https"),
                               let host = url.host, !host.isEmpty,
                               url.user == nil, url.password == nil {
                                if !seen.contains(url.absoluteString) {
                                    seen.insert(url.absoluteString)
                                    collectedURLs.append(url)
                                }
                            }
                        }
                    }
                }
            }
        }

        return collectedURLs
    }

    public func createCompletionReport(
        summary: String,
        goal: String,
        instructions: [String],
        runID: UUID?
    ) -> SAWArtifact? {
        guard SAWReport.shouldCreate(goal: goal, instructions: instructions) else {
            return nil
        }

        let collectedURLs = observedReportSourceURLs(runID: runID)

        let storedTitle = project?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let isDefaultPlaceholder = (storedTitle == "새 프로젝트" || storedTitle == "새프로젝트")
        let reportTitle: String
        if !storedTitle.isEmpty && !isDefaultPlaceholder {
            reportTitle = storedTitle
        } else {
            let firstNonEmptyGoalLine = (project?.goal ?? "")
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
            if let goalLine = firstNonEmptyGoalLine, !goalLine.isEmpty {
                reportTitle = String(goalLine.prefix(60)) + " 보고서"
            } else {
                reportTitle = "업무 보고서"
            }
        }

        do {
            let artifact = try SAWReport.create(
                projectID: projectID,
                runID: runID,
                title: reportTitle,
                content: summary,
                sourceURLs: collectedURLs
            )
            workspace.store.appendArtifact(projectID: projectID, artifact: artifact)
            openReport(artifact)
            return artifact
        } catch {
            if let proj = project,
               !proj.conversation.contains(where: { $0.runID == runID && $0.text == summary }) {
                workspace.store.appendChatMessage(
                    projectID: projectID,
                    message: SAWChatMessage(
                        sender: "assistant",
                        text: summary,
                        status: "waiting",
                        runID: runID
                    )
                )
            }
            let errorMsg = "보고서 파일 저장 중 오류가 발생했습니다: \(error.localizedDescription)"
            workspace.store.appendChatMessage(
                projectID: projectID,
                message: SAWChatMessage(
                    sender: "assistant",
                    text: errorMsg,
                    artifact: nil,
                    status: "error",
                    runID: runID
                )
            )
            return nil
        }
    }
}
