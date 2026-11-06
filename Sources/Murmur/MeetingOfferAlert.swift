import AppKit

/// The "Transcribe this call?" prompt: a genuine NSAlert, but shown without
/// running it modally.
///
/// `runModal()` would block Murmur's main thread, steal keyboard focus from
/// the Meet tab while the user is joining, and could not be taken down when
/// the call ends before anyone answers. Instead the alert's own window is
/// floated above other apps and its buttons are rewired to us.
@MainActor
final class MeetingOfferAlert: NSObject {
    var onStart: () -> Void = {}
    var onDecline: () -> Void = {}

    private var alert: NSAlert?

    func show() {
        close()

        let alert = NSAlert()
        alert.alertStyle = .informational
        // Kept short on purpose: it pops up while the user is joining a call.
        alert.messageText = "Transcribe this meeting?"
        alert.informativeText = "Stays on this Mac. Stops when you leave."
        alert.icon = NSApp.applicationIconImage

        let start = alert.addButton(withTitle: "Transcribe")
        start.target = self
        start.action = #selector(startPressed)
        let decline = alert.addButton(withTitle: "Not Now")
        decline.target = self
        decline.action = #selector(declinePressed)
        decline.keyEquivalent = "\u{1b}"  // Esc

        alert.layout()
        let window = alert.window
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        positionTopRight(window)
        // Shown, but Murmur is not activated: typing keeps going to the browser.
        window.orderFrontRegardless()
        self.alert = alert
    }

    func close() {
        alert?.window.orderOut(nil)
        alert = nil
    }

    @objc private func startPressed() {
        close()
        onStart()
    }

    @objc private func declinePressed() {
        close()
        onDecline()
    }

    /// Where notifications appear, so it reads as a prompt rather than a
    /// dialog blocking the call window in the middle of the screen.
    private func positionTopRight(_ window: NSWindow) {
        guard let screen = NSScreen.main?.visibleFrame else { return }
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(x: screen.maxX - size.width - 16, y: screen.maxY - size.height - 16))
    }
}
