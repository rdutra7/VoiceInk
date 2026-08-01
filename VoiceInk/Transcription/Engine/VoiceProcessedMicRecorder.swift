import Foundation
import AVFoundation
import CoreAudio
import os

// MARK: - Voice-Processed Mic Recorder (AVAudioEngine + Apple AEC)
//
// Optional replacement for CoreAudioRecorder on the MEETING mic channel only.
// Enables Apple's voice-processing IO (echo cancellation) so the far side's voice
// bleeding through the speakers doesn't get re-captured by the mic and duplicated
// into the transcript. Output contract is identical to CoreAudioRecorder:
// 16 kHz mono Int16 WAV at the given URL (the merge pipeline depends on this).
//
// This path fails SILENTLY in several ways (a valid-looking but digitally silent
// file) if the audio graph is set up incompletely — see the comments on each step.
// A liveness watchdog (peak==0 over the first ~1.5s) tears the engine down and
// falls back to a plain CoreAudioRecorder so the meeting is never lost.

/// Recorder-selection decision, extracted pure for testing.
enum MeetingMicKind {
    case coreAudio
    case voiceProcessed

    static func resolve(voiceProcessingEnabled: Bool) -> MeetingMicKind {
        voiceProcessingEnabled ? .voiceProcessed : .coreAudio
    }
}

/// Liveness watchdog decision logic, extracted pure for testing.
/// Tracks peak amplitude over an opening window of tap frames.
/// `observe` returns: nil = keep observing, true = alive (signal seen),
/// false = fall back (window elapsed with exact-zero peak).
struct LivenessWatchdog {
    let windowFrames: Int
    private(set) var observedFrames = 0
    private(set) var peak: Float = 0
    private var decided = false

    init(windowFrames: Int) {
        self.windowFrames = windowFrames
    }

    mutating func observe(peakInBuffer: Float, frames: Int) -> Bool? {
        guard !decided else { return nil }
        peak = max(peak, peakInBuffer)
        observedFrames += frames
        if peak > 0 {
            decided = true
            return true
        }
        if observedFrames >= windowFrames {
            decided = true
            return false
        }
        return nil
    }
}

final class VoiceProcessedMicRecorder {

    // Output contract (must match CoreAudioRecorder): 16 kHz mono Int16 WAV.
    static let targetSampleRate: Double = 16_000
    static let targetChannels: AVAudioChannelCount = 1
    static let targetBitDepth: Int = 16

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "VoiceProcessedMicRecorder")

    private let engine = AVAudioEngine()
    private var audioFile: AVAudioFile?
    private var converter: AVAudioConverter?
    private var fileFormat: AVAudioFormat?

    private var watchdog: LivenessWatchdog?
    private var recordingURL: URL?
    private var deviceID: AudioDeviceID = 0
    private var tapInstalled = false
    private var isRecording = false

    /// CoreAudioRecorder used only if AEC produces digital silence. Reuses the
    /// existing, tested capture+conversion path so the meeting survives.
    private let fallbackRecorder = CoreAudioRecorder()
    /// Diagnosable: true once we've torn down AEC and switched to CoreAudioRecorder.
    private(set) var didFallBack = false

    // MARK: - Public surface (mirrors the minimal contract MeetingRecorder uses)

    func startRecording(toOutputFile url: URL, deviceID: AudioDeviceID) throws {
        recordingURL = url
        self.deviceID = deviceID

        let input = engine.inputNode

        // 1. Enable voice processing BEFORE engine.start(), on the INPUT node only
        //    (it enables the duplex pair; enabling it on the output too is redundant).
        //    Absent → no echo cancellation at all.
        try input.setVoiceProcessingEnabled(true)

        // Ducking of other audio: minimize it (can be minimized, not zeroed).
        input.voiceProcessingOtherAudioDuckingConfiguration =
            AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                enableAdvancedDucking: false,
                duckingLevel: .min
            )

        // 2. Apply the selected input device to the engine's input unit before start.
        //    Non-fatal if it fails — fall through to the system default device.
        if deviceID != 0, let unit = input.audioUnit {
            var dev = deviceID
            let st = AudioUnitSetProperty(
                unit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &dev,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            if st != noErr {
                logger.error("🎙️ Failed to set input device \(deviceID, privacy: .public) on VP unit: \(st, privacy: .public); using default")
            }
        }

        // 3. One explicit mono format at the device's native rate. NEVER trust
        //    inputNode.outputFormat(forBus:0) post-enable for the channel count
        //    (can report a bogus multichannel format); only the scalar sample
        //    rate is reliable. The tap converts to this mono format internally.
        let nativeRate = input.outputFormat(forBus: 0).sampleRate
        let deviceRate = nativeRate > 0 ? nativeRate : 48_000
        guard let tapFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: deviceRate,
            channels: 1,
            interleaved: false
        ) else {
            throw VoiceProcessedMicRecorderError.invalidFormat
        }

        // 4. Complete the render path: mainMixer → output, same mono format, volume 0.
        //    VoiceProcessingIO is DUPLEX — with an incomplete render path it produces
        //    silence even though nothing is meant to play.
        let mixer = engine.mainMixerNode
        engine.connect(mixer, to: engine.outputNode, format: tapFormat)
        mixer.outputVolume = 0

        // 5. Output file + converter (Float32 mono @ deviceRate → Int16 mono @ 16 kHz).
        let file = try makeOutputFile(at: url)
        audioFile = file
        fileFormat = file.processingFormat
        guard let converter = AVAudioConverter(from: tapFormat, to: file.processingFormat) else {
            throw VoiceProcessedMicRecorderError.converterUnavailable
        }
        self.converter = converter

        // 6. Watchdog window: ~1.5s of tap frames (device-rate frames).
        watchdog = LivenessWatchdog(windowFrames: Int(deviceRate * 1.5))

        // 7. Install the tap WITH the explicit mono format (unit down-mixes internally).
        input.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { [weak self] buffer, _ in
            self?.handleTap(buffer)
        }
        tapInstalled = true

        // 8. Start.
        engine.prepare()
        do {
            try engine.start()
        } catch {
            teardownEngine()
            audioFile = nil
            throw error
        }
        isRecording = true
        logger.notice("🎙️ VoiceProcessedMicRecorder started (AEC on, deviceRate=\(Int(deviceRate), privacy: .public))")
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        // Idempotent teardown regardless of whether we already fell back — safe under
        // any interleaving with the async fallback dispatched from the tap thread.
        teardownEngine()
        fallbackRecorder.stopRecording() // no-op unless fallback was active
        audioFile = nil
        converter = nil
        watchdog = nil
        logger.notice("🎙️ VoiceProcessedMicRecorder stopped (didFallBack=\(self.didFallBack, privacy: .public))")
    }

    // MARK: - Tap handling (audio thread)

    private func handleTap(_ buffer: AVAudioPCMBuffer) {
        guard !didFallBack else { return }

        if watchdog != nil {
            let p = Self.peak(of: buffer)
            if let decision = watchdog!.observe(peakInBuffer: p, frames: Int(buffer.frameLength)) {
                watchdog = nil
                if decision == false {
                    // AEC delivered a digitally-silent opening window → fall back.
                    // Must not tear the engine down from inside the tap; hop to main.
                    didFallBack = true
                    DispatchQueue.main.async { [weak self] in self?.fallBackToCoreAudio() }
                    return
                }
            }
        }

        writeConverted(buffer)
    }

    private func writeConverted(_ buffer: AVAudioPCMBuffer) {
        guard let converter, let fileFormat, let audioFile else { return }

        let ratio = Self.targetSampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
        guard capacity > 0, let out = AVAudioPCMBuffer(pcmFormat: fileFormat, frameCapacity: capacity) else { return }

        var fed = false
        var convError: NSError?
        let status = converter.convert(to: out, error: &convError) { _, inStatus in
            if fed {
                inStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            inStatus.pointee = .haveData
            return buffer
        }

        if status == .error {
            logger.error("🎙️ AEC buffer conversion failed: \(convError?.localizedDescription ?? "unknown", privacy: .public)")
            return
        }
        guard out.frameLength > 0 else { return }
        do {
            try audioFile.write(from: out)
        } catch {
            logger.error("🎙️ AEC file write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Fallback (main thread)

    private func fallBackToCoreAudio() {
        guard isRecording, let url = recordingURL else { return }
        logger.error("🎙️ AEC produced digital silence over the opening window; falling back to CoreAudioRecorder for the rest of the session")

        // Tear down the AEC engine and close the (silent) partial file. The ~1.5s
        // silent prefix is discarded: CoreAudioRecorder recreates the SAME URL, so
        // MeetingRecorder's temp-file rename contract is untouched.
        teardownEngine()
        audioFile = nil
        converter = nil

        do {
            try fallbackRecorder.startRecording(toOutputFile: url, deviceID: deviceID)
        } catch {
            logger.error("🎙️ CoreAudioRecorder fallback ALSO failed to start: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Helpers

    private func teardownEngine() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if engine.isRunning {
            engine.stop()
        }
        try? engine.inputNode.setVoiceProcessingEnabled(false)
    }

    private func makeOutputFile(at url: URL) throws -> AVAudioFile {
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.targetSampleRate,
            AVNumberOfChannelsKey: Int(Self.targetChannels),
            AVLinearPCMBitDepthKey: Self.targetBitDepth,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        return try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )
    }

    /// Absolute peak amplitude of a Float32 mono buffer (0 for a silent buffer).
    static func peak(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData else { return 0 }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        var peak: Float = 0
        let samples = channels[0]
        for i in 0..<frames {
            let s = abs(samples[i])
            if s > peak { peak = s }
        }
        return peak
    }
}

// MARK: - Error Types

enum VoiceProcessedMicRecorderError: LocalizedError {
    case invalidFormat
    case converterUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidFormat:
            return String(localized: "Failed to build the voice-processing capture format")
        case .converterUnavailable:
            return String(localized: "Failed to create the voice-processing audio converter")
        }
    }
}
