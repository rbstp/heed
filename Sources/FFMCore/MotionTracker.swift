/// A sliding-window sum of recent pointer movement.
///
/// Used to tell two situations apart that look identical to a single hit test: the pointer moving
/// onto a different window, and a different window arriving underneath a pointer that is sitting
/// still. Only the first should move focus. Comparing against a single tick's movement is not
/// enough -- a slow, deliberate crossing moves only a pixel or two per tick -- so movement is
/// accumulated over a short window instead.
public struct MotionTracker {
    private var samples: [Double] = []
    private let capacity: Int

    /// - Parameter capacity: how many ticks to remember. Kept in ticks rather than seconds so the
    ///   window scales with the poll interval.
    public init(capacity: Int) {
        self.capacity = max(1, capacity)
        samples.reserveCapacity(self.capacity)
    }

    public mutating func record(_ distance: Double) {
        samples.append(distance)
        if samples.count > capacity {
            samples.removeFirst(samples.count - capacity)
        }
    }

    /// Distance covered over the remembered window.
    public var total: Double {
        samples.reduce(0, +)
    }

    public mutating func reset() {
        samples.removeAll(keepingCapacity: true)
    }
}
