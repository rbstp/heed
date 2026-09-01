import XCTest
@testable import FFMCore

final class HotkeySpecTests: XCTestCase {
    /// The shipped default. If this test ever has to change, so does the README.
    func testTheDefaultCombination() {
        let spec = HotkeySpec("cmd+ctrl+h")
        XCTAssertEqual(spec?.modifiers, [.command, .control])
        XCTAssertEqual(spec?.key, "h")
        XCTAssertEqual(spec?.keyCode, 4)   // kVK_ANSI_H
        XCTAssertEqual(spec?.display, "⌃⌘H")
    }

    func testSpellingsThatMeanTheSameThing() {
        let canonical = HotkeySpec("cmd+ctrl+h")
        for text in ["command+control+h", "Cmd+Ctrl+H", "CTRL+CMD+H", "cmd-ctrl-h",
                     "cmd ctrl h", "⌘⌃h", "⌃⌘H", "meta+control+h"] {
            XCTAssertEqual(HotkeySpec(text), canonical, "\(text) should parse the same way")
        }
    }

    func testEveryModifier() {
        let spec = HotkeySpec("cmd+ctrl+opt+shift+k")
        XCTAssertEqual(spec?.modifiers, [.command, .control, .option, .shift])
        // The order macOS shows them in, not the order they were typed.
        XCTAssertEqual(spec?.display, "⌃⌥⇧⌘K")
    }

    /// Without a modifier the hotkey would swallow that key across the whole system, starting with
    /// your ability to type it.
    func testRejectsAKeyWithNoModifier() {
        XCTAssertNil(HotkeySpec("h"))
        XCTAssertNil(HotkeySpec("f5"))
        XCTAssertNil(HotkeySpec(""))
    }

    /// Shift is not a chord: `shift+a` is how a capital A is typed, so accepting it would take
    /// uppercase away system-wide -- exactly what the modifier rule exists to prevent.
    func testRejectsShiftAsTheOnlyModifier() {
        XCTAssertNil(HotkeySpec("shift+a"))
        XCTAssertNil(HotkeySpec("⇧h"))
        XCTAssertNotNil(HotkeySpec("cmd+shift+a"), "shift alongside a real modifier is fine")
    }

    func testRejectsModifiersWithNoKey() {
        XCTAssertNil(HotkeySpec("cmd"))
        XCTAssertNil(HotkeySpec("cmd+ctrl"))
        XCTAssertNil(HotkeySpec("⌘⌃"))
    }

    func testRejectsTwoKeys() {
        XCTAssertNil(HotkeySpec("cmd+h+j"))
    }

    /// A typo must not quietly register some other key. This is the failure the parser exists to
    /// turn into a log line.
    func testRejectsAKeyItDoesNotKnow() {
        XCTAssertNil(HotkeySpec("cmd+ctrl+hh"))
        XCTAssertNil(HotkeySpec("cmd+ctrl+f21"))
        XCTAssertNil(HotkeySpec("cmd+ctrl+wat"))
    }

    func testNamedKeysAndTheirAliases() {
        XCTAssertEqual(HotkeySpec("cmd+space")?.keyCode, 49)
        XCTAssertEqual(HotkeySpec("cmd+esc"), HotkeySpec("cmd+escape"))
        XCTAssertEqual(HotkeySpec("ctrl+enter"), HotkeySpec("ctrl+return"))
        XCTAssertEqual(HotkeySpec("cmd+ctrl+f5")?.keyCode, 96)
        XCTAssertEqual(HotkeySpec("cmd+ctrl+f5")?.display, "⌃⌘F5")
    }

    /// Every code is the one the SDK defines. Spot-checked against values that are easy to
    /// transpose: the letter row is not in alphabetical order, and the digits are not in order.
    func testKeyCodesMatchTheSDK() {
        let expected: [String: UInt16] = ["a": 0, "s": 1, "z": 6, "b": 11, "q": 12, "y": 16,
                                          "1": 18, "5": 23, "6": 22, "9": 25, "0": 29,
                                          "tab": 48, "space": 49, "return": 36, "escape": 53]
        for (key, code) in expected {
            XCTAssertEqual(HotkeySpec("cmd+\(key)")?.keyCode, code, "key code for \(key)")
        }
    }
}
