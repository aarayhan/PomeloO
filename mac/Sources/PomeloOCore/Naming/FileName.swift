import Foundation

/// File name rules shared with `pomeloo/catalog.py` (`ext_of`, `stem_of`).
public enum FileName {
    /// Spellings other than the canonical extension. The catalog lists canonical names only, so a
    /// `.jpeg` file has to be mapped to `jpg` before it is looked up.
    /// Mirrors `ALIASES` in pomeloo/catalog.py (not exported to docs/catalog.json yet).
    public static let aliases: [String: String] = [
        "jpeg": "jpg", "jpe": "jpg", "tif": "tiff", "heif": "heic", "aif": "aiff",
        "markdown": "md", "htm": "html", "tgz": "gz", "oga": "ogg", "m4v": "mp4",
    ]

    /// Canonical lowercase extension: `Photo.JPEG` is `jpg`, `a.tar.gz` is `gz`, no extension is "".
    public static func ext(of url: URL) -> String {
        ext(ofName: url.lastPathComponent)
    }

    public static func ext(ofName name: String) -> String {
        let lower = name.lowercased()
        if lower.hasSuffix(".tar.gz") { return "gz" }
        let e = suffix(of: lower)
        return aliases[e] ?? e
    }

    /// The name without its last extension, with `.tar.gz` and `.tgz` removed whole.
    public static func stem(of url: URL) -> String {
        stem(ofName: url.lastPathComponent)
    }

    public static func stem(ofName name: String) -> String {
        let lower = name.lowercased()
        if lower.hasSuffix(".tar.gz") { return String(name.dropLast(7)) }
        if lower.hasSuffix(".tgz") { return String(name.dropLast(4)) }
        // like the regex `\.[^.]+$`: from the last dot, if something follows it
        if let dot = name.lastIndex(of: "."), name.index(after: dot) < name.endIndex {
            return String(name[..<dot])
        }
        return name
    }

    /// Python's `Path.suffix` without the dot: "" for `.bashrc`, `a.` and names without a dot.
    private static func suffix(of name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex,
              name.index(after: dot) < name.endIndex else { return "" }
        return String(name[name.index(after: dot)...])
    }
}
