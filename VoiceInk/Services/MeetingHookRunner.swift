import Foundation
import os

// MARK: - Meeting Hook Runner
//
// Fires a user-configured shell command after a meeting transcript is saved. The merged
// transcript is piped to the command's stdin; the recording's stamp and duration are
// exposed as environment variables. Fire-and-forget: failures are logged, never surfaced
// into the transcription flow. Only meetings trigger this — never dictation.

enum MeetingHookRunner {
    static let commandDefaultsKey = "MeetingOnStopCommand"

    private static let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "MeetingHookRunner")

    /// Pure: the extra environment variables handed to the hook command.
    /// (The transcript itself arrives on stdin, not here.)
    static func hookEnvironment(stamp: String, duration: TimeInterval) -> [String: String] {
        [
            "VOICEINK_MEETING_STAMP": stamp,
            "VOICEINK_MEETING_DURATION": String(Int(duration.rounded()))
        ]
    }

    /// If a command is configured, run it off the main actor with the transcript on stdin.
    /// No-op when the setting is empty. Never throws.
    static func runIfConfigured(transcript: String, stamp: String, duration: TimeInterval) {
        let command = (UserDefaults.standard.string(forKey: commandDefaultsKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }

        let context = CustomCommandDeliveryContext(
            transcript: transcript,
            additionalEnvironment: hookEnvironment(stamp: stamp, duration: duration)
        )

        Task.detached(priority: .utility) {
            do {
                _ = try await CustomCommandDeliveryRunner.run(command: command, timeout: 60, context: context)
            } catch {
                logger.error("Meeting on-stop command failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
