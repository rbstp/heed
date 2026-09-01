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
    private let onQuit: () -> Void
    private var state = MenuBarState(enabled: true, trusted: true)
    /// The registered hotkey, shown beside the toggle so the menu is where you find out it exists.
    /// Nil when none is registered.
    var shortcut: HotkeySpec?

    init(onClick: @escaping () -> Void, onQuit: @escaping () -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        self.onClick = onClick
        self.onQuit = onQuit
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        guard let button = item.button else { return }
        button.image = MenuBarController.icon()
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(clicked)
        // Right-click has to be asked for; a status item button sends its action on left mouse up
        // only. Control-click arrives as an ordinary left click carrying the modifier, so both are
        // sorted out in `clicked`.
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
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

        state = MenuBarState(enabled: enabled, trusted: trusted)
        button.appearsDisabled = state.dimmed
        button.toolTip = state.tooltip
        button.setAccessibilityLabel(state.label)
    }

    @objc private func clicked() {
        let event = NSApp.currentEvent
        let secondary = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true
        if secondary {
            showMenu()
        } else {
            onClick()
        }
    }

    /// The menu exists for what a one-button switch cannot say: which version is running, that the
    /// icon is a switch at all, where the log is, and how to leave.
    ///
    /// Assigned to the item and taken away again rather than left in place, because a status item
    /// that owns a menu opens it on every click -- which would cost the left-click toggle. Handing
    /// it over for the length of one click is what gets AppKit's own placement and highlighting
    /// instead of a popover positioned by hand.
    private func showMenu() {
        guard let button = item.button else { return }
        item.menu = menu()
        button.performClick(nil)
        item.menu = nil
    }

    private func menu() -> NSMenu {
        let menu = NSMenu()

        // No action, so AppKit's automatic enabling greys it out: a heading, not a command.
        menu.addItem(NSMenuItem(title: "Heed \(MenuBarController.version)", action: nil,
                                keyEquivalent: ""))
        menu.addItem(.separator())

        let toggle = NSMenuItem(title: state.toggleTitle, action: #selector(toggleFromMenu),
                                keyEquivalent: "")
        toggle.target = self
        // Only for a key AppKit can render from a single character. An F-key or an arrow needs the
        // NSxxxFunctionKey constants, and a menu is not worth a second key table -- the log and the
        // README name the combination in every case.
        if let shortcut, shortcut.key.count == 1 {
            toggle.keyEquivalent = shortcut.key
            toggle.keyEquivalentModifierMask = MenuBarController.modifierMask(shortcut)
        }
        menu.addItem(toggle)

        let log = NSMenuItem(title: "Open Log", action: #selector(openLog), keyEquivalent: "")
        log.target = self
        menu.addItem(log)

        menu.addItem(.separator())

        // Last and separated, where every other Mac app keeps it, with the ⌘Q that matches. What
        // quitting costs is not the same in both cases -- installed, it takes the login agent with
        // it until the next login -- so the tooltip comes from `QuitPlan`, which is also what
        // decides how it is done.
        let quit = NSMenuItem(title: "Quit Heed", action: #selector(quitFromMenu),
                              keyEquivalent: "q")
        quit.target = self
        quit.toolTip = quitPlan.tooltip
        menu.addItem(quit)

        return menu
    }

    private static func modifierMask(_ spec: HotkeySpec) -> NSEvent.ModifierFlags {
        var mask: NSEvent.ModifierFlags = []
        if spec.modifiers.contains(.command) { mask.insert(.command) }
        if spec.modifiers.contains(.control) { mask.insert(.control) }
        if spec.modifiers.contains(.option) { mask.insert(.option) }
        if spec.modifiers.contains(.shift) { mask.insert(.shift) }
        return mask
    }

    @objc private func toggleFromMenu() {
        onClick()
    }

    @objc private func quitFromMenu() {
        onQuit()
    }

    /// The agent's only output. Opens in whatever handles .log, which is Console by default.
    @objc private func openLog() {
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Logs/heed.log")
        guard FileManager.default.fileExists(atPath: url.path) else {
            Log.note("no log at \(url.path) yet")
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// The bundle's version, or a marker when there is no bundle -- running straight out of
    /// `.build`, where claiming a version would be a small lie.
    private static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "(unpackaged)"
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
