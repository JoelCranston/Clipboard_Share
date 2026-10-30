import AppKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // Menu bar only: no Dock icon (LSUIElement in Info.plist does the same for the bundled app).
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
