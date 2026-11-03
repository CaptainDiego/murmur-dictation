import Testing
import AVFoundation
@testable import Murmur
import FluidAudio

/// Exercises the real model: download (if needed), load onto the Neural
/// Engine, and transcribe a known phrase. Skipped by default since it needs
/// the ~480 MB Parakeet v3 bundle; opt in with:
///
///   MURMUR_RUN_MODEL_TESTS=1 swift test
@Suite("Transcription (real model)", .enabled(if: ProcessInfo.processInfo.environment["MURMUR_RUN_MODEL_TESTS"] != nil))
struct TranscriptionIntegrationTests {
    @Test("A synthesized phrase round-trips through Parakeet v3")
    func transcribesKnownPhrase() async throws {
        let phrase = "The quick brown fox jumps over the lazy dog"
        let audioURL = try synthesize(phrase)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let transcriber = Transcriber()
        await transcriber.prepare(version: .v3) { _ in }

        guard await transcriber.isReady else {
            Issue.record("Model failed to load")
            return
        }

        let samples = try AudioConverter(sampleRate: 16_000).resampleAudioFile(audioURL)
        let text = try await transcriber.transcribe(samples: samples, sampleRate: 16_000)

        let words = Set(text.lowercased().split(separator: " ").map(String.init))
        for expected in ["quick", "brown", "fox", "lazy", "dog"] {
            #expect(words.contains(expected), "Expected \"\(expected)\" in transcript: \(text)")
        }
    }

    @Test("Offline: cached model loads and transcribes with the network denied")
    func worksFullyOffline() async throws {
        let cacheDir = Transcriber.cacheDirectory(for: .v3)
        try #require(
            FileManager.default.fileExists(atPath: cacheDir.path),
            "Run the online test first so the model is cached"
        )

        // sandbox-exec denies all network access to this process; a genuine
        // offline claim has to survive that, not just an unplugged cable.
        let audioURL = try synthesize("Testing offline transcription")
        defer { try? FileManager.default.removeItem(at: audioURL) }

        // The test binary and the app executable are built as siblings
        // under .build/<triple>/<config>/, regardless of which one SwiftPM
        // happens to be running right now.
        let testBinaryDir = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
            .deletingLastPathComponent()
        let murmurBinary = testBinaryDir.appendingPathComponent("Murmur")
        try #require(
            FileManager.default.fileExists(atPath: murmurBinary.path),
            "Expected the Murmur executable next to the test binary at \(murmurBinary.path)"
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = [
            "-p", "(version 1)(allow default)(deny network*)",
            murmurBinary.path, "--transcribe", audioURL.path,
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(process.terminationStatus == 0)
        #expect(output.lowercased().contains("offline"))
    }

    private func synthesize(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("murmur-test-\(UUID().uuidString).aiff")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-v", "Samantha", "-o", url.path, text]
        try process.run()
        process.waitUntilExit()
        try #require(FileManager.default.fileExists(atPath: url.path))
        return url
    }
}
