import AppKit
import ApplicationServices
import Foundation
import HeedCore

func accessibilityTrusted(prompt: Bool) -> Bool {
    let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
}

let usage = "usage: Heed [--probe [X Y]] [--windows] [--toggle] [--on] [--off] "
    + "[--focus next|previous|left|right|up|down|<number>]\n"

let agent = Agent()

// `--probe` inspects the pointer; `--probe X Y` inspects a screen point. Never starts the loop.
if let flag = CommandLine.arguments.firstIndex(of: "--probe") {
    let rest = CommandLine.arguments.dropFirst(flag + 1).prefix(2).compactMap(Double.init)
    agent.probe(at: rest.count == 2 ? CGPoint(x: rest[0], y: rest[1]) : nil)
    exit(0)
}

// `--windows` prints the focus ring as JSON and exits, for anything driving Heed from outside.
if CommandLine.arguments.contains("--windows") {
    agent.listWindows()
    exit(0)
}

// `--toggle`, `--on`, `--off`, `--focus <what>`: tell the running agent and exit. A second process
// cannot reach its state, so the command travels as a distributed notification.
switch commandLineRequest(CommandLine.arguments) {
case .command(let command):
    let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        .contains { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
    guard running else {
        FileHandle.standardError.write(Data("Heed is not running; nothing to tell\n".utf8))
        exit(1)
    }
    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name(commandNotification), object: command.written,
        userInfo: nil, deliverImmediately: true
    )
    print("sent \(command.written) to Heed")
    exit(0)
case .unknown(let flag):
    FileHandle.standardError.write(Data("Heed: \(flag) is not an option I know\n\(usage)".utf8))
    exit(2)
case .none:
    break
}

// A status item needs NSApplication's window server connection and event loop to be clickable.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

Log.note("Heed starting (\(bundleID))")

// All before the permission gate, so a reload, the switch and the commands work while the grant is
// still outstanding.
let delegate = AppDelegate(agent: agent)
app.delegate = delegate
agent.installSignalHandlers()
agent.installMenuBar()
agent.observeCommands()
var permissionWaiter: DispatchSourceTimer?

if accessibilityTrusted(prompt: true) {
    agent.start()
} else {
    // Prompt once and wait: exiting would make KeepAlive respawn and prompt forever, and prompting
    // on every check would put the dialog up every two seconds.
    Log.note("not trusted for Accessibility yet -- grant it in "
        + "System Settings > Privacy & Security > Accessibility. Waiting.")

    let waiter = DispatchSource.makeTimerSource(queue: .main)
    waiter.schedule(deadline: .now() + 2, repeating: 2)
    waiter.setEventHandler {
        guard accessibilityTrusted(prompt: false) else { return }
        Log.note("Accessibility permission granted")
        permissionWaiter?.cancel()
        permissionWaiter = nil
        agent.start()
    }
    waiter.resume()
    permissionWaiter = waiter
}

// Not RunLoop.main.run(): only NSApplication's loop pulls window server events for the status item.
app.run()
