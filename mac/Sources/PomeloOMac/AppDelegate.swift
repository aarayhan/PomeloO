import AppKit
import PomeloOCore

/// Owns the menu bar item. Phase 0: the item and a Quit command, nothing else.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath",
                                accessibilityDescription: AppInfo.name)
            image?.isTemplate = true
            button.image = image
            button.toolTip = AppInfo.name
        }
        item.menu = makeMenu()
        statusItem = item
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()

        let title = NSMenuItem(title: "\(AppInfo.name) \(Self.versionText)", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit \(AppInfo.name)",
                              action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        return menu
    }

    private static var versionText: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? AppInfo.developmentVersion
    }
}
