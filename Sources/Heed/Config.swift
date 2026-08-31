import FFMCore
import Foundation

let bundleID = "io.github.rbstp.heed"

struct Config {
    var enabled = true
    var dwellMs = 0
    var pollMs = 40
    var raise = true
    var typingCooldownMs = 500
    var verifyTimeoutMs = 600
    var entryMotionPx = 6
    var ignoreWhenCommandHeld = true
    var menuGuard = true
    var requireStandardWindow = true
    var excludedWindowTitles: [String] = []
    /// Compiled title rules. See `TitleRule` in FFMCore, where the matching is tested.
    var titleExclusions: [TitleRule] = []
    var verbose = false
    var excludedBundleIDs: Set<String> = []

    var dwell: Double { Double(dwellMs) / 1000 }
    var poll: Double { Double(pollMs) / 1000 }
    var typingCooldown: Double { Double(typingCooldownMs) / 1000 }
    var verifyTimeout: Double { Double(verifyTimeoutMs) / 1000 }

    /// Apps that must never receive focus from the pointer.
    ///
    /// Most of these draw overlays or transient chrome that the pointer would otherwise chase --
    /// Mission Control and Launchpad are drawn by the Dock, which is why excluding the Dock covers
    /// them. Raycast and AltTab are here because both put a floating panel under the cursor while
    /// you are in the middle of using them.
    static let builtinExclusions: Set<String> = [
        bundleID,
        "com.apple.dock",
        "com.apple.WindowServer",
        "com.apple.loginwindow",
        "com.apple.controlcenter",
        "com.apple.notificationcenterui",
        "com.apple.systemuiserver",
        "com.apple.screencaptureui",
        "com.apple.Spotlight",
        "com.raycast.macos",
        "com.lwouis.alt-tab-macos",
    ]

    /// Windows that present as ordinary but are transient chrome, keyed by the app that owns them.
    ///
    /// Outlook's meeting reminder is the motivating case, and it is genuinely indistinguishable by
    /// structure: a 400x146 panel reporting subrole AXStandardWindow and role description "standard
    /// window", carrying both minimize and zoom buttons. Its one structural difference from a real
    /// document window -- no AXFullScreenButton -- is useless as a rule, because legitimate
    /// fixed-size windows lack it too (Calculator, for one). So a targeted title rule it is.
    ///
    /// Anchored on the exact titles Outlook uses ("1 Reminder", "3 Reminders"), so an email whose
    /// subject merely contains the word is unaffected.
    static let builtinTitleExclusions: [(bundleID: String?, pattern: String)] = [
        ("com.microsoft.Outlook", "^[0-9]+ Reminders?$"),
    ]
    /// The `dev.rboisvert.focus-macos` defaults domain, however this process was started.
    ///
    /// Installed in the app bundle, the main bundle identifier already *is* that domain, so
    /// `.standard` reads it. A suite name must not be used there: Foundation rejects using your own
    /// bundle identifier as a suite ("does not make sense and will not work") and silently reads
    /// nothing. Run as a bare binary instead -- `make probe`, or straight out of `.build` -- there is
    /// no main bundle identifier to go on, and the suite is what finds the same domain.
    static func store() -> UserDefaults {
        if Bundle.main.bundleIdentifier == bundleID {
            return .standard
        }
        return UserDefaults(suiteName: bundleID) ?? .standard
    }

    static func load() -> Config {
        var config = Config()
        config.excludedBundleIDs = builtinExclusions

        let defaults = store()

        func int(_ key: String, _ current: Int) -> Int {
            defaults.object(forKey: key) == nil ? current : defaults.integer(forKey: key)
        }
        func bool(_ key: String, _ current: Bool) -> Bool {
            defaults.object(forKey: key) == nil ? current : defaults.bool(forKey: key)
        }

        config.enabled = bool("enabled", config.enabled)
        config.dwellMs = max(0, int("dwellMs", config.dwellMs))
        config.pollMs = max(10, int("pollMs", config.pollMs))
        config.raise = bool("raise", config.raise)
        config.typingCooldownMs = max(0, int("typingCooldownMs", config.typingCooldownMs))
        config.verifyTimeoutMs = max(50, int("verifyTimeoutMs", config.verifyTimeoutMs))
        config.entryMotionPx = max(0, int("entryMotionPx", config.entryMotionPx))
        config.ignoreWhenCommandHeld = bool("ignoreWhenCommandHeld", config.ignoreWhenCommandHeld)
        config.menuGuard = bool("menuGuard", config.menuGuard)
        config.requireStandardWindow = bool("requireStandardWindow", config.requireStandardWindow)
        if let titles = defaults.stringArray(forKey: "excludedWindowTitles") {
            config.excludedWindowTitles = titles
        }
        config.verbose = bool("verbose", config.verbose)

        // Additive: users extend the built-in list rather than having to restate it.
        if let extra = defaults.stringArray(forKey: "excludedBundleIDs") {
            config.excludedBundleIDs.formUnion(extra)
        }

        // Built-in rules first, then the user's, which apply to every app.
        var rules: [(bundleID: String?, pattern: String)] = builtinTitleExclusions
        rules += config.excludedWindowTitles.map { (nil, $0) }
        config.titleExclusions = rules.compactMap { rule in
            guard let compiled = TitleRule(bundleID: rule.bundleID, pattern: rule.pattern) else {
                Log.note("ignoring an invalid excludedWindowTitles pattern: \(rule.pattern)")
                return nil
            }
            return compiled
        }
        return config
    }
}
