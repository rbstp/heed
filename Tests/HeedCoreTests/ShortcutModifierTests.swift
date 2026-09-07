import XCTest
@testable import HeedCore

/// What the Shortcut Modifier menu does to the settings before anything is registered.
final class ShortcutModifierTests: XCTestCase {
    /// Heed's own defaults: the four main shortcuts under Control-Command, the directional ones
    /// deliberately under Control-Option-Command.
    private let defaults = ["ctrl+cmd+h", "cmd+ctrl+right", "cmd+ctrl+left", "cmd+ctrl+1",
                            "cmd+ctrl+alt+h", "cmd+ctrl+alt+l", "cmd+ctrl+alt+k", "cmd+ctrl+alt+j"]

    func testTheToggleNamesTheSharedModifier() {
        XCTAssertEqual(sharedModifiers(of: defaults), [.control, .command])
    }

    /// However the modifiers were typed: the setting is whatever the user wrote, the comparison is
    /// of combinations.
    func testReadsTheModifierWhateverTheSpelling() {
        XCTAssertEqual(sharedModifiers(of: ["Command-Control-H"]), [.control, .command])
        XCTAssertEqual(sharedModifiers(of: ["⌘⌃H"]), [.control, .command])
    }

    func testFallsBackToTheFirstSettingThatParses() {
        XCTAssertEqual(sharedModifiers(of: ["", "none", "alt+cmd+right"]), [.option, .command])
    }

    func testNoShortcutAtAllHasNoSharedModifier() {
        XCTAssertEqual(sharedModifiers(of: ["", "none", "nonsense"]), [])
    }

    /// The bug this fixes: rewriting every setting onto one modifier put the toggle and focus-left,
    /// which are both H, on the same combination, and that pair can never both be registered.
    func testLeavesSettingsThatAreNotUnderTheSharedModifier() {
        let moved = rewriteHotkeys(defaults, under: [.control, .command], to: [.option, .command])
        XCTAssertEqual(moved, ["alt+cmd+h", "alt+cmd+right", "alt+cmd+left", "alt+cmd+1",
                               "cmd+ctrl+alt+h", "cmd+ctrl+alt+l", "cmd+ctrl+alt+k",
                               "cmd+ctrl+alt+j"])
        XCTAssertNil(firstClash(in: moved.compactMap { HotkeySpec($0) }.map { (name: $0.key, spec: $0) }),
                     "no two settings may land on the same combination")
    }

    func testMovesSettingsWrittenInAnyOrder() {
        XCTAssertEqual(
            rewriteHotkeys(["Command-Control-H", "⌘⌃Right"], under: [.control, .command],
                           to: [.control, .option]),
            ["ctrl+alt+h", "ctrl+alt+right"]
        )
    }

    func testLeavesSettingsThatAreOffOrUnreadable() {
        XCTAssertEqual(rewriteHotkeys(["", "none", "nonsense", "ctrl+cmd+h"],
                                      under: [.control, .command], to: [.option, .command]),
                       ["", "none", "nonsense", "alt+cmd+h"])
    }

    // MARK: - Two settings on one combination

    func testNamesBothSidesOfAClash() {
        let claims: [(name: String, spec: HotkeySpec)] = [
            (name: "toggle", spec: HotkeySpec("ctrl+alt+cmd+h")!),
            (name: "next", spec: HotkeySpec("ctrl+alt+cmd+right")!),
            (name: "left", spec: HotkeySpec("ctrl+alt+cmd+h")!),
        ]
        let clash = firstClash(in: claims)
        XCTAssertEqual(clash?.0, "toggle")
        XCTAssertEqual(clash?.1, "left")
    }

    func testNoClashWhenEveryCombinationIsDistinct() {
        let claims: [(name: String, spec: HotkeySpec)] = [
            (name: "toggle", spec: HotkeySpec("ctrl+cmd+h")!),
            (name: "next", spec: HotkeySpec("ctrl+cmd+right")!),
        ]
        XCTAssertNil(firstClash(in: claims))
    }

    /// The same key under different modifiers is a different combination.
    func testTheModifiersArePartOfTheCombination() {
        let claims: [(name: String, spec: HotkeySpec)] = [
            (name: "toggle", spec: HotkeySpec("ctrl+cmd+h")!),
            (name: "left", spec: HotkeySpec("ctrl+alt+cmd+h")!),
        ]
        XCTAssertNil(firstClash(in: claims))
    }

    /// Picking the modifier the directional shortcuts already use genuinely cannot be done, and
    /// the clash is what says so instead of Carbon refusing the second registration.
    func testMovingOntoTheDirectionalModifierClashes() {
        let moved = rewriteHotkeys(defaults, under: [.control, .command],
                                   to: [.control, .option, .command])
        let claims = moved.enumerated().compactMap { index, text in
            HotkeySpec(text).map { (name: index, spec: $0) }
        }
        let clash = firstClash(in: claims)
        XCTAssertEqual(clash?.0, 0, "the toggle")
        XCTAssertEqual(clash?.1, 4, "focus left, which is also H")
    }
}
