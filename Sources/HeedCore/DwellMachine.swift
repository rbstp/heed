public enum TickCondition: Equatable, Sendable {
    /// Focus must not move right now; cancels any dwell in progress.
    case suppressing
    /// The last hit test is stale (Space change, display change, wake); cancels dwell and forces a re-test.
    case invalidating
    case normal
}

/// Dwell logic for focus-follows-mouse, free of platform APIs so it can be tested directly.
///
/// Holds no "last focused" state: focus moved by other means (keyboard, Cmd-Tab) would make a cached
/// answer wrong, so `isAlreadyFocused` is asked live at the moment focus would apply.
public struct DwellMachine<Target: Equatable> {
    public var dwell: Double

    private var candidate: Target?
    private var candidateSince: Double = 0
    private var forceHitTest = false

    public init(dwell: Double) {
        self.dwell = dwell
    }

    /// True while a target can still emerge without new input, so the caller can stop polling
    /// when it is false.
    public var needsTick: Bool { candidate != nil || forceHitTest }

    /// `hitTest` runs only when the pointer moved or a re-test was forced; `isAlreadyFocused` only
    /// when dwell has just expired.
    public mutating func tick(
        now: Double,
        condition: TickCondition,
        cursorMoved: Bool,
        hitTest: () -> Target?,
        isAlreadyFocused: (Target) -> Bool
    ) -> Target? {
        guard condition == .normal else {
            invalidate()
            return nil
        }

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
        }

        guard let pending = candidate, now - candidateSince >= dwell else { return nil }
        candidate = nil
        return isAlreadyFocused(pending) ? nil : pending
    }

    /// Drop any dwell in progress and force a fresh hit test on the next tick.
    public mutating func invalidate() {
        candidate = nil
        forceHitTest = true
    }
}
