import Foundation

/// A key combination parsed from the string a user types into `defaults write`.
public struct HotkeySpec: Equatable, Sendable {
    /// Declared in the order macOS displays them: ⌃⌥⇧⌘.
    public enum Modifier: String, Sendable, CaseIterable {
        case control, option, shift, command

        var symbol: String {
            switch self {
            case .control: "⌃"
            case .option: "⌥"
            case .shift: "⇧"
            case .command: "⌘"
            }
        }

        var written: String {
            switch self {
            case .control: "ctrl"
            case .option: "alt"
            case .shift: "shift"
            case .command: "cmd"
            }
        }

        var spoken: String { rawValue.capitalized }
    }

    public let modifiers: Set<Modifier>
    /// A `kVK_*` constant, transcribed so this module stays free of platform frameworks.
    public let keyCode: UInt16
    /// The canonical key name, lowercase: "h", "f5", "space".
    public let key: String

    /// Parses forms like `cmd+ctrl+h`, `Command-Control-H`, `⌘⌃H`. Nil unless there is exactly one
    /// key and at least one modifier other than shift: `shift+a` is how a capital A is typed, and a
    /// hotkey with no real modifier would swallow that key system-wide.
    public init?(_ text: String) {
        var normalized = text.lowercased()
        for modifier in Modifier.allCases {
            normalized = normalized.replacingOccurrences(of: modifier.symbol, with: "\(modifier.rawValue)+")
        }

        var found: Set<Modifier> = []
        var keyToken: String?
        for raw in normalized.split(whereSeparator: { $0 == "+" || $0 == "-" || $0 == " " }) {
            let token = String(raw)
            if let modifier = HotkeySpec.modifierNames[token] {
                found.insert(modifier)
            } else {
                guard keyToken == nil else { return nil }
                keyToken = token
            }
        }

        guard HotkeySpec.isChord(found),
              let name = keyToken.map({ HotkeySpec.keyAliases[$0] ?? $0 }),
              let code = HotkeySpec.keyCodes[name]
        else { return nil }

        modifiers = found
        key = name
        keyCode = code
    }

    private init(modifiers: Set<Modifier>, key: String, keyCode: UInt16) {
        self.modifiers = modifiers
        self.key = key
        self.keyCode = keyCode
    }

    /// Whether a setting names no hotkey at all: empty, or "none".
    public static func isOff(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed.lowercased() == "none"
    }

    /// The same key under different modifiers, or nil when that would not be a legal hotkey.
    public func withModifiers(_ modifiers: Set<Modifier>) -> HotkeySpec? {
        guard HotkeySpec.isChord(modifiers) else { return nil }
        return HotkeySpec(modifiers: modifiers, key: key, keyCode: keyCode)
    }

    /// The same modifiers with another key, or nil when the key is not one this knows.
    public func withKey(_ key: String) -> HotkeySpec? {
        let name = HotkeySpec.keyAliases[key.lowercased()] ?? key.lowercased()
        guard let code = HotkeySpec.keyCodes[name] else { return nil }
        return HotkeySpec(modifiers: modifiers, key: name, keyCode: code)
    }

    /// The form `defaults write` takes: `ctrl+alt+shift+cmd+h`.
    public var written: String {
        (modifiers.ordered.map(\.written) + [key]).joined(separator: "+")
    }

    /// The form macOS shows: `⌃⌥⇧⌘H`.
    public var display: String {
        modifiers.symbols + (key.count == 1 ? key.uppercased() : key.capitalized)
    }

    private static func isChord(_ modifiers: Set<Modifier>) -> Bool {
        modifiers.contains { $0 != .shift }
    }

    private static let modifierNames: [String: Modifier] = [
        "cmd": .command, "command": .command, "meta": .command,
        "ctrl": .control, "control": .control,
        "opt": .option, "option": .option, "alt": .option,
        "shift": .shift,
    ]

    private static let keyAliases: [String: String] = [
        "esc": "escape", "enter": "return", "del": "delete", "backspace": "delete",
        "pgup": "pageup", "pgdn": "pagedown", "spacebar": "space",
    ]

    private static let keyCodes: [String: UInt16] = [
        "a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "f": 3, "g": 5, "h": 4, "i": 34, "j": 38,
        "k": 40, "l": 37, "m": 46, "n": 45, "o": 31, "p": 35, "q": 12, "r": 15, "s": 1, "t": 17,
        "u": 32, "v": 9, "w": 13, "x": 7, "y": 16, "z": 6,
        "0": 29, "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
        "f9": 101, "f10": 109, "f11": 103, "f12": 111, "f13": 105, "f14": 107, "f15": 113,
        "f16": 106, "f17": 64, "f18": 79, "f19": 80, "f20": 90,
        "space": 49, "tab": 48, "return": 36, "escape": 53, "delete": 51, "forwarddelete": 117,
        "help": 114, "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
        "left": 123, "right": 124, "up": 126, "down": 125,
        "minus": 27, "equal": 24, "grave": 50, "comma": 43, "period": 47, "slash": 44,
        "semicolon": 41, "quote": 39, "backslash": 42, "leftbracket": 33, "rightbracket": 30,
    ]
}

extension Set where Element == HotkeySpec.Modifier {
    var ordered: [HotkeySpec.Modifier] { HotkeySpec.Modifier.allCases.filter(contains) }
    var symbols: String { ordered.map(\.symbol).joined() }
}

/// Rewrite a hotkey setting under different modifiers, keeping its key. A setting that is off or
/// does not parse is returned unchanged.
public func rewriteHotkey(_ text: String, modifiers: Set<HotkeySpec.Modifier>) -> String {
    guard !HotkeySpec.isOff(text),
          let changed = HotkeySpec(text.trimmingCharacters(in: .whitespaces))?.withModifiers(modifiers)
    else { return text }
    return changed.written
}

/// The modifier combinations the menu offers, in menu order. Command-Shift is left out: with the
/// arrow keys it selects a line in every text field, and a registered hotkey takes that away.
public enum ModifierPreset: CaseIterable, Sendable {
    case controlCommand, optionCommand, controlOption, controlOptionCommand

    public var modifiers: Set<HotkeySpec.Modifier> {
        switch self {
        case .controlCommand: [.control, .command]
        case .optionCommand: [.option, .command]
        case .controlOption: [.control, .option]
        case .controlOptionCommand: [.control, .option, .command]
        }
    }

    public var display: String { modifiers.symbols }

    public var spoken: String { modifiers.ordered.map(\.spoken).joined(separator: "-") }

    /// What the combination takes away from other apps. Carbon only refuses a combination another
    /// app registered; one the system reads directly is taken quietly, so this is the only warning.
    public var caution: String? {
        switch self {
        case .optionCommand:
            "Command-Option with the arrow keys moves between tabs in most browsers and terminals. "
                + "Heed would take that away."
        default: nil
        }
    }

    public static func matching(_ modifiers: Set<HotkeySpec.Modifier>?) -> ModifierPreset? {
        guard let modifiers else { return nil }
        return allCases.first { $0.modifiers == modifiers }
    }
}
