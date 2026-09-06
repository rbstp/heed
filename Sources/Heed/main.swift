import AppKit
import ApplicationServices
import Foundation

func accessibilityTrusted(prompt: Bool) -> Bool {
    let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
}

let agent = Agent()

// `--probe` inspects the pointer; `--probe X Y` inspects a screen point. Never starts the loop.
if let flag = CommandLine.arguments.firstIndex(of: "--probe") {
    let rest = CommandLine.arguments.dropFirst(flag + 1).prefix(2).compactMap(Double.init)
    agent.probe(at: rest.count == 2 ? CGPoint(x: rest[0], y: rest[1]) : nil)
    exit(0)
}

// A status item needs NSApplication's window server connection and event loop to be clickable.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

Log.note("Heed starting (\(bundleID))")

// Both before the permission gate, so a reload and the switch work while the grant is outstanding.
agent.installSignalHandlers()
agent.installMenuBar()
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
