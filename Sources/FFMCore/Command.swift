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

/// The command a `heed://` URL asks for: `heed://focus/next`, `heed://toggle`.
public func parseCommand(host: String?, path: String) -> HeedCommand? {
    parseCommand(path: [host ?? ""] + path.split(separator: "/").map(String.init))
}

/// What a command line asks of a running Heed.
public enum CommandLineRequest: Equatable, Sendable {
    /// No flag asked for anything; start normally.
    case none
    case command(HeedCommand)
    case unknown(String)
}

/// Read `--toggle`, `--on`, `--off`, `--focus <what>` off a command line. The first argument is the
/// executable, and `--probe` is the caller's own business: it never reaches here.
public func commandLineRequest(_ arguments: [String]) -> CommandLineRequest {
    let arguments = arguments.dropFirst()
    guard let index = arguments.firstIndex(where: { $0.hasPrefix("--") }) else { return .none }

    let flag = arguments[index]
    let path = [String(flag.dropFirst(2))] + arguments[arguments.index(after: index)...].prefix(1)
    guard let command = parseCommand(path: path) else { return .unknown(flag) }
    return .command(command)
}
