import Foundation
import AVFoundation

/// Folds the two transcribed tracks of a meeting (mic + system) into ONE normal recording.
///
/// The dual-track / per-source-diarization machinery is plumbing — the end artifact should just be a
/// recording. Once both tracks have transcribed, this mixes their audio into a single file,
/// **de-duplicates the echo** (the mic also records the speaker output, so the same speech lands on
/// both tracks), re-homes the surviving utterances under one combined recording sorted by time, and
/// removes the intermediate track rows. The result opens in the normal detail view.
enum MeetingAssembler {
    private static let lock = NSLock()
    private static var inProgress = Set<String>()
    private static let logger = VoxtralLogger.shared

    /// Parse the meeting stamp from a track file name: "meeting_<stamp>_mic.caf" → "<stamp>".
    static func stamp(fromFileName fileName: String) -> String? {
        let base = (fileName as NSString).deletingPathExtension
        let parts = base.split(separator: "_").map(String.init)
        guard parts.count >= 3, parts[0] == "meeting",
              base.hasSuffix("_mic") || base.hasSuffix("_system") else { return nil }
        return parts[1]
    }

    /// Live trigger: fold only once BOTH tracks exist (wait for the sibling). Safe to call from each
    /// track's completion.
    @discardableResult
    static func assembleIfReady(stamp: String) async -> Int64? {
        await fold(stamp: stamp, requireBothTracks: true)
    }

    /// Retroactively fold every meeting that still has un-merged tracks (pairs that never folded, and
    /// mic-only meetings). Returns how many were folded/cleaned.
    static func foldAllExisting() async -> Int {
        let all = (try? GRDBRecordingRepository().getAll(limit: 100_000)) ?? []
        let stamps = Set(all.compactMap { stamp(fromFileName: $0.fileName) })
        var folded = 0
        for s in stamps where await fold(stamp: s, requireBothTracks: false) != nil { folded += 1 }
        logger.info("[MeetingAssembler] foldAllExisting folded \(folded) of \(stamps.count) meeting(s)")
        return folded
    }

    /// Fold a meeting's track(s) into one clean recording.
    /// - `requireBothTracks`: when true (live path) no-ops until both mic + system are present.
    @discardableResult
    static func fold(stamp: String, requireBothTracks: Bool) async -> Int64? {
        lock.lock()
        if inProgress.contains(stamp) { lock.unlock(); return nil }
        inProgress.insert(stamp)
        lock.unlock()
        defer { lock.lock(); inProgress.remove(stamp); lock.unlock() }

        let recRepo = GRDBRecordingRepository()
        let uttRepo = GRDBUtteranceRepository()
        let all = (try? recRepo.getByFileNamePrefix("meeting_\(stamp)_")) ?? []

        // Already folded? (a combined "meeting_<stamp>.*" with no _mic/_system suffix exists)
        if all.contains(where: { !$0.fileName.contains("_mic") && !$0.fileName.contains("_system") }) {
            return nil
        }
        let tracks = all.filter { $0.fileName.contains("_mic") || $0.fileName.contains("_system") }
        guard !tracks.isEmpty else { return nil }
        if requireBothTracks && tracks.count < 2 { return nil } // sibling not done yet

        // Single track (e.g. mic-only meeting): nothing to merge/dedupe — just give it a clean title.
        if tracks.count == 1 {
            let only = tracks[0]
            guard let rid = only.id else { return nil }
            let title = meetingTitle(stamp: stamp, fallback: only.createdAt)
            guard only.title != title else { return rid }
            try? GRDBDatabaseManager.shared.write { db in
                try db.execute(sql: "UPDATE recordings SET title = ? WHERE id = ?", arguments: [title, rid])
            }
            logger.info("[MeetingAssembler] Retitled single-track meeting \(stamp) → \(title)")
            return rid
        }

        // Pair: gather per-source utterances + audio.
        var micUtts: [Utterance] = []
        var sysUtts: [Utterance] = []
        var trackURLs: [URL] = []
        for rec in tracks {
            if let path = rec.filePath, FileManager.default.fileExists(atPath: path) {
                trackURLs.append(URL(fileURLWithPath: path))
            }
            guard let rid = rec.id else { continue }
            let us = (try? uttRepo.getByRecordingId(rid)) ?? []
            if rec.fileName.contains("_mic") { micUtts += us } else { sysUtts += us }
        }
        guard !(micUtts.isEmpty && sysUtts.isEmpty) else { return nil }

        // De-dupe echo: drop mic lines that duplicate an overlapping system line; keep system + real
        // mic turns, ordered by time.
        let micSU = micUtts.map { MeetingTranscriptMerger.SourceUtterance(speaker: $0.speaker, start: $0.startTime, end: $0.endTime, text: $0.text, id: $0.id) }
        let sysSU = sysUtts.map { MeetingTranscriptMerger.SourceUtterance(speaker: $0.speaker, start: $0.startTime, end: $0.endTime, text: $0.text, id: $0.id) }
        let kept = MeetingTranscriptMerger.mergeDeduped(mic: micSU, system: sysSU)
        let keptIds = kept.compactMap { $0.id }
        let keptSet = Set(keptIds)
        let dropIds = (micUtts + sysUtts).compactMap { $0.id }.filter { !keptSet.contains($0) }

        // 1. Mix audio into one file (best-effort; fall back to the longest track on failure).
        let dir = trackURLs.first?.deletingLastPathComponent()
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let combinedURL = dir.appendingPathComponent("meeting_\(stamp).m4a")
        var audioPath: String?
        if trackURLs.count >= 2, (try? await mix(trackURLs, to: combinedURL)) != nil {
            audioPath = combinedURL.path
        } else {
            audioPath = tracks.max(by: { ($0.duration ?? 0) < ($1.duration ?? 0) })?.filePath
        }

        // 2. Create the single combined recording.
        let createdAt = tracks.compactMap { $0.createdAt }.min() ?? Date()
        let combined = Recording(
            id: nil,
            title: meetingTitle(stamp: stamp, fallback: createdAt),
            fileName: "meeting_\(stamp).m4a",
            filePath: audioPath,
            duration: tracks.compactMap { $0.duration }.max(),
            language: tracks.first?.language,
            createdAt: createdAt,
            transcribedAt: Date(),
            source: .recording,
            fullTranscript: nil,
            metadata: nil
        )
        guard let combinedId = try? recRepo.create(combined) else {
            logger.error("[MeetingAssembler] Failed to create combined recording for \(stamp)")
            return nil
        }

        // 3. Re-home surviving utterances (time-ordered), delete echo dupes, drop the track rows.
        try? GRDBDatabaseManager.shared.write { db in
            for (idx, id) in keptIds.enumerated() {
                try db.execute(
                    sql: "UPDATE utterances SET recording_id = ?, utterance_index = ? WHERE id = ?",
                    arguments: [combinedId, idx, id])
            }
            for id in dropIds {
                try db.execute(sql: "DELETE FROM utterances WHERE id = ?", arguments: [id])
            }
            for rec in tracks {
                guard let rid = rec.id else { continue }
                try db.execute(sql: "DELETE FROM recordings WHERE id = ?", arguments: [rid])
            }
        }
        logger.info("[MeetingAssembler] Folded meeting \(stamp): \(tracks.count) tracks → recording \(combinedId), kept \(keptIds.count) lines, dropped \(dropIds.count) echo dupes")
        return combinedId
    }

    /// Mix audio files that share t=0 into one. AVMutableComposition with both as audio tracks, then
    /// export to m4a — the composition's audio tracks are rendered together into the output.
    static func mix(_ urls: [URL], to output: URL) async throws {
        try? FileManager.default.removeItem(at: output)
        let composition = AVMutableComposition()
        for url in urls {
            let asset = AVURLAsset(url: url)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            guard let src = audioTracks.first else { continue }
            let dur = try await asset.load(.duration)
            guard let track = composition.addMutableTrack(
                withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: dur), of: src, at: .zero)
        }
        guard let export = AVAssetExportSession(
            asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw NSError(domain: "MeetingAssembler", code: 1)
        }
        export.outputURL = output
        export.outputFileType = .m4a
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { cont.resume() }
        }
        if export.status != .completed {
            throw export.error ?? NSError(domain: "MeetingAssembler", code: 2)
        }
    }

    private static func meetingTitle(stamp: String, fallback: Date) -> String {
        let date = TimeInterval(stamp).map { Date(timeIntervalSince1970: $0) } ?? fallback
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        return "Meeting · \(fmt.string(from: date))"
    }
}
