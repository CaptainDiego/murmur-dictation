import AppKit
import Carbon.HIToolbox

/// Listens for the configured trigger anywhere in the system and reports
/// key-down / key-up so the app can run either toggle or hold-to-talk.
///
/// Two very different mechanisms sit behind this one class:
///
/// * A key combination uses Carbon's `RegisterEventHotKey`, which needs no
///   special permission and reliably reports both press and release.
/// * A lone modifier key has to be watched with a global event monitor,
///   which only delivers events once Accessibility is granted.
@MainActor
final class HotkeyListener {
    var onPress: () -> Void = {}
    var onRelease: () -> Void = {}
    /// The hold was interrupted (the modifier turned out to be part of a
    /// shortcut), so whatever was captured should be thrown away.
    var onCancel: () -> Void = {}

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var flagsMonitor: Any?
    private var keyDownMonitor: Any?
    private var modifierIsDown = false

    private static let signature: OSType = 0x4D524D52  // 'MRMR'
    private static let hotKeyID: UInt32 = 1
    /// Carbon hands us a raw pointer, so the live listener is parked here.
    private static weak var active: HotkeyListener?

    private(set) var trigger: Trigger?

    // MARK: - Registration

    /// Installs the given trigger, replacing whatever was active.
    /// Returns false when the trigger could not be claimed, which for a
    /// combo means another app already owns it.
    @discardableResult
    func register(_ trigger: Trigger) -> Bool {
        unregister()
        self.trigger = trigger

        switch trigger {
        case .combo(let keyCode, let modifiers):
            return registerCarbonHotKey(keyCode: keyCode, modifiers: modifiers)
        case .modifier(let key):
            return registerModifierWatch(key)
        }
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let handler = eventHandler {
            RemoveEventHandler(handler)
            eventHandler = nil
        }
        if let monitor = flagsMonitor {
            NSEvent.removeMonitor(monitor)
            flagsMonitor = nil
        }
        if let monitor = keyDownMonitor {
            NSEvent.removeMonitor(monitor)
            keyDownMonitor = nil
        }
        modifierIsDown = false
        if HotkeyListener.active === self { HotkeyListener.active = nil }
        trigger = nil
    }

    // MARK: - Carbon combo

    private func registerCarbonHotKey(keyCode: UInt16, modifiers: UInt32) -> Bool {
        HotkeyListener.active = self

        var specs = [
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]

        let installStatus = InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, _ -> OSStatus in
                guard let event else { return OSStatus(eventNotHandledErr) }
                var id = EventHotKeyID()
                let status = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                    nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
                guard status == noErr, id.signature == HotkeyListener.signature else {
                    return OSStatus(eventNotHandledErr)
                }
                let isPress = GetEventKind(event) == UInt32(kEventHotKeyPressed)
                // Carbon calls us on the main run loop, but hop explicitly so
                // the compiler is satisfied about actor isolation.
                DispatchQueue.main.async {
                    guard let listener = HotkeyListener.active else { return }
                    if isPress { listener.onPress() } else { listener.onRelease() }
                }
                return noErr
            },
            specs.count,
            &specs,
            nil,
            &eventHandler
        )
        guard installStatus == noErr else { return false }

        let id = EventHotKeyID(signature: HotkeyListener.signature, id: HotkeyListener.hotKeyID)
        let status = RegisterEventHotKey(
            UInt32(keyCode), modifiers, id, GetEventDispatcherTarget(), 0, &hotKeyRef)
        return status == noErr && hotKeyRef != nil
    }

    // MARK: - Lone modifier

    private func registerModifierWatch(_ key: ModifierKey) -> Bool {
        guard Permissions.hasAccessibility else { return false }

        let relevant: NSEvent.ModifierFlags = [.command, .control, .option, .shift, .function]

        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) {
            [weak self] event in
            guard let self else { return }
            MainActor.assumeIsolated {
                let held = event.modifierFlags.intersection(relevant)

                guard event.keyCode == key.rawValue else {
                    // Some other modifier moved. If that happened mid-hold the
                    // user is building a shortcut, not dictating.
                    if self.modifierIsDown {
                        self.modifierIsDown = false
                        self.onCancel()
                    }
                    return
                }

                let isDown = held.contains(key.flag)
                if isDown, !self.modifierIsDown {
                    // Only fire when this key is the *only* thing held down.
                    guard held == [key.flag] || (key == .fn && held == [.function]) else { return }
                    self.modifierIsDown = true
                    self.onPress()
                } else if !isDown, self.modifierIsDown {
                    self.modifierIsDown = false
                    self.onRelease()
                }
            }
        }

        keyDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                // A real key went down while the modifier was held, so this was
                // a shortcut such as Right-Option-C.
                if self.modifierIsDown {
                    self.modifierIsDown = false
                    self.onCancel()
                }
            }
        }

        return flagsMonitor != nil
    }
}

/// Checks the two permissions the app can need, without ever prompting twice.
enum Permissions {
    /// Accessibility is needed to paste at the cursor and to watch a lone
    /// modifier key.
    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt, which also adds the app to the
    /// Accessibility list in System Settings.
    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    /// Where "Press 🌐 key to" lives.
    static func openKeyboardSettings() {
        open("x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
    }

    private static func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
