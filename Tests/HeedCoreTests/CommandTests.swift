import XCTest
@testable import HeedCore

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

    func testEmptySegmentsAreIgnored() {
        XCTAssertEqual(parseCommand(path: ["focus", "", "next"]), .focusStep(1))
        XCTAssertEqual(parseCommand("/toggle/"), .toggle)
    }

    func testTheSettingVerbs() {
        XCTAssertEqual(parseCommand("set/warpPointer/true"), .set(key: "warpPointer", value: "true"))
        XCTAssertEqual(parseCommand("set/focusNextHotkey/cmd+ctrl+right"),
                       .set(key: "focusNextHotkey", value: "cmd+ctrl+right"))
        XCTAssertEqual(parseCommand("Set/excludedWindowTitles/^a/b$"),
                       .set(key: "excludedWindowTitles", value: "^a/b$"), "a value keeps its slashes and case")
        XCTAssertEqual(parseCommand("reset/dwellMs"), .reset(key: "dwellMs"))
        XCTAssertEqual(parseCommand("hotkeys/release"), .releaseHotkeys)
        XCTAssertEqual(parseCommand("hotkeys/Restore"), .restoreHotkeys)
        XCTAssertEqual(parseCommand("settings"), .openSettings)
        XCTAssertNil(parseCommand("settings/general"))
        XCTAssertNil(parseCommand("set/warpPointer"))
        XCTAssertNil(parseCommand("reset"))
        XCTAssertNil(parseCommand("reset/a/b"))
        XCTAssertNil(parseCommand("hotkeys/all"))
    }

    func testUnknownVerbsAreRefused() {
        XCTAssertNil(parseCommand("quit"))
        XCTAssertNil(parseCommand("focus"))
        XCTAssertNil(parseCommand("focus/sideways"))
        XCTAssertNil(parseCommand(""))
        XCTAssertNil(parseCommand("toggle/next"), "a verb that takes no argument")
        XCTAssertNil(parseCommand("focus/next/again"))
    }

    /// A place in the ring is only true of the ring it came from, so a list hands back the window
    /// server's own number instead.
    func testAWindowCanBeAskedForByItsWindowServerNumber() {
        XCTAssertEqual(parseCommand("focus/id/1"), .focusWindowID(1))
        XCTAssertEqual(parseCommand("focus/id/48213"), .focusWindowID(48213))
        XCTAssertEqual(parseCommand(path: ["focus", "ID", "7"]), .focusWindowID(7))
        XCTAssertNil(parseCommand("focus/id"))
        XCTAssertNil(parseCommand("focus/id/0"))
        XCTAssertNil(parseCommand("focus/id/-3"))
        XCTAssertNil(parseCommand("focus/id/abc"))
        XCTAssertNil(parseCommand("focus/id/7/8"))
    }

    /// The shortcuts stop at the digit keys; a window picked from a list does not.
    func testWindowNumbersRunPastTheDigitKeys() {
        XCTAssertEqual(parseCommand("focus/1"), .focusNumber(1))
        XCTAssertEqual(parseCommand("focus/9"), .focusNumber(9))
        XCTAssertEqual(parseCommand("focus/10"), .focusNumber(10))
        XCTAssertEqual(parseCommand("focus/99"), .focusNumber(99))
        XCTAssertNil(parseCommand("focus/0"))
        XCTAssertEqual(parseCommand("focus/100"), .focusNumber(100))
        XCTAssertNil(parseCommand("focus/1000"))
        XCTAssertNil(parseCommand("focus/-1"))
        XCTAssertNil(parseCommand("focus/1x"))
        XCTAssertNil(parseCommand("focus/٣"), "digits the window list will never produce")
    }

    func testEveryCommandSurvivesTheRoundTrip() {
        let commands: [HeedCommand] = [
            .toggle, .enable, .disable, .focusStep(1), .focusStep(-1),
            .focusNumber(1), .focusNumber(9), .focusNumber(23), .focusWindowID(48213),
            .set(key: "warpPointer", value: "true"), .set(key: "focusNextHotkey", value: "none"),
            .set(key: "excludedWindowTitles", value: "^a//b $, c"), .reset(key: "dwellMs"),
            .releaseHotkeys, .restoreHotkeys, .openSettings,
        ] + FocusDirection.allCases.map { .focusDirection($0) }

        for command in commands {
            XCTAssertEqual(parseCommand(command.written), command, command.written)
        }
    }
}

final class CommandFrontDoorTests: XCTestCase {
    // MARK: - heed:// URLs

    private func url(_ text: String) -> HeedCommand? {
        guard let url = URL(string: text) else { return nil }
        return parseCommand(host: url.host, path: url.path)
    }

    func testAURLReachesEveryCommand() {
        XCTAssertEqual(url("heed://toggle"), .toggle)
        XCTAssertEqual(url("heed://on"), .enable)
        XCTAssertEqual(url("heed://focus/next"), .focusStep(1))
        XCTAssertEqual(url("heed://set/warpPointer/true"), .set(key: "warpPointer", value: "true"))
        XCTAssertEqual(url("heed://set/excludedWindowTitles/^a/b$"),
                       .set(key: "excludedWindowTitles", value: "^a/b$"))
        XCTAssertEqual(url("heed://hotkeys/release"), .releaseHotkeys)
        XCTAssertEqual(url("heed://settings"), .openSettings)
        XCTAssertEqual(url("heed://focus/previous"), .focusStep(-1))
        XCTAssertEqual(url("heed://focus/left"), .focusDirection(.left))
        XCTAssertEqual(url("heed://focus/7"), .focusNumber(7))
    }

    /// A URL host arrives lowercased, and a trailing slash leaves an empty path segment.
    func testTheShapesAURLArrivesInAreAccepted() {
        XCTAssertEqual(url("heed://Toggle"), .toggle)
        XCTAssertEqual(url("heed://focus/next/"), .focusStep(1))
        XCTAssertEqual(url("heed://toggle/"), .toggle)
    }

    func testAURLAskingForSomethingElseIsRefused() {
        XCTAssertNil(url("heed://quit"))
        XCTAssertNil(url("heed://focus"))
        XCTAssertNil(url("heed://focus/sideways"))
        XCTAssertNil(url("heed://"))
    }

    // MARK: - Command line

    func testTheFlagsReachEveryCommand() {
        XCTAssertEqual(commandLineRequest(["Heed", "--toggle"]), .command(.toggle))
        XCTAssertEqual(commandLineRequest(["Heed", "--on"]), .command(.enable))
        XCTAssertEqual(commandLineRequest(["Heed", "--off"]), .command(.disable))
        XCTAssertEqual(commandLineRequest(["Heed", "--focus", "next"]), .command(.focusStep(1)))
        XCTAssertEqual(commandLineRequest(["Heed", "--focus", "up"]),
                       .command(.focusDirection(.up)))
        XCTAssertEqual(commandLineRequest(["Heed", "--focus", "2"]), .command(.focusNumber(2)))
        XCTAssertEqual(commandLineRequest(["Heed", "--set", "warpPointer", "on"]),
                       .command(.set(key: "warpPointer", value: "on")))
        XCTAssertEqual(commandLineRequest(["Heed", "--reset", "dwellMs"]), .command(.reset(key: "dwellMs")))
        XCTAssertEqual(commandLineRequest(["Heed", "--hotkeys", "release"]), .command(.releaseHotkeys))
    }

    /// Launchd starts Heed with no arguments at all, and macOS can add a `-psn_` one.
    func testNoFlagMeansStartNormally() {
        XCTAssertEqual(commandLineRequest(["Heed"]), CommandLineRequest.none)
        XCTAssertEqual(commandLineRequest([]), CommandLineRequest.none)
        XCTAssertEqual(commandLineRequest(["Heed", "-psn_0_12345"]), CommandLineRequest.none)
    }

    func testAFlagThatIsNotOneIsNamedBack() {
        XCTAssertEqual(commandLineRequest(["Heed", "--quit"]), .unknown("--quit"))
        XCTAssertEqual(commandLineRequest(["Heed", "--focus"]), .unknown("--focus"))
        XCTAssertEqual(commandLineRequest(["Heed", "--focus", "sideways"]), .unknown("--focus"))
    }

    func testTheExecutableNameIsNotAFlag() {
        XCTAssertEqual(commandLineRequest(["--toggle"]), CommandLineRequest.none)
    }
}
