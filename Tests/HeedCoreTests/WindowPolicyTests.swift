import ApplicationServices
import CoreGraphics
import XCTest
@testable import HeedCore

final class WindowSourceTests: XCTestCase {

    /// Trusting a non-window top level made every window of some apps unfocusable.
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

    /// AXWindow reports a sheet's owner instead, hiding it.
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

    /// An About panel opened from the menu, robbed of key status by the sibling under the pointer.
    func testDialogsHoldFocusAgainstTheirSiblings() {
        XCTAssertTrue(transientWindowHoldsFocus(subrole: kAXDialogSubrole))
        XCTAssertTrue(transientWindowHoldsFocus(subrole: kAXSystemDialogSubrole))
    }

    func testFloatingPanelsHoldFocus() {
        XCTAssertTrue(transientWindowHoldsFocus(subrole: kAXFloatingWindowSubrole))
        XCTAssertTrue(transientWindowHoldsFocus(subrole: kAXSystemFloatingWindowSubrole))
    }

    /// Switching between two documents of one app with the pointer is the core use.
    func testAStandardWindowDoesNotHoldFocus() {
        XCTAssertFalse(transientWindowHoldsFocus(subrole: kAXStandardWindowSubrole))
    }

    func testUnknownSubrolesDoNotHoldFocus() {
        XCTAssertFalse(transientWindowHoldsFocus(subrole: nil))
        XCTAssertFalse(transientWindowHoldsFocus(subrole: kAXUnknownSubrole))
        XCTAssertFalse(transientWindowHoldsFocus(subrole: "AXSomethingCustom"))
    }
}

final class PromptTests: XCTestCase {
    private let finderPrompt = [PromptRule(bundleID: "com.apple.finder", identifier: "Progress")]

    func testFindersReplaceQuestionAwaitsAnswer() {
        XCTAssertTrue(windowAwaitsAnswer(
            identifier: "Progress", bundleID: "com.apple.finder",
            buttonCount: 3, promptRules: finderPrompt
        ))
    }

    /// The same window as a plain copy bar has at most a lone Stop button.
    func testPlainProgressDoesNotHoldFocus() {
        for buttons in [0, 1] {
            XCTAssertFalse(windowAwaitsAnswer(
                identifier: "Progress", bundleID: "com.apple.finder",
                buttonCount: buttons, promptRules: finderPrompt
            ), "\(buttons) window-level button(s) is not a question")
        }
    }

    func testOrdinaryFinderWindowsDoNotMatch() {
        XCTAssertFalse(windowAwaitsAnswer(
            identifier: "FinderWindow", bundleID: "com.apple.finder",
            buttonCount: 3, promptRules: finderPrompt
        ))
    }

    func testARuleIsScopedToItsApp() {
        XCTAssertFalse(windowAwaitsAnswer(
            identifier: "Progress", bundleID: "com.example.App",
            buttonCount: 3, promptRules: finderPrompt
        ))
    }

    func testMissingIdentifierNeverMatches() {
        XCTAssertFalse(windowAwaitsAnswer(
            identifier: nil, bundleID: "com.apple.finder",
            buttonCount: 3, promptRules: finderPrompt
        ))
        XCTAssertFalse(windowAwaitsAnswer(
            identifier: "Progress", bundleID: nil,
            buttonCount: 3, promptRules: finderPrompt
        ))
    }

    func testNoRulesMatchNothing() {
        XCTAssertFalse(windowAwaitsAnswer(
            identifier: "Progress", bundleID: "com.apple.finder",
            buttonCount: 3, promptRules: []
        ))
    }
}

final class WindowPolicyTests: XCTestCase {
    private let outlook = "com.microsoft.Outlook"
    private let reminderRule = TitleRule(bundleID: "com.microsoft.Outlook",
                                         pattern: "^[0-9]+ (Reminders?|rappels?)$")!

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

    func testOnlyStandardWindowsPassTheAllowlist() {
        let policy = WindowPolicy(requireStandardWindow: true)
        XCTAssertEqual(evaluate(candidate(), policy: policy), .accept)
        for subrole in [kAXFloatingWindowSubrole, kAXSystemFloatingWindowSubrole,
                        kAXDialogSubrole, kAXSystemDialogSubrole, kAXUnknownSubrole, nil] {
            XCTAssertNotEqual(evaluate(candidate(subrole: subrole), policy: policy), .accept,
                              "subrole \(subrole ?? "nil") must not pass the allowlist")
        }
    }

    /// The escape hatch for an app whose windows do not report a standard subrole.
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

    /// The reminder panel passes every structural check; the title rule is all that stops it.
    func testOutlooksReminderPanelIsRejectedByTitle() {
        let policy = WindowPolicy(titleRules: [reminderRule])
        XCTAssertNotEqual(
            evaluate(candidate(title: "1 Reminder", bundleID: outlook), policy: policy), .accept
        )
        XCTAssertNotEqual(
            evaluate(candidate(title: "4 Reminders", bundleID: outlook), policy: policy), .accept
        )
    }

    func testAnEmailAboutRemindersStaysFocusable() {
        let policy = WindowPolicy(titleRules: [reminderRule])
        for title in ["Reminder: standup", "RE: Reminder to file expenses", "Calendar"] {
            XCTAssertEqual(
                evaluate(candidate(title: title, bundleID: outlook), policy: policy), .accept,
                "\"\(title)\" is an ordinary window"
            )
        }
    }

    func testATitleRuleDoesNotLeakToOtherApps() {
        let policy = WindowPolicy(titleRules: [reminderRule])
        XCTAssertEqual(
            evaluate(candidate(title: "1 Reminder", bundleID: "com.apple.Reminders"), policy: policy),
            .accept
        )
    }

    /// The user's `excludedWindowTitles` entries carry no bundle id and apply everywhere.
    func testAnUnscopedTitleRuleAppliesToEveryApp() {
        let policy = WindowPolicy(titleRules: [TitleRule(bundleID: nil, pattern: "^Picture in Picture$")!])
        for bundle in ["com.apple.Safari", "app.zen-browser.zen", nil] {
            XCTAssertNotEqual(
                evaluate(candidate(title: "Picture in Picture", bundleID: bundle), policy: policy),
                .accept, "\(bundle ?? "an app with no bundle id") must be excluded too"
            )
        }
        XCTAssertEqual(evaluate(candidate(title: "Document", bundleID: nil), policy: policy), .accept)
    }

    func testAnUnreadableTitleCannotBypassARuleItWouldNotHaveMatched() {
        let policy = WindowPolicy(titleRules: [reminderRule])
        XCTAssertEqual(evaluate(candidate(title: nil, bundleID: outlook), policy: policy), .accept)
    }
}
