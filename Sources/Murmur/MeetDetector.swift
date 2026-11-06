import AppKit
import ApplicationServices
import CoreAudio

/// A browser Murmur can watch for Google Meet calls.
struct Browser: Equatable {
    let name: String
    /// The app itself, whose windows we read titles from.
    let appBundleID: String
    /// Bundle ID prefixes of the processes that actually open the mic
    /// (Chromium does this in helper processes).
    let audioPrefixes: [String]

    static let all: [Browser] = [
        Browser(name: "Google Chrome", appBundleID: "com.google.Chrome", audioPrefixes: ["com.google.Chrome"]),
        Browser(name: "Arc", appBundleID: "company.thebrowser.Browser", audioPrefixes: ["company.thebrowser"]),
        Browser(name: "Brave", appBundleID: "com.brave.Browser", audioPrefixes: ["com.brave.Browser"]),
        Browser(name: "Microsoft Edge", appBundleID: "com.microsoft.edgemac", audioPrefixes: ["com.microsoft.edgemac"]),
        Browser(name: "Vivaldi", appBundleID: "com.vivaldi.Vivaldi", audioPrefixes: ["com.vivaldi.Vivaldi"]),
        // Safari does its audio in a shared WebKit process.
        Browser(name: "Safari", appBundleID: "com.apple.Safari", audioPrefixes: ["com.apple.WebKit.GPU"]),
    ]

    static func owning(audioBundleID id: String) -> Browser? {
        all.first { browser in browser.audioPrefixes.contains { id.hasPrefix($0) } }
    }
}

/// What the detector sees at one moment.
enum MeetSignal: Equatable {
    /// No browser has the microphone open.
    case idle
    /// A browser has the mic open; `meetTitle` is set when one of its
    /// windows is showing Google Meet.
    case browserMic(Browser, meetTitle: String?)
}

/// Spots a Google Meet call without any browser extension:
///
/// 1. Core Audio reports which processes have the microphone open. A browser
///    grabbing it is the trigger (Meet keeps it open while you are muted,
///    and releases it when you leave the call).
/// 2. The browser's window titles, read through Accessibility (which Murmur
///    already has for pasting), tell a Meet call apart from other sites.
@MainActor
enum MeetDetector {
    static func current() -> MeetSignal {
        let micUsers = CoreAudioSupport.processes().filter(\.isRunningInput)
        guard let browser = micUsers.lazy.compactMap({ Browser.owning(audioBundleID: $0.bundleID) }).first
        else { return .idle }
        return .browserMic(browser, meetTitle: meetWindowTitle(in: browser))
    }

    /// Only a window's *active* tab shows in its title, so a Meet tab hidden
    /// behind another one is noticed once the user switches back to it.
    static func meetWindowTitle(in browser: Browser) -> String? {
        guard Permissions.hasAccessibility else { return nil }
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: browser.appBundleID) {
            let element = AXUIElementCreateApplication(app.processIdentifier)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success,
                let windows = value as? [AXUIElement]
            else { continue }
            for window in windows {
                var title: CFTypeRef?
                if AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title) == .success,
                    let title = title as? String, MeetWindow.isMeet(title)
                {
                    return title
                }
            }
        }
        return nil
    }

    /// Whether any tab of the browser, not just the one in front, is a Meet
    /// call. Read from the tab strip through Accessibility. Returns nil when
    /// no tabs could be found at all (no permission, or a browser that lays
    /// its tab strip out differently), so callers can tell "no Meet tab"
    /// apart from "can't tell".
    static func hasMeetTab(in browser: Browser) -> Bool? {
        guard Permissions.hasAccessibility else { return nil }
        var sawTabs = false
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: browser.appBundleID) {
            let element = AXUIElementCreateApplication(app.processIdentifier)
            for window in children(of: element, attribute: kAXWindowsAttribute) {
                var found = false
                scanTabs(window, depth: 0, sawTabs: &sawTabs, foundMeet: &found)
                if found { return true }
            }
        }
        return sawTabs ? false : nil
    }

    /// Walks the window's controls looking for tab buttons. Page content
    /// (AXWebArea) is skipped: it is large and never holds the tab strip.
    private static func scanTabs(_ element: AXUIElement, depth: Int, sawTabs: inout Bool, foundMeet: inout Bool) {
        guard depth < 10, !foundMeet else { return }
        let role = string(element, kAXRoleAttribute)
        if role == "AXWebArea" { return }
        if role == kAXRadioButtonRole as String || role == "AXTab",
            let parent = parentRole(of: element), parent == kAXTabGroupRole as String
        {
            sawTabs = true
            let title = string(element, kAXTitleAttribute) ?? string(element, kAXDescriptionAttribute) ?? ""
            if MeetWindow.isMeet(title) { foundMeet = true }
            return
        }
        for child in children(of: element, attribute: kAXChildrenAttribute) {
            scanTabs(child, depth: depth + 1, sawTabs: &sawTabs, foundMeet: &foundMeet)
        }
    }

    private static func parentRole(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &value) == .success,
            let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return string(value as! AXUIElement, kAXRoleAttribute)
    }

    private static func children(of element: AXUIElement, attribute: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}

/// Reports a fresh `MeetSignal` whenever something that could change it
/// happens. While nobody is using the microphone (nearly all the time) it
/// is purely event-driven: no timers, no wakeups.
///
/// Sources, all delivered on the main queue:
/// * Core Audio: every input device's "running somewhere" flag (the moment
///   any app opens or closes a mic) and the process list changing. All
///   inputs, not just the default: Meet picks its own microphone, which is
///   often not the Mac's default input (verified with a USB mic).
/// * Accessibility: while a browser holds the mic but no Meet window has
///   been seen yet, title and focus changes in that browser, so switching
///   to the Meet tab is noticed immediately.
/// * A 2 s check, but only while another app has the mic open. Core Audio
///   does not reliably notify per-process "running input" changes
///   (verified: the flag flips with no callback), and once Murmur itself
///   records the call the device stays "running", so this is the only way
///   to see the browser let go of the mic when the user leaves the call.
@MainActor
final class MeetWatcher {
    var onSignal: (MeetSignal) -> Void = { _ in }

    private let system = AudioObjectID(kAudioObjectSystemObject)
    private var systemListeners: [(AudioObjectPropertySelector, AudioObjectPropertyListenerBlock)] = []
    private var inputDeviceListeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var micInUseCheck: Timer?
    private var titleObserver: AXObserver?
    private var titleObservedPID: pid_t?
    private var evaluationQueued = false
    private var isRunning = false

    func start() {
        guard !isRunning else { return }
        isRunning = true
        listenToSystem(kAudioHardwarePropertyProcessObjectList) { [weak self] in
            self?.scheduleEvaluation()
        }
        // Mics being plugged in or removed.
        listenToSystem(kAudioHardwarePropertyDevices) { [weak self] in
            self?.rebindInputDevices()
            self?.scheduleEvaluation()
        }
        rebindInputDevices()
        evaluate()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        for (selector, block) in systemListeners {
            var addr = CoreAudioSupport.address(selector)
            AudioObjectRemovePropertyListenerBlock(system, &addr, .main, block)
        }
        systemListeners.removeAll()
        unbindInputDevices()
        micInUseCheck?.invalidate()
        micInUseCheck = nil
        stopObservingTitles()
    }

    /// Ask for a fresh look, e.g. right after Murmur's own dictation lets
    /// go of the mic: if a browser grabbed it meanwhile, the device never
    /// went idle, so no Core Audio event would announce it.
    func recheck() {
        scheduleEvaluation()
    }

    // MARK: - Evaluation

    /// Several notifications usually arrive together; fold them into one check.
    private func scheduleEvaluation() {
        guard isRunning, !evaluationQueued else { return }
        evaluationQueued = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.evaluationQueued = false
                self?.evaluate()
            }
        }
    }

    private func evaluate() {
        guard isRunning else { return }
        updateMicInUseCheck()
        let signal = MeetDetector.current()
        if case .browserMic(let browser, nil) = signal {
            observeTitles(of: browser)
        } else {
            stopObservingTitles()
        }
        onSignal(signal)
    }

    /// Murmur's own use of the mic (Fn dictation, or recording a meeting)
    /// doesn't count, so holding Fn never starts the periodic check.
    private func updateMicInUseCheck() {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let inUse = CoreAudioSupport.processes().contains { $0.isRunningInput && $0.pid != ownPID }
        if inUse, micInUseCheck == nil {
            micInUseCheck = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleEvaluation() }
            }
        } else if !inUse {
            micInUseCheck?.invalidate()
            micInUseCheck = nil
        }
    }

    // MARK: - Core Audio listeners

    private func listenToSystem(_ selector: AudioObjectPropertySelector, _ handler: @escaping @MainActor () -> Void) {
        var addr = CoreAudioSupport.address(selector)
        let block: AudioObjectPropertyListenerBlock = { _, _ in MainActor.assumeIsolated { handler() } }
        if AudioObjectAddPropertyListenerBlock(system, &addr, .main, block) == noErr {
            systemListeners.append((selector, block))
        }
    }

    private func rebindInputDevices() {
        let current = Set(CoreAudioSupport.inputDevices())
        for (device, block) in inputDeviceListeners where !current.contains(device) {
            var addr = CoreAudioSupport.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
            AudioObjectRemovePropertyListenerBlock(device, &addr, .main, block)
            inputDeviceListeners[device] = nil
        }
        for device in current where inputDeviceListeners[device] == nil {
            var addr = CoreAudioSupport.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated { self?.scheduleEvaluation() }
            }
            if AudioObjectAddPropertyListenerBlock(device, &addr, .main, block) == noErr {
                inputDeviceListeners[device] = block
            }
        }
    }

    private func unbindInputDevices() {
        for (device, block) in inputDeviceListeners {
            var addr = CoreAudioSupport.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
            AudioObjectRemovePropertyListenerBlock(device, &addr, .main, block)
        }
        inputDeviceListeners.removeAll()
    }

    // MARK: - Accessibility title changes

    private func observeTitles(of browser: Browser) {
        guard Permissions.hasAccessibility,
            let app = NSRunningApplication.runningApplications(withBundleIdentifier: browser.appBundleID).first
        else { return }
        let pid = app.processIdentifier
        guard titleObservedPID != pid else { return }
        stopObservingTitles()

        var observer: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let watcher = Unmanaged<MeetWatcher>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { watcher.scheduleEvaluation() }
        }
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return }

        // Registering on the application element covers all its windows.
        let element = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXTitleChangedNotification, kAXFocusedWindowChangedNotification, kAXWindowCreatedNotification] {
            AXObserverAddNotification(observer, element, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        titleObserver = observer
        titleObservedPID = pid
    }

    private func stopObservingTitles() {
        if let titleObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(titleObserver), .defaultMode)
        }
        titleObserver = nil
        titleObservedPID = nil
    }
}

/// Recognizes a Google Meet browser window from its title.
enum MeetWindow {
    /// Meet codes look like `abc-defg-hij`.
    private static let codePattern = try! NSRegularExpression(pattern: #"\b[a-z]{3}-[a-z]{4}-[a-z]{3}\b"#)

    /// Browsers append their own name to window titles.
    private static let browserSuffixes = [
        " - Google Chrome", " – Google Chrome", " - Brave", " - Microsoft Edge", " - Arc", " - Vivaldi",
    ]

    static func isMeet(_ title: String) -> Bool {
        let tab = tabTitle(title)
        if tab.hasPrefix("Meet - ") || tab.hasPrefix("Meet – ") || tab.hasPrefix("Meet — ") { return true }
        if tab.contains("Google Meet"), tab != "Google Meet" { return true }
        return code(in: tab) != nil && tab.localizedCaseInsensitiveContains("meet")
    }

    static func code(in title: String) -> String? {
        let range = NSRange(title.startIndex..., in: title)
        guard let match = codePattern.firstMatch(in: title, range: range),
            let found = Range(match.range, in: title)
        else { return nil }
        return String(title[found])
    }

    /// "Meet - Weekly sync" → "Weekly sync"; a bare code gives nil.
    static func meetingName(_ title: String) -> String? {
        var tab = tabTitle(title)
        for prefix in ["Meet - ", "Meet – ", "Meet — "] where tab.hasPrefix(prefix) {
            tab.removeFirst(prefix.count)
        }
        for suffix in [" - Google Meet", " – Google Meet"] where tab.hasSuffix(suffix) {
            tab.removeLast(suffix.count)
        }
        tab = tab.trimmingCharacters(in: .whitespaces)
        if tab.isEmpty || tab == "Google Meet" || code(in: tab) == tab { return nil }
        return tab
    }

    private static func tabTitle(_ title: String) -> String {
        var tab = title
        for suffix in browserSuffixes {
            if let range = tab.range(of: suffix) {
                tab = String(tab[..<range.lowerBound])
            }
        }
        return tab.trimmingCharacters(in: .whitespaces)
    }
}
