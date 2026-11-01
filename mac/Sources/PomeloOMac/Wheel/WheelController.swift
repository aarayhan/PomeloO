import AppKit
import PomeloOCore

/// The wheel window: shown around a point while files are dragged (or when the shortcut asks for it),
/// hidden again when they leave, drop or the key is let go.
@MainActor
final class WheelController: NSObject, NSWindowDelegate {
    private let service: ConversionService
    private let panel: FloatingPanel
    private let view = WheelView()
    private var hideTimer: Timer?

    /// Called when files are dropped on a format, or one is picked with the keyboard.
    var onConvert: (([URL], String) -> Void)?

    /// How long the pointer may be away from the wheel before it closes (the Windows wheel waits 350 ms).
    private let leaveDelay: TimeInterval = 0.35
    /// How long after the mouse button is let go a wheel nobody dropped on stays (400 ms on Windows).
    private let releaseDelay: TimeInterval = 0.4

    init(service: ConversionService) {
        self.service = service
        panel = FloatingPanel(size: view.frame.size, level: .popUpMenu)
        super.init()
        panel.contentView = view
        panel.delegate = self
        view.controller = self
    }

    var isVisible: Bool { panel.isVisible }

    // MARK: showing

    /// Under the pointer while a file is being dragged and a key was tapped: empty until the drag enters it.
    func showForGesture(at point: NSPoint) {
        present(files: [], keyboard: false, around: point)
    }

    /// Opened with the shortcut for files that are already known; arrows and Enter drive it.
    func showForKeyboard(files: [URL], at point: NSPoint) {
        present(files: files, keyboard: true, around: point)
    }

    /// Around a point (screen coordinates) for a drag that starts on the drop pad.
    func show(files: [URL], around point: NSPoint) {
        present(files: files, keyboard: false, around: point)
    }

    private func present(files: [URL], keyboard: Bool, around point: NSPoint) {
        hideTimer?.invalidate()
        view.model.setKeyboard(keyboard)
        view.model.setSelection(files, service: service)
        let size = view.frame.size
        var origin = NSPoint(x: point.x - WheelGeometry.size / 2, y: point.y + WheelGeometry.size / 2 - size.height)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main {
            let area = screen.visibleFrame.insetBy(dx: 8, dy: 8)
            origin.x = min(max(origin.x, area.minX), max(area.minX, area.maxX - size.width))
            origin.y = min(max(origin.y, area.minY), max(area.minY, area.maxY - size.height))
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.acceptsKeys = keyboard
        if keyboard {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(view)
        } else {
            panel.orderFrontRegardless()
        }
    }

    func hide() {
        hideTimer?.invalidate()
        panel.orderOut(nil)
        panel.acceptsKeys = false
        view.model.setKeyboard(false)
        view.model.pointerLeft()
        view.needsDisplay = true
    }

    /// The mouse button was let go. A wheel nobody dropped on closes shortly after; a keyboard wheel stays.
    func dragSessionEnded() {
        guard panel.isVisible, !view.model.keyboard else { return }
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: releaseDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { if self?.view.model.keyboard == false { self?.hide() } }
        }
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
        return chooseHotPetal()
    }

    func dragEnded() {
        if panel.isVisible, !view.model.keyboard { hide() }
    }

    // MARK: keyboard

    /// Arrows move round the wheel, Return or Space chooses, Escape or Tab closes.
    func key(_ event: NSEvent) {
        switch Int(event.keyCode) {
        case 124, 125: view.model.moveHover(by: 1)  // right, down
        case 123, 126: view.model.moveHover(by: -1)  // left, up
        case 115: view.model.hoverFirst()  // home
        case 119: view.model.hoverLast()  // end
        case 36, 76, 49: _ = chooseHotPetal()  // return, enter, space
        case 53, 48: hide()  // escape, tab
        default: break
        }
        view.needsDisplay = true
    }

    private func chooseHotPetal() -> Bool {
        let chosen = view.model.chosen
        let files = view.model.urls
        hide()
        guard let chosen else { return false }
        onConvert?(files, chosen.id)
        return true
    }

    /// The keyboard wheel closes when it loses focus (a click elsewhere, another app coming forward).
    func windowDidResignKey(_ notification: Notification) {
        if view.model.keyboard { hide() }
    }
}
