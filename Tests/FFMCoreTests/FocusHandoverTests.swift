import XCTest
@testable import FFMCore

/// Pid 100 owns the window under the pointer ("A"); pid 200 is the app handed focus.
final class FocusHandoverTests: XCTestCase {
    private func fresh(settle: Double = 0.3) -> FocusHandover<String> {
        FocusHandover<String>(settle: settle)
    }

    /// Focus was on the window under the pointer, then was not, and the pointer never moved.
    private func handedOver(settle: Double = 0.3) -> FocusHandover<String> {
        var handover = fresh(settle: settle)
        handover.sample(window: "A", hasFocus: true, anchor: "A", owner: 100, pointerMoved: false)
        let handed = handover.sample(window: "A", hasFocus: false, anchor: "A", owner: 200, pointerMoved: false)
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
        XCTAssertFalse(handover.sample(window: "A", hasFocus: false, anchor: "A", owner: 200, pointerMoved: false))
        XCTAssertFalse(handover.isHolding)
    }

    func testFocusLeavingTheWindowUnderTheStillPointerIsAHandover() {
        var handover = handedOver()
        XCTAssertTrue(handover.isHolding)
        XCTAssertEqual(decide(&handover, "A", at: 0), .hold)
    }

    /// Read as a handover, a failed focus attempt would hold focus away from the very window being
    /// focused and stop the retry.
    func testFocusNeverHavingArrivedIsNotAHandover() {
        var handover = fresh()
        handover.sample(window: "C", hasFocus: false, anchor: "C", owner: 200, pointerMoved: false)
        XCTAssertFalse(handover.sample(window: "C", hasFocus: false, anchor: "C", owner: 200, pointerMoved: false))
        XCTAssertFalse(handover.isHolding, "a failed focus attempt must stay retryable")
    }

    /// A Space switch shows a different window under a pointer that never moved.
    func testADifferentWindowArrivingUnderAStillPointerIsAHandover() {
        var handover = fresh()
        handover.sample(window: "A", hasFocus: true, anchor: "A", owner: 100, pointerMoved: false)
        XCTAssertTrue(handover.sample(window: "N", hasFocus: false, anchor: "N", owner: 200, pointerMoved: false))
        XCTAssertEqual(decide(&handover, "N", at: 0), .hold)
    }

    /// The answer was already "no" the second time, so a bare yes/no would miss it.
    func testASecondHandoverWhileAlreadyHoldingIsNoticed() {
        var handover = handedOver()
        XCTAssertTrue(handover.sample(window: "A", hasFocus: false, anchor: "A", owner: 300, pointerMoved: false),
                      "focus moved on from one holder to another without the pointer")
        XCTAssertEqual(decide(&handover, "A", frontmost: 300, at: 0), .hold)
    }

    func testFocusOnTheWindowUnderThePointerIsNotAHandover() {
        var handover = fresh()
        handover.sample(window: "A", hasFocus: true, anchor: "A", owner: 100, pointerMoved: false)
        XCTAssertFalse(handover.sample(window: "A", hasFocus: true, anchor: "A", owner: 100, pointerMoved: false))
        XCTAssertFalse(handover.isHolding)
    }

    func testAMovingPointerNeverArmsAndRebaselines() {
        var handover = fresh()
        handover.sample(window: "A", hasFocus: true, anchor: "A", owner: 100, pointerMoved: false)
        XCTAssertFalse(handover.sample(window: "A", hasFocus: nil, anchor: "A", owner: 200, pointerMoved: true))
        XCTAssertFalse(handover.sample(window: "A", hasFocus: false, anchor: "A", owner: 200, pointerMoved: false),
                       "the sample after movement is a baseline, not a handover")
        XCTAssertFalse(handover.isHolding)
    }

    func testASampleWithNoOwnerRebaselines() {
        var handover = fresh()
        handover.sample(window: "A", hasFocus: true, anchor: "A", owner: 100, pointerMoved: false)
        handover.sample(window: "A", hasFocus: false, anchor: "A", owner: nil, pointerMoved: false)
        XCTAssertFalse(handover.isHolding)
        XCTAssertFalse(handover.sample(window: "A", hasFocus: false, anchor: "A",
                                       owner: 200, pointerMoved: false),
                       "the sample after one that could not be attributed is a baseline")
    }

    /// Launching from the Dock: the pointer is over nothing this agent would focus.
    func testAHandoverWithThePointerOverNothingStillHolds() {
        var handover = fresh()
        handover.sample(window: nil, hasFocus: nil, anchor: nil, owner: 100, pointerMoved: false)
        XCTAssertTrue(handover.sample(window: nil, hasFocus: nil, anchor: nil,
                                      owner: 200, pointerMoved: false),
                      "focus moved to another app while the pointer sat over nothing")
        XCTAssertTrue(handover.isHolding)
    }

    func testAnUnanchoredHoldSurvivesCrossingAndEndsOnSettling() {
        var handover = fresh()
        handover.sample(window: nil, hasFocus: nil, anchor: nil, owner: 100, pointerMoved: false)
        handover.sample(window: nil, hasFocus: nil, anchor: nil, owner: 200, pointerMoved: false)

        for step in 0...20 {
            XCTAssertEqual(decide(&handover, step.isMultiple(of: 2) ? "B" : "C",
                                  at: Double(step) * 0.06), .hold, "crossing on the way")
        }
        XCTAssertEqual(decide(&handover, "B", at: 1.3), .hold)
        XCTAssertEqual(decide(&handover, "B", pointerMoved: false, travelling: false, at: 1.4), .hold)
        XCTAssertEqual(decide(&handover, "B", pointerMoved: false, travelling: false, at: 1.8), .entered)
    }

    func testAnUnanchoredHoldIsNotEndedByAWindowArrivingUnderAStillPointer() {
        var handover = fresh()
        handover.sample(window: nil, hasFocus: nil, anchor: nil, owner: 100, pointerMoved: false)
        handover.sample(window: nil, hasFocus: nil, anchor: nil, owner: 200, pointerMoved: false)
        XCTAssertEqual(decide(&handover, "P", pointerMoved: false, travelling: false, at: 0), .hold)
        XCTAssertTrue(handover.isHolding)
    }

    func testTheSameNothingUnderThePointerIsNotAHandover() {
        var handover = fresh()
        handover.sample(window: nil, hasFocus: nil, anchor: nil, owner: 200, pointerMoved: false)
        XCTAssertFalse(handover.sample(window: nil, hasFocus: nil, anchor: nil,
                                       owner: 200, pointerMoved: false))
        XCTAssertFalse(handover.isHolding)
    }

    // MARK: - Overruling a hold

    func testOnlyTheAppThatWasHandedFocusHolds() {
        var handover = handedOver()
        XCTAssertEqual(decide(&handover, "A", frontmost: 300, at: 0), .free)
    }

    func testMovementWithinTheAnchorWindowNeverEndsTheHold() {
        var handover = handedOver()
        for step in 0..<20 {
            XCTAssertEqual(decide(&handover, "A", at: Double(step)), .hold)
        }
    }

    /// One maximised window takes longer to cross than any settle worth having.
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

    func testAPauseShorterThanTheSettleDoesNotEndTheHold() {
        var handover = handedOver()
        XCTAssertEqual(decide(&handover, "B", at: 0.0), .hold)
        XCTAssertEqual(decide(&handover, "B", pointerMoved: false, travelling: false, at: 0.1), .hold)
        XCTAssertEqual(decide(&handover, "B", pointerMoved: false, travelling: false, at: 0.25), .hold)
        XCTAssertEqual(decide(&handover, "B", at: 0.3), .hold, "moving again: the clock is thrown away")
        XCTAssertEqual(decide(&handover, "B", pointerMoved: false, travelling: false, at: 0.5), .hold)
        XCTAssertEqual(decide(&handover, "B", pointerMoved: false, travelling: false, at: 0.81), .entered)
    }

    /// Recent motion still reads as movement for a moment after the pointer stops, long enough for
    /// a pop-up to appear underneath; only movement on the sample the window first resolves counts.
    func testAWindowAppearingUnderAStillPointerIsNeverAnEntry() {
        var handover = handedOver()
        XCTAssertEqual(decide(&handover, "P", pointerMoved: false, travelling: true, at: 0.0), .hold)
        XCTAssertEqual(decide(&handover, "P", pointerMoved: false, travelling: false, at: 5.0), .hold)
        XCTAssertTrue(handover.isHolding)
        XCTAssertFalse(handover.isSettling, "and it must not keep the caller polling for it")
    }

    func testSettleCreditDoesNotCarryToAnotherHolder() {
        var handover = handedOver()
        XCTAssertEqual(decide(&handover, "B", at: 0.0), .hold)
        XCTAssertEqual(decide(&handover, "B", pointerMoved: false, travelling: false, at: 0.1), .hold)
        handover.sample(window: "B", hasFocus: true, anchor: "B", owner: 300, pointerMoved: false)
        XCTAssertTrue(handover.sample(window: "B", hasFocus: false, anchor: "B", owner: 300, pointerMoved: false))
        XCTAssertEqual(decide(&handover, "B", frontmost: 300, pointerMoved: false,
                              travelling: false, at: 0.2), .hold,
                       "B is where Q was handed focus: the pointer has asked for nothing")
    }

    func testIsSettlingCoversTheWholeContestIncludingTheStop() {
        var handover = handedOver()
        XCTAssertFalse(handover.isSettling)
        XCTAssertEqual(decide(&handover, "B", at: 0.0), .hold)
        XCTAssertTrue(handover.isSettling, "still travelling, but the caller must keep asking")
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

    /// Sub-threshold jitter must not turn "barely moved" into "settled somewhere else".
    func testTinyMovementDoesNotContestAnUnanchoredHold() {
        var handover = fresh()
        handover.sample(window: nil, hasFocus: nil, anchor: nil, owner: 100, pointerMoved: false)
        handover.sample(window: nil, hasFocus: nil, anchor: nil, owner: 200, pointerMoved: false)

        XCTAssertEqual(decide(&handover, "B", pointerMoved: true, travelling: false, at: 0), .hold)
        XCTAssertFalse(handover.isSettling, "sub-threshold jitter must not start the settle clock")
        XCTAssertEqual(decide(&handover, "B", pointerMoved: false, travelling: false, at: 10), .hold)
    }

    /// Rest means no movement, not merely less than the entry threshold.
    func testTinyMovementResetsASettleInProgress() {
        var handover = handedOver()
        XCTAssertEqual(decide(&handover, "B", at: 0), .hold)
        XCTAssertEqual(decide(&handover, "B", pointerMoved: false, travelling: false, at: 0.1), .hold)
        XCTAssertEqual(decide(&handover, "B", pointerMoved: true, travelling: false, at: 0.35), .hold)
        XCTAssertEqual(decide(&handover, "B", pointerMoved: false, travelling: false, at: 0.4), .hold)
        XCTAssertEqual(decide(&handover, "B", pointerMoved: false, travelling: false, at: 0.65), .hold)
        XCTAssertEqual(decide(&handover, "B", pointerMoved: false, travelling: false, at: 0.71), .entered)
    }

    func testAppliedFocusEstablishesAnAuthoritativeBaseline() {
        var handover = fresh()
        handover.sample(window: "A", hasFocus: true, anchor: "A", owner: 100, pointerMoved: false)
        handover.noteAppliedFocus(window: "B", owner: 200)

        XCTAssertFalse(handover.sample(window: "B", hasFocus: true, anchor: "B",
                                       owner: 200, pointerMoved: false))
        XCTAssertFalse(handover.isHolding)
    }

    // MARK: - Giving up

    func testAbandoningAContestKeepsTheHold() {
        var handover = handedOver()
        XCTAssertEqual(decide(&handover, "B", at: 0.0), .hold)
        XCTAssertTrue(handover.isSettling)
        handover.abandonContest()
        XCTAssertFalse(handover.isSettling)
        XCTAssertTrue(handover.isHolding)
        XCTAssertEqual(decide(&handover, "A", at: 0.1), .hold)
    }

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
        XCTAssertFalse(handover.sample(window: "A", hasFocus: false, anchor: "A", owner: 200, pointerMoved: false),
                       "the first sample after a reset is a baseline")
    }

    // MARK: - The sequence the agent performs

    /// Sample what the previous tick saw, record the new position as movement, then decide. Miss the
    /// movement sample and the next tick reads ordinary travel as the world changing under a still
    /// pointer: a fresh hold, and focus never follows the pointer again.
    func testAHoldSurvivesThePointerCrossingAndIsThenReleasedByIt() {
        var handover = FocusHandover<String>(settle: 0.3)
        var now = 0.0
        var lastSeen = "Zen"
        var decision = HandoverDecision.free

        func tick(over window: String, moved: Bool, hasFocus: Bool, owner: Int32) {
            let handed = handover.sample(window: lastSeen, hasFocus: hasFocus, anchor: lastSeen,
                                         owner: owner, pointerMoved: false)
            lastSeen = window
            if moved, !handed {
                handover.sample(window: window, hasFocus: nil, anchor: window,
                                owner: owner, pointerMoved: true)
            }
            decision = handover.decide(for: window, frontmost: owner, pointerMoved: moved,
                                       travelling: moved, at: now)
            now += 0.05
        }

        tick(over: "Zen", moved: false, hasFocus: true, owner: 2)
        XCTAssertFalse(handover.isHolding)

        tick(over: "Zen", moved: false, hasFocus: false, owner: 1)
        XCTAssertTrue(handover.isHolding, "focus arrived without the pointer")
        XCTAssertEqual(decision, .hold)

        for _ in 0..<6 { tick(over: "Ghostty", moved: true, hasFocus: false, owner: 1) }
        XCTAssertEqual(decision, .hold, "crossing a window is not arriving at it")

        var released = false
        for _ in 0..<10 {
            tick(over: "Ghostty", moved: false, hasFocus: false, owner: 1)
            if decision == .entered { released = true }
        }
        XCTAssertTrue(released, "settled somewhere else, so the hold is spent")
        XCTAssertFalse(handover.isHolding)
    }

    func testAHoldDiscoveredOnAMovingTickStillHolds() {
        var handover = FocusHandover<String>(settle: 0.3)
        handover.sample(window: "Zen", hasFocus: true, anchor: "Zen", owner: 1, pointerMoved: false)
        let handed = handover.sample(window: "Zen", hasFocus: false, anchor: "Zen",
                                     owner: 1, pointerMoved: false)
        XCTAssertTrue(handed)
        XCTAssertEqual(
            handover.decide(for: "Zen", frontmost: 1, pointerMoved: true, travelling: true, at: 0),
            .hold,
            "the hold was found this very tick; movement does not undo it"
        )
    }

    // MARK: - Focus moved by the agent's own shortcut

    /// Stepping between two windows of the frontmost app changes nothing `sample` can see.
    func testKeyboardFocusIsHeldEvenWhenNothingObservableChanged() {
        var handover = FocusHandover<String>(settle: 0.3)
        handover.sample(window: "C", hasFocus: false, anchor: "C", owner: 1, pointerMoved: false)
        handover.sample(window: "C", hasFocus: false, anchor: "C", owner: 1, pointerMoved: false)
        XCTAssertFalse(handover.isHolding, "nothing observable changed, so nothing is inferred")

        handover.noteKeyboardFocus(anchor: "C", owner: 1)
        XCTAssertTrue(handover.isHolding(owner: 1))
        XCTAssertEqual(
            handover.decide(for: "C", frontmost: 1, pointerMoved: false, travelling: false, at: 0),
            .hold,
            "the pointer has not moved since the keystroke, so it does not overrule it"
        )
    }

    func testKeyboardFocusIsReleasedOnceThePointerSettlesElsewhere() {
        var handover = FocusHandover<String>(settle: 0.3)
        handover.noteKeyboardFocus(anchor: "C", owner: 1)

        XCTAssertEqual(
            handover.decide(for: "D", frontmost: 1, pointerMoved: true, travelling: true, at: 0),
            .hold,
            "still travelling"
        )
        XCTAssertEqual(
            handover.decide(for: "D", frontmost: 1, pointerMoved: false, travelling: false, at: 1),
            .hold,
            "the settle clock starts when the pointer stops, not before"
        )
        XCTAssertEqual(
            handover.decide(for: "D", frontmost: 1, pointerMoved: false, travelling: false, at: 1.4),
            .entered
        )
    }

    func testKeyboardFocusWithNothingUnderThePointerIsEndedAnywhere() {
        var handover = FocusHandover<String>(settle: 0)
        handover.noteKeyboardFocus(anchor: nil, owner: 1)
        XCTAssertEqual(
            handover.decide(for: "A", frontmost: 1, pointerMoved: true, travelling: true, at: 0),
            .hold
        )
        XCTAssertEqual(
            handover.decide(for: "A", frontmost: 1, pointerMoved: false, travelling: false, at: 0.1),
            .entered
        )
    }

    func testKeyboardFocusDiscardsAContestInProgress() {
        var handover = FocusHandover<String>(settle: 0.3)
        handover.noteKeyboardFocus(anchor: "C", owner: 1)
        _ = handover.decide(for: "D", frontmost: 1, pointerMoved: true, travelling: true, at: 0)
        _ = handover.decide(for: "D", frontmost: 1, pointerMoved: false, travelling: false, at: 0.1)
        XCTAssertTrue(handover.isSettling)

        handover.noteKeyboardFocus(anchor: "C", owner: 2)
        XCTAssertFalse(handover.isSettling)
        XCTAssertEqual(
            handover.decide(for: "D", frontmost: 2, pointerMoved: false, travelling: false, at: 0.2),
            .hold,
            "the pointer has to travel to D again to overrule the new holder"
        )
    }
}
