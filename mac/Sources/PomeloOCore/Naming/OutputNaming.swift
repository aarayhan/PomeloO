import Foundation

/// Where a result goes and what it is called (docs/features.md): beside the source, `photo.webp`,
/// then `photo 2.webp`, `photo 3.webp` when the name is taken. A result is always a new file.
public enum OutputNaming {
    /// `<stem>[ <label>].<ext>` in the source's folder (`out_path` in pomeloo/catalog.py). `gz` is
    /// written as `.tar.gz`; the extension `folder` names a directory without a suffix.
    public static func proposed(for source: URL, ext: String, label: String? = nil) -> URL {
        let directory = source.deletingLastPathComponent()
        var name = FileName.stem(of: source)
        if let label, !label.isEmpty { name += " \(label)" }
        if ext == "folder" { return directory.appendingPathComponent(name, isDirectory: true) }
        return directory.appendingPathComponent("\(name).\(ext == "gz" ? "tar.gz" : ext)")
    }

    /// `photo.webp` with n = 2 is `photo 2.webp`; `a.tar.gz` becomes `a 2.tar.gz`.
    public static func numbered(_ url: URL, _ n: Int) -> URL {
        let name = url.lastPathComponent
        let base: String
        let suffix: String
        if name.hasSuffix(".tar.gz") {
            base = String(name.dropLast(7))
            suffix = ".tar.gz"
        } else {
            suffix = url.pathExtension.isEmpty ? "" : ".\(url.pathExtension)"
            base = String(name.dropLast(suffix.count))
        }
        return url.deletingLastPathComponent().appendingPathComponent("\(base) \(n)\(suffix)")
    }
}

/// Hands out names for results that are still being written, so two jobs that would both produce
/// `photo.jpg` (photo.webp and photo.heic) get `photo.jpg` and `photo 2.jpg`.
public actor NameReserver {
    private var claimed: Set<URL> = []

    public init() {}

    /// The first of `proposed`, `proposed 2`, `proposed 3`... that neither exists nor is claimed.
    public func reserve(_ proposed: URL) -> URL {
        var candidate = proposed
        var n = 2
        while claimed.contains(candidate) || FileManager.default.fileExists(atPath: candidate.path) {
            candidate = OutputNaming.numbered(proposed, n)
            n += 1
        }
        claimed.insert(candidate)
        return candidate
    }

    /// Call when the job is over, whether it wrote the file or failed.
    public func release(_ url: URL) {
        claimed.remove(url)
    }
}
