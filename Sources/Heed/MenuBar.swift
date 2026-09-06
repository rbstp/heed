import AppKit
import FFMCore

/// The menu bar item. Main thread only; `Agent` hops to it explicitly.
final class MenuBarController: NSObject {
    private let item: NSStatusItem
    private let onClick: () -> Void
    private let onQuit: () -> Void
    private let onChooseModifier: (ModifierPreset) -> Void
    private var state = MenuBarState(enabled: true, trusted: true)
    /// The toggle hotkey, shown beside the menu item. Nil when none is registered.
    var shortcut: HotkeySpec?
    /// The modifier every shortcut is registered under. Nil when nothing is registered, or when it
    /// is a combination the menu does not offer.
    var modifiers: Set<HotkeySpec.Modifier>?
    private var flashRestore: DispatchWorkItem?

    init(
        onClick: @escaping () -> Void,
        onQuit: @escaping () -> Void,
        onChooseModifier: @escaping (ModifierPreset) -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        self.onClick = onClick
        self.onQuit = onQuit
        self.onChooseModifier = onChooseModifier
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        guard let button = item.button else { return }
        button.image = MenuBarController.icon()
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(clicked)
        // A status item button sends its action on left mouse up only unless asked.
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    func remove() {
        dispatchPrecondition(condition: .onQueue(.main))
        NSStatusBar.system.removeStatusItem(item)
    }

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

    /// The menu is assigned for the length of one click: a status item that owns a menu opens it on
    /// every click, which would cost the left-click toggle.
    private func showMenu() {
        guard let button = item.button else { return }
        item.menu = menu()
        button.performClick(nil)
        item.menu = nil
    }

    private func menu() -> NSMenu {
        let menu = NSMenu()

        menu.addItem(NSMenuItem(title: "Heed \(MenuBarController.version)", action: nil,
                                keyEquivalent: ""))
        menu.addItem(.separator())

        let toggle = NSMenuItem(title: state.toggleTitle, action: #selector(toggleFromMenu),
                                keyEquivalent: "")
        toggle.target = self
        // Only a single-character key renders as a key equivalent; F-keys and arrows would need the
        // NSxxxFunctionKey table.
        if let shortcut, shortcut.key.count == 1 {
            toggle.keyEquivalent = shortcut.key
            toggle.keyEquivalentModifierMask = MenuBarController.modifierMask(shortcut)
        }
        menu.addItem(toggle)

        let modifier = NSMenuItem(title: "Shortcut Modifier", action: nil, keyEquivalent: "")
        modifier.submenu = modifierMenu()
        menu.addItem(modifier)

        let log = NSMenuItem(title: "Open Log", action: #selector(openLog), keyEquivalent: "")
        log.target = self
        menu.addItem(log)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Heed", action: #selector(quitFromMenu),
                              keyEquivalent: "q")
        quit.target = self
        quit.toolTip = quitPlan.tooltip
        menu.addItem(quit)

        return menu
    }

    private func modifierMenu() -> NSMenu {
        let menu = NSMenu()
        let current = ModifierPreset.matching(modifiers)
        for (index, preset) in ModifierPreset.allCases.enumerated() {
            let item = NSMenuItem(title: preset.display, action: #selector(chooseModifier(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = preset == current ? .on : .off
            item.toolTip = [preset.spoken, preset.caution].compactMap { $0 }.joined(separator: ". ")
            menu.addItem(item)
        }
        return menu
    }

    @objc private func chooseModifier(_ sender: NSMenuItem) {
        let presets = ModifierPreset.allCases
        guard presets.indices.contains(sender.tag) else { return }
        onChooseModifier(presets[sender.tag])
    }

    /// Flash the icon green or red to say whether a change took. Refusal shows longer.
    func flash(accepted: Bool) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let button = item.button else { return }

        flashRestore?.cancel()
        button.image = MenuBarController.icon(accepted ? .systemGreen : .systemRed)

        let restore = DispatchWorkItem { [weak self] in
            self?.item.button?.image = MenuBarController.icon()
            self?.flashRestore = nil
        }
        flashRestore = restore
        DispatchQueue.main.asyncAfter(deadline: .now() + (accepted ? 0.7 : 1.3), execute: restore)
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

    @objc private func openLog() {
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Logs/heed.log")
        guard FileManager.default.fileExists(atPath: url.path) else {
            Log.note("no log at \(url.path) yet")
            return
        }
        NSWorkspace.shared.open(url)
    }

    private static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "(unpackaged)"
    }

    /// The app icon's cube at menu bar size, drawn per backing scale. A template image so AppKit
    /// inverts it for the menu bar; `colour` is only for the flash, and a coloured image cannot be a
    /// template because a template is a mask.
    private static func icon(_ colour: NSColor? = nil) -> NSImage {
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

            // The three edges meeting at the near corner, without which it reads as a hexagon.
            for corner in [vertex(-hw, hh), vertex(hw, hh), vertex(0, -r)] {
                path.move(to: vertex(0, 0))
                path.line(to: corner)
            }

            (colour ?? .black).setStroke()
            path.stroke()
            return true
        }
        image.isTemplate = colour == nil
        return image
    }
}
