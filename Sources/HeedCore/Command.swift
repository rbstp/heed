import Foundation

public enum HeedCommand: Equatable, Sendable {
    case toggle
    case enable
    case disable
    case focusStep(Int)
    case focusNumber(Int)
    /// A window by the number the window server gives it, which survives the ring being rebuilt.
    case focusWindowID(Int)
    case focusDirection(FocusDirection)
    /// A setting by its defaults key, as the Settings window would set it.
    case set(key: String, value: String)
    case reset(key: String)
    case releaseHotkeys
    case restoreHotkeys
    case openSettings

    public var written: String {
        switch self {
        case .toggle: "toggle"
        case .enable: "enable"
        case .disable: "disable"
        case .focusStep(let delta): delta >= 0 ? "focus/next" : "focus/previous"
        case .focusNumber(let number): "focus/\(number)"
        case .focusWindowID(let id): "focus/id/\(id)"
        case .focusDirection(let direction): "focus/\(direction.rawValue)"
        case .set(let key, let value): "set/\(key)/\(value)"
        case .reset(let key): "reset/\(key)"
        case .releaseHotkeys: "hotkeys/release"
        case .restoreHotkeys: "hotkeys/restore"
        case .openSettings: "settings"
        }
    }
}

public func parseCommand(_ text: String) -> HeedCommand? {
    // `set` keeps its value whole, slashes and all.
    let whole = text.split(separator: "/", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
    if whole.count == 3, whole[0].trimmingCharacters(in: .whitespaces).lowercased() == "set" {
        return parseCommand(path: whole)
    }
    return parseCommand(path: text.split(separator: "/").map(String.init))
}

public func parseCommand(path: [String]) -> HeedCommand? {
    // Verbs are matched lowercased; a key or value is passed on as written.
    let given = path.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    let segments = given.map { $0.lowercased() }

    switch segments.first {
    case "toggle":
        return segments.count == 1 ? .toggle : nil
    case "enable", "on":
        return segments.count == 1 ? .enable : nil
    case "disable", "off":
        return segments.count == 1 ? .disable : nil
    case "focus":
        if segments.count == 3, segments[1] == "id" {
            guard let id = number(segments[2], upTo: Int.max) else { return nil }
            return .focusWindowID(id)
        }
        guard segments.count == 2 else { return nil }
        return parseFocus(segments[1])
    case "set":
        guard given.count >= 3 else { return nil }
        return .set(key: given[1], value: path.count == 3 ? path[2] : given[2...].joined(separator: "/"))
    case "reset":
        return given.count == 2 ? .reset(key: given[1]) : nil
    case "settings":
        return segments.count == 1 ? .openSettings : nil
    case "hotkeys":
        guard segments.count == 2 else { return nil }
        switch segments[1] {
        case "release": return .releaseHotkeys
        case "restore": return .restoreHotkeys
        default: return nil
        }
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
    // Past 9 as well: the shortcuts stop at the digit keys, a window picked from a list does not.
    return number(what, upTo: 999).map { .focusNumber($0) }
}

public func parseCommand(host: String?, path: String) -> HeedCommand? {
    parseCommand((host ?? "") + path)
}

public enum CommandLineRequest: Equatable, Sendable {
    case none
    case command(HeedCommand)
    case unknown(String)
}

public func commandLineRequest(_ arguments: [String]) -> CommandLineRequest {
    let arguments = arguments.dropFirst()
    guard let index = arguments.firstIndex(where: { $0.hasPrefix("--") }) else { return .none }

    let flag = arguments[index]
    let path = [String(flag.dropFirst(2))] + arguments[arguments.index(after: index)...].prefix(2)
    guard let command = parseCommand(path: path) else { return .unknown(flag) }
    return .command(command)
}

private func number(_ text: String, upTo limit: Int) -> Int? {
    guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(text),
          (1...limit).contains(value)
    else { return nil }
    return value
}
