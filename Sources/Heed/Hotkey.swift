import Carbon
import FFMCore

/// A system-wide hotkey, held for as long as this object lives.
///
/// Carbon's `RegisterEventHotKey` rather than an `NSEvent` global monitor, for two reasons. It
/// *consumes* the combination, so the keystroke does not also land in whatever you were typing in --
/// a monitor only observes. And it needs no Accessibility grant, so the switch works while Heed is
/// still waiting for one, which is the moment you are most likely to want to turn it off.
///
/// Main thread only: this registers with the application event target, which is the main run loop's.
final class Hotkey {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    /// Nil when the combination is already spoken for -- another app registered it first, and macOS
    /// gives it to whoever asked first with no way to take it.
    init?(spec: HotkeySpec, action: @escaping () -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        self.action = action

        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                    eventKind: UInt32(kEventHotKeyPressed))
        // A bare C function pointer, so the instance travels as the context pointer -- the same
        // shape as the display reconfiguration callback in Agent. Unretained is safe because the
        // handler is removed in deinit, before this object goes away.
        let installed = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, context in
                guard let context else { return noErr }
                Unmanaged<Hotkey>.fromOpaque(context).takeUnretainedValue().fire()
                return noErr
            },
            1, &pressed, Unmanaged.passUnretained(self).toOpaque(), &handler
        )
        guard installed == noErr else {
            Log.note("could not install the hotkey handler (OSStatus \(installed))")
            return nil
        }

        var carbonModifiers: UInt32 = 0
        if spec.modifiers.contains(.command) { carbonModifiers |= UInt32(cmdKey) }
        if spec.modifiers.contains(.control) { carbonModifiers |= UInt32(controlKey) }
        if spec.modifiers.contains(.option) { carbonModifiers |= UInt32(optionKey) }
        if spec.modifiers.contains(.shift) { carbonModifiers |= UInt32(shiftKey) }

        let identifier = EventHotKeyID(signature: OSType(0x68_65_65_64), id: 1)   // 'heed'
        let registered = RegisterEventHotKey(
            UInt32(spec.keyCode), carbonModifiers, identifier, GetApplicationEventTarget(), 0,
            &reference
        )
        guard registered == noErr, reference != nil else {
            RemoveEventHandler(handler)
            handler = nil
            // -9878 is eventHotKeyExistsErr, which is the answer worth naming: the combination is
            // not broken, it belongs to something else.
            Log.note(registered == -9878
                ? "hotkey \(spec.display) is already taken by another app; none registered"
                : "could not register hotkey \(spec.display) (OSStatus \(registered))")
            return nil
        }
    }

    deinit {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
    }

    private func fire() {
        action()
    }
}
