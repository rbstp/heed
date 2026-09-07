import AppKit
import HeedCore

/// The menu bar item. Main thread only; `Agent` hops to it explicitly.
final class MenuBarController: NSObject {
    private let item: NSStatusItem
    private let onClick: () -> Void
    private let onQuit: () -> Void
    private let onChooseModifier: (ModifierPreset) -> Void
    private let onToggleNumbers: () -> Void
    private var state = MenuBarState(enabled: true, trusted: true)
    /// Whether the window numbers are switched on, for the check beside the menu item.
    var showsNumbers = true
    /// The toggle hotkey, shown beside the menu item. Nil when none is registered.
    var shortcut: HotkeySpec?
    /// The modifier every shortcut is registered under. Nil when nothing is registered, or when it
    /// is a combination the menu does not offer.
    var modifiers: Set<HotkeySpec.Modifier>?
    private var flashRestore: DispatchWorkItem?

    init(
        onClick: @escaping () -> Void,
        onQuit: @escaping () -> Void,
        onChooseModifier: @escaping (ModifierPreset) -> Void,
        onToggleNumbers: @escaping () -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        self.onClick = onClick
        self.onQuit = onQuit
        self.onChooseModifier = onChooseModifier
        self.onToggleNumbers = onToggleNumbers
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        guard let button = item.button else { return }
        showImage()
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
        if flashRestore == nil { showImage() }
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

        let numbers = NSMenuItem(title: "Show Window Numbers",
                                 action: #selector(toggleNumbersFromMenu), keyEquivalent: "")
        numbers.target = self
        numbers.state = showsNumbers ? .on : .off
        numbers.toolTip = "Number the windows while the shortcut modifier is held, so the window "
            + "to switch to can be read off the screen."
        menu.addItem(numbers)

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

    /// Flash the glyph green or red to say whether a change took. Refusal shows longer.
    func flash(accepted: Bool) {
        dispatchPrecondition(condition: .onQueue(.main))

        flashRestore?.cancel()
        showImage(colour: accepted ? .systemGreen : .systemRed)

        let restore = DispatchWorkItem { [weak self] in
            self?.flashRestore = nil
            self?.showImage()
        }
        flashRestore = restore
        DispatchQueue.main.asyncAfter(deadline: .now() + (accepted ? 0.7 : 1.3), execute: restore)
    }

    private func showImage(colour: NSColor? = nil) {
        item.button?.image = MenuBarController.mark(state.glyph, colour: colour)
    }

    /// Heed's mark at menu bar size. 18 points is what AppKit sizes a status item symbol to, and the
    /// glyph's proportions are ninths, so every straight edge lands on a whole pixel at 1x.
    ///
    /// A template unless coloured; a template is a mask, so the flash colour has to be drawn into
    /// the image rather than tinted onto it. The drawing handler runs again per backing scale, so
    /// the same call is right on a Retina display and on a 1x one.
    private static func mark(_ glyph: Glyph, colour: NSColor?) -> NSImage {
        let side: CGFloat = 18
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.addPath(glyphPath(glyph, side: side))
            context.setFillColor((colour ?? .black).cgColor)
            context.fillPath()
            return true
        }
        image.isTemplate = colour == nil
        return image
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

    @objc private func toggleNumbersFromMenu() {
        onToggleNumbers()
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
}
