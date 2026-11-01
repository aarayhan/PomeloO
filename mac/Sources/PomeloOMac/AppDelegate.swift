import AppKit
import Carbon.HIToolbox
import PomeloOCore

/// Owns the menu bar item and the pieces behind it: the drop pad, the wheel and the conversions.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let showPadKey = "showDropPad"
    private static let useFinderKey = "useFinderSelection"

    private var statusItem: NSStatusItem?
    private var padItem: NSMenuItem?
    private var finderItem: NSMenuItem?
    private var pad: DropPad?
    private var wheel: WheelController?
    private var coordinator: ConversionCoordinator?
    private var gestures: DragGestureMonitor?
    private var hotKey: GlobalHotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [Self.showPadKey: true, Self.useFinderKey: true])

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

    /// Control-Shift-Space opens the wheel, driven by the arrow keys. The files are the ones selected in
    /// Finder when Finder is in front and may be asked, otherwise the ones copied with ⌘C.
    private func startShortcut(wheel: WheelController, coordinator: ConversionCoordinator) {
        let controlShift = controlKey | shiftKey
        hotKey = GlobalHotKey(keyCode: kVK_Space, modifiers: controlShift) { [weak self, weak wheel, weak coordinator] in
            guard let self, let wheel, let coordinator else { return }
            Task { @MainActor in await self.openWheelFromShortcut(wheel: wheel, coordinator: coordinator) }
        }
        if hotKey == nil {
            coordinator.toast.show("⌃⇧Space is used by another app, so the keyboard shortcut is off.")
        }
    }

    private func openWheelFromShortcut(wheel: WheelController, coordinator: ConversionCoordinator) async {
        let pointer = NSEvent.mouseLocation
        let result = await ShortcutFiles.resolve(
            finder: FinderAppleEvents(),
            useFinder: UserDefaults.standard.bool(forKey: Self.useFinderKey),
            explain: { await MainActor.run { Self.explainFinderAccess() } },
            // read only when needed, on the main thread (the resolver runs elsewhere)
            clipboard: { DispatchQueue.main.sync { MainActor.assumeIsolated { Self.copiedFiles() } } })

        if result.files.isEmpty {
            coordinator.toast.show(result.finderRefused
                ? "PomeloO can't read Finder's selection. Copy the files (⌘C) first, or allow it in System Settings > Privacy & Security > Automation."
                : "Select files in Finder, or copy them (⌘C), then press ⌃⇧Space.", seconds: 7)
            return
        }
        wheel.showForKeyboard(files: result.files, at: pointer)
    }

    /// One sentence before macOS shows its own dialog. "Use Copied Files" turns the Finder selection off
    /// (the menu turns it on again), so nobody who declines is asked twice.
    private static func explainFinderAccess() -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "PomeloO would like to read which files are selected in Finder."
        alert.informativeText = "macOS will ask next whether PomeloO may control Finder; it only asks Finder for the current selection. If you say no, PomeloO uses the files you copied with ⌘C instead."
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Use Copied Files")
        let agreed = alert.runModal() == .alertFirstButtonReturn
        if !agreed { UserDefaults.standard.set(false, forKey: useFinderKey) }
        return agreed
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

        let finderItem = NSMenuItem(title: "Use Finder Selection for ⌃⇧Space", action: #selector(toggleFinder), keyEquivalent: "")
        finderItem.target = self
        finderItem.state = UserDefaults.standard.bool(forKey: Self.useFinderKey) ? .on : .off
        menu.addItem(finderItem)
        self.finderItem = finderItem
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit \(AppInfo.name)",
                              action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        return menu
    }

    @objc private func toggleFinder() {
        let on = !UserDefaults.standard.bool(forKey: Self.useFinderKey)
        UserDefaults.standard.set(on, forKey: Self.useFinderKey)
        finderItem?.state = on ? .on : .off
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
