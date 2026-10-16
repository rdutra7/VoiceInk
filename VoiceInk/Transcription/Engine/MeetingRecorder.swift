import Foundation
import AVFoundation
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
    // Set only when the opt-in AEC path is active; nil = default CoreAudioRecorder path.
    private var voiceMicRecorder: VoiceProcessedMicRecorder?
    private let systemRecorder = SystemAudioRecorder()

    /// The mic recorder in use for the current session. Off = the untouched
    /// CoreAudioRecorder instance (behaviour byte-for-byte identical to before).
    private var activeMic: MeetingMicRecording {
        voiceMicRecorder ?? micRecorder
    }

    private var micTempURL: URL?
    private var systemTempURL: URL?
    private var stamp: String?
    private var micDeviceID: AudioDeviceID = 0
    private var micRateAtStart: Double = 0

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

        // 3. Start mic. Opt-in echo cancellation (Apple voice processing) when the
        //    MeetingMicVoiceProcessing default is set; otherwise the default path.
        switch MeetingMicKind.resolve(voiceProcessingEnabled: UserDefaults.standard.bool(forKey: "MeetingMicVoiceProcessing")) {
        case .voiceProcessed:
            voiceMicRecorder = VoiceProcessedMicRecorder()
        case .coreAudio:
            voiceMicRecorder = nil
        }
        do {
            try activeMic.startRecording(toOutputFile: micTempURL, deviceID: deviceID)
        } catch {
            logger.error("🎬 mic.startRecording failed: \(error.localizedDescription, privacy: .public)")
            throw MeetingRecorderError.micStartFailed(error)
        }

        // 4. Start system audio
        do {
            try await systemRecorder.startRecording(toOutputFile: systemTempURL)
        } catch {
            logger.error("🎬 system.startRecording failed: \(error.localizedDescription, privacy: .public)")
            activeMic.stopRecording()
            voiceMicRecorder = nil
            try? FileManager.default.removeItem(at: micTempURL)
            throw MeetingRecorderError.systemStartFailed(error)
        }

        // 5. Remember paths
        self.micTempURL = micTempURL
        self.systemTempURL = systemTempURL
        self.stamp = stamp
        self.micDeviceID = deviceID
        self.micRateAtStart = Self.nominalSampleRate(of: deviceID)
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
        let wallClock = startedAt.map { Date().timeIntervalSince($0) } ?? 0

        activeMic.stopRecording()
        voiceMicRecorder = nil
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
        logTiming(stamp: stamp, wallClock: wallClock, mic: resolvedMicURL, sys: resolvedSysURL)
        return result
    }

    // MARK: - Helpers

    /// Appends one line per meeting to Meetings/timing.log comparing wall-clock time with
    /// each track's length. A track much longer or shorter than the wall clock drifts, and
    /// the merged dialogue comes out of order (the mic track was ~5% long on 2026-10-15,
    /// with AirPods; cause not found yet). The unified log doesn't keep these for long.
    private func logTiming(stamp: String, wallClock: TimeInterval, mic: URL, sys: URL) {
        func seconds(_ url: URL) -> Double {
            guard let file = try? AVAudioFile(forReading: url) else { return -1 }
            return Double(file.length) / file.fileFormat.sampleRate
        }
        let deviceName = AudioDeviceManager.shared.getDeviceName(deviceID: micDeviceID) ?? "?"
        let line = String(
            format: "%@ wall=%.1fs mic=%.1fs sys=%.1fs micDevice=\"%@\" micRateAtStart=%.0f micRateAtStop=%.0f\n",
            stamp, wallClock, seconds(mic), seconds(sys), deviceName,
            micRateAtStart, Self.nominalSampleRate(of: micDeviceID)
        )
        logger.notice("🎬 timing: \(line, privacy: .public)")

        let logURL = mic.deletingLastPathComponent().appendingPathComponent("timing.log")
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(to: logURL, atomically: true, encoding: .utf8)
        }
    }

    private static func nominalSampleRate(of deviceID: AudioDeviceID) -> Double {
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &rate)
        return rate
    }

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

// MARK: - Mic Recorder Abstraction
//
// The minimal surface MeetingRecorder needs from a mic capture backend. Lets the
// default CoreAudioRecorder and the opt-in VoiceProcessedMicRecorder be swapped
// without touching the orchestration/rename logic.

protocol MeetingMicRecording: AnyObject {
    func startRecording(toOutputFile url: URL, deviceID: AudioDeviceID) throws
    func stopRecording()
}

extension CoreAudioRecorder: MeetingMicRecording {}

extension VoiceProcessedMicRecorder: MeetingMicRecording {}
