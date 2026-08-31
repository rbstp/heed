import AppKit

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

    func render(enabled: Bool, trusted: Bool) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let button = item.button else { return }

        // Dimmed whenever the pointer moves nothing, which includes waiting for the Accessibility
        // grant -- an undimmed icon there would claim the agent was working when it cannot.
        //
        // AppKit's own disabled-control treatment rather than an alpha of our own, so it matches
        // every other menu bar item and follows appearance changes.
        button.appearsDisabled = !(enabled && trusted)

        // The switch and the grant are separate facts and the icon can only show one of them, so
        // the tooltip carries both -- but only while it is on. Off, nothing re-checks the grant,
        // because that only happens on a tick and there are no ticks; naming it here would leave
        // the tooltip claiming a missing permission for as long as the agent stayed off, long after
        // it had been granted. Off explains the dimming on its own, and clicking on re-reads the
        // grant before this runs again.
        var help = enabled ? "Heed is on. Click to turn it off." : "Heed is off. Click to turn it on."
        if enabled, !trusted {
            help += " It also needs Accessibility permission, from"
                + " System Settings > Privacy & Security > Accessibility."
        }
        button.toolTip = help
        button.setAccessibilityLabel("Heed, \(enabled ? "on" : "off")")
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
