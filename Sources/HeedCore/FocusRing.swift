import CoreGraphics
import Foundation

/// A window as the focus shortcuts see it. Frames are global, top-left origin: the space
/// Accessibility reports positions in and `CGDisplayBounds` reports screens in.
public struct RingWindow: Equatable, Sendable {
    public let frame: CGRect
    public let key: Int

    public init(frame: CGRect, key: Int) {
        self.frame = frame
        self.key = key
    }
}

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

/// The window server calls a window on screen while it is completely buried. Subtracting covers one
/// at a time gives an order-dependent answer, so the frame is cut into a grid along every cover edge
/// and the uncovered cells are measured as a region.
public func isVisible(
    _ frame: CGRect, behind covering: some Sequence<CGRect>, minimum: CGFloat = 40
) -> Bool {
    guard frame.width >= minimum, frame.height >= minimum else { return false }
    guard let (x, y, covered) = coverGrid(of: frame, behind: covering) else { return true }

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

public func ringStep(count: Int, from current: Int?, by delta: Int) -> Int? {
    guard count > 0 else { return nil }
    guard let current else { return delta >= 0 ? 0 : count - 1 }
    let stepped = (current + delta) % count
    return stepped < 0 ? stepped + count : stepped
}

/// The display a window mostly sits on, falling back to the nearest when none of it shows.
func screenIndex(for frame: CGRect, in screens: [CGRect]) -> Int {
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

public enum FocusDirection: String, Sendable, CaseIterable {
    case left, right, up, down
}

/// Candidates are the windows whose centre lies beyond the source centre along the axis. One
/// overlapping the source across the axis beats one that does not; among equals the nearest wins,
/// with `RingWindow.key` breaking ties. No wrapping: a dead end at the edge is information, and the
/// ring shortcuts already cover "keep going".
public func directionalStep(
    from source: CGRect, in windows: [RingWindow], _ direction: FocusDirection
) -> Int? {
    guard !source.isNull, !windows.isEmpty else { return nil }

    let horizontal = direction == .left || direction == .right
    let forward = direction == .right || direction == .down

    func along(_ frame: CGRect) -> CGFloat { horizontal ? frame.midX : frame.midY }
    func overlaps(_ frame: CGRect) -> Bool {
        horizontal
            ? frame.minY < source.maxY && frame.maxY > source.minY
            : frame.minX < source.maxX && frame.maxX > source.minX
    }

    var best: (aligned: Bool, gap: CGFloat, key: Int, index: Int)?
    for (index, window) in windows.enumerated() {
        let gap = along(window.frame) - along(source)
        guard forward ? gap > 0 : gap < 0 else { continue }

        let score = (aligned: overlaps(window.frame), gap: abs(gap), key: window.key, index: index)
        guard let standing = best else {
            best = score
            continue
        }
        if (!standing.aligned && score.aligned)
            || (standing.aligned == score.aligned
                && (score.gap, score.key) < (standing.gap, standing.key)) {
            best = score
        }
    }
    return best?.index
}
