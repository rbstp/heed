import CoreGraphics
import XCTest
@testable import HeedCore

/// Where the pointer sits for every test that is not about the pointer moving, and the window
/// server's number for the window "A" it sits on.
private let resting = CGPoint(x: 400, y: 300)
private let windowA = 1
private let windowB = 2

/// Pid 100 owns the window under the pointer ("A"); pid 200 is the app handed focus.
final class FocusHandoverTests: XCTestCase {
    private func fresh(settle: Double = 0.3) -> FocusHandover<String> {
        FocusHandover<String>(settle: settle, travel: 6)
    }

    /// Focus was on the window under the pointer, then was not, and the pointer never moved.
    private func handedOver(settle: Double = 0.3) -> FocusHandover<String> {
        var handover = fresh(settle: settle)
        handover.sample(window: "A", hasFocus: true, anchor: "A", number: windowA, pointer: resting, owner: 100,
                        pointerMoved: false)
        let handed = handover.sample(window: "A", hasFocus: false, anchor: "A", number: windowA, pointer: resting,
                                     owner: 200, pointerMoved: false)
        XCTAssertTrue(handed)
        return handover
    }

    private func decide(
        _ handover: inout FocusHandover<String>, _ target: String, frontmost: Int32 = 200,
        pointer: CGPoint? = resting, pointerMoved: Bool = true, travelling: Bool = true,
        at now: Double
    ) -> HandoverDecision {
        handover.decide(for: target, frontmost: frontmost, pointer: pointer,
                        pointerMoved: pointerMoved, travelling: travelling, at: now)
    }

    // MARK: - Noticing a handover

    func testAFirstLookIsNotAHandover() {
        var handover = fresh()
        XCTAssertFalse(handover.sample(window: "A", hasFocus: false, anchor: "A", number: windowA, pointer: resting,
                                       owner: 200, pointerMoved: false))
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
        handover.sample(window: "C", hasFocus: false, anchor: "C", number: windowA, pointer: resting, owner: 200,
                        pointerMoved: false)
        XCTAssertFalse(handover.sample(window: "C", hasFocus: false, anchor: "C", number: windowA, pointer: resting,
                                       owner: 200, pointerMoved: false))
        XCTAssertFalse(handover.isHolding, "a failed focus attempt must stay retryable")
    }

    /// A Space switch shows a different window under a pointer that never moved.
    func testADifferentWindowArrivingUnderAStillPointerIsAHandover() {
        var handover = fresh()
        handover.sample(window: "A", hasFocus: true, anchor: "A", number: windowA, pointer: resting, owner: 100,
                        pointerMoved: false)
        XCTAssertTrue(handover.sample(window: "N", hasFocus: false, anchor: "N", number: windowA, pointer: resting,
                                      owner: 200, pointerMoved: false))
        XCTAssertEqual(decide(&handover, "N", at: 0), .hold)
    }

    /// The answer was already "no" the second time, so a bare yes/no would miss it.
    func testASecondHandoverWhileAlreadyHoldingIsNoticed() {
        var handover = handedOver()
        XCTAssertTrue(handover.sample(window: "A", hasFocus: false, anchor: "A", number: windowA, pointer: resting,
                                      owner: 300, pointerMoved: false),
                      "focus moved on from one holder to another without the pointer")
        XCTAssertEqual(decide(&handover, "A", frontmost: 300, at: 0), .hold)
    }

    func testFocusOnTheWindowUnderThePointerIsNotAHandover() {
        var handover = fresh()
        handover.sample(window: "A", hasFocus: true, anchor: "A", number: windowA, pointer: resting, owner: 100,
                        pointerMoved: false)
        XCTAssertFalse(handover.sample(window: "A", hasFocus: true, anchor: "A", number: windowA, pointer: resting,
                                       owner: 100, pointerMoved: false))
        XCTAssertFalse(handover.isHolding)
    }

    func testAMovingPointerNeverArmsAndRebaselines() {
        var handover = fresh()
        handover.sample(window: "A", hasFocus: true, anchor: "A", number: windowA, pointer: resting, owner: 100,
                        pointerMoved: false)
        XCTAssertFalse(handover.sample(window: "A", hasFocus: nil, anchor: "A", number: windowA, pointer: resting,
                                       owner: 200, pointerMoved: true))
        XCTAssertFalse(handover.sample(window: "A", hasFocus: false, anchor: "A", number: windowA, pointer: resting,
                                       owner: 200, pointerMoved: false),
                       "the sample after movement is a baseline, not a handover")
        XCTAssertFalse(handover.isHolding)
    }

    func testASampleWithNoOwnerRebaselines() {
        var handover = fresh()
        handover.sample(window: "A", hasFocus: true, anchor: "A", number: windowA, pointer: resting, owner: 100,
                        pointerMoved: false)
        handover.sample(window: "A", hasFocus: false, anchor: "A", number: windowA, pointer: resting, owner: nil,
                        pointerMoved: false)
        XCTAssertFalse(handover.isHolding)
        XCTAssertFalse(handover.sample(window: "A", hasFocus: false, anchor: "A",
                                       number: windowA, pointer: resting, owner: 200, pointerMoved: false),
                       "the sample after one that could not be attributed is a baseline")
    }

    /// Launching from the Dock: the pointer is over nothing this agent would focus.
    func testAHandoverWithThePointerOverNothingStillHolds() {
        var handover = fresh()
        handover.sample(window: nil, hasFocus: nil, anchor: nil, number: nil, pointer: resting, owner: 100,
                        pointerMoved: false)
        XCTAssertTrue(handover.sample(window: nil, hasFocus: nil, anchor: nil,
                                      number: windowA, pointer: resting, owner: 200, pointerMoved: false),
                      "focus moved to another app while the pointer sat over nothing")
        XCTAssertTrue(handover.isHolding)
    }

    func testAnUnanchoredHoldSurvivesCrossingAndEndsOnSettling() {
        var handover = fresh()
        handover.sample(window: nil, hasFocus: nil, anchor: nil, number: nil, pointer: resting, owner: 100,
                        pointerMoved: false)
        handover.sample(window: nil, hasFocus: nil, anchor: nil, number: nil, pointer: resting, owner: 200,
                        pointerMoved: false)

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
        handover.sample(window: nil, hasFocus: nil, anchor: nil, number: nil, pointer: resting, owner: 100,
                        pointerMoved: false)
        handover.sample(window: nil, hasFocus: nil, anchor: nil, number: nil, pointer: resting, owner: 200,
                        pointerMoved: false)
        XCTAssertEqual(decide(&handover, "P", pointerMoved: false, travelling: false, at: 0), .hold)
        XCTAssertTrue(handover.isHolding)
    }

    func testTheSameNothingUnderThePointerIsNotAHandover() {
        var handover = fresh()
        handover.sample(window: nil, hasFocus: nil, anchor: nil, number: nil, pointer: resting, owner: 200,
                        pointerMoved: false)
        XCTAssertFalse(handover.sample(window: nil, hasFocus: nil, anchor: nil,
                                       number: windowA, pointer: resting, owner: 200, pointerMoved: false))
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
        handover.sample(window: "B", hasFocus: true, anchor: "B", number: windowA, pointer: resting, owner: 300,
                        pointerMoved: false)
        XCTAssertTrue(handover.sample(window: "B", hasFocus: false, anchor: "B", number: windowA, pointer: resting,
                                      owner: 300, pointerMoved: false))
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
        handover.sample(window: nil, hasFocus: nil, anchor: nil, number: nil, pointer: resting, owner: 100,
                        pointerMoved: false)
        handover.sample(window: nil, hasFocus: nil, anchor: nil, number: nil, pointer: resting, owner: 200,
                        pointerMoved: false)

        let jitter = CGPoint(x: resting.x + 2, y: resting.y)
        XCTAssertEqual(decide(&handover, "B", pointer: jitter, pointerMoved: true,
                              travelling: false, at: 0), .hold)
        XCTAssertFalse(handover.isSettling, "sub-threshold jitter must not start the settle clock")
        XCTAssertEqual(decide(&handover, "B", pointer: jitter, pointerMoved: false,
                              travelling: false, at: 10), .hold)
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
        handover.sample(window: "A", hasFocus: true, anchor: "A", number: windowA, pointer: resting, owner: 100,
                        pointerMoved: false)
        handover.noteAppliedFocus(window: "B", owner: 200)

        XCTAssertFalse(handover.sample(window: "B", hasFocus: true, anchor: "B",
                                       number: windowA, pointer: resting, owner: 200, pointerMoved: false))
        XCTAssertFalse(handover.isHolding)
    }

    /// The window the pointer set out from is exempt only while the pointer is still on it. Crossing
    /// to another window and coming straight back is the mouse in use, and focus follows it home.
    func testComingBackToTheAnchorAfterLeavingItEndsTheHold() {
        var handover = handedOver()
        let across = CGPoint(x: resting.x + 900, y: resting.y)

        XCTAssertEqual(decide(&handover, "B", pointer: across, at: 0), .hold, "crossing B")
        XCTAssertEqual(decide(&handover, "A", pointer: resting, at: 0.2), .hold, "back on A, moving")
        XCTAssertEqual(decide(&handover, "A", pointer: resting, pointerMoved: false,
                              travelling: false, at: 0.3), .hold)
        XCTAssertEqual(decide(&handover, "A", pointer: resting, pointerMoved: false,
                              travelling: false, at: 0.7), .entered)
        XCTAssertFalse(handover.isHolding)
    }

    /// Which is not licence to end it without leaving: a pointer that has only ever been on the
    /// anchor keeps the hold however far it wanders on it.
    func testWanderingTheAnchorWindowKeepsItsExemption() {
        var handover = handedOver()
        for step in 0..<20 {
            let wandered = CGPoint(x: resting.x + Double(step) * 40, y: resting.y)
            XCTAssertEqual(decide(&handover, "A", pointer: wandered, at: Double(step) * 0.1), .hold)
        }
        XCTAssertEqual(decide(&handover, "A", pointer: resting, pointerMoved: false,
                              travelling: false, at: 5), .hold)
        XCTAssertTrue(handover.isHolding)
    }

    /// The excursion the keystroke's own cooldown hides: onto another window and back before a hit
    /// test was allowed to run, so the window server was the only witness.
    func testAnExcursionSeenOnlyByTheWindowServerSpendsTheAnchor() {
        var handover = handedOver()
        // A step the anchor's own frame would have called staying put: another window overlapping it.
        handover.notePointer(CGPoint(x: resting.x + 20, y: resting.y), under: windowB)
        handover.notePointer(resting, under: windowA)

        XCTAssertEqual(decide(&handover, "A", pointerMoved: false, travelling: false, at: 0), .hold)
        XCTAssertEqual(decide(&handover, "A", pointerMoved: false, travelling: false, at: 0.4),
                       .entered)
        XCTAssertFalse(handover.isHolding)
    }

    /// Which the anchor's own frame could not answer: another window can overlap it, and the anchor
    /// can move out from under a pointer that never went anywhere.
    func testAPointerThatStaysOnTheAnchorWindowKeepsItsExemption() {
        var handover = handedOver()
        handover.notePointer(CGPoint(x: resting.x + 900, y: resting.y + 400), under: windowA)
        handover.notePointer(resting, under: windowA)

        XCTAssertEqual(decide(&handover, "P", pointerMoved: false, travelling: false, at: 0), .hold)
        XCTAssertEqual(decide(&handover, "P", pointerMoved: false, travelling: false, at: 5), .hold)
        XCTAssertTrue(handover.isHolding)
    }

    /// Leaving for the desktop or the menu bar is leaving.
    func testThePointerOverNoWindowAtAllHasLeftTheAnchor() {
        var handover = handedOver()
        handover.notePointer(CGPoint(x: resting.x, y: 2), under: nil)
        handover.notePointer(resting, under: windowA)

        XCTAssertEqual(decide(&handover, "A", pointerMoved: false, travelling: false, at: 0), .hold)
        XCTAssertEqual(decide(&handover, "A", pointerMoved: false, travelling: false, at: 0.4),
                       .entered)
    }

    /// With no window to name, the same question falls back to how far the pointer has come.
    func testAnUnanchoredHoldNoticesTheExcursionByDistance() {
        var handover = fresh()
        handover.sample(window: nil, hasFocus: nil, anchor: nil, number: nil, pointer: resting,
                        owner: 100, pointerMoved: false)
        handover.sample(window: nil, hasFocus: nil, anchor: nil, number: nil, pointer: resting,
                        owner: 200, pointerMoved: false)
        handover.notePointer(CGPoint(x: resting.x + 900, y: resting.y), under: nil)

        XCTAssertEqual(decide(&handover, "P", pointerMoved: false, travelling: false, at: 0), .hold)
        XCTAssertEqual(decide(&handover, "P", pointerMoved: false, travelling: false, at: 0.4),
                       .entered)
    }

    /// Having left once is not licence for the next window to arrive under a pointer that has since
    /// stopped: a pop-up after the journey is still the world moving, not the pointer.
    func testAWindowArrivingAfterTheDepartureIsStillNotAnEntry() {
        var handover = handedOver()
        let across = CGPoint(x: resting.x + 900, y: resting.y)
        XCTAssertEqual(decide(&handover, "B", pointer: across, at: 0), .hold)
        XCTAssertEqual(decide(&handover, "B", pointer: across, pointerMoved: false,
                              travelling: false, at: 0.1), .hold)
        handover.abandonContest()

        XCTAssertEqual(decide(&handover, "C", pointer: across, pointerMoved: false,
                              travelling: false, at: 0.2), .hold, "C came to the pointer")
        XCTAssertEqual(decide(&handover, "C", pointer: across, pointerMoved: false,
                              travelling: false, at: 5), .hold)
        XCTAssertTrue(handover.isHolding)
    }

    /// Wandering the anchor while nothing may look is still wandering the anchor, so a window that
    /// then arrives where the pointer stopped has not been entered either.
    func testWanderingOnTheAnchorUnwatchedIsNotTravel() {
        var handover = handedOver()
        let corner = CGPoint(x: resting.x + 95, y: resting.y + 95)
        handover.notePointer(corner, under: windowA)

        XCTAssertEqual(decide(&handover, "P", pointer: corner, pointerMoved: false,
                              travelling: false, at: 0), .hold)
        XCTAssertEqual(decide(&handover, "P", pointer: corner, pointerMoved: false,
                              travelling: false, at: 5), .hold)
        XCTAssertTrue(handover.isHolding)
    }

    /// Focus arriving a second time does not put the pointer back where it started: the agent
    /// re-declares the same handover a tick later, from a window the pointer has already left.
    func testASecondHandoverKeepsWhereThePointerHasBeen() {
        var handover = handedOver()
        handover.notePointer(CGPoint(x: resting.x + 900, y: resting.y), under: windowB)

        XCTAssertTrue(handover.sample(window: "A", hasFocus: false, anchor: "A", number: windowB,
                                      pointer: resting, owner: 300, pointerMoved: false))
        handover.sample(window: "A", hasFocus: false, anchor: "A", number: windowB,
                        pointer: resting, owner: 200, pointerMoved: false)

        XCTAssertEqual(decide(&handover, "B", pointerMoved: false, travelling: false, at: 0), .hold)
        XCTAssertEqual(decide(&handover, "B", pointerMoved: false, travelling: false, at: 0.4),
                       .entered)
    }

    /// The window under a pointer changes for reasons of its own -- one opens over it, the anchor
    /// closes -- and a hand on a mouse is never perfectly still.
    func testANewWindowUnderAnAlmostStillPointerIsNotADeparture() {
        var handover = handedOver()
        handover.notePointer(CGPoint(x: resting.x + 2, y: resting.y), under: windowB)

        XCTAssertEqual(decide(&handover, "A", pointerMoved: false, travelling: false, at: 0), .hold)
        XCTAssertEqual(decide(&handover, "A", pointerMoved: false, travelling: false, at: 5), .hold)
        XCTAssertTrue(handover.isHolding)
    }

    /// Travel that led nowhere the agent could name is spent, not saved up for the next window to
    /// arrive under a pointer that has since stopped.
    func testTravelOntoNothingIsNotCreditForAWindowThatArrivesLater() {
        var handover = handedOver()
        handover.notePointer(CGPoint(x: resting.x + 900, y: resting.y), under: nil)
        handover.abandonContest()

        XCTAssertEqual(decide(&handover, "P", pointerMoved: false, travelling: false, at: 0), .hold)
        XCTAssertEqual(decide(&handover, "P", pointerMoved: false, travelling: false, at: 5), .hold)
        XCTAssertTrue(handover.isHolding)
    }

    /// A hold with nothing to anchor to must not be given a window to be exempt about.
    func testAnUnanchoredHoldIsNotGivenAWindowIdentity() {
        var handover = fresh()
        handover.sample(window: nil, hasFocus: nil, anchor: nil, number: windowA, pointer: resting,
                        owner: 100, pointerMoved: false)
        handover.sample(window: nil, hasFocus: nil, anchor: nil, number: windowA, pointer: resting,
                        owner: 200, pointerMoved: false)
        let across = CGPoint(x: resting.x + 900, y: resting.y)
        handover.notePointer(across, under: windowA)

        XCTAssertEqual(decide(&handover, "P", pointer: across, pointerMoved: false,
                              travelling: false, at: 0), .hold)
        XCTAssertEqual(decide(&handover, "P", pointer: across, pointerMoved: false,
                              travelling: false, at: 0.4), .entered,
                       "anywhere it settles counts, whatever window that is")
    }

    /// The window server is asked only when a hold is actually declared: it costs a round trip, and
    /// the sample runs every tick.
    func testTheWindowUnderThePointerIsAskedForOnlyWhenAHoldIsDeclared() {
        var handover = fresh()
        var asked = 0
        func number() -> Int? {
            asked += 1
            return windowA
        }
        handover.sample(window: "A", hasFocus: true, anchor: "A", number: number(), pointer: resting,
                        owner: 100, pointerMoved: false)
        XCTAssertEqual(asked, 0, "focus on the window under the pointer is not a handover")
        handover.sample(window: "A", hasFocus: nil, anchor: "A", number: number(), pointer: resting,
                        owner: 100, pointerMoved: true)
        XCTAssertEqual(asked, 0, "a moving pointer only rebaselines")
        handover.sample(window: "A", hasFocus: false, anchor: "A", number: number(), pointer: resting,
                        owner: 200, pointerMoved: false)
        XCTAssertEqual(asked, 1)
    }

    /// Two apps can hold at once, and only the one the pointer left is spent by leaving.
    func testLeavingOneAnchorDoesNotSpendAnother() {
        var handover = handedOver()
        handover.sample(window: "B", hasFocus: true, anchor: "B", number: windowB, pointer: resting,
                        owner: 300, pointerMoved: false)
        XCTAssertTrue(handover.sample(window: "B", hasFocus: false, anchor: "B", number: windowB,
                                      pointer: resting, owner: 400, pointerMoved: false))
        handover.notePointer(CGPoint(x: resting.x + 900, y: resting.y), under: windowB)

        XCTAssertEqual(decide(&handover, "B", frontmost: 400, pointerMoved: false,
                              travelling: false, at: 0), .hold, "still on what 400 was handed from")
        XCTAssertEqual(decide(&handover, "B", frontmost: 400, pointerMoved: false,
                              travelling: false, at: 5), .hold)
        XCTAssertEqual(decide(&handover, "B", frontmost: 200, pointerMoved: false,
                              travelling: false, at: 5.4), .hold, "200 was handed from A")
        XCTAssertEqual(decide(&handover, "B", frontmost: 200, pointerMoved: false,
                              travelling: false, at: 5.8), .entered)
    }

    // MARK: - Travel no tick was allowed to watch

    /// The keystroke that hands focus over suppresses focus decisions for half a second, which is
    /// long enough for the pointer to cross to another screen and stop. Nothing then moves, and
    /// without the pointer's position the hold would stand until the pointer moved again.
    func testAPointerFoundSomewhereElseAtRestSettlesThere() {
        var handover = handedOver()
        let elsewhere = CGPoint(x: resting.x + 900, y: resting.y)

        XCTAssertEqual(decide(&handover, "B", pointer: elsewhere, pointerMoved: false,
                              travelling: false, at: 0), .hold, "the settle clock starts here")
        XCTAssertTrue(handover.isSettling, "and the caller has to be kept asking")
        XCTAssertEqual(decide(&handover, "B", pointer: elsewhere, pointerMoved: false,
                              travelling: false, at: 0.4), .entered)
        XCTAssertFalse(handover.isHolding)
    }

    func testAKeyboardHoldIsSettledByAnArrivalNoTickSaw() {
        var handover = fresh()
        handover.noteKeyboardFocus(anchor: "C", number: windowA, pointer: resting, owner: 1)
        let elsewhere = CGPoint(x: resting.x - 900, y: resting.y + 40)

        XCTAssertEqual(decide(&handover, "D", frontmost: 1, pointer: elsewhere, pointerMoved: false,
                              travelling: false, at: 0), .hold)
        XCTAssertEqual(decide(&handover, "D", frontmost: 1, pointer: elsewhere, pointerMoved: false,
                              travelling: false, at: 0.4), .entered)
        XCTAssertEqual(decide(&handover, "C", frontmost: 1, pointer: resting, at: 0.5), .free,
                       "the hold is spent, so the pointer is followed back to C as well")
    }

    /// The pop-up case the arrival test must not swallow: the window changed, the pointer did not.
    func testAWindowArrivingWhereThePointerAlreadySatIsStillNotAnEntry() {
        var handover = handedOver()
        XCTAssertEqual(decide(&handover, "P", pointer: resting, pointerMoved: false,
                              travelling: false, at: 0), .hold)
        XCTAssertEqual(decide(&handover, "P", pointer: resting, pointerMoved: false,
                              travelling: false, at: 5), .hold)
        XCTAssertTrue(handover.isHolding)
        XCTAssertFalse(handover.isSettling)
    }

    /// Where the pointer must travel from is wherever it was last seen on the anchor, not where it
    /// happened to be at the handover: a pointer wandering its own window has not left it.
    func testWanderingTheAnchorWindowMovesWhereTheHoldMeasuresFrom() {
        var handover = handedOver()
        let wandered = CGPoint(x: resting.x + 300, y: resting.y + 200)
        XCTAssertEqual(decide(&handover, "A", pointer: wandered, at: 0), .hold)

        XCTAssertEqual(decide(&handover, "P", pointer: wandered, pointerMoved: false,
                              travelling: false, at: 0.1), .hold, "a pop-up, not an arrival")
        XCTAssertEqual(decide(&handover, "P", pointer: wandered, pointerMoved: false,
                              travelling: false, at: 5), .hold)
        XCTAssertTrue(handover.isHolding)
    }

    /// Nothing can be concluded from a position the caller could not read.
    func testAnUnknownPointerNeverEndsAHold() {
        var handover = handedOver()
        XCTAssertEqual(decide(&handover, "B", pointer: nil, pointerMoved: false,
                              travelling: false, at: 0), .hold)
        XCTAssertEqual(decide(&handover, "B", pointer: nil, pointerMoved: false,
                              travelling: false, at: 5), .hold)
        XCTAssertTrue(handover.isHolding)
    }

    /// Focus taken by the pointer is what every hold was waiting for, however many apps were
    /// holding: one left behind would apply again the next time its app came forward.
    func testFocusTakenByThePointerSpendsEveryHold() {
        var handover = handedOver()
        handover.sample(window: "B", hasFocus: true, anchor: "B", number: windowB, pointer: resting,
                        owner: 300, pointerMoved: false)
        XCTAssertTrue(handover.sample(window: "B", hasFocus: false, anchor: "B", number: windowB,
                                      pointer: resting, owner: 400, pointerMoved: false))
        XCTAssertTrue(handover.isHolding(owner: 200))
        XCTAssertTrue(handover.isHolding(owner: 400))

        handover.noteAppliedFocus(window: "C", owner: 500)

        XCTAssertFalse(handover.isHolding)
        XCTAssertFalse(handover.isSettling)
        XCTAssertEqual(decide(&handover, "A", frontmost: 200, at: 0), .free)
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
        XCTAssertFalse(handover.sample(window: "A", hasFocus: false, anchor: "A", number: windowA, pointer: resting,
                                       owner: 200, pointerMoved: false),
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
                                         number: windowA, pointer: resting, owner: owner, pointerMoved: false)
            lastSeen = window
            if moved, !handed {
                handover.sample(window: window, hasFocus: nil, anchor: window,
                                number: windowA, pointer: resting, owner: owner, pointerMoved: true)
            }
            decision = handover.decide(for: window, frontmost: owner, pointer: resting, pointerMoved: moved,
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
        handover.sample(window: "Zen", hasFocus: true, anchor: "Zen", number: windowA, pointer: resting, owner: 1,
                        pointerMoved: false)
        let handed = handover.sample(window: "Zen", hasFocus: false, anchor: "Zen",
                                     number: windowA, pointer: resting, owner: 1, pointerMoved: false)
        XCTAssertTrue(handed)
        XCTAssertEqual(
            handover.decide(for: "Zen", frontmost: 1, pointer: resting, pointerMoved: true,
                            travelling: true, at: 0),
            .hold,
            "the hold was found this very tick; movement does not undo it"
        )
    }

    // MARK: - Focus moved by the agent's own shortcut

    /// Stepping between two windows of the frontmost app changes nothing `sample` can see.
    func testKeyboardFocusIsHeldEvenWhenNothingObservableChanged() {
        var handover = FocusHandover<String>(settle: 0.3)
        handover.sample(window: "C", hasFocus: false, anchor: "C", number: windowA, pointer: resting, owner: 1,
                        pointerMoved: false)
        handover.sample(window: "C", hasFocus: false, anchor: "C", number: windowA, pointer: resting, owner: 1,
                        pointerMoved: false)
        XCTAssertFalse(handover.isHolding, "nothing observable changed, so nothing is inferred")

        handover.noteKeyboardFocus(anchor: "C", number: windowA, pointer: resting, owner: 1)
        XCTAssertTrue(handover.isHolding(owner: 1))
        XCTAssertEqual(
            handover.decide(for: "C", frontmost: 1, pointer: resting, pointerMoved: false,
                            travelling: false, at: 0),
            .hold,
            "the pointer has not moved since the keystroke, so it does not overrule it"
        )
    }

    func testKeyboardFocusIsReleasedOnceThePointerSettlesElsewhere() {
        var handover = FocusHandover<String>(settle: 0.3)
        handover.noteKeyboardFocus(anchor: "C", number: windowA, pointer: resting, owner: 1)

        XCTAssertEqual(
            handover.decide(for: "D", frontmost: 1, pointer: resting, pointerMoved: true,
                            travelling: true, at: 0),
            .hold,
            "still travelling"
        )
        XCTAssertEqual(
            handover.decide(for: "D", frontmost: 1, pointer: resting, pointerMoved: false,
                            travelling: false, at: 1),
            .hold,
            "the settle clock starts when the pointer stops, not before"
        )
        XCTAssertEqual(
            handover.decide(for: "D", frontmost: 1, pointer: resting, pointerMoved: false,
                            travelling: false, at: 1.4),
            .entered
        )
    }

    func testKeyboardFocusWithNothingUnderThePointerIsEndedAnywhere() {
        var handover = FocusHandover<String>(settle: 0)
        handover.noteKeyboardFocus(anchor: nil, number: nil, pointer: resting, owner: 1)
        XCTAssertEqual(
            handover.decide(for: "A", frontmost: 1, pointer: resting, pointerMoved: true,
                            travelling: true, at: 0),
            .hold
        )
        XCTAssertEqual(
            handover.decide(for: "A", frontmost: 1, pointer: resting, pointerMoved: false,
                            travelling: false, at: 0.1),
            .entered
        )
    }

    func testKeyboardFocusDiscardsAContestInProgress() {
        var handover = FocusHandover<String>(settle: 0.3)
        handover.noteKeyboardFocus(anchor: "C", number: windowA, pointer: resting, owner: 1)
        _ = handover.decide(for: "D", frontmost: 1, pointer: resting, pointerMoved: true,
                            travelling: true, at: 0)
        _ = handover.decide(for: "D", frontmost: 1, pointer: resting, pointerMoved: false,
                            travelling: false, at: 0.1)
        XCTAssertTrue(handover.isSettling)

        handover.noteKeyboardFocus(anchor: "C", number: windowA, pointer: resting, owner: 2)
        XCTAssertFalse(handover.isSettling)
        XCTAssertEqual(
            handover.decide(for: "D", frontmost: 2, pointer: resting, pointerMoved: false,
                            travelling: false, at: 0.2),
            .hold,
            "the pointer has to travel to D again to overrule the new holder"
        )
    }
}
