import AppKit
import Foundation

/// Handles parsing address bar input for Hana companion commands.
enum HanaAddressCommand {
    private static let existingPrefixes: Set<String> = [
        "하나",
        "하나야",
        "하냐야",
        "하나씨"
    ]

    private static let freshPrefixes: Set<String> = [
        "새하나",
        "새대화"
    ]

    /// Matches exact bare command `하나 새창` (trimmed NFC and whitespace folded).
    /// Kept strictly as the only route to the external Hana companion window.
    static func isExternalWindowCommand(_ raw: String) -> Bool {
        AddressText.fold(raw) == "하나 새창"
    }

    /// Matches the first whitespace-delimited token against Hana reserved keywords.
    /// Trailing comma immediately after the token (e.g. `새대화,`) is supported.
    /// Returns (question, fresh) if matched, or nil.
    static func parse(_ raw: String) -> (question: String, fresh: Bool)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Exact match for standalone "브리핑" (equivalent to "하나 브리핑")
        let normalizedTrimmed = trimmed.precomposedStringWithCanonicalMapping
        if normalizedTrimmed == "브리핑" {
            return (question: "브리핑", fresh: false)
        }

        // Find the first token (whitespace-delimited)
        let words = AddressText.words(trimmed)
        guard let firstWord = words.first else { return nil }

        var token = firstWord.word.precomposedStringWithCanonicalMapping
        if token.hasSuffix(",") && token.count > 1 {
            token.removeLast()
            token = token.precomposedStringWithCanonicalMapping
        }

        let isExisting = existingPrefixes.contains(token)
        let isFresh = freshPrefixes.contains(token)

        guard isExisting || isFresh else { return nil }

        // Remainder after the first word range
        let remainderStartIndex = firstWord.range.upperBound
        let question = String(trimmed[remainderStartIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)

        return (question: question, fresh: isFresh)
    }
}
