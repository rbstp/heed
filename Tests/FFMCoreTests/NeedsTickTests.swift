import XCTest
@testable import FFMCore

/// Every case where `needsTick` wrongly reports false is a case where focus quietly stops following
/// the pointer until something else happens.
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

    func testQuietWhenNothingHasHappened() {
        XCTAssertFalse(machine().needsTick)
    }

    func testBusyWhileADwellIsRunning() {
        var m = machine(dwell: 0.2)
        _ = tick(&m, moved: true, now: 100)
        XCTAssertTrue(m.needsTick, "a dwell is in progress; slowing down would stretch it")

        XCTAssertEqual(tick(&m, now: 100.3), "A")
        XCTAssertFalse(m.needsTick)
    }

    /// Going quiet with an armed hit test outstanding would defer it to the next heartbeat.
    func testBusyAfterSuppressionArmsAHitTest() {
        var m = machine()
        _ = tick(&m, .suppressing)
        XCTAssertTrue(m.needsTick)

        _ = tick(&m, now: 100.1)
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

    func testQuietOverEmptySpace() {
        var m = machine()
        m.invalidate()
        _ = tick(&m, under: nil)
        XCTAssertFalse(m.needsTick)
    }

    func testQuietAfterAnInstantDwellFires() {
        var m = machine(dwell: 0)
        XCTAssertEqual(tick(&m, moved: true), "A")
        XCTAssertFalse(m.needsTick)
    }
}
