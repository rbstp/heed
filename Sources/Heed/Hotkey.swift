import Carbon
import FFMCore

/// A system-wide hotkey, held for as long as this object lives.
///
/// Carbon's `RegisterEventHotKey` rather than an `NSEvent` global monitor, for two reasons. It
/// *consumes* the combination, so the keystroke does not also land in whatever you were typing in --
/// a monitor only observes. And it needs no Accessibility grant, so the switch works while Heed is
/// still waiting for one, which is the moment you are most likely to want to turn it off.
///
/// Main thread only: this registers with the application event target, which is the main run loop's,
/// and the shared table below is unsynchronised on the strength of that.
final class Hotkey {
    /// One handler for the whole process, dispatching on the id the event carries.
    ///
    /// Not one per registration, which is what this was when there was only ever one hotkey. Carbon
    /// calls *every* handler installed for `kEventHotKeyPressed` on a target, with no filtering by
    /// which key was pressed, and stops at the first that reports the event handled -- so a second
    /// handler would run the wrong action for the wrong key and hide the right one completely.
    private static var handler: EventHandlerRef?
    private static var actions: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1

    private let id: UInt32
    private var reference: EventHotKeyRef?

    /// Nil when the combination is already spoken for -- another app registered it first, and macOS
    /// gives it to whoever asked first with no way to take it.
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

        // Exclusive, which decides what happens on a clash rather than leaving it to chance. A
        // non-exclusive registration -- the zero default -- succeeds even when another app already
        // holds the combination, and then *both* actions run on every press, which is a worse
        // outcome than either app winning. Exclusive registration is refused instead, and refusal
        // is something that can be reported. The SDK spells this out at CarbonEvents.h's
        // kEventHotKeyExclusive.
        let identifier = EventHotKeyID(signature: OSType(0x68_65_65_64), id: id)   // 'heed'
        let registered = RegisterEventHotKey(
            UInt32(spec.keyCode), carbonModifiers, identifier, GetApplicationEventTarget(),
            UInt32(kEventHotKeyExclusive), &reference
        )
        guard registered == noErr, reference != nil else {
            // Unregister anything a partial failure left behind before dropping the reference.
            if let reference { UnregisterEventHotKey(reference) }
            reference = nil
            // -9878 is eventHotKeyExistsErr, which is the answer worth naming: the combination is
            // not broken, it belongs to something else.
            Log.note(registered == -9878
                ? "hotkey \(spec.display) is already taken by another app; none registered"
                : "could not register hotkey \(spec.display) (OSStatus \(registered))")
            return nil
        }

        // Last, so a failed registration leaves nothing behind to be fired.
        Hotkey.actions[id] = action
    }

    deinit {
        if let reference { UnregisterEventHotKey(reference) }
        Hotkey.actions[id] = nil
    }

    /// Installs the shared handler once. The handler is never removed: it belongs to the process
    /// rather than to any one registration, and there is nothing to gain by tearing it down and
    /// putting it back every time a combination changes.
    private static func installHandler() -> Bool {
        if handler != nil { return true }

        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                    eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ in
                // The id is read from the event rather than carried as context, which is what lets
                // one handler serve every registration.
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
