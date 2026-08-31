import AppKit
import FFMCore

/// The menu bar item: says whether focus is following the pointer, and toggles it when clicked.
///
/// Main thread only. The agent's state lives on its own queue and AppKit's lives here, so every
/// crossing between the two is an explicit hop -- `Agent.syncMenuBar` one way, the click handler
/// the other.
final class MenuBarController: NSObject {
    private let item: NSStatusItem
    private let onClick: () -> Void

    init(onClick: @escaping () -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        self.onClick = onClick
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        guard let button = item.button else { return }
        button.image = MenuBarController.icon()
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(clicked)
    }

    /// Removed explicitly rather than left to the item's own deallocation, which would give the
    /// slot up whenever the last reference happened to drop rather than now.
    func remove() {
        dispatchPrecondition(condition: .onQueue(.main))
        NSStatusBar.system.removeStatusItem(item)
    }

    /// What to show is decided by `MenuBarState` in FFMCore, where it is tested; this only applies
    /// the answer. AppKit's own disabled-control treatment does the dimming, so it matches every
    /// other menu bar item and follows appearance changes rather than an alpha of our own.
    func render(enabled: Bool, trusted: Bool) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let button = item.button else { return }

        let state = MenuBarState(enabled: enabled, trusted: trusted)
        button.appearsDisabled = state.dimmed
        button.toolTip = state.tooltip
        button.setAccessibilityLabel(state.label)
    }

    @objc private func clicked() {
        onClick()
    }

    /// The app icon's cube, reduced to what survives at menu bar size: the hexagon silhouette and
    /// the three edges meeting at its near corner, without which it reads as a plain hexagon.
    ///
    /// A template image, so AppKit inverts it for a light or dark menu bar instead of us shipping
    /// two. Drawn in code for the same reason `Tools/make-icon.swift` is, and the drawing handler
    /// is re-run per backing scale, so the strokes stay crisp on a Retina display rather than being
    /// a 16px bitmap doubled.
    private static func icon() -> NSImage {
        let side: CGFloat = 16
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            let r = side * 0.44
            let hw = r * 0.8660254   // cos 30
            let hh = r * 0.5
            func vertex(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
                NSPoint(x: side / 2 + x, y: side / 2 + y)
            }

            let path = NSBezierPath()
            path.lineWidth = 1.1
            path.lineJoinStyle = .round
            path.lineCapStyle = .round

            path.move(to: vertex(0, r))
            for corner in [vertex(hw, hh), vertex(hw, -hh), vertex(0, -r),
                           vertex(-hw, -hh), vertex(-hw, hh)] {
                path.line(to: corner)
            }
            path.close()

            // From the nearest corner to the two near edges of the top face and straight down the
            // front edge. Not to the top vertex: that draws a diagonal the cube does not have.
            for corner in [vertex(-hw, hh), vertex(hw, hh), vertex(0, -r)] {
                path.move(to: vertex(0, 0))
                path.line(to: corner)
            }

            NSColor.black.setStroke()
            path.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }
}
