import Testing
@testable import VoiceInk

struct MeetingRecoveryServiceTests {

    // MARK: - Stamp validation

    @Test func validStampIsAccepted() {
        #expect(MeetingRecoveryService.isValidStamp("20250722-134501"))
    }

    @Test func invalidStampsAreRejected() {
        #expect(!MeetingRecoveryService.isValidStamp("2025-07-22"))
        #expect(!MeetingRecoveryService.isValidStamp("20250722134501"))     // missing dash
        #expect(!MeetingRecoveryService.isValidStamp("2025072a-134501"))    // non-digit
        #expect(!MeetingRecoveryService.isValidStamp("20250722-13450"))     // too short
        #expect(!MeetingRecoveryService.isValidStamp(""))
    }

    // MARK: - Filename parsing

    @Test func parsesFinalFilenames() {
        #expect(MeetingRecoveryService.parse(filename: "20250722-134501.mic.wav")
            == ParsedMeetingFile(stamp: "20250722-134501", track: "mic", isTmp: false))
        #expect(MeetingRecoveryService.parse(filename: "20250722-134501.sys.wav")
            == ParsedMeetingFile(stamp: "20250722-134501", track: "sys", isTmp: false))
    }

    @Test func parsesHiddenTmpFilenames() {
        #expect(MeetingRecoveryService.parse(filename: ".20250722-134501.mic.tmp.wav")
            == ParsedMeetingFile(stamp: "20250722-134501", track: "mic", isTmp: true))
        #expect(MeetingRecoveryService.parse(filename: ".20250722-134501.sys.tmp.wav")
            == ParsedMeetingFile(stamp: "20250722-134501", track: "sys", isTmp: true))
    }

    @Test func rejectsUnrelatedFilenames() {
        #expect(MeetingRecoveryService.parse(filename: "failed") == nil)
        #expect(MeetingRecoveryService.parse(filename: ".DS_Store") == nil)
        #expect(MeetingRecoveryService.parse(filename: "20250722-134501.mic.tmp.wav") == nil) // tmp without leading dot
        #expect(MeetingRecoveryService.parse(filename: ".20250722-134501.mic.wav") == nil)    // final with leading dot
        #expect(MeetingRecoveryService.parse(filename: "notastamp.mic.wav") == nil)
    }

    // MARK: - Recovery planning

    @Test func finalPairEnqueues() {
        let actions = MeetingRecoveryService.recoveryActions(for: [
            "20250722-134501.mic.wav",
            "20250722-134501.sys.wav"
        ])
        #expect(actions == [.enqueuePair(stamp: "20250722-134501")])
    }

    @Test func tmpPairIsRenamed() {
        let actions = MeetingRecoveryService.recoveryActions(for: [
            ".20250722-134501.mic.tmp.wav",
            ".20250722-134501.sys.tmp.wav"
        ])
        #expect(actions == [.renameTmpPair(stamp: "20250722-134501")])
    }

    @Test func loneFinalIsIgnored() {
        let actions = MeetingRecoveryService.recoveryActions(for: [
            "20250722-134501.mic.wav"
        ])
        #expect(actions == [.ignoreLone(filename: "20250722-134501.mic.wav")])
    }

    @Test func loneTmpIsIgnored() {
        let actions = MeetingRecoveryService.recoveryActions(for: [
            ".20250722-134501.sys.tmp.wav"
        ])
        #expect(actions == [.ignoreLone(filename: ".20250722-134501.sys.tmp.wav")])
    }

    @Test func failedSubdirAndJunkAreExcluded() {
        let actions = MeetingRecoveryService.recoveryActions(for: [
            "failed",
            ".DS_Store",
            "20250722-134501.mic.wav",
            "20250722-134501.sys.wav"
        ])
        #expect(actions == [.enqueuePair(stamp: "20250722-134501")])
    }

    @Test func mixedListIsHandledDeterministically() {
        let actions = MeetingRecoveryService.recoveryActions(for: [
            // complete final pair
            "20250722-100000.sys.wav",
            "20250722-100000.mic.wav",
            // complete tmp pair
            ".20250722-110000.mic.tmp.wav",
            ".20250722-110000.sys.tmp.wav",
            // lone final mic
            "20250722-120000.mic.wav",
            // lone tmp sys
            ".20250722-130000.sys.tmp.wav",
            // junk
            "failed"
        ])
        // Pairs first (sorted by stamp), then lone files (sorted by name).
        #expect(actions == [
            .enqueuePair(stamp: "20250722-100000"),
            .renameTmpPair(stamp: "20250722-110000"),
            .ignoreLone(filename: ".20250722-130000.sys.tmp.wav"),
            .ignoreLone(filename: "20250722-120000.mic.wav")
        ])
    }

    @Test func emptyListYieldsNoActions() {
        #expect(MeetingRecoveryService.recoveryActions(for: []).isEmpty)
    }
}
