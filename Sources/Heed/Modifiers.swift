import AppKit
import Carbon
import HeedCore

// HeedCore names the modifiers; AppKit and Carbon each carry the same four bits in their own
// vocabulary. The translation lives here so a fifth modifier is one row rather than three.
extension HotkeySpec.Modifier {
    var appKit: NSEvent.ModifierFlags {
        switch self {
        case .control: .control
        case .option: .option
        case .shift: .shift
        case .command: .command
        }
    }

    var carbon: UInt32 {
        switch self {
        case .control: UInt32(controlKey)
        case .option: UInt32(optionKey)
        case .shift: UInt32(shiftKey)
        case .command: UInt32(cmdKey)
        }
    }

    static func all(in flags: NSEvent.ModifierFlags) -> Set<Self> {
        let held = flags.intersection(.deviceIndependentFlagsMask)
        return Set(allCases.filter { held.contains($0.appKit) })
    }
}

extension Set where Element == HotkeySpec.Modifier {
    var appKitMask: NSEvent.ModifierFlags { reduce(into: []) { $0.insert($1.appKit) } }

    var carbonMask: UInt32 { reduce(0) { $0 | $1.carbon } }
}
