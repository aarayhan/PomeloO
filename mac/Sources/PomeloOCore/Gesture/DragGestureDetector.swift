import Foundation

public struct ModifierKeys: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let shift = ModifierKeys(rawValue: 1)
    public static let control = ModifierKeys(rawValue: 2)
    public static let option = ModifierKeys(rawValue: 4)
    public static let command = ModifierKeys(rawValue: 8)

    /// The keys that open a wheel while files are dragged.
    static let gestureKeys: ModifierKeys = [.shift, .control, .option]
}

/// A key that can be tapped during a drag. Control and Option are the Windows app's Ctrl and Alt.
public enum GestureKey: String, CaseIterable, Sendable {
    case shift, control, option

    var modifier: ModifierKeys {
        switch self {
        case .shift: .shift
        case .control: .control
        case .option: .option
        }
    }
}

public enum WheelMode: String, CaseIterable, Sendable {
    case convert, tools, actions

    public var title: String {
        switch self {
        case .convert: "Convert"
        case .tools: "Tools"
        case .actions: "Actions"
        }
    }
}

public enum GestureKeys {
    /// The Windows defaults: Shift converts, Ctrl opens the tools, Alt the actions.
    public static let defaults: [GestureKey: WheelMode] = [.shift: .convert, .control: .tools, .option: .actions]
}

/// Recognises "a file is being dragged and a key was tapped" from samples of the input state taken a few
/// times a second. Pure logic: the AppKit monitor reads the keyboard, the mouse buttons and the drag
/// pasteboard (nothing that needs a permission, see mac/docs/install.md) and feeds them in.
///
/// The rules are those of native/watch.c in the Windows app: a drag is a held left button while the
/// drag pasteboard changed to carry files, and a tap is exactly one of Shift, Control or Option going down
/// while it is the only one held and it was not already held when the button went down.
public struct DragGestureDetector: Sendable {
    public enum Event: Equatable, Sendable {
        case dragBegan
        case keyTapped(GestureKey)
        case dragEnded
    }

    private var lastChangeCount: Int?
    private var pressed = false
    private var armed = false
    private var previous: ModifierKeys = []

    public init() {}

    /// One sample. `pasteboardHasFiles` is asked only when the drag pasteboard changed during a press.
    public mutating func update(buttonDown: Bool, modifiers: ModifierKeys, pasteboardChangeCount: Int,
                                pasteboardHasFiles: () -> Bool) -> [Event] {
        var events: [Event] = []

        guard buttonDown else {
            if pressed, armed { events.append(.dragEnded) }
            pressed = false
            armed = false
            lastChangeCount = pasteboardChangeCount  // anything that changed while no button was down does not count
            return events
        }

        if !pressed {  // the press itself
            pressed = true
            armed = false
            previous = modifiers
            if lastChangeCount == nil { lastChangeCount = pasteboardChangeCount }
        }

        if !armed, let last = lastChangeCount, pasteboardChangeCount != last {
            lastChangeCount = pasteboardChangeCount
            if pasteboardHasFiles() {
                armed = true
                events.append(.dragBegan)
            }
        }

        if armed {
            let held = modifiers.intersection(.gestureKeys)
            let newlyDown = held.subtracting(previous)
            if held.rawValue.nonzeroBitCount == 1, newlyDown.rawValue.nonzeroBitCount == 1,
               let key = GestureKey.allCases.first(where: { $0.modifier == newlyDown }) {
                events.append(.keyTapped(key))
            }
            previous = modifiers
        }
        return events
    }
}
