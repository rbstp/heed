import Foundation
import os

/// stderr logging; the LaunchAgent redirects it to ~/Library/Logs/heed.log.
enum Log {
    /// Written by config reloads on the agent's queue and read from any thread that logs, so it
    /// sits behind a lock rather than `nonisolated(unsafe)` hope.
    private static let verboseState = OSAllocatedUnfairLock(initialState: false)
    static var verbose: Bool {
        get { verboseState.withLock { $0 } }
        set { verboseState.withLock { $0 = newValue } }
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    static func note(_ message: String) {
        emit(message)
    }

    /// Per-decision detail. Off by default; this is the channel that makes focus behaviour
    /// diagnosable, since which of the fallback rungs an app responds to can only be observed.
    static func debug(_ message: @autoclosure () -> String) {
        guard verbose else { return }
        emit(message())
    }

    private static func emit(_ message: String) {
        FileHandle.standardError.write("\(formatter.string(from: Date())) \(message)\n".data(using: .utf8)!)
    }
}
