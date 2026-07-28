import Foundation
import SwiftUI
import AVFoundation
import SwiftData
import os

@MainActor
class AudioTranscriptionManager: ObservableObject {
    static let shared = AudioTranscriptionManager()

    // MARK: - Published State

    @Published var queue: [AudioFileQueueItem] = []
    @Published var isProcessingQueue = false
    @Published var lastCompletedItemId: UUID?

    // MARK: - Private

    private var processingTask: Task<Void, Never>?
    private var processingGeneration: UInt64 = 0
    private let audioProcessor = AudioProcessor()
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "AudioTranscriptionManager")

    private init() {}

    // MARK: - Queue Management

    /// Add one or more audio file URLs to the queue. Invalid files are silently skipped.
    /// Pass `recordingType` to tag the resulting `Transcription` (e.g. "meeting" for
    /// files produced by MeetingRecorder).
    func addToQueue(urls: [URL], recordingType: String? = nil) {
        for url in urls {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            guard SupportedMedia.isSupported(url: url) else { continue }

            // Avoid adding the same file path twice if it's already pending/processing
            let path = url.standardizedFileURL.path
            if queue.contains(where: { $0.url.standardizedFileURL.path == path && !$0.status.isTerminal }) {
                continue
            }

            let item = AudioFileQueueItem(url: url, recordingType: recordingType)
            queue.append(item)
        }
    }

    /// Enqueue a meeting recording (two WAV files: mic + system audio).
    /// Deduplicates by mic URL path — ignores the call if the mic path is already
    /// pending/processing.
    func addMeetingToQueue(micURL: URL, systemURL: URL) {
        guard FileManager.default.fileExists(atPath: micURL.path) else { return }
        guard FileManager.default.fileExists(atPath: systemURL.path) else { return }

        let path = micURL.standardizedFileURL.path
        if queue.contains(where: { $0.url.standardizedFileURL.path == path && !$0.status.isTerminal }) {
            return
        }

        let item = AudioFileQueueItem(url: micURL, systemAudioURL: systemURL, recordingType: "meeting")
        queue.append(item)
    }

    /// Remove a pending item from the queue.
    func removeFromQueue(id: UUID) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        let item = queue[index]

        // Only allow removing pending items
        guard case .pending = item.status else { return }

        queue.remove(at: index)
    }

    /// Clear all items from the queue, cancelling any in-progress work.
    func clearAll() {
        cancelProcessing()
        queue.removeAll()
        lastCompletedItemId = nil
    }

    /// Retry a failed item by resetting it to pending and re-enqueuing.
    func retryItem(id: UUID) {
        guard let item = queue.first(where: { $0.id == id }),
              case .failed = item.status else { return }

        item.status = .pending
    }

    /// Start processing pending items in the queue sequentially.
    func startProcessing(modelContext: ModelContext, engine: VoiceInkEngine, mode: ModeConfig) {
        guard !isProcessingQueue else { return }
        isProcessingQueue = true
        processingGeneration &+= 1
        let generation = processingGeneration

        processingTask = Task { [weak self] in
            guard let self else { return }

            while let item = self.nextPendingItem() {
                guard !Task.isCancelled else { break }
                await self.processItem(item, modelContext: modelContext, engine: engine, mode: mode)
            }

            if self.processingGeneration == generation {
                self.isProcessingQueue = false
            }
        }
    }

    func cancelProcessing() {
        processingTask?.cancel()
        processingTask = nil
        isProcessingQueue = false

        // Reset any in-progress items back to pending
        for item in queue {
            if case .processing = item.status {
                item.status = .pending
            }
        }
    }

    var hasPendingItems: Bool {
        queue.contains { if case .pending = $0.status { return true }; return false }
    }

    // MARK: - Private

    private func nextPendingItem() -> AudioFileQueueItem? {
        queue.first { if case .pending = $0.status { return true }; return false }
    }

    private func processItem(_ item: AudioFileQueueItem, modelContext: ModelContext, engine: VoiceInkEngine, mode: ModeConfig) async {
        let serviceRegistry = TranscriptionServiceRegistry(
            modelProvider: engine.whisperModelManager,
            modelsDirectory: engine.whisperModelManager.modelsDirectory,
            modelContext: modelContext
        )

        do {
            guard let transcriptionConfiguration = ModeRuntimeResolver.transcriptionConfiguration(
                mode: mode,
                transcriptionModelManager: engine.transcriptionModelManager
            ) else {
                throw TranscriptionError.noModelSelected
            }
            let currentModel = transcriptionConfiguration.model

            // Route meeting items to the dedicated meeting pipeline
            if item.isMeeting {
                await processMeetingItem(item, modelContext: modelContext, engine: engine, mode: mode,
                                         transcriptionConfiguration: transcriptionConfiguration, serviceRegistry: serviceRegistry)
                await serviceRegistry.cleanup()
                return
            }

            // Phase: Loading
            item.status = .processing(phase: .loading)
            try Task.checkCancellation()

            // Phase: Processing Audio
            item.status = .processing(phase: .processingAudio)

            let accessing = item.url.startAccessingSecurityScopedResource()
            defer { if accessing { item.url.stopAccessingSecurityScopedResource() } }

            let samples = try await audioProcessor.processAudioToSamples(item.url)
            try Task.checkCancellation()

            let audioAsset = AVURLAsset(url: item.url)
            let duration = CMTimeGetSeconds(try await audioAsset.load(.duration))

            let recordingsDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("com.prakashjoshipax.VoiceInk")
                .appendingPathComponent("Recordings")

            let fileName = "transcribed_\(UUID().uuidString).wav"
            let permanentURL = recordingsDirectory.appendingPathComponent(fileName)

            try FileManager.default.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)
            try audioProcessor.saveSamplesAsWav(samples: samples, to: permanentURL)
            try Task.checkCancellation()

            // Phase: Transcribing
            item.status = .processing(phase: .transcribing)
            let transcriptionStart = Date()
            var text = try await serviceRegistry.transcribe(
                audioURL: permanentURL,
                model: currentModel,
                context: transcriptionConfiguration.requestContext
            )
            let transcriptionDuration = Date().timeIntervalSince(transcriptionStart)
            text = TranscriptionOutputFilter.filter(text)
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)

            let modeMetadata = transcriptionConfiguration.metadata
            let formattingConfiguration = ModeRuntimeResolver.transcriptionFormattingConfiguration(mode: mode)

            if formattingConfiguration.isTextFormattingEnabled {
                text = ParagraphFormatter.format(text)
            }

            text = WordReplacementService.shared.applyReplacements(to: text, using: modelContext)
            let cleanedText = TranscriptionOutputFilter.applyCleanupPreferences(
                text,
                punctuationMode: formattingConfiguration.punctuationCleanupMode,
                shouldLowercase: formattingConfiguration.lowercaseTranscription
            )
            try Task.checkCancellation()

            // Handle enhancement if enabled
            var transcription: Transcription

            let enhancementConfiguration = engine.enhancementService
                .flatMap { enhancementService in
                    enhancementService.getAIService().map { aiService in
                        ModeRuntimeResolver.currentEnhancementConfiguration(
                            mode: mode,
                            enhancementService: enhancementService,
                            aiService: aiService
                        )
                    }
                }

            if let enhancementService = engine.enhancementService,
               let enhancementConfiguration,
               enhancementConfiguration.isEnabled,
               enhancementService.isConfigured(for: enhancementConfiguration) {
                item.status = .processing(phase: .enhancing)
                do {
                    let (enhancedText, enhancementDuration, promptName) = try await enhancementService.enhance(
                        text,
                        configuration: enhancementConfiguration
                    )
                    transcription = Transcription(
                        text: cleanedText,
                        duration: duration,
                        enhancedText: enhancedText,
                        audioFileURL: permanentURL.absoluteString,
                        transcriptionModelName: currentModel.displayName,
                        aiEnhancementModelName: enhancementConfiguration.modelName ?? enhancementConfiguration.provider?.defaultModel,
                        promptName: promptName,
                        transcriptionDuration: transcriptionDuration,
                        enhancementDuration: enhancementDuration,
                        aiRequestSystemMessage: enhancementService.lastSystemMessageSent,
                        aiRequestUserMessage: enhancementService.lastUserMessageSent,
                        modeName: modeMetadata.name,
                        modeEmoji: modeMetadata.emoji
                    )
                } catch {
                    logger.error("Enhancement failed: \(error, privacy: .public)")
                    transcription = Transcription(
                        text: cleanedText,
                        duration: duration,
                        enhancedText: "Enhancement failed: \(error.localizedDescription)",
                        audioFileURL: permanentURL.absoluteString,
                        transcriptionModelName: currentModel.displayName,
                        promptName: nil,
                        transcriptionDuration: transcriptionDuration,
                        modeName: modeMetadata.name,
                        modeEmoji: modeMetadata.emoji
                    )
                }
            } else {
                transcription = Transcription(
                    text: cleanedText,
                    duration: duration,
                    audioFileURL: permanentURL.absoluteString,
                    transcriptionModelName: currentModel.displayName,
                    promptName: nil,
                    transcriptionDuration: transcriptionDuration,
                    modeName: modeMetadata.name,
                    modeEmoji: modeMetadata.emoji
                )
            }

            if let recordingType = item.recordingType {
                transcription.recordingType = recordingType
            }
            transcription.transcriptionStatus = TranscriptionStatus.completed.rawValue

            modelContext.insert(transcription)
            try modelContext.save()
            NotificationCenter.default.post(name: .transcriptionCreated, object: transcription)
            NotificationCenter.default.post(name: .transcriptionCompleted, object: transcription)

            item.transcription = transcription
            item.status = .completed
            lastCompletedItemId = item.id

        } catch {
            if Task.isCancelled || error is CancellationError {
                item.status = .pending
            } else {
                logger.error("Transcription error: \(error, privacy: .public)")
                item.status = .failed(message: error.localizedDescription)
            }
        }

        await serviceRegistry.cleanup()
    }

    // MARK: - Meeting Transcription Pipeline

    /// Decides the terminal status and whether the source WAV files should be deleted
    /// once a meeting transcript has been produced. A blank transcript (e.g. both tracks
    /// were silent) is treated as a failure so the item stays retryable and the audio
    /// is preserved instead of being destroyed with nothing to show for it.
    nonisolated static func meetingCompletionOutcome(finalText: String) -> (status: QueueItemStatus, shouldDeleteSourceAudio: Bool) {
        guard !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (.failed(message: "Meeting transcript was empty"), false)
        }
        return (.completed, true)
    }

    /// Processes a meeting item: transcribes mic and system audio separately, merges
    /// results into a speaker-labelled dialogue, and saves a Transcription with no
    /// audioFileURL. On success the two WAV files are deleted (D3). On failure or
    /// cancellation the files are kept so the item can be retried.
    private func processMeetingItem(
        _ item: AudioFileQueueItem,
        modelContext: ModelContext,
        engine: VoiceInkEngine,
        mode: ModeConfig,
        transcriptionConfiguration: TranscriptionRuntimeConfiguration,
        serviceRegistry: TranscriptionServiceRegistry
    ) async {
        let currentModel = transcriptionConfiguration.model
        let modeMetadata = transcriptionConfiguration.metadata
        let micURL = item.url

        guard let systemURL = item.systemAudioURL else {
            item.status = .failed(message: "Missing system audio URL for meeting item")
            return
        }

        do {
            // Phase: Processing Audio
            item.status = .processing(phase: .processingAudio)
            try Task.checkCancellation()

            let transcriptionStart = Date()
            var finalText: String
            var duration: TimeInterval

            if currentModel.provider == .whisper {
                // Whisper path: get segments per track, then merge by timestamp
                let whisperService = serviceRegistry.localTranscriptionService

                // Load mic samples → transcribe mic
                let micSamples = try await audioProcessor.processAudioToSamples(micURL)
                let micSampleCount = micSamples.count
                try Task.checkCancellation()

                item.status = .processing(phase: .transcribing)
                let micSegments = try await whisperService.transcribeToSegments(
                    samples: micSamples,
                    model: currentModel,
                    context: transcriptionConfiguration.requestContext
                )
                try Task.checkCancellation()

                // Load sys samples (mic samples now eligible for ARC collection)
                let sysSamples = try await audioProcessor.processAudioToSamples(systemURL)
                let sysSampleCount = sysSamples.count
                try Task.checkCancellation()

                let sysSegments = try await whisperService.transcribeToSegments(
                    samples: sysSamples,
                    model: currentModel,
                    context: transcriptionConfiguration.requestContext
                )

                duration = Double(max(micSampleCount, sysSampleCount)) / 16_000.0
                finalText = MeetingTranscriptMerger.merge(mic: micSegments, system: sysSegments)

            } else {
                // Non-whisper fallback: transcribe each WAV whole, produce two labelled blocks
                item.status = .processing(phase: .transcribing)

                let micText = try await serviceRegistry.transcribe(
                    audioURL: micURL,
                    model: currentModel,
                    context: transcriptionConfiguration.requestContext
                )
                try Task.checkCancellation()

                let sysText = try await serviceRegistry.transcribe(
                    audioURL: systemURL,
                    model: currentModel,
                    context: transcriptionConfiguration.requestContext
                )

                let micAsset = AVURLAsset(url: micURL)
                let sysAsset = AVURLAsset(url: systemURL)
                let micDuration = CMTimeGetSeconds(try await micAsset.load(.duration))
                let sysDuration = CMTimeGetSeconds(try await sysAsset.load(.duration))
                duration = max(micDuration, sysDuration)

                var blocks: [String] = []
                let trimmedMic = micText.trimmingCharacters(in: .whitespacesAndNewlines)
                let trimmedSys = sysText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedMic.isEmpty { blocks.append("Eu: \(trimmedMic)") }
                if !trimmedSys.isEmpty { blocks.append("Outro lado: \(trimmedSys)") }
                finalText = blocks.joined(separator: "\n\n")
            }

            let transcriptionDuration = Date().timeIntervalSince(transcriptionStart)

            // Apply post-processing (D6: filter + word replacements only, no paragraph formatting)
            finalText = TranscriptionOutputFilter.filter(finalText)
            finalText = WordReplacementService.shared.applyReplacements(to: finalText, using: modelContext)
            try Task.checkCancellation()

            let outcome = Self.meetingCompletionOutcome(finalText: finalText)

            if case .completed = outcome.status {
                // Save — audioFileURL is nil per D3 (WAVs will be deleted after save)
                let transcription = Transcription(
                    text: finalText,
                    duration: duration,
                    audioFileURL: nil,
                    transcriptionModelName: currentModel.displayName,
                    promptName: nil,
                    transcriptionDuration: transcriptionDuration,
                    modeName: modeMetadata.name,
                    modeEmoji: modeMetadata.emoji
                )
                transcription.recordingType = "meeting"
                transcription.transcriptionStatus = TranscriptionStatus.completed.rawValue

                modelContext.insert(transcription)
                try modelContext.save()
                NotificationCenter.default.post(name: .transcriptionCreated, object: transcription)
                NotificationCenter.default.post(name: .transcriptionCompleted, object: transcription)

                item.transcription = transcription
                item.status = outcome.status
                lastCompletedItemId = item.id

                // Post-meeting hook: pipe the transcript to a user-configured command.
                if let stamp = MeetingRecoveryService.parse(filename: micURL.lastPathComponent)?.stamp {
                    MeetingHookRunner.runIfConfigured(transcript: finalText, stamp: stamp, duration: duration)
                }
            } else {
                // Empty transcript is a permanent failure (silent audio): quarantine the WAVs
                // in Meetings/failed/ so launch recovery doesn't re-enqueue them forever.
                logger.error("Meeting transcript was empty; quarantining source audio to failed/")
                item.status = outcome.status
                MeetingRecoveryService.quarantineFailedMeeting(micURL: micURL, systemURL: systemURL)
            }

            // D3: Delete both WAV files only when the outcome says it's safe to do so
            if outcome.shouldDeleteSourceAudio {
                try? FileManager.default.removeItem(at: micURL)
                try? FileManager.default.removeItem(at: systemURL)
            }

        } catch {
            // D3: On failure or cancellation, keep WAV files for retry
            if Task.isCancelled || error is CancellationError {
                item.status = .pending
            } else {
                logger.error("Meeting transcription error: \(error, privacy: .public)")
                item.status = .failed(message: error.localizedDescription)
            }
        }
    }
}

enum TranscriptionError: Error, LocalizedError {
    case noModelSelected
    case transcriptionCancelled

    var errorDescription: String? {
        switch self {
        case .noModelSelected:
            return String(localized: "No transcription model selected")
        case .transcriptionCancelled:
            return String(localized: "Transcription was cancelled")
        }
    }
}
