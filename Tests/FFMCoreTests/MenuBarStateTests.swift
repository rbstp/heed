import XCTest
@testable import FFMCore

final class MenuBarStateTests: XCTestCase {
    func testBrightOnlyWhenItCanActuallyWork() {
        XCTAssertFalse(MenuBarState(enabled: true, trusted: true).dimmed)

        // Dimmed for either reason. The icon reports whether the pointer moves anything, and a
        // grant that never arrived means it does not, however the switch is set.
        XCTAssertTrue(MenuBarState(enabled: false, trusted: true).dimmed)
        XCTAssertTrue(MenuBarState(enabled: true, trusted: false).dimmed)
        XCTAssertTrue(MenuBarState(enabled: false, trusted: false).dimmed)
    }

    /// The regression this whole type exists for. Nothing re-checks trust while the agent is not
    /// polling, so naming the missing grant while off would leave the tooltip claiming it long after
    /// the user had granted it -- a message that cannot be made true again without a click.
    func testNeverNamesTheGrantWhileOff() {
        for trusted in [true, false] {
            let state = MenuBarState(enabled: false, trusted: trusted)
            XCTAssertFalse(state.tooltip.contains("Accessibility"),
                           "off tooltip must not mention the grant (trusted: \(trusted))")
            XCTAssertEqual(state.tooltip, "Heed is off. Click to turn it on.")
        }
    }

    func testNamesTheGrantWhileOnAndUntrusted() {
        let state = MenuBarState(enabled: true, trusted: false)
        XCTAssertTrue(state.tooltip.hasPrefix("Heed is on."))
        XCTAssertTrue(state.tooltip.contains("Accessibility"))
        XCTAssertTrue(state.tooltip.contains("System Settings"))
    }

    func testSaysNothingAboutPermissionWhenThereIsNothingToSay() {
        XCTAssertEqual(MenuBarState(enabled: true, trusted: true).tooltip,
                       "Heed is on. Click to turn it off.")
    }

    /// The label is all a VoiceOver user gets, so it carries the switch position rather than
    /// whether the icon happens to be dimmed.
    func testLabelReportsTheSwitchNotTheDimming() {
        XCTAssertEqual(MenuBarState(enabled: true, trusted: false).label, "Heed, on")
        XCTAssertEqual(MenuBarState(enabled: false, trusted: true).label, "Heed, off")
    }

    /// The menu item offers the opposite of the current state; naming the current one is the
    /// classic way to build a switch nobody can read.
    func testToggleTitleOffersTheOppositeState() {
        XCTAssertEqual(MenuBarState(enabled: true, trusted: true).toggleTitle, "Turn Heed Off")
        XCTAssertEqual(MenuBarState(enabled: false, trusted: true).toggleTitle, "Turn Heed On")
    }
}
