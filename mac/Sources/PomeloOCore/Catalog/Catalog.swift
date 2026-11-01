import Foundation

public enum FileKind: String, Decodable, Sendable {
    case image, audio, video, archive, subtitle, spreadsheet, document
}

/// The format, tool and action tables, loaded from `docs/catalog.json`. Windows and Mac read the same
/// file; nothing here restates which format converts to which.
public struct Catalog: Decodable, Sendable {
    public struct Format: Decodable, Sendable {
        public let kind: FileKind
        /// Targets in the order the wheel shows them.
        public let to: [String]
        public let tools: [String]
        public let toolsMany: [String]

        enum CodingKeys: String, CodingKey {
            case kind, to, tools
            case toolsMany = "tools_many"
        }
    }

    public struct Tool: Decodable, Sendable {
        public let short: String
        public let name: String
    }

    public struct Action: Decodable, Sendable {
        public let short: String
        public let name: String
        public let about: String
    }

    public let version: String
    public let formats: [String: Format]
    public let tools: [String: Tool]
    public let actions: [String: Action]

    public init(data: Data) throws {
        self = try JSONDecoder().decode(Catalog.self, from: data)
    }

    /// The catalog compiled into the app.
    public static let bundled: Catalog = {
        do {
            return try Catalog(data: bundledData)
        } catch {
            fatalError("The embedded catalog.json is not valid: \(error)")
        }
    }()

    static var bundledData: Data { Data(PackageResources.catalog_json) }

    /// Kind of a canonical extension (see `FileName.ext`), or nil when the catalog does not list it.
    public func kind(ofExtension ext: String) -> FileKind? {
        formats[ext]?.kind
    }

    /// Every target the catalog lists for this extension. Whether this Mac can actually write it is a
    /// separate question: see `ConversionService.availableTargets`.
    public func targets(forExtension ext: String) -> [String] {
        formats[ext]?.to ?? []
    }

    /// Extensions with a catalog entry, for registering drop types.
    public var inputExtensions: [String] { formats.keys.sorted() }
}
