import Foundation

/// stderr logging; the LaunchAgent redirects it to ~/Library/Logs/focus-macos.log.
enum Log {
    nonisolated(unsafe) static var verbose = false

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
