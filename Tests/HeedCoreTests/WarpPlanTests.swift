import CoreGraphics
import XCTest
@testable import HeedCore

final class WarpPlanTests: XCTestCase {
    // Two 1920x1080 displays side by side, top-left origin.
    private let left = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    private let right = CGRect(x: 1920, y: 0, width: 1920, height: 1080)

    private func point(
        _ frame: CGRect, x: Int = 50, y: Int = 50, pointer: CGPoint? = nil, screens: [CGRect]? = nil
    ) -> CGPoint? {
        warpPoint(into: frame, xPercent: x, yPercent: y, pointer: pointer,
                  screens: screens ?? [left, right])
    }

    // MARK: - When not to move the pointer

    func testAPointerAlreadyInTheWindowStaysWhereItIs() {
        let window = CGRect(x: 100, y: 100, width: 800, height: 600)
        XCTAssertNil(point(window, pointer: CGPoint(x: 400, y: 300)))
    }

    /// Sharing an edge is inside as far as `CGRect.contains` is concerned, and that is the same rule
    /// the hit test resolves by.
    func testAPointerOnTheWindowEdgeCountsAsInside() {
        let window = CGRect(x: 100, y: 100, width: 800, height: 600)
        XCTAssertNil(point(window, pointer: CGPoint(x: 100, y: 100)))
        XCTAssertNotNil(point(window, pointer: CGPoint(x: 900, y: 700)),
                        "the far edge is outside, so this one does move")
    }

    func testNoFrameMeansNoWarp() {
        XCTAssertNil(point(.null))
        XCTAssertNil(point(CGRect(x: 100, y: 100, width: 0, height: 600)))
    }

    func testAWindowOnNoScreenAtAllMeansNoWarp() {
        let offscreen = CGRect(x: 5_000, y: 5_000, width: 800, height: 600)
        XCTAssertNil(point(offscreen))
    }

    /// A window merely touching a display edge shows nothing of itself.
    func testAWindowTouchingAScreenEdgeMeansNoWarp() {
        XCTAssertNil(point(CGRect(x: -800, y: 0, width: 800, height: 600)))
    }

    func testAnUnknownPointerPositionStillWarps() {
        let window = CGRect(x: 100, y: 100, width: 800, height: 600)
        XCTAssertEqual(point(window, pointer: nil), CGPoint(x: 500, y: 400))
    }

    // MARK: - Where it lands

    func testTheDefaultIsTheCentreOfTheWindow() {
        let window = CGRect(x: 200, y: 100, width: 800, height: 600)
        XCTAssertEqual(point(window, pointer: CGPoint(x: 1_800, y: 900)), CGPoint(x: 600, y: 400))
    }

    func testPercentagesAreReadAgainstTheWindow() {
        let window = CGRect(x: 200, y: 100, width: 800, height: 600)
        let away = CGPoint(x: 1_800, y: 900)
        // Two pixels in from each edge, so 0 and 100 land inside the window rather than on its line.
        XCTAssertEqual(point(window, x: 0, y: 0, pointer: away), CGPoint(x: 202, y: 102))
        XCTAssertEqual(point(window, x: 100, y: 100, pointer: away), CGPoint(x: 998, y: 698))
        XCTAssertEqual(point(window, x: 25, y: 75, pointer: away), CGPoint(x: 400, y: 550))
    }

    func testPercentagesOutsideTheRangeAreClamped() {
        let window = CGRect(x: 200, y: 100, width: 800, height: 600)
        let away = CGPoint(x: 1_800, y: 900)
        XCTAssertEqual(point(window, x: -50, y: 400, pointer: away), CGPoint(x: 202, y: 698))
    }

    // MARK: - Windows hanging off a display

    func testAWindowHalfOffTheLeftEdgeLandsOnThePartThatShows() {
        // Centre would be at x=-100, which no display can show.
        let window = CGRect(x: -500, y: 100, width: 800, height: 600)
        let warped = point(window, pointer: CGPoint(x: 1_800, y: 900))
        XCTAssertEqual(warped, CGPoint(x: 2, y: 400))
    }

    func testAWindowHangingOffTheBottomIsClampedToTheDisplay() {
        let window = CGRect(x: 200, y: 800, width: 800, height: 600)
        let warped = point(window, pointer: CGPoint(x: 1_800, y: 100))
        XCTAssertEqual(warped, CGPoint(x: 600, y: 1_078))
    }

    /// A sliver narrower than the margin gets a point rather than an inverted inset.
    func testASliverOfAWindowStillGetsAPoint() {
        let window = CGRect(x: -799, y: 100, width: 800, height: 600)
        XCTAssertEqual(point(window, pointer: CGPoint(x: 1_800, y: 900)), CGPoint(x: 0, y: 400))
    }

    // MARK: - Several displays

    func testAWindowOnTheSecondDisplayLandsThere() {
        let window = CGRect(x: 2_400, y: 200, width: 800, height: 600)
        XCTAssertEqual(point(window, pointer: CGPoint(x: 100, y: 100)), CGPoint(x: 2_800, y: 500))
    }

    /// Straddling two displays, the one showing more of the window is the one that clamps.
    func testAWindowStraddlingTwoDisplaysIsClampedToTheOneShowingMostOfIt() {
        let window = CGRect(x: 1_620, y: 100, width: 800, height: 600)
        // 300px on the left display, 500px on the right one, so the right one wins and the centre
        // at x=2020 is already inside it.
        XCTAssertEqual(point(window, pointer: CGPoint(x: 100, y: 900)), CGPoint(x: 2_020, y: 400))
    }

    /// A display above the primary one has a negative origin.
    func testADisplayAboveThePrimaryOneWorksLikeAnyOther() {
        let above = CGRect(x: 0, y: -1_080, width: 1_920, height: 1_080)
        let window = CGRect(x: 100, y: -900, width: 800, height: 600)
        XCTAssertEqual(point(window, pointer: CGPoint(x: 100, y: 100), screens: [left, above]),
                       CGPoint(x: 500, y: -600))
    }

    /// Nothing to clamp against is not the same as nowhere to go.
    func testWithNoDisplaysReportedTheWindowItselfIsTheBounds() {
        let window = CGRect(x: 100, y: 100, width: 800, height: 600)
        XCTAssertEqual(point(window, pointer: CGPoint(x: 9_000, y: 9_000), screens: []),
                       CGPoint(x: 500, y: 400))
    }
}

extension WarpPlanTests {
    /// Accessibility can report a window at no position at all, and NaN defeats every comparison:
    /// the rect is neither null nor empty, and the clamp would carry the NaN through.
    func testANonFiniteFrameMeansNoWarp() {
        let noOrigin = CGRect(x: CGFloat.nan, y: 100, width: 800, height: 600)
        XCTAssertFalse(noOrigin.isNull || noOrigin.isEmpty, "the guard cannot lean on isNull")
        XCTAssertNil(point(noOrigin, pointer: CGPoint(x: 1_800, y: 900)))
        XCTAssertNil(point(CGRect(x: 100, y: CGFloat.nan, width: 800, height: 600)))
        XCTAssertNil(point(CGRect(x: 100, y: 100, width: CGFloat.infinity, height: 600)))
    }

    func testANonFinitePointerIsTreatedAsUnknown() {
        let window = CGRect(x: 100, y: 100, width: 800, height: 600)
        XCTAssertEqual(point(window, pointer: CGPoint(x: CGFloat.nan, y: CGFloat.nan)), CGPoint(x: 500, y: 400))
    }
}
