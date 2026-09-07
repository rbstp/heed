import Foundation

public struct TitleRule {
    public let bundleID: String?
    private let regex: NSRegularExpression

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
        regex.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)) != nil
    }
}

public func titleIsExcluded(_ title: String, bundleID: String?, rules: [TitleRule]) -> Bool {
    rules.contains { $0.applies(toBundleID: bundleID) && $0.matches(title) }
}
