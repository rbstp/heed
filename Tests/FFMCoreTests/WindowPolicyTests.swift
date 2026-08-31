import ApplicationServices
import CoreGraphics
import XCTest
@testable import FFMCore

final class WindowSourceTests: XCTestCase {

    /// Regression test. Some apps report a content element as their top level; trusting it because it
    /// was merely non-nil made every window of those apps unfocusable, which showed up in the log as
    /// an endless run of "skipped: role AXList".
    func testAContentElementTopLevelIsNotTrusted() {
        let resolution = resolveWindowSource(topLevelRole: "AXList", elementRole: "AXGroup")
        XCTAssertEqual(resolution, .tryInOrder([.windowAttribute]),
                       "a top level that is not a window must not be used as one")
    }

    func testAWindowTopLevelIsPreferred() {
        XCTAssertEqual(
            resolveWindowSource(topLevelRole: kAXWindowRole, elementRole: "AXButton"),
            .tryInOrder([.topLevel, .windowAttribute])
        )
    }

    /// AXTopLevelUIElement is asked first precisely because it is the only one that reveals a sheet:
    /// AXWindow reports the sheet's owner instead, hiding it.
    func testASheetIsRejectedRatherThanResolvedToItsOwner() {
        XCTAssertEqual(resolveWindowSource(topLevelRole: kAXSheetRole, elementRole: "AXButton"), .sheet)
        XCTAssertEqual(resolveWindowSource(topLevelRole: kAXSheetRole, elementRole: kAXWindowRole), .sheet)
    }

    func testTheHitElementIsUsedOnlyWhenItIsItselfAWindow() {
        XCTAssertEqual(
            resolveWindowSource(topLevelRole: nil, elementRole: kAXWindowRole),
            .tryInOrder([.windowAttribute, .hitElement])
        )
        XCTAssertEqual(
            resolveWindowSource(topLevelRole: nil, elementRole: "AXStaticText"),
            .tryInOrder([.windowAttribute])
        )
    }
}

final class FocusHolderTests: XCTestCase {

    /// The motivating case: an About panel (CodeBurn's reports subrole AXDialog and an empty
    /// title) opened from the menu, immediately robbed of key status by the sibling window still
    /// sitting under the pointer.
    func testDialogsHoldFocusAgainstTheirSiblings() {
        XCTAssertTrue(transientWindowHoldsFocus(subrole: kAXDialogSubrole))
        XCTAssertTrue(transientWindowHoldsFocus(subrole: kAXSystemDialogSubrole))
    }

    func testFloatingPanelsHoldFocus() {
        XCTAssertTrue(transientWindowHoldsFocus(subrole: kAXFloatingWindowSubrole))
        XCTAssertTrue(transientWindowHoldsFocus(subrole: kAXSystemFloatingWindowSubrole))
    }

    /// An ordinary sibling window must not hold: switching between two documents of one app with
    /// the pointer is the tool's core use.
    func testAStandardWindowDoesNotHoldFocus() {
        XCTAssertFalse(transientWindowHoldsFocus(subrole: kAXStandardWindowSubrole))
    }

    func testUnknownSubrolesDoNotHoldFocus() {
        XCTAssertFalse(transientWindowHoldsFocus(subrole: nil))
        XCTAssertFalse(transientWindowHoldsFocus(subrole: kAXUnknownSubrole))
        XCTAssertFalse(transientWindowHoldsFocus(subrole: "AXSomethingCustom"))
    }
}

final class WindowPolicyTests: XCTestCase {
    private let outlook = "com.microsoft.Outlook"

    private func candidate(
        role: String? = kAXWindowRole,
        subrole: String? = kAXStandardWindowSubrole,
        isModal: Bool = false,
        isMinimized: Bool = false,
        size: CGSize? = CGSize(width: 800, height: 600),
        title: String? = "Document",
        bundleID: String? = "com.example.App",
        canActivate: Bool = true
    ) -> WindowCandidate {
        WindowCandidate(
            role: role, subrole: subrole, isModal: isModal, isMinimized: isMinimized,
            size: size, title: title, bundleID: bundleID, canActivate: canActivate
        )
    }

    private func reason(_ verdict: WindowVerdict) -> String? {
        if case let .reject(why) = verdict { return why }
        return nil
    }

    func testAnOrdinaryWindowIsAccepted() {
        XCTAssertEqual(evaluate(candidate(), policy: WindowPolicy()), .accept)
    }

    func testNonWindowRolesAreRejected() {
        for role in ["AXList", "AXGroup", "AXMenu", nil] {
            XCTAssertNotEqual(evaluate(candidate(role: role), policy: WindowPolicy()), .accept,
                              "role \(role ?? "nil") is not a window")
        }
    }

    // MARK: - Subroles

    /// The allowlist is what keeps transient panels from dragging their app forward. Every ordinary
    /// window across the apps tested reports AXStandardWindow; chrome does not.
    func testOnlyStandardWindowsPassTheAllowlist() {
        let policy = WindowPolicy(requireStandardWindow: true)
        XCTAssertEqual(evaluate(candidate(), policy: policy), .accept)
        for subrole in [kAXFloatingWindowSubrole, kAXSystemFloatingWindowSubrole,
                        kAXDialogSubrole, kAXSystemDialogSubrole, kAXUnknownSubrole, nil] {
            XCTAssertNotEqual(evaluate(candidate(subrole: subrole), policy: policy), .accept,
                              "subrole \(subrole ?? "nil") must not pass the allowlist")
        }
    }

    /// With the allowlist off, an unrecognised subrole is allowed through but known chrome is not --
    /// the escape hatch for an app whose windows do not report a standard subrole.
    func testWithTheAllowlistOffOnlyKnownChromeIsRejected() {
        let policy = WindowPolicy(requireStandardWindow: false)
        XCTAssertEqual(evaluate(candidate(subrole: "AXSomethingCustom"), policy: policy), .accept)
        XCTAssertEqual(evaluate(candidate(subrole: nil), policy: policy), .accept)
        XCTAssertNotEqual(evaluate(candidate(subrole: kAXDialogSubrole), policy: policy), .accept)
        XCTAssertNotEqual(evaluate(candidate(subrole: kAXFloatingWindowSubrole), policy: policy), .accept)
    }

    // MARK: - Structural guards

    func testModalAndMinimizedWindowsAreRejected() {
        XCTAssertEqual(reason(evaluate(candidate(isModal: true), policy: WindowPolicy())), "modal")
        XCTAssertEqual(
            reason(evaluate(candidate(isMinimized: true), policy: WindowPolicy())), "minimized"
        )
    }

    func testTinyAndUnmeasurableWindowsAreRejected() {
        let policy = WindowPolicy(minimumSize: 40)
        XCTAssertNotEqual(evaluate(candidate(size: CGSize(width: 20, height: 300)), policy: policy), .accept)
        XCTAssertNotEqual(evaluate(candidate(size: CGSize(width: 300, height: 20)), policy: policy), .accept)
        XCTAssertNotEqual(evaluate(candidate(size: nil), policy: policy), .accept)
        XCTAssertEqual(evaluate(candidate(size: CGSize(width: 40, height: 40)), policy: policy), .accept)
    }

    func testAppsThatCannotBeActivatedAreRejected() {
        XCTAssertNotEqual(evaluate(candidate(canActivate: false), policy: WindowPolicy()), .accept)
    }

    func testExcludedBundlesAreRejected() {
        let policy = WindowPolicy(excludedBundleIDs: ["com.apple.dock"])
        XCTAssertNotEqual(evaluate(candidate(bundleID: "com.apple.dock"), policy: policy), .accept)
        XCTAssertEqual(evaluate(candidate(bundleID: "com.apple.Finder"), policy: policy), .accept)
    }

    // MARK: - Title rules

    /// The reminder panel passes every structural check -- standard subrole, ordinary size, minimize
    /// and zoom buttons -- so the title rule is the only thing standing between it and dragging all
    /// of Outlook in front of your work.
    func testOutlooksReminderPanelIsRejectedByTitle() {
        let policy = WindowPolicy(
            titleRules: [TitleRule(bundleID: outlook, pattern: "^[0-9]+ (Reminders?|rappels?)$")!]
        )
        XCTAssertNotEqual(
            evaluate(candidate(title: "1 Reminder", bundleID: outlook), policy: policy), .accept
        )
        XCTAssertNotEqual(
            evaluate(candidate(title: "4 Reminders", bundleID: outlook), policy: policy), .accept
        )
    }

    func testAnEmailAboutRemindersStaysFocusable() {
        let policy = WindowPolicy(
            titleRules: [TitleRule(bundleID: outlook, pattern: "^[0-9]+ (Reminders?|rappels?)$")!]
        )
        for title in ["Reminder: standup", "RE: Reminder to file expenses", "Calendar"] {
            XCTAssertEqual(
                evaluate(candidate(title: title, bundleID: outlook), policy: policy), .accept,
                "\"\(title)\" is an ordinary window"
            )
        }
    }

    func testATitleRuleDoesNotLeakToOtherApps() {
        let policy = WindowPolicy(
            titleRules: [TitleRule(bundleID: outlook, pattern: "^[0-9]+ (Reminders?|rappels?)$")!]
        )
        XCTAssertEqual(
            evaluate(candidate(title: "1 Reminder", bundleID: "com.apple.Reminders"), policy: policy),
            .accept
        )
    }

    func testAnUnreadableTitleCannotBypassARuleItWouldNotHaveMatched() {
        let policy = WindowPolicy(
            titleRules: [TitleRule(bundleID: outlook, pattern: "^[0-9]+ (Reminders?|rappels?)$")!]
        )
        XCTAssertEqual(evaluate(candidate(title: nil, bundleID: outlook), policy: policy), .accept)
    }
}
