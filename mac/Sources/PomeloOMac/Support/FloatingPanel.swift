import AppKit

/// A borderless panel that floats above other windows and never takes focus or activates the app, so
/// dropping on it does not steal the keyboard from whatever the user was doing.
final class FloatingPanel: NSPanel {
    init(size: NSSize, level: NSWindow.Level = .floating) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        self.level = level
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

extension NSColor {
    /// 0...255 components, as the Windows app writes its colours.
    static func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: Double = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
    }

    static func hex(_ value: UInt32, alpha: Double = 1) -> NSColor {
        rgb(Int(value >> 16) & 255, Int(value >> 8) & 255, Int(value) & 255, alpha)
    }
}
