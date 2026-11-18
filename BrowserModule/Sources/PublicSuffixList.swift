import CryptoKit
import Foundation

/// The Public Suffix List (https://publicsuffix.org, MPL-2.0), used to find where one operator's names end and another's
/// begin: `co.kr` (ICANN section) and `github.io` / `surge.sh` / `*.compute.amazonaws.com` (PRIVATE section, shared
/// hosting) are suffixes, so `example.co.kr` and `alice.github.io` are registrable domains but `co.kr` and `github.io`
/// themselves are not.
///
/// The bundled file `Resources/public_suffix_list.dat` is the official list, byte for byte, pinned by SHA-256. Every
/// failure answers "not known" (nil), and callers treat nil as "not allowed": a missing, altered or unparsable list, a
/// host whose TLD has no rule in the list (the list's implicit `*` fallback is deliberately NOT applied), an IP literal,
/// a single label, and a host that is itself a public suffix.
///
/// To update: replace the file with a fresh download of https://publicsuffix.org/list/public_suffix_list.dat, set
/// `bundledSHA256` to its `shasum -a 256`, and record the new VERSION in THIRD-PARTY-NOTICES.txt.
public struct PublicSuffixList {
    /// SHA-256 of the bundled list (VERSION 2026-11-17_16-14-34_UTC, COMMIT 09c1b150f33c6145a73afcf7db0fb872fc54b4d1).
    static let bundledSHA256 = "809adae1a2cb1621b70165c11e0d14412d3f104f40a4ebed9a99e23c54f78d71"
    /// The real list has ~10 000 rules; far fewer means a truncated file even if its hash were somehow updated.
    private static let minimumBundledRuleCount = 8000

    private let exact: Set<String>
    private let wildcardParents: Set<String>
    private let exceptions: Set<String>
    let ruleCount: Int

    /// The list shipped in the app bundle, or nil when it is missing, altered (hash mismatch) or does not parse.
    public static let bundled: PublicSuffixList? = {
        guard let url = Bundle.main.url(forResource: "public_suffix_list", withExtension: "dat"),
              let data = try? Data(contentsOf: url) else { return nil }
        return verified(data: data, expectedSHA256: bundledSHA256)
    }()

    static func verified(data: Data, expectedSHA256: String) -> PublicSuffixList? {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == expectedSHA256, let list = PublicSuffixList(data: data),
              list.ruleCount >= minimumBundledRuleCount else { return nil }
        return list
    }

    /// Parses list text. Nil for anything malformed (strictness is the point: a half-read list must not be used).
    init?(data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var exact = Set<String>(), wildcardParents = Set<String>(), exceptions = Set<String>()
        var sections: [String] = []
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("//") {
                if line.contains("===BEGIN ICANN DOMAINS===") { sections.append("BI") }
                if line.contains("===END ICANN DOMAINS===") { sections.append("EI") }
                if line.contains("===BEGIN PRIVATE DOMAINS===") { sections.append("BP") }
                if line.contains("===END PRIVATE DOMAINS===") { sections.append("EP") }
                continue
            }
            // A rule is the text up to the first whitespace (the list format allows trailing commentary).
            var rule = String(line.split(whereSeparator: { $0 == " " || $0 == "\t" })[0]).lowercased()
            var isException = false, isWildcard = false
            if rule.hasPrefix("!") { isException = true; rule.removeFirst() }
            else if rule.hasPrefix("*.") { isWildcard = true; rule.removeFirst(2) }
            guard !rule.isEmpty else { return nil }
            var labels: [String] = []
            for label in rule.split(separator: ".", omittingEmptySubsequences: false) {
                guard !label.isEmpty, !label.contains("*"), !label.contains("!"),
                      let ascii = Self.asciiLabel(String(label)) else { return nil }
                labels.append(ascii)
            }
            let normalized = labels.joined(separator: ".")
            if isException {
                guard labels.count >= 2 else { return nil }
                exceptions.insert(normalized)
            } else if isWildcard {
                wildcardParents.insert(normalized)
            } else {
                exact.insert(normalized)
            }
        }
        // Both sections, each opened and closed, in order: a truncated download lacks the end markers.
        guard sections == ["BI", "EI", "BP", "EP"], !exact.isEmpty else { return nil }
        self.exact = exact
        self.wildcardParents = wildcardParents
        self.exceptions = exceptions
        self.ruleCount = exact.count + wildcardParents.count + exceptions.count
    }

    /// The registrable domain (public suffix plus exactly one label, "eTLD+1") of an ASCII host, or nil when the host is
    /// malformed, an IP literal, has no explicit rule in the list (unknown TLD), or is itself a public suffix.
    public func registrableDomain(ofHost rawHost: String) -> String? {
        guard let labels = Self.validatedLabels(rawHost) else { return nil }
        let count = labels.count
        func joined(from index: Int) -> String { labels[index...].joined(separator: ".") }

        // An exception rule (`!www.ck`) always prevails and makes its own name registrable: suffix = rule minus 1 label.
        for index in 0..<count where exceptions.contains(joined(from: index)) {
            return joined(from: index)
        }
        // Otherwise the matching rule with the most labels prevails. Scanning from the longest candidate, the first
        // hit is it. `*.x` matches any name one label longer than `x`.
        var suffixLength = 0
        for index in 0..<count {
            if exact.contains(joined(from: index)) || (index + 1 < count && wildcardParents.contains(joined(from: index + 1))) {
                suffixLength = count - index
                break
            }
        }
        guard suffixLength > 0, count > suffixLength else { return nil }   // no rule (unknown TLD), or a bare suffix
        return joined(from: count - suffixLength - 1)
    }

    /// Lowercase ASCII LDH host split into labels, or nil. No trailing dot, port, brackets, user info or non-ASCII.
    static func validatedLabels(_ host: String) -> [String]? {
        guard !host.isEmpty, host.utf8.count <= 253, host == host.lowercased() else { return nil }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard labels.count >= 1 else { return nil }
        for label in labels {
            guard (1...63).contains(label.utf8.count), !label.hasPrefix("-"), !label.hasSuffix("-"),
                  label.utf8.allSatisfy({ ($0 >= 0x61 && $0 <= 0x7a) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2d || $0 == 0x5f })
            else { return nil }
        }
        return labels
    }

    /// A host with every non-ASCII label converted to punycode; nil when a label is empty or cannot be converted.
    static func asciiHost(_ host: String) -> String? {
        var labels: [String] = []
        for label in host.split(separator: ".", omittingEmptySubsequences: false) {
            guard let ascii = asciiLabel(String(label)) else { return nil }
            labels.append(ascii)
        }
        return labels.joined(separator: ".")
    }

    /// A list label as it appears in a punycode (ASCII) host: non-ASCII labels (e.g. 한국) become `xn--…` (RFC 3492).
    static func asciiLabel(_ label: String) -> String? {
        let scalars = label.unicodeScalars.map { $0.value }
        guard !scalars.isEmpty else { return nil }
        if scalars.allSatisfy({ $0 < 0x80 }) { return label }

        let base: UInt32 = 36, tMin: UInt32 = 1, tMax: UInt32 = 26
        func digit(_ value: UInt32) -> Character {
            Character(UnicodeScalar(value < 26 ? 0x61 + value : 0x30 + (value - 26))!)
        }
        func adapt(_ delta: UInt32, _ points: UInt32, _ first: Bool) -> UInt32 {
            var delta = first ? delta / 700 : delta / 2
            delta += delta / points
            var k: UInt32 = 0
            while delta > ((base - tMin) * tMax) / 2 { delta /= base - tMin; k += base }
            return k + (base - tMin + 1) * delta / (delta + 38)
        }

        var output = String(scalars.filter { $0 < 0x80 }.map { Character(UnicodeScalar($0)!) })
        let basicCount = UInt32(output.count)
        var handled = basicCount
        if basicCount > 0 { output.append("-") }
        var n: UInt32 = 0x80, delta: UInt32 = 0, bias: UInt32 = 72
        while handled < UInt32(scalars.count) {
            guard let next = scalars.filter({ $0 >= n }).min() else { return nil }
            let (step, overflow1) = (next - n).multipliedReportingOverflow(by: handled + 1)
            let (grown, overflow2) = delta.addingReportingOverflow(step)
            guard !overflow1, !overflow2 else { return nil }
            delta = grown
            n = next
            for scalar in scalars {
                if scalar < n {
                    guard delta < UInt32.max else { return nil }
                    delta += 1
                } else if scalar == n {
                    var q = delta, k = base
                    while true {
                        let t = k <= bias ? tMin : (k >= bias + tMax ? tMax : k - bias)
                        if q < t { break }
                        output.append(digit(t + (q - t) % (base - t)))
                        q = (q - t) / (base - t)
                        k += base
                    }
                    output.append(digit(q))
                    bias = adapt(delta, handled + 1, handled == basicCount)
                    delta = 0
                    handled += 1
                }
            }
            delta += 1
            n += 1
        }
        return "xn--" + output
    }
}
