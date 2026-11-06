import AVFoundation
import Foundation

enum RecorderError: LocalizedError {
    case microphoneDenied
    case noInputDevice
    case engineFailed(String)

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            return "Murmur needs microphone access. Grant it in System Settings › Privacy & Security › Microphone."
        case .noInputDevice:
            return "No audio input device. A Mac mini has no built-in microphone, so plug one in and pick it in System Settings › Sound › Input."
        case .engineFailed(let detail):
            return "Could not start the microphone: \(detail)"
        }
    }
}

/// Captures microphone audio into a plain Float array.
///
/// The tap runs at whatever rate the input device uses; resampling to the
/// 16 kHz Parakeet expects happens once at the end, in `Transcriber`.
final class Recorder {
    /// Rebuilt on every `start()`. An engine caches the input device's format
    /// when its input node is first touched; reusing one after the user
    /// switches microphones (AirPods connecting, a USB mic, a new pick in
    /// System Settings › Sound) makes `installTap`/`start` raise an
    /// Objective-C exception for the format mismatch. Swift can't catch that:
    /// AppKit swallows it, but it unwinds through the Swift concurrency
    /// runtime and leaves its executor bookkeeping corrupt, so the next
    /// `MainActor.assumeIsolated` (the hotkey monitor) crashes the app.
    private var engine: AVAudioEngine?
    private let lock = NSLock()
    private var samples: [Float] = []
    private var captureRate: Double = 48_000
    private(set) var isRecording = false

    /// Prompts on first call; afterwards just reports the stored answer.
    static func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    static var microphoneAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    func start() throws {
        guard !isRecording else { return }
        guard Recorder.microphoneAuthorized else { throw RecorderError.microphoneDenied }

        // A fresh engine each time picks up a device the user switched to
        // while the app was running — see `engine`.
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw RecorderError.noInputDevice
        }

        lock.lock()
        samples.removeAll(keepingCapacity: true)
        captureRate = format.sampleRate
        lock.unlock()

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self, let channels = buffer.floatChannelData else { return }
            let frames = Int(buffer.frameLength)
            guard frames > 0 else { return }

            // Mix to mono: Parakeet wants a single channel, and averaging
            // keeps a stereo interface from halving the signal.
            var mono = [Float](repeating: 0, count: frames)
            let channelCount = Int(buffer.format.channelCount)
            if channelCount == 1 {
                mono.withUnsafeMutableBufferPointer { dst in
                    dst.baseAddress?.update(from: channels[0], count: frames)
                }
            } else {
                let scale = 1.0 / Float(channelCount)
                for channel in 0..<channelCount {
                    let src = channels[channel]
                    for frame in 0..<frames {
                        mono[frame] += src[frame] * scale
                    }
                }
            }

            self.lock.lock()
            self.samples.append(contentsOf: mono)
            self.lock.unlock()
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw RecorderError.engineFailed(error.localizedDescription)
        }
        self.engine = engine
        isRecording = true
    }

    /// Stops the tap and hands back everything captured.
    @discardableResult
    func stop() -> (samples: [Float], sampleRate: Double) {
        guard isRecording else { return ([], captureRate) }
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        isRecording = false

        lock.lock()
        let captured = samples
        let rate = captureRate
        samples.removeAll(keepingCapacity: false)
        lock.unlock()
        return (captured, rate)
    }

    /// Stops and throws the audio away.
    func cancel() {
        _ = stop()
    }

    /// Rough peak level of the most recent audio, for the menu bar indicator.
    var recentPeak: Float {
        lock.lock()
        defer { lock.unlock() }
        let window = min(samples.count, 2048)
        guard window > 0 else { return 0 }
        var peak: Float = 0
        for value in samples.suffix(window) {
            peak = max(peak, abs(value))
        }
        return peak
    }
}
