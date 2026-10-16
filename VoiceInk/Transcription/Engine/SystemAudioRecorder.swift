import Foundation
import AVFoundation
import AudioToolbox
import ScreenCaptureKit
import CoreMedia
import os

// MARK: - System Audio Recorder (ScreenCaptureKit-based loopback capture)
//
// Mirrors the CoreAudioRecorder contract (start/stop, isCurrentlyRecording, onAudioChunk)
// so MeetingRecorder can drive a mic and a system-audio source through the same shape.
// Produces 16 kHz mono PCM Int16 WAV — same format the transcription pipeline expects.
@available(macOS 14.4, *)
final class SystemAudioRecorder: NSObject, @unchecked Sendable {

    // MARK: - Properties

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "SystemAudioRecorder")

    private var stream: SCStream?
    private var audioFile: ExtAudioFileRef?
    private let sampleHandlerQueue = DispatchQueue(
        label: "com.prakashjoshipax.voiceink.systemaudio.handler",
        qos: .userInitiated
    )

    private var isRecording = false
    private var recordingURL: URL?

    // Output format: 16 kHz mono PCM Int16 (matches CoreAudioRecorder)
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

    // SCStream input format (asked via SCStreamConfiguration: 48 kHz stereo Float32 non-interleaved)
    private let converterInputFormat: AVAudioFormat? = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 2,
        interleaved: false
    )

    // Intermediate format for AVAudioConverter (16 kHz mono Float32, then we cast to Int16)
    private let converterOutputFormat: AVAudioFormat? = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: true
    )

    private var converter: AVAudioConverter?

    // Serialize ExtAudioFileWrite vs close (stop on caller queue races with handler queue)
    private let writeLock = NSLock()

    // Streaming callback — same contract as CoreAudioRecorder.onAudioChunk
    private let audioChunkLock = NSLock()
    private var _onAudioChunk: ((_ data: Data) -> Void)?
    var onAudioChunk: ((_ data: Data) -> Void)? {
        get {
            audioChunkLock.lock()
            defer { audioChunkLock.unlock() }
            return _onAudioChunk
        }
        set {
            audioChunkLock.lock()
            _onAudioChunk = newValue
            audioChunkLock.unlock()
        }
    }

    var isCurrentlyRecording: Bool { isRecording }
    var currentRecordingURL: URL? { recordingURL }

    // MARK: - Lifecycle

    override init() {
        super.init()
    }

    deinit {
        // Best-effort sync cleanup. Caller should `await stopRecording()` first.
        writeLock.lock()
        if let file = audioFile {
            ExtAudioFileDispose(file)
            audioFile = nil
        }
        writeLock.unlock()
    }

    // MARK: - Public Interface

    /// Starts capturing system audio (mixed output of all apps except this one)
    /// and writes a WAV file at `url`. Throws if Screen Recording permission is not granted
    /// or ScreenCaptureKit cannot start.
    func startRecording(toOutputFile url: URL) async throws {
        await stopRecording()

        // 1. Enumerate shareable content (this prompts Screen Recording permission if not granted)
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
        } catch {
            logger.error("🔊 Failed to query SCShareableContent: \(error.localizedDescription, privacy: .public)")
            throw SystemAudioRecorderError.cannotEnumerateContent(error)
        }

        guard let display = content.displays.first else {
            throw SystemAudioRecorderError.noDisplayAvailable
        }

        // 2. Exclude our own bundle so VoiceInk's own sounds (notifications, transcription chime)
        //    don't bleed into the recording.
        let bundleID = Bundle.main.bundleIdentifier ?? "com.prakashjoshipax.VoiceInk"
        let ownApp = content.applications.first { $0.bundleIdentifier == bundleID }
        let excluded = ownApp.map { [$0] } ?? []
        let filter = SCContentFilter(
            display: display,
            excludingApplications: excluded,
            exceptingWindows: []
        )

        // 3. Configure stream: prioritize audio, minimize video work (we only need audio)
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        // SCStreamConfiguration requires video parameters even when we only want audio.
        // Keep them as small/slow as possible.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1) // ~1 fps
        config.queueDepth = 5
        config.showsCursor = false

        // 4. Create output WAV file
        try createOutputFile(at: url)
        recordingURL = url

        // 5. Build converter (48 kHz stereo Float32 → 16 kHz mono Float32)
        guard let inFmt = converterInputFormat,
              let outFmt = converterOutputFormat,
              let converter = AVAudioConverter(from: inFmt, to: outFmt) else {
            closeOutputFileLocked()
            recordingURL = nil
            throw SystemAudioRecorderError.converterSetupFailed
        }
        self.converter = converter

        // 6. Create + start SCStream
        let scStream = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try scStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleHandlerQueue)
        } catch {
            logger.error("🔊 Failed to add audio stream output: \(error.localizedDescription, privacy: .public)")
            closeOutputFileLocked()
            recordingURL = nil
            self.converter = nil
            throw SystemAudioRecorderError.failedToAddOutput(error)
        }

        do {
            try await scStream.startCapture()
        } catch {
            logger.error("🔊 Failed to start SCStream capture: \(error.localizedDescription, privacy: .public)")
            closeOutputFileLocked()
            recordingURL = nil
            self.converter = nil
            throw SystemAudioRecorderError.failedToStartCapture(error)
        }

        stream = scStream
        isRecording = true
        logger.notice("🔊 SystemAudioRecorder started → \(url.path, privacy: .public)")
    }

    /// Stops capture, closes the WAV file, and clears state.
    func stopRecording() async {
        guard isRecording || stream != nil else { return }

        let wasRecording = isRecording
        isRecording = false

        if wasRecording, let scStream = stream {
            do {
                try await scStream.stopCapture()
            } catch {
                logger.warning("🔊 stopCapture error: \(error.localizedDescription, privacy: .public)")
            }
        }

        stream = nil
        converter = nil

        closeOutputFileLocked()

        recordingURL = nil
        logger.notice("🔊 SystemAudioRecorder stopped")
    }

    /// Synchronous wrapper that takes the writeLock and closes the output file.
    /// Pulled out so async callers don't trigger Swift 6 lock-in-async warnings.
    private func closeOutputFileLocked() {
        writeLock.lock()
        closeOutputFile()
        writeLock.unlock()
    }

    // MARK: - File Management

    private func createOutputFile(at url: URL) throws {
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
            logger.error("🔊 ExtAudioFileCreateWithURL failed: \(status, privacy: .public)")
            throw SystemAudioRecorderError.failedToCreateFile(status: status)
        }
        audioFile = fileRef

        status = ExtAudioFileSetProperty(
            fileRef!,
            kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
            &outputFormat
        )
        if status != noErr {
            logger.error("🔊 Failed to set ClientDataFormat: \(status, privacy: .public)")
            throw SystemAudioRecorderError.failedToSetFileFormat(status: status)
        }
    }

    private func closeOutputFile() {
        if let file = audioFile {
            ExtAudioFileDispose(file)
            audioFile = nil
        }
    }

    // MARK: - Sample Buffer Processing

    fileprivate func processSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard isRecording,
              sampleBuffer.isValid,
              let inFmt = converterInputFormat,
              let outFmt = converterOutputFormat,
              let converter = converter else {
            return
        }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0 else { return }

        // Pull the AudioBufferList out of the CMSampleBuffer. SCStream gives us non-interleaved
        // stereo, so we need 2 buffers.
        let ablPointer = AudioBufferList.allocate(maximumBuffers: 2)
        defer { free(ablPointer.unsafeMutablePointer) }

        var blockBuffer: CMBlockBuffer?
        let listSize = MemoryLayout<AudioBufferList>.size + MemoryLayout<AudioBuffer>.size
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: ablPointer.unsafeMutablePointer,
            bufferListSize: listSize,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else {
            logger.warning("🔊 CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer failed: \(status, privacy: .public)")
            return
        }

        // Wrap the AudioBufferList in an AVAudioPCMBuffer (no copy)
        guard let inputPCMBuffer = AVAudioPCMBuffer(
            pcmFormat: inFmt,
            bufferListNoCopy: ablPointer.unsafePointer,
            deallocator: nil
        ) else {
            return
        }
        inputPCMBuffer.frameLength = frameCount

        // Allocate output buffer (16 kHz mono — 1/3 the frame count, with slack)
        let outputCapacity = AVAudioFrameCount(
            Double(frameCount) * outFmt.sampleRate / inFmt.sampleRate
        ) + 16
        guard let outputPCMBuffer = AVAudioPCMBuffer(
            pcmFormat: outFmt,
            frameCapacity: outputCapacity
        ) else {
            return
        }

        // Convert
        let (conversionStatus, error) = Self.convert(inputPCMBuffer, with: converter, into: outputPCMBuffer)

        if conversionStatus == .error {
            logger.warning("🔊 AVAudioConverter error: \(error?.localizedDescription ?? "unknown", privacy: .public)")
            return
        }

        guard outputPCMBuffer.frameLength > 0,
              let floatData = outputPCMBuffer.floatChannelData?[0] else {
            return
        }

        writeAndStream(samples: floatData, frameCount: Int(outputPCMBuffer.frameLength))
    }

    /// Converts one chunk, handing the converter the input exactly once. Answering
    /// `.haveData` on every pull made AVAudioConverter re-read the same chunk until the
    /// output buffer was full, adding ~16 duplicated frames per chunk (~4.7% extra audio
    /// at 48 kHz → 16 kHz), so system-audio timestamps drifted later than the mic's over
    /// a long meeting (+159 s on a 53-min recording on 2026-10-14).
    static func convert(
        _ input: AVAudioPCMBuffer,
        with converter: AVAudioConverter,
        into output: AVAudioPCMBuffer
    ) -> (status: AVAudioConverterOutputStatus, error: NSError?) {
        var error: NSError?
        var consumed = false
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return input
        }
        return (status, error)
    }

    private func writeAndStream(samples: UnsafePointer<Float>, frameCount: Int) {
        // Float32 mono → Int16 mono with clipping (same scaling as CoreAudioRecorder)
        var intSamples = [Int16](repeating: 0, count: frameCount)
        for i in 0..<frameCount {
            let scaled = samples[i] * 32767.0
            let clipped = max(-32768.0, min(32767.0, scaled))
            intSamples[i] = Int16(clipped)
        }

        // Write to file under lock (stop() can race from another queue)
        writeLock.lock()
        if let file = audioFile {
            intSamples.withUnsafeMutableBufferPointer { ptr in
                var outABL = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: 1,
                        mDataByteSize: UInt32(frameCount * MemoryLayout<Int16>.size),
                        mData: UnsafeMutableRawPointer(ptr.baseAddress)
                    )
                )
                let writeStatus = ExtAudioFileWrite(file, UInt32(frameCount), &outABL)
                if writeStatus != noErr {
                    logger.error("🔊 ExtAudioFileWrite failed: \(writeStatus, privacy: .public)")
                }
            }
        }
        writeLock.unlock()

        // Emit chunk to streaming callback if attached
        if let chunk = onAudioChunk {
            let data = intSamples.withUnsafeBytes { Data($0) }
            chunk(data)
        }
    }
}

// MARK: - SCStreamDelegate

@available(macOS 14.4, *)
extension SystemAudioRecorder: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        logger.error("🔊 SCStream stopped with error: \(error.localizedDescription, privacy: .public)")
        Task { await self.stopRecording() }
    }
}

// MARK: - SCStreamOutput

@available(macOS 14.4, *)
extension SystemAudioRecorder: SCStreamOutput {
    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio else { return }
        processSampleBuffer(sampleBuffer)
    }
}

// MARK: - Error Types

enum SystemAudioRecorderError: LocalizedError {
    case cannotEnumerateContent(Error)
    case noDisplayAvailable
    case converterSetupFailed
    case failedToAddOutput(Error)
    case failedToStartCapture(Error)
    case failedToCreateFile(status: OSStatus)
    case failedToSetFileFormat(status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .cannotEnumerateContent(let error):
            return String(format: String(localized: "Cannot enumerate shareable content (Screen Recording permission may be required): %@"), error.localizedDescription)
        case .noDisplayAvailable:
            return String(localized: "No display available for system audio capture")
        case .converterSetupFailed:
            return String(localized: "Failed to set up audio converter for system audio")
        case .failedToAddOutput(let error):
            return String(format: String(localized: "Failed to add SCStream output: %@"), error.localizedDescription)
        case .failedToStartCapture(let error):
            return String(format: String(localized: "Failed to start SCStream capture: %@"), error.localizedDescription)
        case .failedToCreateFile(let status):
            return String(format: String(localized: "Failed to create system audio file: %lld"), Int64(status))
        case .failedToSetFileFormat(let status):
            return String(format: String(localized: "Failed to set system audio file format: %lld"), Int64(status))
        }
    }
}
