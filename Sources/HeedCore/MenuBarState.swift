public struct MenuBarState: Equatable, Sendable {
    public let dimmed: Bool
    public let label: String
    public let tooltip: String
    public let toggleTitle: String
    public let glyph: Glyph

    public init(enabled: Bool, trusted: Bool) {
        dimmed = !(enabled && trusted)
        label = "Heed, \(enabled ? "on" : "off")"
        toggleTitle = enabled ? "Turn Heed Off" : "Turn Heed On"
        glyph = enabled ? .attending : .idle

        var help = enabled
            ? "Heed is on. Click to turn it off."
            : "Heed is off. Click to turn it on."
        // Named only while on: nothing re-checks trust while off, so the tooltip would go stale.
        if enabled, !trusted {
            help += " It also needs Accessibility permission, from"
                + " System Settings > Privacy & Security > Accessibility."
        }
        tooltip = help
    }
}
