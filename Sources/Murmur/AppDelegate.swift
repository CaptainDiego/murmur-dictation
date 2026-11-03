import AppKit
import AVFoundation
import ServiceManagement

/// What the app is doing, which drives the menu bar icon.
enum AppState: Equatable {
    case preparing(String)
    case ready
    case listening
    case transcribing
    case problem(String)
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static let triggerChanged = Notification.Name("MurmurTriggerChanged")
    static let modelChanged = Notification.Name("MurmurModelChanged")

    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let hotkey = HotkeyListener()
    private let recorder = Recorder()
    private let transcriber = Transcriber()
    private var preferences: PreferencesWindowController?

    private var state: AppState = .preparing("Starting…") { didSet { refreshStatusIcon() } }
    private var lastTranscript = ""
    private var recordingStartedAt: Date?
    /// Guards against a release arriving after we already stopped.
    private var isCapturing = false
    /// Accessibility is only checked at launch; if the user grants it
    /// afterwards in System Settings, nothing tells Murmur. This retries
    /// quietly until it notices, then stops itself.
    private var accessibilityPoll: Timer?

    /// Below this a hold-to-talk press was a mis-tap, not dictation.
    private let minimumHold: TimeInterval = 0.2

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageOnly
        menu.delegate = self
        statusItem.menu = menu
        refreshStatusIcon()

        NotificationCenter.default.addObserver(
            self, selector: #selector(applyTrigger), name: AppDelegate.triggerChanged, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(reloadModel), name: AppDelegate.modelChanged, object: nil)

        runFirstLaunchSetupIfNeeded()
        applyTrigger()
        warmUpModel()

        // Ask for the microphone up front so the first dictation is instant.
        Task { _ = await Recorder.requestMicrophoneAccess() }
    }

    /// One-time setup: start at login, and ask for the Accessibility right
    /// that watching the Fn key and pasting both depend on.
    private func runFirstLaunchSetupIfNeeded() {
        guard !Settings.shared.didFirstRun else { return }
        Settings.shared.didFirstRun = true

        do {
            try LoginItem.set(true)
        } catch {
            NSLog("Murmur: could not register login item — \(error.localizedDescription)")
        }

        if !Permissions.hasAccessibility {
            Permissions.requestAccessibility()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkey.unregister()
        stopWatchingForAccessibilityGrant()
        if recorder.isRecording { recorder.cancel() }
    }

    // MARK: - Model

    private func warmUpModel() {
        let version = Settings.shared.model.asrVersion
        state = .preparing("Loading model…")

        let transcriber = self.transcriber
        Task {
            await transcriber.prepare(version: version) { modelState in
                Task { @MainActor [weak self] in
                    self?.apply(modelState)
                }
            }
        }
    }

    private func apply(_ modelState: ModelState) {
        switch modelState {
        case .idle:
            state = .preparing("Starting…")
        case .downloading(let fraction):
            let percent = Int((fraction * 100).rounded())
            state = .preparing("Downloading model… \(percent)%")
        case .compiling:
            state = .preparing("Preparing model…")
        case .ready:
            if case .listening = state { return }
            if case .transcribing = state { return }
            state = .ready
        case .failed(let message):
            state = .problem(message)
        }
    }

    @objc private func reloadModel() {
        let transcriber = self.transcriber
        Task { [weak self] in
            await transcriber.unload()
            await MainActor.run { self?.warmUpModel() }
        }
    }

    // MARK: - Hotkey

    @objc private func applyTrigger() {
        let trigger = Settings.shared.trigger

        // Any trigger can end up needing Accessibility: a lone modifier needs
        // it to be heard at all, and paste mode needs it to deliver the
        // transcript. Ask for it up front either way so the system adds a
        // fresh entry tied to *this* running binary rather than waiting on a
        // stale one from a previous build.
        let needsAccessibility = trigger.needsAccessibilityToListen || Settings.shared.outputMode == .paste
        if needsAccessibility, !Permissions.hasAccessibility {
            Permissions.requestAccessibility()
        }

        if trigger.needsAccessibilityToListen, !Permissions.hasAccessibility {
            hotkey.unregister()
            state = .problem("Grant Accessibility to use \(trigger.display)")
            startWatchingForAccessibilityGrant()
            return
        }
        stopWatchingForAccessibilityGrant()

        hotkey.onPress = { [weak self] in self?.handlePress() }
        hotkey.onRelease = { [weak self] in self?.handleRelease() }
        hotkey.onCancel = { [weak self] in self?.handleCancel() }

        if !hotkey.register(trigger) {
            state = .problem("\(trigger.display) is already taken by another app")
            return
        }

        if case .problem = state { state = .ready }
    }

    /// Checks every second for Accessibility to turn up, so granting it in
    /// System Settings while Murmur is already running takes effect without
    /// the user having to touch Murmur's own UI first.
    private func startWatchingForAccessibilityGrant() {
        guard accessibilityPoll == nil else { return }
        accessibilityPoll = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard Permissions.hasAccessibility else { return }
                self.stopWatchingForAccessibilityGrant()
                self.applyTrigger()
            }
        }
    }

    private func stopWatchingForAccessibilityGrant() {
        accessibilityPoll?.invalidate()
        accessibilityPoll = nil
    }

    private func handlePress() {
        switch Settings.shared.activationMode {
        case .toggle:
            isCapturing ? stopAndTranscribe() : startCapture()
        case .hold:
            startCapture()
        }
    }

    private func handleRelease() {
        guard Settings.shared.activationMode == .hold else { return }
        guard isCapturing else { return }

        // Ignore an accidental brush of the key.
        if let started = recordingStartedAt, Date().timeIntervalSince(started) < minimumHold {
            discardCapture()
            return
        }
        stopAndTranscribe()
    }

    private func handleCancel() {
        guard isCapturing else { return }
        discardCapture()
    }

    // MARK: - Dictation

    private func startCapture() {
        guard !isCapturing else { return }

        Task { [weak self] in
            guard let self else { return }
            let ready = await self.transcriber.isReady
            guard ready else {
                self.flash("Model is still loading")
                return
            }
            guard await Recorder.requestMicrophoneAccess() else {
                self.report(RecorderError.microphoneDenied)
                return
            }

            do {
                try self.recorder.start()
                self.isCapturing = true
                self.recordingStartedAt = Date()
                self.state = .listening
                self.playSound(.start)
            } catch {
                self.report(error)
            }
        }
    }

    private func discardCapture() {
        recorder.cancel()
        isCapturing = false
        recordingStartedAt = nil
        state = .ready
    }

    private func stopAndTranscribe() {
        guard isCapturing else { return }
        let captured = recorder.stop()
        isCapturing = false
        recordingStartedAt = nil
        state = .transcribing
        playSound(.stop)

        Task { [weak self] in
            guard let self else { return }
            do {
                let text = try await self.transcriber.transcribe(
                    samples: captured.samples, sampleRate: captured.sampleRate)
                await MainActor.run { self.handleTranscript(text) }
            } catch {
                await MainActor.run {
                    if case TranscriberError.tooShort = error {
                        self.state = .ready
                    } else {
                        self.report(error)
                    }
                }
            }
        }
    }

    private func handleTranscript(_ text: String) {
        guard !text.isEmpty else {
            flash("Nothing was heard")
            return
        }

        lastTranscript = text
        let delivered = Paster.deliver(text, mode: Settings.shared.outputMode)
        if delivered {
            state = .ready
            playSound(.done)
        } else {
            state = .problem("Copied instead — grant Accessibility to paste")
        }
    }

    // MARK: - Feedback

    private enum Chime { case start, stop, done }

    private func playSound(_ chime: Chime) {
        guard Settings.shared.playSounds else { return }
        let name: String
        switch chime {
        case .start: name = "Tink"
        case .stop: name = "Pop"
        case .done: name = "Morse"
        }
        if chime == .done { return }  // the paste itself is the confirmation
        NSSound(named: name)?.play()
    }

    private func report(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        state = .problem(message)
    }

    /// Shows a transient message, then returns to the ready state.
    private func flash(_ message: String) {
        state = .problem(message)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, case .problem = self.state else { return }
            self.state = .ready
        }
    }

    private func refreshStatusIcon() {
        guard let button = statusItem?.button else { return }

        let symbol: String
        var tint: NSColor? = nil
        switch state {
        case .preparing:
            symbol = "arrow.down.circle"
        case .ready:
            symbol = "mic"
        case .listening:
            symbol = "mic.fill"
            tint = .systemRed
        case .transcribing:
            symbol = "waveform"
            tint = .systemBlue
        case .problem:
            symbol = "exclamationmark.triangle"
            tint = .systemOrange
        }

        let description = statusLine
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        button.image?.isTemplate = tint == nil
        button.contentTintColor = tint
        button.toolTip = "Murmur — \(description)"
    }

    /// macOS can bind the Globe key to input-source switching, emoji or its
    /// own dictation, which fires alongside Murmur. Zero or unset is clear.
    static var globeKeyIsClaimedBySystem: Bool {
        guard let value = UserDefaults.standard.persistentDomain(forName: "com.apple.HIToolbox")?["AppleFnUsageType"] as? Int
        else { return false }
        return value != 0
    }

    private var statusLine: String {
        switch state {
        case .preparing(let message): return message
        case .ready: return "Ready · \(Settings.shared.trigger.display)"
        case .listening: return "Listening…"
        case .transcribing: return "Transcribing…"
        case .problem(let message): return message
        }
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let status = NSMenuItem(title: statusLine, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        if case .problem(let message) = state, message.contains("Accessibility") {
            let fix = NSMenuItem(
                title: "Open Accessibility Settings…", action: #selector(openAccessibility),
                keyEquivalent: "")
            fix.target = self
            menu.addItem(fix)
        }

        menu.addItem(.separator())

        let toggle = NSMenuItem(
            title: isCapturing ? "Stop Dictation" : "Start Dictation",
            action: #selector(toggleDictation), keyEquivalent: "")
        toggle.target = self
        toggle.isEnabled = {
            if case .preparing = state { return false }
            return true
        }()
        menu.addItem(toggle)

        let mode = NSMenuItem(
            title: Settings.shared.activationMode == .hold
                ? "Mode: Hold \(Settings.shared.trigger.display)"
                : "Mode: Toggle with \(Settings.shared.trigger.display)",
            action: nil, keyEquivalent: "")
        mode.isEnabled = false
        menu.addItem(mode)

        if !lastTranscript.isEmpty {
            menu.addItem(.separator())
            let preview = lastTranscript.count > 48
                ? String(lastTranscript.prefix(48)) + "…"
                : lastTranscript
            let header = NSMenuItem(title: "Last: \(preview)", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)

            let copyItem = NSMenuItem(
                title: "Copy Last Transcript", action: #selector(copyLast), keyEquivalent: "")
            copyItem.target = self
            menu.addItem(copyItem)
        }

        menu.addItem(.separator())

        let prefs = NSMenuItem(
            title: "Settings…", action: #selector(showPreferences), keyEquivalent: ",")
        prefs.target = self
        menu.addItem(prefs)

        let quit = NSMenuItem(title: "Quit Murmur", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func toggleDictation() {
        isCapturing ? stopAndTranscribe() : startCapture()
    }

    @objc private func copyLast() {
        guard !lastTranscript.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastTranscript, forType: .string)
    }

    @objc private func openAccessibility() {
        Permissions.openAccessibilitySettings()
    }

    @objc private func showPreferences() {
        if preferences == nil {
            preferences = PreferencesWindowController()
        }
        NSApp.activate(ignoringOtherApps: true)
        preferences?.showWindow(nil)
        preferences?.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

/// Login-item handling, which only works from inside a real .app bundle.
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func set(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
