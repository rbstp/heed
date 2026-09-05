import CoreGraphics
import XCTest
@testable import FFMCore

final class FocusRingTests: XCTestCase {
    // Two 1920x1080 displays side by side, in the top-left origin space Accessibility reports.
    private let left = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    private let right = CGRect(x: 1920, y: 0, width: 1920, height: 1080)

    private func window(_ key: Int, x: CGFloat, y: CGFloat = 0,
                        width: CGFloat = 960, height: CGFloat = 1080) -> RingWindow {
        RingWindow(frame: CGRect(x: x, y: y, width: width, height: height), key: key)
    }

    private func keys(_ windows: [RingWindow]) -> [Int] {
        windows.map(\.key)
    }

    // MARK: - Order

    /// The shape the shortcut promises: two windows on the first screen, two on the second, walked
    /// in that order and no other.
    func testWalksEachScreenLeftToRight() {
        let ordered = ringOrder(
            [window(1, x: 0), window(2, x: 960),
             window(3, x: 1920), window(4, x: 2880)],
            screens: [left, right]
        )
        XCTAssertEqual(keys(ordered), [1, 2, 3, 4])
    }

    /// The caller hands these over in whatever order the window server and each app listed them,
    /// which is a stacking order and changes every time focus moves. The ring must not.
    func testTheOrderWindowsArriveInDoesNotMatter() {
        let windows = [window(3, x: 1920), window(1, x: 0),
                       window(4, x: 2880), window(2, x: 960)]
        XCTAssertEqual(keys(ringOrder(windows, screens: [left, right])), [1, 2, 3, 4])
    }

    /// Displays are listed by the system in an order of its own; the ring follows the desk instead.
    func testTheOrderScreensArriveInDoesNotMatter() {
        let windows = [window(1, x: 0), window(3, x: 1920)]
        XCTAssertEqual(keys(ringOrder(windows, screens: [right, left])), [1, 3])
    }

    /// A display placed to the *left* of the primary one has a negative origin, which is the case a
    /// comparison against zero would get backwards.
    func testAScreenLeftOfThePrimaryOneComesFirst() {
        let further = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let ordered = ringOrder(
            [window(2, x: 0), window(1, x: -1920)],   // 1 is on the further-left display
            screens: [left, further]
        )
        XCTAssertEqual(keys(ordered), [1, 2])
    }

    func testWindowsInAColumnRunTopToBottom() {
        let ordered = ringOrder(
            [window(2, x: 0, y: 540, height: 540),    // lower
             window(1, x: 0, y: 0, height: 540)],     // upper
            screens: [left]
        )
        XCTAssertEqual(keys(ordered), [1, 2])
    }

    /// Columns before rows: a window further right comes later even when it starts higher up.
    func testHorizontalPositionWinsOverVertical() {
        let ordered = ringOrder(
            [window(2, x: 960, y: 0, height: 540),    // further right, but higher up
             window(1, x: 0, y: 540, height: 540)],   // further left, but lower down
            screens: [left]
        )
        XCTAssertEqual(keys(ordered), [1, 2])
    }

    /// Two maximised windows share a frame exactly. Without the key to break the tie their order
    /// would depend on how the caller happened to collect them, and one of the two could never be
    /// reached: every press would land on whichever came out first.
    func testWindowsSharingAFrameKeepAFixedOrder() {
        let a = RingWindow(frame: left, key: 81)
        let b = RingWindow(frame: left, key: 12337)
        XCTAssertEqual(keys(ringOrder([a, b], screens: [left])), [81, 12337])
        XCTAssertEqual(keys(ringOrder([b, a], screens: [left])), [81, 12337],
                       "the older window first, whichever order they were collected in")
    }

    // MARK: - Which screen a window is on

    /// Dragged across the boundary, a window belongs to the screen showing most of it -- not to
    /// whichever one its origin happens to land in.
    func testAWindowSpanningTwoScreensBelongsToTheOneShowingMostOfIt() {
        // Starts on the left screen, but three quarters of it is on the right one.
        let straddling = window(1, x: 1440, width: 1920)
        let ordered = ringOrder([straddling, window(2, x: 1920)], screens: [left, right])
        XCTAssertEqual(keys(ordered), [1, 2],
                       "both are on the right screen, ordered by position within it")

        let onTheLeft = ringOrder([straddling, window(2, x: 0)], screens: [left, right])
        XCTAssertEqual(keys(onTheLeft), [2, 1], "the left screen's window comes first")
    }

    /// A window dragged almost entirely off an edge, or left behind by a display that was just
    /// unplugged, still has to be reachable. Dropping it from the ring would strand it.
    func testAWindowOffEveryScreenGoesToTheNearestOne() {
        let stranded = window(2, x: 4200, y: 2400, width: 200, height: 200)
        let ordered = ringOrder([window(1, x: 0), stranded], screens: [left, right])
        XCTAssertEqual(keys(ordered), [1, 2], "nearest to the right screen, so it comes last")
    }

    func testWithNoScreensWindowsAreStillOrdered() {
        let ordered = ringOrder([window(2, x: 960), window(1, x: 0)], screens: [])
        XCTAssertEqual(keys(ordered), [1, 2])
    }

    func testAnEmptyRingStaysEmpty() {
        XCTAssertEqual(ringOrder([], screens: [left, right]).count, 0)
    }

    // MARK: - Stepping

    func testStepsForwardAndWrapsRound() {
        XCTAssertEqual(ringStep(count: 4, from: 0, by: 1), 1)
        XCTAssertEqual(ringStep(count: 4, from: 2, by: 1), 3)
        XCTAssertEqual(ringStep(count: 4, from: 3, by: 1), 0)
    }

    func testStepsBackAndWrapsRound() {
        XCTAssertEqual(ringStep(count: 4, from: 3, by: -1), 2)
        XCTAssertEqual(ringStep(count: 4, from: 0, by: -1), 3)
    }

    /// Focus can be on a panel, a sheet, or an app the ring cannot see. The shortcut has to work
    /// from there rather than refusing until focus is somewhere it recognises.
    func testFromOutsideTheRingForwardStartsAtTheFirstWindow() {
        XCTAssertEqual(ringStep(count: 4, from: nil, by: 1), 0)
    }

    func testFromOutsideTheRingBackwardStartsAtTheLastWindow() {
        XCTAssertEqual(ringStep(count: 4, from: nil, by: -1), 3)
    }

    func testASingleWindowStaysWhereItIs() {
        XCTAssertEqual(ringStep(count: 1, from: 0, by: 1), 0)
        XCTAssertEqual(ringStep(count: 1, from: 0, by: -1), 0)
    }

    func testAnEmptyRingHasNowhereToStep() {
        XCTAssertNil(ringStep(count: 0, from: nil, by: 1))
        XCTAssertNil(ringStep(count: 0, from: 0, by: -1))
    }

    /// Held down, the shortcut repeats. Every press must land somewhere real.
    func testRepeatedStepsVisitEveryWindowAndComeBack() {
        var visited: [Int] = []
        var index: Int? = 0
        for _ in 0..<5 {
            index = ringStep(count: 4, from: index, by: 1)
            visited.append(index!)
        }
        XCTAssertEqual(visited, [1, 2, 3, 0, 1])
    }

    func testStepsLargerThanTheRingStayInRange() {
        XCTAssertEqual(ringStep(count: 3, from: 0, by: 7), 1)
        XCTAssertEqual(ringStep(count: 3, from: 0, by: -7), 2)
    }

    // MARK: - What is in the ring at all

    /// The motivating case. The window server calls every window in the Space "on screen", so a
    /// display tiled by two windows still reports whatever they are covering -- and cycling through
    /// those means cycling through every window ever opened.
    func testTwoTiledWindowsHideWhatTheyCover() {
        let slack = CGRect(x: -1920, y: 67, width: 960, height: 1050)
        let zen = CGRect(x: -960, y: 67, width: 960, height: 1050)
        let behindBoth = CGRect(x: -1920, y: 67, width: 1920, height: 1050)
        XCTAssertFalse(isVisible(behindBoth, behind: [slack, zen]),
                       "no single window covers it, but together they cover it exactly")
        XCTAssertTrue(isVisible(behindBoth, behind: [slack]),
                      "half of it still shows")
    }

    /// A stack of maximised windows is one entry, not ten.
    func testAWindowUnderAnIdenticalOneIsHidden() {
        XCTAssertFalse(isVisible(left, behind: [left]))
    }

    func testAWindowWithNothingInFrontIsVisible() {
        XCTAssertTrue(isVisible(left, behind: []))
    }

    func testWindowsElsewhereOnTheDeskDoNotHideIt() {
        XCTAssertTrue(isVisible(left, behind: [right]))
    }

    /// Tiled windows meet along an edge where a point of rounding either way is arbitrary. A
    /// hairline of a buried window peeking out must not put the whole of it back in the ring.
    func testASliverShowingDoesNotCount() {
        let covered = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let almost = CGRect(x: 0, y: 0, width: 990, height: 1000)
        XCTAssertFalse(isVisible(covered, behind: [almost]), "a 10pt strip is not somewhere to look")

        let half = CGRect(x: 0, y: 0, width: 500, height: 1000)
        XCTAssertTrue(isVisible(covered, behind: [half]))
    }

    /// Covered on both sides but not in the middle: still visible, and the pieces have to be
    /// tracked separately to see it.
    func testAGapBetweenTwoCoveringWindowsCounts() {
        let covered = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let leftHalf = CGRect(x: 0, y: 0, width: 400, height: 1000)
        let rightHalf = CGRect(x: 600, y: 0, width: 400, height: 1000)
        XCTAssertTrue(isVisible(covered, behind: [leftHalf, rightHalf]))

        let wider = CGRect(x: 380, y: 0, width: 240, height: 1000)
        XCTAssertFalse(isVisible(covered, behind: [leftHalf, rightHalf, wider]),
                       "the gap is filled, so nothing shows")
    }

    /// Covered across the middle, leaving a band above and below.
    func testABandAboveAndBelowCounts() {
        let covered = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let across = CGRect(x: -100, y: 100, width: 1200, height: 800)
        XCTAssertTrue(isVisible(covered, behind: [across]), "100pt shows at the top and bottom")
    }

    /// Two covers that overlap each other cut the window in both directions at once. Measuring
    /// whatever pieces those cuts leave behind gets this wrong: the uncovered strip down the right
    /// is 50 by 100 and plainly visible, but the cuts slice it into parts that are each too short.
    /// The answer must not depend on the order the covers arrive in either, since their union does
    /// not.
    func testOverlappingCoversDoNotSliceAVisibleRegionIntoNothing() {
        let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        let corner = CGRect(x: 0, y: 0, width: 40, height: 40)
        let across = CGRect(x: 0, y: 10, width: 50, height: 60)
        XCTAssertTrue(isVisible(frame, behind: [corner, across]))
        XCTAssertTrue(isVisible(frame, behind: [across, corner]),
                      "the same two windows, so the same answer")
    }

    /// A window smaller than the threshold is never in the ring, which is the same answer the
    /// window policy gives about windows that small.
    func testAWindowSmallerThanTheThresholdIsNeverVisible() {
        XCTAssertFalse(isVisible(CGRect(x: 0, y: 0, width: 20, height: 20), behind: []))
    }

    // MARK: - Where a step starts from

    private let ring = ["a", "b", "c", "d"]

    func testWithNoStepRememberedTheSystemAnswers() {
        XCTAssertEqual(ringStart(in: ring, live: 2, lastStep: nil), 2)
        XCTAssertNil(ringStart(in: ring, live: nil, lastStep: nil))
    }

    /// The ordinary case: the app moved key focus where it was asked to, so the system's answer has
    /// caught up and the memory of the step is spent.
    func testOnceTheSystemAgreesItAnswers() {
        XCTAssertEqual(ringStart(in: ring, live: 1, lastStep: (from: "a", to: "b")), 1)
    }

    /// The system still names the window the step moved away from. Either the app has not finished
    /// moving key focus or it never will; either way the step happened.
    func testWhileTheSystemStillNamesTheWindowLeftBehindTheStepAnswers() {
        XCTAssertEqual(ringStart(in: ring, live: 0, lastStep: (from: "a", to: "b")), 1)
    }

    /// Something else moved focus -- a click, ⌘-Tab, the pointer. That is newer news than the step.
    func testAnyOtherAnswerFromTheSystemWins() {
        XCTAssertEqual(ringStart(in: ring, live: 3, lastStep: (from: "a", to: "b")), 3)
    }

    /// Focus was on nothing the ring knows when the step was made, and still is.
    func testAStepMadeFromOutsideTheRingIsStillRemembered() {
        XCTAssertEqual(ringStart(in: ring, live: nil, lastStep: (from: nil, to: "c")), 2)
        XCTAssertNil(ringStart(in: ring, live: nil, lastStep: (from: "a", to: "c")),
                     "focus left the ring after the step, so the step is stale")
    }

    /// The window stepped to has closed, or the Space changed and the ring is a different one.
    func testAStepToAWindowNoLongerInTheRingIsIgnored() {
        XCTAssertEqual(ringStart(in: ring, live: 0, lastStep: (from: "a", to: "gone")), 0)
    }

    /// The failure this exists for: an app that raises a window without ever giving it key focus.
    /// The system's answer never changes, and without the memory every press would step from the
    /// same place and land on the same window for good.
    func testHoldingTheKeyDownAdvancesEvenIfTheAppNeverMovesKeyFocus() {
        var lastStep: (from: String?, to: String)?
        var visited: [String] = []
        for _ in 0..<5 {
            // The system keeps insisting focus is on "a", press after press.
            let from = ringStart(in: ring, live: 0, lastStep: lastStep)
            let index = ringStep(count: ring.count, from: from, by: 1)!
            visited.append(ring[index])
            lastStep = (from: "a", to: ring[index])
        }
        XCTAssertEqual(visited, ["b", "c", "d", "a", "b"])
    }
}
