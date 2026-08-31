import XCTest
@testable import FFMCore

/// `needsTick` is what lets the agent stop polling, so every case where it wrongly reports false is
/// a case where focus quietly stops following the pointer until something else happens.
final class NeedsTickTests: XCTestCase {
    private func machine(dwell: Double = 0.2) -> DwellMachine<String> {
        DwellMachine<String>(dwell: dwell)
    }

    private func tick(
        _ machine: inout DwellMachine<String>,
        _ condition: TickCondition = .normal,
        moved: Bool = false,
        now: Double = 100,
        under target: String? = "A"
    ) -> String? {
        machine.tick(now: now, condition: condition, cursorMoved: moved,
                     hitTest: { target }, isAlreadyFocused: { _ in false })
    }

    /// A fresh machine has never been told anything, so there is nothing to wait for.
    func testQuietWhenNothingHasHappened() {
        var m = machine()
        XCTAssertFalse(m.needsTick)
    }

    func testBusyWhileADwellIsRunning() {
        var m = machine(dwell: 0.2)
        _ = tick(&m, moved: true, now: 100)
        XCTAssertTrue(m.needsTick, "a dwell is in progress; slowing down would stretch it")

        // Dwell expires and is spent, so there is nothing left pending.
        XCTAssertEqual(tick(&m, now: 100.3), "A")
        XCTAssertFalse(m.needsTick)
    }

    /// The case that matters most. Suppression arms a hit test, and that test is what acquires the
    /// window the pointer is already resting on once typing stops. Going quiet with it outstanding
    /// would defer it to the next heartbeat.
    func testBusyAfterSuppressionArmsAHitTest() {
        var m = machine()
        _ = tick(&m, .suppressing)
        XCTAssertTrue(m.needsTick)

        _ = tick(&m, now: 100.1)   // the armed test runs here
        XCTAssertTrue(m.needsTick, "instant dwell aside, a candidate is now pending")
    }

    func testBusyAfterInvalidation() {
        var m = machine()
        XCTAssertFalse(m.needsTick)
        m.invalidate()
        XCTAssertTrue(m.needsTick)
    }

    func testBusyAfterAnInvalidatingTick() {
        var m = machine()
        _ = tick(&m, .invalidating)
        XCTAssertTrue(m.needsTick)
    }

    /// Nothing under the pointer (the desktop) clears the candidate, and with the forced test spent
    /// there is nothing to keep ticking for.
    func testQuietOverEmptySpace() {
        var m = machine()
        m.invalidate()
        _ = tick(&m, under: nil)
        XCTAssertFalse(m.needsTick)
    }

    /// Instant dwell is the default, so this is the ordinary path: a moved pointer resolves and
    /// fires in the same tick, leaving nothing pending.
    func testQuietAfterAnInstantDwellFires() {
        var m = machine(dwell: 0)
        XCTAssertEqual(tick(&m, moved: true), "A")
        XCTAssertFalse(m.needsTick)
    }
}
