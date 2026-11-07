import AVFoundation
import CoreAudio
import Foundation

/// One continuous stretch of audio on disk. A capture is split into several
/// whenever the device underneath it changes (AirPods connecting, a new mic
/// picked in Sound settings), and `offset` places each one on the meeting's
/// clock so timestamps stay right across the switch.
struct AudioSegment: Sendable {
    let url: URL
    /// Seconds from the start of the meeting to the first sample.
    let offset: TimeInterval
}

/// Writes audio to disk as 16 kHz mono 16-bit PCM, the format Parakeet
/// runs on anyway. Recording at the device rate (often 48 kHz, 32-bit
/// float) would take about 6× the space for no gain in accuracy:
/// roughly 2 MB per minute per side instead of 11.5 MB.
///
/// Not thread-safe; each capture calls it from one serial context.
final class DownsamplingWriter {
    static let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    private let converter: AVAudioConverter
    private let file: AVAudioFile

    init(url: URL, inputFormat: AVAudioFormat) throws {
        guard let converter = AVAudioConverter(from: inputFormat, to: Self.format) else {
            throw CoreAudioSupport.Failure(what: "Setting up the audio converter", status: -1)
        }
        // Average all channels rather than keeping only the first.
        converter.downmix = true
        self.converter = converter
        file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
            ],
            commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        let ratio = Self.format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard buffer.frameLength > 0,
            let output = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: capacity)
        else { return }

        // The converter keeps its resampling state between calls, so feeding
        // it one buffer at a time gives a seamless stream.
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        if error == nil, output.frameLength > 0 {
            try? file.write(from: output)
        }
    }
}

/// Records the microphone (the "me" side of a call) to disk.
///
/// A new `AVAudioEngine` is built for every segment: reusing one after the
/// input device changes makes `installTap` raise an Objective-C exception
/// for the format mismatch (see `Recorder.engine`).
@MainActor
final class MicCapture {
    private let directory: URL
    private let startedAt: Date
    private var engine: AVAudioEngine?
    private var configObserver: NSObjectProtocol?
    private(set) var segments: [AudioSegment] = []

    init(directory: URL, startedAt: Date) {
        self.directory = directory
        self.startedAt = startedAt
    }

    func start() throws {
        try openSegment()
    }

    func stop() {
        closeSegment()
    }

    private func openSegment() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw RecorderError.noInputDevice }

        let url = directory.appendingPathComponent("mic-\(segments.count).caf")
        let writer = try DownsamplingWriter(url: url, inputFormat: format)

        // The tap runs on an AVAudioEngine thread (not the real-time one),
        // where converting and writing are fine.
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            writer.write(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw RecorderError.engineFailed(error.localizedDescription)
        }

        self.engine = engine
        segments.append(AudioSegment(url: url, offset: Date().timeIntervalSince(startedAt)))

        // The engine stops itself when the input device changes underneath it.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.deviceChanged() }
        }
    }

    private func closeSegment() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        // Dropping the engine releases the tap closure, which closes the file.
        engine = nil
    }

    private func deviceChanged() {
        closeSegment()
        reopen(attempt: 0)
    }

    /// A device that is mid-switch can briefly report no format, so retry.
    private func reopen(attempt: Int) {
        do {
            try openSegment()
        } catch {
            guard attempt < 10 else {
                NSLog("Murmur: meeting mic could not restart — \(error.localizedDescription)")
                return
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                self?.reopen(attempt: attempt + 1)
            }
        }
    }
}

/// Records what the Mac plays (the "others" side of a call) with a Core
/// Audio process tap, macOS 14.2+. For a Meet call only the browser it runs
/// in is recorded, so music, notifications and other apps stay out; Core
/// Audio cannot tell one tab from another, so other tabs in that browser
/// still come through. Without a browser (a manual start, any meeting app)
/// everything but Murmur's own sounds is recorded. The tap needs the
/// "System Audio Recording" permission; macOS asks the first time.
@MainActor
final class SystemAudioCapture {
    private let directory: URL
    private let startedAt: Date
    private let queue = DispatchQueue(label: "com.murmur.meeting.system-audio")

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var outputListener: AudioObjectPropertyListenerBlock?
    private var processListener: AudioObjectPropertyListenerBlock?
    private var permissionRetry: Timer?
    /// Whether the last entry in `segments` is still being recorded.
    private var segmentOpen = false
    /// When set, only this browser's processes are recorded.
    private let browser: Browser?
    /// The browser processes the current tap covers.
    private var tappedProcesses: Set<AudioObjectID> = []
    private(set) var segments: [AudioSegment] = []

    /// Loudest sample seen, touched only on `queue`. Stays at zero when the
    /// permission was refused, since the tap then delivers pure silence.
    nonisolated(unsafe) private var peak: Float = 0
    /// Loudest sample in the segment being recorded now, also on `queue`.
    /// A segment that stays silent is thrown away when it closes, so the
    /// pieces left by `retryUntilHeard` never reach Parakeet, which tends
    /// to invent words ("thank you", "um") when fed silence.
    nonisolated(unsafe) private var segmentPeak: Float = 0
    /// Below this, a sample counts as silence (about -80 dBFS).
    nonisolated private static let silence: Float = 0.0001

    init(directory: URL, startedAt: Date, onlyFrom browser: Browser? = nil) {
        self.directory = directory
        self.startedAt = startedAt
        self.browser = browser
    }

    func start() throws {
        try openSegment()
        watchOutputDevice()
        if browser != nil { watchProcesses() }
        retryUntilHeard()
    }

    /// A tap created while macOS is still asking for the "System Audio
    /// Recording" permission (the first meeting after installing) delivers
    /// silence for its whole life, even once the user clicks Allow. So while
    /// nothing has been heard yet, rebuild it every few seconds; the first
    /// rebuild after the grant gets real audio. The silent pieces this
    /// leaves behind hold no speech and are skipped when transcribing.
    private func retryUntilHeard() {
        let started = Date()
        permissionRetry = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, !self.heardAnything, Date().timeIntervalSince(started) < 60 else {
                    timer.invalidate()
                    return
                }
                self.restartSegment(because: nil)
            }
        }
    }

    func stop() {
        permissionRetry?.invalidate()
        permissionRetry = nil
        removeListener(&outputListener, kAudioHardwarePropertyDefaultOutputDevice)
        removeListener(&processListener, kAudioHardwarePropertyProcessObjectList)
        closeSegment()
    }

    private func removeListener(
        _ listener: inout AudioObjectPropertyListenerBlock?, _ selector: AudioObjectPropertySelector
    ) {
        guard let block = listener else { return }
        var addr = CoreAudioSupport.address(selector)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, block)
        listener = nil
    }

    /// Swaps in a fresh tap and capture device; logged unless routine.
    private func restartSegment(because reason: String?) {
        if let reason { NSLog("Murmur: \(reason); restarting system audio capture") }
        closeSegment()
        do {
            try openSegment()
        } catch {
            NSLog("Murmur: system audio capture could not restart — \(error.localizedDescription)")
        }
    }

    /// The browser's processes that Core Audio knows about right now.
    private func browserProcesses() -> Set<AudioObjectID> {
        guard let browser else { return [] }
        return Set(
            CoreAudioSupport.processes()
                .filter { process in browser.audioPrefixes.contains { process.bundleID.hasPrefix($0) } }
                .map(\.objectID))
    }

    /// True once any non-silent audio came through the tap.
    var heardAnything: Bool {
        queue.sync { peak > Self.silence }
    }

    private func openSegment() throws {
        let description: CATapDescription
        if browser != nil {
            tappedProcesses = browserProcesses()
            description = CATapDescription(monoMixdownOfProcesses: Array(tappedProcesses))
        } else {
            let own = CoreAudioSupport.ownProcessObject().map { [$0] } ?? []
            description = CATapDescription(monoGlobalTapButExcludeProcesses: own)
        }
        description.uuid = UUID()
        description.name = "Murmur meeting capture"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        try CoreAudioSupport.check(AudioHardwareCreateProcessTap(description, &tap), "Creating the audio tap")
        tapID = tap

        do {
            var addr = CoreAudioSupport.address(kAudioTapPropertyFormat)
            var asbd = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try CoreAudioSupport.check(
                AudioObjectGetPropertyData(tap, &addr, 0, nil, &size, &asbd), "Reading the tap format")
            guard let format = AVAudioFormat(streamDescription: &asbd) else {
                throw CoreAudioSupport.Failure(what: "Reading the tap format", status: -1)
            }

            // A tap is read through a private aggregate device that wraps the
            // current output device.
            let outputUID = try CoreAudioSupport.defaultOutputDeviceUID()
            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Murmur Meeting Capture",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
                kAudioAggregateDeviceTapListKey: [
                    [
                        kAudioSubTapDriftCompensationKey: true,
                        kAudioSubTapUIDKey: description.uuid.uuidString,
                    ]
                ],
            ]
            var device = AudioObjectID(kAudioObjectUnknown)
            try CoreAudioSupport.check(
                AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device),
                "Creating the capture device")
            aggregateID = device

            let url = directory.appendingPathComponent("system-\(segments.count).caf")
            let writer = try DownsamplingWriter(url: url, inputFormat: format)
            queue.sync { segmentPeak = 0 }

            // With a dispatch queue the block runs there, not on the real-time
            // I/O thread, so writing the file directly is safe.
            var proc: AudioDeviceIOProcID?
            try CoreAudioSupport.check(
                AudioDeviceCreateIOProcIDWithBlock(&proc, device, queue) { [weak self] _, input, _, _, _ in
                    guard
                        let buffer = AVAudioPCMBuffer(
                            pcmFormat: format, bufferListNoCopy: input, deallocator: nil)
                    else { return }
                    self?.trackPeak(buffer)
                    writer.write(buffer)
                }, "Starting system audio capture")
            procID = proc
            try CoreAudioSupport.check(AudioDeviceStart(device, proc), "Starting system audio capture")

            segments.append(AudioSegment(url: url, offset: Date().timeIntervalSince(startedAt)))
            segmentOpen = true
        } catch {
            closeSegment()
            throw error
        }
    }

    nonisolated private func trackPeak(_ buffer: AVAudioPCMBuffer) {
        guard segmentPeak <= Self.silence, let data = buffer.floatChannelData else { return }
        let count = Int(buffer.frameLength) * (buffer.format.isInterleaved ? Int(buffer.format.channelCount) : 1)
        for index in 0..<count where abs(data[0][index]) > segmentPeak {
            segmentPeak = abs(data[0][index])
        }
        peak = max(peak, segmentPeak)
    }

    private func closeSegment() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        // Let any write still queued finish before the file is let go.
        let silent = queue.sync { segmentPeak <= Self.silence }
        if segmentOpen, silent, let last = segments.popLast() {
            try? FileManager.default.removeItem(at: last.url)
        }
        segmentOpen = false
    }

    /// The browser can start a new audio process mid-call (Chromium restarts
    /// its audio service now and then), so re-tap when the set changes.
    private func watchProcesses() {
        var addr = CoreAudioSupport.address(kAudioHardwarePropertyProcessObjectList)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, self.browserProcesses() != self.tappedProcesses else { return }
                self.restartSegment(because: "browser audio processes changed")
            }
        }
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, listener)
        processListener = listener
    }

    /// The aggregate device wraps one specific output device, so switching
    /// to AirPods mid-call needs a fresh one.
    private func watchOutputDevice() {
        var addr = CoreAudioSupport.address(kAudioHardwarePropertyDefaultOutputDevice)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.restartSegment(because: "output device changed")
            }
        }
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, listener)
        outputListener = listener
    }
}
