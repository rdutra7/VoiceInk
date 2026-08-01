import Testing
import AVFoundation
@testable import VoiceInk

struct VoiceProcessedMicRecorderTests {

    // MARK: - Recorder-selection decision

    @Test func flagOnSelectsVoiceProcessed() {
        #expect(MeetingMicKind.resolve(voiceProcessingEnabled: true) == .voiceProcessed)
    }

    @Test func flagOffSelectsCoreAudio() {
        #expect(MeetingMicKind.resolve(voiceProcessingEnabled: false) == .coreAudio)
    }

    // MARK: - Liveness watchdog decision logic

    @Test func silentWindowTriggersFallback() {
        var wd = LivenessWatchdog(windowFrames: 100)
        #expect(wd.observe(peakInBuffer: 0, frames: 50) == nil)   // still inside the window
        #expect(wd.observe(peakInBuffer: 0, frames: 50) == false) // window reached, exact-zero peak → fall back
    }

    @Test func signalBeforeWindowMeansAlive() {
        var wd = LivenessWatchdog(windowFrames: 100)
        #expect(wd.observe(peakInBuffer: 0, frames: 30) == nil)
        #expect(wd.observe(peakInBuffer: 0.5, frames: 30) == true) // any non-zero peak → alive
    }

    @Test func singleSilentBufferSpanningWindowFallsBack() {
        var wd = LivenessWatchdog(windowFrames: 100)
        #expect(wd.observe(peakInBuffer: 0, frames: 200) == false)
    }

    @Test func decisionIsSticky() {
        var wd = LivenessWatchdog(windowFrames: 100)
        #expect(wd.observe(peakInBuffer: 0.9, frames: 10) == true)
        // After deciding, further observations no longer produce a decision.
        #expect(wd.observe(peakInBuffer: 0, frames: 500) == nil)
    }

    @Test func tinySilentBuffersStayUndecidedUntilWindow() {
        var wd = LivenessWatchdog(windowFrames: 100)
        #expect(wd.observe(peakInBuffer: 0, frames: 40) == nil)
        #expect(wd.observe(peakInBuffer: 0, frames: 40) == nil)
        #expect(wd.observe(peakInBuffer: 0, frames: 40) == false) // 120 >= 100
    }

    // MARK: - Output format constants (must match CoreAudioRecorder's contract)

    @Test func targetFormatMatchesContract() {
        #expect(VoiceProcessedMicRecorder.targetSampleRate == 16_000)
        #expect(VoiceProcessedMicRecorder.targetChannels == 1)
        #expect(VoiceProcessedMicRecorder.targetBitDepth == 16)
    }

    // MARK: - Peak detection (liveness input)

    @Test func peakOfSilentBufferIsZero() throws {
        let buffer = try makeFloatBuffer(samples: [0, 0, 0, 0])
        #expect(VoiceProcessedMicRecorder.peak(of: buffer) == 0)
    }

    @Test func peakReturnsAbsoluteMaximum() throws {
        let buffer = try makeFloatBuffer(samples: [0, 0.5, -0.8, 0.1])
        #expect(VoiceProcessedMicRecorder.peak(of: buffer) == 0.8)
    }

    @Test func peakOfEmptyBufferIsZero() throws {
        let buffer = try makeFloatBuffer(samples: [])
        #expect(VoiceProcessedMicRecorder.peak(of: buffer) == 0)
    }

    // MARK: - Helpers

    private func makeFloatBuffer(samples: [Float]) throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        ))
        let buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(max(samples.count, 1))
        ))
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channel = buffer.floatChannelData {
            for (i, sample) in samples.enumerated() {
                channel[0][i] = sample
            }
        }
        return buffer
    }
}
