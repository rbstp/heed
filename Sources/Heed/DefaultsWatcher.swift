import Foundation

/// A `defaults write` from another process reaches a key-value observer; nothing else tells a
/// running app. Own writes reach it too, and reload the same way.
final class DefaultsWatcher: NSObject {
    let defaults: UserDefaults
    var changed: () -> Void = {}
    private let keys: [String]

    init(_ defaults: UserDefaults, keys: [String]) {
        self.defaults = defaults
        self.keys = keys
        super.init()
        for key in keys {
            defaults.addObserver(self, forKeyPath: key, options: [], context: nil)
        }
    }

    deinit {
        for key in keys {
            defaults.removeObserver(self, forKeyPath: key)
        }
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        changed()
    }
}
