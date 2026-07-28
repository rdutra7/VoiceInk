import Foundation
import os

// MARK: - Meeting Recovery Service
//
// Recovers meeting recordings orphaned by a crash / force-quit between MeetingRecorder
// producing WAV files and the transcription pipeline consuming them. Runs once at launch,
// scans the Meetings/ directory, and re-enqueues any complete pair it finds:
//   - a temp pair `.<stamp>.mic.tmp.wav` + `.<stamp>.sys.tmp.wav` → renamed to final, then enqueued
//   - a final pair `<stamp>.mic.wav`   + `<stamp>.sys.wav`        → enqueued directly
// Lone files (a track missing its counterpart) are left in place and never enqueued.
// The `failed/` subdirectory is skipped — meetings quarantined there produced empty
// transcripts and must not be recovered again on every launch.

enum MeetingRecoveryAction: Equatable {
    case renameTmpPair(stamp: String)
    case enqueuePair(stamp: String)
    case ignoreLone(filename: String)
}

struct ParsedMeetingFile: Equatable {
    let stamp: String
    let track: String   // "mic" or "sys"
    let isTmp: Bool
}

enum MeetingRecoveryService {
    private static let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "MeetingRecoveryService")

    // MARK: - Pure parsing

    /// A meeting stamp is `yyyyMMdd-HHmmss` (8 digits, dash, 6 digits).
    static func isValidStamp(_ stamp: String) -> Bool {
        let parts = stamp.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 8, parts[1].count == 6 else { return false }
        return parts.allSatisfy { $0.allSatisfy(\.isNumber) }
    }

    /// Parses a Meetings/ entry into its stamp, track and temp/final kind, or nil if the
    /// name is not a recognised meeting WAV (e.g. `.DS_Store`, the `failed` subdir).
    static func parse(filename: String) -> ParsedMeetingFile? {
        for track in ["mic", "sys"] {
            let tmpSuffix = ".\(track).tmp.wav"
            if filename.hasPrefix("."), filename.hasSuffix(tmpSuffix) {
                let stamp = String(filename.dropFirst().dropLast(tmpSuffix.count))
                if isValidStamp(stamp) { return ParsedMeetingFile(stamp: stamp, track: track, isTmp: true) }
            }
            let finalSuffix = ".\(track).wav"
            if !filename.hasPrefix("."), filename.hasSuffix(finalSuffix) {
                let stamp = String(filename.dropLast(finalSuffix.count))
                if isValidStamp(stamp) { return ParsedMeetingFile(stamp: stamp, track: track, isTmp: false) }
            }
        }
        return nil
    }

    // MARK: - Pure planning

    /// Turns a directory listing into an ordered list of recovery actions: complete pairs
    /// first (sorted by stamp), then lone files (sorted by name). Deterministic for testing.
    static func recoveryActions(for filenames: [String]) -> [MeetingRecoveryAction] {
        struct Key: Hashable { let stamp: String; let isTmp: Bool }
        var groups: [Key: [String: String]] = [:]   // key → track → filename
        for name in filenames {
            guard let parsed = parse(filename: name) else { continue }
            groups[Key(stamp: parsed.stamp, isTmp: parsed.isTmp), default: [:]][parsed.track] = name
        }

        var actions: [MeetingRecoveryAction] = []
        var loneFiles: [String] = []
        let stamps = Set(groups.keys.map(\.stamp)).sorted()
        for stamp in stamps {
            let tmp = groups[Key(stamp: stamp, isTmp: true)] ?? [:]
            let final = groups[Key(stamp: stamp, isTmp: false)] ?? [:]
            if tmp["mic"] != nil, tmp["sys"] != nil {
                actions.append(.renameTmpPair(stamp: stamp))
                loneFiles.append(contentsOf: final.values)   // stray finals for same stamp
            } else if final["mic"] != nil, final["sys"] != nil {
                actions.append(.enqueuePair(stamp: stamp))
                loneFiles.append(contentsOf: tmp.values)      // stray tmps for same stamp
            } else {
                loneFiles.append(contentsOf: tmp.values)
                loneFiles.append(contentsOf: final.values)
            }
        }
        for filename in loneFiles.sorted() { actions.append(.ignoreLone(filename: filename)) }
        return actions
    }

    // MARK: - Meetings directory

    static func meetingsDirectory() -> URL? {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ) else { return nil }
        return support
            .appendingPathComponent("com.prakashjoshipax.VoiceInk", isDirectory: true)
            .appendingPathComponent("Meetings", isDirectory: true)
    }

    /// Moves a failed meeting's two WAV files into `Meetings/failed/` so the recovery scan
    /// won't re-enqueue an empty-transcript meeting on every launch. Best-effort.
    nonisolated static func quarantineFailedMeeting(micURL: URL, systemURL: URL) {
        let fm = FileManager.default
        let failedDir = micURL.deletingLastPathComponent().appendingPathComponent("failed", isDirectory: true)
        try? fm.createDirectory(at: failedDir, withIntermediateDirectories: true)
        for url in [micURL, systemURL] {
            let dest = failedDir.appendingPathComponent(url.lastPathComponent)
            try? fm.removeItem(at: dest)
            try? fm.moveItem(at: url, to: dest)
        }
    }

    // MARK: - Recovery (impure)

    @MainActor
    static func recover(engine: VoiceInkEngine, mode: ModeConfig) {
        guard let dir = meetingsDirectory() else { return }
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path), !names.isEmpty else { return }

        let actions = recoveryActions(for: names)
        guard !actions.isEmpty else { return }

        let manager = AudioTranscriptionManager.shared
        var didEnqueue = false

        for action in actions {
            switch action {
            case .ignoreLone(let filename):
                logger.notice("Recovery: ignoring lone meeting file \(filename, privacy: .public)")

            case .enqueuePair(let stamp):
                let mic = dir.appendingPathComponent("\(stamp).mic.wav")
                let sys = dir.appendingPathComponent("\(stamp).sys.wav")
                manager.addMeetingToQueue(micURL: mic, systemURL: sys)
                didEnqueue = true
                logger.notice("Recovery: enqueued final pair \(stamp, privacy: .public)")

            case .renameTmpPair(let stamp):
                let micTmp = dir.appendingPathComponent(".\(stamp).mic.tmp.wav")
                let sysTmp = dir.appendingPathComponent(".\(stamp).sys.tmp.wav")
                let mic = dir.appendingPathComponent("\(stamp).mic.wav")
                let sys = dir.appendingPathComponent("\(stamp).sys.wav")
                do {
                    try fm.moveItem(at: micTmp, to: mic)
                    try fm.moveItem(at: sysTmp, to: sys)
                    manager.addMeetingToQueue(micURL: mic, systemURL: sys)
                    didEnqueue = true
                    logger.notice("Recovery: finalized + enqueued tmp pair \(stamp, privacy: .public)")
                } catch {
                    logger.error("Recovery: failed to finalize tmp pair \(stamp, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        if didEnqueue {
            manager.startProcessing(modelContext: engine.modelContext, engine: engine, mode: mode)
        }
    }
}
