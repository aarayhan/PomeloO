import AppKit
import CoreServices

/// Finder's selection through one Apple Event ("get selection of Finder", as file URLs), sent from this
/// process so the macOS Automation permission belongs to PomeloO. Sent off the main thread with a time limit.
///
/// [BELUM DIUJI] against a real Finder with the permission dialog; the event and the reading of its reply
/// are checked in the tests, the sending is not.
public struct FinderAppleEvents: FinderSelectionProviding {
    static let finderID = "com.apple.finder"

    public init() {}

    public var isFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.finderID
    }

    public func permission() -> FinderPermission {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: Self.finderID).first != nil else {
            return .notRunning
        }
        let target = NSAppleEventDescriptor(bundleIdentifier: Self.finderID)
        let status = AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, false)
        return Self.permission(forStatus: status)
    }

    static func permission(forStatus status: OSStatus) -> FinderPermission {
        switch Int(status) {
        case 0: .granted
        case -1744: .askFirst  // errAEEventWouldRequireUserConsent
        case -600: .notRunning  // procNotFound
        default: .denied  // -1743 errAEEventNotPermitted, or anything else that is not a yes
        }
    }

    public func selection(askUser: Bool, timeout: TimeInterval) async -> FinderSelectionOutcome {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Self.querySelection(askUser: askUser, timeout: timeout))
            }
        }
    }

    // MARK: the event

    /// "get selection of application Finder", asking for file URLs.
    static func makeSelectionEvent() -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kAECoreSuite), eventID: AEEventID(kAEGetData),
            targetDescriptor: NSAppleEventDescriptor(bundleIdentifier: finderID),
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))

        // an object specifier: the property `selection` of the application (a null container)
        let specifier = NSAppleEventDescriptor.record()
        specifier.setDescriptor(NSAppleEventDescriptor(typeCode: fourCC("prop")), forKeyword: fourCC("want"))
        specifier.setDescriptor(NSAppleEventDescriptor.null(), forKeyword: fourCC("from"))
        specifier.setDescriptor(NSAppleEventDescriptor(enumCode: fourCC("prop")), forKeyword: fourCC("form"))
        specifier.setDescriptor(NSAppleEventDescriptor(typeCode: fourCC("sele")), forKeyword: fourCC("seld"))
        if let object = specifier.coerce(toDescriptorType: fourCC("obj ")) {
            event.setParam(object, forKeyword: fourCC("----"))
        }
        event.setParam(NSAppleEventDescriptor(typeCode: fourCC("furl")), forKeyword: fourCC("rtyp"))
        return event
    }

    private static func querySelection(askUser: Bool, timeout: TimeInterval) -> FinderSelectionOutcome {
        let event = makeSelectionEvent()
        var reply = AppleEvent()
        let mode = AESendMode(kAEWaitReply) | AESendMode(askUser ? kAEAlwaysInteract : kAENeverInteract)
        let status = AESendMessage(event.aeDesc, &reply, mode, Int(timeout * 60))  // the time limit is in ticks
        defer { AEDisposeDesc(&reply) }
        guard status == noErr else { return outcome(forStatus: status) }
        return parse(reply: NSAppleEventDescriptor(aeDescNoCopy: &reply))
    }

    private static func outcome(forStatus status: OSStatus) -> FinderSelectionOutcome {
        switch Int(status) {
        case -1743, -1744: .notPermitted
        case -1712: .unavailable("Finder did not answer in time.")
        case -600: .unavailable("Finder is not running.")
        default: .unavailable("Apple Event error \(status).")
        }
    }

    /// The files of a reply, or why there are none.
    static func parse(reply: NSAppleEventDescriptor) -> FinderSelectionOutcome {
        if let error = reply.paramDescriptor(forKeyword: fourCC("errn")), error.int32Value != 0 {
            return outcome(forStatus: error.int32Value)
        }
        guard let result = reply.paramDescriptor(forKeyword: fourCC("----")) else { return .empty }
        var urls: [URL] = []
        if result.descriptorType == fourCC("furl") {
            if let url = result.fileURLValue { urls.append(url) }
        } else if result.numberOfItems > 0 {
            for index in 1...result.numberOfItems {
                if let url = result.atIndex(index)?.fileURLValue { urls.append(url) }
            }
        }
        return urls.isEmpty ? .empty : .files(urls)
    }
}

/// A four-character code as the number Apple Events use.
func fourCC(_ code: String) -> FourCharCode {
    code.utf8.reduce(0) { $0 << 8 | FourCharCode($1) }
}
