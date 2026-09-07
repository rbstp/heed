import Carbon
import HeedCore

/// Carbon rather than an `NSEvent` global monitor: it consumes the keystroke and needs no
/// Accessibility grant, so the switch works while Heed is still waiting for one. Main thread only.
final class Hotkey {
    // One handler for the process: Carbon calls every handler installed for kEventHotKeyPressed and
    // stops at the first that claims the event, so one per registration would run the wrong action.
    private static var handler: EventHandlerRef?
    private static var actions: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1

    private let id: UInt32
    private var reference: EventHotKeyRef?

    init?(spec: HotkeySpec, action: @escaping () -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        id = Hotkey.nextID
        Hotkey.nextID += 1

        guard Hotkey.installHandler() else { return nil }

        var carbonModifiers: UInt32 = 0
        if spec.modifiers.contains(.command) { carbonModifiers |= UInt32(cmdKey) }
        if spec.modifiers.contains(.control) { carbonModifiers |= UInt32(controlKey) }
        if spec.modifiers.contains(.option) { carbonModifiers |= UInt32(optionKey) }
        if spec.modifiers.contains(.shift) { carbonModifiers |= UInt32(shiftKey) }

        // Exclusive: a non-exclusive registration succeeds alongside another app's, and then both
        // actions run on every press. Refusal is something that can be reported.
        let identifier = EventHotKeyID(signature: OSType(0x68_65_65_64), id: id)   // 'heed'
        let registered = RegisterEventHotKey(
            UInt32(spec.keyCode), carbonModifiers, identifier, GetApplicationEventTarget(),
            UInt32(kEventHotKeyExclusive), &reference
        )
        guard registered == noErr, reference != nil else {
            if let reference { UnregisterEventHotKey(reference) }
            reference = nil
            Log.note(registered == eventHotKeyExistsErr
                ? "hotkey \(spec.display) is already taken by another app; none registered"
                : "could not register hotkey \(spec.display) (OSStatus \(registered))")
            return nil
        }

        Hotkey.actions[id] = action
    }

    deinit {
        if let reference { UnregisterEventHotKey(reference) }
        Hotkey.actions[id] = nil
    }

    private static func installHandler() -> Bool {
        if handler != nil { return true }

        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                    eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ in
                var pressedID = EventHotKeyID()
                let read = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                    nil, MemoryLayout<EventHotKeyID>.size, nil, &pressedID
                )
                guard read == noErr, let action = Hotkey.actions[pressedID.id] else {
                    return OSStatus(eventNotHandledErr)
                }
                action()
                return noErr
            },
            1, &pressed, nil, &handler
        )
        guard installed == noErr else {
            Log.note("could not install the hotkey handler (OSStatus \(installed))")
            return false
        }
        return true
    }
}
