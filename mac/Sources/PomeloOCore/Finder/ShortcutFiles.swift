import Foundation

/// Whether PomeloO may ask Finder for its selection (macOS "Automation" permission), without asking the user.
public enum FinderPermission: Equatable, Sendable {
    case granted
    case denied
    /// Nobody was asked yet: asking now makes macOS show its dialog.
    case askFirst
    case notRunning
}

public enum FinderSelectionOutcome: Equatable, Sendable {
    case files([URL])
    case empty
    case notPermitted
    /// Finder did not answer in time, is not running, or the answer was not understood.
    case unavailable(String)
}

/// Reads Finder's current selection. The real one sends an Apple Event; the tests use a fake.
public protocol FinderSelectionProviding: Sendable {
    /// Finder is the app in front: only then is its selection what the user means.
    var isFrontmost: Bool { get }
    func permission() -> FinderPermission
    /// `askUser` lets macOS show its permission dialog; `timeout` is how long to wait for the answer.
    func selection(askUser: Bool, timeout: TimeInterval) async -> FinderSelectionOutcome
}

public enum ShortcutFileSource: Equatable, Sendable {
    case finderSelection
    case clipboard
}

public struct ShortcutFilesResult: Equatable, Sendable {
    public let files: [URL]
    public let source: ShortcutFileSource
    /// Finder's selection was wanted but could not be read because the permission was refused.
    public let finderRefused: Bool
}

/// Which files the shortcut works on. The Finder selection when Finder is in front and may be asked,
/// otherwise the files copied with ⌘C (the Windows behaviour). Refusing the permission, an empty
/// selection, a slow Finder: every way the first choice fails ends with the clipboard, never with a lost feature.
public enum ShortcutFiles {
    /// How long a Finder that already has permission may take.
    public static let quickTimeout: TimeInterval = 3
    /// How long to wait while the user answers the system dialog.
    public static let dialogTimeout: TimeInterval = 120

    /// - Parameters:
    ///   - useFinder: the user's setting; false skips Finder entirely.
    ///   - explain: shown before the system dialog (the first time); false means the user would rather not.
    public static func resolve(finder: FinderSelectionProviding,
                               useFinder: Bool = true,
                               explain: @Sendable () async -> Bool,
                               clipboard: @Sendable () -> [URL]) async -> ShortcutFilesResult {
        func fromClipboard(refused: Bool) -> ShortcutFilesResult {
            ShortcutFilesResult(files: clipboard(), source: .clipboard, finderRefused: refused)
        }
        guard useFinder, finder.isFrontmost else { return fromClipboard(refused: false) }

        let outcome: FinderSelectionOutcome
        switch finder.permission() {
        case .denied:
            return fromClipboard(refused: true)
        case .notRunning:
            return fromClipboard(refused: false)
        case .askFirst:
            guard await explain() else { return fromClipboard(refused: false) }
            outcome = await finder.selection(askUser: true, timeout: dialogTimeout)
        case .granted:
            outcome = await finder.selection(askUser: false, timeout: quickTimeout)
        }

        switch outcome {
        case let .files(files) where !files.isEmpty:
            return ShortcutFilesResult(files: files, source: .finderSelection, finderRefused: false)
        case .notPermitted:
            return fromClipboard(refused: true)
        case .files, .empty, .unavailable:
            return fromClipboard(refused: false)
        }
    }
}
