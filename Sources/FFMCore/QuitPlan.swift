/// How to quit: whether leaving is a matter of exiting, or of telling launchd to stop expecting
/// this process back.
///
/// Here rather than beside the AppKit code for the reason the rest of this module is here: it is a
/// decision about values, and it is the half that fails quietly. Installed, Heed runs as a login
/// agent with KeepAlive set, and launchd starts a new process within a second of one exiting -- so
/// a Quit item that merely exited would be a switch with nothing on the other end, the icon back
/// before the menu had finished closing. Unloading the job is what actually stops it.
public enum QuitPlan: Equatable, Sendable {
    /// Nothing is waiting to restart this process -- a copy run out of `.build`, or one launched
    /// from the Finder -- so exiting is the whole of it.
    case terminate
    /// Running as the login agent named by this domain target. Unloading it ends this process and
    /// the respawn together.
    case unloadLoginAgent(domainTarget: String)

    /// - Parameters:
    ///   - serviceName: `XPC_SERVICE_NAME` from the environment, which launchd sets to the label of
    ///     the job it started.
    ///   - label: the login agent's label, which is Heed's bundle identifier.
    ///   - uid: the user whose GUI domain that job lives in.
    public init(serviceName: String?, label: String, uid: UInt32) {
        // Only the exact label counts as being that job. LaunchServices gives an app launched from
        // the Finder an `application.<bundle-id>.<digits>.<digits>` name of its own, and a shell
        // passes down whatever Terminal was handed; taking either for the login agent would unload
        // the running agent on behalf of a second copy that was never it.
        guard serviceName == label else {
            self = .terminate
            return
        }
        self = .unloadLoginAgent(domainTarget: "gui/\(uid)/\(label)")
    }

    /// The `launchctl` arguments that carry this out, or nil when there is nothing to run.
    ///
    /// `bootout` rather than `stop` or `kill`: those two leave the job loaded, which is precisely
    /// how you ask KeepAlive to start it again. Removing the job from the domain is the only one of
    /// the three that means what the menu item says. The plist stays in `~/Library/LaunchAgents`,
    /// so the next login bootstraps it again -- quitting is for this login session, not forever.
    public var launchctlArguments: [String]? {
        switch self {
        case .terminate:
            return nil
        case .unloadLoginAgent(let domainTarget):
            return ["bootout", domainTarget]
        }
    }

    /// The menu item's tooltip. How long quitting lasts is the one thing a Quit item cannot say by
    /// its title, and it is not the same in both cases.
    public var tooltip: String {
        switch self {
        case .terminate:
            return "Quit Heed."
        case .unloadLoginAgent:
            return "Quit Heed and unload its login agent, so it stays gone until you log in again."
        }
    }
}
