/// Refuses a window that changed under a pointer that has not travelled: a window arriving under a
/// still pointer was not moved onto. The window that was admitted becomes the baseline, so the one
/// the pointer already sits on stays acquirable however still the pointer is.
public struct EntryGuard<Target: Equatable> {
    private var baseline: Target?

    public init() {}

    /// A `threshold` of 0 disables the guard.
    public mutating func admit(
        _ target: Target, travelled: Double, threshold: Double
    ) -> EntryVerdict {
        guard threshold > 0, travelled < threshold else {
            baseline = target
            return .admitted
        }
        guard let previous = baseline else {
            baseline = target
            return .baseline
        }
        // Left standing when a different window is refused, or the next tick would accept it.
        guard previous == target else { return .blocked }
        baseline = target
        return .admitted
    }

    /// Take a window as the baseline without judging it, for focus that arrived by a route the
    /// guard cannot see: by the time a handover settles, the travel that earned it has aged out of
    /// the motion tracker.
    public mutating func adopt(_ target: Target) {
        baseline = target
    }

    public mutating func reset() {
        baseline = nil
    }
}

public enum EntryVerdict: Equatable, Sendable {
    case admitted
    case baseline
    case blocked
}
