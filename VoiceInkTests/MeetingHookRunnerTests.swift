import Testing
@testable import VoiceInk

struct MeetingHookRunnerTests {

    @Test func environmentCarriesStampAndDuration() {
        let env = MeetingHookRunner.hookEnvironment(stamp: "20250722-134501", duration: 92.4)
        #expect(env["VOICEINK_MEETING_STAMP"] == "20250722-134501")
        #expect(env["VOICEINK_MEETING_DURATION"] == "92")   // rounded to integer seconds
    }

    @Test func durationRoundsToNearestSecond() {
        #expect(MeetingHookRunner.hookEnvironment(stamp: "s", duration: 0)["VOICEINK_MEETING_DURATION"] == "0")
        #expect(MeetingHookRunner.hookEnvironment(stamp: "s", duration: 59.6)["VOICEINK_MEETING_DURATION"] == "60")
    }

    @Test func stampParsingFromFinalMicFilename() {
        // Feature 1 extracts the stamp from the mic filename before firing the hook.
        #expect(MeetingRecoveryService.parse(filename: "20250722-134501.mic.wav")?.stamp == "20250722-134501")
    }

    @Test func deliveryContextMergesAdditionalEnvironment() {
        let context = CustomCommandDeliveryContext(
            transcript: "hello",
            additionalEnvironment: ["VOICEINK_MEETING_STAMP": "20250722-134501"]
        )
        #expect(context.standardInput == "hello")
        #expect(context.environment["VOICEINK_TRANSCRIPT"] == "hello")
        #expect(context.environment["VOICEINK_MEETING_STAMP"] == "20250722-134501")
    }
}
