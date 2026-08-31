import XCTest
@testable import FFMCore

final class MotionTrackerTests: XCTestCase {
    func testStartsAtZero() {
        XCTAssertEqual(MotionTracker(capacity: 5).total, 0)
    }

    func testSumsWithinTheWindow() {
        var tracker = MotionTracker(capacity: 5)
        for _ in 0..<3 { tracker.record(2) }
        XCTAssertEqual(tracker.total, 6)
    }

    /// Old movement must age out, or a single flick would keep the pointer looking "in motion"
    /// indefinitely and defeat the guard.
    func testForgetsMovementOlderThanTheWindow() {
        var tracker = MotionTracker(capacity: 3)
        tracker.record(100)
        for _ in 0..<3 { tracker.record(0) }
        XCTAssertEqual(tracker.total, 0, "a flick four ticks ago must no longer count as motion")
    }

    func testAStationaryPointerReadsAsStationary() {
        var tracker = MotionTracker(capacity: 5)
        for _ in 0..<20 { tracker.record(0) }
        XCTAssertEqual(tracker.total, 0)
    }

    /// A slow deliberate crossing moves only a pixel or two per tick, which is exactly why the
    /// window exists: over five ticks it still clears a small threshold.
    func testSlowDeliberateMovementAccumulates() {
        var tracker = MotionTracker(capacity: 5)
        for _ in 0..<5 { tracker.record(2) }
        XCTAssertGreaterThan(tracker.total, 6)
    }

    func testResetClears() {
        var tracker = MotionTracker(capacity: 5)
        tracker.record(50)
        tracker.reset()
        XCTAssertEqual(tracker.total, 0)
    }

    func testCapacityIsAtLeastOne() {
        var tracker = MotionTracker(capacity: 0)
        tracker.record(7)
        XCTAssertEqual(tracker.total, 7)
    }
}
