/// Focus that arrived without the pointer (a new window, a shortcut, Cmd-Tab) is held until the
/// pointer travels to another window and rests there.
///
/// The signal is asked once a tick: does the window under the pointer hold focus? When that answer
/// turns to no while the pointer has not moved, something other than the pointer moved focus. A
/// different window arriving under a still pointer (a Space switch) earns a hold the same way.
///
/// Not derived from the window server: its frontmost window misses focus changes that reorder
/// nothing and key panels above the ordinary level, and matching its windows to Accessibility
/// elements would need private API.
public struct FocusHandover<Target: Equatable> {
    /// Rest time on another window before it overrules a hold. Crossing a window is not arriving
    /// at it, however long the crossing takes, so only stopping counts.
    public var settle: Double

    private var last: Observation?
    /// Keyed per app: which answer applies depends on who holds focus when the question is asked.
    private var holds: [Int32: Hold] = [:]
    private var pending: Pending?

    private struct Observation {
        /// Nil when the pointer is over nothing this agent would focus; that is still an observation.
        let window: Target?
        let hasFocus: Bool?
        let owner: Int32
    }

    private struct Hold {
        /// What the pointer must leave. Nil when it was over nothing, so anywhere it settles counts.
        let anchor: Target?
    }

    private struct Pending {
        let owner: Int32
        let target: Target
        /// Nil while the pointer is still travelling across the target.
        var restingSince: Double?
    }

    public init(settle: Double) {
        self.settle = settle
    }

    public var isHolding: Bool { !holds.isEmpty }

    public func isHolding(owner: Int32) -> Bool { holds[owner] != nil }

    /// True from the moment the pointer resolves another window, so the caller keeps asking; a
    /// resting pointer produces no hit test of its own.
    public var isSettling: Bool { pending != nil }

    /// Fold in whether the window under the pointer holds focus. `hasFocus` is nil exactly when
    /// `window` is, and when the pointer moved; `anchor` is nil when there is nothing to anchor to.
    /// Returns true when this sample recorded a handover.
    @discardableResult
    public mutating func sample(
        window: Target?, hasFocus: Bool?, anchor: Target?, owner: Int32?, pointerMoved: Bool
    ) -> Bool {
        let previous = last

        guard let owner else {
            last = nil
            return false
        }
        guard !pointerMoved else {
            last = Observation(window: window, hasFocus: nil, owner: owner)
            return false
        }
        last = Observation(window: window, hasFocus: hasFocus, owner: owner)

        guard hasFocus != true else { return false }

        // A first look is a baseline. Focus that was already elsewhere for the same window and
        // holder is the agent failing to focus it, which must stay retryable.
        guard let previous,
              previous.hasFocus == true || previous.window != window || previous.owner != owner
        else { return false }

        holds[owner] = Hold(anchor: anchor)
        pending = nil
        return true
    }

    /// What the pointer may do about `target` while `frontmost` holds focus. `pointerMoved` is this
    /// sample's own movement; `travelling` is the caller's recent-motion measure.
    public mutating func decide(
        for target: Target, frontmost: Int32, pointerMoved: Bool, travelling: Bool, at now: Double
    ) -> HandoverDecision {
        guard let hold = holds[frontmost] else {
            pending = nil
            return .free
        }
        if let anchor = hold.anchor, anchor == target {
            pending = nil
            return .hold
        }

        if pending?.target != target || pending?.owner != frontmost {
            // A window that came to a still pointer (a pop-up, a Space switch) is not an entry.
            guard pointerMoved, travelling else {
                pending = nil
                return .hold
            }
            pending = Pending(owner: frontmost, target: target, restingSince: nil)
        }

        if pointerMoved || travelling {
            pending?.restingSince = nil
            return .hold
        }
        if pending?.restingSince == nil { pending?.restingSince = now }
        guard let since = pending?.restingSince, now - since >= settle else { return .hold }

        holds[frontmost] = nil
        pending = nil
        return .entered
    }

    /// Give up a contest without giving up the hold, for when the caller can no longer say what the
    /// pointer is over. Left standing, it would keep the loop awake for a settle that cannot end.
    public mutating func abandonContest() {
        pending = nil
    }

    /// Drop everything about a process that exited; pids are recycled.
    public mutating func forget(owner: Int32) {
        holds[owner] = nil
        if pending?.owner == owner { pending = nil }
    }

    /// Record focus the agent moved by keyboard. Said rather than inferred: stepping between two
    /// windows of the app that already had focus changes nothing `sample` can see.
    public mutating func noteKeyboardFocus(anchor: Target?, owner: Int32) {
        holds[owner] = Hold(anchor: anchor)
        pending = nil
    }

    /// Baseline after the agent moved focus with the pointer, so the owner change on the next tick is
    /// not read as a handover.
    public mutating func noteAppliedFocus(window: Target, owner: Int32) {
        last = Observation(window: window, hasFocus: true, owner: owner)
        holds[owner] = nil
        if pending?.owner == owner { pending = nil }
    }

    public mutating func reset() {
        last = nil
        holds = [:]
        pending = nil
    }
}

public enum HandoverDecision: Equatable, Sendable {
    /// Nothing is held for the app that has focus.
    case free
    /// Focus stays where it was handed.
    case hold
    /// The pointer travelled here and settled; the hold is spent and the entry is proven.
    case entered
}
