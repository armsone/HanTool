import Foundation

/// Deterministic, bounded, Foundation-only renderer for model-written report bodies.
///
/// Input (Markdown subset, legacy block HTML, or plain text) is parsed into a small block model and
/// rebuilt with a fixed set of canonical tags. Incoming tags/attributes are never passed through;
/// only validated absolute http(s) hrefs survive. Supported subset: headings, paragraphs, flat lists,
/// pipe/HTML tables, http(s) links (incl. bare URLs), bold, inline code and code blocks.
enum SAWReportContent {
    static let maxBytes = 1_048_576
    /// Table limits (padded grid): at most 1000 rows, 64 columns and 10000 expanded cells.
    static let maxTableRows = 1_000
    static let maxTableColumns = 64
    static let maxTableCells = 10_000

    struct Rendered: Equatable {
        var bodyHTML: String
        var plainText: String
    }

    struct RenderError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Renders `source` (markup allowed) plus an optional app-written plain-text `appendix`.
    static func render(_ source: String, appendix: String? = nil) throws -> Rendered {
        var total = source.utf8.count
        if let appendix { total += appendix.utf8.count }
        guard total <= maxBytes else {
            throw RenderError(message: "보고서 내용이 변환 가능한 크기(1MB)를 넘었습니다.")
        }
        let clean = sanitize(source)
        let bytes = Array(clean.utf8)
        var blocks: [Block]
        if looksLikeHTML(bytes) {
            blocks = try parseHTML(bytes)
        } else {
            blocks = parseMarkdown(clean)
        }
        if let appendix { blocks += plainBlocks(sanitize(appendix)) }
        return try emit(blocks)
    }

    /// Readable plain text of a fragment produced by `render` (or an old escaped pre-wrap body).
    /// Never fetches anything; table cells, lines, list items and link URLs keep their boundaries.
    static func plainText(fromSafeHTML html: String) -> String {
        let b = Array(html.utf8)
        var out = ""
        var label = ""
        var linkHref: String?
        var i = 0
        var textStart = 0
        func flush(_ end: Int) {
            guard end > textStart else { return }
            let t = decodeEntities(String(decoding: b[textStart..<end], as: UTF8.self))
            out += t
            if linkHref != nil { label += t }
        }
        while i < b.count {
            guard b[i] == 0x3C, i + 1 < b.count, isAlpha(b[i + 1]) || b[i + 1] == 0x2F,
                  let end = tagEnd(b, from: i + 1, limit: 4096) else { i += 1; continue }
            flush(i)
            var p = i + 1
            let closing = b[p] == 0x2F
            if closing { p += 1 }
            let ns = p
            while p < end, isAlnum(b[p]) { p += 1 }
            let name = String(decoding: b[ns..<p], as: UTF8.self).lowercased()
            switch name {
            case "br": out += "\n"
            case "li": out += closing ? "\n" : "- "
            case "p", "h2", "h3", "h4", "pre": if closing { out += "\n\n" }
            case "ul", "ol", "table": if closing { out += "\n" }
            case "td", "th": if closing { out += " | " }
            case "tr":
                if closing {
                    if out.hasSuffix(" | ") { out.removeLast(3) }
                    out += "\n"
                }
            case "a":
                if closing {
                    if let h = linkHref, label != h { out += " (\(h))" }
                    linkHref = nil
                } else {
                    linkHref = attributeValue(b, from: p, to: end, name: "href")
                    label = ""
                }
            default: break
            }
            i = end + 1
            textStart = i
        }
        flush(b.count)
        return out.trimmingCharacters(in: .newlines)
    }

    // MARK: - Model

    private struct Span {
        var text: String
        var href: String? = nil
        var code = false
        var bold = false
    }

    private struct Cell {
        var spans: [Span]
        var header: Bool
    }

    private enum Block {
        case heading(Int, [Span])
        case paragraph([Span])
        case list(ordered: Bool, items: [[Span]])
        case table([[Cell]])
        case code(String)
    }

    // MARK: - Emit

    private static func emit(_ blocks: [Block]) throws -> Rendered {
        var html = ""
        var text = ""
        for block in blocks {
            switch block {
            case .heading(let level, let spans):
                let tag = level <= 2 ? "h2" : (level == 3 ? "h3" : "h4")
                html += "<\(tag)>\(inlineHTML(spans))</\(tag)>\n"
                text += inlineText(spans) + "\n\n"
            case .paragraph(let spans):
                html += "<p>\(inlineHTML(spans))</p>\n"
                text += inlineText(spans) + "\n\n"
            case .list(let ordered, let items):
                let tag = ordered ? "ol" : "ul"
                html += "<\(tag)>\n"
                for (n, item) in items.enumerated() {
                    html += "<li>\(inlineHTML(item))</li>\n"
                    text += (ordered ? "\(n + 1). " : "- ") + inlineText(item).replacingOccurrences(of: "\n", with: " ") + "\n"
                }
                html += "</\(tag)>\n"
                text += "\n"
            case .table(let rows):
                let width = rows.map { $0.count }.max() ?? 0
                // Preflight before any padding: rows * width is checked by division, never multiplied.
                guard rows.count <= maxTableRows, width <= maxTableColumns,
                      width == 0 || rows.count <= maxTableCells / width else {
                    throw RenderError(message: "표가 변환 가능한 크기(최대 \(maxTableRows)행, \(maxTableColumns)열, \(maxTableCells)칸)를 넘었습니다.")
                }
                var textBytes = text.utf8.count
                html += "<table>\n"
                for (r, row) in rows.enumerated() {
                    html += "<tr>"
                    var cells: [String] = []
                    for c in 0..<width {
                        let cell = c < row.count ? row[c] : Cell(spans: [], header: false)
                        let inner = inlineHTML(cell.spans)
                        html += cell.header ? "<th scope=\"\(r == 0 ? "col" : "row")\">\(inner)</th>" : "<td>\(inner)</td>"
                        let cellText = inlineText(cell.spans).replacingOccurrences(of: "\n", with: " ")
                        cells.append(cellText)
                        // Byte budget per cell; plain text is built from the same cells, so bound it too.
                        textBytes += cellText.utf8.count
                        guard html.utf8.count <= maxBytes, textBytes <= maxBytes else {
                            throw RenderError(message: "변환된 보고서가 저장 가능한 크기(1MB)를 넘었습니다.")
                        }
                    }
                    html += "</tr>\n"
                    text += "| " + cells.joined(separator: " | ") + " |\n"
                    if r == 0, row.contains(where: { $0.header }) {
                        text += "| " + [String](repeating: "---", count: width).joined(separator: " | ") + " |\n"
                    }
                }
                html += "</table>\n"
                text += "\n"
            case .code(let code):
                html += "<pre><code>\(escape(code))</code></pre>\n"
                text += "```\n\(code)\n```\n\n"
            }
            guard html.utf8.count <= maxBytes else {
                throw RenderError(message: "변환된 보고서가 저장 가능한 크기(1MB)를 넘었습니다.")
            }
        }
        return Rendered(bodyHTML: html, plainText: text.trimmingCharacters(in: .newlines))
    }

    private static func inlineHTML(_ spans: [Span]) -> String {
        var out = ""
        for s in spans {
            var piece = s.text.components(separatedBy: "\n").map(escape).joined(separator: "<br>")
            if s.code { piece = "<code>\(piece)</code>" }
            if s.bold { piece = "<strong>\(piece)</strong>" }
            if let h = s.href {
                piece = "<a href=\"\(escape(h))\" target=\"_blank\" rel=\"noopener noreferrer\">\(piece)</a>"
            }
            out += piece
        }
        return out
    }

    private static func inlineText(_ spans: [Span]) -> String {
        var out = ""
        for s in spans {
            out += s.text
            if let h = s.href, s.text != h { out += " (\(h))" }
        }
        return out
    }

    static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for ch in s.unicodeScalars {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.unicodeScalars.append(ch)
            }
        }
        return out
    }

    /// Drops control characters other than tab/newline (CR becomes newline).
    private static func sanitize(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        var prevCR = false
        for ch in s.unicodeScalars {
            if ch == "\r" { out.append("\n"); prevCR = true; continue }
            defer { prevCR = false }
            if ch == "\n" && prevCR { continue }
            if (ch.value < 0x20 && ch != "\n" && ch != "\t") || ch.value == 0x7F { continue }
            out.append(ch)
        }
        return String(out)
    }

    // MARK: - Markdown / plain text

    private static let blockTags: Set<String> = [
        "h1", "h2", "h3", "h4", "h5", "h6", "p", "div", "ul", "ol", "li", "table", "tr", "td", "th",
        "pre", "html", "body", "head", "style", "script", "blockquote", "hr", "thead", "tbody"
    ]

    /// True when the line at `from` (after indentation) opens/closes a ``` or ~~~ fence.
    private static func isFenceLine(_ b: [UInt8], _ from: Int) -> UInt8? {
        var j = from
        while j < b.count, b[j] == 0x20 || b[j] == 0x09 { j += 1 }
        guard j + 2 < b.count, b[j] == 0x60 || b[j] == 0x7E, b[j + 1] == b[j], b[j + 2] == b[j] else { return nil }
        return b[j]
    }

    /// Block tags count only outside Markdown code (fenced blocks and inline backtick spans).
    private static func looksLikeHTML(_ b: [UInt8]) -> Bool {
        var i = 0
        var lineStart = true
        while i < b.count {
            if lineStart {
                lineStart = false
                if let fence = isFenceLine(b, i) {
                    // Skip the opening line, then everything up to and including the closing fence line.
                    while i < b.count, b[i] != 0x0A { i += 1 }
                    while i < b.count {
                        i += 1
                        if isFenceLine(b, i) == fence { break }
                        while i < b.count, b[i] != 0x0A { i += 1 }
                    }
                    while i < b.count, b[i] != 0x0A { i += 1 }
                    lineStart = true
                    continue
                }
            }
            if b[i] == 0x0A { lineStart = true; i += 1; continue }
            if b[i] == 0x60 {
                var k = i + 1
                while k < b.count, b[k] != 0x60, b[k] != 0x0A { k += 1 }
                i = (k < b.count && b[k] == 0x60) ? k + 1 : i + 1
                continue
            }
            if b[i] == 0x3C {
                var j = i + 1
                if j < b.count, b[j] == 0x2F { j += 1 }
                let s = j
                while j < b.count, j - s < 12, isAlnum(b[j]) { j += 1 }
                if j > s, blockTags.contains(String(decoding: b[s..<j], as: UTF8.self).lowercased()) { return true }
            }
            i += 1
        }
        return false
    }

    private static func plainBlocks(_ s: String) -> [Block] {
        var blocks: [Block] = []
        var para: [Span] = []
        func flush() {
            if !para.isEmpty { blocks.append(.paragraph(para)); para = [] }
        }
        for line in s.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { flush(); continue }
            if !para.isEmpty { para.append(Span(text: "\n")) }
            para.append(Span(text: line))
        }
        flush()
        return blocks
    }

    private static func parseMarkdown(_ source: String) -> [Block] {
        let lines = source.components(separatedBy: "\n")
        var blocks: [Block] = []
        var para: [String] = []
        func flushPara() {
            guard !para.isEmpty else { return }
            var spans: [Span] = []
            for (n, l) in para.enumerated() {
                if n > 0 { spans.append(Span(text: "\n")) }
                spans += inline(l)
            }
            para = []
            blocks.append(.paragraph(spans))
        }
        var i = 0
        while i < lines.count {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if t.isEmpty { flushPara(); i += 1; continue }
            if t.hasPrefix("```") || t.hasPrefix("~~~") {
                flushPara()
                let fence = String(t.prefix(3))
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[i])
                    i += 1
                }
                i += 1
                blocks.append(.code(code.joined(separator: "\n")))
                continue
            }
            if let (level, text) = heading(t) {
                flushPara()
                blocks.append(.heading(level, inline(text)))
                i += 1
                continue
            }
            if isRule(t) { flushPara(); i += 1; continue }
            if t.contains("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                flushPara()
                var rows: [[Cell]] = [splitRow(t).map { Cell(spans: inline($0), header: true) }]
                i += 2
                while i < lines.count {
                    let r = lines[i].trimmingCharacters(in: .whitespaces)
                    if r.isEmpty || !r.contains("|") { break }
                    rows.append(splitRow(r).map { Cell(spans: inline($0), header: false) })
                    i += 1
                }
                blocks.append(.table(rows))
                continue
            }
            if let first = listItem(t) {
                flushPara()
                var items = [inline(first.text)]
                i += 1
                while i < lines.count {
                    let raw = lines[i]
                    let rt = raw.trimmingCharacters(in: .whitespaces)
                    if rt.isEmpty { break }
                    if let next = listItem(rt) {
                        items.append(inline(next.text))
                    } else if raw.hasPrefix(" ") || raw.hasPrefix("\t"), heading(rt) == nil, !rt.hasPrefix("```") {
                        items[items.count - 1] += [Span(text: " ")] + inline(rt)
                    } else {
                        break
                    }
                    i += 1
                }
                blocks.append(.list(ordered: first.ordered, items: items))
                continue
            }
            var p = t
            if p.hasPrefix(">") { p = String(p.dropFirst()).trimmingCharacters(in: .whitespaces) }
            para.append(p)
            i += 1
        }
        flushPara()
        return blocks
    }

    private static func heading(_ t: String) -> (Int, String)? {
        let hashes = t.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count) else { return nil }
        let rest = t.dropFirst(hashes.count)
        guard rest.first == " " else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("#") { text.removeLast() }
        text = text.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : (hashes.count, text)
    }

    private static func isRule(_ t: String) -> Bool {
        let chars = t.filter { $0 != " " }
        guard chars.count >= 3, let f = chars.first, "-*_".contains(f) else { return false }
        return chars.allSatisfy { $0 == f }
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.contains("-") && t.allSatisfy { "|:- ".contains($0) }
    }

    private static func splitRow(_ line: String) -> [String] {
        var s = line
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|"), !s.hasSuffix("\\|") { s.removeLast() }
        var cells: [String] = []
        var cur = ""
        var esc = false
        for ch in s {
            if esc {
                if ch != "|" { cur.append("\\") }
                cur.append(ch)
                esc = false
            } else if ch == "\\" {
                esc = true
            } else if ch == "|" {
                cells.append(cur.trimmingCharacters(in: .whitespaces))
                cur = ""
            } else {
                cur.append(ch)
            }
        }
        if esc { cur.append("\\") }
        cells.append(cur.trimmingCharacters(in: .whitespaces))
        return cells
    }

    private static func listItem(_ t: String) -> (ordered: Bool, text: String)? {
        guard let f = t.first else { return nil }
        if "-*+".contains(f), t.dropFirst().first == " " {
            return (false, t.dropFirst().trimmingCharacters(in: .whitespaces))
        }
        let digits = t.prefix { $0.isASCII && $0.isNumber }
        guard (1...9).contains(digits.count) else { return nil }
        let rest = t.dropFirst(digits.count)
        guard let m = rest.first, m == "." || m == ")", rest.dropFirst().first == " " else { return nil }
        return (true, rest.dropFirst().trimmingCharacters(in: .whitespaces))
    }

    private static func inline(_ s: String) -> [Span] {
        let u = Array(s.unicodeScalars)
        var spans: [Span] = []
        var buf = String.UnicodeScalarView()
        var bold = false
        func flush() {
            if !buf.isEmpty { spans.append(Span(text: String(buf), bold: bold)); buf = String.UnicodeScalarView() }
        }
        let escapable = "\\`*[]()|#<>_-.!~+"
        var i = 0
        while i < u.count {
            let c = u[i]
            if c == "\\", i + 1 < u.count, escapable.unicodeScalars.contains(u[i + 1]) {
                buf.append(u[i + 1]); i += 2; continue
            }
            if c == "`", let j = u[(i + 1)...].firstIndex(of: "`"), j > i + 1 {
                flush()
                spans.append(Span(text: String(String.UnicodeScalarView(u[(i + 1)..<j])), code: true))
                i = j + 1; continue
            }
            if c == "*", i + 1 < u.count, u[i + 1] == "*" {
                flush(); bold.toggle(); i += 2; continue
            }
            if c == "<", let n = brLength(u, i) {
                flush(); spans.append(Span(text: "\n")); i += n; continue
            }
            if c == "[", let close = labelEnd(u, i), close + 1 < u.count, u[close + 1] == "(",
               let end = urlEnd(u, close + 2) {
                let label = String(String.UnicodeScalarView(u[(i + 1)..<close]))
                let rawURL = String(String.UnicodeScalarView(u[(close + 2)..<end]))
                let url = rawURL.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
                flush()
                if let href = safeHref(url) {
                    spans.append(Span(text: label.isEmpty ? url : label, href: href, bold: bold))
                } else if !label.isEmpty {
                    spans.append(Span(text: label, bold: bold))
                }
                i = end + 1; continue
            }
            if (c == "h" || c == "H"), i == 0 || !isAlnumScalar(u[i - 1]), hasPrefixCI(u, i, "http://") || hasPrefixCI(u, i, "https://") {
                var j = i
                while j < u.count, j - i < 2048, !isURLStop(u[j]) { j += 1 }
                var end = j
                while end > i, ".,;:!?)]}'".unicodeScalars.contains(u[end - 1]) { end -= 1 }
                let url = String(String.UnicodeScalarView(u[i..<end]))
                if let href = safeHref(url) {
                    flush()
                    spans.append(Span(text: url, href: href, bold: bold))
                    i = end
                } else {
                    buf.append(contentsOf: u[i..<j])
                    i = j
                }
                continue
            }
            buf.append(c)
            i += 1
        }
        flush()
        return spans
    }

    private static func labelEnd(_ u: [Unicode.Scalar], _ i: Int) -> Int? {
        var j = i + 1
        let lim = min(u.count, i + 201)
        while j < lim {
            if u[j] == "]" { return j }
            if u[j] == "[" { return nil }
            j += 1
        }
        return nil
    }

    private static func urlEnd(_ u: [Unicode.Scalar], _ k: Int) -> Int? {
        var j = k
        let lim = min(u.count, k + 2049)
        while j < lim {
            if u[j] == ")" { return j }
            j += 1
        }
        return nil
    }

    private static func brLength(_ u: [Unicode.Scalar], _ i: Int) -> Int? {
        for p in ["<br>", "<br/>", "<br />"] where hasPrefixCI(u, i, p) { return p.count }
        return nil
    }

    private static func hasPrefixCI(_ u: [Unicode.Scalar], _ i: Int, _ p: String) -> Bool {
        var j = i
        for ch in p.unicodeScalars {
            guard j < u.count else { return false }
            let a = u[j].value
            let lower = (a >= 65 && a <= 90) ? a + 32 : a
            if lower != ch.value { return false }
            j += 1
        }
        return true
    }

    private static func isURLStop(_ s: Unicode.Scalar) -> Bool {
        s.value <= 0x20 || s == "<" || s == ">" || s == "\"" || s == "`" || s == "\\"
    }

    private static func isAlnumScalar(_ s: Unicode.Scalar) -> Bool {
        s.isASCII && (s.properties.isAlphabetic || (s.value >= 48 && s.value <= 57))
    }

    // MARK: - Legacy HTML

    private static let suppressedTags: Set<String> = [
        "script", "style", "head", "title", "noscript", "template", "iframe", "object", "embed", "svg",
        "math", "applet", "canvas", "audio", "video", "xmp", "noembed"
    ]

    private static func parseHTML(_ b: [UInt8]) throws -> [Block] {
        let builder = HTMLBuilder()
        let n = b.count
        var i = 0
        var textStart = 0
        var failures = 0
        func flushText(_ end: Int) {
            if end > textStart {
                builder.addText(decodeEntities(String(decoding: b[textStart..<end], as: UTF8.self)))
            }
        }
        while i < n {
            guard b[i] == 0x3C, i + 1 < n else { i += 1; continue }
            if hasPrefix(b, i, "<!--") {
                flushText(i)
                i = find(b, "-->", from: i + 4).map { $0 + 3 } ?? n
                textStart = i
                continue
            }
            let c1 = b[i + 1]
            guard isAlpha(c1) || c1 == 0x21 || c1 == 0x3F || (c1 == 0x2F && i + 2 < n && isAlpha(b[i + 2])) else {
                i += 1; continue
            }
            guard let end = tagEnd(b, from: i + 1, limit: 4096) else {
                failures += 1
                if failures > 64 {
                    throw RenderError(message: "보고서 마크업이 비정상적으로 복잡하여 변환할 수 없습니다.")
                }
                i += 1; continue
            }
            flushText(i)
            let start = i
            i = end + 1
            textStart = i
            if c1 == 0x21 || c1 == 0x3F { continue }
            var p = start + 1
            let closing = b[p] == 0x2F
            if closing { p += 1 }
            let ns = p
            while p < end, isAlnum(b[p]) { p += 1 }
            let name = String(decoding: b[ns..<p], as: UTF8.self).lowercased()
            if suppressedTags.contains(name) {
                if !closing, b[end - 1] != 0x2F {
                    if let e = find(b, "</" + name, from: i) {
                        i = (find(b, ">", from: e).map { $0 + 1 }) ?? n
                    } else {
                        i = n
                    }
                    textStart = i
                }
                continue
            }
            let href = (name == "a" && !closing) ? attributeValue(b, from: p, to: end, name: "href") : nil
            builder.handle(name: name, closing: closing, rawHref: href)
        }
        flushText(n)
        return builder.finish()
    }

    private final class HTMLBuilder {
        enum Mode { case flow, heading(Int), item, cell }

        var blocks: [Block] = []
        var spans: [Span] = []
        var mode = Mode.flow
        var href: String?
        var codeDepth = 0
        var boldDepth = 0
        var inPre = false
        var preText = ""
        var listDepth = 0
        var listOrdered = false
        var items: [[Span]] = []
        var table: [[Cell]]?
        var tableDepth = 0
        var row: [Cell]?
        var cellHeader = false

        var inCell: Bool { if case .cell = mode { return true }; return false }
        var inHeading: Bool { if case .heading = mode { return true }; return false }
        var inItem: Bool { if case .item = mode { return true }; return false }

        func addText(_ t: String) {
            if inPre { preText += t; return }
            var out = ""
            var lastSpace = spans.last?.text.last?.isWhitespace ?? true
            for ch in t {
                if ch.isWhitespace {
                    if !lastSpace { out.append(" "); lastSpace = true }
                } else {
                    out.append(ch); lastSpace = false
                }
            }
            if !out.isEmpty {
                spans.append(Span(text: out, href: href, code: codeDepth > 0, bold: boldDepth > 0))
            }
        }

        func emitParagraph() {
            if listDepth > 0 { flushList() }
            let t = SAWReportContent.trim(spans)
            spans = []
            if !t.isEmpty { blocks.append(.paragraph(t)) }
        }

        func boundary() {
            if case .flow = mode { emitParagraph(); return }
            if let last = spans.last, !(last.text.last?.isWhitespace ?? true) { spans.append(Span(text: " ")) }
        }

        func closeHeading() {
            if case .heading(let n) = mode {
                let t = SAWReportContent.trim(spans)
                if !t.isEmpty { blocks.append(.heading(n, t)) }
                spans = []
                mode = .flow
            }
        }

        func endItem() {
            guard inItem else { return }
            let t = SAWReportContent.trim(spans)
            spans = []
            mode = .flow
            if !t.isEmpty { items.append(t) }
        }

        func flushList() {
            if !items.isEmpty { blocks.append(.list(ordered: listOrdered, items: items)); items = [] }
        }

        func closeLists() {
            endItem()
            flushList()
            listDepth = 0
        }

        func endCell() {
            guard inCell else { return }
            let t = SAWReportContent.trim(spans)
            spans = []
            mode = .flow
            row?.append(Cell(spans: t, header: cellHeader))
        }

        func endRow() {
            endCell()
            if let r = row, !r.isEmpty { table?.append(r) }
            row = nil
        }

        /// Closes whatever block is open; returns false when inside a table cell (treated as a break).
        func startBlock() -> Bool {
            if inCell { boundary(); return false }
            closeHeading()
            closeLists()
            emitParagraph()
            return true
        }

        func handle(name: String, closing: Bool, rawHref: String?) {
            if inPre {
                if name == "pre" && closing {
                    inPre = false
                    var code = preText
                    if code.hasPrefix("\n") { code.removeFirst() }
                    while code.hasSuffix("\n") { code.removeLast() }
                    blocks.append(.code(code))
                    preText = ""
                } else if name == "br" {
                    preText += "\n"
                }
                return
            }
            switch name {
            case "h1", "h2", "h3", "h4", "h5", "h6":
                if closing {
                    if inHeading { closeHeading() } else { boundary() }
                } else if startBlock() {
                    mode = .heading(Int(name.dropFirst()) ?? 2)
                }
            case "p", "div", "blockquote", "section", "article":
                boundary()
            case "ul", "ol":
                if inCell || inHeading { boundary(); return }
                if closing {
                    if listDepth > 0 {
                        listDepth -= 1
                        endItem()
                        if listDepth == 0 { flushList() }
                    }
                } else if listDepth == 0 {
                    closeHeading()
                    emitParagraph()
                    listOrdered = name == "ol"
                    listDepth = 1
                } else {
                    endItem()
                    listDepth += 1
                }
            case "li":
                if inCell {
                    boundary()
                    if !closing { spans.append(Span(text: "• ")) }
                } else if inHeading {
                    boundary()
                } else if closing {
                    endItem()
                } else {
                    endItem()
                    if listDepth == 0 { emitParagraph(); listDepth = 1; listOrdered = false }
                    mode = .item
                }
            case "table":
                if !closing {
                    tableDepth += 1
                    if tableDepth == 1, startBlock() { table = [] }
                } else if tableDepth > 0 {
                    tableDepth -= 1
                    if tableDepth == 0 {
                        endRow()
                        if let rows = table, !rows.isEmpty { blocks.append(.table(rows)) }
                        table = nil
                    }
                }
            case "tr":
                guard table != nil else { boundary(); return }
                endRow()
                if !closing { row = [] }
            case "td", "th":
                guard table != nil else { boundary(); return }
                endCell()
                if !closing {
                    if row == nil { row = [] }
                    cellHeader = name == "th"
                    mode = .cell
                }
            case "pre":
                if !closing, startBlock() { inPre = true; preText = "" }
            case "code":
                codeDepth = closing ? max(0, codeDepth - 1) : codeDepth + 1
            case "strong", "b":
                boldDepth = closing ? max(0, boldDepth - 1) : boldDepth + 1
            case "a":
                href = closing ? nil : rawHref.flatMap { SAWReportContent.safeHref($0) }
            case "br":
                if inHeading { boundary() } else { spans.append(Span(text: "\n")) }
            case "hr":
                _ = startBlock()
            default:
                break
            }
        }

        func finish() -> [Block] {
            if inPre {
                inPre = false
                blocks.append(.code(preText))
            }
            if table != nil {
                endRow()
                if let rows = table, !rows.isEmpty { blocks.append(.table(rows)) }
                table = nil
            }
            closeHeading()
            closeLists()
            emitParagraph()
            return blocks
        }
    }

    private static func trim(_ spans: [Span]) -> [Span] {
        guard let a = spans.firstIndex(where: { !$0.text.allSatisfy { $0.isWhitespace } }),
              let z = spans.lastIndex(where: { !$0.text.allSatisfy { $0.isWhitespace } }) else { return [] }
        var s = Array(spans[a...z])
        s[0].text = String(s[0].text.drop(while: { $0.isWhitespace }))
        let l = s.count - 1
        while s[l].text.last?.isWhitespace == true { s[l].text.removeLast() }
        return s
    }

    // MARK: - Shared scanning helpers

    /// Strict absolute http(s) URL with host, no credentials or control characters; nil otherwise.
    static func safeHref(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.utf8.count <= 2048,
              !t.unicodeScalars.contains(where: { $0.value <= 0x20 || ($0.value >= 0x7F && $0.value <= 0x9F) || $0 == "\\" }) else {
            return nil
        }
        let lower = t.lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://"),
              let comps = URLComponents(string: t),
              let scheme = comps.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = comps.host, !host.isEmpty,
              comps.user == nil, comps.password == nil,
              let url = comps.url else { return nil }
        return url.absoluteString
    }

    static func decodeEntities(_ s: String) -> String {
        guard s.utf8.contains(0x26) else { return s }
        let u = Array(s.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        while i < u.count {
            if u[i] == "&" {
                var j = i + 1
                let lim = min(u.count, i + 12)
                while j < lim, u[j] != ";", u[j] != "&" { j += 1 }
                if j < lim, u[j] == ";", let d = entity(String(String.UnicodeScalarView(u[(i + 1)..<j]))) {
                    out.append(d)
                    i = j + 1
                    continue
                }
            }
            out.append(u[i])
            i += 1
        }
        return String(out)
    }

    private static func entity(_ name: String) -> Unicode.Scalar? {
        switch name {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        case "nbsp": return "\u{00A0}"
        default: break
        }
        guard name.hasPrefix("#"), name.count > 1 else { return nil }
        let body = name.dropFirst()
        let value: UInt32?
        if body.hasPrefix("x") || body.hasPrefix("X") {
            value = UInt32(body.dropFirst(), radix: 16)
        } else {
            value = UInt32(body, radix: 10)
        }
        guard let v = value, let scalar = Unicode.Scalar(v),
              v >= 0x20 || v == 0x09 || v == 0x0A, v != 0x7F else { return nil }
        return scalar
    }

    private static func tagEnd(_ b: [UInt8], from: Int, limit: Int) -> Int? {
        var quote: UInt8 = 0
        var j = from
        let stop = min(b.count, from + limit)
        while j < stop {
            let c = b[j]
            if quote != 0 {
                if c == quote { quote = 0 }
            } else if c == 0x22 || c == 0x27 {
                quote = c
            } else if c == 0x3E {
                return j
            }
            j += 1
        }
        return nil
    }

    private static func attributeValue(_ b: [UInt8], from: Int, to: Int, name: String) -> String? {
        var p = from
        func isWS(_ c: UInt8) -> Bool { c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0x0C }
        while p < to {
            while p < to, isWS(b[p]) || b[p] == 0x2F { p += 1 }
            let s = p
            while p < to, !isWS(b[p]), b[p] != 0x3D, b[p] != 0x2F { p += 1 }
            if p == s { p += 1; continue }
            let attr = String(decoding: b[s..<p], as: UTF8.self).lowercased()
            while p < to, isWS(b[p]) { p += 1 }
            var value = ""
            if p < to, b[p] == 0x3D {
                p += 1
                while p < to, isWS(b[p]) { p += 1 }
                if p < to, b[p] == 0x22 || b[p] == 0x27 {
                    let q = b[p]
                    p += 1
                    let vs = p
                    while p < to, b[p] != q { p += 1 }
                    value = String(decoding: b[vs..<p], as: UTF8.self)
                    if p < to { p += 1 }
                } else {
                    let vs = p
                    while p < to, !isWS(b[p]) { p += 1 }
                    value = String(decoding: b[vs..<p], as: UTF8.self)
                }
            }
            if attr == name { return decodeEntities(value) }
        }
        return nil
    }

    private static func hasPrefix(_ b: [UInt8], _ i: Int, _ p: String) -> Bool {
        let pb = Array(p.utf8)
        guard i + pb.count <= b.count else { return false }
        for k in 0..<pb.count where b[i + k] != pb[k] { return false }
        return true
    }

    /// Case-insensitive search for an ASCII-lowercase pattern.
    private static func find(_ b: [UInt8], _ p: String, from: Int) -> Int? {
        let pb = Array(p.utf8)
        guard !pb.isEmpty, b.count >= pb.count, from <= b.count - pb.count else { return nil }
        var i = from
        while i <= b.count - pb.count {
            var k = 0
            while k < pb.count {
                let c = b[i + k]
                let lower = (c >= 65 && c <= 90) ? c + 32 : c
                if lower != pb[k] { break }
                k += 1
            }
            if k == pb.count { return i }
            i += 1
        }
        return nil
    }

    private static func isAlpha(_ c: UInt8) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) }
    private static func isAlnum(_ c: UInt8) -> Bool { isAlpha(c) || (c >= 48 && c <= 57) }
}
