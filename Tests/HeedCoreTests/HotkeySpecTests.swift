import XCTest
@testable import HeedCore

final class HotkeySpecTests: XCTestCase {
    /// The shipped default. If this changes, so does the README.
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
                     "cmd ctrl h", "⌘⌃h", "⌃⌘H", "meta+control+h", " cmd+ctrl+h "] {
            XCTAssertEqual(HotkeySpec(text), canonical, "\(text) should parse the same way")
        }
    }

    func testEveryModifier() {
        let spec = HotkeySpec("cmd+ctrl+opt+shift+k")
        XCTAssertEqual(spec?.modifiers, [.command, .control, .option, .shift])
        XCTAssertEqual(spec?.display, "⌃⌥⇧⌘K", "the order macOS shows them in")
        XCTAssertEqual(spec?.written, "ctrl+alt+shift+cmd+k")
    }

    func testRejectsAKeyWithNoModifier() {
        XCTAssertNil(HotkeySpec("h"))
        XCTAssertNil(HotkeySpec("f5"))
        XCTAssertNil(HotkeySpec(""))
    }

    /// `shift+a` is how a capital A is typed.
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

    /// A typo must not quietly register some other key.
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
    }

    func testNamedKeysAreCapitalisedForDisplay() {
        XCTAssertEqual(HotkeySpec("cmd+ctrl+f5")?.display, "⌃⌘F5")
        XCTAssertEqual(HotkeySpec("cmd+ctrl+right")?.display, "⌃⌘Right")
        XCTAssertEqual(HotkeySpec("alt+space")?.display, "⌥Space")
    }

    /// Spot-checked against values that are easy to transpose.
    func testKeyCodesMatchTheSDK() {
        let expected: [String: UInt16] = ["a": 0, "s": 1, "z": 6, "b": 11, "q": 12, "y": 16,
                                          "1": 18, "5": 23, "6": 22, "9": 25, "0": 29,
                                          "tab": 48, "space": 49, "return": 36, "escape": 53]
        for (key, code) in expected {
            XCTAssertEqual(HotkeySpec("cmd+\(key)")?.keyCode, code, "key code for \(key)")
        }
    }

    func testASettingThatNamesNoHotkeyIsOff() {
        for text in ["", "  ", "none", "None", " NONE "] {
            XCTAssertTrue(HotkeySpec.isOff(text), "\"\(text)\" names no hotkey")
        }
        XCTAssertFalse(HotkeySpec.isOff("cmd+ctrl+h"))
        XCTAssertFalse(HotkeySpec.isOff("nonsense"), "a typo is not switched off; it is reported")
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
        XCTAssertEqual(changed?.display, "⇧⌘Right")
        XCTAssertEqual(changed?.written, "shift+cmd+right")
        XCTAssertEqual(changed?.keyCode, HotkeySpec("cmd+ctrl+right")?.keyCode)
    }

    func testTheModifiersAreKeptWhenTheKeyChanges() {
        let spec = HotkeySpec("cmd+ctrl+1")!
        XCTAssertEqual(spec.withKey("2"), HotkeySpec("cmd+ctrl+2"))
        XCTAssertEqual(spec.withKey("Esc"), HotkeySpec("cmd+ctrl+escape"))
        XCTAssertNil(spec.withKey("wat"))
    }

    /// One setting stands for nine registrations, so every digit has to parse.
    func testDigitsOneToNineAreAllKnown() {
        for digit in 1...9 {
            XCTAssertNotNil(HotkeySpec("cmd+ctrl+\(digit)"), "digit \(digit)")
        }
    }

    /// The same rule a typed combination has to pass.
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

    func testRewritingLeavesSomethingItCannotParseAlone() {
        XCTAssertEqual(rewriteHotkey("cmd+ctrl+nonsense", modifiers: [.option, .command]),
                       "cmd+ctrl+nonsense")
    }

    /// The stored text is however it was typed; the rewrite is canonical. Comparing text would call
    /// the same chord a change.
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

    func testThePresetsAreNamedTheWayMacOSNamesThem() {
        XCTAssertEqual(ModifierPreset.controlCommand.display, "⌃⌘")
        XCTAssertEqual(ModifierPreset.controlOptionCommand.display, "⌃⌥⌘")
        XCTAssertEqual(ModifierPreset.controlCommand.spoken, "Control-Command")
        XCTAssertEqual(ModifierPreset.optionCommand.spoken, "Option-Command")
    }

    func testTheModifierInForceIsRecognised() {
        XCTAssertEqual(ModifierPreset.matching([.control, .command]), .controlCommand)
        XCTAssertEqual(ModifierPreset.matching(HotkeySpec("cmd+ctrl+alt+left")!.modifiers),
                       .controlOptionCommand)
    }

    /// Someone who typed their own combination should see none of the offered ones ticked.
    func testAModifierNobodyOfferedMatchesNothing() {
        XCTAssertNil(ModifierPreset.matching([.command]))
        XCTAssertNil(ModifierPreset.matching([.control, .option, .shift, .command]))
        XCTAssertNil(ModifierPreset.matching(nil))
    }

    func testTheCombinationsThatTakeSomethingAwaySaySo() {
        XCTAssertNotNil(ModifierPreset.optionCommand.caution)
        XCTAssertNil(ModifierPreset.controlCommand.caution)
    }

    /// Command-Shift with the arrows selects a line in every text field; the menu does not hand it
    /// out, but `defaults write` still sets it.
    func testCommandShiftIsNotOffered() {
        XCTAssertFalse(ModifierPreset.allCases.contains { $0.modifiers == [.shift, .command] })
        XCTAssertNil(ModifierPreset.matching(HotkeySpec("cmd+shift+left")!.modifiers))
        XCTAssertNotNil(HotkeySpec("cmd+shift+left"), "but it is still a combination Heed accepts")
    }
}
