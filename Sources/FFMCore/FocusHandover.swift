/// Focus that arrived without the pointer, and what the pointer has to do to overrule it.
///
/// Focus follows the pointer — but not everything that takes focus was asked for by the pointer. A
/// new window opens, a shortcut raises a window that was already behind others, ⌘-Tab switches away:
/// each of those is the user handing focus somewhere deliberately, and a pointer that has not moved
/// since has said nothing at all. Left to itself the loop takes that focus straight back, and the
/// first line typed into the new window lands in the old one.
///
/// This is the half the entry-motion guard cannot see. Nothing arrived *under* the pointer, so there
/// is no arrival to reject: the pointer is resting on the window it was already resting on, and what
/// changed happened somewhere else on screen.
///
/// **The signal is the agent's own question, asked once a tick: does the window under the pointer
/// hold focus?** When that answer stops being yes while the pointer has not moved, something other
/// than the pointer moved focus — nothing else can have, because the pointer is the only thing this
/// agent moves focus for. Asking it that way needs no notion of *what* moved focus, and no window
/// list: an earlier version watched which window was frontmost in the window server, which cannot
/// see focus changes that reorder nothing, cannot see key panels above the ordinary window level,
/// and cannot be matched to an Accessibility element without the private call this program avoids.
///
/// The same question also answers the other way the world moves without the pointer: a *different*
/// window arriving under a still pointer, which is what a Space switch does to every window at once.
/// Both are "the world changed, not the pointer", and both earn a hold.
///
/// Free of platform APIs like the rest of FFMCore, so the parts that are easy to get wrong can be
/// tested directly: a first look must not read as a handover, focus never having arrived must not
/// read as focus having left, and crossing a window on the way somewhere must not count as arriving.
public struct FocusHandover<Target: Equatable> {
    /// How long the pointer must be at **rest** on another window before it overrules a hold.
    ///
    /// Two things this is deliberately not. It is not "touched another window": reaching a window on
    /// another display means crossing whatever lies between, and each crossing would take the focus
    /// you were walking towards — and once focus moves, that app comes forward and buries the window
    /// you were walking to, so it can no longer be reached by pointer at all. And it is not "was
    /// over another window for a while": crossing one maximised window takes longer than any settle
    /// worth having, so time alone cannot tell travelling from arriving. Only stopping can.
    public var settle: Double

    /// The previous answer, the window it was asked about, and who held focus at the time.
    ///
    /// All three matter. An answer about window A says nothing about whether window C ever held
    /// focus, and reading it as if it did turns every failed focus attempt into a handover — which
    /// would hold focus away from the very window being focused, and stop the retry. And focus
    /// moving on from one app to another while the pointer stays parked is a second handover, which
    /// a bare yes/no could not see because the answer was already no.
    private var last: (window: Target, hasFocus: Bool, owner: Int32)?

    /// What the pointer was over when each app was handed focus, keyed by that app.
    ///
    /// Keyed per app rather than held as one slot because the answer depends on which app holds
    /// focus when the question is asked, and that can change back and forth without the pointer
    /// moving at all.
    private var anchors: [Int32: Target] = [:]

    /// The window the pointer is contesting a hold on, and when it last came to rest there.
    /// `restingSince` is nil while the pointer is still travelling across it.
    private var pending: Pending?

    private struct Pending {
        /// Whose hold is being contested. Credit earned against one holder is not credit against
        /// the next: without this, resting on B while P held focus and then ⌘-Tabbing to Q let Q's
        /// brand-new hold be overruled instantly by time banked before Q existed.
        let owner: Int32
        let target: Target
        var restingSince: Double?
    }

    public init(settle: Double) {
        self.settle = settle
    }

    /// Whether anything is being held. Lets the caller skip the live lookups its answer needs.
    public var isHolding: Bool { !anchors.isEmpty }

    /// Whether a hold is being contested right now, so the caller knows to keep asking.
    ///
    /// True from the moment the pointer resolves some other window, not merely once it has stopped
    /// there. Narrowing this to "the clock is running" deadlocked: a pointer that has come to rest
    /// produces no hit test of its own, so nothing asked again, so the clock never started and focus
    /// never moved. It is bounded all the same — the pointer is either travelling, which produces
    /// hit tests anyway, or resting out a settle that ends.
    public var isSettling: Bool { pending != nil }

    /// Fold in whether the window under the pointer holds focus.
    ///
    /// - Parameters:
    ///   - window: the window under the pointer, or nil when there is none this agent would focus.
    ///   - hasFocus: whether that window holds focus, or nil when the caller did not ask. Either nil
    ///     re-establishes a baseline rather than reading as a handover.
    ///   - owner: the process that holds focus now.
    ///   - pointerMoved: whether the pointer moved on this sample. A moving pointer explains the
    ///     answer changing all by itself, so nothing is read into it — and the caller is expected to
    ///     skip the live lookup entirely and pass nil for `hasFocus`, since this is the common case
    ///     and the lookup is not free.
    /// - Returns: true when this sample recorded a handover, so the caller can re-derive.
    @discardableResult
    public mutating func sample(
        window: Target?, hasFocus: Bool?, owner: Int32?, pointerMoved: Bool
    ) -> Bool {
        let previous = last

        guard !pointerMoved, let window, let hasFocus, let owner else {
            last = nil
            return false
        }
        last = (window, hasFocus, owner)

        // Focus is where the pointer is: nothing to hold, and nothing to hold it against.
        guard !hasFocus else { return false }

        // A first look cannot tell a handover from the way things already were. And focus that was
        // *already* elsewhere, for this same window and the same holder, has not just left -- that
        // is the agent trying and failing to focus it, which must stay retryable rather than
        // becoming a hold. Anything else that changed did so without the pointer.
        guard let previous,
              previous.hasFocus || previous.window != window || previous.owner != owner
        else { return false }

        anchors[owner] = window
        // Credit earned against whoever held focus before is not credit against this holder.
        pending = nil
        return true
    }

    /// What the pointer may do about `target` while `frontmost` holds focus.
    ///
    /// - Parameters:
    ///   - pointerMoved: whether the pointer itself moved on this sample. This, and not accumulated
    ///     travel, is what tells a window the pointer moved onto from a window that appeared
    ///     underneath it — the accumulated kind still reads as movement for a fifth of a second
    ///     after the pointer stops, which is long enough for a pop-up to be mistaken for an entry.
    ///   - travelling: whether the pointer has travelled recently, by whatever measure the caller's
    ///     entry guard uses. The settle clock runs only while this is false.
    public mutating func decide(
        for target: Target, frontmost: Int32, pointerMoved: Bool, travelling: Bool, at now: Double
    ) -> HandoverDecision {
        guard let anchor = anchors[frontmost] else {
            pending = nil
            return .free
        }
        // Still where it was when that app was handed focus, so it has asked for nothing. Movement
        // *within* that window says nothing either, which is the point: you should be able to nudge
        // the mouse while typing into what just opened.
        guard anchor != target else {
            pending = nil
            return .hold
        }

        if pending?.target != target || pending?.owner != frontmost {
            // The pointer itself has to have moved onto this window. A window that appears under a
            // pointer which is not moving -- a pop-up, or the whole screen changing on a Space
            // switch -- came to the pointer, and no amount of waiting turns that into an entry.
            guard pointerMoved else {
                pending = nil
                return .hold
            }
            pending = Pending(owner: frontmost, target: target, restingSince: nil)
        }

        // Still travelling. Crossing a window is not arriving at it, however long the crossing
        // takes, so the clock does not start until the pointer stops -- and starts over if it
        // moves on again.
        if travelling {
            pending?.restingSince = nil
            return .hold
        }
        if pending?.restingSince == nil { pending?.restingSince = now }
        guard let since = pending?.restingSince, now - since >= settle else { return .hold }

        // Travelled here and stopped. That is an entry, and a better-evidenced one than the entry
        // guard can manage on its own: it watched the pointer arrive in motion and then come to
        // rest, over a longer window than recent motion covers. So the hold is spent -- not paused,
        // because a hold that came back when the pointer returned would make focus depend on where
        // the pointer had been rather than where it is.
        anchors[frontmost] = nil
        pending = nil
        return .entered
    }

    /// Give up a contest in progress without giving up the hold, for when the caller can no longer
    /// say what the pointer is over: the window closed, the pointer reached the desktop,
    /// Accessibility stopped answering. Leaving it in place would ask the caller to keep forcing hit
    /// tests for a settle that can never complete, which is a loop that never idles again.
    public mutating func abandonContest() {
        pending = nil
    }

    /// Drop everything remembered about a process, for when it exits. Process identifiers are
    /// recycled, and a hold left behind by a dead one would be applied to whatever inherits its
    /// number — as well as keeping that process's window references alive for no reason.
    public mutating func forget(owner: Int32) {
        anchors[owner] = nil
        if pending?.owner == owner { pending = nil }
    }

    /// Forget the previous answer, so the next sample only re-establishes a baseline, and drop every
    /// hold. For the moments when the agent stops being able to speak for the recent past at all —
    /// being switched off and on again, or reconfigured.
    public mutating func reset() {
        last = nil
        anchors = [:]
        pending = nil
    }
}

public enum HandoverDecision: Equatable, Sendable {
    /// Nothing is held for the app that has focus; the ordinary guards decide.
    case free
    /// Focus stays where it was handed. Do nothing.
    case hold
    /// The pointer travelled to this window and settled on it. Focus it, and take the entry as
    /// proven: the settle period is the evidence, and by now recent motion has decayed away.
    case entered
}
