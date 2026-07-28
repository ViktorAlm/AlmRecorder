import Foundation

struct RealtimeTranscriptAssembler {
    private(set) var committed = ""
    private(set) var provisional = ""

    var displayText: String {
        [committed, provisional]
            .filter { !$0.isEmpty }
            .joined(separator: committed.isEmpty || provisional.hasPrefix(" ") ? "" : " ")
    }

    mutating func updateProvisional(_ text: String) {
        provisional = text
    }

    @discardableResult
    mutating func commit(_ text: String) -> String {
        let incoming = text.trimmingCharacters(in: .whitespacesAndNewlines)
        provisional = ""
        guard !incoming.isEmpty else { return committed }
        guard !committed.isEmpty else {
            committed = incoming
            return committed
        }

        let existingWords = Self.words(in: committed)
        let incomingWords = Self.words(in: incoming)
        let maximum = min(12, existingWords.count, incomingWords.count)
        var overlap = 0
        if maximum > 0 {
            for count in stride(from: maximum, through: 1, by: -1) {
                let suffix = existingWords.suffix(count).map(Self.normalized)
                let prefix = incomingWords.prefix(count).map(Self.normalized)
                if suffix == prefix, count >= 2 || suffix.first?.count ?? 0 >= 5 {
                    overlap = count
                    break
                }
            }
        }

        let remainder = incomingWords.dropFirst(overlap).joined(separator: " ")
        if !remainder.isEmpty {
            committed += Self.needsSpace(before: remainder, after: committed) ? " \(remainder)" : remainder
        }
        return committed
    }

    private static func words(in text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private static func normalized(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: .punctuationCharacters)
    }

    private static func needsSpace(before incoming: String, after existing: String) -> Bool {
        guard let first = incoming.first, let last = existing.last else { return false }
        if ".,!?;:)]}".contains(first) { return false }
        if "([{\"".contains(last) { return false }
        return true
    }
}
