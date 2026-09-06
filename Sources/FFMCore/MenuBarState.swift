/// What the menu bar icon shows, derived from the two facts that decide it.
public struct MenuBarState: Equatable, Sendable {
    /// True when the pointer moves nothing: switched off, or no Accessibility grant.
    public let dimmed: Bool
    public let label: String
    public let tooltip: String
    public let toggleTitle: String
    /// The menu bar glyph: a pointer with attention rays while on, a plain pointer while off, so the
    /// switch position shows by shape as well as by dimming, which also means "no permission".
    public let symbolName: String

    public init(enabled: Bool, trusted: Bool) {
        dimmed = !(enabled && trusted)
        label = "Heed, \(enabled ? "on" : "off")"
        toggleTitle = enabled ? "Turn Heed Off" : "Turn Heed On"
        symbolName = enabled ? "cursorarrow.rays" : "cursorarrow"

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
