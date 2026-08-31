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

// MARK: - Windows that hold focus

/// A window that must keep its app's keyboard focus, matched on the accessibility identifier its
/// developer gave it. For prompts the subrole checks cannot classify: Finder's file-operation
/// window -- the one asking whether to replace the file you just dropped -- reports subrole
/// AXStandardWindow while (on macOS 27) Finder's ordinary browser windows report AXDialog, exactly
/// backwards. Its identifier ("Progress"), unlike its title ("Copy"), survives localization.
public struct PromptRule: Equatable, Sendable {
    public let bundleID: String
    public let identifier: String

    public init(bundleID: String, identifier: String) {
        self.bundleID = bundleID
        self.identifier = identifier
    }
}

/// Whether the window that currently holds its app's keyboard focus should keep it against a
/// pointer-driven switch to a *sibling* window of the same app.
///
/// The mirror image of the transient-window rejection above. Heed already refuses to *give* focus
/// to a dialog or floating panel; this refuses to *take* key status away from one. The everyday
/// case is the About box: picked from a menu, it opens away from the pointer, so the main window
/// still sitting under the pointer immediately takes key status back -- and since a dialog can
/// never be acquired by pointer, hovering the panel cannot restore it. The panel is buried before
/// it can be read. (CodeBurn's About panel, which motivated this, reports subrole AXDialog and an
/// empty title -- a title-based exception would have had nothing to match.)
///
/// Scoped to the same app on purpose: moving the pointer to a *different* app is a clear change of
/// intent and still switches. Within the app, clicking a sibling window still works too; that is
/// macOS, not Heed.
public func transientWindowHoldsFocus(subrole: String?) -> Bool {
    guard let subrole else { return false }
    return transientSubroles.contains(subrole)
}

/// Whether the window holding an app's keyboard focus is a prompt in the middle of asking its
/// question, which the agent answers for by moving no focus anywhere: stealing focus raises
/// another window over the prompt, and a buried prompt can never be reached by pointer again,
/// because the hit test resolves whatever covers it.
///
/// Two conditions, both required. The identifier rule names the window; the button count tells the
/// question form from the idle one. Finder's Progress window is both the file-copy progress bar
/// and the replace/skip/stop question -- same identifier, same subrole -- and only the question
/// form shows a row of answer buttons as direct children of the window. Requiring two or more
/// keeps a lone Stop button from freezing pointer focus for the length of a big copy.
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

    // Windows that pass every structural check and are still transient chrome. Outlook's meeting
    // reminder is the motivating case; see Config.builtinTitleExclusions.
    let rules = policy.titleRules.filter { $0.applies(toBundleID: candidate.bundleID) }
    if !rules.isEmpty, let title = candidate.title,
       titleIsExcluded(title, bundleID: candidate.bundleID, rules: rules) {
        return .reject("title \"\(title)\" matches a transient-window rule")
    }

    return .accept
}
