import Foundation
import os

enum Log {
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
