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

    // MARK: - Changing the modifier

    func testTheWrittenFormParsesBackToTheSameCombination() {
        for text in ["cmd+ctrl+h", "⌘⌃⇧F5", "alt-command-left", "ctrl+opt+cmd+space"] {
            let spec = HotkeySpec(text)!
            XCTAssertEqual(HotkeySpec(spec.written), spec, "\(text) did not survive being written")
        }
    }

    func testTheKeyIsKeptWhenTheModifierChanges() {
        let changed = HotkeySpec("cmd+ctrl+right")!.withModifiers([.shift, .command])
        XCTAssertEqual(changed?.display, "⇧⌘right".replacingOccurrences(of: "right", with: "Right"))
        XCTAssertEqual(changed?.written, "shift+cmd+right")
    }

    /// The same rule a typed combination has to pass: shift alone is not a chord, it is how a
    /// capital letter is typed.
    func testAModifierChangeThatWouldNotBeALegalHotkeyIsRefused() {
        XCTAssertNil(HotkeySpec("cmd+ctrl+h")!.withModifiers([.shift]))
        XCTAssertNil(HotkeySpec("cmd+ctrl+h")!.withModifiers([]))
    }

    func testRewritingKeepsEachKey() {
        XCTAssertEqual(rewriteHotkey("cmd+ctrl+h", modifiers: [.option, .command]), "alt+cmd+h")
        XCTAssertEqual(rewriteHotkey("cmd+ctrl+left", modifiers: [.option, .command]),
                       "alt+cmd+left")
    }

    /// A shortcut somebody switched off must not come back because they changed the modifier.
    func testRewritingLeavesASwitchedOffShortcutAlone() {
        XCTAssertEqual(rewriteHotkey("", modifiers: [.option, .command]), "")
        XCTAssertEqual(rewriteHotkey("  ", modifiers: [.option, .command]), "  ")
        XCTAssertEqual(rewriteHotkey("none", modifiers: [.option, .command]), "none")
    }

    /// Nor must a typo turn into a working shortcut nobody asked for.
    func testRewritingLeavesSomethingItCannotParseAlone() {
        XCTAssertEqual(rewriteHotkey("cmd+ctrl+nonsense", modifiers: [.option, .command]),
                       "cmd+ctrl+nonsense")
    }

    /// The trap a "did this actually change anything?" check has to avoid. What is stored is
    /// however somebody wrote it; what comes back from a rewrite is canonical. The same chord is
    /// then two different strings, and comparing the text would call it a change.
    func testTheSameCombinationCanBeWrittenTwoWays() {
        let rewritten = rewriteHotkey("cmd+ctrl+h", modifiers: [.control, .command])
        XCTAssertNotEqual(rewritten, "cmd+ctrl+h", "the canonical order is not the typed one")
        XCTAssertEqual(HotkeySpec(rewritten), HotkeySpec("cmd+ctrl+h"),
                       "but they are the same combination")
    }

    // MARK: - What the menu offers

    func testEveryOfferedModifierMakesALegalHotkey() {
        let spec = HotkeySpec("cmd+ctrl+right")!
        for preset in ModifierPreset.allCases {
            XCTAssertNotNil(spec.withModifiers(preset.modifiers), "\(preset.display) is not usable")
        }
    }

    func testTheOfferedModifiersAreAllDifferent() {
        let sets = ModifierPreset.allCases.map(\.modifiers)
        XCTAssertEqual(Set(sets.map { $0.map(\.rawValue).sorted().joined() }).count, sets.count)
    }

    func testTheModifierInForceIsRecognised() {
        XCTAssertEqual(ModifierPreset.matching([.control, .command]), .controlCommand)
        XCTAssertEqual(ModifierPreset.matching(HotkeySpec("cmd+ctrl+alt+left")!.modifiers),
                       .controlOptionCommand)
    }

    /// Someone who typed their own combination into `defaults write` should see none of the offered
    /// ones ticked, rather than the nearest.
    func testAModifierNobodyOfferedMatchesNothing() {
        XCTAssertNil(ModifierPreset.matching([.command]))
        XCTAssertNil(ModifierPreset.matching([.control, .option, .shift, .command]))
        XCTAssertNil(ModifierPreset.matching(nil))
    }

    func testTheCombinationsThatTakeSomethingAwaySaySo() {
        XCTAssertNotNil(ModifierPreset.optionCommand.caution)
        XCTAssertNil(ModifierPreset.controlCommand.caution)
    }

    /// Command-Shift with the arrow keys selects a line in every text field on the system, which is
    /// too much to take away from behind a tooltip. `defaults write` still sets it for anyone who
    /// wants it; the menu does not hand it out.
    func testCommandShiftIsNotOffered() {
        XCTAssertFalse(ModifierPreset.allCases.contains { $0.modifiers == [.shift, .command] })
        XCTAssertNil(ModifierPreset.matching(HotkeySpec("cmd+shift+left")!.modifiers))
        XCTAssertNotNil(HotkeySpec("cmd+shift+left"), "but it is still a combination Heed accepts")
    }
}
