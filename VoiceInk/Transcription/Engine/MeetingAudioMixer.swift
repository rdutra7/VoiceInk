import Foundation
import AudioToolbox
import os

// MARK: - Meeting Audio Mixer
//
// Mixes two synchronized Int16 mono streams (microphone + system audio, both at 16 kHz)
// into a single WAV file. Both source streams arrive via callbacks (`feedMic`, `feedSystem`)
// and are paired sample-for-sample as they become available — when both buffers have
// `n` frames, the next `n` frames get summed (with clipping protection) and written.
//
// This pairing approach avoids realtime sync code (mach_absolute_time, drift correction):
// in practice both sources are clocked to the same system clock at 16 kHz, so they stay
// aligned over typical meeting durations. The only effect is the constant offset from
// whichever source produces its first chunk first — at < 200 ms it's imperceptible.
final class MeetingAudioMixer: @unchecked Sendable {

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "MeetingAudioMixer")

    private var audioFile: ExtAudioFileRef?

    // Output: 16 kHz mono PCM Int16 (matches both inputs)
    private var outputFormat = AudioStreamBasicDescription(
        mSampleRate: 16000.0,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 2,
        mFramesPerPacket: 1,
        mBytesPerFrame: 2,
        mChannelsPerFrame: 1,
        mBitsPerChannel: 16,
        mReserved: 0
    )

    // Serial queue serializes feed + drain so we don't need a separate mutex around buffers.
    private let queue = DispatchQueue(
        label: "com.prakashjoshipax.voiceink.meeting.mixer",
        qos: .userInitiated
    )

    private var micBuffer: [Int16] = []
    private var sysBuffer: [Int16] = []
    private var isOpen = false
    private var totalFramesWritten: UInt64 = 0

    // MARK: - Lifecycle

    init() {}

    deinit {
        if let file = audioFile {
            ExtAudioFileDispose(file)
        }
    }

    /// Opens the output WAV file at `url`. Throws if the file can't be created.
    /// Idempotent: closing then re-opening with a new URL is fine.
    func open(at url: URL) throws {
        try queue.sync {
            close_locked()

            if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
            }
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            var fileRef: ExtAudioFileRef?
            var status = ExtAudioFileCreateWithURL(
                url as CFURL,
                kAudioFileWAVEType,
                &outputFormat,
                nil,
                AudioFileFlags.eraseFile.rawValue,
                &fileRef
            )
            if status != noErr {
                logger.error("🎬 ExtAudioFileCreateWithURL failed: \(status, privacy: .public)")
                throw MeetingAudioMixerError.failedToCreateFile(status: status)
            }

            status = ExtAudioFileSetProperty(
                fileRef!,
                kExtAudioFileProperty_ClientDataFormat,
                UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
                &outputFormat
            )
            if status != noErr {
                ExtAudioFileDispose(fileRef!)
                logger.error("🎬 Failed to set ClientDataFormat: \(status, privacy: .public)")
                throw MeetingAudioMixerError.failedToSetFileFormat(status: status)
            }

            audioFile = fileRef
            micBuffer.removeAll(keepingCapacity: true)
            sysBuffer.removeAll(keepingCapacity: true)
            totalFramesWritten = 0
            isOpen = true
            logger.notice("🎬 Mixer opened → \(url.path, privacy: .public)")
        }
    }

    /// Closes the output file. Any remaining samples in only one buffer (no pair to mix
    /// against) are flushed as-is so a meeting with one silent side still records both
    /// sides' content.
    func close() {
        queue.sync {
            flushRemainder_locked()
            close_locked()
        }
    }

    /// Feeds microphone samples (16 kHz mono Int16, raw little-endian bytes).
    func feedMic(_ data: Data) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.append_locked(data: data, to: &self.micBuffer)
            self.drainPair_locked()
        }
    }

    /// Feeds system audio samples (16 kHz mono Int16, raw little-endian bytes).
    func feedSystem(_ data: Data) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.append_locked(data: data, to: &self.sysBuffer)
            self.drainPair_locked()
        }
    }

    // MARK: - Internals (run on `queue`)

    private func append_locked(data: Data, to buffer: inout [Int16]) {
        let sampleCount = data.count / MemoryLayout<Int16>.size
        guard sampleCount > 0 else { return }
        let startIdx = buffer.count
        buffer.append(contentsOf: repeatElement(Int16(0), count: sampleCount))
        _ = buffer.withUnsafeMutableBufferPointer { dst in
            data.copyBytes(
                to: UnsafeMutableRawBufferPointer(
                    start: dst.baseAddress?.advanced(by: startIdx),
                    count: sampleCount * MemoryLayout<Int16>.size
                )
            )
        }
    }

    private func drainPair_locked() {
        guard isOpen, audioFile != nil else { return }
        let pairFrames = min(micBuffer.count, sysBuffer.count)
        guard pairFrames > 0 else { return }

        var mixed = [Int16](repeating: 0, count: pairFrames)
        for i in 0..<pairFrames {
            let sum = Int32(micBuffer[i]) &+ Int32(sysBuffer[i])
            mixed[i] = Int16(max(Int32(Int16.min), min(Int32(Int16.max), sum)))
        }

        write_locked(samples: mixed)

        micBuffer.removeFirst(pairFrames)
        sysBuffer.removeFirst(pairFrames)
    }

    private func flushRemainder_locked() {
        // Whichever buffer is longer when we close has samples that arrived without a
        // pair from the other source — usually because one source stopped first or one
        // produced very little. Write those samples as-is.
        if !micBuffer.isEmpty {
            write_locked(samples: micBuffer)
            micBuffer.removeAll(keepingCapacity: true)
        }
        if !sysBuffer.isEmpty {
            write_locked(samples: sysBuffer)
            sysBuffer.removeAll(keepingCapacity: true)
        }
    }

    private func write_locked(samples: [Int16]) {
        guard let file = audioFile, !samples.isEmpty else { return }
        let frameCount = UInt32(samples.count)
        var localSamples = samples
        localSamples.withUnsafeMutableBufferPointer { ptr in
            var outABL = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 1,
                    mDataByteSize: frameCount * UInt32(MemoryLayout<Int16>.size),
                    mData: UnsafeMutableRawPointer(ptr.baseAddress)
                )
            )
            let status = ExtAudioFileWrite(file, frameCount, &outABL)
            if status != noErr {
                logger.error("🎬 ExtAudioFileWrite failed: \(status, privacy: .public)")
            } else {
                totalFramesWritten &+= UInt64(frameCount)
            }
        }
    }

    private func close_locked() {
        if let file = audioFile {
            ExtAudioFileDispose(file)
            audioFile = nil
        }
        isOpen = false
    }
}

// MARK: - Error Types

enum MeetingAudioMixerError: LocalizedError {
    case failedToCreateFile(status: OSStatus)
    case failedToSetFileFormat(status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .failedToCreateFile(let status):
            return String(format: String(localized: "Failed to create mixed audio file: %lld"), Int64(status))
        case .failedToSetFileFormat(let status):
            return String(format: String(localized: "Failed to set mixed audio file format: %lld"), Int64(status))
        }
    }
}
