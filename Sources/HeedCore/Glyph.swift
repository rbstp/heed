import CoreGraphics

/// Geometry only, so the menu bar item and the app icon draw the same shape from one description.
/// CoreGraphics rather than AppKit keeps this module free of the frameworks the agent needs.
public enum Glyph: Equatable, Sendable {
    case attending
    /// The chevrons alone: Heed is off. A shape difference as well as the dimming, which also stands
    /// for "no Accessibility permission".
    case idle
}

/// One fillable path rather than a stroke and a fill: a caller drawing a menu bar template image
/// has nothing but a mask to fill, and stroking here means both callers get identical ink.
public func glyphPath(_ glyph: Glyph, side: CGFloat) -> CGPath {
    // Ninths and eighteenths, so an 18pt menu bar image lands every edge on a whole pixel and the
    // mark stays crisp on a 1x display. These are centre lines: a round stroke puts the ink half a
    // width beyond each end, which is what leaves the gap between a chevron and the core.
    let width = side / 9
    let across = side / 9      // how far a chevron's tails sit either side of its axis
    let back = side * 5 / 18   // from the centre to where a chevron opens
    let tip = side * 7 / 18    // from the centre to where it points
    let middle = side / 2

    let chevrons = CGMutablePath()
    for (dx, dy) in [(1.0, 0.0), (-1.0, 0.0), (0.0, 1.0), (0.0, -1.0)] {
        let sideways = CGPoint(x: CGFloat(dy) * across, y: CGFloat(dx) * across)
        let opening = CGPoint(x: middle + CGFloat(dx) * back, y: middle + CGFloat(dy) * back)
        chevrons.move(to: CGPoint(x: opening.x + sideways.x, y: opening.y + sideways.y))
        chevrons.addLine(to: CGPoint(x: middle + CGFloat(dx) * tip, y: middle + CGFloat(dy) * tip))
        chevrons.addLine(to: CGPoint(x: opening.x - sideways.x, y: opening.y - sideways.y))
    }

    let path = CGMutablePath()
    path.addPath(chevrons.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round,
                               miterLimit: 10))
    if glyph == .attending {
        let core = side * 2 / 9
        path.addPath(CGPath(
            roundedRect: CGRect(x: (side - core) / 2, y: (side - core) / 2,
                                width: core, height: core),
            cornerWidth: core * 0.3, cornerHeight: core * 0.3, transform: nil
        ))
    }
    return path
}
