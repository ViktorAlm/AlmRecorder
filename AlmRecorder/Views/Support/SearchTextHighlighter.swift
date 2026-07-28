import AppKit
import Foundation
import SwiftUI

enum SearchTextHighlighter {
    static func attributedString(
        _ text: String,
        query: String,
        highlightColor: NSColor = NSColor.systemYellow.withAlphaComponent(0.32)
    ) -> AttributedString {
        let result = NSMutableAttributedString(string: text)
        let terms = searchableTerms(in: query)
        guard !terms.isEmpty, !text.isEmpty else {
            return AttributedString(result)
        }

        let pattern = terms
            .sorted { $0.count > $1.count }
            .map(NSRegularExpression.escapedPattern(for:))
            .joined(separator: "|")
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else {
            return AttributedString(result)
        }

        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        for match in expression.matches(in: text, range: fullRange) {
            result.addAttribute(.backgroundColor, value: highlightColor, range: match.range)
            result.addAttribute(
                .font,
                value: NSFont.systemFont(
                    ofSize: NSFont.systemFontSize,
                    weight: .semibold
                ),
                range: match.range
            )
        }
        return AttributedString(result)
    }

    static func searchableTerms(in query: String) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let tokens = trimmed
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        var terms: [String] = tokens
        if tokens.count > 1 {
            terms.append(trimmed)
        }

        var seen: Set<String> = []
        return terms.filter {
            let normalized = $0.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
            return seen.insert(normalized).inserted
        }
    }
}
