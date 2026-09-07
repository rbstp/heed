import CoreGraphics

/// `frame` cut into a grid along every covering edge, with the cells something in front covers
/// marked. Nil when nothing covers it, which each caller answers for itself.
func coverGrid(
    of frame: CGRect, behind covering: some Sequence<CGRect>
) -> (x: [CGFloat], y: [CGFloat], covered: [[Bool]])? {
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
    guard !covers.isEmpty else { return nil }

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
    return (x, y, covered)
}
