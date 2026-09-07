import CoreGraphics
import Foundation

public struct NumberBadge: Equatable, Sendable {
    public let number: Int
    public let centre: CGPoint

    public init(number: Int, centre: CGPoint) {
        self.number = number
        self.centre = centre
    }
}

/// An exact match: the overlay is a picture of the numbered shortcuts, and holding anything extra
/// makes a combination they are not registered under, so the numbers would be a lie.
public func numbersArmed(
    pressed: Set<HotkeySpec.Modifier>, wanted: Set<HotkeySpec.Modifier>?
) -> Bool {
    guard let wanted, !wanted.isEmpty else { return false }
    return pressed == wanted
}

/// Windows past the ninth get none: the shortcuts stop at the digit keys, so there is nothing left
/// to press for them and a number nobody can type would only mislead.
public func numberBadges(at centres: [CGPoint], limit: Int = 9) -> [NumberBadge] {
    centres.prefix(max(limit, 0)).enumerated().map { index, centre in
        NumberBadge(number: index + 1, centre: centre)
    }
}

/// A badge at the plain centre lands on whatever is on top whenever a window is covered across its
/// middle, and then it labels the wrong window: a maximised browser with a terminal parked over it
/// keeps its edges showing, so it stays in the ring, but its centre is under the terminal. Placing
public func visibleCentre(of frame: CGRect, behind covering: some Sequence<CGRect>) -> CGPoint {
    let middle = CGPoint(x: frame.midX, y: frame.midY)
    guard frame.width > 0, frame.height > 0 else { return middle }

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
    guard !covers.isEmpty else { return middle }

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

    var best: (area: CGFloat, rect: CGRect)?
    for left in 0..<(x.count - 1) {
        var blocked = [Bool](repeating: false, count: y.count - 1)
        for right in (left + 1)..<x.count {
            for row in 0..<(y.count - 1) where covered[row][right - 1] { blocked[row] = true }
            let width = x[right] - x[left]

            var top = 0
            for row in 0...(y.count - 1) {
                guard row < y.count - 1, !blocked[row] else {
                    let height = y[row] - y[top]
                    let area = width * height
                    if height > 0, area > (best?.area ?? 0) {
                        best = (area, CGRect(x: x[left], y: y[top], width: width, height: height))
                    }
                    top = row + 1
                    continue
                }
            }
        }
    }
    guard let rect = best?.rect else { return middle }
    return CGPoint(x: rect.midX, y: rect.midY)
}
