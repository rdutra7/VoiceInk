import Foundation
import CoreAudio
import os

// MARK: - Meeting Recorder
//
// Orchestrates a microphone capture (CoreAudioRecorder) and a system-audio capture
// (SystemAudioRecorder) in parallel, mixes their streams with MeetingAudioMixer, and
// produces a single WAV file ready for the existing transcription pipeline.
//
// Output: 16 kHz mono Int16 WAV at
//   ~/Library/Application Support/com.prakashjoshipax.VoiceInk/Meetings/<timestamp>.wav
//
// Both source recorders also write their own temp WAV (required by the CoreAudio /
// ExtAudioFile pattern); these are deleted on stop after the mixed WAV is closed.
@available(macOS 14.4, *)
@MainActor
final class MeetingRecorder {

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "MeetingRecorder")

    private let micRecorder = CoreAudioRecorder()
    private let systemRecorder = SystemAudioRecorder()
    private let mixer = MeetingAudioMixer()

    private var mixedURL: URL?
    private var micTempURL: URL?
    private var systemTempURL: URL?

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
        let mixedURL = dir.appendingPathComponent("\(stamp).wav")
        let micTempURL = dir.appendingPathComponent(".\(stamp).mic.tmp.wav")
        let systemTempURL = dir.appendingPathComponent(".\(stamp).sys.tmp.wav")

        // 3. Open mixer first so feeders never get fed before file is ready
        do {
            try mixer.open(at: mixedURL)
        } catch {
            logger.error("🎬 mixer.open failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }

        // 4. Wire callbacks
        micRecorder.onAudioChunk = { [weak self] data in
            self?.mixer.feedMic(data)
        }
        systemRecorder.onAudioChunk = { [weak self] data in
            self?.mixer.feedSystem(data)
        }

        // 5. Start mic
        do {
            try micRecorder.startRecording(toOutputFile: micTempURL, deviceID: deviceID)
        } catch {
            logger.error("🎬 mic.startRecording failed: \(error.localizedDescription, privacy: .public)")
            mixer.close()
            try? FileManager.default.removeItem(at: mixedURL)
            throw MeetingRecorderError.micStartFailed(error)
        }

        // 6. Start system audio
        do {
            try await systemRecorder.startRecording(toOutputFile: systemTempURL)
        } catch {
            logger.error("🎬 system.startRecording failed: \(error.localizedDescription, privacy: .public)")
            micRecorder.stopRecording()
            mixer.close()
            try? FileManager.default.removeItem(at: micTempURL)
            try? FileManager.default.removeItem(at: mixedURL)
            throw MeetingRecorderError.systemStartFailed(error)
        }

        // 7. Remember paths
        self.mixedURL = mixedURL
        self.micTempURL = micTempURL
        self.systemTempURL = systemTempURL
        self.startedAt = Date()
        self.isRecording = true
        logger.notice("🎬 MeetingRecorder started → \(mixedURL.path, privacy: .public)")
    }

    /// Stops both sources, finalizes the mixed WAV, deletes the temp files, and returns
    /// the URL of the final mixed WAV. Returns nil if no recording was active.
    @discardableResult
    func stop() async -> URL? {
        guard isRecording else { return nil }
        isRecording = false

        micRecorder.stopRecording()
        await systemRecorder.stopRecording()
        mixer.close()

        if let mic = micTempURL {
            try? FileManager.default.removeItem(at: mic)
        }
        if let sys = systemTempURL {
            try? FileManager.default.removeItem(at: sys)
        }

        let result = mixedURL
        micTempURL = nil
        systemTempURL = nil
        mixedURL = nil
        startedAt = nil
        logger.notice("🎬 MeetingRecorder stopped → \(result?.path ?? "(nil)", privacy: .public)")
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
