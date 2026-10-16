import Foundation
import os

enum Log {
    static let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs/heed.log")

    /// Opened from the Finder or at login, stderr is /dev/null.
    static func toFileUnlessTerminal() {
        guard isatty(STDERR_FILENO) == 0 else { return }
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        dup2(fd, STDERR_FILENO)
        close(fd)
    }

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

    static func debug(_ message: @autoclosure () -> String) {
        guard verbose else { return }
        emit(message())
    }

    private static func emit(_ message: String) {
        FileHandle.standardError.write(Data("\(formatter.string(from: Date())) \(message)\n".utf8))
    }
}
