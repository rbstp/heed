import Foundation

/// Something another program can ask a running Heed to do, behind both the `heed://` URL scheme
/// and the command-line flags, so the two cannot drift apart.
public enum HeedCommand: Equatable, Sendable {
    case toggle
    case enable
    case disable
    /// One step around the focus ring; forward for a positive delta.
    case focusStep(Int)
    /// A window by its number in ring order, 1 to 9.
    case focusNumber(Int)
    case focusDirection(FocusDirection)

    /// The canonical wire form, `focus/next` or `toggle`, which `parseCommand` reads back.
    public var written: String {
        switch self {
        case .toggle: "toggle"
        case .enable: "enable"
        case .disable: "disable"
        case .focusStep(let delta): delta >= 0 ? "focus/next" : "focus/previous"
        case .focusNumber(let number): "focus/\(number)"
        case .focusDirection(let direction): "focus/\(direction.rawValue)"
        }
    }
}

/// Parse `toggle` or `focus/next`: the wire form, and the tail of a `heed://` URL.
public func parseCommand(_ text: String) -> HeedCommand? {
    parseCommand(path: text.split(separator: "/").map(String.init))
}

/// Parse a command from its path segments. Case and surrounding space do not matter.
public func parseCommand(path: [String]) -> HeedCommand? {
    let segments = path
        .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        .filter { !$0.isEmpty }

    switch segments.first {
    case "toggle":
        return segments.count == 1 ? .toggle : nil
    case "enable", "on":
        return segments.count == 1 ? .enable : nil
    case "disable", "off":
        return segments.count == 1 ? .disable : nil
    case "focus":
        guard segments.count == 2 else { return nil }
        return parseFocus(segments[1])
    default:
        return nil
    }
}

private func parseFocus(_ what: String) -> HeedCommand? {
    switch what {
    case "next", "forward":
        return .focusStep(1)
    case "previous", "prev", "back":
        return .focusStep(-1)
    default:
        break
    }
    if let direction = FocusDirection(rawValue: what) { return .focusDirection(direction) }
    guard what.count == 1, let number = Int(what), (1...9).contains(number) else { return nil }
    return .focusNumber(number)
}
