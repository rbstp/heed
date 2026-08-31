/// Focus-follows-mouse dwell logic, with no dependency on Accessibility, CoreGraphics or AppKit.
///
/// Kept deliberately free of platform APIs so the parts that are easy to get subtly wrong — dwell
/// expiry, and deciding when a hit test is even worth performing — can be tested directly.
///
/// Design note: this machine holds no `applied`/last-focused field. An earlier design cached the
/// window it had most recently focused and refused to re-focus it, which broke as soon as focus moved
/// by any other means: focus window A with the pointer, switch to B with the keyboard, nudge the
/// pointer inside A, and the cached value said "A is already focused" so A never regained focus.
/// Instead the caller supplies `isAlreadyFocused`, consulted only at the moment focus would be
/// applied, so the authority is always live system state rather than this machine's memory.
public enum TickCondition: Equatable, Sendable {
    /// Focus must not move right now (button held, recent keystroke, menu open, secure input).
    /// Cancels any dwell in progress.
    case suppressing
    /// Something happened that makes a previous hit test meaningless even if the pointer never
    /// moved — a Space change, display reconfiguration, wake from sleep. Cancels dwell and forces
    /// the next tick to re-run the hit test.
    case invalidating
    /// Nothing special.
    case normal
}

public struct DwellMachine<Target: Equatable> {
    /// Seconds the pointer must rest on a target before focus follows.
    public var dwell: Double

    private var candidate: Target?
    private var candidateSince: Double = 0
    private var forceHitTest = false

    public init(dwell: Double) {
        self.dwell = dwell
    }

    /// True when a dwell is in progress. Lets the caller skip guards that are only worth paying for
    /// while something is actually pending.
    public var hasCandidate: Bool { candidate != nil }

    /// Advance one tick.
    ///
    /// - Parameters:
    ///   - now: Monotonic seconds. Injected rather than read internally so tests control time.
    ///   - condition: See `TickCondition`.
    ///   - cursorMoved: Whether the pointer moved since the previous tick.
    ///   - hitTest: Resolves the target under the pointer. Called *only* when a hit test is actually
    ///     needed, which is the point of routing it through here — a stationary pointer must not
    ///     generate cross-process traffic.
    ///   - isAlreadyFocused: Live check against real system focus. Called at most once per tick, and
    ///     only when dwell has just expired.
    /// - Returns: The target to focus, or `nil` to do nothing.
    public mutating func tick(
        now: Double,
        condition: TickCondition,
        cursorMoved: Bool,
        hitTest: () -> Target?,
        isAlreadyFocused: (Target) -> Bool
    ) -> Target? {
        switch condition {
        case .suppressing:
            // Arm a fresh hit test as well as dropping the candidate. Without it, entering a window
            // while suppressed (mid-typing, button held, menu open) and then stopping left the
            // pointer parked over a window that could never be acquired: no movement means no hit
            // test, and the candidate is already gone.
            candidate = nil
            forceHitTest = true
            return nil
        case .invalidating:
            candidate = nil
            forceHitTest = true
            return nil
        case .normal:
            break
        }

        // A stationary pointer skips the hit test but must still be able to reach expiry below --
        // settling on a window and waiting is the single most common way focus is meant to move.
        if cursorMoved || forceHitTest {
            forceHitTest = false
            guard let target = hitTest() else {
                candidate = nil
                return nil
            }
            if candidate != target {
                candidate = target
                candidateSince = now
            }
            // Same target as last tick: leave candidateSince alone, so moving *within* a window
            // cannot starve the timer.
        }

        guard let pending = candidate, now - candidateSince >= dwell else { return nil }

        // Clear before returning: whether or not the caller succeeds, dwell for this target is
        // spent. Re-arming on failure is the caller's decision, via invalidate().
        candidate = nil
        return isAlreadyFocused(pending) ? nil : pending
    }

    /// Drop any dwell in progress and force a fresh hit test on the next tick. Used after a failed
    /// focus attempt, so the next tick re-derives the target instead of reusing a possibly dead
    /// reference, and after external events that change what sits under the pointer.
    public mutating func invalidate() {
        candidate = nil
        forceHitTest = true
    }
}
