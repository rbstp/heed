import HeedCore

/// One row per shortcut setting: what it does, the defaults key it is stored under, and the
/// `Config` field it lands in. `Config.load` reads through it and `changeModifiers` writes
/// through it, so the mapping is stated once.
enum Shortcut: CaseIterable {
    case toggle, focusNext, focusPrevious, focusWindow
    case focusLeft, focusRight, focusUp, focusDown

    var which: String {
        switch self {
        case .toggle: "toggles Heed"
        case .focusNext: "moves focus to the next window"
        case .focusPrevious: "moves focus to the previous window"
        case .focusWindow: "moves focus to a window by number"
        case .focusLeft, .focusRight, .focusUp, .focusDown:
            "moves focus \(direction?.rawValue ?? "")"
        }
    }

    var defaultsKey: String {
        switch self {
        case .toggle: "hotkey"
        case .focusNext: "focusNextHotkey"
        case .focusPrevious: "focusPreviousHotkey"
        case .focusWindow: "focusWindowHotkey"
        case .focusLeft: "focusLeftHotkey"
        case .focusRight: "focusRightHotkey"
        case .focusUp: "focusUpHotkey"
        case .focusDown: "focusDownHotkey"
        }
    }

    var keyPath: WritableKeyPath<Config, String> {
        switch self {
        case .toggle: \.hotkey
        case .focusNext: \.focusNextHotkey
        case .focusPrevious: \.focusPreviousHotkey
        case .focusWindow: \.focusWindowHotkey
        case .focusLeft: \.focusLeftHotkey
        case .focusRight: \.focusRightHotkey
        case .focusUp: \.focusUpHotkey
        case .focusDown: \.focusDownHotkey
        }
    }

    var direction: FocusDirection? {
        switch self {
        case .focusLeft: .left
        case .focusRight: .right
        case .focusUp: .up
        case .focusDown: .down
        default: nil
        }
    }
}
