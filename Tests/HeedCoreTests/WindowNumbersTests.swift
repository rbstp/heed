import CoreGraphics
import XCTest
@testable import HeedCore

final class WindowNumbersTests: XCTestCase {
    private let controlCommand: Set<HotkeySpec.Modifier> = [.control, .command]

    func testArmsOnTheExactCombination() {
        XCTAssertTrue(numbersArmed(pressed: controlCommand, wanted: controlCommand))
    }

    /// Anything extra makes a combination the numbered shortcuts are not registered under, so the
    /// numbers would be promising keys that do nothing.
    func testDoesNotArmWhenMoreIsHeld() {
        XCTAssertFalse(numbersArmed(pressed: [.control, .command, .shift], wanted: controlCommand))
    }

    func testDoesNotArmWhenLessIsHeld() {
        XCTAssertFalse(numbersArmed(pressed: [.control], wanted: controlCommand))
        XCTAssertFalse(numbersArmed(pressed: [], wanted: controlCommand))
    }

    /// No numbered shortcut is registered, so there is nothing to picture.
    func testDoesNotArmWithoutAShortcut() {
        XCTAssertFalse(numbersArmed(pressed: controlCommand, wanted: nil))
        XCTAssertFalse(numbersArmed(pressed: [], wanted: nil))
        XCTAssertFalse(numbersArmed(pressed: [], wanted: []))
    }

    func testNumbersWindowsInRingOrderFromOne() {
        let badges = numberBadges(at: [CGPoint(x: 50, y: 25), CGPoint(x: 400, y: 250)])
        XCTAssertEqual(badges, [
            NumberBadge(number: 1, centre: CGPoint(x: 50, y: 25)),
            NumberBadge(number: 2, centre: CGPoint(x: 400, y: 250)),
        ])
    }

    /// The shortcuts stop at the digit keys, so a tenth badge would name a key nobody can press.
    func testStopsAtTheLastDigit() {
        let badges = numberBadges(at: (0..<14).map { CGPoint(x: CGFloat($0) * 10, y: 0) })
        XCTAssertEqual(badges.count, 9)
        XCTAssertEqual(badges.last?.number, 9)
    }

    func testNoWindowsMeansNoBadges() {
        XCTAssertTrue(numberBadges(at: []).isEmpty)
    }

    // MARK: - Where a number goes

    func testUncoveredWindowIsNumberedAtItsCentre() {
        let frame = CGRect(x: 0, y: 0, width: 400, height: 200)
        XCTAssertEqual(visibleCentre(of: frame, behind: [] as [CGRect]),
                       CGPoint(x: 200, y: 100))
        XCTAssertEqual(visibleCentre(of: frame, behind: [CGRect(x: 900, y: 900, width: 10, height: 10)]),
                       CGPoint(x: 200, y: 100))
    }

    /// The case the plain centre gets wrong: a window covered across its middle would be numbered
    /// on top of whatever is covering it, and the digit would name the wrong window.
    func testCoveredMiddleMovesTheNumberIntoWhatShows() {
        let frame = CGRect(x: 0, y: 0, width: 400, height: 100)
        let cover = CGRect(x: 100, y: 0, width: 200, height: 100)
        let centre = visibleCentre(of: frame, behind: [cover])
        XCTAssertFalse(cover.contains(centre), "the number must not sit on the covering window")
        // Both clear strips are 100 wide; the left one wins on the sweep reaching it first.
        XCTAssertEqual(centre, CGPoint(x: 50, y: 50))
    }

    /// A dialog centred on its parent: without this the two badges land in the same spot.
    func testTheLargerClearPatchWins() {
        let frame = CGRect(x: 0, y: 0, width: 400, height: 100)
        let dialog = CGRect(x: 100, y: 0, width: 100, height: 100)
        let centre = visibleCentre(of: frame, behind: [dialog])
        // Clear: 0...100 and 200...400. The wider right-hand strip wins.
        XCTAssertEqual(centre, CGPoint(x: 300, y: 50))
        XCTAssertFalse(dialog.contains(centre))
    }

    func testFindsAClearBandAcrossSeveralCovers() {
        let frame = CGRect(x: 0, y: 0, width: 300, height: 300)
        let covers = [
            CGRect(x: 0, y: 0, width: 300, height: 100),
            CGRect(x: 0, y: 200, width: 300, height: 100),
        ]
        XCTAssertEqual(visibleCentre(of: frame, behind: covers), CGPoint(x: 150, y: 150))
    }

    /// Not a window the ring contains, but the caller should not have to know that.
    func testCompletelyCoveredFallsBackToTheCentre() {
        let frame = CGRect(x: 10, y: 20, width: 100, height: 50)
        XCTAssertEqual(visibleCentre(of: frame, behind: [CGRect(x: 0, y: 0, width: 500, height: 500)]),
                       CGPoint(x: 60, y: 45))
    }

    func testEmptyFrameFallsBackToTheCentre() {
        let frame = CGRect(x: 5, y: 5, width: 0, height: 0)
        XCTAssertEqual(visibleCentre(of: frame, behind: [CGRect(x: 0, y: 0, width: 10, height: 10)]),
                       CGPoint(x: 5, y: 5))
    }

    /// Frames are global, and a display left of or above the main one has negative coordinates.
    func testWorksInNegativeCoordinates() {
        let frame = CGRect(x: -400, y: -200, width: 400, height: 100)
        let cover = CGRect(x: -300, y: -200, width: 300, height: 100)
        let centre = visibleCentre(of: frame, behind: [cover])
        XCTAssertEqual(centre, CGPoint(x: -350, y: -150))
        XCTAssertFalse(cover.contains(centre))
    }
}
