import AVFoundation
import Foundation
import FluidAudio
import ServiceManagement

/// `Murmur --transcribe <audio file>` runs the exact transcription path the
/// menu bar app uses and prints the result. Handy for checking the model
/// works offline without having to speak into the microphone.
enum SelfTest {
    /// `Murmur --status` prints everything that commonly needs checking when
    /// a background menu bar app appears to do nothing.
    @MainActor
    static func printStatus() -> Never {
        let settings = Settings.shared
        let version = settings.model.asrVersion
        let cache = Transcriber.cacheDirectory(for: version)
        let cached = FileManager.default.fileExists(atPath: cache.path)

        print("Murmur status")
        print("  Trigger:        \(settings.trigger.display)")
        print("  Activation:     \(settings.activationMode.label)")
        print("  Transcript:     \(settings.outputMode.label)")
        print("  Model:          \(settings.model.label)")
        print("  Model cached:   \(cached ? "yes — runs offline" : "no — will download on first use")")
        print("  Cache path:     \(cache.path)")
        print("  Microphone:     \(Recorder.microphoneAuthorized ? "granted" : "NOT granted")")
        print("  Accessibility:  \(Permissions.hasAccessibility ? "granted" : "NOT granted")")
        print("  Launch at login:\(loginStatus())")
        if AppDelegate.globeKeyIsClaimedBySystem {
            print("  WARNING: macOS has the 🌐 Globe key bound to a system action.")
            print("           Set Keyboard › \"Press 🌐 key to\" to \"Do Nothing\".")
        }
        exit(0)
    }

    private static func loginStatus() -> String {
        switch SMAppService.mainApp.status {
        case .enabled: return " enabled"
        case .notRegistered: return " not registered"
        case .requiresApproval: return " needs approval in System Settings › General › Login Items"
        case .notFound: return " not found (run from /Applications/Murmur.app)"
        @unknown default: return " unknown"
        }
    }

    static func run(path: String) -> Never {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            FileHandle.standardError.write(Data("No such file: \(path)\n".utf8))
            exit(1)
        }

        let version = Settings.shared.model.asrVersion
        let transcriber = Transcriber()
        let done = DispatchSemaphore(value: 0)
        var exitCode: Int32 = 0

        Task {
            defer { done.signal() }

            await transcriber.prepare(version: version) { state in
                switch state {
                case .downloading(let fraction):
                    let percent = Int((fraction * 100).rounded())
                    FileHandle.standardError.write(Data("\rDownloading model… \(percent)%".utf8))
                case .compiling:
                    FileHandle.standardError.write(Data("\rPreparing model…       ".utf8))
                case .ready:
                    FileHandle.standardError.write(Data("\rModel ready.           \n".utf8))
                case .failed(let message):
                    FileHandle.standardError.write(Data("\nModel failed: \(message)\n".utf8))
                case .idle:
                    break
                }
            }

            guard await transcriber.isReady else {
                exitCode = 1
                return
            }

            do {
                // AudioConverter handles any format AVFoundation can read and
                // normalises to the 16 kHz mono Parakeet expects.
                let samples = try AudioConverter(sampleRate: 16_000).resampleAudioFile(url)
                let started = Date()
                let text = try await transcriber.transcribe(samples: samples, sampleRate: 16_000)
                let elapsed = Date().timeIntervalSince(started)
                let audioSeconds = Double(samples.count) / 16_000

                print(text)
                let speed = elapsed > 0 ? audioSeconds / elapsed : 0
                FileHandle.standardError.write(
                    Data(
                        String(
                            format: "\n[%.1fs of audio in %.2fs — %.0fx realtime]\n",
                            audioSeconds, elapsed, speed
                        ).utf8))
            } catch {
                FileHandle.standardError.write(Data("Transcription failed: \(error)\n".utf8))
                exitCode = 1
            }
        }

        done.wait()
        exit(exitCode)
    }
}
