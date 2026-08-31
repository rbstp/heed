import XCTest
@testable import FFMCore

/// Drives DwellMachine with a scripted clock and recording closures.
private final class Harness {
    var machine: DwellMachine<String>
    var now: Double = 100  // arbitrary non-zero start, so a bug reading 0 as "long ago" shows up
    var underCursor: String?
    var focused: String?
    var hitTestCalls = 0
    var focusCheckCalls = 0

    init(dwell: Double = 0.2) {
        machine = DwellMachine(dwell: dwell)
    }

    @discardableResult
    func tick(_ condition: TickCondition = .normal, moved: Bool = false) -> String? {
        machine.tick(
            now: now,
            condition: condition,
            cursorMoved: moved,
            hitTest: {
                self.hitTestCalls += 1
                return self.underCursor
            },
            isAlreadyFocused: {
                self.focusCheckCalls += 1
                return self.focused == $0
            }
        )
    }

    func advance(_ seconds: Double) { now += seconds }
}

final class DwellMachineTests: XCTestCase {

    // MARK: - Expiry

    /// The core behaviour, and the one an earlier draft of this design got wrong by treating
    /// "cursor did not move" as a condition that cancels dwell: settling the pointer and waiting
    /// must be what actually moves focus.
    func testDwellExpiresWhileCursorIsStationary() {
        let h = Harness(dwell: 0.2)
        h.underCursor = "A"

        XCTAssertNil(h.tick(moved: true), "must not fire on the tick the target is first seen")

        h.advance(0.1)
        XCTAssertNil(h.tick(), "must not fire before dwell elapses")

        h.advance(0.15)
        XCTAssertEqual(h.tick(), "A", "must fire once dwell elapses, with no further movement")
    }

    func testStationaryCursorDoesNotHitTest() {
        let h = Harness()
        h.underCursor = "A"
        h.tick(moved: true)
        let after = h.hitTestCalls

        for _ in 0..<10 { h.tick(moved: false) }
        XCTAssertEqual(h.hitTestCalls, after, "a stationary pointer must not generate hit tests")
    }

    func testFiresOnlyOncePerDwell() {
        let h = Harness(dwell: 0.2)
        h.underCursor = "A"
        h.tick(moved: true)
        h.advance(0.25)
        XCTAssertEqual(h.tick(), "A")

        h.advance(1.0)
        XCTAssertNil(h.tick(), "must not re-fire for a target it already resolved")
    }

    func testZeroDwellFiresImmediately() {
        let h = Harness(dwell: 0)
        h.underCursor = "A"
        XCTAssertEqual(h.tick(moved: true), "A")
    }

    // MARK: - Movement within a target

    /// Pointer drift inside one window must not keep resetting the timer, or focus would never
    /// settle for anyone who does not hold the mouse perfectly still.
    func testMovementWithinSameTargetDoesNotRestartDwell() {
        let h = Harness(dwell: 0.2)
        h.underCursor = "A"
        h.tick(moved: true)
        let start = h.now

        // Keep jiggling inside A well past the dwell period. Focus must still land, and land at
        // roughly dwell time -- a machine that reset the clock on every movement would never fire.
        var firedAfter: Double?
        for _ in 0..<10 {
            h.advance(0.06)
            if let fired = h.tick(moved: true) {
                XCTAssertEqual(fired, "A")
                firedAfter = h.now - start
                break
            }
        }

        guard let elapsed = firedAfter else {
            return XCTFail("jitter inside one window starved the dwell timer; focus never fired")
        }
        XCTAssertGreaterThanOrEqual(elapsed, 0.2, "fired before dwell elapsed")
        XCTAssertLessThan(elapsed, 0.3, "fired much later than dwell; the timer was being reset")
    }

    func testNewTargetRestartsDwell() {
        let h = Harness(dwell: 0.2)
        h.underCursor = "A"
        h.tick(moved: true)
        h.advance(0.15)

        h.underCursor = "B"
        XCTAssertNil(h.tick(moved: true), "switching target restarts the clock")
        h.advance(0.15)
        XCTAssertNil(h.tick(), "B has not dwelled long enough yet")
        h.advance(0.1)
        XCTAssertEqual(h.tick(), "B")
    }

    /// Sweeping the pointer across intermediate windows to reach a destination must not focus each
    /// one on the way past.
    func testSweepingAcrossWindowsFocusesOnlyWhereItSettles() {
        let h = Harness(dwell: 0.2)
        for target in ["A", "B", "C", "D"] {
            h.underCursor = target
            h.advance(0.04)
            XCTAssertNil(h.tick(moved: true), "must not focus \(target) while sweeping past it")
        }
        h.advance(0.25)
        XCTAssertEqual(h.tick(), "D", "only the window it settles on gets focus")
    }

    func testNilHitTestClearsCandidate() {
        let h = Harness(dwell: 0.2)
        h.underCursor = "A"
        h.tick(moved: true)

        h.underCursor = nil  // e.g. moved onto the desktop
        h.tick(moved: true)
        h.advance(0.5)
        XCTAssertNil(h.tick(), "a target that vanished must not be focused")
    }

    // MARK: - Conditions

    func testSuppressingCancelsDwell() {
        let h = Harness(dwell: 0.2)
        h.underCursor = "A"
        h.tick(moved: true)
        h.advance(0.15)

        h.tick(.suppressing)  // e.g. a mouse button went down

        h.advance(0.5)
        XCTAssertNil(h.tick(), "dwell cancelled by a suppressing condition must not later fire")
    }

    func testSuppressingDoesNotHitTest() {
        let h = Harness()
        h.underCursor = "A"
        h.tick(.suppressing, moved: true)
        XCTAssertEqual(h.hitTestCalls, 0)
    }

    /// After a Space change or display reconfiguration, what sits under an unmoved pointer is
    /// different, so the next tick has to re-test rather than trust the previous result.
    func testInvalidatingForcesHitTestWithoutMovement() {
        let h = Harness(dwell: 0.2)
        h.underCursor = "A"
        h.tick(moved: true)

        h.tick(.invalidating)
        let before = h.hitTestCalls

        h.underCursor = "B"
        h.tick(moved: false)
        XCTAssertEqual(h.hitTestCalls, before + 1, "invalidation must force a fresh hit test")

        h.advance(0.25)
        XCTAssertEqual(h.tick(), "B", "and the new target is what gets focused")
    }

    func testInvalidateMethodForcesRetryAfterFailure() {
        let h = Harness(dwell: 0.2)
        h.underCursor = "A"
        h.tick(moved: true)
        h.advance(0.25)
        XCTAssertEqual(h.tick(), "A")

        // Caller failed to apply focus and re-arms; a stationary pointer must still get a retry.
        h.machine.invalidate()
        h.tick(moved: false)
        h.advance(0.25)
        XCTAssertEqual(h.tick(), "A", "invalidate() must allow a retry without pointer movement")
    }

    // MARK: - Live focus authority

    func testAlreadyFocusedTargetIsNotRefocused() {
        let h = Harness(dwell: 0.2)
        h.underCursor = "A"
        h.focused = "A"
        h.tick(moved: true)
        h.advance(0.25)
        XCTAssertNil(h.tick(), "no need to focus what is already focused")
    }

    func testFocusCheckIsOnlyConsultedAtExpiry() {
        let h = Harness(dwell: 0.2)
        h.underCursor = "A"
        h.tick(moved: true)
        h.advance(0.1)
        h.tick()
        XCTAssertEqual(h.focusCheckCalls, 0, "must not query live focus before dwell expires")

        h.advance(0.15)
        h.tick()
        XCTAssertEqual(h.focusCheckCalls, 1)
    }

    /// Regression test for the stale-cache bug that a previous design had: focus is moved by the
    /// pointer, then moved elsewhere by other means (keyboard, Cmd-Tab, an app activating itself).
    /// Nudging the pointer inside the original window must bring focus back. A design that
    /// remembered "I already focused A" would refuse here, leaving a dead window under the cursor.
    func testRefocusesAfterFocusMovedAwayByOtherMeans() {
        let h = Harness(dwell: 0.2)
        h.underCursor = "A"
        h.tick(moved: true)
        h.advance(0.25)
        XCTAssertEqual(h.tick(), "A")
        h.focused = "A"

        // User switches to B with the keyboard; pointer never left A.
        h.focused = "B"

        h.tick(moved: true)  // slight nudge inside A
        h.advance(0.25)
        XCTAssertEqual(h.tick(), "A", "pointer still over A, so A must regain focus")
    }
}
