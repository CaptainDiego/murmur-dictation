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
/// The audio is kept on disk only until it has been transcribed, then
/// deleted; the Markdown file is the only thing left behind.
@MainActor
final class MeetingRecorder {
    private struct Session {
        let startedAt: Date
        let directory: URL
        let mic: MicCapture
        let system: SystemAudioCapture
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
        // Audio is deleted once transcribed; anything still here is from a
        // recording that never finished (a crash or force quit). Nothing is
        // recording yet, so it is safe to clear.
        try? FileManager.default.removeItem(at: Self.scratchFolder)
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
    private var lastTabCheck: Bool?? = .none

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
                if tabCheck != lastTabCheck {
                    lastTabCheck = tabCheck
                    log.info("Meet tab open: \(tabCheck.map { $0 ? "yes" : "no" } ?? "can't read tabs", privacy: .public)")
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

        let mic = MicCapture(directory: directory, startedAt: startedAt)
        let system = SystemAudioCapture(directory: directory, startedAt: startedAt, onlyFrom: browser)

        // The call audio is the part that matters most; without it there is
        // no point in recording.
        do {
            try system.start()
        } catch {
            lastError = "Couldn't capture the call audio. Allow Murmur in System Settings › Privacy & Security › Screen & System Audio Recording."
            NSLog("Murmur: system audio capture failed — \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: directory)
            return
        }

        var micProblem: String?
        do {
            try mic.start()
        } catch {
            micProblem = "Your microphone could not be recorded (\(error.localizedDescription)), so only the other side is transcribed."
        }

        log.info("Started meeting recording (tied to Meet: \(meetTitle != nil, privacy: .public); audio from: \(browser?.name ?? "all apps", privacy: .public))")
        session = Session(
            startedAt: startedAt, directory: directory, mic: mic, system: system, micProblem: micProblem,
            meetTitle: meetTitle)
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

        session.mic.stop()
        session.system.stop()

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
    let micProblem: String?
    let outputFolder: URL
    let modelLabel: String

    func run(with transcriber: Transcriber) async -> Result<URL, Error> {
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            // The model may still be loading if Murmur was just launched.
            for _ in 0..<300 where await !transcriber.isReady {
                try await Task.sleep(for: .seconds(1))
            }

            let mine = MeetingTranscript.utterances(
                from: try await tokens(micSegments, transcriber), speaker: .me)
            let theirs = MeetingTranscript.utterances(
                from: try await tokens(systemSegments, transcriber), speaker: .others)
            let utterances = MeetingTranscript.merge(
                MeetingTranscript.removeEcho(from: mine, heardFrom: theirs), theirs)

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
            let url = uniqueURL(in: outputFolder, base: fileBaseName(title))
            try markdown.write(to: url, atomically: true, encoding: .utf8)
            return .success(url)
        } catch {
            return .failure(error)
        }
    }

    private func tokens(_ segments: [AudioSegment], _ transcriber: Transcriber) async throws -> [TimedToken] {
        var all: [TimedToken] = []
        for segment in segments {
            do {
                let found = try await transcriber.transcribeTimed(fileAt: segment.url)
                all += found.map {
                    TimedToken(text: $0.text, start: $0.start + segment.offset, end: $0.end + segment.offset)
                }
            } catch TranscriberError.tooShort {
                continue
            }
        }
        return all
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
