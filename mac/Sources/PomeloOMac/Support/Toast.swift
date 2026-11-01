import AppKit

/// A short notice that fades away by itself, under the menu bar. For results and failures.
@MainActor
final class Toast {
    private var panel: FloatingPanel?
    private var timer: Timer?

    func show(_ text: String, seconds: TimeInterval = 4) {
        timer?.invalidate()
        panel?.orderOut(nil)

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 3
        label.preferredMaxLayoutWidth = 420
        let textSize = label.sizeThatFits(NSSize(width: 420, height: 100))
        let size = NSSize(width: min(460, textSize.width + 36), height: textSize.height + 22)

        let content = NSView(frame: NSRect(origin: .zero, size: size))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.rgb(24, 24, 27, 0.94).cgColor
        content.layer?.cornerRadius = 14
        content.layer?.borderWidth = 1
        content.layer?.borderColor = NSColor.white.withAlphaComponent(30 / 255).cgColor
        label.frame = NSRect(x: 18, y: 11, width: size.width - 36, height: textSize.height)
        content.addSubview(label)

        let panel = FloatingPanel(size: size, level: .statusBar)
        panel.ignoresMouseEvents = true
        panel.contentView = content
        if let area = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: area.midX - size.width / 2, y: area.maxY - size.height - 14))
        }
        panel.orderFrontRegardless()
        self.panel = panel
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.panel?.orderOut(nil) }
        }
    }
}
