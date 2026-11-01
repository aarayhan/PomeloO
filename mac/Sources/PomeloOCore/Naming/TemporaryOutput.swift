import Darwin
import Foundation

/// A hidden file next to the source where an engine writes, so half-written results are never visible
/// under their final name. `commit` renames it atomically; `discard` removes it.
public struct TemporaryOutput: Sendable {
    public let url: URL

    /// `.pomeloo-<UUID>.<ext>` in `directory`. The real extension stays last because engines pick the
    /// container from it.
    public init(directory: URL, ext: String) {
        url = directory.appendingPathComponent(".pomeloo-\(UUID().uuidString).\(ext)")
    }

    public static func isTemporaryName(_ name: String) -> Bool {
        name.hasPrefix(".pomeloo-")
    }

    /// Moves the file to `final` without ever replacing something that already exists there: if the name
    /// was taken in the meantime the next free `name N` is used. Returns the name actually used.
    @discardableResult
    public func commit(to final: URL) throws -> URL {
        var target = final
        var n = 2
        while true {
            let result = url.withUnsafeFileSystemRepresentation { from in
                target.withUnsafeFileSystemRepresentation { to in
                    renamex_np(from, to, UInt32(RENAME_EXCL))
                }
            }
            if result == 0 { return target }
            let code = errno
            guard code == EEXIST else { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
            target = OutputNaming.numbered(final, n)
            n += 1
        }
    }

    public func discard() {
        try? FileManager.default.removeItem(at: url)
    }
}
