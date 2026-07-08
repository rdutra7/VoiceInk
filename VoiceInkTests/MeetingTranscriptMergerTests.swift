import Testing
@testable import VoiceInk

struct MeetingTranscriptMergerTests {

    // Convenience helper
    private func seg(_ text: String, t0ms: Int64, t1ms: Int64 = 0) -> TranscriptionSegment {
        TranscriptionSegment(text: text, t0ms: t0ms, t1ms: t1ms)
    }

    // (1) Interleaving A/B/A — segments from both sides interleave correctly
    @Test func interleaving() {
        let mic = [seg("Bom dia.", t0ms: 0), seg("Vamos começar.", t0ms: 2000)]
        let sys = [seg("Perfeito.", t0ms: 1000)]
        let result = MeetingTranscriptMerger.merge(mic: mic, system: sys)
        #expect(result == "Eu: Bom dia.\n\nOutro lado: Perfeito.\n\nEu: Vamos começar.")
    }

    // (2) Consecutive grouping — consecutive segments from the same side are joined
    @Test func consecutiveGrouping() {
        let mic = [seg("Primeiro.", t0ms: 0), seg("Segundo.", t0ms: 500)]
        let sys = [seg("Resposta.", t0ms: 2000)]
        let result = MeetingTranscriptMerger.merge(mic: mic, system: sys)
        #expect(result == "Eu: Primeiro. Segundo.\n\nOutro lado: Resposta.")
    }

    // (3) Silent side — only one side has content
    @Test func silentSide() {
        let mic: [TranscriptionSegment] = []
        let sys = [seg("Só eu falo.", t0ms: 0)]
        let result = MeetingTranscriptMerger.merge(mic: mic, system: sys)
        #expect(result == "Outro lado: Só eu falo.")
    }

    // (4) Both empty → empty string
    @Test func bothEmpty() {
        let result = MeetingTranscriptMerger.merge(mic: [], system: [])
        #expect(result == "")
    }

    // (5) Whitespace/blank segments are discarded
    @Test func whitespaceSegmentsDiscarded() {
        let mic = [seg("  ", t0ms: 0), seg("Real text.", t0ms: 1000)]
        let sys = [seg("\n", t0ms: 500)]
        let result = MeetingTranscriptMerger.merge(mic: mic, system: sys)
        #expect(result == "Eu: Real text.")
    }

    // (6) Tie on t0ms is deterministic: mic (side 0) comes before system (side 1)
    @Test func tieDeterministicMicFirst() {
        let mic = [seg("Mic.", t0ms: 1000)]
        let sys = [seg("Sys.", t0ms: 1000)]
        let result = MeetingTranscriptMerger.merge(mic: mic, system: sys)
        #expect(result == "Eu: Mic.\n\nOutro lado: Sys.")
    }
}
