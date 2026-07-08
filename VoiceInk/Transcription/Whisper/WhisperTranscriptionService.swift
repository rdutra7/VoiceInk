import Foundation
import AVFoundation
import os

class WhisperTranscriptionService: TranscriptionService {

    private var whisperContext: WhisperContext?
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "WhisperTranscriptionService")
    private let modelsDirectory: URL
    private weak var modelProvider: (any WhisperModelProvider)?

    init(modelsDirectory: URL, modelProvider: (any WhisperModelProvider)? = nil) {
        self.modelsDirectory = modelsDirectory
        self.modelProvider = modelProvider
    }

    func transcribe(audioURL: URL, model: any TranscriptionModel, context: TranscriptionRequestContext) async throws -> String {
        let whisperContext = try await resolveContext(for: model)

        // Read audio data
        let data = try readAudioSamples(audioURL)

        // Set prompt
        await whisperContext.setLanguage(context.language)
        await whisperContext.setPrompt(context.prompt ?? "")

        // Transcribe
        let success = await whisperContext.fullTranscribe(samples: data)

        guard success else {
            logger.error("❌ Core transcription engine failed (whisper_full).")
            throw VoiceInkEngineError.whisperCoreFailed
        }

        let text = await whisperContext.getTranscription()

        logger.notice("Whisper transcription completed successfully.")

        // Only release resources if we created a new context (not using the shared one)
        if await modelProvider?.whisperContext !== whisperContext {
            await whisperContext.releaseResources()
            self.whisperContext = nil
        }

        return text
    }

    /// Transcribes pre-loaded float samples and returns timestamped segments.
    /// Uses the same context resolution and release rules as `transcribe(audioURL:model:context:)`.
    func transcribeToSegments(samples: [Float], model: any TranscriptionModel, context: TranscriptionRequestContext) async throws -> [TranscriptionSegment] {
        let whisperContext = try await resolveContext(for: model)

        await whisperContext.setLanguage(context.language)
        await whisperContext.setPrompt(context.prompt ?? "")

        let success = await whisperContext.fullTranscribe(samples: samples)

        guard success else {
            logger.error("❌ Core transcription engine failed (whisper_full) during segment transcription.")
            throw VoiceInkEngineError.whisperCoreFailed
        }

        let segments = await whisperContext.getSegments()

        // Only release resources if we created a new context (not using the shared one)
        if await modelProvider?.whisperContext !== whisperContext {
            await whisperContext.releaseResources()
            self.whisperContext = nil
        }

        return segments
    }

    // MARK: - Private Helpers

    /// Resolves (or creates) a WhisperContext for the given model.
    /// Sets `self.whisperContext` so the conditional release check in callers works correctly.
    private func resolveContext(for model: any TranscriptionModel) async throws -> WhisperContext {
        guard model.provider == .whisper else {
            throw VoiceInkEngineError.modelLoadFailed
        }

        logger.notice("Initiating local transcription for model: \(model.displayName, privacy: .public)")

        // Check if the required model is already loaded in the model provider
        if let provider = modelProvider,
           await provider.isModelLoaded,
           let loadedContext = await provider.whisperContext,
           await provider.loadedWhisperModel?.name == model.name {

            logger.notice("Using already loaded model: \(model.name, privacy: .public)")
            whisperContext = loadedContext
        } else {
            // Resolve the on-disk URL using the provider's availableModels (covers imports)
            let resolvedURL: URL? = await modelProvider?.availableModels.first(where: { $0.name == model.name })?.url
            guard let modelURL = resolvedURL, FileManager.default.fileExists(atPath: modelURL.path) else {
                logger.error("❌ Model file not found for: \(model.name, privacy: .public)")
                throw VoiceInkEngineError.modelLoadFailed
            }

            logger.notice("Loading model: \(model.name, privacy: .public)")
            do {
                whisperContext = try await WhisperContext.createContext(path: modelURL.path)
            } catch {
                logger.error("❌ Failed to load model: \(model.name, privacy: .public) - \(error, privacy: .public)")
                throw VoiceInkEngineError.modelLoadFailed
            }
        }

        guard let ctx = whisperContext else {
            logger.error("❌ Cannot transcribe: Model could not be loaded")
            throw VoiceInkEngineError.modelLoadFailed
        }

        return ctx
    }

    private func readAudioSamples(_ url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url)
        let floats = stride(from: 44, to: data.count, by: 2).map {
            return data[$0..<$0 + 2].withUnsafeBytes {
                let short = Int16(littleEndian: $0.load(as: Int16.self))
                return max(-1.0, min(Float(short) / 32767.0, 1.0))
            }
        }
        return floats
    }
}
