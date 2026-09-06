import XCTest
@testable import FFMCore

final class CommandTests: XCTestCase {
    func testTheSwitchVerbs() {
        XCTAssertEqual(parseCommand("toggle"), .toggle)
        XCTAssertEqual(parseCommand("enable"), .enable)
        XCTAssertEqual(parseCommand("on"), .enable)
        XCTAssertEqual(parseCommand("disable"), .disable)
        XCTAssertEqual(parseCommand("off"), .disable)
    }

    func testTheFocusVerbs() {
        XCTAssertEqual(parseCommand("focus/next"), .focusStep(1))
        XCTAssertEqual(parseCommand("focus/previous"), .focusStep(-1))
        XCTAssertEqual(parseCommand("focus/prev"), .focusStep(-1))
        XCTAssertEqual(parseCommand("focus/left"), .focusDirection(.left))
        XCTAssertEqual(parseCommand("focus/down"), .focusDirection(.down))
        XCTAssertEqual(parseCommand("focus/3"), .focusNumber(3))
    }

    func testCaseAndSpacingDoNotMatter() {
        XCTAssertEqual(parseCommand(path: ["Focus", " Next "]), .focusStep(1))
        XCTAssertEqual(parseCommand(path: ["TOGGLE"]), .toggle)
    }

    /// A URL splits into a host and a path, which can leave empty segments behind.
    func testEmptySegmentsAreIgnored() {
        XCTAssertEqual(parseCommand(path: ["focus", "", "next"]), .focusStep(1))
        XCTAssertEqual(parseCommand("/toggle/"), .toggle)
    }

    func testUnknownVerbsAreRefused() {
        XCTAssertNil(parseCommand("quit"))
        XCTAssertNil(parseCommand("focus"))
        XCTAssertNil(parseCommand("focus/sideways"))
        XCTAssertNil(parseCommand(""))
        XCTAssertNil(parseCommand("toggle/next"), "a verb that takes no argument")
        XCTAssertNil(parseCommand("focus/next/again"))
    }

    func testOnlyWindowsOneToNine() {
        XCTAssertEqual(parseCommand("focus/1"), .focusNumber(1))
        XCTAssertEqual(parseCommand("focus/9"), .focusNumber(9))
        XCTAssertNil(parseCommand("focus/0"))
        XCTAssertNil(parseCommand("focus/10"))
        XCTAssertNil(parseCommand("focus/-1"))
    }

    /// The wire form and the parser are two halves of one thing.
    func testEveryCommandSurvivesTheRoundTrip() {
        let commands: [HeedCommand] = [
            .toggle, .enable, .disable, .focusStep(1), .focusStep(-1),
            .focusNumber(1), .focusNumber(9),
        ] + FocusDirection.allCases.map { .focusDirection($0) }

        for command in commands {
            XCTAssertEqual(parseCommand(command.written), command, command.written)
        }
    }
}
