import XCTest
@testable import HeedCore

final class QuitPlanTests: XCTestCase {
    private let label = "io.github.rbstp.heed"

    /// Under KeepAlive, exiting is not quitting: launchd has a new process up within a second.
    func testUnloadsTheJobWhenLaunchdStartedIt() {
        XCTAssertEqual(QuitPlan(serviceName: label, label: label, uid: 501),
                       .unloadLoginAgent(domainTarget: "gui/501/\(label)"))
    }

    /// The uid is read rather than assumed; 501 is only the first account macOS creates.
    func testTargetsTheGUIDomainOfThisUser() {
        XCTAssertEqual(QuitPlan(serviceName: label, label: label, uid: 502).launchctlArguments,
                       ["bootout", "gui/502/io.github.rbstp.heed"])
    }

    func testUnloadsRatherThanMerelyStopping() {
        let arguments = QuitPlan(serviceName: label, label: label, uid: 501).launchctlArguments
        XCTAssertEqual(arguments?.first, "bootout")
    }

    /// A second copy (Finder launch, `.build`) must quit itself and leave the agent running.
    func testEveryOtherWayOfBeingStartedJustExits() {
        let others: [String?] = [
            nil,
            "",
            "0",                          // what a shell under Terminal passes down
            "application.\(label).7.8",   // launched from the Finder
            "\(label).loop",              // near miss, not the label
        ]
        for serviceName in others {
            let plan = QuitPlan(serviceName: serviceName, label: label, uid: 501)
            XCTAssertEqual(plan, .terminate,
                           "XPC_SERVICE_NAME \(serviceName ?? "(unset)") is not the login agent")
            XCTAssertNil(plan.launchctlArguments, "nothing to run when there is no job to unload")
        }
    }

    func testTooltipSaysHowLongQuittingLasts() {
        XCTAssertTrue(QuitPlan(serviceName: label, label: label, uid: 501)
            .tooltip.contains("log in again"))
        XCTAssertFalse(QuitPlan(serviceName: nil, label: label, uid: 501)
            .tooltip.contains("log in again"))
    }
}
