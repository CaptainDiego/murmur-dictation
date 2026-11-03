import AppKit
import Carbon.HIToolbox

/// A button that captures the next key combination the user presses.
final class HotkeyRecorderButton: NSButton {
    var onCapture: ((Trigger) -> Void)?

    private var monitor: Any?
    private var isRecording = false
    private var displayedTrigger: Trigger?

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(toggleRecording)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ trigger: Trigger) {
        displayedTrigger = trigger
        guard !isRecording else { return }
        if case .modifier = trigger {
            title = "—"
            isEnabled = false
        } else {
            title = trigger.display
            isEnabled = true
        }
    }

    @objc private func toggleRecording() {
        isRecording ? endRecording() : beginRecording()
    }

    private func beginRecording() {
        isRecording = true
        title = "Press keys…"

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) {
            [weak self] event in
            guard let self, self.isRecording else { return event }

            guard event.type == .keyDown else {
                return nil  // swallow modifier changes while arming
            }

            if event.keyCode == UInt16(kVK_Escape) {
                self.endRecording()
                return nil
            }

            guard !KeyNames.isModifierKeyCode(event.keyCode) else { return nil }

            let modifiers = KeyNames.carbonModifiers(from: event.modifierFlags)
            // A bare letter would swallow that key system-wide, so require a
            // modifier unless it is a function key.
            guard modifiers != 0 || KeyNames.isFunctionKey(event.keyCode) else {
                NSSound.beep()
                return nil
            }

            let trigger = Trigger.combo(keyCode: event.keyCode, carbonModifiers: modifiers)
            self.endRecording()
            self.onCapture?(trigger)
            return nil
        }
    }

    private func endRecording() {
        isRecording = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        if let displayedTrigger {
            show(displayedTrigger)
        } else {
            title = "Click to set"
        }
    }

    override func resignFirstResponder() -> Bool {
        if isRecording { endRecording() }
        return super.resignFirstResponder()
    }
}
