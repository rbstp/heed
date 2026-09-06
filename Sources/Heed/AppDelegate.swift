import AppKit
import FFMCore

/// The `heed://` URL scheme: `heed://focus/next`, `heed://toggle`. A running LSUIElement app
/// receives these directly, so a Raycast Quicklink needs no second process and no IPC.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let agent: Agent

    init(agent: Agent) {
        self.agent = agent
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard let command = parseCommand(host: url.host, path: url.path) else {
                Log.note("ignoring a URL I do not understand: \(url.absoluteString)")
                continue
            }
            Log.debug("URL: \(url.absoluteString)")
            agent.perform(command)
        }
    }
}
