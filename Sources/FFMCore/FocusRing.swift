import CoreGraphics
import Foundation

/// A window as the focus shortcuts see it. Frames are global, top-left origin: the space
/// Accessibility reports positions in and `CGDisplayBounds` reports screens in.
public struct RingWindow: Equatable, Sendable {
    public let frame: CGRect
    /// Tie-breaker for windows sharing an origin; lower sorts first.
    public let key: Int

    public init(frame: CGRect, key: Int) {
        self.frame = frame
        self.key = key
    }
}

/// Ring order: screens left to right, then within each screen left to right, top to bottom.
///
/// Spatial rather than stacking order on purpose: focusing raises, so a stacking order would be
/// rewritten by the act of stepping through it.
public func ringOrder(_ windows: [RingWindow], screens: [CGRect]) -> [RingWindow] {
    let ordered = screens.sorted { ($0.origin.x, $0.origin.y) < ($1.origin.x, $1.origin.y) }
    return windows
        .map { (screen: screenIndex(for: $0.frame, in: ordered), window: $0) }
        .sorted {
            ($0.screen, $0.window.frame.origin.x, $0.window.frame.origin.y, $0.window.key)
                < ($1.screen, $1.window.frame.origin.x, $1.window.frame.origin.y, $1.window.key)
        }
        .map(\.window)
}

/// Whether at least a `minimum` by `minimum` patch of `frame` shows past the windows in front of it.
///
/// The window server calls a window on screen while it is completely buried. Subtracting covers one
/// at a time gives an order-dependent answer, so the frame is cut into a grid along every cover edge
/// and the uncovered cells are measured as a region.
public func isVisible(
    _ frame: CGRect, behind covering: some Sequence<CGRect>, minimum: CGFloat = 40
) -> Bool {
    guard frame.width >= minimum, frame.height >= minimum else { return false }

    var columns: Set<CGFloat> = [frame.minX, frame.maxX]
    var rows: Set<CGFloat> = [frame.minY, frame.maxY]
    var covers: [CGRect] = []
    for cover in covering {
        let overlap = cover.intersection(frame)
        guard !overlap.isNull, !overlap.isEmpty else { continue }
        covers.append(overlap)
        columns.insert(overlap.minX)
        columns.insert(overlap.maxX)
        rows.insert(overlap.minY)
        rows.insert(overlap.maxY)
    }
    guard !covers.isEmpty else { return true }

    let x = columns.sorted()
    let y = rows.sorted()
    var covered = [[Bool]](repeating: [Bool](repeating: false, count: x.count - 1),
                           count: y.count - 1)
    for cover in covers {
        for row in 0..<(y.count - 1) where y[row] >= cover.minY && y[row + 1] <= cover.maxY {
            for column in 0..<(x.count - 1)
            where x[column] >= cover.minX && x[column + 1] <= cover.maxX {
                covered[row][column] = true
            }
        }
    }

    // Widen a span of columns one at a time, and measure the tallest unbroken run of rows in it.
    for left in 0..<(x.count - 1) {
        var blocked = [Bool](repeating: false, count: y.count - 1)
        for right in (left + 1)..<x.count {
            for row in 0..<(y.count - 1) where covered[row][right - 1] { blocked[row] = true }
            guard x[right] - x[left] >= minimum else { continue }

            var tall: CGFloat = 0
            for row in 0..<(y.count - 1) {
                guard !blocked[row] else {
                    tall = 0
                    continue
                }
                tall += y[row + 1] - y[row]
                if tall >= minimum { return true }
            }
        }
    }
    return false
}

/// Where a step starts. `live` is the system's answer and wins whenever it has caught up; while it
/// still names the window the last step moved away from, the step is the newer news. Some apps
/// raise a window without ever moving key focus to it, so without this a held key would stall.
public func ringStart<Window: Equatable>(
    in ring: [Window], live: Int?, lastStep: (from: Window?, to: Window)?
) -> Int? {
    guard let lastStep, let aimed = ring.firstIndex(of: lastStep.to),
          live.map({ ring[$0] }) == lastStep.from
    else { return live }
    return aimed
}

/// Where a step of `delta` lands, wrapping at both ends. From nowhere, forward lands on the first
/// window and backward on the last.
public func ringStep(count: Int, from current: Int?, by delta: Int) -> Int? {
    guard count > 0 else { return nil }
    guard let current else { return delta >= 0 ? 0 : count - 1 }
    let stepped = (current + delta) % count
    return stepped < 0 ? stepped + count : stepped
}

/// The screen a window overlaps most, or the nearest by centre when it overlaps none. Never "no
/// screen": a window dropped from the ring could not be reached at all.
private func screenIndex(for frame: CGRect, in screens: [CGRect]) -> Int {
    guard !screens.isEmpty else { return 0 }

    var best = 0
    var bestArea: CGFloat = 0
    for (index, screen) in screens.enumerated() {
        let overlap = screen.intersection(frame)
        let area = overlap.isNull ? 0 : overlap.width * overlap.height
        if area > bestArea {
            bestArea = area
            best = index
        }
    }
    if bestArea > 0 { return best }

    var nearest = 0
    var shortest = CGFloat.greatestFiniteMagnitude
    for (index, screen) in screens.enumerated() {
        let distance = hypot(screen.midX - frame.midX, screen.midY - frame.midY)
        if distance < shortest {
            shortest = distance
            nearest = index
        }
    }
    return nearest
}
