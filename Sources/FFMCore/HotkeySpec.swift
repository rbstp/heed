/// A key combination, parsed from the string a user types into `defaults write`.
///
/// The parsing is here, and the registering is not: turning "cmd+ctrl+h" into a set of modifiers and
/// a key code is a decision about values, and it is the half that fails quietly. A typo must be
/// rejected with a log line rather than registering some other key.
public struct HotkeySpec: Equatable, Sendable {
    public enum Modifier: String, Sendable, CaseIterable {
        case control, option, shift, command
    }

    public let modifiers: Set<Modifier>
    /// The virtual key code. These are the `kVK_*` constants, written out rather than imported so
    /// this module stays free of platform frameworks; they were transcribed from the SDK, not
    /// remembered.
    public let keyCode: UInt16
    /// The canonical name of the key, lowercase: "h", "f5", "space".
    public let key: String

    /// Parses forms like `cmd+ctrl+h`, `Command-Control-H`, `⌘⌃H`.
    ///
    /// Returns nil for anything it cannot turn into exactly one key plus at least one modifier. The
    /// modifier requirement is not pedantry: a hotkey without one would swallow that key everywhere
    /// on the system, and the first thing you would lose is the ability to type it.
    public init?(_ text: String) {
        // Symbols are accepted with or without separators (⌘⌃H), so they are expanded to tokens
        // first; everything else splits on the usual separators.
        var normalized = text.lowercased()
        for (symbol, word) in [("⌘", "command+"), ("⌃", "control+"), ("⌥", "option+"),
                               ("⇧", "shift+")] {
            normalized = normalized.replacingOccurrences(of: symbol, with: word)
        }

        var found: Set<Modifier> = []
        var keyToken: String?
        for raw in normalized.split(whereSeparator: { $0 == "+" || $0 == "-" || $0 == " " }) {
            let token = String(raw)
            if let modifier = HotkeySpec.modifierNames[token] {
                found.insert(modifier)
            } else {
                // A second bare token means something like "cmd+h+j", which is not a hotkey.
                guard keyToken == nil else { return nil }
                keyToken = token
            }
        }

        guard !found.isEmpty,
              let name = keyToken.flatMap({ HotkeySpec.keyAliases[$0] ?? $0 }),
              let code = HotkeySpec.keyCodes[name]
        else { return nil }

        modifiers = found
        key = name
        keyCode = code
    }

    /// The combination the way macOS writes it, in the order macOS orders it: ⌃⌥⇧⌘ then the key.
    /// Used in the log and anywhere the hotkey has to be shown.
    public var display: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + (key.count == 1 ? key.uppercased() : key.capitalized)
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

    /// Transcribed from `Carbon.HIToolbox`'s `kVK_*` constants.
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
