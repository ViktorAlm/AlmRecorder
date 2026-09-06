import Foundation

/// Grades utterances 0…1 for hallucination-likelihood and assigns a cleanup tier.
/// Pure and deterministic (mirrors SpeakerIdentityInferenceEngine): callers feed text, timing,
/// whisper token stats, and optional neighbor-embedding cosines; no I/O happens here.
///
/// Tier discipline: `junk` (auto-hide) requires a *hard* text reason — boilerplate, empty/symbols,
/// or a runaway repetition loop. Probabilistic signals (token prob, char rate, cross-repetition,
/// embedding duplicates) can only ever escalate to `verify`, which means human review while audio
/// model verification is deferred.
enum TranscriptSuspicionScorer {

    struct Input {
        let text: String
        let startTime: TimeInterval
        let endTime: TimeInterval
        let speaker: String?
        let meanP: Float?    // mean whisper token probability, nil when unavailable (backfill, non-whisper)
        let minP: Float?
        let lowFrac: Float?  // fraction of tokens with p < 0.4

        // Learned-exemplar affinity ("reuse found hallucinations to find more") — computed by
        // the cleanup service against the bad-exemplar memory; defaults keep the cheap
        // creation-time path unchanged.
        var exemplarExact: Bool = false           // normalized text IS a confirmed hallucination
        var exemplarTextCosine: Double? = nil     // max text-embedding cosine vs exemplar set
        var exemplarNgramJaccard: Double? = nil   // max char-trigram Jaccard vs exemplar set
        /// Cosine of this line's 256-dim voice embedding vs its assigned speaker's centroid —
        /// hallucinated segments carry garbage voice prints far from any real speaker.
        var voiceMatch: Double? = nil
    }

    enum Reason: String, Codable {
        case boilerplate, emptyOrSymbols, repetitionLoop, silenceFiller  // hard — force score 1.0, allow junk tier
        case embeddedBoilerplate, repetitionSoft, crossRepetition, lowTokenProb, veryLowTokenProb,
             highCharRate, longSparse, embeddingDuplicate, scriptOutlier,
             knownHallucination, voiceMismatch                            // soft — additive, cap at verify tier
    }

    enum Tier: Equatable { case ok, verify, junk }

    struct Verdict: Equatable {
        let score: Double
        let reasons: [Reason]
        let tier: Tier
    }

    enum Thresholds {
        static let verifyFloor = 0.4
        static let junkFloor = 0.9

        static let veryLowMeanP: Float = 0.40
        static let lowMeanP: Float = 0.55
        static let lowFracLimit: Float = 0.35
        static let veryLowTokenProbScore = 0.55
        static let lowTokenProbScore = 0.35

        static let hardNGramRun = 5      // n-gram repeated this many times consecutively = loop
        static let softNGramRunMin = 3
        static let softDistinctRatio = 0.5
        static let softDistinctMinWords = 10
        static let repetitionSoftScore = 0.45
        static let embeddedBoilerplateScore = 0.55

        static let crossRepetitionMinWords = 3
        static let crossRepetitionScore = 0.5
        static let crossRepetitionRunScore = 0.85

        static let fastCharsPerSecond = 35.0
        static let insaneCharsPerSecond = 50.0
        static let charRateMinDuration = 1.0
        static let fastCharRateScore = 0.4
        static let insaneCharRateScore = 0.6

        static let sparseMinDuration = 12.0
        static let sparseCharsPerSecond = 0.8
        static let longSparseScore = 0.25

        static let embeddingDuplicateCosine = 0.97
        static let embeddingDuplicateMinWords = 8
        static let embeddingDuplicateScore = 0.4

        static let wwwMaxWords = 8

        // Silence filler: "Thank you. . . . . . ." — a RUN of consecutive dots (only whitespace
        // between them) around a couple of stranded words. Real sentence punctuation never runs:
        // "Ja. Ja. Precis." has three runs of one dot each.
        static let fillerMinDotRun = 4
        static let fillerMaxDistinctWords = 3

        // Script outlier: a short line whose script differs from the recording's own majority.
        static let scriptBatchMajorityShare = 0.6
        static let scriptItemDominanceShare = 0.7
        static let scriptOutlierMaxWords = 8
        static let scriptOutlierScore = 0.55

        // Learned exemplars: membership alone never fires — the line must carry another signal
        // or sit on near-silent audio, because common short phrases ("thank you") are also
        // perfectly real speech.
        static let exemplarCosineFloor = 0.92
        static let exemplarJaccardFloor = 0.7
        static let exemplarSparseCPS = 1.5
        static let knownHallucinationScore = 0.5

        // Voice mismatch is strictly corroborative.
        static let voiceMatchFloor = 0.5
        static let voiceMismatchScore = 0.3
    }

    private static let hardReasons: Set<Reason> = [.boilerplate, .emptyOrSymbols, .repetitionLoop, .silenceFiller]

    /// Silence hallucinations beyond the base markers in TranscriptHallucinationFilter (sv + en —
    /// whisper's training data is YouTube-subtitle flavored, so outros and credits dominate).
    private static let extraBoilerplatePhrases = [
        "tack för att du har tittat", "tack för att ni har tittat", "tack för att du tittade",
        "thanks for watching", "thank you for watching",
        "like and subscribe", "prenumerera på kanalen", "glöm inte att prenumerera",
        "översättning av", "översatt av", "svensktextning", "nordiskt undertextat",
    ]

    /// Non-speech markers whisper emits on music/noise. Checked with both bracket styles.
    private static let noiseMarkers: [String] = {
        let base = ["musik", "music", "applåder", "applause", "skratt", "laughter", "blank_audio", "tystnad", "silence"]
        return base.flatMap { ["[\($0)]", "(\($0))"] }
    }()

    /// `neighborCosines[i]` = cosine(textEmbedding[i], textEmbedding[i-1]), nil when either is missing.
    static func score(_ items: [Input], neighborCosines: [Double?]? = nil) -> [Verdict] {
        var verdicts: [Verdict] = []
        verdicts.reserveCapacity(items.count)

        // The recording's own dominant script — outliers are judged RELATIVE to it, so no
        // language is inherently suspicious (an all-Korean recording flags nothing; a stray
        // Korean outro in a Latin-script meeting does).
        let batchScript = dominantScript(over: items)

        var previousNorm: String?
        var previousWordCount = 0
        var previousSpeaker: String?
        var identicalRun = 1

        for (index, item) in items.enumerated() {
            var reasons: [Reason] = []
            var score = 0.0
            let lower = item.text.lowercased()
            let words = wordList(lower)
            let trimmedLength = item.text.trimmingCharacters(in: .whitespacesAndNewlines).count
            let duration = max(item.endTime - item.startTime, 0)

            // --- hard text signals ---
            if isEmptyOrSymbols(item.text) {
                reasons.append(.emptyOrSymbols)
            } else {
                if isBoilerplate(lower, wordCount: words.count) {
                    reasons.append(.boilerplate)
                } else if containsEmbeddedBoilerplate(lower, wordCount: words.count) {
                    reasons.append(.embeddedBoilerplate)
                    score += Thresholds.embeddedBoilerplateScore
                }
                if isSilenceFiller(lower, words: words) {
                    reasons.append(.silenceFiller)
                }
                let nGramRun = maxConsecutiveNGramRun(words)
                if TranscriptHallucinationFilter.isRunawayRepetition(lower) {
                    reasons.append(.repetitionLoop)
                } else if nGramRun >= Thresholds.softNGramRunMin
                            || (words.count >= Thresholds.softDistinctMinWords
                                && distinctRatio(words) <= Thresholds.softDistinctRatio) {
                    reasons.append(.repetitionSoft)
                    score += Thresholds.repetitionSoftScore
                }
            }
            let hasHard = reasons.contains(where: hardReasons.contains)

            // --- cross-utterance repetition (track runs even through junk so loops spanning items count) ---
            let norm = normalized(item.text)
            if !norm.isEmpty, norm == previousNorm {
                identicalRun += 1
            } else {
                identicalRun = 1
            }
            // A pair only counts for full-length lines (back-to-back "Yeah." is normal speech);
            // from the third identical line on it's a drumbeat regardless of length.
            if identicalRun >= 3 {
                reasons.append(.crossRepetition)
                score += Thresholds.crossRepetitionRunScore
            } else if identicalRun == 2,
                      words.count >= Thresholds.crossRepetitionMinWords,
                      previousWordCount >= Thresholds.crossRepetitionMinWords {
                reasons.append(.crossRepetition)
                score += Thresholds.crossRepetitionScore
            }

            // --- script outlier (relative to the recording's own dominant script) ---
            if let majority = batchScript,
               words.count <= Thresholds.scriptOutlierMaxWords,
               let itemScript = dominantScript(of: item.text),
               itemScript.script != majority,
               itemScript.share >= Thresholds.scriptItemDominanceShare {
                reasons.append(.scriptOutlier)
                score += Thresholds.scriptOutlierScore
            }

            // --- whisper token probability ---
            if let meanP = item.meanP, meanP < Thresholds.veryLowMeanP {
                reasons.append(.veryLowTokenProb)
                score += Thresholds.veryLowTokenProbScore
            } else if (item.meanP.map { $0 < Thresholds.lowMeanP } ?? false)
                        || (item.lowFrac.map { $0 > Thresholds.lowFracLimit } ?? false) {
                reasons.append(.lowTokenProb)
                score += Thresholds.lowTokenProbScore
            }

            // --- timing anomalies ---
            if trimmedLength > 0, duration >= Thresholds.charRateMinDuration {
                let charsPerSecond = Double(trimmedLength) / duration
                if charsPerSecond > Thresholds.insaneCharsPerSecond {
                    reasons.append(.highCharRate)
                    score += Thresholds.insaneCharRateScore
                } else if charsPerSecond > Thresholds.fastCharsPerSecond {
                    reasons.append(.highCharRate)
                    score += Thresholds.fastCharRateScore
                }
                if duration > Thresholds.sparseMinDuration, charsPerSecond < Thresholds.sparseCharsPerSecond {
                    reasons.append(.longSparse)
                    score += Thresholds.longSparseScore
                }
            }

            // --- embedding near-duplicate of the previous utterance ---
            let neighborCosine: Double? = {
                guard let cosines = neighborCosines, index < cosines.count else { return nil }
                return cosines[index]
            }()
            if let cosine = neighborCosine,
               cosine >= Thresholds.embeddingDuplicateCosine,
               item.speaker == previousSpeaker,
               words.count >= Thresholds.embeddingDuplicateMinWords,
               previousWordCount >= Thresholds.embeddingDuplicateMinWords {
                reasons.append(.embeddingDuplicate)
                score += Thresholds.embeddingDuplicateScore
            }

            // --- learned exemplar affinity (found hallucinations finding more) ---
            let sparseAudio = duration >= Thresholds.charRateMinDuration
                && trimmedLength > 0
                && Double(trimmedLength) / duration < Thresholds.exemplarSparseCPS
            let exemplarHit = item.exemplarExact
                || (item.exemplarTextCosine ?? 0) >= Thresholds.exemplarCosineFloor
                || (item.exemplarNgramJaccard ?? 0) >= Thresholds.exemplarJaccardFloor
            if exemplarHit, !reasons.isEmpty || sparseAudio {
                reasons.append(.knownHallucination)
                score += Thresholds.knownHallucinationScore
            }

            // --- voice mismatch (corroborative only — never fires on its own) ---
            if let voiceMatch = item.voiceMatch,
               voiceMatch < Thresholds.voiceMatchFloor,
               !reasons.isEmpty {
                reasons.append(.voiceMismatch)
                score += Thresholds.voiceMismatchScore
            }

            let finalScore = hasHard ? 1.0 : min(1.0, score)
            verdicts.append(Verdict(score: finalScore, reasons: reasons, tier: tier(for: finalScore, reasons: reasons)))

            previousNorm = norm
            previousWordCount = words.count
            previousSpeaker = item.speaker
        }
        return verdicts
    }

    /// Reasons serialized for the `utterances.suspicion_reasons` column.
    static func reasonsJSON(_ reasons: [Reason]) -> String {
        guard let data = try? JSONEncoder().encode(reasons),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }

    static func tier(for score: Double, reasons: [Reason]) -> Tier {
        if score >= Thresholds.junkFloor, reasons.contains(where: hardReasons.contains) {
            return .junk
        }
        if score >= Thresholds.verifyFloor {
            return .verify
        }
        return .ok
    }

    // MARK: - Text helpers

    private static func wordList(_ lower: String) -> [String] {
        lower.split(whereSeparator: { $0.isWhitespace })
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
    }

    private static func distinctRatio(_ words: [String]) -> Double {
        guard !words.isEmpty else { return 1.0 }
        return Double(Set(words).count) / Double(words.count)
    }

    /// Canonical text normalization shared by cross-repetition matching and the bad-exemplar
    /// memory — a single definition so "what was learned" and "what is matched" never drift.
    static func normalizedText(_ text: String) -> String {
        normalized(text)
    }

    /// Lowercased, letters/digits only, single-spaced — so "Let's break." matches "lets break".
    /// Punctuation vanishes without splitting words (apostrophes); whitespace collapses.
    private static func normalized(_ text: String) -> String {
        text.lowercased()
            .map { ch -> String in
                if ch.isWhitespace { return " " }
                if ch.isLetter || ch.isNumber { return String(ch) }
                return ""
            }
            .joined()
            .split(separator: " ")
            .joined(separator: " ")
    }

    private static func isBoilerplate(_ lower: String, wordCount: Int) -> Bool {
        if TranscriptHallucinationFilter.isStandaloneBoilerplate(lower) { return true }
        if extraBoilerplatePhrases.contains(where: { phrase in
            lower.contains(phrase)
                && (wordCount <= TranscriptHallucinationFilter.hardBoilerplateMaxWords
                    || hasRepeatedPhrase(phrase, in: lower))
        }) { return true }
        // Credit lines pair "copyright" with an agency; either alone appears in real speech.
        if wordCount <= TranscriptHallucinationFilter.hardBoilerplateMaxWords,
           lower.contains("copyright"), lower.contains("sdi media") { return true }
        // A bare URL utterance is a credit; a long sentence merely mentioning one is real speech.
        if lower.contains("www."), wordCount <= Thresholds.wwwMaxWords { return true }
        return false
    }

    private static func hasRepeatedPhrase(_ phrase: String, in text: String) -> Bool {
        guard let first = text.range(of: phrase) else { return false }
        return text.range(of: phrase, range: first.upperBound..<text.endIndex) != nil
    }

    private static func containsEmbeddedBoilerplate(_ lower: String, wordCount: Int) -> Bool {
        guard wordCount > TranscriptHallucinationFilter.hardBoilerplateMaxWords else {
            return false
        }
        return TranscriptHallucinationFilter.hasBoilerplateMarker(lower)
            || extraBoilerplatePhrases.contains(where: lower.contains)
            || (lower.contains("copyright") && lower.contains("sdi media"))
    }

    /// Junk if nothing alphanumeric remains after stripping known noise markers ("[musik]", "♪",
    /// "…") and whisper's asterisk sound-effects ("*sips*", "*slurp*", "*musik*" — any language).
    private static func isEmptyOrSymbols(_ text: String) -> Bool {
        var residual = text.lowercased()
        for marker in noiseMarkers {
            residual = residual.replacingOccurrences(of: marker, with: "")
        }
        residual = residual.replacingOccurrences(of: #"\*[^*\n]{1,30}\*"#, with: "",
                                                 options: .regularExpression)
        return !residual.contains { $0.isLetter || $0.isNumber }
    }

    /// "Thank you. . . . . . ." — whisper pads silence with consecutive dot runs around a
    /// stranded word or two. Language-agnostic: dots are dots everywhere. A run is dots with
    /// nothing but whitespace between them; "…" counts as a run of three.
    private static func isSilenceFiller(_ lower: String, words: [String]) -> Bool {
        guard !words.isEmpty, Set(words).count <= Thresholds.fillerMaxDistinctWords else { return false }

        var maxRun = 0
        var currentRun = 0
        for char in lower {
            if char == "." {
                currentRun += 1
            } else if char == "…" {
                currentRun += 3
            } else if char.isWhitespace {
                continue   // whitespace doesn't break a dot run
            } else {
                currentRun = 0
            }
            maxRun = max(maxRun, currentRun)
        }
        return maxRun >= Thresholds.fillerMinDotRun
    }

    // MARK: - Script classification (for relative outlier detection)

    /// Coarse script buckets. Han and kana are merged (Japanese mixes them; Chinese shares han),
    /// which keeps genuinely mixed CJK recordings from self-flagging.
    enum WritingScript: Hashable {
        case latin, cjk, hangul, cyrillic, arabic, hebrew, thai, devanagari, greek, other
    }

    private static func script(of scalar: Unicode.Scalar) -> WritingScript? {
        switch scalar.value {
        case 0x0041...0x024F, 0x1E00...0x1EFF: return .latin
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x3040...0x30FF, 0x31F0...0x31FF: return .cjk
        case 0xAC00...0xD7AF, 0x1100...0x11FF, 0x3130...0x318F: return .hangul
        case 0x0400...0x04FF, 0x0500...0x052F: return .cyrillic
        case 0x0600...0x06FF, 0x0750...0x077F: return .arabic
        case 0x0590...0x05FF: return .hebrew
        case 0x0E00...0x0E7F: return .thai
        case 0x0900...0x097F: return .devanagari
        case 0x0370...0x03FF: return .greek
        default: return nil   // digits, punctuation, symbols — script-neutral
        }
    }

    private static func scriptTally(_ text: String) -> [WritingScript: Int] {
        var tally: [WritingScript: Int] = [:]
        for scalar in text.unicodeScalars {
            guard Unicode.Scalar(scalar.value).map(Character.init)?.isLetter ?? false,
                  let script = script(of: scalar) else { continue }
            tally[script, default: 0] += 1
        }
        return tally
    }

    private static func dominantScript(of text: String) -> (script: WritingScript, share: Double)? {
        let tally = scriptTally(text)
        let total = tally.values.reduce(0, +)
        guard total >= 2, let best = tally.max(by: { $0.value < $1.value }) else { return nil }
        return (best.key, Double(best.value) / Double(total))
    }

    /// The batch-majority script, or nil when the recording has no clear majority (heavily mixed
    /// recordings opt out of outlier detection entirely).
    private static func dominantScript(over items: [Input]) -> WritingScript? {
        var tally: [WritingScript: Int] = [:]
        for item in items {
            for (script, count) in scriptTally(item.text) {
                tally[script, default: 0] += count
            }
        }
        let total = tally.values.reduce(0, +)
        guard total >= 20, let best = tally.max(by: { $0.value < $1.value }),
              Double(best.value) / Double(total) >= Thresholds.scriptBatchMajorityShare else {
            return nil
        }
        return best.key
    }

    /// Longest run of an identical 1–4-gram repeated back-to-back ("ja ja ja ja ja ja" → 6,
    /// "i think i think i think" → 3). Checks every phase offset so unaligned loops still count.
    private static func maxConsecutiveNGramRun(_ words: [String]) -> Int {
        guard words.count >= 2 else { return 1 }
        var maxRun = 1
        for n in 1...4 where words.count >= n * 2 {
            for offset in 0..<n {
                var run = 1
                var i = offset + n
                while i + n <= words.count {
                    if words[i..<(i + n)].elementsEqual(words[(i - n)..<i]) {
                        run += 1
                        maxRun = max(maxRun, run)
                    } else {
                        run = 1
                    }
                    i += n
                }
            }
        }
        return maxRun
    }
}
