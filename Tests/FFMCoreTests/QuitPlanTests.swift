import XCTest
@testable import FFMCore

final class QuitPlanTests: XCTestCase {
    private let label = "io.github.rbstp.heed"

    /// The case the type exists for. Installed, Heed is a login agent with KeepAlive set, so
    /// exiting is not quitting: launchd has a new process up within a second, and the menu item
    /// that asked for it looks broken. The job has to come out of the domain.
    func testUnloadsTheJobWhenLaunchdStartedIt() {
        XCTAssertEqual(QuitPlan(serviceName: label, label: label, uid: 501),
                       .unloadLoginAgent(domainTarget: "gui/501/\(label)"))
    }

    /// The target names the GUI domain of the user this process belongs to, which is the only
    /// domain a login agent is ever in -- and the uid is read rather than assumed, since 501 is
    /// only the first account macOS creates.
    func testTargetsTheGUIDomainOfThisUser() {
        XCTAssertEqual(QuitPlan(serviceName: label, label: label, uid: 502).launchctlArguments,
                       ["bootout", "gui/502/io.github.rbstp.heed"])
    }

    /// `bootout` and not `stop` or `kill`: both of those leave the job loaded, which is exactly how
    /// you ask KeepAlive to start it again.
    func testUnloadsRatherThanMerelyStopping() {
        let arguments = QuitPlan(serviceName: label, label: label, uid: 501).launchctlArguments
        XCTAssertEqual(arguments?.first, "bootout")
    }

    /// Nothing but the exact label is that job. A second copy -- launched from the Finder, where
    /// LaunchServices makes a service name of its own, or run out of `.build` -- has to quit itself
    /// and leave the agent running: unloading it there would stop a process the user never clicked.
    func testEveryOtherWayOfBeingStartedJustExits() {
        let others: [String?] = [
            nil,                          // no launchd, no LaunchServices
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

    /// How long quitting lasts is the one thing the title cannot say, so the tooltip says it -- and
    /// only in the case where it is true.
    func testTooltipSaysHowLongQuittingLasts() {
        XCTAssertTrue(QuitPlan(serviceName: label, label: label, uid: 501)
            .tooltip.contains("log in again"))
        XCTAssertFalse(QuitPlan(serviceName: nil, label: label, uid: 501)
            .tooltip.contains("log in again"))
    }
}
