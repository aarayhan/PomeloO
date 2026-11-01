import CoreGraphics
import Foundation
import Vision

/// Faces, text and QR codes through Vision, on the Mac's own models: nothing is downloaded or sent anywhere.
/// Boxes are fractions of the picture (x, y, width, height) with y down from the top, like every area in the tools.
enum VisionTools {
    static let noCodeMessage = "No QR code or barcode found."

    /// Faces, each box grown by 15% so the edges are covered (the Windows app does the same).
    static func faceBoxes(in image: CGImage) throws -> [CGRect] {
        let request = VNDetectFaceRectanglesRequest()
        try perform(request, on: image)
        return (request.results ?? []).map { padded(topLeft(of: $0.boundingBox)) }
    }

    /// Every recognised word, each box grown by 15%.
    static func textBoxes(in image: CGImage) throws -> [CGRect] {
        try recognise(image).flatMap { $0.words.map { padded($0.box) } }
    }

    /// The text of the picture as paragraphs. Uses the accurate level, the only one that includes Indonesian,
    /// and lets Vision work out the language.
    static func text(in image: CGImage) throws -> String {
        TextFlow.joinLines(try recognise(image).map { $0.words.map(\.text).joined(separator: " ") })
    }

    /// The payload of every QR code or barcode, one per line, or a message when there is none.
    static func codes(in image: CGImage) throws -> String {
        let flat = try ImagePixels.flattened(image)  // codes on transparent backgrounds read as black on white
        let request = VNDetectBarcodesRequest()
        try perform(request, on: flat)
        let payloads = (request.results ?? []).compactMap(\.payloadStringValue)
        return payloads.isEmpty ? noCodeMessage : payloads.joined(separator: "\n")
    }

    // MARK: recognition

    struct Line {
        var words: [(text: String, box: CGRect)]
    }

    /// Lines from top to bottom, each with its words and their boxes.
    static func recognise(_ image: CGImage) throws -> [Line] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.automaticallyDetectsLanguage = true
        request.usesLanguageCorrection = true
        try perform(request, on: image)

        let observations = (request.results ?? []).sorted { $0.boundingBox.maxY > $1.boundingBox.maxY }
        var lines: [Line] = []
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            var words: [(String, CGRect)] = []
            for range in wordRanges(in: candidate.string) {
                let box = (try? candidate.boundingBox(for: range)?.boundingBox) ?? observation.boundingBox
                words.append((String(candidate.string[range]), topLeft(of: box)))
            }
            if !words.isEmpty { lines.append(Line(words: words)) }
        }
        return lines
    }

    /// The runs of non-space characters.
    static func wordRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var start: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            if text[index].isWhitespace {
                if let begin = start { ranges.append(begin..<index); start = nil }
            } else if start == nil {
                start = index
            }
            index = text.index(after: index)
        }
        if let begin = start { ranges.append(begin..<text.endIndex) }
        return ranges
    }

    private static func perform(_ request: VNRequest, on image: CGImage) throws {
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            throw ConversionError.failed("Vision could not read this picture: \(error.localizedDescription)")
        }
    }

    /// Vision's boxes start at the bottom left; the tools' start at the top left.
    static func topLeft(of box: CGRect) -> CGRect {
        CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
    }

    private static func padded(_ box: CGRect, by amount: Double = 0.15) -> CGRect {
        let dx = box.width * amount, dy = box.height * amount
        let left = max(0, box.minX - dx), top = max(0, box.minY - dy)
        let right = min(1, box.maxX + dx), bottom = min(1, box.maxY + dy)
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }
}
