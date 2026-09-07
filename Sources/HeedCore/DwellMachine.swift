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

    /// No closure passed here may touch the machine. A nested `invalidate()` is an exclusivity
    /// violation that traps at runtime in every build rather than failing to compile.
    ///
    /// `confirm` re-reads the candidate at the instant focus would apply and hands back what it
    /// found, rather than a yes: for one window an element a dwell old can be a different element,
    /// so the caller needs the fresh one. Nil discards the candidate and arms the next hit test.
    public mutating func tick(
        now: Double,
        condition: TickCondition,
        cursorMoved: Bool,
        hitTest: () -> Target?,
        isAlreadyFocused: (Target) -> Bool,
        confirm: (Target) -> Target?
    ) -> Target? {
        guard condition == .normal else {
            invalidate()
            return nil
        }

        var readThisCall = false
        if cursorMoved || forceHitTest {
            forceHitTest = false
            guard let target = hitTest() else {
                candidate = nil
                return nil
            }
            readThisCall = true
            if candidate != target {
                candidate = target
                candidateSince = now
            }
        }

        guard let pending = candidate, now - candidateSince >= dwell else { return nil }
        candidate = nil
        guard !isAlreadyFocused(pending) else { return nil }
        // Only a candidate that has been maturing since an earlier tick can have gone stale. One
        // this call hit-tested is already what the re-read would find, and that read is the most
        // expensive thing the agent does.
        guard !readThisCall else { return pending }
        guard let confirmed = confirm(pending) else {
            invalidate()
            return nil
        }
        return confirmed
    }

    public mutating func invalidate() {
        candidate = nil
        forceHitTest = true
    }
}
