import Testing
@testable import VoiceInk

struct MeetingCompletionOutcomeTests {

    @Test func emptyTranscriptFailsAndKeepsAudio() {
        let outcome = AudioTranscriptionManager.meetingCompletionOutcome(finalText: "")
        #expect(outcome.status == .failed(message: "Meeting transcript was empty"))
        #expect(outcome.shouldDeleteSourceAudio == false)
    }

    @Test func blankAfterTrimFailsAndKeepsAudio() {
        let outcome = AudioTranscriptionManager.meetingCompletionOutcome(finalText: "   \n ")
        #expect(outcome.status == .failed(message: "Meeting transcript was empty"))
        #expect(outcome.shouldDeleteSourceAudio == false)
    }

    @Test func nonEmptyTranscriptCompletesAndDeletesAudio() {
        let outcome = AudioTranscriptionManager.meetingCompletionOutcome(finalText: "Eu: olá")
        #expect(outcome.status == .completed)
        #expect(outcome.shouldDeleteSourceAudio == true)
    }
}
