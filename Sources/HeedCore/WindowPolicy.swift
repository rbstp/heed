import ApplicationServices
import CoreGraphics
import Foundation

// Decisions over values read from Accessibility, kept apart from the calls that read them so the
// guard chain is testable. ApplicationServices is imported for the role constants only.

public enum WindowSource: Equatable, Sendable {
    case topLevel
    /// `AXWindow`, which maps an element inside a sheet to the sheet's owner.
    case windowAttribute
    case hitElement
}

public enum WindowResolution: Equatable, Sendable {
    /// A sheet's app is already frontmost; disturbing a modal interaction is not worth it.
    case sheet
    case tryInOrder([WindowSource])
}

/// `AXTopLevelUIElement` is the only source that reveals a sheet, so it is consulted first, but it
/// is trusted only when it really is a window: some apps report a content element as their top level.
public func resolveWindowSource(topLevelRole: String?, elementRole: String?) -> WindowResolution {
    if topLevelRole == kAXSheetRole { return .sheet }

    var order: [WindowSource] = []
    if topLevelRole == kAXWindowRole { order.append(.topLevel) }
    order.append(.windowAttribute)
    if elementRole == kAXWindowRole { order.append(.hitElement) }
    return .tryInOrder(order)
}

public struct WindowCandidate: Sendable {
    public let role: String?
    public let subrole: String?
    public let isModal: Bool
    public let isMinimized: Bool
    public let size: CGSize?
    public let title: String?
    public let bundleID: String?
    public let canActivate: Bool

    public init(
        role: String?, subrole: String?, isModal: Bool, isMinimized: Bool,
        size: CGSize?, title: String?, bundleID: String?, canActivate: Bool
    ) {
        self.role = role
        self.subrole = subrole
        self.isModal = isModal
        self.isMinimized = isMinimized
        self.size = size
        self.title = title
        self.bundleID = bundleID
        self.canActivate = canActivate
    }
}

public struct WindowPolicy {
    /// Allow only subrole `AXStandardWindow`: every ordinary window reports it and transient chrome
    /// does not, and enumerating every kind of panel to reject is a losing game.
    public var requireStandardWindow: Bool
    public var minimumSize: CGFloat
    public var excludedBundleIDs: Set<String>
    public var titleRules: [TitleRule]

    public init(
        requireStandardWindow: Bool = true,
        minimumSize: CGFloat = 40,
        excludedBundleIDs: Set<String> = [],
        titleRules: [TitleRule] = []
    ) {
        self.requireStandardWindow = requireStandardWindow
        self.minimumSize = minimumSize
        self.excludedBundleIDs = excludedBundleIDs
        self.titleRules = titleRules
    }
}

public enum WindowVerdict: Equatable {
    case accept
    case reject(String)
}

private let transientSubroles: Set<String> = [
    kAXFloatingWindowSubrole, kAXSystemFloatingWindowSubrole,
    kAXDialogSubrole, kAXSystemDialogSubrole,
]

/// A window that must keep its app's key focus, matched on its accessibility identifier. Finder's
/// replace/skip prompt reports subrole AXStandardWindow while (on macOS 27) its browser windows
/// report AXDialog, so the subrole cannot classify it; its identifier survives localization.
public struct PromptRule: Equatable, Sendable {
    public let bundleID: String
    public let identifier: String

    public init(bundleID: String, identifier: String) {
        self.bundleID = bundleID
        self.identifier = identifier
    }
}

/// Whether the window holding an app's key focus keeps it against a pointer-driven switch to a
/// sibling window. A dialog can never be acquired by pointer, so once buried it stays buried.
public func transientWindowHoldsFocus(subrole: String?) -> Bool {
    guard let subrole else { return false }
    return transientSubroles.contains(subrole)
}

/// Whether the frontmost app's key window is a prompt mid-question. Two or more window-level buttons
/// tell the question form from the idle one: Finder's Progress window is also the plain copy bar.
public func windowAwaitsAnswer(
    identifier: String?, bundleID: String?, buttonCount: Int, promptRules: [PromptRule]
) -> Bool {
    guard buttonCount >= 2, let identifier, let bundleID else { return false }
    return promptRules.contains { $0.bundleID == bundleID && $0.identifier == identifier }
}

public func evaluate(_ candidate: WindowCandidate, policy: WindowPolicy) -> WindowVerdict {
    guard candidate.role == kAXWindowRole else {
        return .reject("role \(candidate.role ?? "nil")")
    }

    if policy.requireStandardWindow {
        guard candidate.subrole == kAXStandardWindowSubrole else {
            return .reject("subrole \(candidate.subrole ?? "none") is not a standard window")
        }
    } else if let subrole = candidate.subrole, transientSubroles.contains(subrole) {
        return .reject("subrole \(subrole)")
    }

    if candidate.isModal { return .reject("modal") }
    if candidate.isMinimized { return .reject("minimized") }

    guard let size = candidate.size else { return .reject("no size reported") }
    if size.width < policy.minimumSize || size.height < policy.minimumSize {
        return .reject("too small (\(Int(size.width))x\(Int(size.height)))")
    }

    guard candidate.canActivate else { return .reject("the app cannot be activated") }

    if let bundleID = candidate.bundleID, policy.excludedBundleIDs.contains(bundleID) {
        return .reject("excluded \(bundleID)")
    }

    if let title = candidate.title,
       titleIsExcluded(title, bundleID: candidate.bundleID, rules: policy.titleRules) {
        return .reject("title \"\(title)\" matches a transient-window rule")
    }

    return .accept
}
