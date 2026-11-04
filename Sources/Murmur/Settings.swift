import AppKit
import Carbon.HIToolbox
import Foundation
import FluidAudio

/// How the hotkey starts and stops dictation.
enum ActivationMode: String, CaseIterable {
    /// Press once to start, press again to stop.
    case toggle
    /// Record only while the key is held down.
    case hold

    var label: String {
        switch self {
        case .toggle: return "Press to start, press again to stop"
        case .hold: return "Hold to talk, release to transcribe"
        }
    }
}

/// What happens to the transcript once it is ready.
enum OutputMode: String, CaseIterable {
    /// Paste at the cursor in the frontmost app (needs Accessibility).
    case paste
    /// Only put it on the clipboard.
    case copyOnly

    var label: String {
        switch self {
        case .paste: return "Paste at the cursor"
        case .copyOnly: return "Copy to clipboard only"
        }
    }
}

/// The Parakeet variants we expose. All run locally on the Neural Engine.
enum ModelChoice: String, CaseIterable {
    case v3
    case ultra
    case v2
    case bark3Clean

    var asrVersion: AsrModelVersion {
        switch self {
        case .v3: return .v3
        case .ultra: return .ultra
        case .v2: return .v2
        case .bark3Clean: return .bark3Clean
        }
    }

    var label: String {
        switch self {
        case .v3: return "Parakeet TDT v3 — 25 languages (~480 MB)"
        case .ultra: return "Parakeet Ultra — v3 retrained, more accurate (~480 MB)"
        case .v2: return "Parakeet TDT v2 — English only, best recall (~480 MB)"
        case .bark3Clean: return "Bark 3.0 Clean — English, drops filler words (~480 MB)"
        }
    }
}

/// A single modifier key that can be used on its own as the trigger.
/// These are the nicest choice for hold-to-talk, but reading them
/// system-wide needs Accessibility permission.
enum ModifierKey: UInt16, CaseIterable {
    case rightOption = 61
    case leftOption = 58
    case rightCommand = 54
    case rightControl = 62
    case fn = 63

    var label: String {
        switch self {
        case .rightOption: return "Right Option (⌥)"
        case .leftOption: return "Left Option (⌥)"
        case .rightCommand: return "Right Command (⌘)"
        case .rightControl: return "Right Control (⌃)"
        case .fn: return "Fn / 🌐 Globe"
        }
    }

    /// The flag that is set while this key is down.
    var flag: NSEvent.ModifierFlags {
        switch self {
        case .rightOption, .leftOption: return .option
        case .rightCommand: return .command
        case .rightControl: return .control
        case .fn: return .function
        }
    }
}

/// The trigger: either a normal key combination or a lone modifier key.
enum Trigger: Equatable {
    case combo(keyCode: UInt16, carbonModifiers: UInt32)
    case modifier(ModifierKey)

    static let fallback = Trigger.combo(
        keyCode: UInt16(kVK_ANSI_D),
        carbonModifiers: UInt32(optionKey)
    )

    /// Human-readable form for menus, e.g. "⌃⌥D".
    var display: String {
        switch self {
        case .modifier(let key):
            return key.label
        case .combo(let keyCode, let mods):
            var out = ""
            if mods & UInt32(controlKey) != 0 { out += "⌃" }
            if mods & UInt32(optionKey) != 0 { out += "⌥" }
            if mods & UInt32(shiftKey) != 0 { out += "⇧" }
            if mods & UInt32(cmdKey) != 0 { out += "⌘" }
            return out + KeyNames.name(for: keyCode)
        }
    }

    /// Reading a lone modifier key globally requires Accessibility.
    var needsAccessibilityToListen: Bool {
        if case .modifier = self { return true }
        return false
    }
}

/// All persisted preferences, backed by UserDefaults.
final class Settings {
    static let shared = Settings()

    private let defaults = UserDefaults.standard
    private enum Key {
        static let triggerKind = "trigger.kind"
        static let triggerKeyCode = "trigger.keyCode"
        static let triggerModifiers = "trigger.carbonModifiers"
        static let activationMode = "activationMode"
        static let outputMode = "outputMode"
        static let model = "model"
        static let playSounds = "playSounds"
        static let trimTrailingNewline = "trimTrailingNewline"
        static let didFirstRun = "didFirstRun"
        static let historySize = "historySize"
    }

    private init() {
        defaults.register(defaults: [
            // Hold ⌥D to talk. A combo needs no Accessibility permission to
            // listen for, so dictation works the moment the app launches;
            // the user can switch to Fn or any other key in Settings.
            Key.triggerKind: "combo",
            Key.triggerKeyCode: Int(kVK_ANSI_D),
            Key.triggerModifiers: Int(optionKey),
            Key.activationMode: ActivationMode.hold.rawValue,
            Key.outputMode: OutputMode.paste.rawValue,
            Key.model: ModelChoice.v3.rawValue,
            Key.playSounds: true,
            Key.trimTrailingNewline: true,
            Key.historySize: 5,
        ])
    }

    var trigger: Trigger {
        get {
            if defaults.string(forKey: Key.triggerKind) == "modifier" {
                let raw = UInt16(defaults.integer(forKey: Key.triggerKeyCode))
                if let key = ModifierKey(rawValue: raw) { return .modifier(key) }
                return .fallback
            }
            let code = UInt16(defaults.integer(forKey: Key.triggerKeyCode))
            let mods = UInt32(defaults.integer(forKey: Key.triggerModifiers))
            guard mods != 0 || KeyNames.isFunctionKey(code) else { return .fallback }
            return .combo(keyCode: code, carbonModifiers: mods)
        }
        set {
            switch newValue {
            case .combo(let code, let mods):
                defaults.set("combo", forKey: Key.triggerKind)
                defaults.set(Int(code), forKey: Key.triggerKeyCode)
                defaults.set(Int(mods), forKey: Key.triggerModifiers)
            case .modifier(let key):
                defaults.set("modifier", forKey: Key.triggerKind)
                defaults.set(Int(key.rawValue), forKey: Key.triggerKeyCode)
                defaults.set(0, forKey: Key.triggerModifiers)
            }
        }
    }

    var activationMode: ActivationMode {
        get { ActivationMode(rawValue: defaults.string(forKey: Key.activationMode) ?? "") ?? .toggle }
        set { defaults.set(newValue.rawValue, forKey: Key.activationMode) }
    }

    var outputMode: OutputMode {
        get { OutputMode(rawValue: defaults.string(forKey: Key.outputMode) ?? "") ?? .paste }
        set { defaults.set(newValue.rawValue, forKey: Key.outputMode) }
    }

    var model: ModelChoice {
        get { ModelChoice(rawValue: defaults.string(forKey: Key.model) ?? "") ?? .v3 }
        set { defaults.set(newValue.rawValue, forKey: Key.model) }
    }

    var playSounds: Bool {
        get { defaults.bool(forKey: Key.playSounds) }
        set { defaults.set(newValue, forKey: Key.playSounds) }
    }

    var trimTrailingNewline: Bool {
        get { defaults.bool(forKey: Key.trimTrailingNewline) }
        set { defaults.set(newValue, forKey: Key.trimTrailingNewline) }
    }

    /// How many recent transcripts the menu keeps (in memory only).
    var historySize: Int {
        get {
            let value = defaults.integer(forKey: Key.historySize)
            return TranscriptHistory.sizes.contains(value) ? value : TranscriptHistory.sizes[0]
        }
        set { defaults.set(newValue, forKey: Key.historySize) }
    }

    /// False until the app has finished its one-time setup.
    var didFirstRun: Bool {
        get { defaults.bool(forKey: Key.didFirstRun) }
        set { defaults.set(newValue, forKey: Key.didFirstRun) }
    }
}
