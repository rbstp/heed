import AppKit
import Foundation
import HeedCore

/// `XPC_SERVICE_NAME` is launchd's own answer to which job this is; the bundle and path are the same
/// whether launchd or a hand launch started the installed app.
let quitPlan = QuitPlan(
    serviceName: ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"],
    label: bundleID,
    uid: getuid()
)

/// Under the login agent this unloads the job through `launchctl`, since there is no API for
/// dropping your own job. launchd removes the job before signalling it, so the SIGTERM that ends this
/// process arrives after the unload is committed; being killed mid-wait is the ordinary outcome.
func quitHeed() {
    dispatchPrecondition(condition: .onQueue(.main))

    guard let arguments = quitPlan.launchctlArguments else {
        Log.note("quitting")
        NSApp.terminate(nil)
        return
    }

    let command = "launchctl \(arguments.joined(separator: " "))"
    Log.note("quitting: \(command) -- Heed returns at the next login")

    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    task.arguments = arguments
    let finished = DispatchSemaphore(value: 0)
    task.terminationHandler = { _ in finished.signal() }
    do {
        try task.run()
    } catch {
        Log.note("could not run launchctl (\(error.localizedDescription)); exiting anyway")
        NSApp.terminate(nil)
        return
    }

    // Bounded: a launchctl that never answers must not leave the icon unresponsive instead of gone.
    if finished.wait(timeout: .now() + 2) == .timedOut {
        Log.note("\(command) has not answered in 2s; exiting anyway")
    } else if task.terminationStatus != 0 {
        Log.note("\(command) exited \(task.terminationStatus); exiting anyway")
    }
    NSApp.terminate(nil)
}
