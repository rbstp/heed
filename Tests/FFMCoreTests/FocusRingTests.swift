import CoreGraphics
import XCTest
@testable import FFMCore

final class FocusRingTests: XCTestCase {
    // Two 1920x1080 displays side by side, top-left origin.
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

    func testWalksEachScreenLeftToRight() {
        let ordered = ringOrder(
            [window(1, x: 0), window(2, x: 960),
             window(3, x: 1920), window(4, x: 2880)],
            screens: [left, right]
        )
        XCTAssertEqual(keys(ordered), [1, 2, 3, 4])
    }

    /// The caller hands windows over in stacking order, which changes every time focus moves.
    func testTheOrderWindowsArriveInDoesNotMatter() {
        let windows = [window(3, x: 1920), window(1, x: 0),
                       window(4, x: 2880), window(2, x: 960)]
        XCTAssertEqual(keys(ringOrder(windows, screens: [left, right])), [1, 2, 3, 4])
    }

    func testTheOrderScreensArriveInDoesNotMatter() {
        let windows = [window(1, x: 0), window(3, x: 1920)]
        XCTAssertEqual(keys(ringOrder(windows, screens: [right, left])), [1, 3])
    }

    /// A display left of the primary has a negative origin.
    func testAScreenLeftOfThePrimaryOneComesFirst() {
        let further = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let ordered = ringOrder(
            [window(2, x: 0), window(1, x: -1920)],
            screens: [left, further]
        )
        XCTAssertEqual(keys(ordered), [1, 2])
    }

    func testWindowsInAColumnRunTopToBottom() {
        let ordered = ringOrder(
            [window(2, x: 0, y: 540, height: 540),
             window(1, x: 0, y: 0, height: 540)],
            screens: [left]
        )
        XCTAssertEqual(keys(ordered), [1, 2])
    }

    func testHorizontalPositionWinsOverVertical() {
        let ordered = ringOrder(
            [window(2, x: 960, y: 0, height: 540),
             window(1, x: 0, y: 540, height: 540)],
            screens: [left]
        )
        XCTAssertEqual(keys(ordered), [1, 2])
    }

    /// Without the key to break the tie, one of two maximised windows could never be reached.
    func testWindowsSharingAFrameKeepAFixedOrder() {
        let a = RingWindow(frame: left, key: 81)
        let b = RingWindow(frame: left, key: 12337)
        XCTAssertEqual(keys(ringOrder([a, b], screens: [left])), [81, 12337])
        XCTAssertEqual(keys(ringOrder([b, a], screens: [left])), [81, 12337],
                       "the older window first, whichever order they were collected in")
    }

    // MARK: - Which screen a window is on

    func testAWindowSpanningTwoScreensBelongsToTheOneShowingMostOfIt() {
        let straddling = window(1, x: 1440, width: 1920)   // three quarters on the right screen
        let ordered = ringOrder([straddling, window(2, x: 1920)], screens: [left, right])
        XCTAssertEqual(keys(ordered), [1, 2],
                       "both are on the right screen, ordered by position within it")

        let onTheLeft = ringOrder([straddling, window(2, x: 0)], screens: [left, right])
        XCTAssertEqual(keys(onTheLeft), [2, 1], "the left screen's window comes first")
    }

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

    /// The window server calls every window in the Space "on screen", tiled over or not.
    func testTwoTiledWindowsHideWhatTheyCover() {
        let slack = CGRect(x: -1920, y: 67, width: 960, height: 1050)
        let zen = CGRect(x: -960, y: 67, width: 960, height: 1050)
        let behindBoth = CGRect(x: -1920, y: 67, width: 1920, height: 1050)
        XCTAssertFalse(isVisible(behindBoth, behind: [slack, zen]),
                       "no single window covers it, but together they cover it exactly")
        XCTAssertTrue(isVisible(behindBoth, behind: [slack]),
                      "half of it still shows")
    }

    func testAWindowUnderAnIdenticalOneIsHidden() {
        XCTAssertFalse(isVisible(left, behind: [left]))
    }

    func testAWindowWithNothingInFrontIsVisible() {
        XCTAssertTrue(isVisible(left, behind: []))
    }

    func testWindowsElsewhereOnTheDeskDoNotHideIt() {
        XCTAssertTrue(isVisible(left, behind: [right]))
    }

    /// Tiled windows meet along an edge where a point of rounding either way is arbitrary.
    func testASliverShowingDoesNotCount() {
        let covered = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let almost = CGRect(x: 0, y: 0, width: 990, height: 1000)
        XCTAssertFalse(isVisible(covered, behind: [almost]), "a 10pt strip is not somewhere to look")

        let half = CGRect(x: 0, y: 0, width: 500, height: 1000)
        XCTAssertTrue(isVisible(covered, behind: [half]))
    }

    func testAGapBetweenTwoCoveringWindowsCounts() {
        let covered = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let leftHalf = CGRect(x: 0, y: 0, width: 400, height: 1000)
        let rightHalf = CGRect(x: 600, y: 0, width: 400, height: 1000)
        XCTAssertTrue(isVisible(covered, behind: [leftHalf, rightHalf]))

        let wider = CGRect(x: 380, y: 0, width: 240, height: 1000)
        XCTAssertFalse(isVisible(covered, behind: [leftHalf, rightHalf, wider]),
                       "the gap is filled, so nothing shows")
    }

    func testABandAboveAndBelowCounts() {
        let covered = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let across = CGRect(x: -100, y: 100, width: 1200, height: 800)
        XCTAssertTrue(isVisible(covered, behind: [across]), "100pt shows at the top and bottom")
    }

    /// A small window in the middle leaves a frame around it that is plainly visible.
    func testACoverInTheMiddleLeavesTheEdgesVisible() {
        let covered = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let middle = CGRect(x: 100, y: 100, width: 800, height: 800)
        XCTAssertTrue(isVisible(covered, behind: [middle]))
        XCTAssertFalse(isVisible(covered, behind: [middle.insetBy(dx: -90, dy: -90)]),
                       "a 10pt frame is not somewhere to look")
    }

    /// Subtracting covers one at a time slices the visible 50x100 strip on the right into pieces that
    /// are each too short; the answer must not depend on the order the covers arrive in either.
    func testOverlappingCoversDoNotSliceAVisibleRegionIntoNothing() {
        let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        let corner = CGRect(x: 0, y: 0, width: 40, height: 40)
        let across = CGRect(x: 0, y: 10, width: 50, height: 60)
        XCTAssertTrue(isVisible(frame, behind: [corner, across]))
        XCTAssertTrue(isVisible(frame, behind: [across, corner]),
                      "the same two windows, so the same answer")
    }

    /// The agent passes a prefix of the stacking order without copying it.
    func testTheCoveringWindowsCanBeASliceOfTheStack() {
        let stack = [left, right, CGRect(x: 0, y: 0, width: 1920, height: 1080)]
        XCTAssertFalse(isVisible(stack[2], behind: stack[..<2]))
        XCTAssertTrue(isVisible(stack[1], behind: stack[..<1]))
    }

    func testAWindowSmallerThanTheThresholdIsNeverVisible() {
        XCTAssertFalse(isVisible(CGRect(x: 0, y: 0, width: 20, height: 20), behind: []))
    }

    // MARK: - Where a step starts from

    private let ring = ["a", "b", "c", "d"]

    func testWithNoStepRememberedTheSystemAnswers() {
        XCTAssertEqual(ringStart(in: ring, live: 2, lastStep: nil), 2)
        XCTAssertNil(ringStart(in: ring, live: nil, lastStep: nil))
    }

    func testOnceTheSystemAgreesItAnswers() {
        XCTAssertEqual(ringStart(in: ring, live: 1, lastStep: (from: "a", to: "b")), 1)
    }

    func testWhileTheSystemStillNamesTheWindowLeftBehindTheStepAnswers() {
        XCTAssertEqual(ringStart(in: ring, live: 0, lastStep: (from: "a", to: "b")), 1)
    }

    /// A click, Cmd-Tab or the pointer moved focus: newer news than the step.
    func testAnyOtherAnswerFromTheSystemWins() {
        XCTAssertEqual(ringStart(in: ring, live: 3, lastStep: (from: "a", to: "b")), 3)
    }

    func testAStepMadeFromOutsideTheRingIsStillRemembered() {
        XCTAssertEqual(ringStart(in: ring, live: nil, lastStep: (from: nil, to: "c")), 2)
        XCTAssertNil(ringStart(in: ring, live: nil, lastStep: (from: "a", to: "c")),
                     "focus left the ring after the step, so the step is stale")
    }

    func testAStepToAWindowNoLongerInTheRingIsIgnored() {
        XCTAssertEqual(ringStart(in: ring, live: 0, lastStep: (from: "a", to: "gone")), 0)
    }

    /// An app that raises a window without moving key focus: the system's answer never changes.
    func testHoldingTheKeyDownAdvancesEvenIfTheAppNeverMovesKeyFocus() {
        var lastStep: (from: String?, to: String)?
        var visited: [String] = []
        for _ in 0..<5 {
            let from = ringStart(in: ring, live: 0, lastStep: lastStep)
            let index = ringStep(count: ring.count, from: from, by: 1)!
            visited.append(ring[index])
            lastStep = (from: "a", to: ring[index])
        }
        XCTAssertEqual(visited, ["b", "c", "d", "a", "b"])
    }
}
