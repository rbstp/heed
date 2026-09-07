import XCTest
@testable import HeedCore

private final class Harness {
    var machine: DwellMachine<String>
    var now: Double = 100  // non-zero, so a bug reading 0 as "long ago" shows up
    var underCursor: String?
    var focused: String?
    var hitTestCalls = 0
    var focusCheckCalls = 0
    var confirmCalls = 0
    /// Nil makes `confirm` refuse; otherwise it stands in for the element a re-read would return.
    var confirmsAs: ((String) -> String?)?

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
            },
            confirm: { candidate in
                self.confirmCalls += 1
                guard let confirmsAs = self.confirmsAs else { return candidate }
                return confirmsAs(candidate)
            }
        )
    }

    func advance(_ seconds: Double) { now += seconds }
}

final class DwellMachineTests: XCTestCase {

    // MARK: - Confirmation

    /// The expensive re-read is what this saves: a candidate the same call hit-tested is already
    /// what confirm would find.
    func testAFreshlyHitTestedCandidateIsNotConfirmedAgain() {
        let harness = Harness(dwell: 0)
        harness.underCursor = "A"
        XCTAssertEqual(harness.tick(moved: true), "A")
        XCTAssertEqual(harness.confirmCalls, 0)
    }

    /// A candidate that matured across ticks can have gone stale, so it is re-read.
    func testACandidateThatMaturedAcrossTicksIsConfirmed() {
        let harness = Harness(dwell: 0.2)
        harness.underCursor = "A"
        harness.tick(moved: true)
        harness.advance(0.3)
        XCTAssertEqual(harness.tick(moved: false), "A")
        XCTAssertEqual(harness.confirmCalls, 1)
    }

    func testConfirmIsNotCalledWhenNoCandidateFires() {
        let harness = Harness(dwell: 0.2)
        harness.underCursor = "A"
        for _ in 0..<10 { harness.tick(moved: false) }
        XCTAssertEqual(harness.confirmCalls, 0)
    }

    /// An already-focused target must not cost a re-read either.
    func testConfirmIsNotCalledWhenTheTargetIsAlreadyFocused() {
        let harness = Harness(dwell: 0.2)
        harness.underCursor = "A"
        harness.focused = "A"
        harness.tick(moved: true)
        harness.advance(0.3)
        XCTAssertNil(harness.tick(moved: false))
        XCTAssertEqual(harness.confirmCalls, 0)
    }

    func testARefusedConfirmationYieldsNothing() {
        let harness = Harness(dwell: 0.2)
        harness.underCursor = "A"
        harness.confirmsAs = { _ in nil }
        harness.tick(moved: true)
        harness.advance(0.3)
        XCTAssertNil(harness.tick(moved: false))
        XCTAssertEqual(harness.confirmCalls, 1)
    }

    func testARefusedConfirmationLeavesTheLoopBusy() {
        let harness = Harness(dwell: 0.2)
        harness.underCursor = "A"
        harness.confirmsAs = { _ in nil }
        harness.tick(moved: true)
        harness.advance(0.3)
        harness.tick(moved: false)
        XCTAssertTrue(harness.machine.needsTick)
    }

    /// The forced test the internal invalidation arms, so a refusal is retried without the cursor
    /// having to move again.
    func testARefusedConfirmationForcesTheNextHitTest() {
        let harness = Harness(dwell: 0.2)
        harness.underCursor = "A"
        harness.confirmsAs = { _ in nil }
        harness.tick(moved: true)
        harness.advance(0.3)
        harness.tick(moved: false)
        let before = harness.hitTestCalls
        harness.tick(moved: false)
        XCTAssertEqual(harness.hitTestCalls, before + 1)
    }

    /// One window can report a different element after a dwell, so the machine hands back what the
    /// re-read found rather than the candidate it was holding.
    func testTheConfirmedElementIsWhatIsReturned() {
        let harness = Harness(dwell: 0.2)
        harness.underCursor = "A"
        harness.confirmsAs = { _ in "A-refreshed" }
        harness.tick(moved: true)
        harness.advance(0.3)
        XCTAssertEqual(harness.tick(moved: false), "A-refreshed")
    }

    func testConfirmFiresOncePerEmissionNotPerTick() {
        let harness = Harness(dwell: 0.2)
        harness.underCursor = "A"
        harness.tick(moved: true)
        harness.advance(0.05)
        harness.tick(moved: false)
        harness.advance(0.05)
        harness.tick(moved: false)
        harness.advance(0.2)
        XCTAssertEqual(harness.tick(moved: false), "A")
        XCTAssertEqual(harness.confirmCalls, 1)
    }

    // MARK: - Expiry

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

    func testMovementWithinSameTargetDoesNotRestartDwell() {
        let h = Harness(dwell: 0.2)
        h.underCursor = "A"
        h.tick(moved: true)
        let start = h.now

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

        h.underCursor = nil
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

        h.tick(.suppressing)

        h.advance(0.5)
        XCTAssertNil(h.tick(), "dwell cancelled by a suppressing condition must not later fire")
    }

    func testSuppressingDoesNotHitTest() {
        let h = Harness()
        h.underCursor = "A"
        h.tick(.suppressing, moved: true)
        XCTAssertEqual(h.hitTestCalls, 0)
    }

    /// Typing over a window and then stopping must leave it acquirable without further movement.
    func testTargetIsReacquiredAfterSuppressionEnds() {
        let h = Harness(dwell: 0.2)
        h.underCursor = "A"
        h.tick(moved: true)
        h.tick(.suppressing)

        let before = h.hitTestCalls
        h.tick(moved: false)
        XCTAssertEqual(h.hitTestCalls, before + 1, "suppression ending must re-test, unprompted")

        h.advance(0.25)
        XCTAssertEqual(h.tick(moved: false), "A",
                       "a window under a still pointer must be focusable once suppression lifts")
    }

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

    /// A design that remembered "I already focused A" would refuse here and leave A dead.
    func testRefocusesAfterFocusMovedAwayByOtherMeans() {
        let h = Harness(dwell: 0.2)
        h.underCursor = "A"
        h.tick(moved: true)
        h.advance(0.25)
        XCTAssertEqual(h.tick(), "A")
        h.focused = "A"

        h.focused = "B"   // keyboard switch; the pointer never left A

        h.tick(moved: true)
        h.advance(0.25)
        XCTAssertEqual(h.tick(), "A", "pointer still over A, so A must regain focus")
    }
}
