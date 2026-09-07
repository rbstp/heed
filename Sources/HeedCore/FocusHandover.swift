import CoreGraphics
import Foundation

/// Holds focus that arrived without the pointer until the pointer travels to another window and
/// rests there. The window server cannot answer this: its frontmost window misses focus changes
/// that reorder nothing.
public struct FocusHandover<Target: Equatable> {
    public var settle: Double

    public var travel: Double

    private var last: Observation?
    /// Keyed per pid: which hold applies depends on who has focus when the question is asked.
    private var holds: [Int32: Hold] = [:]
    private var pending: Pending?
    private var lastAsked: CGPoint?

    private struct Observation {
        let window: Target?
        let hasFocus: Bool?
        let owner: Int32
    }

    private struct Hold {
        let anchor: Target?
        /// The window server's number, not a frame: it survives the window moving and tells
        /// overlapping windows apart.
        let number: Int?
        let pointer: CGPoint?
        var left = false
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
        var restingSince: Double?
    }

    public init(settle: Double, travel: Double = 0) {
        self.settle = settle
        self.travel = travel
    }

    public var isHolding: Bool { !holds.isEmpty }

    public func isHolding(owner: Int32) -> Bool { holds[owner] != nil }

    public var isSettling: Bool { pending != nil }

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

        // Focus already elsewhere for the same window and holder is a failed focus attempt, not a
        // handover, and must stay retryable.
        guard let previous,
              previous.hasFocus == true || previous.window != window || previous.owner != owner
        else { return false }

        holds[owner] = born(anchor: anchor, number: number(), pointer: pointer, after: holds[owner])
        pending = nil
        return true
    }

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
            // A window that came to a still pointer is not an entry.
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
        // Movement that never left the anchor is not travel to find later.
        if accounted { lastAsked = pointer }
    }

    private mutating func born(
        anchor: Target?, number: Int?, pointer: CGPoint?, after standing: Hold? = nil
    ) -> Hold {
        lastAsked = pointer
        return Hold(anchor: anchor, number: anchor == nil ? nil : number, pointer: pointer,
                    left: standing?.left ?? false, unseenTravel: standing?.unseenTravel ?? false)
    }

    private func moved(from origin: CGPoint?, to pointer: CGPoint?) -> Bool {
        guard let origin, let pointer else { return false }
        return hypot(pointer.x - origin.x, pointer.y - origin.y) >= max(travel, 1)
    }

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

    public mutating func noteKeyboardFocus(
        anchor: Target?, number: Int?, pointer: CGPoint?, owner: Int32
    ) {
        holds[owner] = born(anchor: anchor, number: number, pointer: pointer)
        pending = nil
    }

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
    case free
    case hold
    case entered
}
