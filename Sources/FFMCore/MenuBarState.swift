/// What the menu bar icon shows, derived from the two facts that decide it.
///
/// Here rather than beside the AppKit code for the reason everything else in this module is here: it
/// is a decision about values, and it is the part of the menu bar that can be wrong quietly. An icon
/// cannot be unit-tested, but what it is supposed to say can.
public struct MenuBarState: Equatable, Sendable {
    /// True when the pointer moves nothing -- switched off, or no Accessibility grant to move it
    /// with. Both look the same on purpose: the icon reports whether Heed is working, not why.
    public let dimmed: Bool
    /// The accessibility label, which is the only thing a VoiceOver user gets.
    public let label: String
    public let tooltip: String
    /// Title of the menu item that flips the switch, so the wording lives with the rest of it.
    public let toggleTitle: String

    public init(enabled: Bool, trusted: Bool) {
        dimmed = !(enabled && trusted)
        label = "Heed, \(enabled ? "on" : "off")"
        toggleTitle = enabled ? "Turn Heed Off" : "Turn Heed On"

        var help = enabled
            ? "Heed is on. Click to turn it off."
            : "Heed is off. Click to turn it on."
        // The grant is named only while Heed is on, and that is a correctness rule rather than a
        // matter of taste: nothing re-checks trust while the agent is not polling, so a tooltip that
        // named a missing permission while off would go on claiming it for as long as Heed stayed
        // off, long after it had been granted. Off explains the dimming by itself, and turning it
        // back on re-reads the grant before this is built again.
        if enabled, !trusted {
            help += " It also needs Accessibility permission, from"
                + " System Settings > Privacy & Security > Accessibility."
        }
        tooltip = help
    }
}
