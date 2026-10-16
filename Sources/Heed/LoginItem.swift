import Foundation
import ServiceManagement

enum LoginItem {
    private static let offeredKey = "loginItemOffered"

    static var enabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Only once, so switching it off in System Settings sticks.
    static func registerOnce() {
        guard Bundle.main.bundleIdentifier == bundleID else { return }
        let defaults = Config.store()
        guard !defaults.bool(forKey: offeredKey), set(true) else { return }
        defaults.set(true, forKey: offeredKey)
    }

    @discardableResult
    static func set(_ on: Bool) -> Bool {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            Log.note(on ? "opening at login" : "no longer opening at login")
            return true
        } catch {
            Log.note("could not \(on ? "add Heed to" : "remove Heed from") the login items: "
                + error.localizedDescription)
            return false
        }
    }
}
