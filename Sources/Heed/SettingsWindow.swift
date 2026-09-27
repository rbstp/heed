import AppKit
import HeedCore

/// Edits the defaults domain directly; the agent applies a change the way it applies a
/// `defaults write`. Main thread only.
final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate,
    NSTextViewDelegate {
    private unowned let agent: Agent
    private var checkboxes: [String: NSButton] = [:]
    private var fields: [String: NSTextField] = [:]
    private var lists: [String: NSTextView] = [:]
    private var statuses: [Shortcut: NSTextField] = [:]
    private var refused: Set<Shortcut> = []
    private var shown: [String: String] = [:]

    init(agent: Agent) {
        self.agent = agent
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 440),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Heed Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentView = build()
        window.center()
        NSApp.mainMenu = SettingsWindowController.mainMenu()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func present() {
        refresh()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Closing ends no editing on its own, and a list is committed by nothing else.
    func windowWillClose(_ notification: Notification) {
        window?.makeFirstResponder(nil)
    }

    /// An accessory app has no menu bar, and without an Edit menu nothing can be pasted.
    private static func mainMenu() -> NSMenu {
        let edit = NSMenu(title: "Edit")
        for (title, action, key) in [
            ("Undo", Selector(("undo:")), "z"), ("Redo", Selector(("redo:")), "Z"),
            ("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"),
            ("Paste", #selector(NSText.paste(_:)), "v"), ("Select All", #selector(NSText.selectAll(_:)), "a"),
        ] {
            edit.addItem(NSMenuItem(title: title, action: action, keyEquivalent: key))
        }
        let file = NSMenu(title: "File")
        file.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))

        let menu = NSMenu()
        for submenu in [file, edit] {
            let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
            item.submenu = submenu
            menu.addItem(item)
        }
        return menu
    }

    func refresh() {
        let defaults = Config.store()
        for setting in Setting.all {
            switch setting.kind {
            case .bool(let path):
                let value = defaults.object(forKey: setting.key) == nil
                    ? Config()[keyPath: path] : defaults.bool(forKey: setting.key)
                checkboxes[setting.key]?.state = value ? .on : .off
            case .int, .hotkey:
                guard let field = fields[setting.key], field.currentEditor() == nil else { continue }
                shown[setting.key] = stored(setting)
                field.stringValue = shown[setting.key] ?? ""
            case .strings:
                guard let view = lists[setting.key], window?.firstResponder !== view else { continue }
                view.string = (defaults.stringArray(forKey: setting.key) ?? []).joined(separator: "\n")
            }
        }
        for (shortcut, status) in statuses {
            let text = fields[shortcut.defaultsKey]?.stringValue ?? ""
            if refused.contains(shortcut) {
                status.stringValue = "Not registered; the log says why"
                status.textColor = .systemRed
            } else {
                status.stringValue = HotkeySpec.isOff(text) ? "Off" : "Registered"
                status.textColor = .secondaryLabelColor
            }
        }
    }

    /// The text a field shows for what is stored, or the default; an integer as Heed clamps it.
    private func stored(_ setting: Setting) -> String {
        let defaults = Config.store()
        switch setting.kind {
        case .int(let path, let limits):
            let value = defaults.object(forKey: setting.key) == nil
                ? Config()[keyPath: path] : defaults.integer(forKey: setting.key)
            return String(min(max(value, limits.lowerBound), limits.upperBound))
        case .hotkey(let shortcut):
            return defaults.string(forKey: setting.key) ?? Config()[keyPath: shortcut.keyPath]
        case .bool, .strings:
            return ""
        }
    }

    func show(refused: Set<Shortcut>) {
        self.refused = refused
        refresh()
    }

    // MARK: - Layout

    private func build() -> NSView {
        let tabs = NSTabView()
        for section in Setting.sections {
            let item = NSTabViewItem(identifier: section.title)
            item.label = section.title
            item.view = page(for: section)
            tabs.addTabViewItem(item)
        }

        let restore = NSButton(title: "Restore Defaults", target: self, action: #selector(restoreDefaults))
        let bar = NSStackView(views: [NSView(), restore])
        bar.orientation = .horizontal

        let stack = NSStackView(views: [tabs, bar])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            tabs.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            bar.widthAnchor.constraint(equalTo: tabs.widthAnchor),
        ])
        return content
    }

    private func page(for section: (title: String, settings: [Setting])) -> NSView {
        let grid = NSGridView(views: section.settings.map(row))
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.translatesAutoresizingMaskIntoConstraints = false

        var views: [NSView] = [grid]
        if section.title == "Shortcuts" {
            let release = NSButton(title: "Release All", target: self, action: #selector(releaseShortcuts))
            release.toolTip = "Unregister every shortcut, so another app can have the combinations."
            views.append(release)
        }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let page = NSView()
        page.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: page.topAnchor),
            stack.leadingAnchor.constraint(equalTo: page.leadingAnchor),
        ])
        return page
    }

    private func row(_ setting: Setting) -> [NSView] {
        let label = NSTextField(labelWithString: "\(setting.label):")
        label.toolTip = setting.help
        let identifier = NSUserInterfaceItemIdentifier(setting.key)

        switch setting.kind {
        case .bool:
            let box = NSButton(checkboxWithTitle: "", target: self, action: #selector(checkboxChanged(_:)))
            box.identifier = identifier
            box.toolTip = setting.help
            box.setAccessibilityLabel(setting.label)
            checkboxes[setting.key] = box
            return [label, box]
        case .int:
            let field = NSTextField(string: "")
            field.identifier = identifier
            field.delegate = self
            field.toolTip = setting.help
            field.alignment = .right
            field.widthAnchor.constraint(equalToConstant: 70).isActive = true
            fields[setting.key] = field
            let unit = NSTextField(labelWithString: setting.unit ?? "")
            unit.textColor = .secondaryLabelColor
            return [label, field, unit]
        case .hotkey(let shortcut):
            let field = NSTextField(string: "")
            field.identifier = identifier
            field.delegate = self
            field.placeholderString = "none"
            field.toolTip = setting.help
            field.widthAnchor.constraint(equalToConstant: 180).isActive = true
            fields[setting.key] = field
            let status = NSTextField(labelWithString: "")
            status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            statuses[shortcut] = status
            return [label, field, status]
        case .strings:
            let scroll = NSTextView.scrollableTextView()
            let view = scroll.documentView as! NSTextView
            view.identifier = identifier
            view.delegate = self
            view.font = .userFixedPitchFont(ofSize: NSFont.smallSystemFontSize)
            view.isRichText = false
            view.isAutomaticQuoteSubstitutionEnabled = false
            view.isAutomaticDashSubstitutionEnabled = false
            view.isAutomaticTextReplacementEnabled = false
            view.isAutomaticSpellingCorrectionEnabled = false
            scroll.borderType = .bezelBorder
            scroll.toolTip = setting.help
            scroll.widthAnchor.constraint(equalToConstant: 320).isActive = true
            scroll.heightAnchor.constraint(equalToConstant: 72).isActive = true
            lists[setting.key] = view
            return [label, scroll]
        }
    }

    // MARK: - Edits

    @objc private func checkboxChanged(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue else { return }
        agent.change(key, to: sender.state == .on)
    }

    /// A field that was not edited writes nothing, so it cannot put back what changed elsewhere.
    /// `refresh` skips a field still being ended, so the field is set here.
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
              let setting = field.identifier.flatMap({ Setting.named($0.rawValue) })
        else { return }
        guard field.stringValue != shown[setting.key] else {
            field.stringValue = stored(setting)
            shown[setting.key] = field.stringValue
            return
        }
        guard let value = setting.parse(field.stringValue) else {
            if case .hotkey(let shortcut) = setting.kind, let status = statuses[shortcut] {
                status.stringValue = "Not a combination; try cmd+ctrl+h"
                status.textColor = .systemRed
                return
            }
            field.stringValue = shown[setting.key] ?? ""
            return
        }
        agent.change(setting.key, to: value)
        shown[setting.key] = "\(value)"
        field.stringValue = shown[setting.key] ?? ""
    }

    func textDidEndEditing(_ notification: Notification) {
        guard let view = notification.object as? NSTextView, let key = view.identifier?.rawValue else { return }
        let lines = view.string.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let kept = Config.store().stringArray(forKey: key) ?? []
        guard lines != kept else {
            view.string = kept.joined(separator: "\n")
            return
        }
        agent.change(key, to: lines.isEmpty ? nil : lines)
    }

    @objc private func releaseShortcuts() {
        agent.perform(.releaseHotkeys)
    }

    @objc private func restoreDefaults() {
        let alert = NSAlert()
        alert.messageText = "Restore every setting to its default?"
        alert.informativeText = "Shortcuts, exclusions and the rest go back to what a fresh install has."
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        for setting in Setting.all { agent.change(setting.key, to: nil) }
    }
}
