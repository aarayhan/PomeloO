import AppKit
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
