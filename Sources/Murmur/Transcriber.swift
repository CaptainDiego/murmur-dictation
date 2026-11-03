import AVFoundation
import CoreML
import Foundation
import FluidAudio

/// Where the model stands right now, surfaced in the menu.
enum ModelState: Equatable {
    case idle
    case downloading(Double)
    case compiling
    case ready
    case failed(String)
}

enum TranscriberError: LocalizedError {
    case notReady
    case tooShort

    var errorDescription: String? {
        switch self {
        case .notReady: return "The speech model is still loading."
        case .tooShort: return "That was too short to transcribe."
        }
    }
}

/// Owns the Parakeet models and runs transcription off the main thread.
///
/// Everything here is local: the only network access is the one-time model
/// download from Hugging Face, after which the app works entirely offline.
actor Transcriber {
    private var manager: AsrManager?
    private var loadedVersion: AsrModelVersion?
    private var decoderLayers = 2
    private let converter = AudioConverter(sampleRate: 16_000)

    /// Parakeet needs a meaningful amount of audio; below this it is noise.
    private static let minimumSamples = 16_000 / 4  // 0.25 s at 16 kHz

    /// Downloads if needed, then loads the models onto the Neural Engine.
    func prepare(
        version: AsrModelVersion,
        onState: @escaping @Sendable (ModelState) -> Void
    ) async {
        if manager != nil, loadedVersion == version {
            onState(.ready)
            return
        }

        if let existing = manager {
            await existing.cleanup()
            manager = nil
            loadedVersion = nil
        }

        do {
            // Explicitly pin inference to the ANE. Letting it fall back to
            // CPU or GPU costs a large multiple in throughput.
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .cpuAndNeuralEngine

            let models = try await Transcriber.loadModels(
                version: version, configuration: configuration, onState: onState)

            let asr = AsrManager(config: .default)
            try await asr.loadModels(models)
            decoderLayers = await asr.decoderLayerCount
            manager = asr
            loadedVersion = version
            onState(.ready)
        } catch {
            manager = nil
            loadedVersion = nil
            onState(.failed(error.localizedDescription))
        }
    }

    /// Loads the CoreML bundles, downloading them only when they are not
    /// already on disk.
    ///
    /// Once cached, this path never touches the network: `loadLocal` reads the
    /// exact directory and resolves no repository, so Murmur keeps working on
    /// a machine that is offline.
    private static func loadModels(
        version: AsrModelVersion,
        configuration: MLModelConfiguration,
        onState: @escaping @Sendable (ModelState) -> Void
    ) async throws -> AsrModels {
        let cacheDirectory = AsrModels.defaultCacheDirectory(for: version)

        if AsrModels.modelsExist(at: cacheDirectory, version: version) {
            onState(.compiling)
            do {
                return try AsrModels.loadLocal(
                    from: cacheDirectory, version: version, configuration: configuration)
            } catch {
                // A half-written or outdated cache: fall through and refetch.
                onState(.downloading(0))
            }
        }

        return try await AsrModels.downloadAndLoad(
            configuration: configuration,
            version: version,
            progressHandler: { progress in
                switch progress.phase {
                case .listing, .downloading:
                    onState(.downloading(progress.fractionCompleted))
                case .compiling:
                    onState(.compiling)
                }
            }
        )
    }

    var isReady: Bool { manager != nil }

    /// Resamples to 16 kHz mono and runs Parakeet over it.
    func transcribe(samples: [Float], sampleRate: Double) async throws -> String {
        guard let manager else { throw TranscriberError.notReady }

        let prepared: [Float]
        if abs(sampleRate - 16_000) < 1 {
            prepared = samples
        } else {
            prepared = try converter.resample(samples, from: sampleRate)
        }

        guard prepared.count >= Transcriber.minimumSamples else {
            throw TranscriberError.tooShort
        }

        // Each utterance is independent, so the decoder starts from scratch.
        var state = try TdtDecoderState(decoderLayers: decoderLayers)
        let result = try await manager.transcribe(prepared, decoderState: &state)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Frees the CoreML models, e.g. when switching variants.
    func unload() async {
        if let manager { await manager.cleanup() }
        manager = nil
        loadedVersion = nil
    }

    /// Where the CoreML bundles live on disk.
    nonisolated static func cacheDirectory(for version: AsrModelVersion) -> URL {
        AsrModels.defaultCacheDirectory(for: version)
    }
}
