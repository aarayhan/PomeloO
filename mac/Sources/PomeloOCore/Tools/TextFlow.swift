import Foundation

enum TextFlow {
    /// Reflows recognised lines into paragraphs (`join_lines` in pomeloo/tools/detect.py): a line that does not
    /// end a sentence continues on the next one (a trailing hyphen joins the word), while short lines, bullets and
    /// numbered items stay separate.
    static func joinLines(_ lines: [String]) -> String {
        let item = try! NSRegularExpression(pattern: #"^([-•*·]|\d+[.)]|[a-z][.)])\s"#)
        var out: [String] = []
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            let previous = out.last ?? ""
            let startsItem = item.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
            let endsSentence = previous.last.map { ".!?:;".contains($0) } ?? false
            if !previous.isEmpty, !startsItem, !endsSentence, previous.count > 30 {
                if previous.hasSuffix("-"), line.first?.isLowercase == true {
                    out[out.count - 1] = String(previous.dropLast()) + line
                } else {
                    out[out.count - 1] = previous + " " + line
                }
            } else {
                out.append(line)
            }
        }
        return out.joined(separator: "\n")
    }
}
