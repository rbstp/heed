import FFMCore
import Foundation

let bundleID = "io.github.rbstp.heed"
/// Distributed notification a second copy of the binary posts to reach the running agent.
let commandNotification = "\(bundleID).command"

struct Config {
    var enabled = true
    var menuBarIcon = true
    var hotkey = "cmd+ctrl+h"
    // Control rather than Shift: Cmd-Shift with the arrows selects a line in every text field, and
    // a Carbon hotkey takes the combination away system-wide.
    var focusNextHotkey = "cmd+ctrl+right"
    var focusPreviousHotkey = "cmd+ctrl+left"
    /// Window 1; the same modifiers with 2 to 9 reach the others. See `Agent.combinations`.
    var focusWindowHotkey = "cmd+ctrl+1"
    /// Off by default: four more exclusive grabs nobody asked for would be hostile.
    var focusLeftHotkey = ""
    var focusRightHotkey = ""
    var focusUpHotkey = ""
    var focusDownHotkey = ""
    /// Move the pointer into a window that took focus without it. Off by default: a cursor that
    /// jumps unasked is worse than one left behind.
    var warpPointer = false
    var warpX = 50
    var warpY = 50
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
    var promptRules: [PromptRule] = []
    var titleExclusions: [TitleRule] = []
    var verbose = false
    var excludedBundleIDs: Set<String> = []

    var windowPolicy: WindowPolicy {
        WindowPolicy(
            requireStandardWindow: requireStandardWindow,
            excludedBundleIDs: excludedBundleIDs,
            titleRules: titleExclusions
        )
    }

    var dwell: Double { Double(dwellMs) / 1000 }
    var poll: Double { Double(pollMs) / 1000 }
    /// Never faster than `poll`.
    var idlePoll: Double { max(Double(idlePollMs) / 1000, poll) }
    var typingCooldown: Double { Double(typingCooldownMs) / 1000 }
    var clickGrace: Double { Double(clickGraceMs) / 1000 }
    var handoverSettle: Double { Double(handoverSettleMs) / 1000 }
    var verifyTimeout: Double { Double(verifyTimeoutMs) / 1000 }

    /// Overlay and transient-chrome apps the pointer would otherwise chase. Mission Control and
    /// Launchpad are drawn by the Dock.
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

    /// Outlook's meeting reminder is structurally indistinguishable from a document window (subrole
    /// AXStandardWindow, minimize and zoom buttons), so it is matched on its exact titles. English and
    /// French only; another locale needs an `excludedWindowTitles` entry.
    static let builtinTitleExclusions: [(bundleID: String?, pattern: String)] = [
        ("com.microsoft.Outlook", "^[0-9]+ (Reminders?|rappels?)$"),
    ]

    static let builtinPromptRules: [PromptRule] = [
        PromptRule(bundleID: "com.apple.finder", identifier: "Progress"),
    ]

    /// Installed, the main bundle identifier already is the domain and a suite name of your own
    /// bundle identifier is rejected by Foundation. As a bare binary the suite is what finds it.
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
        config.hotkey = defaults.string(forKey: "hotkey") ?? config.hotkey
        config.focusNextHotkey = defaults.string(forKey: "focusNextHotkey") ?? config.focusNextHotkey
        config.focusPreviousHotkey =
            defaults.string(forKey: "focusPreviousHotkey") ?? config.focusPreviousHotkey
        config.focusWindowHotkey = defaults.string(forKey: "focusWindowHotkey") ?? config.focusWindowHotkey
        config.focusLeftHotkey = defaults.string(forKey: "focusLeftHotkey") ?? config.focusLeftHotkey
        config.focusRightHotkey = defaults.string(forKey: "focusRightHotkey") ?? config.focusRightHotkey
        config.focusUpHotkey = defaults.string(forKey: "focusUpHotkey") ?? config.focusUpHotkey
        config.focusDownHotkey = defaults.string(forKey: "focusDownHotkey") ?? config.focusDownHotkey
        config.warpPointer = bool("warpPointer", config.warpPointer)
        config.warpX = int("warpX", config.warpX, 0...100)
        config.warpY = int("warpY", config.warpY, 0...100)
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
        config.verbose = bool("verbose", config.verbose)

        config.excludedBundleIDs.formUnion(defaults.stringArray(forKey: "excludedBundleIDs") ?? [])

        let userTitles = defaults.stringArray(forKey: "excludedWindowTitles") ?? []
        let rules = builtinTitleExclusions + userTitles.map { (bundleID: nil, pattern: $0) }
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
