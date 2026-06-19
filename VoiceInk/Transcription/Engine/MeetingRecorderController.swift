import Foundation
import SwiftData
import SwiftUI
import os

// MARK: - Meeting Recorder Controller
//
// Thin ObservableObject wrapper around `MeetingRecorder` so SwiftUI views (menu bar,
// settings, debug panels) can drive start/stop and observe state. Singleton because
// only one meeting can be recording at a time.
@available(macOS 14.4, *)
@MainActor
final class MeetingRecorderController: ObservableObject {

    static let shared = MeetingRecorderController()

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "MeetingRecorderController")
    private let recorder = MeetingRecorder()

    @Published private(set) var isRecording = false
    @Published private(set) var startedAt: Date?
    @Published private(set) var lastError: String?

    private init() {}

    /// Starts a new meeting recording. No-op if a recording is already active.
    func start() async {
        guard !isRecording else { return }
        lastError = nil
        do {
            try await recorder.start()
            isRecording = true
            startedAt = recorder.startedAt
            logger.notice("🎬 Meeting recording started")
        } catch {
            lastError = error.localizedDescription
            isRecording = false
            startedAt = nil
            logger.error("🎬 Failed to start meeting: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Stops the current meeting recording. Once the mixed WAV is finalized it is
    /// enqueued in `AudioTranscriptionManager` so the existing pipeline transcribes
    /// it (and tags the resulting `Transcription` as `recordingType="meeting"`).
    func stop(modelContext: ModelContext, engine: VoiceInkEngine, mode: ModeConfig) async {
        guard isRecording else { return }
        isRecording = false
        let url = await recorder.stop()
        startedAt = nil

        guard let url = url else {
            logger.error("🎬 stop returned nil URL — no file to enqueue")
            return
        }

        let manager = AudioTranscriptionManager.shared
        manager.addToQueue(urls: [url], recordingType: "meeting")
        manager.startProcessing(modelContext: modelContext, engine: engine, mode: mode)
        logger.notice("🎬 Meeting enqueued for transcription → \(url.lastPathComponent, privacy: .public)")
    }
}
