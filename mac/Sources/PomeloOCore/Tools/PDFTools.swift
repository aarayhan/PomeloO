import CoreGraphics
import CoreText
import Foundation
import PDFKit

public struct WatermarkOptions: Sendable, Equatable {
    public var text: String
    /// Width of the text as a percentage of the page width.
    public var sizePercent: Int
    public var opacityPercent: Int
    /// Counter-clockwise degrees: 0, 45 or 90.
    public var angle: Int
    /// `#rrggbb`
    public var color: String

    public init(text: String = "CONFIDENTIAL", sizePercent: Int = 70, opacityPercent: Int = 25, angle: Int = 45, color: String = "#ff0000") {
        self.text = text
        self.sizePercent = sizePercent
        self.opacityPercent = opacityPercent
        self.angle = angle
        self.color = color
    }
}

public struct NumberingOptions: Sendable, Equatable {
    public enum Style: String, Sendable, CaseIterable {
        case plain = "1"
        case page = "Page 1"
        case ofTotal = "1 / 10"
        case pageOfTotal = "Page 1 of 10"
    }

    public var style: Style
    /// "bottom left", "bottom center", "bottom right", "top left", "top center", "top right"
    public var position: String
    public var start: Int
    public var size: Int

    public init(style: Style = .ofTotal, position: String = "bottom center", start: Int = 1, size: Int = 10) {
        self.style = style
        self.position = position
        self.start = start
        self.size = size
    }
}

/// What the PDF tools do to a document. The page copying uses PDFKit; the tools that draw on every page
/// (watermark, page numbers, removing a password) draw each original page into a new PDF with Core Graphics,
/// which keeps text and vector art as they were. Bookmarks, links and form fields are not carried over.
enum PDFTools {
    // MARK: merge, split, organize (PDFKit)

    static func merge(_ sources: [URL], to destination: URL, cancel: CancelFlag) throws {
        let merged = PDFDocument()
        for source in sources {
            let document = try open(source)
            for index in 0..<document.pageCount {
                try cancel.check()
                try merged.insert(copy(of: page(document, index)), at: merged.pageCount)
            }
        }
        try save(merged, to: destination)
    }

    /// `ranges` like `1-3, 5`; empty means every page on its own file. Files are `<stem> 1.pdf`, `<stem> 2.pdf`...
    static func split(_ source: URL, ranges: String, intoFolder folder: URL, cancel: CancelFlag) throws {
        let document = try open(source)
        let groups = try pageGroups(ranges, pageCount: document.pageCount)
        guard !groups.isEmpty else { throw ConversionError.failed("None of those pages exist in \(source.lastPathComponent).") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let stem = FileName.stem(of: source)
        for (number, pages) in groups.enumerated() {
            try cancel.check()
            let part = PDFDocument()
            for index in pages { try part.insert(copy(of: page(document, index)), at: part.pageCount) }
            try save(part, to: folder.appendingPathComponent("\(stem) \(number + 1).pdf"))
        }
    }

    /// `order`: 0-based source pages in their new order; pages left out are removed and a page named twice is
    /// copied. `rotations`: output position to extra degrees (a multiple of 90).
    static func organize(_ source: URL, order: [Int]?, rotations: [Int: Int], to destination: URL, cancel: CancelFlag) throws {
        let document = try open(source)
        let result: PDFDocument
        if let order {
            result = PDFDocument()
            for index in order {
                try cancel.check()
                try result.insert(copy(of: page(document, index)), at: result.pageCount)
            }
        } else {
            result = document
        }
        for (position, degrees) in rotations {
            guard let target = result.page(at: position), degrees % 90 == 0 else {
                throw ConversionError.failed("Can't rotate page \(position + 1) by \(degrees) degrees.")
            }
            target.rotation = (((target.rotation + degrees) % 360) + 360) % 360
        }
        try save(result, to: destination)
    }

    // MARK: drawing on every page (Core Graphics)

    static func watermark(_ source: URL, options: WatermarkOptions, to destination: URL, cancel: CancelFlag) throws {
        let text = options.text.isEmpty ? "CONFIDENTIAL" : options.text
        let color = rgb(options.color)
        try redraw(source, password: "", to: destination, cancel: cancel) { context, page, _, _ in
            let reference = CTLineCreateWithAttributedString(styled(text, size: 1, color: color))
            let unit = max(0.0001, CTLineGetTypographicBounds(reference, nil, nil, nil))
            let size = max(6, page.width * Double(options.sizePercent) / 100 / unit)
            let line = CTLineCreateWithAttributedString(styled(text, size: size, color: color))
            let width = CTLineGetTypographicBounds(line, nil, nil, nil)
            context.saveGState()
            context.setAlpha(CGFloat(options.opacityPercent) / 100)
            context.translateBy(x: page.midX, y: page.midY)
            context.rotate(by: CGFloat(options.angle) * .pi / 180)
            context.textPosition = CGPoint(x: -width / 2, y: -size / 3)
            CTLineDraw(line, context)
            context.restoreGState()
        }
    }

    static func number(_ source: URL, options: NumberingOptions, to destination: URL, cancel: CancelFlag) throws {
        let parts = options.position.split(separator: " ").map(String.init)
        guard parts.count == 2, ["top", "bottom"].contains(parts[0]), ["left", "center", "right"].contains(parts[1]) else {
            throw ConversionError.failed("Unknown position \"\(options.position)\".")
        }
        let margin = 28.0
        let size = Double(options.size)
        let gray = CGColor(gray: 0.25, alpha: 1)
        try redraw(source, password: "", to: destination, cancel: cancel) { context, page, index, total in
            let number = options.start + index
            let last = options.start + total - 1
            let label: String
            switch options.style {
            case .plain: label = "\(number)"
            case .page: label = "Page \(number)"
            case .ofTotal: label = "\(number) / \(last)"
            case .pageOfTotal: label = "Page \(number) of \(last)"
            }
            let line = CTLineCreateWithAttributedString(styled(label, size: size, color: gray))
            let width = CTLineGetTypographicBounds(line, nil, nil, nil)
            let x: Double
            switch parts[1] {
            case "left": x = margin
            case "center": x = (page.width - width) / 2
            default: x = page.width - margin - width
            }
            let y = parts[0] == "top" ? page.height - (margin + size) : margin
            context.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(line, context)
        }
    }

    /// A copy that needs the password to open. The strength is what PDFKit writes on macOS: AES-128 (PDF 1.6, security
    /// handler revision 4), measured in the tests. The Windows app writes AES-256; Apple's frameworks do not offer it.
    /// Revision 4 derives its key with MD5, so how strong this is depends on how long the password is.
    /// Unlike the tools that draw pages again, this keeps bookmarks, links and forms. The same password is both
    /// the one to open the file and the owner's.
    static func protect(_ source: URL, password: String, to destination: URL, cancel: CancelFlag) throws {
        guard !password.isEmpty else { throw ConversionError.failed("Type a password.") }
        let document = try open(source)  // a file that already has one is refused: unlock it first
        try cancel.check()
        guard document.write(to: destination, withOptions: [.userPasswordOption: password, .ownerPasswordOption: password]) else {
            throw ConversionError.cannotWrite(destination.lastPathComponent)
        }
    }

    /// A copy without the password. The password is checked first, so a wrong one says so.
    static func unlock(_ source: URL, password: String, to destination: URL, cancel: CancelFlag) throws {
        try redraw(source, password: password, to: destination, cancel: cancel) { _, _, _, _ in }
    }

    // MARK: pages

    /// `1-3, 5` as 0-based page groups; empty gives every page on its own. Pages outside the document are
    /// dropped, and a group with no page left disappears (like `_parse_ranges` in the Windows app).
    static func pageGroups(_ spec: String, pageCount: Int) throws -> [[Int]] {
        if spec.trimmingCharacters(in: .whitespaces).isEmpty { return (0..<pageCount).map { [$0] } }
        var groups: [[Int]] = []
        for part in spec.split(separator: ",") {
            let ends = part.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard let low = Int(ends[0]), let high = ends.count > 1 ? Int(ends[1]) : low else {
                throw ConversionError.failed("Page ranges look like 1-3, 5. \"\(part.trimmingCharacters(in: .whitespaces))\" does not.")
            }
            let pages = low <= high ? (low...high).filter { (1...max(1, pageCount)).contains($0) && pageCount > 0 }.map { $0 - 1 } : []
            if !pages.isEmpty { groups.append(pages) }
        }
        return groups
    }

    // MARK: helpers

    private static func open(_ url: URL) throws -> PDFDocument {
        guard let document = PDFDocument(url: url) else { throw ConversionError.cannotRead(url.lastPathComponent) }
        if document.isLocked { throw ConversionError.failed("\(url.lastPathComponent) needs its password.") }
        return document
    }

    private static func page(_ document: PDFDocument, _ index: Int) throws -> PDFPage {
        guard let page = document.page(at: index) else {
            throw ConversionError.failed("This PDF has no page \(index + 1) (it has \(document.pageCount)).")
        }
        return page
    }

    private static func copy(of page: PDFPage) throws -> PDFPage {
        guard let copy = page.copy() as? PDFPage else { throw ConversionError.failed("Can't copy a page.") }
        return copy
    }

    private static func save(_ document: PDFDocument, to url: URL) throws {
        guard document.write(to: url) else { throw ConversionError.cannotWrite(url.lastPathComponent) }
    }

    private static func styled(_ text: String, size: Double, color: CGColor) -> NSAttributedString {
        let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        return NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ])
    }

    private static func rgb(_ hex: String) -> CGColor {
        HexColor.cgColor(hex, fallback: CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
    }

    /// Draws every page of the source into a new PDF, upright and at its visible size, and lets `decorate`
    /// draw on top. `decorate` gets the page rectangle (origin zero), the 0-based page index and the page count.
    private static func redraw(_ source: URL, password: String, to destination: URL, cancel: CancelFlag,
                               decorate: (CGContext, CGRect, Int, Int) -> Void) throws {
        guard let document = CGPDFDocument(source as CFURL) else { throw ConversionError.cannotRead(source.lastPathComponent) }
        if document.isEncrypted, !document.isUnlocked, !document.unlockWithPassword(password) {
            throw ConversionError.failed(password.isEmpty ? "This PDF needs its password." : "Wrong password.")
        }
        guard let context = CGContext(destination as CFURL, mediaBox: nil, nil) else {
            throw ConversionError.cannotWrite(destination.lastPathComponent)
        }
        let total = document.numberOfPages
        guard total > 0 else { throw ConversionError.failed("\(source.lastPathComponent) has no pages.") }
        for number in 1...total {
            try cancel.check()
            guard let page = document.page(at: number) else { continue }
            let box = page.getBoxRect(.cropBox)
            let turned = page.rotationAngle % 180 != 0
            var rect = CGRect(x: 0, y: 0, width: turned ? box.height : box.width, height: turned ? box.width : box.height)
            let mediaBox = Data(bytes: &rect, count: MemoryLayout<CGRect>.size)
            context.beginPDFPage([kCGPDFContextMediaBox: mediaBox] as CFDictionary)
            context.saveGState()
            context.concatenate(page.getDrawingTransform(.cropBox, rect: rect, rotate: 0, preserveAspectRatio: true))
            context.drawPDFPage(page)
            context.restoreGState()
            decorate(context, rect, number - 1, total)
            context.endPDFPage()
        }
        context.closePDF()
    }
}
