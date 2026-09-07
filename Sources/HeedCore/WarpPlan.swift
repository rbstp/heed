import CoreGraphics
import Foundation

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

private func visiblePart(of frame: CGRect, on screens: [CGRect]) -> CGRect {
    guard !screens.isEmpty else { return frame }
    return screens[screenIndex(for: frame, in: screens)].intersection(frame)
}
