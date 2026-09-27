import Foundation
import HeedCore

let bundleID = "io.github.rbstp.heed"
let commandNotification = "\(bundleID).command"

struct Config {
    var enabled = true
    var menuBarIcon = true
    var hotkey = "cmd+ctrl+h"
    // Control rather than Shift: Cmd-Shift with the arrows selects a line in every text field, and
    // a Carbon hotkey takes the combination away system-wide.
    var focusNextHotkey = "cmd+ctrl+right"
    var focusPreviousHotkey = "cmd+ctrl+left"
    var focusWindowHotkey = "cmd+ctrl+1"
    /// Off by default: four more exclusive grabs nobody asked for would be hostile.
    var focusLeftHotkey = ""
    var focusRightHotkey = ""
    var focusUpHotkey = ""
    var focusDownHotkey = ""
    var windowNumbers = true
    /// Long enough that a shortcut typed at speed is over before anything is drawn.
    var windowNumbersDelayMs = 100
    /// Off by default: a cursor that jumps unasked is worse than one left behind.
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
    var idlePoll: Double { max(Double(idlePollMs) / 1000, poll) }
    var typingCooldown: Double { Double(typingCooldownMs) / 1000 }
    var clickGrace: Double { Double(clickGraceMs) / 1000 }
    var handoverSettle: Double { Double(handoverSettleMs) / 1000 }
    var windowNumbersDelay: Double { Double(windowNumbersDelayMs) / 1000 }
    var verifyTimeout: Double { Double(verifyTimeoutMs) / 1000 }

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

    /// Outlook's meeting reminder is structurally indistinguishable from a document window
    /// (subrole AXStandardWindow, minimize and zoom buttons), so it is matched on its exact
    /// titles. English and French only; another locale needs an `excludedWindowTitles` entry.
    static let builtinTitleExclusions: [(bundleID: String?, pattern: String)] = [
        ("com.microsoft.Outlook", "^[0-9]+ (Reminders?|rappels?)$"),
    ]

    static let builtinPromptRules: [PromptRule] = [
        PromptRule(bundleID: "com.apple.finder", identifier: "Progress"),
    ]

    /// Installed, the bundle identifier already is the domain, and Foundation rejects a suite name
    /// matching your own. As a bare binary the suite is what finds it.
    static func store() -> UserDefaults {
        if Bundle.main.bundleIdentifier == bundleID {
            return .standard
        }
        return UserDefaults(suiteName: bundleID) ?? .standard
    }

    static let keys: [String] = Setting.all.map(\.key)

    static func load() -> Config {
        var config = Config()
        config.excludedBundleIDs = builtinExclusions
        config.promptRules = builtinPromptRules

        let defaults = store()

        for setting in Setting.all {
            switch setting.kind {
            case .bool(let path):
                guard defaults.object(forKey: setting.key) != nil else { continue }
                config[keyPath: path] = defaults.bool(forKey: setting.key)
            case .int(let path, let limits):
                guard defaults.object(forKey: setting.key) != nil else { continue }
                let given = defaults.integer(forKey: setting.key)
                let clamped = min(max(given, limits.lowerBound), limits.upperBound)
                if clamped != given {
                    Log.note("\(setting.key)=\(given) is outside \(limits.lowerBound)...\(limits.upperBound); "
                        + "using \(clamped)")
                }
                config[keyPath: path] = clamped
            case .hotkey(let shortcut):
                guard let text = defaults.string(forKey: setting.key) else { continue }
                config[keyPath: shortcut.keyPath] = text
            case .strings:
                break
            }
        }

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
