import ApplicationServices
import Foundation

// Every call here is a cross-process message and a potential stall; callers keep the count per
// tick down.

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

func axFrame(_ element: AXUIElement) -> CGRect? {
    guard let origin = axPoint(element, kAXPositionAttribute),
          let size = axSize(element, kAXSizeAttribute)
    else { return nil }
    return CGRect(origin: origin, size: size)
}

@discardableResult
func axSet(_ element: AXUIElement, _ attribute: String, _ value: CFTypeRef) -> AXError {
    AXUIElementSetAttributeValue(element, attribute as CFString, value)
}

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

struct Target {
    let pid: pid_t
    let window: AXUIElement?
    let bundleID: String?
    let frame: CGRect
    let title: String?
    let describedAs: String
}

extension Target: Equatable {
    static func == (lhs: Target, rhs: Target) -> Bool {
        guard lhs.pid == rhs.pid else { return false }
        switch (lhs.window, rhs.window) {
        case (nil, nil):
            return true
        case let (lhsWindow?, rhsWindow?):
            // Electron hands back a different AXUIElement for the same window depending on how it
            // was obtained, so identity is backed by frame and title. Frame alone is not identity:
            // two maximised windows of one app share one.
            if CFEqual(lhsWindow, rhsWindow) { return true }
            guard !lhs.frame.isNull, !lhs.frame.isEmpty, lhs.frame == rhs.frame else { return false }
            return lhs.title == rhs.title
        default:
            return false
        }
    }
}

/// A live element as a `Target`, so the identity rule in `Target ==` is the only one there is. Only
/// the fields that rule reads are filled in.
func windowTarget(_ element: AXUIElement, pid: pid_t) -> Target {
    Target(pid: pid, window: element, bundleID: nil, frame: axFrame(element) ?? .null,
           title: axString(element, kAXTitleAttribute), describedAs: "")
}

/// Whether a live element is the window a `Target` names. `CFEqual` first: it answers for most
/// windows without the two reads behind it.
func sameWindow(_ element: AXUIElement, as target: Target) -> Bool {
    guard let window = target.window else { return false }
    if CFEqual(element, window) { return true }
    return windowTarget(element, pid: target.pid) == target
}
