import HeedCore

/// `Config.load` reads through it, the Settings window edits through it, and `heed://set` names it.
struct Setting {
    enum Kind {
        case bool(WritableKeyPath<Config, Bool>)
        case int(WritableKeyPath<Config, Int>, ClosedRange<Int>)
        case hotkey(Shortcut)
        /// One entry per line in the window, comma-separated in a URL. `Config.load` reads these
        /// itself, since each is folded into a built-in list.
        case strings
    }

    let key: String
    let kind: Kind
    let label: String
    let help: String

    static let sections: [(title: String, settings: [Setting])] = [
        ("General", [
            Setting(key: "enabled", kind: .bool(\.enabled), label: "Focus follows mouse",
                    help: "Turn focus following on or off."),
            Setting(key: "menuBarIcon", kind: .bool(\.menuBarIcon), label: "Menu bar icon",
                    help: "Show the menu bar icon."),
            Setting(key: "raise", kind: .bool(\.raise), label: "Raise the focused window",
                    help: "Raise the selected window within its app."),
            Setting(key: "verbose", kind: .bool(\.verbose), label: "Log every decision",
                    help: "Log each focus decision."),
        ]),
        ("Shortcuts", [
            Setting(key: Shortcut.toggle.defaultsKey, kind: .hotkey(.toggle), label: "Toggle Heed",
                    help: "Global toggle. Empty disables it."),
            Setting(key: Shortcut.focusNext.defaultsKey, kind: .hotkey(.focusNext), label: "Next window",
                    help: "Move focus to the next window. Empty disables it."),
            Setting(key: Shortcut.focusPrevious.defaultsKey, kind: .hotkey(.focusPrevious),
                    label: "Previous window", help: "Move focus to the previous window. Empty disables it."),
            Setting(key: Shortcut.focusWindow.defaultsKey, kind: .hotkey(.focusWindow),
                    label: "Window by number",
                    help: "Move focus to window 1; the same modifiers with 2 to 9 reach the others. "
                        + "Empty disables it."),
            Setting(key: Shortcut.focusLeft.defaultsKey, kind: .hotkey(.focusLeft), label: "Window to the left",
                    help: "Move focus to the nearest window to the left. Empty disables it."),
            Setting(key: Shortcut.focusRight.defaultsKey, kind: .hotkey(.focusRight),
                    label: "Window to the right",
                    help: "Move focus to the nearest window to the right. Empty disables it."),
            Setting(key: Shortcut.focusUp.defaultsKey, kind: .hotkey(.focusUp), label: "Window above",
                    help: "Move focus to the nearest window above. Empty disables it."),
            Setting(key: Shortcut.focusDown.defaultsKey, kind: .hotkey(.focusDown), label: "Window below",
                    help: "Move focus to the nearest window below. Empty disables it."),
        ]),
        ("Window numbers", [
            Setting(key: "windowNumbers", kind: .bool(\.windowNumbers), label: "Show window numbers",
                    help: "Number the windows on screen while the numbered shortcuts' modifier is held."),
            Setting(key: "windowNumbersDelayMs", kind: .int(\.windowNumbersDelayMs, 0...2_000),
                    label: "After holding the modifier for", help: "How long that modifier must be held first."),
        ]),
        ("Pointer", [
            Setting(key: "warpPointer", kind: .bool(\.warpPointer), label: "Move the pointer into the focused window",
                    help: "Move the pointer into a window that took keyboard focus."),
            Setting(key: "warpX", kind: .int(\.warpX, 0...100), label: "Across",
                    help: "Where in that window the pointer lands, as a percentage across."),
            Setting(key: "warpY", kind: .int(\.warpY, 0...100), label: "Down",
                    help: "Where in that window the pointer lands, as a percentage down."),
        ]),
        ("Timing", [
            Setting(key: "dwellMs", kind: .int(\.dwellMs, 0...5_000), label: "Dwell",
                    help: "Time the pointer must rest before focus changes. Try 200 if instant is too eager."),
            Setting(key: "pollMs", kind: .int(\.pollMs, 10...1_000), label: "Poll",
                    help: "Pointer sampling interval while active."),
            Setting(key: "idlePollMs", kind: .int(\.idlePollMs, 100...10_000), label: "Idle poll",
                    help: "Heartbeat while idle. Mouse movement wakes the fast loop."),
            Setting(key: "typingCooldownMs", kind: .int(\.typingCooldownMs, 0...5_000), label: "After a keystroke",
                    help: "Ignore pointer focus after a keystroke."),
            Setting(key: "clickGraceMs", kind: .int(\.clickGraceMs, 0...2_000), label: "After a click",
                    help: "Ignore pointer focus after a mouse press or release."),
            Setting(key: "entryMotionPx", kind: .int(\.entryMotionPx, 0...200), label: "Travel before focusing",
                    help: "Travel required before a different window may take focus. 0 disables the guard."),
            Setting(key: "verifyTimeoutMs", kind: .int(\.verifyTimeoutMs, 20...2_000), label: "Verify within",
                    help: "Time allowed to confirm a focus change before retrying."),
        ]),
        ("Guards", [
            Setting(key: "ignoreWhenCommandHeld", kind: .bool(\.ignoreWhenCommandHeld),
                    label: "Ignore the pointer while Command is held",
                    help: "Suppress pointer focus while Command is held."),
            Setting(key: "menuGuard", kind: .bool(\.menuGuard), label: "Ignore the pointer while a menu is open",
                    help: "Suppress pointer focus while menus, popovers, or drag images are visible."),
            Setting(key: "handoverGuard", kind: .bool(\.handoverGuard), label: "Keep focus that arrived by keyboard",
                    help: "Keep focus that arrived without pointer movement."),
            Setting(key: "handoverSettleMs", kind: .int(\.handoverSettleMs, 0...5_000), label: "Release it after resting for",
                    help: "Rest time on another window before releasing held focus."),
            Setting(key: "requireStandardWindow", kind: .bool(\.requireStandardWindow),
                    label: "Only ordinary windows", help: "Only focus ordinary AXStandardWindow windows."),
            Setting(key: "promptGuard", kind: .bool(\.promptGuard), label: "Keep focus on a prompt",
                    help: "Keep focus on a prompt until it is answered."),
        ]),
        ("Exclusions", [
            Setting(key: "excludedWindowTitles", kind: .strings, label: "Window titles to skip",
                    help: "Case-insensitive regular expressions, one per line."),
            Setting(key: "excludedBundleIDs", kind: .strings, label: "Apps to skip",
                    help: "Bundle IDs, one per line."),
        ]),
    ]

    static let all: [Setting] = sections.flatMap(\.settings)

    static func named(_ key: String) -> Setting? {
        all.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }
    }

    var unit: String? {
        if key.hasSuffix("Ms") { return "ms" }
        if key.hasSuffix("Px") { return "px" }
        if key == "warpX" || key == "warpY" { return "%" }
        return nil
    }

    func parse(_ text: String) -> Any? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        switch kind {
        case .bool:
            switch trimmed.lowercased() {
            case "true", "on", "yes", "1": return true
            case "false", "off", "no", "0": return false
            default: return nil
            }
        case .int(_, let limits):
            guard let value = Int(trimmed) else { return nil }
            return min(max(value, limits.lowerBound), limits.upperBound)
        case .hotkey:
            if HotkeySpec.isOff(trimmed) { return "" }
            return HotkeySpec(trimmed) == nil ? nil : trimmed
        case .strings:
            return trimmed.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
    }
}
