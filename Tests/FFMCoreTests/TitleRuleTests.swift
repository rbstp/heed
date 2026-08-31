import XCTest
@testable import FFMCore

final class TitleRuleTests: XCTestCase {
    private let outlook = "com.microsoft.Outlook"
    /// The shipped rule for Outlook's meeting reminder panel.
    private let reminderPattern = "^[0-9]+ (Reminders?|rappels?)$"

    private func rules(_ pairs: [(String?, String)]) -> [TitleRule] {
        pairs.compactMap { TitleRule(bundleID: $0.0, pattern: $0.1) }
    }

    func testMatchesOutlookReminderPanel() {
        let r = rules([(outlook, reminderPattern)])
        XCTAssertTrue(titleIsExcluded("1 Reminder", bundleID: outlook, rules: r))
        XCTAssertTrue(titleIsExcluded("3 Reminders", bundleID: outlook, rules: r))
        XCTAssertTrue(titleIsExcluded("12 Reminders", bundleID: outlook, rules: r))
    }

    /// The whole reason the pattern is anchored. An email about a reminder is an ordinary window and
    /// must stay focusable -- a substring match on "Reminder" would silently break it.
    func testDoesNotMatchAnEmailWhoseSubjectMentionsReminders() {
        let r = rules([(outlook, reminderPattern)])
        for title in [
            "Reminder: standup tomorrow",
            "RE: Reminder to submit timesheets",
            "1 Reminder about your invoice",
            "Reminders",
            "Calendar",
            "Inbox - rboisvert@devolutions.net",
        ] {
            XCTAssertFalse(
                titleIsExcluded(title, bundleID: outlook, rules: r),
                "\"\(title)\" is an ordinary window and must stay focusable"
            )
        }
    }

    /// The title follows Outlook's locale, so the shipped rule carries the French titles too.
    func testMatchesOutlookReminderPanelInFrench() {
        let r = rules([(outlook, reminderPattern)])
        XCTAssertTrue(titleIsExcluded("1 rappel", bundleID: outlook, rules: r))
        XCTAssertTrue(titleIsExcluded("3 rappels", bundleID: outlook, rules: r))
    }

    func testDoesNotMatchAnEmailWhoseSubjectMentionsRappels() {
        let r = rules([(outlook, reminderPattern)])
        for title in [
            "Rappel : standup demain",
            "RE: rappel pour les feuilles de temps",
            "1 rappel de plus",
            "Rappels",
        ] {
            XCTAssertFalse(
                titleIsExcluded(title, bundleID: outlook, rules: r),
                "\"\(title)\" is an ordinary window and must stay focusable"
            )
        }
    }

    func testRuleIsScopedToItsApp() {
        let r = rules([(outlook, reminderPattern)])
        XCTAssertFalse(
            titleIsExcluded("1 Reminder", bundleID: "com.apple.Reminders", rules: r),
            "an Outlook-scoped rule must not affect another app's identically titled window"
        )
        XCTAssertFalse(titleIsExcluded("1 Reminder", bundleID: nil, rules: r))
    }

    func testUnscopedRuleAppliesEverywhere() {
        let r = rules([(nil, "^Picture in Picture$")])
        XCTAssertTrue(titleIsExcluded("Picture in Picture", bundleID: "app.zen-browser.zen", rules: r))
        XCTAssertTrue(titleIsExcluded("picture in picture", bundleID: "com.apple.Safari", rules: r))
        XCTAssertFalse(titleIsExcluded("Picture in Picture Settings", bundleID: nil, rules: r))
    }

    func testInvalidPatternIsRejectedRatherThanCrashing() {
        XCTAssertNil(TitleRule(bundleID: nil, pattern: "[unterminated"))
    }

    func testNoRulesExcludesNothing() {
        XCTAssertFalse(titleIsExcluded("1 Reminder", bundleID: outlook, rules: []))
    }
}
