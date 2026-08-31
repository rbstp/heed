import Foundation

/// A rule that excludes a window from pointer focus based on its title.
///
/// Needed because some windows are transient chrome yet are structurally indistinguishable from
/// ordinary document windows -- see `Config.builtinTitleExclusions` for the case that motivated it.
/// Kept here, away from the Accessibility code, so the matching is directly testable: the risk with
/// title rules is not that they fail to match, it is that they match too much.
public struct TitleRule {
    /// The app this rule applies to. `nil` applies it to every app.
    public let bundleID: String?
    private let regex: NSRegularExpression

    /// Returns nil if the pattern is not a valid regular expression.
    public init?(bundleID: String?, pattern: String) {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else { return nil }
        self.bundleID = bundleID
        self.regex = regex
    }

    public func applies(toBundleID bundle: String?) -> Bool {
        bundleID == nil || bundleID == bundle
    }

    public func matches(_ title: String) -> Bool {
        let whole = NSRange(title.startIndex..., in: title)
        return regex.firstMatch(in: title, range: whole) != nil
    }
}

/// Whether a window with this title, owned by this app, should be left alone.
public func titleIsExcluded(_ title: String, bundleID: String?, rules: [TitleRule]) -> Bool {
    rules.contains { $0.applies(toBundleID: bundleID) && $0.matches(title) }
}
