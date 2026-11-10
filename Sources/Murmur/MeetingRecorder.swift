import AVFoundation
import AppKit
import os

/// Readable with:
///   log show --last 1h --predicate 'subsystem == "com.murmur.dictation"' --info
private let log = Logger(subsystem: "com.murmur.dictation", category: "meetings")

/// Why a recording ended, written into the transcript.
enum MeetingStopReason: Sendable {
    case menu
    case leftCall
    case quit

    var description: String {
        switch self {
        case .menu: return "from the menu bar"
        case .leftCall: return "automatically when you left the call"
        case .quit: return "when Murmur quit"
        }
    }
}

/// Records a meeting: the user's mic on one side, whatever the Mac plays
/// (the call) on the other, then writes a timestamped Markdown transcript.
///
/// A recording starts only when the user says so, either from the menu bar
/// or from the alert shown when they join a Google Meet. A recording tied
/// to a Meet call stops by itself shortly after they leave it.
///
/// For diagnosis, the raw audio of each side, an event log and the raw
/// (pre-merge) transcripts are kept next to the Markdown file in
/// `Recordings/<same name>/`, so missing parts can be traced to either the
/// capture or the transcription. Folders older than two weeks are deleted.
@MainActor
final class MeetingRecorder {
    private struct Session {
        let startedAt: Date
        let directory: URL
        let mic: MicCapture
        let system: SystemAudioCapture
        let diagnostics: MeetingDiagnostics
        let heartbeat: Timer
        var micProblem: String?
        /// The Meet window title when this recording belongs to a Meet call;
        /// such a recording ends when the browser lets go of the mic.
        let meetTitle: String?
    }

    /// Called whenever anything the menu shows changes.
    var onChange: () -> Void = {}

    /// When the current recording started, or nil when not recording.
    var recordingSince: Date? { session?.startedAt }
    /// Meetings that have been stopped and are being transcribed right now.
    private(set) var pendingTranscripts = 0 { didSet { onChange() } }
    /// The most recent transcript written, for "Open Last Transcript".
    private(set) var lastTranscript: URL? { didSet { onChange() } }
    /// Why the last start or transcript failed, shown in the menu.
    private(set) var lastError: String? { didSet { onChange() } }

    /// The Meet call the alert is currently asking about, if any.
    private(set) var offeredMeetTitle: String? { didSet { onChange() } }

    private let transcriber: Transcriber
    private var session: Session? { didSet { onChange() } }
    private let watcher = MeetWatcher()
    private let offerAlert = MeetingOfferAlert()
    private var offerBrowser: Browser?
    /// Armed when the browser lets go of the mic mid-meeting; a short drop
    /// (device switch, reconnect) is cancelled before it fires.
    private var endTimer: Timer?
    /// Set after "Not Now" or a manual stop; cleared once the browser lets
    /// go of the mic, so the same call is not offered again.
    private var suppressedUntilMicReleased = false

    /// Leaving a call releases the mic; only a gap this long ends the
    /// recording, so a brief glitch does not.
    private let endGrace: TimeInterval = 15

    init(transcriber: Transcriber) {
        self.transcriber = transcriber
        // Anything still here is from a recording that never finished (a
        // crash or force quit). Keep it with the others for diagnosis.
        let fm = FileManager.default
        let kept = Settings.shared.meetingsFolder.appendingPathComponent("Recordings", isDirectory: true)
        for leftover in (try? fm.contentsOfDirectory(at: Self.scratchFolder, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.createDirectory(at: kept, withIntermediateDirectories: true)
            try? fm.moveItem(at: leftover, to: kept.appendingPathComponent("Unfinished \(leftover.lastPathComponent)"))
        }
        try? fm.removeItem(at: Self.scratchFolder)
        offerAlert.onStart = { [weak self] in self?.acceptOffer() }
        offerAlert.onDecline = { [weak self] in self?.declineOffer() }
        watcher.onSignal = { [weak self] signal in self?.handle(signal) }
    }

    /// Whether to watch for Meet calls and offer to transcribe them.
    func setOffersEnabled(_ enabled: Bool) {
        if enabled {
            watcher.start()
        } else {
            watcher.stop()
            withdrawOffer()
        }
    }

    /// Dictation just released the mic; see `MeetWatcher.recheck`.
    func dictationEnded() {
        watcher.recheck()
    }

    // MARK: - Meet detection

    private var lastSignal: MeetSignal?
    /// Last result of looking for a Meet tab, logged only when it changes.
    private var lastTabCheck = ""

    private func handle(_ signal: MeetSignal) {
        if signal != lastSignal {
            lastSignal = signal
            switch signal {
            case .idle: log.info("No browser is using the mic")
            case .browserMic(let browser, let title):
                log.info("\(browser.name, privacy: .public) is using the mic; Meet window: \(title != nil, privacy: .public)")
            }
        }
        switch signal {
        case .idle:
            suppressedUntilMicReleased = false
            // The call ended before anyone answered.
            withdrawOffer()
            if session?.meetTitle != nil { armEndTimer("Browser let go of the mic") }
        case .browserMic(let browser, let meetTitle):
            if let session {
                // Chrome can keep the mic open for a minute or more after
                // the user hangs up, so a closed Meet tab also ends the call.
                // The visible title alone can't tell: it only shows the tab
                // in front, and the user may just have switched tabs.
                let tabCheck = meetTitle == nil ? MeetDetector.hasMeetTab(in: browser) : true
                let described = tabCheck.map { $0 ? "yes" : "no" } ?? "can't read tabs"
                if described != lastTabCheck {
                    lastTabCheck = described
                    log.info("Meet tab open: \(described, privacy: .public)")
                }
                if session.meetTitle != nil, tabCheck == false {
                    armEndTimer("No Meet tab is open any more")
                } else {
                    if endTimer != nil { log.info("The call is back; keep recording") }
                    cancelEndTimer()
                }
            } else if let meetTitle, !suppressedUntilMicReleased, offeredMeetTitle == nil {
                offerBrowser = browser
                offeredMeetTitle = meetTitle
                log.info("Offering to transcribe the Meet call")
                offerAlert.show()
            }
        }
    }

    /// "Start Transcript" in the alert.
    func acceptOffer() {
        guard let title = offeredMeetTitle else { return }
        let browser = offerBrowser
        withdrawOffer()
        begin(meetTitle: title, browser: browser)
    }

    /// "Not Now": leave this call alone until the browser lets go of the mic.
    func declineOffer() {
        guard offeredMeetTitle != nil else { return }
        withdrawOffer()
        suppressedUntilMicReleased = true
    }

    private func withdrawOffer() {
        guard offeredMeetTitle != nil else { return }
        offerAlert.close()
        offeredMeetTitle = nil
        offerBrowser = nil
    }

    private func armEndTimer(_ why: String) {
        guard endTimer == nil else { return }
        log.info("\(why, privacy: .public); stopping in \(Int(self.endGrace)) s unless it comes back")
        endTimer = Timer.scheduledTimer(withTimeInterval: endGrace, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop(reason: .leftCall) }
        }
    }

    private func cancelEndTimer() {
        endTimer?.invalidate()
        endTimer = nil
    }

    var meetingFolder: URL { Settings.shared.meetingsFolder }

    /// Where audio waits to be transcribed, one subfolder per recording.
    private static let scratchFolder = FileManager.default.temporaryDirectory
        .appendingPathComponent("MurmurMeetings", isDirectory: true)

    /// "Start Meeting Transcript" in the menu. If a Meet call is live right
    /// now, the recording is tied to it and ends when the user leaves.
    func start() {
        if offeredMeetTitle != nil {
            acceptOffer()
            return
        }
        var meetTitle: String?
        var browser: Browser?
        if case .browserMic(let found, let title?) = MeetDetector.current() {
            meetTitle = title
            browser = found
        }
        begin(meetTitle: meetTitle, browser: browser)
    }

    /// With a browser, only that browser's audio is recorded as "others".
    private func begin(meetTitle: String?, browser: Browser?) {
        guard session == nil else { return }
        lastError = nil
        cancelEndTimer()

        let startedAt = Date()
        let directory = Self.scratchFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            lastError = "Couldn't create a recording folder: \(error.localizedDescription)"
            return
        }

        let diagnostics = MeetingDiagnostics(directory: directory, startedAt: startedAt)
        let info = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        diagnostics.note(
            "Murmur \(info), recording started (tied to Meet: \(meetTitle ?? "no"); others = \(browser?.name ?? "all apps"))")
        diagnostics.note(
            "permissions: microphone \(Recorder.microphoneAuthorized ? "granted" : "NOT granted"), system audio \(SystemAudioPermission.status)")
        let mic = MicCapture(directory: directory, startedAt: startedAt, diagnostics: diagnostics)
        let system = SystemAudioCapture(
            directory: directory, startedAt: startedAt, diagnostics: diagnostics, onlyFrom: browser)

        // The call audio is the part that matters most; without it there is
        // no point in recording.
        do {
            try system.start()
        } catch {
            lastError = "Couldn't capture the call audio. Allow Murmur in System Settings › Privacy & Security › Screen & System Audio Recording."
            NSLog("Murmur: system audio capture failed — \(error.localizedDescription)")
            diagnostics.note("[others] ERROR capture failed to start — \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: directory)
            return
        }

        var micProblem: String?
        do {
            try mic.start()
        } catch {
            micProblem = "Your microphone could not be recorded (\(error.localizedDescription)), so only the other side is transcribed."
            diagnostics.note("[me] ERROR mic failed to start — \(error.localizedDescription)")
        }

        // One line a minute per side: if the other side goes missing from
        // the transcript, this shows whether audio was arriving at the time.
        let heartbeat = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [mic, system, diagnostics] _ in
            MainActor.assumeIsolated {
                for (side, meter) in [("me", mic.meter), ("others", system.meter)] {
                    let reading = meter.takeInterval()
                    var line = "[\(side)] last minute: \(LevelMeter.describe(reading, sampleRate: meter.sampleRate))"
                    if reading.callbacks == 0 { line += " — WARNING NO AUDIO ARRIVED" }
                    else if reading.peak <= 0.0001 { line += " — silent" }
                    diagnostics.note(line)
                }
            }
        }

        log.info("Started meeting recording (tied to Meet: \(meetTitle != nil, privacy: .public); audio from: \(browser?.name ?? "all apps", privacy: .public))")
        session = Session(
            startedAt: startedAt, directory: directory, mic: mic, system: system, diagnostics: diagnostics,
            heartbeat: heartbeat, micProblem: micProblem, meetTitle: meetTitle)
    }

    func stop(reason: MeetingStopReason = .menu) {
        guard let session else { return }
        log.info("Stopping meeting recording \(reason.description, privacy: .public)")
        self.session = nil
        cancelEndTimer()
        // Stopped by hand while still in the call: don't offer it again.
        if session.meetTitle != nil, case .browserMic = MeetDetector.current() {
            suppressedUntilMicReleased = true
        }

        session.heartbeat.invalidate()
        session.mic.stop()
        session.system.stop()
        session.diagnostics.note(
            "recording stopped \(reason.description); \(session.mic.segments.count) mic segment(s), \(session.system.segments.count) others segment(s), \(session.system.silentSegments.count) silent others segment(s) skipped")

        // Leaving the call gives no other sign that the recording ended.
        if reason == .leftCall, Settings.shared.playSounds { NSSound(named: "Pop")?.play() }

        let job = MeetingJob(
            meetTitle: session.meetTitle,
            stopReason: reason,
            startedAt: session.startedAt,
            endedAt: Date(),
            directory: session.directory,
            micSegments: session.mic.segments,
            systemSegments: session.system.segments,
            systemWasSilent: !session.system.heardAnything,
            diagnostics: session.diagnostics,
            micProblem: session.micProblem,
            outputFolder: Settings.shared.meetingsFolder,
            modelLabel: Settings.shared.model.label)

        pendingTranscripts += 1
        let transcriber = self.transcriber
        Task { [weak self] in
            let outcome = await job.run(with: transcriber)
            await MainActor.run {
                guard let self else { return }
                self.pendingTranscripts -= 1
                switch outcome {
                case .success(let url):
                    self.lastTranscript = url
                case .failure(let error):
                    self.lastError =
                        "Meeting transcript failed: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
                }
            }
        }
    }
}

/// Everything needed to turn a finished recording into a Markdown file.
private struct MeetingJob: Sendable {
    let meetTitle: String?
    let stopReason: MeetingStopReason
    let startedAt: Date
    let endedAt: Date
    let directory: URL
    let micSegments: [AudioSegment]
    let systemSegments: [AudioSegment]
    let systemWasSilent: Bool
    let diagnostics: MeetingDiagnostics
    let micProblem: String?
    let outputFolder: URL
    let modelLabel: String
    var removeFillers = Settings.shared.removeFillers
    /// False when re-transcribing a folder that is already kept.
    var moveRecording = true
    /// Overrides the transcript's file name.
    var outputName: String?

    func run(with transcriber: Transcriber) async -> Result<URL, Error> {
        let base = fileBaseName(meetTitle == nil ? "Meeting" : "Google Meet")
        let keptAt = outputFolder.appendingPathComponent("Recordings", isDirectory: true)
        defer { if moveRecording { keep(in: keptAt, name: base) } }
        do {
            // The model may still be loading if Murmur was just launched.
            for _ in 0..<300 where await !transcriber.isReady {
                try await Task.sleep(for: .seconds(1))
            }

            diagnostics.note("transcribing (model ready: \(await transcriber.isReady))")
            let mine = MeetingTranscript.utterances(
                from: try await tokens(micSegments, transcriber, side: "me"), speaker: .me)
            let theirs = MeetingTranscript.utterances(
                from: try await tokens(systemSegments, transcriber, side: "others"), speaker: .others)
            let kept = MeetingTranscript.removeEcho(from: mine, heardFrom: theirs)
            // Fillers go after echo removal (which matches on every word)
            // and before merging, so a line that was only "um" disappears.
            let utterances = removeFillers
                ? MeetingTranscript.merge(
                    MeetingTranscript.removingFillers(from: kept), MeetingTranscript.removingFillers(from: theirs))
                : MeetingTranscript.merge(kept, theirs)

            // What each side said before echo removal and merging, plus what
            // the echo filter threw away.
            writeRaw(mine, to: "me-raw.txt")
            writeRaw(theirs, to: "others-raw.txt")
            let dropped = mine.filter { m in !kept.contains { $0.start == m.start && $0.text == m.text } }
            writeRaw(dropped, to: "me-dropped-as-echo.txt")
            diagnostics.note(
                "utterances: me \(mine.count) (\(dropped.count) dropped as echo), others \(theirs.count), merged \(utterances.count)")

            var notes: [String] = []
            if let micProblem { notes.append(micProblem) }
            if systemWasSilent {
                notes.append(
                    "The computer audio was silent. If others spoke, allow Murmur in System Settings › Privacy & Security › Screen & System Audio Recording.")
            }

            // Window titles carry browser noise ("- Microphone recording"),
            // so the meeting code is all that is taken from them.
            let title = meetTitle == nil ? "Meeting" : "Google Meet"
            let header = MeetingTranscript.Header(
                title: title, meetingCode: meetTitle.flatMap(MeetWindow.code(in:)),
                startedAt: startedAt, endedAt: endedAt, stoppedHow: stopReason.description,
                myName: Self.myName, model: modelLabel, notes: notes)
            let markdown = MeetingTranscript.markdown(header: header, utterances: utterances)

            try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
            let url = uniqueURL(in: outputFolder, base: outputName ?? fileBaseName(title))
            try markdown.write(to: url, atomically: true, encoding: .utf8)
            diagnostics.note("transcript written: \(url.lastPathComponent)")
            return .success(url)
        } catch {
            diagnostics.note("ERROR transcription failed — \(error.localizedDescription)")
            return .failure(error)
        }
    }

    private func tokens(_ segments: [AudioSegment], _ transcriber: Transcriber, side: String) async throws
        -> [TimedToken]
    {
        var all: [TimedToken] = []
        for (index, segment) in segments.enumerated() {
            let name = segment.url.lastPathComponent
            let duration = (try? AVAudioFile(forReading: segment.url)).map {
                Double($0.length) / $0.fileFormat.sampleRate
            } ?? 0
            do {
                let found = try await transcriber.transcribeTimed(fileAt: segment.url)
                all += found.map {
                    TimedToken(text: $0.text, start: $0.start + segment.offset, end: $0.end + segment.offset)
                }
                // Long stretches with no words inside a segment are where to
                // listen first when something seems missing.
                var gaps: [String] = []
                var previous = 0.0
                for token in found + [TimedToken(text: "", start: duration, end: duration)] {
                    if token.start - previous > 30 {
                        gaps.append(
                            "\(MeetingDiagnostics.elapsed(segment.offset + previous))–\(MeetingDiagnostics.elapsed(segment.offset + token.start))")
                    }
                    previous = max(previous, token.end)
                }
                diagnostics.note(
                    "[\(side)] \(name) (#\(index), starts +\(MeetingDiagnostics.elapsed(segment.offset)), \(String(format: "%.1f", duration)) s): \(found.count) tokens"
                        + (gaps.isEmpty ? "" : "; no words for 30 s+ at \(gaps.joined(separator: ", "))"))
            } catch TranscriberError.tooShort {
                diagnostics.note("[\(side)] \(name): skipped, too short (\(String(format: "%.1f", duration)) s)")
                continue
            } catch {
                diagnostics.note("[\(side)] ERROR \(name) failed to transcribe — \(error.localizedDescription)")
                throw error
            }
        }
        return all
    }

    private func writeRaw(_ utterances: [Utterance], to file: String) {
        let text = utterances.map {
            "[\(MeetingDiagnostics.elapsed($0.start))–\(MeetingDiagnostics.elapsed($0.end))] \($0.text)"
        }.joined(separator: "\n")
        try? text.write(to: directory.appendingPathComponent(file), atomically: true, encoding: .utf8)
    }

    /// Moves the recording folder next to the transcripts and prunes old ones.
    private func keep(in folder: URL, name: String) {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            var target = folder.appendingPathComponent(name, isDirectory: true)
            var n = 2
            while fm.fileExists(atPath: target.path) {
                target = folder.appendingPathComponent("\(name) \(n)", isDirectory: true)
                n += 1
            }
            diagnostics.note("audio and logs kept in \(target.path)")
            try fm.moveItem(at: directory, to: target)
        } catch {
            NSLog("Murmur: couldn't keep meeting recording — \(error.localizedDescription)")
        }
        let cutoff = Date().addingTimeInterval(-14 * 24 * 3600)
        for old in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey])) ?? [] {
            if let created = try? old.resourceValues(forKeys: [.creationDateKey]).creationDate, created < cutoff {
                try? fm.removeItem(at: old)
            }
        }
    }

    /// The first name from the macOS account, e.g. "Diego".
    static var myName: String {
        NSFullUserName().split(separator: " ").first.map(String.init) ?? "Me"
    }

    private func fileBaseName(_ title: String) -> String {
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HHmm"
        let safe = title.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>")).joined(separator: "-")
        return "\(stamp.string(from: startedAt)) \(safe)"
    }

    private func uniqueURL(in folder: URL, base: String) -> URL {
        var url = folder.appendingPathComponent("\(base).md")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) \(n).md")
            n += 1
        }
        return url
    }
}

/// `Murmur --retranscribe <Recordings/... folder>` rebuilds the transcript
/// from a kept recording, e.g. after a transcription fix. Segment offsets
/// come from `events.log`; a `system-N-fixed.caf` next to `system-N.caf`
/// is used instead of it (audio repaired after the fact).
enum Retranscribe {
    static func run(folder path: String) -> Never {
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        guard let log = try? String(contentsOf: folder.appendingPathComponent("events.log"), encoding: .utf8) else {
            FileHandle.standardError.write(Data("No events.log in \(path)\n".utf8))
            exit(1)
        }

        // "... +00:00:27.1 [others] segment 0 opened: ... → system-0.caf"
        var offsets: [String: TimeInterval] = [:]
        // The folder is named like its transcript: "2026-11-10 1100 Google Meet".
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HHmm"
        let startedAt = stamp.date(from: String(folder.lastPathComponent.prefix(15))) ?? Date()
        var endedAt = startedAt
        for line in log.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 2)
            guard parts.count == 3, parts[1].hasPrefix("+") else { continue }
            let hms = parts[1].dropFirst().split(separator: ":").compactMap { Double($0) }
            guard hms.count == 3 else { continue }
            let elapsed = hms[0] * 3600 + hms[1] * 60 + hms[2]
            if line.contains("recording stopped") { endedAt = startedAt.addingTimeInterval(elapsed) }
            if line.contains(" opened: "), let arrow = line.range(of: "→ ") {
                offsets[String(line[arrow.upperBound...])] = elapsed
            }
        }

        func segments(_ prefix: String) -> [AudioSegment] {
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
                .filter { $0.hasPrefix(prefix) && $0.hasSuffix(".caf") && !$0.hasSuffix("-fixed.caf") }
                .sorted()
            return names.compactMap { name in
                guard let offset = offsets[name] else { return nil }
                let fixed = name.replacingOccurrences(of: ".caf", with: "-fixed.caf")
                let use = FileManager.default.fileExists(atPath: folder.appendingPathComponent(fixed).path) ? fixed : name
                FileHandle.standardError.write(Data("\(prefix) segment \(use) at +\(offset) s\n".utf8))
                return AudioSegment(url: folder.appendingPathComponent(use), offset: offset)
            }
        }

        let transcriber = Transcriber()
        let done = DispatchSemaphore(value: 0)
        var exitCode: Int32 = 0
        let diagnostics = MeetingDiagnostics(
            directory: folder.appendingPathComponent("retranscribe", isDirectory: true)
                .creatingDirectory(), startedAt: Date())
        var job = MeetingJob(
            meetTitle: folder.lastPathComponent.contains("Google Meet") ? "Google Meet" : nil,
            stopReason: .menu, startedAt: startedAt, endedAt: endedAt,
            directory: folder.appendingPathComponent("retranscribe", isDirectory: true),
            micSegments: segments("mic-"), systemSegments: segments("system-"),
            systemWasSilent: false, diagnostics: diagnostics, micProblem: nil,
            outputFolder: folder, modelLabel: Settings.shared.model.label)
        job.moveRecording = false
        job.outputName = "retranscribed"

        Task {
            defer { done.signal() }
            await transcriber.prepare(version: Settings.shared.model.asrVersion) { _ in }
            switch await job.run(with: transcriber) {
            case .success(let url): print(url.path)
            case .failure(let error):
                FileHandle.standardError.write(Data("Failed: \(error)\n".utf8))
                exitCode = 1
            }
        }
        done.wait()
        exit(exitCode)
    }
}

private extension URL {
    func creatingDirectory() -> URL {
        try? FileManager.default.createDirectory(at: self, withIntermediateDirectories: true)
        return self
    }
}
