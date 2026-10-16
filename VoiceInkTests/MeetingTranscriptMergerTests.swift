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

    // (7) Whisper loop across and within segments collapses to the first occurrence
    @Test func repetitionLoopCollapsed() {
        let loop = "E aí, eu vou fazer o que eu estou com a gente."
        let mic = [
            seg(loop, t0ms: 0),
            seg("\(loop) \(loop)", t0ms: 1000),
            seg("e aí eu vou fazer o que eu estou com a gente!", t0ms: 2000),
            seg(loop, t0ms: 3000),
            seg("Qual o dia que vai funcionar?", t0ms: 4000),
        ]
        let (cleaned, removed) = MeetingTranscriptMerger.collapseRepeatedSentences(mic)
        #expect(removed == 4)
        #expect(cleaned.map(\.text) == [loop, "", "", "", "Qual o dia que vai funcionar?"])
        #expect(cleaned.map(\.t0ms) == [0, 1000, 2000, 3000, 4000])
        let merged = MeetingTranscriptMerger.merge(mic: cleaned, system: [])
        #expect(merged == "Eu: \(loop) Qual o dia que vai funcionar?")
    }

    // (8) Short natural repeats are not touched
    @Test func shortRepeatsKept() {
        let mic = [seg("Tchau. Tchau. Tchau.", t0ms: 0), seg("Sim. Sim.", t0ms: 1000)]
        let (cleaned, removed) = MeetingTranscriptMerger.collapseRepeatedSentences(mic)
        #expect(removed == 0)
        #expect(cleaned.map(\.text) == ["Tchau. Tchau. Tchau.", "Sim. Sim."])
    }

    // (9) Segments without removals keep their exact original text
    @Test func untouchedSegmentsKeepOriginalText() {
        let odd = "Custa 1.500 pontos...  certo?Sim"
        let mic = [seg(odd, t0ms: 0), seg("Ok.", t0ms: 500), seg("Ok.", t0ms: 600),
                   seg("Ok.", t0ms: 700), seg("Ok.", t0ms: 800)]
        let (cleaned, removed) = MeetingTranscriptMerger.collapseRepeatedSentences(mic)
        #expect(removed == 3)
        #expect(cleaned[0].text == odd)
        #expect(cleaned.map(\.text) == [odd, "Ok.", "", "", ""])
    }
}
