import CoreGraphics
import Foundation

/// Where the pointer should land inside a window that just took keyboard focus. Global top-left
/// coordinates, the space Accessibility, `CGDisplayBounds` and `CGWarpMouseCursorPosition` share.
///
/// Nil leaves the pointer alone: no frame, the pointer already inside the window, or nothing of the
/// window on any display. The percentages are read against the window, then clamped a couple of
/// pixels inside the part of it a display shows.
public func warpPoint(
    into frame: CGRect, xPercent: Int, yPercent: Int, pointer: CGPoint?, screens: [CGRect]
) -> CGPoint? {
    guard !frame.isNull, !frame.isEmpty,
          frame.origin.x.isFinite, frame.origin.y.isFinite,
          frame.width.isFinite, frame.height.isFinite
    else { return nil }
    if let pointer, pointer.x.isFinite, pointer.y.isFinite, frame.contains(pointer) { return nil }

    let visible = visiblePart(of: frame, on: screens)
    guard !visible.isEmpty else { return nil }

    let x = frame.minX + frame.width * CGFloat(min(max(xPercent, 0), 100)) / 100
    let y = frame.minY + frame.height * CGFloat(min(max(yPercent, 0), 100)) / 100

    let margin: CGFloat = 2
    let safe = visible.insetBy(
        dx: min(margin, max(0, visible.width / 2 - 0.5)),
        dy: min(margin, max(0, visible.height / 2 - 0.5))
    )
    return CGPoint(x: min(max(x, safe.minX), safe.maxX), y: min(max(y, safe.minY), safe.maxY))
}

/// The part of a window the display showing most of it can show. No displays reported means nothing
/// to clamp against, so the frame stands; overlapping none of them is off the world.
private func visiblePart(of frame: CGRect, on screens: [CGRect]) -> CGRect {
    guard !screens.isEmpty else { return frame }

    var best = CGRect.null
    var bestArea: CGFloat = 0
    for screen in screens {
        let overlap = screen.intersection(frame)
        guard !overlap.isNull else { continue }
        let area = overlap.width * overlap.height
        if area > bestArea {
            bestArea = area
            best = overlap
        }
    }
    return best
}
