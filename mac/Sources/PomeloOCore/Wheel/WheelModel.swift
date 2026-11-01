import CoreGraphics
import Foundation

public struct WheelItem: Equatable, Sendable, Identifiable {
    /// The target extension (`jpg`, `gz`...) in the Convert wheel, the tool id (`compressPDF`...) in the Tools wheel.
    public let id: String
    public let title: String

    public init(target: String) {
        id = target
        title = target == "gz" ? "GZIP" : target.uppercased()
    }

    /// A tool petal: the short title the catalog gives it (`COMPRESS`, `ADD BG`...).
    public init(tool id: String, catalog: Catalog) {
        self.id = id
        title = catalog.tools[id]?.short ?? id.uppercased()
    }
}

/// What the wheel shows and which petal is hot. No windows and no events here: the AppKit view feeds it
/// pointer positions and asks what was chosen, which is what the tests do too.
public struct WheelModel: Sendable {
    public private(set) var urls: [URL] = []
    public private(set) var items: [WheelItem] = []
    public private(set) var hover: Int?
    public private(set) var mode = WheelMode.convert
    /// Opened with the shortcut rather than by a drag: the arrow keys move the hot petal and Enter chooses.
    public private(set) var keyboard = false

    private var conversions: ConversionService?
    private var tools: ToolService?

    /// The wheels there are so far. Actions come later; the third dot appears with them.
    public static let availableModes: [WheelMode] = [.convert, .tools]

    public init() {}

    public init(urls: [URL], service: ConversionService, tools: ToolService? = nil, mode: WheelMode = .convert) {
        self.mode = mode
        setSelection(urls, service: service, tools: tools)
    }

    /// Replaces the files and the petals offered for them in the current mode.
    public mutating func setSelection(_ urls: [URL], service: ConversionService, tools: ToolService? = nil) {
        self.urls = urls
        conversions = service
        if let tools { self.tools = tools }
        rebuild()
    }

    /// Switches to another wheel for the same files. A mode that does not exist yet is ignored.
    @discardableResult
    public mutating func setMode(_ newMode: WheelMode) -> Bool {
        guard Self.availableModes.contains(newMode), newMode != mode else { return false }
        mode = newMode
        rebuild()
        return true
    }

    private mutating func rebuild() {
        switch mode {
        case .convert:
            items = conversions?.wheelTargets(for: urls).map(WheelItem.init(target:)) ?? []
        case .tools:
            let catalog = tools?.catalog ?? .bundled
            items = tools?.availableTools(for: urls).map { WheelItem(tool: $0, catalog: catalog) } ?? []
        case .actions:
            items = []
        }
        hover = keyboard && !items.isEmpty ? 0 : nil
    }

    /// Switches keyboard control on or off; with it on the first petal is hot, as in the Windows wheel.
    public mutating func setKeyboard(_ on: Bool) {
        keyboard = on
        hover = on && !items.isEmpty ? 0 : nil
    }

    /// Arrow keys: the next or previous petal, wrapping round. Right and down are +1, left and up -1.
    public mutating func moveHover(by step: Int) {
        guard !items.isEmpty else { return }
        hover = (((hover ?? 0) + step) % items.count + items.count) % items.count
    }

    public mutating func hoverFirst() { if !items.isEmpty { hover = 0 } }
    public mutating func hoverLast() { if !items.isEmpty { hover = items.count - 1 } }

    /// Moves the pointer; true when the hot petal changed (a redraw, a tick).
    @discardableResult
    public mutating func pointerMoved(x: Double, y: Double) -> Bool {
        let now = WheelGeometry.petal(atX: x, y: y, count: items.count)
        defer { hover = now }
        return now != hover
    }

    public mutating func pointerLeft() {
        if !keyboard { hover = nil }
    }

    /// The item under the pointer, if any.
    public var chosen: WheelItem? {
        guard let hover, items.indices.contains(hover) else { return nil }
        return items[hover]
    }

    // MARK: text

    public var title: String { mode.title }

    public var countText: String {
        urls.isEmpty ? "Drop here" : "\(urls.count) file\(urls.count == 1 ? "" : "s")"
    }

    /// Under the wheel: what letting go does, or what to do.
    public var hint: String {
        if let chosen { return "\(keyboard ? "Press Enter" : "Let go") to \(verb(for: chosen))" }
        if !urls.isEmpty, items.isEmpty { return "No \(mode == .convert ? "conversions" : mode.title.lowercased()) for this selection" }
        return mode == .convert ? "Drop on a format" : "Drop on a \(mode == .tools ? "tool" : "action")"
    }

    private func verb(for item: WheelItem) -> String {
        switch mode {
        case .convert: "make a \(item.title)"
        case .tools: "use \(tools?.catalog.tools[item.id]?.name ?? item.title.capitalized)"
        case .actions: item.title.lowercased()
        }
    }
}

extension ConversionService {
    /// The extension the wheel is built for: the common one, or `png` for images of different formats
    /// (any image can become what a PNG can), or nil for a mixed selection that has no formats.
    public func selectionExtension(of urls: [URL]) -> String? {
        let extensions = Set(urls.map(FileName.ext(of:)))
        if extensions.count == 1 { return extensions.first }
        if !extensions.isEmpty, extensions.allSatisfy({ catalog.kind(ofExtension: $0) == .image }) { return "png" }
        return nil
    }

    /// Formats the wheel offers for these files, in catalog order, limited to what this Mac can write.
    public func wheelTargets(for urls: [URL]) -> [String] {
        guard let ext = selectionExtension(of: urls) else { return [] }
        return availableTargets(forExtension: ext)
    }
}
