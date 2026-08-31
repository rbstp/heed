import ApplicationServices
import CoreGraphics
import Foundation

/// Which Accessibility element to treat as "the window under the pointer", and whether a candidate
/// window is eligible for pointer focus.
///
/// Split out from the Accessibility code because these are decisions over *values*, not over API
/// calls: given a role, a subrole, a size and a title, the answer is fixed. Keeping them here makes
/// the whole guard chain testable, which matters because it is where the mistakes have actually been
/// made -- trusting a top-level element that was not a window, and letting a transient panel through.
///
/// ApplicationServices is imported for the role and subrole constants only, so they have one source
/// of truth rather than being retyped. Nothing here calls the Accessibility API.
///
/// What this deliberately does not abstract is the platform behaviour itself. Whether `AXFrontmost`
/// moves focus, or whether `AXFocusedApplication` answers at all, cannot be learned from a test
/// double: a double returns whatever its author believed, and that belief was the bug. Those live in
/// the agent, verified against the running system and logged.

// MARK: - Choosing the window

public enum WindowSource: Equatable, Sendable {
    /// The element's `AXTopLevelUIElement`.
    case topLevel
    /// The element's `AXWindow`, which maps an element inside a sheet to the sheet's *owner*.
    case windowAttribute
    /// The hit element itself, when it is already a window.
    case hitElement
}

public enum WindowResolution: Equatable, Sendable {
    /// The pointer is over a sheet. Its app is necessarily frontmost already, and disturbing a modal
    /// interaction is not worth it.
    case sheet
    /// Sources to try in order; the first that yields an element wins.
    case tryInOrder([WindowSource])
}

/// Decide where to look for the window, from the roles alone.
///
/// `AXTopLevelUIElement` is consulted first because it is the only one that reveals a sheet --
/// `AXWindow` would report the sheet's owner and hide it. But it is only *trusted* when it really is
/// a window: some apps report a content element, an `AXList` for one, as their top level, and taking
/// that at face value made every window of those apps unfocusable.
public func resolveWindowSource(topLevelRole: String?, elementRole: String?) -> WindowResolution {
    if topLevelRole == kAXSheetRole { return .sheet }

    var order: [WindowSource] = []
    if topLevelRole == kAXWindowRole { order.append(.topLevel) }
    order.append(.windowAttribute)
    if elementRole == kAXWindowRole { order.append(.hitElement) }
    return .tryInOrder(order)
}

// MARK: - Judging the window

/// Everything the policy needs to know about a candidate window, read once by the caller.
public struct WindowCandidate: Sendable {
    public let role: String?
    public let subrole: String?
    public let isModal: Bool
    public let isMinimized: Bool
    public let size: CGSize?
    public let title: String?
    public let bundleID: String?
    /// False for apps macOS will not activate at all (`.prohibited`).
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
    /// Require subrole `AXStandardWindow`. An allowlist, because every ordinary window across the
    /// apps tested reports it while transient chrome does not, and enumerating every kind of panel,
    /// alert, HUD and popover to reject is a losing game.
    public var requireStandardWindow: Bool
    /// Windows smaller than this in either dimension are treated as chrome.
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
    /// Carries the reason, so the log can say why rather than just that.
    case reject(String)
}

/// Subroles rejected when `requireStandardWindow` is off: floating panels and dialogs.
private let transientSubroles: Set<String> = [
    kAXFloatingWindowSubrole, kAXSystemFloatingWindowSubrole,
    kAXDialogSubrole, kAXSystemDialogSubrole,
]

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

    // Windows that pass every structural check and are still transient chrome. Outlook's meeting
    // reminder is the motivating case; see Config.builtinTitleExclusions.
    let rules = policy.titleRules.filter { $0.applies(toBundleID: candidate.bundleID) }
    if !rules.isEmpty, let title = candidate.title,
       titleIsExcluded(title, bundleID: candidate.bundleID, rules: rules) {
        return .reject("title \"\(title)\" matches a transient-window rule")
    }

    return .accept
}
