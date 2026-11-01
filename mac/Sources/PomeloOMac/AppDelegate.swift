import AppKit
import Carbon.HIToolbox
import PomeloOCore

/// Owns the menu bar item and the pieces behind it: the drop pad, the wheel and the conversions.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let showPadKey = "showDropPad"

    private var statusItem: NSStatusItem?
    private var padItem: NSMenuItem?
    private var pad: DropPad?
    private var wheel: WheelController?
    private var coordinator: ConversionCoordinator?
    private var gestures: DragGestureMonitor?
    private var hotKey: GlobalHotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [Self.showPadKey: true])

        let service = ConversionService()
        let coordinator = ConversionCoordinator(service: service)
        let wheel = WheelController(service: service)
        let pad = DropPad()
        self.coordinator = coordinator
        self.wheel = wheel
        self.pad = pad

        wheel.onConvert = { [weak coordinator] files, target in coordinator?.convert(files, to: target) }
        pad.onFilesEntered = { [weak wheel] files, center in wheel?.show(files: files, around: center) }
        coordinator.onProgress = { [weak self] fraction in self?.showProgress(fraction) }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath",
                                accessibilityDescription: AppInfo.name)
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeading
            button.toolTip = AppInfo.name
        }
        let menu = makeMenu()
        item.menu = menu
        pad.menu = menu
        statusItem = item

        pad.setVisible(UserDefaults.standard.bool(forKey: Self.showPadKey))
        padItem?.state = pad.isVisible ? .on : .off

        startGestures(wheel: wheel)
        startShortcut(wheel: wheel, coordinator: coordinator)
    }

    /// Drag a file anywhere, tap Shift, and the wheel opens under the pointer. Only the Convert wheel exists
    /// so far; Control and Option are mapped to Tools and Actions (the Windows keys) for when those arrive.
    private func startGestures(wheel: WheelController) {
        let monitor = DragGestureMonitor()
        monitor.onEvent = { [weak wheel] event, pointer in
            guard let wheel else { return }
            switch event {
            case let .keyTapped(key):
                if GestureKeys.defaults[key] == .convert, !wheel.isVisible { wheel.showForGesture(at: pointer) }
            case .dragEnded:
                wheel.dragSessionEnded()
            case .dragBegan:
                break
            }
        }
        monitor.start()
        gestures = monitor
    }

    /// Control-Shift-Space opens the wheel, driven by the arrow keys, for the files that were copied.
    private func startShortcut(wheel: WheelController, coordinator: ConversionCoordinator) {
        let controlShift = controlKey | shiftKey
        hotKey = GlobalHotKey(keyCode: kVK_Space, modifiers: controlShift) { [weak wheel, weak coordinator] in
            let files = Self.copiedFiles()
            guard !files.isEmpty else {
                coordinator?.toast.show("Copy files in Finder (⌘C), then press ⌃⇧Space.")
                return
            }
            wheel?.showForKeyboard(files: files, at: NSEvent.mouseLocation)
        }
        if hotKey == nil {
            coordinator.toast.show("⌃⇧Space is used by another app, so the keyboard shortcut is off.")
        }
    }

    /// Files on the clipboard (what Finder copies with ⌘C).
    private static func copiedFiles() -> [URL] {
        let objects = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        return (objects as? [URL]) ?? []
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()

        let title = NSMenuItem(title: "\(AppInfo.name) \(Self.versionText)", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())

        let padItem = NSMenuItem(title: "Show Drop Pad", action: #selector(togglePad), keyEquivalent: "")
        padItem.target = self
        menu.addItem(padItem)
        self.padItem = padItem
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit \(AppInfo.name)",
                              action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        return menu
    }

    @objc private func togglePad() {
        guard let pad else { return }
        let show = !pad.isVisible
        pad.setVisible(show)
        padItem?.state = show ? .on : .off
        UserDefaults.standard.set(show, forKey: Self.showPadKey)
    }

    /// A percentage next to the icon while conversions run; nothing when idle.
    private func showProgress(_ fraction: Double?) {
        statusItem?.button?.title = fraction.map { " \(Int(($0 * 100).rounded()))%" } ?? ""
    }

    private static var versionText: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? AppInfo.developmentVersion
    }
}
