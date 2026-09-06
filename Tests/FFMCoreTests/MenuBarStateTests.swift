import XCTest
@testable import FFMCore

final class MenuBarStateTests: XCTestCase {
    func testBrightOnlyWhenItCanActuallyWork() {
        XCTAssertFalse(MenuBarState(enabled: true, trusted: true).dimmed)
        XCTAssertTrue(MenuBarState(enabled: false, trusted: true).dimmed)
        XCTAssertTrue(MenuBarState(enabled: true, trusted: false).dimmed)
        XCTAssertTrue(MenuBarState(enabled: false, trusted: false).dimmed)
    }

    /// Nothing re-checks trust while off, so a tooltip naming the grant would go stale.
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

    /// The label is all a VoiceOver user gets, so it carries the switch position.
    func testLabelReportsTheSwitchNotTheDimming() {
        XCTAssertEqual(MenuBarState(enabled: true, trusted: false).label, "Heed, on")
        XCTAssertEqual(MenuBarState(enabled: false, trusted: true).label, "Heed, off")
    }

    func testToggleTitleOffersTheOppositeState() {
        XCTAssertEqual(MenuBarState(enabled: true, trusted: true).toggleTitle, "Turn Heed Off")
        XCTAssertEqual(MenuBarState(enabled: false, trusted: true).toggleTitle, "Turn Heed On")
    }
}
