public enum TickCondition: Equatable, Sendable {
    case suppressing
    case invalidating
    case normal
}

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

    public var needsTick: Bool { candidate != nil || forceHitTest }

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

    public mutating func invalidate() {
        candidate = nil
        forceHitTest = true
    }
}
