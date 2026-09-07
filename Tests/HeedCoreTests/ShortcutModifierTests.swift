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

    /// The bug: rewriting everything onto one modifier put the toggle and focus-left, both H, on
    /// the same combination.
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
        XCTAssertEqual(clash?.earlier, "toggle")
        XCTAssertEqual(clash?.later, "left")
        XCTAssertEqual(clash?.spec, HotkeySpec("ctrl+alt+cmd+h"))
    }

    func testNoClashWhenEveryCombinationIsDistinct() {
        let claims: [(name: String, spec: HotkeySpec)] = [
            (name: "toggle", spec: HotkeySpec("ctrl+cmd+h")!),
            (name: "next", spec: HotkeySpec("ctrl+cmd+right")!),
        ]
        XCTAssertNil(firstClash(in: claims))
    }

    func testTheModifiersArePartOfTheCombination() {
        let claims: [(name: String, spec: HotkeySpec)] = [
            (name: "toggle", spec: HotkeySpec("ctrl+cmd+h")!),
            (name: "left", spec: HotkeySpec("ctrl+alt+cmd+h")!),
        ]
        XCTAssertNil(firstClash(in: claims))
    }

    /// A duplicate the settings already had is not the change's doing: the settings that move are
    /// disjoint from it, so the menu must still apply.
    func testADuplicateAmongUnmovedSettingsIsNotCausedByTheChange() {
        // Two directional settings on one combination, and the four main ones under Control-Command.
        let typo = ["ctrl+cmd+h", "cmd+ctrl+right", "cmd+ctrl+left", "cmd+ctrl+1",
                    "cmd+ctrl+alt+a", "cmd+ctrl+alt+d", "cmd+ctrl+alt+k", "cmd+ctrl+alt+k"]
        let under = sharedModifiers(of: typo)
        let texts = rewriteHotkeys(typo, under: under, to: [.option, .command])

        let moved = Set(zip(typo, texts).enumerated().compactMap { index, pair in
            HotkeySpec(pair.0) == HotkeySpec(pair.1) ? nil : index
        })
        let claims = texts.enumerated().compactMap { index, text in
            HotkeySpec(text).map { (name: index, spec: $0) }
        }
        let clash = firstClash(in: claims)
        XCTAssertEqual(clash?.later, 7, "the second of the two duplicated settings")
        XCTAssertTrue(moved.isDisjoint(with: [clash!.earlier, clash!.later]),
                      "neither side of the clash moved, so it must not block the change")
    }

    /// Picking the modifier the directional shortcuts already use genuinely cannot be done.
    func testMovingOntoTheDirectionalModifierClashes() {
        let moved = rewriteHotkeys(defaults, under: [.control, .command],
                                   to: [.control, .option, .command])
        let claims = moved.enumerated().compactMap { index, text in
            HotkeySpec(text).map { (name: index, spec: $0) }
        }
        let clash = firstClash(in: claims)
        XCTAssertEqual(clash?.earlier, 0, "the toggle")
        XCTAssertEqual(clash?.later, 4, "focus left, which is also H")
    }
}
