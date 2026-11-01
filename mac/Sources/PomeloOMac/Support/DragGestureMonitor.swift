import AppKit
import PomeloOCore

/// Watches for "a file is being dragged and a key was tapped" by reading the state of the mouse buttons, the
/// modifier keys and the drag pasteboard a few times a second. These are plain reads of current state, not
/// event monitors, and the spike in mac/docs/install.md found them to need no permission on macOS 26.5.1.
///
/// Slow while no button is down (10 Hz), 30 Hz while one is, so a tap of 100 ms is not missed.
@MainActor
final class DragGestureMonitor {
    private var detector = DragGestureDetector()
    private var timer: Timer?
    private var fast = false

    /// An event and where the pointer was (screen coordinates).
    var onEvent: ((DragGestureDetector.Event, NSPoint) -> Void)?

    func start() {
        schedule(fast: false)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func schedule(fast: Bool) {
        self.fast = fast
        timer?.invalidate()
        let timer = Timer(timeInterval: fast ? 1.0 / 30 : 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = fast ? 0.005 : 0.03  // let the system coalesce the idle wake-ups
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let down = NSEvent.pressedMouseButtons & 1 != 0
        if down != fast { schedule(fast: down) }

        let flags = NSEvent.modifierFlags
        var modifiers: ModifierKeys = []
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.command) { modifiers.insert(.command) }

        let drag = NSPasteboard(name: .drag)
        let events = detector.update(buttonDown: down, modifiers: modifiers, pasteboardChangeCount: drag.changeCount,
                                     pasteboardHasFiles: { drag.types?.contains(.fileURL) == true })
        let pointer = NSEvent.mouseLocation
        for event in events { onEvent?(event, pointer) }
    }
}
