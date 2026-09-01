import AppKit
import FFMCore
import Foundation

/// How this process should quit, decided once: what started it does not change while it runs.
///
/// `XPC_SERVICE_NAME` is launchd's own answer to "which job is this", so it is read rather than
/// inferred from the bundle or the executable path -- an installed `Heed.app` launched by hand is
/// the same binary in the same place as the one launchd runs, and only the environment tells them
/// apart.
let quitPlan = QuitPlan(
    serviceName: ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"],
    label: bundleID,
    uid: getuid()
)

/// Quits, which under the login agent means unloading the job rather than exiting: with KeepAlive
/// set, launchd starts a new process within a second of this one leaving.
///
/// The unload is launchd's to do and there is no API for asking it to drop your own job, so
/// `launchctl` asks -- the same `bootout` the README and `make uninstall` run by hand. launchd
/// removes the job from the domain before it signals what is left running in it, so the SIGTERM
/// that ends this process arrives after the unload is committed: waiting here is not a race with
/// it, and being killed part way through the wait is the ordinary outcome rather than a failure.
/// The `terminate` below is for the paths where that signal never comes.
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
    // The handler runs on a queue of Process's own, so waiting for it here is a wait on launchd,
    // not on this thread.
    let finished = DispatchSemaphore(value: 0)
    task.terminationHandler = { _ in finished.signal() }
    do {
        try task.run()
    } catch {
        Log.note("could not run launchctl (\(error.localizedDescription)); exiting anyway")
        NSApp.terminate(nil)
        return
    }

    // Bounded, because the alternative failure is worse: the wait is only here to keep this process
    // alive long enough for launchd to commit the unload, and a menu item still waiting on a
    // launchctl that will never answer would leave the icon unresponsive instead of gone.
    if finished.wait(timeout: .now() + 2) == .timedOut {
        Log.note("\(command) has not answered in 2s; exiting anyway")
    } else if task.terminationStatus != 0 {
        // Reached when the job was not loaded after all, in which case exiting is the whole of it:
        // there is nothing left to start this process again.
        Log.note("\(command) exited \(task.terminationStatus); exiting anyway")
    }
    NSApp.terminate(nil)
}
