import CoreGraphics
import Foundation

/// The order the focus shortcuts walk windows in, and where one step starts and lands.
///
/// Free of Accessibility and AppKit like the rest of this module: given a set of frames and the
/// screens they sit on, the answer is fixed, and this is the half that is easy to get quietly wrong.
///
/// Two separate questions here, and they take opposite answers.
///
/// **What is in the ring** is what you can see. A window buried behind others is not somewhere the
/// pointer could reach either, and stepping onto it would raise it over whatever you were looking
/// at -- so a stack of ten maximised windows on one screen is one entry, not ten. `isVisible`
/// answers that, and it is the only thing here that consults what is in front of what.
///
/// **The order they are visited in** is spatial, never a stacking order. Focusing a window raises
/// it, so an order derived from what is in front would be rewritten by the very act of stepping
/// through it: press "next" twice and you would be back where you started. Position does not move
/// when focus does, so walking the ring visits every window exactly once and comes back round --
/// which is the whole of what the shortcut promises.

/// A window as the ring sees it.
public struct RingWindow: Equatable, Sendable {
    /// Global screen coordinates with a top-left origin -- the space Accessibility reports window
    /// positions in, and the one `CGDisplayBounds` reports screens in.
    public let frame: CGRect
    /// Stable, unique identity, used only to break ties. Two windows sharing an origin -- stacked
    /// exactly, or both maximised -- must keep a fixed order rather than swapping places between
    /// presses, which would strand one of them. Lower sorts first, so the caller passing the window
    /// server's number gets the older window first, which is at least explicable.
    public let key: Int

    public init(frame: CGRect, key: Int) {
        self.frame = frame
        self.key = key
    }
}

/// Sort windows into the ring: screen by screen from left to right, and within each screen left to
/// right, then top to bottom.
///
/// Screens are ordered by where they are rather than by the order the system lists them in, so the
/// ring runs the way the displays are actually arranged on the desk.
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

/// Whether a window shows past the windows drawn in front of it.
///
/// The window server will call a window "on screen" while it is completely buried behind others: it
/// is in this Space and not minimized, which is a different question from whether you can see it.
/// Two side-by-side windows tiling a display cover whatever is behind them exactly, and everything
/// behind them belongs in the ring no more than a window on another Space does.
///
/// "Shows" means a patch you could see and point at, not a sliver. Tiled windows meet along an edge
/// where a point of rounding either way is arbitrary, and a hairline of a buried window peeking out
/// must not put the whole of it back in the ring. `minimum` is that threshold, applied to both sides
/// of an uncovered rectangle -- the same size the window policy calls too small to be a window.
///
/// - Parameter covering: the frames drawn in front of this one, which is the order the window server
///   lists windows in. Whoever owns them: a window hides what is behind it whether or not the ring
///   would ever accept it as a target itself.
public func isVisible(_ frame: CGRect, behind covering: [CGRect], minimum: CGFloat = 40) -> Bool {
    guard frame.width >= minimum, frame.height >= minimum else { return false }

    // Cut the window along every edge the windows in front of it introduce, then ask whether any
    // block of cells none of them touches is large enough to see.
    //
    // Subtracting the covers one at a time and measuring the pieces that survive is the obvious way
    // to do this, and it is wrong. The pieces are whatever the order of the cuts happened to
    // produce, so one wide uncovered region gets sliced by a cut somewhere else entirely into parts
    // that are each too small while the region itself is not -- and the answer then depends on the
    // order the covers arrived in, which is nothing to do with what is visible. The grid asks about
    // the region rather than about the pieces.
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

    // Widen a span of columns one at a time, carrying which rows it has run into something covered
    // in, and measure the tallest unbroken stretch of the rest.
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

/// Where a step should start from.
///
/// `live` is where the system says focus is, as an index into the ring, and it is the authority
/// whenever it has caught up. `lastStep` covers the case where it has not. Asking an app to focus
/// one of its own windows is not always answered at once, and some apps raise a window without ever
/// moving key focus to it at all -- and there the live answer would never catch up, so holding the
/// key down would step onto one window and stay there for good.
///
/// So while the live answer still names the window the last step moved *away* from, that step is
/// the newer news and the next one goes on from where it landed. The moment the live answer names
/// anything else, something other than the shortcut has moved focus and it wins.
public func ringStart<Window: Equatable>(
    in ring: [Window], live: Int?, lastStep: (from: Window?, to: Window)?
) -> Int? {
    guard let lastStep, let aimed = ring.firstIndex(of: lastStep.to),
          live.map({ ring[$0] }) == lastStep.from
    else { return live }
    return aimed
}

/// Where a step of `delta` lands, wrapping at both ends.
///
/// `current` is nil when focus is nowhere the ring can place it. Stepping forward from nowhere lands
/// on the first window and backward on the last, so the shortcut still works from wherever focus
/// happens to be rather than refusing until it is somewhere recognised.
public func ringStep(count: Int, from current: Int?, by delta: Int) -> Int? {
    guard count > 0 else { return nil }
    guard let current else { return delta >= 0 ? 0 : count - 1 }
    let stepped = (current + delta) % count
    return stepped < 0 ? stepped + count : stepped
}

/// Which screen a window belongs to: the one it overlaps most.
///
/// When it overlaps none -- dragged almost entirely off an edge, or left behind by a display that
/// was just unplugged -- the nearest one by centre. Never "no screen": a window dropped from the
/// ring could not be reached by the shortcut at all, which is a worse answer than an order that is
/// merely surprising.
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
