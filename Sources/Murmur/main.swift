import AppKit

// A headless mode for verifying the local model end to end.
let arguments = CommandLine.arguments
if arguments.count > 2, arguments[1] == "--transcribe" {
    SelfTest.run(path: arguments[2])
}
if arguments.count > 1, arguments[1] == "--status" {
    MainActor.assumeIsolated { SelfTest.printStatus() }
}

// NSApplication holds its delegate weakly, so the app keeps a strong
// reference here for the lifetime of the process.
private var retainedDelegate: AppDelegate?

// A plain NSApplication rather than @main, so the menu-bar-only lifecycle
// stays explicit and there is no storyboard or nib to carry around.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    retainedDelegate = delegate
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
