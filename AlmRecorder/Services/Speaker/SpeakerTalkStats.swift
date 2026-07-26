import Foundation

/// Pure "talking style" statistics for one speaker, computed from the utterance slice of the
/// recordings they appear in (all speakers' utterances of those recordings, hidden lines
/// excluded by the caller). No database access — fully testable.
enum SpeakerTalkStats {

    struct Utterance {
        let recordingId: Int64
        let speakerUuid: String?
        let start: TimeInterval
        let end: TimeInterval
        let text: String
    }

    struct SignatureWord: Equatable {
        let word: String
        let count: Int
        /// How many times more often than everyone else in the same recordings (smoothed).
        /// When the speaker is always alone this is just their count.
        let ratio: Double
    }

    struct Monologue: Equatable {
        let recordingId: Int64
        let duration: TimeInterval
        let words: Int
    }

    struct Stats: Equatable {
        let wordsPerMinute: Double?
        let avgWordShare: Double?   // 0…1, averaged over the recordings they speak in
        let avgTimeShare: Double?   // 0…1, vs all speech (not silence) in those recordings
        let vocabularySize: Int
        let longestMonologue: Monologue?
        let signatureWords: [SignatureWord]
    }

    static func compute(for uuid: String, in utterances: [Utterance],
                        signatureLimit: Int = 5, minSignatureCount: Int = 4) -> Stats {
        let tokens: [[String]] = utterances.map { tokenize($0.text) }

        // One pass: totals, per-recording aggregates, and word frequencies.
        struct RecAgg {
            var myWords = 0, allWords = 0
            var myTime: TimeInterval = 0, allTime: TimeInterval = 0
            var spokeHere = false
        }
        var recs: [Int64: RecAgg] = [:]
        var myFreq: [String: Int] = [:]
        var otherFreq: [String: Int] = [:]
        var myWordCount = 0, otherWordCount = 0
        var myDuration: TimeInterval = 0

        for (u, words) in zip(utterances, tokens) {
            let duration = max(0, u.end - u.start)
            var agg = recs[u.recordingId] ?? RecAgg()
            agg.allWords += words.count
            agg.allTime += duration
            if u.speakerUuid == uuid {
                agg.myWords += words.count
                agg.myTime += duration
                agg.spokeHere = true
                myWordCount += words.count
                myDuration += duration
                for w in words { myFreq[w, default: 0] += 1 }
            } else {
                otherWordCount += words.count
                for w in words { otherFreq[w, default: 0] += 1 }
            }
            recs[u.recordingId] = agg
        }

        let wordsPerMinute: Double? = (myDuration > 0 && myWordCount > 0)
            ? Double(myWordCount) / (myDuration / 60)
            : nil

        // Shares: averaged per recording they actually spoke in.
        var wordShares: [Double] = []
        var timeShares: [Double] = []
        for agg in recs.values where agg.spokeHere {
            if agg.allWords > 0 { wordShares.append(Double(agg.myWords) / Double(agg.allWords)) }
            if agg.allTime > 0 { timeShares.append(agg.myTime / agg.allTime) }
        }
        let avgWordShare = wordShares.isEmpty ? nil : wordShares.reduce(0, +) / Double(wordShares.count)
        let avgTimeShare = timeShares.isEmpty ? nil : timeShares.reduce(0, +) / Double(timeShares.count)

        return Stats(
            wordsPerMinute: wordsPerMinute,
            avgWordShare: avgWordShare,
            avgTimeShare: avgTimeShare,
            vocabularySize: myFreq.count,
            longestMonologue: longestMonologue(for: uuid, utterances: utterances, tokens: tokens),
            signatureWords: signatureWords(myFreq: myFreq, myTotal: myWordCount,
                                           otherFreq: otherFreq, otherTotal: otherWordCount,
                                           limit: signatureLimit, minCount: minSignatureCount)
        )
    }

    /// Locale-aware word split: lowercased, diacritics kept, pure numbers/punctuation dropped.
    static func tokenize(_ text: String) -> [String] {
        var result: [String] = []
        let lowered = text.lowercased()
        lowered.enumerateSubstrings(in: lowered.startIndex..., options: .byWords) { word, _, _, _ in
            guard let word, word.rangeOfCharacter(from: .letters) != nil else { return }
            result.append(word)
        }
        return result
    }

    // MARK: - Pieces

    /// Longest run of consecutive utterances by the speaker, uninterrupted by anyone else,
    /// measured first-start → last-end.
    private static func longestMonologue(for uuid: String,
                                         utterances: [Utterance],
                                         tokens: [[String]]) -> Monologue? {
        let byRecording = Dictionary(grouping: zip(utterances, tokens).map { ($0, $1) },
                                     by: { $0.0.recordingId })
        var best: Monologue?

        for (recordingId, list) in byRecording {
            let ordered = list.sorted { $0.0.start < $1.0.start }
            var runStart: TimeInterval?
            var runEnd: TimeInterval = 0
            var runWords = 0

            func closeRun() {
                if let start = runStart {
                    let duration = runEnd - start
                    if duration > (best?.duration ?? -1) {
                        best = Monologue(recordingId: recordingId, duration: duration, words: runWords)
                    }
                }
                runStart = nil
                runWords = 0
            }

            for (u, words) in ordered {
                if u.speakerUuid == uuid {
                    if runStart == nil { runStart = u.start }
                    runEnd = max(runEnd, u.end)
                    runWords += words.count
                } else {
                    closeRun()
                }
            }
            closeRun()
        }
        return best
    }

    /// Words the speaker uses disproportionately more than everyone else (smoothed relative
    /// frequency ratio). With no other speech to compare against, fall back to plain frequency.
    private static func signatureWords(myFreq: [String: Int], myTotal: Int,
                                       otherFreq: [String: Int], otherTotal: Int,
                                       limit: Int, minCount: Int) -> [SignatureWord] {
        guard myTotal > 0 else { return [] }
        var result: [SignatureWord] = []
        for (word, count) in myFreq where count >= minCount && word.count >= 2 {
            let ratio: Double
            if otherTotal == 0 {
                ratio = Double(count)
            } else {
                let mine = Double(count) / Double(myTotal)
                let others = (Double(otherFreq[word] ?? 0) + 0.5) / Double(otherTotal)
                ratio = mine / others
            }
            result.append(SignatureWord(word: word, count: count, ratio: ratio))
        }
        result.sort {
            if $0.ratio != $1.ratio { return $0.ratio > $1.ratio }
            if $0.count != $1.count { return $0.count > $1.count }
            return $0.word < $1.word
        }
        return Array(result.prefix(limit))
    }
}
