import AVFoundation
import Testing
@testable import VoiceInk

struct SystemAudioConversionTests {

    // 60 s of 48 kHz stereo, fed in 1024-frame chunks the way SCStream delivers it, must come
    // out as 60 s of 16 kHz mono. The old pull block re-read each chunk and added ~4.7%.
    @available(macOS 14.4, *)
    @Test func chunkedConversionKeepsDuration() throws {
        let inFmt = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false))
        let outFmt = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: true))
        let converter = try #require(AVAudioConverter(from: inFmt, to: outFmt))

        let chunkFrames: AVAudioFrameCount = 1024
        let chunks = 60 * 48_000 / Int(chunkFrames)
        var totalOut = 0
        for chunk in 0..<chunks {
            let input = try #require(AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: chunkFrames))
            input.frameLength = chunkFrames
            for ch in 0..<2 {
                let data = input.floatChannelData![ch]
                for i in 0..<Int(chunkFrames) {
                    data[i] = sin(Float(chunk * Int(chunkFrames) + i) * 0.05) * 0.5
                }
            }
            let output = try #require(AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: chunkFrames / 3 + 16))
            let result = SystemAudioRecorder.convert(input, with: converter, into: output)
            #expect(result.status != .error)
            totalOut += Int(output.frameLength)
        }

        let expected = Double(chunks) * Double(chunkFrames) / 3.0
        // Converter latency may hold back a few frames; duplication would add ~45 000.
        #expect(abs(Double(totalOut) - expected) < 200)
    }
}
