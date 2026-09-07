/// A sliding-window sum of recent pointer movement, in ticks so it scales with the poll interval.
///
/// Tells the pointer moving onto a window from a window arriving under a still pointer: a slow
/// crossing moves a pixel or two per tick, so one tick's movement is not enough to go on.
public struct MotionTracker {
    private var samples: [Double] = []
    private let capacity: Int

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
        samples.reserveCapacity(self.capacity + 1)
    }

    /// Non-finite distances count as no movement; a NaN would defeat every threshold comparison.
    public mutating func record(_ distance: Double) {
        samples.append(distance.isFinite ? distance : 0)
        if samples.count > capacity { samples.removeFirst() }
    }

    public var total: Double { samples.reduce(0, +) }

    public mutating func reset() {
        samples.removeAll(keepingCapacity: true)
    }
}
