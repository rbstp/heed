import FFMCore
import Foundation

let bundleID = "io.github.rbstp.heed"

struct Config {
    var enabled = true
    var menuBarIcon = true
    /// Parsed by `HotkeySpec` in FFMCore, where the parsing is tested. Empty disables it.
    var hotkey = "cmd+ctrl+h"
    var dwellMs = 0
    var pollMs = 40
    var idlePollMs = 1_000
    var raise = true
    var typingCooldownMs = 500
    var clickGraceMs = 150
    var verifyTimeoutMs = 100
    var entryMotionPx = 6
    var ignoreWhenCommandHeld = true
    var menuGuard = true
    var handoverGuard = true
    var handoverSettleMs = 300
    var requireStandardWindow = true
    var promptGuard = true
    /// Prompts that hold focus; see PromptRule in FFMCore, where the matching is tested.
    var promptRules: [PromptRule] = []
    var excludedWindowTitles: [String] = []
    /// Compiled title rules. See `TitleRule` in FFMCore, where the matching is tested.
    var titleExclusions: [TitleRule] = []
    var verbose = false
    var excludedBundleIDs: Set<String> = []

    /// The tested policy in FFMCore, built from these settings.
    var windowPolicy: WindowPolicy {
        WindowPolicy(
            requireStandardWindow: requireStandardWindow,
            excludedBundleIDs: excludedBundleIDs,
            titleRules: titleExclusions
        )
    }

    var dwell: Double { Double(dwellMs) / 1000 }
    var poll: Double { Double(pollMs) / 1000 }
    /// Never faster than `poll`: a "slow" heartbeat that outpaced the fast one would just be more
    /// wakeups under another name.
    var idlePoll: Double { max(Double(idlePollMs) / 1000, poll) }
    var typingCooldown: Double { Double(typingCooldownMs) / 1000 }
    var clickGrace: Double { Double(clickGraceMs) / 1000 }
    var handoverSettle: Double { Double(handoverSettleMs) / 1000 }
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
    /// subject merely contains the word is unaffected. The title follows the app's locale, so the
    /// rule covers the locales seen so far -- English and French ("1 rappel") -- and any other
    /// locale needs an `excludedWindowTitles` entry until it is added here.
    static let builtinTitleExclusions: [(bundleID: String?, pattern: String)] = [
        ("com.microsoft.Outlook", "^[0-9]+ (Reminders?|rappels?)$"),
    ]
    /// The `io.github.rbstp.heed` defaults domain, however this process was started.
    ///
    /// Installed in the app bundle, the main bundle identifier already *is* that domain, so
    /// `.standard` reads it. A suite name must not be used there: Foundation rejects using your own
    /// bundle identifier as a suite ("does not make sense and will not work") and silently reads
    /// nothing. Run as a bare binary instead -- `make probe`, or straight out of `.build` -- there is
    /// no main bundle identifier to go on, and the suite is what finds the same domain.
    /// Windows that pass every structural check yet are prompts awaiting an answer, keyed on the
    /// accessibility identifier their developer set. Finder's file-operation window is the
    /// motivating case: its replace/skip/stop question reports subrole AXStandardWindow, so
    /// nothing structural marks it, and its title ("Copy") changes with the locale while the
    /// identifier does not.
    static let builtinPromptRules: [PromptRule] = [
        PromptRule(bundleID: "com.apple.finder", identifier: "Progress"),
    ]

    static func store() -> UserDefaults {
        if Bundle.main.bundleIdentifier == bundleID {
            return .standard
        }
        return UserDefaults(suiteName: bundleID) ?? .standard
    }

    static func load() -> Config {
        var config = Config()
        config.excludedBundleIDs = builtinExclusions
        config.promptRules = builtinPromptRules

        let defaults = store()

        /// Clamped to a sane range and logged when clamped: these values are typed by hand into
        /// `defaults write`, and a stray zero used to be able to park the agent for hours.
        func int(_ key: String, _ current: Int, _ limits: ClosedRange<Int>) -> Int {
            guard defaults.object(forKey: key) != nil else { return current }
            let given = defaults.integer(forKey: key)
            let clamped = min(max(given, limits.lowerBound), limits.upperBound)
            if clamped != given {
                Log.note("\(key)=\(given) is outside \(limits.lowerBound)...\(limits.upperBound); "
                    + "using \(clamped)")
            }
            return clamped
        }
        func bool(_ key: String, _ current: Bool) -> Bool {
            defaults.object(forKey: key) == nil ? current : defaults.bool(forKey: key)
        }

        config.enabled = bool("enabled", config.enabled)
        config.menuBarIcon = bool("menuBarIcon", config.menuBarIcon)
        if let hotkey = defaults.string(forKey: "hotkey") {
            config.hotkey = hotkey
        }
        config.dwellMs = int("dwellMs", config.dwellMs, 0...5_000)
        config.pollMs = int("pollMs", config.pollMs, 10...1_000)
        config.idlePollMs = int("idlePollMs", config.idlePollMs, 100...10_000)
        config.raise = bool("raise", config.raise)
        config.typingCooldownMs = int("typingCooldownMs", config.typingCooldownMs, 0...5_000)
        config.clickGraceMs = int("clickGraceMs", config.clickGraceMs, 0...2_000)
        config.verifyTimeoutMs = int("verifyTimeoutMs", config.verifyTimeoutMs, 20...2_000)
        config.entryMotionPx = int("entryMotionPx", config.entryMotionPx, 0...200)
        config.handoverGuard = bool("handoverGuard", config.handoverGuard)
        config.handoverSettleMs = int("handoverSettleMs", config.handoverSettleMs, 0...5_000)
        config.ignoreWhenCommandHeld = bool("ignoreWhenCommandHeld", config.ignoreWhenCommandHeld)
        config.menuGuard = bool("menuGuard", config.menuGuard)
        config.requireStandardWindow = bool("requireStandardWindow", config.requireStandardWindow)
        config.promptGuard = bool("promptGuard", config.promptGuard)
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
