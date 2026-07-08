import Foundation
import CoreAudio
import os

// MARK: - Meeting Recorder
//
// Orchestrates a microphone capture (CoreAudioRecorder) and a system-audio capture
// (SystemAudioRecorder) in parallel, producing two separate WAV files ready for the
// meeting transcription pipeline (which transcribes each source independently and
// interleaves the results into a speaker-labelled dialogue).
//
// Output files (16 kHz mono Int16 WAV) are placed at:
//   ~/Library/Application Support/com.prakashjoshipax.VoiceInk/Meetings/<stamp>.mic.wav
//   ~/Library/Application Support/com.prakashjoshipax.VoiceInk/Meetings/<stamp>.sys.wav
@available(macOS 14.4, *)
@MainActor
final class MeetingRecorder {

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "MeetingRecorder")

    private let micRecorder = CoreAudioRecorder()
    private let systemRecorder = SystemAudioRecorder()

    private var micTempURL: URL?
    private var systemTempURL: URL?
    private var stamp: String?

    private(set) var isRecording = false
    private(set) var startedAt: Date?

    // MARK: - Public API

    /// Begins capturing microphone + system audio. Throws if any source fails to start
    /// (e.g. Screen Recording permission denied, mic permission denied, no input device).
    func start() async throws {
        guard !isRecording else { return }

        // 1. Pick a microphone device. Custom selection from AudioDeviceManager when set;
        //    otherwise fall back to the system default input.
        let deviceID = await pickInputDeviceID()
        guard deviceID != 0 else {
            throw MeetingRecorderError.noInputDevice
        }

        // 2. Compute file paths
        let dir = try meetingsDirectory()
        let stamp = isoStamp(from: Date())
        let micTempURL = dir.appendingPathComponent(".\(stamp).mic.tmp.wav")
        let systemTempURL = dir.appendingPathComponent(".\(stamp).sys.tmp.wav")

        // 3. Start mic
        do {
            try micRecorder.startRecording(toOutputFile: micTempURL, deviceID: deviceID)
        } catch {
            logger.error("🎬 mic.startRecording failed: \(error.localizedDescription, privacy: .public)")
            throw MeetingRecorderError.micStartFailed(error)
        }

        // 4. Start system audio
        do {
            try await systemRecorder.startRecording(toOutputFile: systemTempURL)
        } catch {
            logger.error("🎬 system.startRecording failed: \(error.localizedDescription, privacy: .public)")
            micRecorder.stopRecording()
            try? FileManager.default.removeItem(at: micTempURL)
            throw MeetingRecorderError.systemStartFailed(error)
        }

        // 5. Remember paths
        self.micTempURL = micTempURL
        self.systemTempURL = systemTempURL
        self.stamp = stamp
        self.startedAt = Date()
        self.isRecording = true
        logger.notice("🎬 MeetingRecorder started")
    }

    /// Stops both sources, renames the temp WAVs to their final names, and returns
    /// the URLs of the two output files. Returns nil if no recording was active.
    @discardableResult
    func stop() async -> MeetingRecordingFiles? {
        guard isRecording else { return nil }
        isRecording = false

        micRecorder.stopRecording()
        await systemRecorder.stopRecording()

        guard let micTemp = micTempURL, let sysTemp = systemTempURL, let stamp = stamp else {
            micTempURL = nil
            systemTempURL = nil
            self.stamp = nil
            startedAt = nil
            return nil
        }

        let dir = micTemp.deletingLastPathComponent()
        let micFinalURL = dir.appendingPathComponent("\(stamp).mic.wav")
        let sysFinalURL = dir.appendingPathComponent("\(stamp).sys.wav")

        // Rename temp files to final names; fall back to temp URL on rename failure
        let resolvedMicURL: URL
        do {
            try FileManager.default.moveItem(at: micTemp, to: micFinalURL)
            resolvedMicURL = micFinalURL
        } catch {
            logger.error("🎬 Failed to rename mic temp file: \(error.localizedDescription, privacy: .public)")
            resolvedMicURL = micTemp
        }

        let resolvedSysURL: URL
        do {
            try FileManager.default.moveItem(at: sysTemp, to: sysFinalURL)
            resolvedSysURL = sysFinalURL
        } catch {
            logger.error("🎬 Failed to rename sys temp file: \(error.localizedDescription, privacy: .public)")
            resolvedSysURL = sysTemp
        }

        micTempURL = nil
        systemTempURL = nil
        self.stamp = nil
        startedAt = nil

        let result = MeetingRecordingFiles(micURL: resolvedMicURL, systemURL: resolvedSysURL)
        logger.notice("🎬 MeetingRecorder stopped → mic: \(resolvedMicURL.lastPathComponent, privacy: .public), sys: \(resolvedSysURL.lastPathComponent, privacy: .public)")
        return result
    }

    // MARK: - Helpers

    private func pickInputDeviceID() async -> AudioDeviceID {
        let manager = AudioDeviceManager.shared
        if let selected = manager.selectedDeviceID, selected != 0 {
            return selected
        }
        return manager.getSystemDefaultDevice() ?? 0
    }

    private func meetingsDirectory() throws -> URL {
        let fm = FileManager.default
        let support = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = support
            .appendingPathComponent("com.prakashjoshipax.VoiceInk", isDirectory: true)
            .appendingPathComponent("Meetings", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func isoStamp(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}

// MARK: - Return Value

struct MeetingRecordingFiles {
    let micURL: URL
    let systemURL: URL
}

// MARK: - Error Types

enum MeetingRecorderError: LocalizedError {
    case noInputDevice
    case micStartFailed(Error)
    case systemStartFailed(Error)

    var errorDescription: String? {
        switch self {
        case .noInputDevice:
            return String(localized: "No microphone input device available")
        case .micStartFailed(let error):
            return String(format: String(localized: "Microphone failed to start: %@"), error.localizedDescription)
        case .systemStartFailed(let error):
            return String(format: String(localized: "System audio failed to start: %@"), error.localizedDescription)
        }
    }
}
