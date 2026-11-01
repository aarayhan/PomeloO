import AppKit

/// The drop pad: a small round target that stays above other windows. Dragging files onto it opens the
/// wheel around it. It can be moved by dragging it, and a right click opens the menu bar menu.
@MainActor
final class DropPad {
    private let panel = FloatingPanel(size: NSSize(width: 68, height: 68))
    private let view = DropPadView()

    /// Files were dragged onto the pad; the point is the middle of the pad on screen.
    var onFilesEntered: (([URL], NSPoint) -> Void)?
    var menu: NSMenu?

    init() {
        panel.contentView = view
        view.pad = self
        placeInCorner()
    }

    var isVisible: Bool { panel.isVisible }

    func setVisible(_ visible: Bool) {
        if visible {
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
    }

    /// Bottom right of the main screen, like the Windows pad.
    private func placeInCorner() {
        guard let area = NSScreen.main?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(x: area.maxX - 88, y: area.minY + 30))
    }

    fileprivate var center: NSPoint {
        NSPoint(x: panel.frame.midX, y: panel.frame.midY)
    }

    fileprivate func filesEntered(_ files: [URL]) {
        onFilesEntered?(files, center)
    }

    fileprivate func move(by delta: NSPoint) {
        panel.setFrameOrigin(NSPoint(x: panel.frame.origin.x + delta.x, y: panel.frame.origin.y + delta.y))
    }

    fileprivate func showMenu(with event: NSEvent) {
        guard let menu else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }
}

private final class DropPadView: NSView {
    weak var pad: DropPad?
    private var hot = false
    private var dragStart: NSPoint?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 68, height: 68))
        registerForDraggedTypes([.fileURL])
        toolTip = "PomeloO: drop files here. Right-click for the menu."
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let g = NSGraphicsContext.current?.cgContext else { return }
        let c = CGPoint(x: 34, y: 34)
        func disc(_ radius: CGFloat, at center: CGPoint, fill: NSColor, stroke: NSColor? = nil) {
            let rect = CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius)
            g.setFillColor(fill.cgColor)
            g.fillEllipse(in: rect)
            if let stroke {
                g.setStrokeColor(stroke.cgColor)
                g.setLineWidth(1)
                g.strokeEllipse(in: rect)
            }
        }
        disc(29, at: CGPoint(x: c.x, y: c.y + 2), fill: NSColor.rgb(0, 0, 0, 70 / 255))  // soft shadow
        if hot { disc(33, at: c, fill: NSColor.rgb(255, 138, 0, 90 / 255)) }  // glow while hovered or a file is over it
        disc(28, at: c, fill: NSColor.rgb(28, 28, 31, 230 / 255), stroke: NSColor.white.withAlphaComponent(40 / 255))
        CitrusIcon.draw(in: g, origin: CGPoint(x: 14, y: 15), side: 40)
    }

    // MARK: drops

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let objects = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                            options: [.urlReadingFileURLsOnly: true])
        let files = (objects as? [URL]) ?? []
        guard !files.isEmpty else { return [] }
        setHot(true)
        pad?.filesEntered(files)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        setHot(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        setHot(false)
    }

    /// Dropping on the pad itself (not on a petal) does nothing: the wheel is where a format is chosen.
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        false
    }

    private func setHot(_ value: Bool) {
        hot = value
        needsDisplay = true
    }

    override func mouseEntered(with event: NSEvent) { setHot(true) }
    override func mouseExited(with event: NSEvent) { setHot(false) }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
        super.updateTrackingAreas()
    }

    // MARK: moving and the menu

    override func mouseDown(with event: NSEvent) {
        dragStart = NSEvent.mouseLocation
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let now = NSEvent.mouseLocation
        pad?.move(by: NSPoint(x: now.x - start.x, y: now.y - start.y))
        dragStart = now
    }

    override func mouseUp(with event: NSEvent) {
        dragStart = nil
    }

    override func rightMouseDown(with event: NSEvent) {
        pad?.showMenu(with: event)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
