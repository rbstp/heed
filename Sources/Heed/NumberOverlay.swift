import AppKit
import HeedCore

/// The numbers shown over each window while the numbered shortcuts' modifier is held, so the window
/// to switch to can be read off the screen rather than counted.
///
/// One panel per badge rather than one sheet per screen: a panel is placed in global coordinates
/// without caring which display a window is on, and there are never more than nine. Main thread
/// only; `Agent` hops to it explicitly.
final class NumberOverlay {
    /// Big enough to read across a room, small enough not to bury a narrow window.
    private static let side: CGFloat = 56

    private var panels: [NSPanel] = []

    var isShowing: Bool { !panels.isEmpty }

    /// Replace whatever is on screen with these badges. Replacing rather than diffing: the whole set
    /// is rebuilt each time the ring is, and nine windows is not enough work to be worth matching up.
    func show(_ badges: [NumberBadge]) {
        dispatchPrecondition(condition: .onQueue(.main))
        hide()

        // Accessibility's frames have a top-left origin; AppKit places windows from the bottom left
        // of the display that owns (0, 0).
        let flip = CGDisplayBounds(CGMainDisplayID()).maxY
        for badge in badges {
            let side = NumberOverlay.side
            let frame = NSRect(x: badge.centre.x - side / 2, y: flip - badge.centre.y - side / 2,
                               width: side, height: side)
            panels.append(NumberOverlay.panel(showing: badge.number, at: frame))
        }
    }

    func hide() {
        dispatchPrecondition(condition: .onQueue(.main))
        for panel in panels { panel.orderOut(nil) }
        panels = []
    }

    private static func panel(showing number: Int, at frame: NSRect) -> NSPanel {
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.contentView = BadgeView(number: number)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Above ordinary windows but below menus, so a menu opened over one still reads first.
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        // Follows the user between Spaces, and stays out of Mission Control and Cmd-Tab.
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle,
                                    .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        // The panels are dropped by letting go of them, never closed; a window that releases itself
        // on close would then be over-released.
        panel.isReleasedWhenClosed = false
        // An LSUIElement app has nothing to take focus from, but a panel that could take it would
        // still put the keystroke the numbers are there to serve into itself.
        panel.orderFrontRegardless()
        return panel
    }

    /// The badge itself: a dark rounded tile with a light rim, which reads over a window of any
    /// colour without needing to know what is behind it.
    private final class BadgeView: NSView {
        private let number: Int

        init(number: Int) {
            self.number = number
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not loaded from a nib") }

        override func draw(_ dirtyRect: NSRect) {
            let rim: CGFloat = 2
            let tile = NSBezierPath(roundedRect: bounds.insetBy(dx: 3 + rim / 2, dy: 3 + rim / 2),
                                    xRadius: 14, yRadius: 14)
            NSColor(calibratedWhite: 0.07, alpha: 0.9).setFill()
            tile.fill()
            NSColor(calibratedWhite: 1, alpha: 0.55).setStroke()
            tile.lineWidth = rim
            tile.stroke()

            let digit = "\(number)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: BadgeView.font, .foregroundColor: NSColor.white,
            ]
            let size = digit.size(withAttributes: attributes)
            digit.draw(at: NSPoint(x: bounds.midX - size.width / 2,
                                   y: bounds.midY - size.height / 2),
                       withAttributes: attributes)
        }

        /// Rounded, to match the tile and the app's own mark. Falls back to the plain system face
        /// where the rounded design is not available.
        private static let font: NSFont = {
            let base = NSFont.systemFont(ofSize: 28, weight: .bold)
            guard let rounded = base.fontDescriptor.withDesign(.rounded) else { return base }
            return NSFont(descriptor: rounded, size: 28) ?? base
        }()
    }
}
