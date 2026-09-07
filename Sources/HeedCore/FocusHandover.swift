import CoreGraphics
import Foundation

/// Focus that arrived without the pointer (a new window, a shortcut, Cmd-Tab) is held until the
/// pointer travels to another window and rests there. The window it set out from is exempt only
/// until it leaves: a pointer that has been somewhere else is a mouse in use, and the hold then
/// ends wherever it stops, that window included. Leaving is judged from the window the pointer is
/// over as the window server numbers it, since the hit test is not allowed to run while focus
/// decisions are suppressed.
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

    /// How far from where the handover left it the pointer counts as having travelled since.
    public var travel: Double

    private var last: Observation?
    /// Keyed per app: which answer applies depends on who holds focus when the question is asked.
    private var holds: [Int32: Hold] = [:]
    private var pending: Pending?
    /// Where the pointer was the last time a decision was asked for, so travel between two asks
    /// counts even when no tick was allowed to watch it happen.
    private var lastAsked: CGPoint?

    private struct Observation {
        /// Nil when the pointer is over nothing this agent would focus; that is still an observation.
        let window: Target?
        let hasFocus: Bool?
        let owner: Int32
    }

    private struct Hold {
        /// What the pointer must leave. Nil when it was over nothing, so anywhere it settles counts.
        let anchor: Target?
        /// The window server's number for what the pointer was on. A stable identity: it survives
        /// the window moving, and it tells overlapping windows apart, which a frame cannot.
        let number: Int?
        /// Where the pointer was while the anchor still held it.
        let pointer: CGPoint?
        /// Set once the pointer has been seen away from the anchor; coming back is then an arrival.
        var left = false
        /// Travel nothing was allowed to watch, good for the one contest it explains.
        var unseenTravel = false

        func staying(at pointer: CGPoint?) -> Hold {
            Hold(anchor: anchor, number: number, pointer: pointer ?? self.pointer,
                 left: left, unseenTravel: unseenTravel)
        }

        var away: Hold {
            Hold(anchor: anchor, number: number, pointer: pointer, left: true, unseenTravel: true)
        }

        var spent: Hold {
            Hold(anchor: anchor, number: number, pointer: pointer, left: true, unseenTravel: false)
        }
    }

    private struct Pending {
        let owner: Int32
        let target: Target
        /// Nil while the pointer is still travelling across the target.
        var restingSince: Double?
    }

    public init(settle: Double, travel: Double = 0) {
        self.settle = settle
        self.travel = travel
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
        window: Target?, hasFocus: Bool?, anchor: Target?, number: @autoclosure () -> Int?,
        pointer: CGPoint?, owner: Int32?, pointerMoved: Bool
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

        holds[owner] = born(anchor: anchor, number: number(), pointer: pointer, after: holds[owner])
        pending = nil
        return true
    }

    /// What the pointer may do about `target` while `frontmost` holds focus. `pointer` is where it
    /// is now, `pointerMoved` this sample's own movement, `travelling` the caller's recent-motion
    /// measure.
    public mutating func decide(
        for target: Target, frontmost: Int32, pointer: CGPoint?, pointerMoved: Bool,
        travelling: Bool, at now: Double
    ) -> HandoverDecision {
        let travelled = moved(from: lastAsked, to: pointer)
        if let pointer { lastAsked = pointer }

        guard let hold = holds[frontmost] else {
            pending = nil
            return .free
        }
        if !hold.left, let anchor = hold.anchor, anchor == target {
            holds[frontmost] = hold.staying(at: pointer)
            pending = nil
            return .hold
        }

        if pending?.target != target || pending?.owner != frontmost {
            // A window that came to a still pointer (a pop-up, a Space switch) is not an entry.
            guard hold.unseenTravel || (pointerMoved && travelling) || travelled else {
                pending = nil
                return .hold
            }
            pending = Pending(owner: frontmost, target: target, restingSince: nil)
            holds[frontmost] = hold.spent
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

    /// Fold in where the pointer is, every tick, whether or not a hit test is allowed this one.
    public mutating func notePointer(_ pointer: CGPoint, under number: Int?) {
        var accounted = !holds.isEmpty
        for (owner, hold) in holds {
            guard !hold.left else {
                accounted = false
                continue
            }
            let away = hold.number.map { $0 != number && moved(from: hold.pointer, to: pointer) }
                ?? moved(from: hold.pointer, to: pointer)
            holds[owner] = away ? hold.away : hold.staying(at: pointer)
            if away { accounted = false }
        }
        // Movement that never left the anchor is movement to nowhere, so it is not travel to find
        // later: the next decision measures from here.
        if accounted { lastAsked = pointer }
    }

    /// A hold declared where one already stands keeps what the pointer has done since: focus
    /// arriving twice does not put the pointer back where it started. Only an anchor can be
    /// identified by number, so an unanchored hold keeps its "anywhere it settles counts".
    private mutating func born(
        anchor: Target?, number: Int?, pointer: CGPoint?, after standing: Hold? = nil
    ) -> Hold {
        lastAsked = pointer
        return Hold(anchor: anchor, number: anchor == nil ? nil : number, pointer: pointer,
                    left: standing?.left ?? false, unseenTravel: standing?.unseenTravel ?? false)
    }

    /// Unknown either way counts as staying put: an answer that cannot be given cannot end a hold.
    private func moved(from origin: CGPoint?, to pointer: CGPoint?) -> Bool {
        guard let origin, let pointer else { return false }
        return hypot(pointer.x - origin.x, pointer.y - origin.y) >= max(travel, 1)
    }

    /// Give up a contest without giving up the hold, for when the caller can no longer say what the
    /// pointer is over. Left standing, it would keep the loop awake for a settle that cannot end.
    public mutating func abandonContest() {
        pending = nil
        for (owner, hold) in holds where hold.unseenTravel {
            holds[owner] = hold.spent
        }
    }

    /// Drop everything about a process that exited; pids are recycled.
    public mutating func forget(owner: Int32) {
        holds[owner] = nil
        if pending?.owner == owner { pending = nil }
    }

    /// Record focus the agent moved by keyboard. Said rather than inferred: stepping between two
    /// windows of the app that already had focus changes nothing `sample` can see.
    public mutating func noteKeyboardFocus(
        anchor: Target?, number: Int?, pointer: CGPoint?, owner: Int32
    ) {
        holds[owner] = born(anchor: anchor, number: number, pointer: pointer)
        pending = nil
    }

    /// Baseline after the agent moved focus with the pointer, so the owner change on the next tick is
    /// not read as a handover. The pointer settling somewhere is what every hold was waiting for, so
    /// they all go, rather than accumulating for apps that never come forward again.
    public mutating func noteAppliedFocus(window: Target, owner: Int32) {
        last = Observation(window: window, hasFocus: true, owner: owner)
        holds = [:]
        pending = nil
    }

    public mutating func reset() {
        last = nil
        holds = [:]
        pending = nil
        lastAsked = nil
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
