import AVFoundation
import Foundation
import os

private let osLog = Logger(subsystem: "com.murmur.dictation", category: "meetings")

/// A plain-text log of everything that happens during one recording, kept
/// next to the raw audio so a transcript with missing parts can be checked
/// against what was actually captured. Lines look like:
///
///     14:03:12.481 +00:03:12.5 [others] segment 2 opened (reason: output device changed)
///
/// Safe to call from any thread.
final class MeetingDiagnostics: @unchecked Sendable {
    let url: URL
    private let startedAt: Date
    private let lock = NSLock()
    private let handle: FileHandle?
    private let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    init(directory: URL, startedAt: Date) {
        url = directory.appendingPathComponent("events.log")
        self.startedAt = startedAt
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
    }

    deinit { try? handle?.close() }

    func note(_ message: String) {
        let now = Date()
        let line = "\(clock.string(from: now)) +\(Self.elapsed(now.timeIntervalSince(startedAt))) \(message)\n"
        lock.lock()
        defer { lock.unlock() }
        handle?.write(Data(line.utf8))
        osLog.info("\(message, privacy: .public)")
    }

    /// "+01:02:03.4" style offset into the meeting.
    static func elapsed(_ seconds: TimeInterval) -> String {
        let s = max(0, seconds)
        let whole = Int(s)
        return String(format: "%02d:%02d:%04.1f", whole / 3600, whole / 60 % 60, s - Double(whole / 60 * 60))
    }

    /// Converts a linear peak to dBFS for the log.
    static func dbfs(_ peak: Float) -> String {
        peak <= 0 ? "-inf dBFS" : String(format: "%.0f dBFS", 20 * log10(peak))
    }
}

/// Counts what one side of the call delivers, for the once-a-minute
/// heartbeat line and the per-segment summary. Fed from the audio thread,
/// read from the main thread.
final class LevelMeter: @unchecked Sendable {
    struct Reading {
        var frames: Int64 = 0
        var callbacks = 0
        var peak: Float = 0
        /// Longest stretch with no audio callbacks at all.
        var longestStall: TimeInterval = 0
    }

    private let lock = NSLock()
    private var interval = Reading()
    private var segment = Reading()
    private var lastCallback: Date?
    private let side: String
    private let diagnostics: MeetingDiagnostics
    /// The device rate of the segment being recorded, to turn frames into seconds.
    private var rate: Double = 0
    var sampleRate: Double {
        get { lock.lock(); defer { lock.unlock() }; return rate }
        set { lock.lock(); rate = newValue; lock.unlock() }
    }

    init(side: String, diagnostics: MeetingDiagnostics) {
        self.side = side
        self.diagnostics = diagnostics
    }

    func record(_ buffer: AVAudioPCMBuffer) {
        let peak = Self.peak(of: buffer)
        let now = Date()
        lock.lock()
        let stall = lastCallback.map { now.timeIntervalSince($0) } ?? 0
        lastCallback = now
        for reading in [\LevelMeter.interval, \LevelMeter.segment] {
            self[keyPath: reading].frames += Int64(buffer.frameLength)
            self[keyPath: reading].callbacks += 1
            self[keyPath: reading].peak = max(self[keyPath: reading].peak, peak)
            self[keyPath: reading].longestStall = max(self[keyPath: reading].longestStall, stall)
        }
        lock.unlock()
        // Audio normally arrives every ~10–100 ms; a gap this long means
        // samples were lost or the device stopped delivering.
        if stall > 1 {
            diagnostics.note("[\(side)] WARNING no audio callbacks for \(String(format: "%.1f", stall)) s")
        }
    }

    /// The stats since the last call, then starts a new interval.
    func takeInterval() -> Reading {
        lock.lock()
        defer { interval = Reading(); lock.unlock() }
        return interval
    }

    /// The stats since the current segment opened, then starts a new one.
    func takeSegment() -> Reading {
        lock.lock()
        defer { segment = Reading(); lastCallback = nil; lock.unlock() }
        return segment
    }

    static func peak(of buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData else { return 0 }
        let channels = buffer.format.isInterleaved ? 1 : Int(buffer.format.channelCount)
        let perChannel = Int(buffer.frameLength) * (buffer.format.isInterleaved ? Int(buffer.format.channelCount) : 1)
        var peak: Float = 0
        for channel in 0..<channels {
            for index in 0..<perChannel { peak = max(peak, abs(data[channel][index])) }
        }
        return peak
    }

    static func describe(_ r: Reading, sampleRate: Double) -> String {
        let seconds = sampleRate > 0 ? Double(r.frames) / sampleRate : 0
        return String(
            format: "%.1f s audio, %d callbacks, peak %@, longest stall %.2f s",
            seconds, r.callbacks, MeetingDiagnostics.dbfs(r.peak), r.longestStall)
    }
}
