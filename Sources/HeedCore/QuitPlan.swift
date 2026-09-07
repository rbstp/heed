public enum QuitPlan: Equatable, Sendable {
    case terminate
    case unloadLoginAgent(domainTarget: String)

    /// `serviceName` is `XPC_SERVICE_NAME`, which launchd sets to the label of the job it started.
    /// Only the exact label counts: the Finder gives a launched app an `application.<id>.n.n` name.
    public init(serviceName: String?, label: String, uid: UInt32) {
        self = serviceName == label
            ? .unloadLoginAgent(domainTarget: "gui/\(uid)/\(label)")
            : .terminate
    }

    /// `bootout`, not `stop` or `kill`: those leave the job loaded, which is what KeepAlive restarts.
    public var launchctlArguments: [String]? {
        guard case let .unloadLoginAgent(domainTarget) = self else { return nil }
        return ["bootout", domainTarget]
    }

    public var tooltip: String {
        switch self {
        case .terminate:
            "Quit Heed."
        case .unloadLoginAgent:
            "Quit Heed and unload its login agent, so it stays gone until you log in again."
        }
    }
}
