import ApplicationServices
import Foundation

// MARK: - Attribute access
//
// Thin wrappers so call sites read as intent rather than as out-parameter plumbing. Every one of
// these is a cross-process message, so they are all potential stalls; callers keep the number per
// tick down deliberately.

func axCopy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
    return value
}

func axString(_ element: AXUIElement, _ attribute: String) -> String? {
    axCopy(element, attribute) as? String
}

func axBool(_ element: AXUIElement, _ attribute: String) -> Bool? {
    axCopy(element, attribute) as? Bool
}

func axElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
    guard let value = axCopy(element, attribute),
          CFGetTypeID(value) == AXUIElementGetTypeID()
    else { return nil }
    return (value as! AXUIElement)
}

func axPoint(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
    guard let value = axCopy(element, attribute),
          CFGetTypeID(value) == AXValueGetTypeID()
    else { return nil }
    var point = CGPoint.zero
    guard AXValueGetValue((value as! AXValue), .cgPoint, &point) else { return nil }
    return point
}

func axSize(_ element: AXUIElement, _ attribute: String) -> CGSize? {
    guard let value = axCopy(element, attribute),
          CFGetTypeID(value) == AXValueGetTypeID()
    else { return nil }
    var size = CGSize.zero
    guard AXValueGetValue((value as! AXValue), .cgSize, &size) else { return nil }
    return size
}

@discardableResult
func axSet(_ element: AXUIElement, _ attribute: String, _ value: CFTypeRef) -> AXError {
    AXUIElementSetAttributeValue(element, attribute as CFString, value)
}

/// Whether an attribute can actually be written on this specific element. Needed because
/// settability is per-element, not per-role: `AXFocused` is writable on some windows and not
/// others, so it has to be asked rather than assumed.
func axIsSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
    var settable: DarwinBoolean = false
    guard AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success else { return false }
    return settable.boolValue
}

func axPid(_ element: AXUIElement) -> pid_t? {
    var pid: pid_t = 0
    guard AXUIElementGetPid(element, &pid) == .success else { return nil }
    return pid
}

// MARK: - Target

/// A window the pointer is over, and the app that owns it.
///
/// `window` is nil for the app-level fallback used when an app exposes no usable Accessibility tree
/// (some games, XQuartz, a few Java toolkits). Per-window precision is not reachable for those
/// without private API; the app is the honest ceiling.
struct Target {
    let pid: pid_t
    let window: AXUIElement?
    let bundleID: String?
    /// Captured at hit-test time. Used to compare windows without further cross-process calls --
    /// see the equality below for why identity alone is not enough.
    let frame: CGRect
    /// For logs only.
    let describedAs: String
}

extension Target: Equatable {
    static func == (lhs: Target, rhs: Target) -> Bool {
        guard lhs.pid == rhs.pid else { return false }
        switch (lhs.window, rhs.window) {
        case (nil, nil):
            return true
        case let (lhsWindow?, rhsWindow?):
            // CFEqual first, then the frame.
            //
            // Identity alone is not sufficient: Electron apps (Slack, Spotify) hand back a different
            // AXUIElement instance for the same logical window depending on how it was obtained, so
            // CFEqual reports a difference where there is none. Treating that as a different window
            // makes the pointer look like it is constantly entering somewhere new. The frame is
            // captured up front, so this costs no extra cross-process calls.
            if CFEqual(lhsWindow, rhsWindow) { return true }
            return !lhs.frame.isEmpty && lhs.frame == rhs.frame
        default:
            return false
        }
    }
}
