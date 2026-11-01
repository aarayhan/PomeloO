import AppKit

// Explicit entry point: `@main` on an NSApplicationDelegate looks for a nib in Info.plist, and there is none.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)  // also what LSUIElement does in the bundle; keeps `swift run` out of the Dock
app.run()
