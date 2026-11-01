import AppKit
import PomeloOCore

/// The wheel window: shown around a point while files are dragged, hidden again when they leave or drop.
@MainActor
final class WheelController {
    private let service: ConversionService
    private let panel: FloatingPanel
    private let view = WheelView()
    private var hideTimer: Timer?

    /// Called when files are dropped on a format.
    var onConvert: (([URL], String) -> Void)?

    /// How long the pointer may be away from the wheel before it closes (the Windows wheel waits 350 ms).
    private let leaveDelay: TimeInterval = 0.35

    init(service: ConversionService) {
        self.service = service
        panel = FloatingPanel(size: view.frame.size, level: .popUpMenu)
        panel.contentView = view
        view.controller = self
    }

    var isVisible: Bool { panel.isVisible }

    /// Shows the wheel centred on `point` (screen coordinates), moved inwards where it would leave the screen.
    func show(files: [URL], around point: NSPoint) {
        hideTimer?.invalidate()
        view.model.setSelection(files, service: service)
        let size = view.frame.size
        var origin = NSPoint(x: point.x - WheelGeometry.size / 2, y: point.y + WheelGeometry.size / 2 - size.height)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main {
            let area = screen.visibleFrame.insetBy(dx: 8, dy: 8)
            origin.x = min(max(origin.x, area.minX), max(area.minX, area.maxX - size.width))
            origin.y = min(max(origin.y, area.minY), max(area.minY, area.maxY - size.height))
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        hideTimer?.invalidate()
        panel.orderOut(nil)
        view.model.pointerLeft()
        view.needsDisplay = true
    }

    // MARK: events from the view

    func dragEntered(files: [URL], at point: CGPoint) {
        hideTimer?.invalidate()
        if !files.isEmpty, files != view.model.urls { view.model.setSelection(files, service: service) }
        dragMoved(to: point)
    }

    func dragMoved(to point: CGPoint) {
        if view.model.pointerMoved(x: point.x, y: point.y) { view.needsDisplay = true }
    }

    func dragExited() {
        view.model.pointerLeft()
        view.needsDisplay = true
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: leaveDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
    }

    /// The files were let go over the wheel: on a format they are converted, anywhere else nothing happens.
    func drop(at point: CGPoint) -> Bool {
        dragMoved(to: point)
        let chosen = view.model.chosen
        let files = view.model.urls
        hide()
        guard let chosen else { return false }
        onConvert?(files, chosen.id)
        return true
    }

    func dragEnded() {
        if panel.isVisible { hide() }
    }
}
