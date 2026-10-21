import Testing
@testable import VoiceInk

@MainActor
struct MeetingLoopRetryTests {

    private let loop = "Eu vou correr aqui do meu lado."

    private func segs(_ texts: [String]) -> [TranscriptionSegment] {
        texts.enumerated().map { TranscriptionSegment(text: $0.element, t0ms: Int64($0.offset) * 1000, t1ms: 0) }
    }

    /// Stands in for Whisper: hands out `attempts` in order and records each call's prompt.
    private final class FakeWhisper {
        var attempts: [[TranscriptionSegment]]
        var prompts: [String?] = []
        init(_ attempts: [[TranscriptionSegment]]) { self.attempts = attempts }
        func transcribe(_ prompt: String?) -> [TranscriptionSegment] {
            prompts.append(prompt)
            return attempts.removeFirst()
        }
    }

    @Test func noLoopTranscribesOnceWithPrompt() async throws {
        let fake = FakeWhisper([segs(["Bom dia.", "Vamos lá."])])
        let result = try await AudioTranscriptionManager.transcribeMeetingTrack(prompt: "contexto") { fake.transcribe($0) }
        #expect(fake.prompts == ["contexto"])
        #expect(result.segments.map(\.text) == ["Bom dia.", "Vamos lá."])
        #expect(result.removedCount == 0)
        #expect(result.retriedFrom == nil)
    }

    @Test func repeatBelowThresholdDoesNotRetry() async throws {
        // 10 identical sentences → 9 removed, one short of the threshold
        let fake = FakeWhisper([segs(Array(repeating: loop, count: 10))])
        let result = try await AudioTranscriptionManager.transcribeMeetingTrack(prompt: "contexto") { fake.transcribe($0) }
        #expect(fake.prompts == ["contexto"])
        #expect(result.removedCount == 9)
        #expect(result.retriedFrom == nil)
    }

    @Test func loopRetriesWithoutPromptAndKeepsCleanRetry() async throws {
        let looped = segs(["Galera."] + Array(repeating: loop, count: 39))
        let clean = segs(["Galera.", "Ah, acabei de comer aqui."])
        let fake = FakeWhisper([looped, clean])
        let result = try await AudioTranscriptionManager.transcribeMeetingTrack(prompt: "contexto") { fake.transcribe($0) }
        #expect(fake.prompts == ["contexto", nil])
        #expect(result.segments.map(\.text) == ["Galera.", "Ah, acabei de comer aqui."])
        #expect(result.removedCount == 0)
        #expect(result.retriedFrom == 38)
    }

    @Test func retryThatLoopsAsMuchKeepsFirstAttempt() async throws {
        let first = segs(["Galera."] + Array(repeating: loop, count: 39))
        let retry = segs(["Oi."] + Array(repeating: loop, count: 50))
        let fake = FakeWhisper([first, retry])
        let result = try await AudioTranscriptionManager.transcribeMeetingTrack(prompt: "contexto") { fake.transcribe($0) }
        #expect(fake.prompts.count == 2)
        #expect(result.segments.first?.text == "Galera.")
        #expect(result.removedCount == 38)
        #expect(result.retriedFrom == 38)
    }

    @Test func emptyRetryKeepsFirstAttempt() async throws {
        let first = segs(["Galera."] + Array(repeating: loop, count: 39))
        let fake = FakeWhisper([first, segs(["", " "])])
        let result = try await AudioTranscriptionManager.transcribeMeetingTrack(prompt: "contexto") { fake.transcribe($0) }
        #expect(result.segments.first?.text == "Galera.")
        #expect(result.removedCount == 38)
        #expect(result.retriedFrom == 38)
    }
}
