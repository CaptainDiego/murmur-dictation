import AppKit
import AVFoundation

@MainActor
final class PreferencesWindowController: NSWindowController, NSWindowDelegate {
    private let hotkeyButton = HotkeyRecorderButton()
    private let modifierPopup = NSPopUpButton()
    private let modePopup = NSPopUpButton()
    private let outputPopup = NSPopUpButton()
    private let modelPopup = NSPopUpButton()
    private let historyPopup = NSPopUpButton()
    private let soundsCheckbox = NSButton(checkboxWithTitle: "Play a sound when recording starts", target: nil, action: nil)
    private let meetingOffersCheckbox = NSButton(checkboxWithTitle: "Ask to transcribe when I join a Google Meet", target: nil, action: nil)
    private let loginCheckbox = NSButton(checkboxWithTitle: "Launch Murmur at login", target: nil, action: nil)
    private let micStatusLabel = NSTextField(labelWithString: "")
    private let axStatusLabel = NSTextField(labelWithString: "")

    /// Remembers the combo so toggling the modifier popup back to "None"
    /// restores what the user had rather than a default.
    private var lastCombo: Trigger = .fallback

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 610),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Murmur Settings"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self

        if case .combo = Settings.shared.trigger {
            lastCombo = Settings.shared.trigger
        }

        buildLayout()
        loadValues()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Layout

    private func buildLayout() {
        guard let content = window?.contentView else { return }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor),
        ])

        stack.addArrangedSubview(sectionTitle("Shortcut"))

        hotkeyButton.onCapture = { [weak self] trigger in
            guard let self else { return }
            self.lastCombo = trigger
            self.modifierPopup.selectItem(at: 0)
            self.commit(trigger)
        }
        stack.addArrangedSubview(row("Key combination", hotkeyButton, width: 180))

        modifierPopup.addItem(withTitle: "None — use the combination above")
        for key in ModifierKey.allCases {
            modifierPopup.addItem(withTitle: "Hold \(key.label)")
        }
        modifierPopup.target = self
        modifierPopup.action = #selector(modifierChanged)
        stack.addArrangedSubview(row("Single modifier", modifierPopup, width: 300))

        stack.addArrangedSubview(
            hint("A single modifier key is the nicest way to push-to-talk, but macOS only lets Murmur see it once Accessibility is granted."))

        if AppDelegate.globeKeyIsClaimedBySystem {
            let warning = NSTextField(
                wrappingLabelWithString:
                    "macOS currently uses the 🌐 Globe key for something else. Set “Press 🌐 key to” to “Do Nothing” so it only triggers Murmur.")
            warning.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            warning.textColor = .systemOrange
            warning.preferredMaxLayoutWidth = 350
            warning.widthAnchor.constraint(equalToConstant: 350).isActive = true

            let button = NSButton(
                title: "Open Keyboard Settings", target: self, action: #selector(openKeyboard))
            button.bezelStyle = .rounded

            let row = NSStackView(views: [warning, button])
            row.orientation = .horizontal
            row.spacing = 10
            row.alignment = .centerY
            stack.addArrangedSubview(row)
        }

        for mode in ActivationMode.allCases {
            modePopup.addItem(withTitle: mode.label)
        }
        modePopup.target = self
        modePopup.action = #selector(modeChanged)
        stack.addArrangedSubview(row("Activation", modePopup, width: 300))

        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(sectionTitle("Transcription"))

        for choice in ModelChoice.allCases {
            modelPopup.addItem(withTitle: choice.label)
        }
        modelPopup.target = self
        modelPopup.action = #selector(modelChanged)
        stack.addArrangedSubview(row("Model", modelPopup, width: 360))

        for mode in OutputMode.allCases {
            outputPopup.addItem(withTitle: mode.label)
        }
        outputPopup.target = self
        outputPopup.action = #selector(outputChanged)
        stack.addArrangedSubview(row("Transcript", outputPopup, width: 300))

        for size in TranscriptHistory.sizes {
            historyPopup.addItem(withTitle: "Last \(size) dictations")
        }
        historyPopup.target = self
        historyPopup.action = #selector(historyChanged)
        stack.addArrangedSubview(row("Recent", historyPopup, width: 200))

        stack.addArrangedSubview(
            hint("Recent dictations are kept in memory only and are forgotten when Murmur quits. The model is downloaded once, then everything runs on the Neural Engine. Murmur makes no network calls while transcribing."))

        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(sectionTitle("Permissions"))
        stack.addArrangedSubview(
            permissionRow(micStatusLabel, button: "Open Microphone Settings", action: #selector(openMic)))
        stack.addArrangedSubview(
            permissionRow(axStatusLabel, button: "Open Accessibility Settings", action: #selector(openAccessibility)))

        stack.addArrangedSubview(separator())

        soundsCheckbox.target = self
        soundsCheckbox.action = #selector(soundsChanged)
        stack.addArrangedSubview(soundsCheckbox)

        meetingOffersCheckbox.target = self
        meetingOffersCheckbox.action = #selector(meetingOffersChanged)
        stack.addArrangedSubview(meetingOffersCheckbox)

        loginCheckbox.target = self
        loginCheckbox.action = #selector(loginChanged)
        stack.addArrangedSubview(loginCheckbox)

        let reveal = NSButton(
            title: "Reveal Downloaded Models", target: self, action: #selector(revealModels))
        reveal.bezelStyle = .rounded
        stack.addArrangedSubview(reveal)
    }

    private func sectionTitle(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        return label
    }

    private func hint(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = 480
        label.widthAnchor.constraint(equalToConstant: 480).isActive = true
        return label
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.widthAnchor.constraint(equalToConstant: 480).isActive = true
        return box
    }

    private func row(_ title: String, _ control: NSView, width: CGFloat) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 120).isActive = true
        control.widthAnchor.constraint(equalToConstant: width).isActive = true

        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .firstBaseline
        return row
    }

    private func permissionRow(_ label: NSTextField, button title: String, action: Selector) -> NSStackView {
        label.widthAnchor.constraint(equalToConstant: 230).isActive = true
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        let row = NSStackView(views: [label, button])
        row.orientation = .horizontal
        row.spacing = 10
        return row
    }

    // MARK: - Values

    private func loadValues() {
        let settings = Settings.shared

        hotkeyButton.show(lastCombo)
        switch settings.trigger {
        case .combo:
            modifierPopup.selectItem(at: 0)
            hotkeyButton.show(settings.trigger)
        case .modifier(let key):
            let index = (ModifierKey.allCases.firstIndex(of: key) ?? 0) + 1
            modifierPopup.selectItem(at: index)
            hotkeyButton.show(settings.trigger)
        }

        modePopup.selectItem(at: ActivationMode.allCases.firstIndex(of: settings.activationMode) ?? 0)
        outputPopup.selectItem(at: OutputMode.allCases.firstIndex(of: settings.outputMode) ?? 0)
        modelPopup.selectItem(at: ModelChoice.allCases.firstIndex(of: settings.model) ?? 0)
        historyPopup.selectItem(at: TranscriptHistory.sizes.firstIndex(of: settings.historySize) ?? 0)
        soundsCheckbox.state = settings.playSounds ? .on : .off
        meetingOffersCheckbox.state = settings.meetingOffers ? .on : .off
        loginCheckbox.state = LoginItem.isEnabled ? .on : .off
        refreshPermissions()
    }

    private func refreshPermissions() {
        let micOK = Recorder.microphoneAuthorized
        micStatusLabel.stringValue = micOK ? "Microphone: granted" : "Microphone: not granted"
        micStatusLabel.textColor = micOK ? .secondaryLabelColor : .systemOrange

        let axOK = Permissions.hasAccessibility
        axStatusLabel.stringValue = axOK ? "Accessibility: granted" : "Accessibility: not granted"
        axStatusLabel.textColor = axOK ? .secondaryLabelColor : .systemOrange
    }

    private func commit(_ trigger: Trigger) {
        Settings.shared.trigger = trigger
        hotkeyButton.show(trigger)
        NotificationCenter.default.post(name: AppDelegate.triggerChanged, object: nil)
    }

    // MARK: - Actions

    @objc private func modifierChanged() {
        let index = modifierPopup.indexOfSelectedItem
        if index == 0 {
            commit(lastCombo)
        } else {
            let key = ModifierKey.allCases[index - 1]
            if !Permissions.hasAccessibility {
                Permissions.requestAccessibility()
            }
            commit(.modifier(key))
        }
        refreshPermissions()
    }

    @objc private func modeChanged() {
        Settings.shared.activationMode = ActivationMode.allCases[modePopup.indexOfSelectedItem]
    }

    @objc private func outputChanged() {
        Settings.shared.outputMode = OutputMode.allCases[outputPopup.indexOfSelectedItem]
        if Settings.shared.outputMode == .paste, !Permissions.hasAccessibility {
            Permissions.requestAccessibility()
            refreshPermissions()
        }
    }

    @objc private func modelChanged() {
        let choice = ModelChoice.allCases[modelPopup.indexOfSelectedItem]
        guard choice != Settings.shared.model else { return }
        Settings.shared.model = choice
        NotificationCenter.default.post(name: AppDelegate.modelChanged, object: nil)
    }

    @objc private func historyChanged() {
        Settings.shared.historySize = TranscriptHistory.sizes[historyPopup.indexOfSelectedItem]
    }

    @objc private func soundsChanged() {
        Settings.shared.playSounds = soundsCheckbox.state == .on
    }

    @objc private func meetingOffersChanged() {
        Settings.shared.meetingOffers = meetingOffersCheckbox.state == .on
        NotificationCenter.default.post(name: AppDelegate.meetingOffersChanged, object: nil)
    }

    @objc private func loginChanged() {
        do {
            try LoginItem.set(loginCheckbox.state == .on)
        } catch {
            loginCheckbox.state = LoginItem.isEnabled ? .on : .off
            let alert = NSAlert()
            alert.messageText = "Could not change the login item"
            alert.informativeText =
                "\(error.localizedDescription)\n\nThis usually means Murmur is running outside its .app bundle."
            alert.runModal()
        }
    }

    @objc private func openKeyboard() {
        Permissions.openKeyboardSettings()
    }

    @objc private func openMic() {
        Permissions.openMicrophoneSettings()
    }

    @objc private func openAccessibility() {
        Permissions.requestAccessibility()
        Permissions.openAccessibilitySettings()
    }

    @objc private func revealModels() {
        let url = Transcriber.cacheDirectory(for: Settings.shared.model.asrVersion)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Window

    func windowDidBecomeKey(_ notification: Notification) {
        refreshPermissions()
        loginCheckbox.state = LoginItem.isEnabled ? .on : .off
    }
}
