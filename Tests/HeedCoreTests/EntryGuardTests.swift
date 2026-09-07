import XCTest
@testable import HeedCore

final class EntryGuardTests: XCTestCase {
    private let threshold = 6.0

    private func guarded() -> EntryGuard<String> { EntryGuard<String>() }

    func testTheFirstWindowSeenIsOnlyABaseline() {
        var entry = guarded()
        XCTAssertEqual(entry.admit("a", travelled: 0, threshold: threshold), .baseline)
    }

    func testTravelAdmitsWithoutABaseline() {
        var entry = guarded()
        XCTAssertEqual(entry.admit("a", travelled: 10, threshold: threshold), .admitted)
    }

    func testTravelExactlyAtTheThresholdAdmits() {
        var entry = guarded()
        XCTAssertEqual(entry.admit("a", travelled: threshold, threshold: threshold), .admitted)
    }

    /// The window the pointer already rests on stays acquirable however still the pointer is.
    func testTheBaselineWindowIsAdmittedWithoutTravel() {
        var entry = guarded()
        _ = entry.admit("a", travelled: 0, threshold: threshold)
        XCTAssertEqual(entry.admit("a", travelled: 0, threshold: threshold), .admitted)
    }

    func testAWindowArrivingUnderAStillPointerIsBlocked() {
        var entry = guarded()
        _ = entry.admit("a", travelled: 0, threshold: threshold)
        XCTAssertEqual(entry.admit("b", travelled: 0, threshold: threshold), .blocked)
    }

    func testStillBlockedJustBelowTheThreshold() {
        var entry = guarded()
        _ = entry.admit("a", travelled: 0, threshold: threshold)
        XCTAssertEqual(entry.admit("b", travelled: threshold - 0.01, threshold: threshold), .blocked)
    }

    /// The rule that stops the next tick accepting what this one refused.
    func testARefusalLeavesTheBaselineStanding() {
        var entry = guarded()
        _ = entry.admit("a", travelled: 0, threshold: threshold)
        XCTAssertEqual(entry.admit("b", travelled: 0, threshold: threshold), .blocked)
        XCTAssertEqual(entry.admit("b", travelled: 0, threshold: threshold), .blocked,
                       "the refused window must not have become the baseline")
        XCTAssertEqual(entry.admit("a", travelled: 0, threshold: threshold), .admitted)
    }

    func testAnAdmittedWindowBecomesTheBaseline() {
        var entry = guarded()
        _ = entry.admit("a", travelled: 10, threshold: threshold)
        XCTAssertEqual(entry.admit("b", travelled: 0, threshold: threshold), .blocked)
        XCTAssertEqual(entry.admit("a", travelled: 0, threshold: threshold), .admitted)
    }

    func testResetForgetsTheBaseline() {
        var entry = guarded()
        _ = entry.admit("a", travelled: 10, threshold: threshold)
        entry.reset()
        XCTAssertEqual(entry.admit("b", travelled: 0, threshold: threshold), .baseline)
    }

    func testAdoptTakesABaselineWithoutJudging() {
        var entry = guarded()
        entry.adopt("a")
        XCTAssertEqual(entry.admit("b", travelled: 0, threshold: threshold), .blocked)
        XCTAssertEqual(entry.admit("a", travelled: 0, threshold: threshold), .admitted)
    }

    func testAThresholdOfZeroDisablesTheGuard() {
        var entry = guarded()
        XCTAssertEqual(entry.admit("a", travelled: 0, threshold: 0), .admitted)
        XCTAssertEqual(entry.admit("b", travelled: 0, threshold: 0), .admitted)
    }

    func testAThresholdOfZeroNeverBlocks() {
        var entry = guarded()
        for name in ["a", "b", "c", "a"] {
            XCTAssertEqual(entry.admit(name, travelled: 0, threshold: 0), .admitted)
        }
    }

    /// `Target ==` compares frame and title when the elements differ, so equality is not an
    /// equivalence relation: a window that merely resized can stop matching its own baseline.
    private struct Drifting: Equatable {
        let position: Int

        static func == (lhs: Drifting, rhs: Drifting) -> Bool {
            abs(lhs.position - rhs.position) <= 1
        }
    }

    func testANearlyEqualWindowStillCountsAsTheBaseline() {
        var entry = EntryGuard<Drifting>()
        _ = entry.admit(Drifting(position: 10), travelled: 0, threshold: threshold)
        XCTAssertEqual(entry.admit(Drifting(position: 11), travelled: 0, threshold: threshold),
                       .admitted)
    }

    func testTheBaselineFollowsTheDriftItAdmits() {
        var entry = EntryGuard<Drifting>()
        _ = entry.admit(Drifting(position: 10), travelled: 0, threshold: threshold)
        _ = entry.admit(Drifting(position: 11), travelled: 0, threshold: threshold)
        XCTAssertEqual(entry.admit(Drifting(position: 12), travelled: 0, threshold: threshold),
                       .admitted, "the admitted window became the baseline, so 12 is within 1 of it")
    }

    func testDriftBeyondToleranceIsBlocked() {
        var entry = EntryGuard<Drifting>()
        _ = entry.admit(Drifting(position: 10), travelled: 0, threshold: threshold)
        XCTAssertEqual(entry.admit(Drifting(position: 20), travelled: 0, threshold: threshold),
                       .blocked)
    }
}
