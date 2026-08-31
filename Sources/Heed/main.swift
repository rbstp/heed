import AppKit
import ApplicationServices
import Foundation

/// Whether this process is trusted for Accessibility, optionally showing the system prompt.
func accessibilityTrusted(prompt: Bool) -> Bool {
    let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
}

let agent = Agent()

// One-shot diagnostic; never starts the loop.
// `--probe` inspects the pointer; `--probe X Y` inspects an explicit screen point, which is how you
// examine a window you cannot hover without disturbing it.
if let flag = CommandLine.arguments.firstIndex(of: "--probe") {
    let rest = CommandLine.arguments.dropFirst(flag + 1).prefix(2).compactMap(Double.init)
    agent.probe(at: rest.count == 2 ? CGPoint(x: rest[0], y: rest[1]) : nil)
    exit(0)
}

// A status item needs an application object: NSStatusBar hands items out over the window server
// connection NSApplication establishes, and a click on one arrives as an event only NSApplication's
// loop pulls. `.accessory` states LSUIElement's promise in code -- no Dock icon, no menu of our own
// -- which also covers running as a bare binary, where there is no Info.plist to read it from.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

Log.note("Heed starting (\(bundleID))")

// Both before the permission gate: a reload request must work whether or not the agent got that
// far, and the icon should be there to say the grant is what is missing.
agent.installSignalHandlers()
agent.installMenuBar()
var permissionWaiter: DispatchSourceTimer?

if accessibilityTrusted(prompt: true) {
    agent.start()
} else {
    // Prompt once, then wait quietly. Two deliberate choices here:
    //
    // Don't exit. The LaunchAgent sets KeepAlive, so exiting would respawn the process and prompt
    // again, forever.
    //
    // Don't re-prompt. Passing prompt:true on every check would put the dialog up every two
    // seconds. Later checks are silent, so granting permission in System Settings is picked up on
    // its own without the user having to restart anything.
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

// NSApplication's loop, not RunLoop.main.run() and not dispatchMain(). All three service the main
// run loop, which is how NSWorkspace notifications (Space changes, wake, app termination) and the
// main dispatch queue arrive; only this one also pulls window server events, without which the menu
// bar item draws but cannot be clicked.
app.run()
