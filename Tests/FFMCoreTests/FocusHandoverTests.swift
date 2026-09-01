import XCTest
@testable import FFMCore

/// Pid 100 owns the window under the pointer ("A"); pid 200 is the app that gets handed focus.
/// The settle is 0.3s unless a test cares otherwise.
final class FocusHandoverTests: XCTestCase {
    private func fresh(settle: Double = 0.3) -> FocusHandover<String> {
        FocusHandover<String>(settle: settle)
    }

    /// A handover: focus was on the window under the pointer, then was not, and the pointer never
    /// moved. Returns a watch already in that state.
    private func handedOver(settle: Double = 0.3) -> FocusHandover<String> {
        var handover = fresh(settle: settle)
        handover.sample(window: "A", hasFocus: true, owner: 100, pointerMoved: false)
        let handed = handover.sample(window: "A", hasFocus: false, owner: 200, pointerMoved: false)
        XCTAssertTrue(handed)
        return handover
    }

    private func decide(
        _ handover: inout FocusHandover<String>, _ target: String, frontmost: Int32 = 200,
        pointerMoved: Bool = true, travelling: Bool = true, at now: Double
    ) -> HandoverDecision {
        handover.decide(for: target, frontmost: frontmost,
                        pointerMoved: pointerMoved, travelling: travelling, at: now)
    }

    // MARK: - Noticing a handover

    func testAFirstLookIsNotAHandover() {
        var handover = fresh()
        XCTAssertFalse(handover.sample(window: "A", hasFocus: false, owner: 200, pointerMoved: false))
        XCTAssertFalse(handover.isHolding)
    }

    func testFocusLeavingTheWindowUnderTheStillPointerIsAHandover() {
        var handover = handedOver()
        XCTAssertTrue(handover.isHolding)
        XCTAssertEqual(decide(&handover, "A", at: 0), .hold)
    }

    /// The one that would have broken focusing altogether: focus never arriving on the window the
    /// agent is trying to focus looks identical to focus leaving it, unless the previous answer is
    /// remembered against the window it was asked about. Read as a handover, it would hold focus
    /// away from the very window being focused and stop the retry.
    func testFocusNeverHavingArrivedIsNotAHandover() {
        var handover = fresh()
        handover.sample(window: "C", hasFocus: false, owner: 200, pointerMoved: false)
        XCTAssertFalse(handover.sample(window: "C", hasFocus: false, owner: 200, pointerMoved: false))
        XCTAssertFalse(handover.isHolding, "a failed focus attempt must stay retryable")
    }

    /// A Space switch shows a different window under a pointer that never moved. That is the world
    /// changing rather than the pointer, and it earns a hold on the new window just the same.
    func testADifferentWindowArrivingUnderAStillPointerIsAHandover() {
        var handover = fresh()
        handover.sample(window: "A", hasFocus: true, owner: 100, pointerMoved: false)
        XCTAssertTrue(handover.sample(window: "N", hasFocus: false, owner: 200, pointerMoved: false))
        XCTAssertEqual(decide(&handover, "N", at: 0), .hold)
    }

    /// Switching away twice over: the answer was already "no" the second time, so a bare yes/no
    /// would have missed it and let the parked pointer take focus back from the second app.
    func testASecondHandoverWhileAlreadyHoldingIsNoticed() {
        var handover = handedOver()
        XCTAssertTrue(handover.sample(window: "A", hasFocus: false, owner: 300, pointerMoved: false),
                      "focus moved on from one holder to another without the pointer")
        XCTAssertEqual(decide(&handover, "A", frontmost: 300, at: 0), .hold)
    }

    func testFocusOnTheWindowUnderThePointerIsNotAHandover() {
        var handover = fresh()
        handover.sample(window: "A", hasFocus: true, owner: 100, pointerMoved: false)
        XCTAssertFalse(handover.sample(window: "A", hasFocus: true, owner: 100, pointerMoved: false))
        XCTAssertFalse(handover.isHolding)
    }

    /// A moving pointer explains focus and the pointer parting company all by itself, and the caller
    /// does not even pay for the answer -- so this must both refuse to arm and re-baseline.
    func testAMovingPointerNeverArmsAndRebaselines() {
        var handover = fresh()
        handover.sample(window: "A", hasFocus: true, owner: 100, pointerMoved: false)
        XCTAssertFalse(handover.sample(window: "A", hasFocus: nil, owner: 200, pointerMoved: true))
        XCTAssertFalse(handover.sample(window: "A", hasFocus: false, owner: 200, pointerMoved: false),
                       "the sample after movement is a baseline, not a handover")
        XCTAssertFalse(handover.isHolding)
    }

    func testAnUnaskedOrUnanswerableSampleRebaselines() {
        var handover = fresh()
        handover.sample(window: "A", hasFocus: true, owner: 100, pointerMoved: false)
        handover.sample(window: nil, hasFocus: nil, owner: 200, pointerMoved: false)
        XCTAssertFalse(handover.sample(window: "A", hasFocus: false, owner: 200, pointerMoved: false))
    }

    // MARK: - Overruling a hold

    /// Only the app that was handed focus can be holding it.
    func testOnlyTheAppThatWasHandedFocusHolds() {
        var handover = handedOver()
        XCTAssertEqual(decide(&handover, "A", frontmost: 300, at: 0), .free)
    }

    /// Movement within the held-against window says nothing: you can nudge the mouse while typing
    /// into what just opened.
    func testMovementWithinTheAnchorWindowNeverEndsTheHold() {
        var handover = handedOver()
        for step in 0..<20 {
            XCTAssertEqual(decide(&handover, "A", at: Double(step)), .hold)
        }
    }

    /// Reaching a window on another display means crossing whatever lies between; one maximised
    /// window takes longer to cross than any settle worth having.
    func testCrossingOneLargeWindowForAgesDoesNotEndTheHold() {
        var handover = handedOver()
        for step in 0...40 {
            XCTAssertEqual(decide(&handover, "B", at: Double(step) * 0.05), .hold)
        }
        XCTAssertTrue(handover.isHolding)
    }

    func testSettlingOnAnotherWindowEndsTheHold() {
        var handover = handedOver()
        XCTAssertEqual(decide(&handover, "B", at: 0.0), .hold, "arrived, still moving")
        XCTAssertEqual(decide(&handover, "B", pointerMoved: false, travelling: false, at: 0.1), .hold)
        XCTAssertEqual(decide(&handover, "B", pointerMoved: false, travelling: false, at: 0.4), .entered)
        XCTAssertFalse(handover.isHolding)
        XCTAssertEqual(decide(&handover, "A", at: 0.5), .free,
                       "the hold is spent, not paused: coming back must not revive it")
    }

    func testTheSettleRestartsOnEachNewWindow() {
        var handover = handedOver()
        XCTAssertEqual(decide(&handover, "B", at: 0.0), .hold)
        XCTAssertEqual(decide(&handover, "B", pointerMoved: false, travelling: false, at: 0.1), .hold)
        XCTAssertEqual(decide(&handover, "C", at: 0.25), .hold, "moved on to another window")
        XCTAssertEqual(decide(&handover, "C", pointerMoved: false, travelling: false, at: 0.3), .hold)
        XCTAssertEqual(decide(&handover, "C", pointerMoved: false, travelling: false, at: 0.55), .hold)
        XCTAssertEqual(decide(&handover, "C", pointerMoved: false, travelling: false, at: 0.61), .entered)
    }

    /// A pause on the way -- the hand hesitating -- is not arriving either, if it is shorter than
    /// the settle.
    func testAPauseShorterThanTheSettleDoesNotEndTheHold() {
        var handover = handedOver()
        XCTAssertEqual(decide(&handover, "B", at: 0.0), .hold)
        XCTAssertEqual(decide(&handover, "B", pointerMoved: false, travelling: false, at: 0.1), .hold)
        XCTAssertEqual(decide(&handover, "B", pointerMoved: false, travelling: false, at: 0.25), .hold)
        XCTAssertEqual(decide(&handover, "B", at: 0.3), .hold, "moving again: the clock is thrown away")
        XCTAssertEqual(decide(&handover, "B", pointerMoved: false, travelling: false, at: 0.5), .hold)
        XCTAssertEqual(decide(&handover, "B", pointerMoved: false, travelling: false, at: 0.81), .entered)
    }

    /// Recent motion still reads as movement for a fifth of a second after the pointer stops, which
    /// is long enough for a pop-up to appear underneath and be mistaken for a window walked to. Only
    /// the pointer moving on the very sample the window first resolves counts as arriving.
    func testAWindowAppearingUnderAStillPointerIsNeverAnEntry() {
        var handover = handedOver()
        XCTAssertEqual(decide(&handover, "P", pointerMoved: false, travelling: true, at: 0.0), .hold)
        XCTAssertEqual(decide(&handover, "P", pointerMoved: false, travelling: false, at: 5.0), .hold)
        XCTAssertTrue(handover.isHolding)
        XCTAssertFalse(handover.isSettling, "and it must not keep the caller polling for it")
    }

    /// Time banked while one app held focus is not credit against the next one. Without this,
    /// resting on B while P held focus and then switching to Q let Q's brand-new hold be overruled
    /// on the spot, undoing the switch.
    func testSettleCreditDoesNotCarryToAnotherHolder() {
        var handover = handedOver()
        XCTAssertEqual(decide(&handover, "B", at: 0.0), .hold)
        XCTAssertEqual(decide(&handover, "B", pointerMoved: false, travelling: false, at: 0.1), .hold)
        // Q is handed focus while the pointer rests on B.
        handover.sample(window: "B", hasFocus: true, owner: 300, pointerMoved: false)
        XCTAssertTrue(handover.sample(window: "B", hasFocus: false, owner: 300, pointerMoved: false))
        XCTAssertEqual(decide(&handover, "B", frontmost: 300, pointerMoved: false,
                              travelling: false, at: 0.2), .hold,
                       "B is where Q was handed focus: the pointer has asked for nothing")
    }

    func testIsSettlingCoversTheWholeContestIncludingTheStop() {
        var handover = handedOver()
        XCTAssertFalse(handover.isSettling)
        XCTAssertEqual(decide(&handover, "B", at: 0.0), .hold)
        XCTAssertTrue(handover.isSettling, "still travelling, but the caller must keep asking")
        // The clock starts at the first sample that finds the pointer at rest, not at some earlier
        // moment it could not have known about.
        XCTAssertEqual(decide(&handover, "B", pointerMoved: false, travelling: false, at: 0.1), .hold)
        XCTAssertTrue(handover.isSettling)
        XCTAssertEqual(decide(&handover, "B", pointerMoved: false, travelling: false, at: 0.4), .entered)
        XCTAssertFalse(handover.isSettling, "the loop must not be kept awake once it is spent")
    }

    func testASettleOfZeroEndsTheHoldAsSoonAsThePointerStops() {
        var handover = handedOver(settle: 0)
        XCTAssertEqual(decide(&handover, "B", at: 0.0), .hold, "moving, so not yet")
        XCTAssertEqual(decide(&handover, "B", pointerMoved: false, travelling: false, at: 0.0), .entered)
    }

    // MARK: - Giving up

    /// The window closing, or the pointer reaching the desktop, ends the contest but not the hold.
    /// Left standing, the contest would have the caller forcing hit tests for a settle that can
    /// never complete -- a loop that never idles again.
    func testAbandoningAContestKeepsTheHold() {
        var handover = handedOver()
        XCTAssertEqual(decide(&handover, "B", at: 0.0), .hold)
        XCTAssertTrue(handover.isSettling)
        handover.abandonContest()
        XCTAssertFalse(handover.isSettling)
        XCTAssertTrue(handover.isHolding)
        XCTAssertEqual(decide(&handover, "A", at: 0.1), .hold)
    }

    /// Pids are recycled, so a hold outliving its process would be applied to a stranger.
    func testForgettingAProcessDropsItsHoldAndItsContest() {
        var handover = handedOver()
        XCTAssertEqual(decide(&handover, "B", at: 0.0), .hold)
        handover.forget(owner: 200)
        XCTAssertFalse(handover.isHolding)
        XCTAssertFalse(handover.isSettling)
        XCTAssertEqual(decide(&handover, "A", at: 0.1), .free)
    }

    func testResetForgetsEverything() {
        var handover = handedOver()
        handover.reset()
        XCTAssertFalse(handover.isHolding)
        XCTAssertFalse(handover.isSettling)
        XCTAssertFalse(handover.sample(window: "A", hasFocus: false, owner: 200, pointerMoved: false),
                       "the first sample after a reset is a baseline")
    }
}
