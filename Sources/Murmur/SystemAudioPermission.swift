import AppKit

/// The "System Audio Recording" permission a Core Audio tap needs to hear
/// the other side of a call.
///
/// macOS has no public API to check or request it: normally the prompt only
/// appears when the first tap starts, which is mid-call. These two private
/// TCC calls (the same ones Apple's audio-tap sample apps rely on) let
/// Murmur ask at launch instead. If they are ever missing, everything still
/// works the old way: the prompt shows during the first meeting, and
/// `SystemAudioCapture` keeps retrying until access is granted.
enum SystemAudioPermission {
    enum Status { case granted, denied, unknown }

    private static let service = "kTCCServiceAudioCapture" as CFString

    private typealias PreflightFunc = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestFunc = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    private static let tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    static var status: Status {
        guard let tcc, let symbol = dlsym(tcc, "TCCAccessPreflight") else { return .unknown }
        switch unsafeBitCast(symbol, to: PreflightFunc.self)(service, nil) {
        case 0: return .granted
        case 1: return .denied
        default: return .unknown
        }
    }

    /// Shows the system prompt if the user hasn't answered it yet; does
    /// nothing once they have. `completion` runs on the main queue.
    static func requestIfNeeded(completion: @escaping @MainActor (Bool) -> Void = { _ in }) {
        guard status == .unknown, let tcc, let symbol = dlsym(tcc, "TCCAccessRequest") else {
            let granted = status == .granted
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(granted) } }
            return
        }
        unsafeBitCast(symbol, to: RequestFunc.self)(service, nil) { granted in
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(granted) } }
        }
    }

    static func openSettings() {
        // Audio-only apps are listed under Screen & System Audio Recording.
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
