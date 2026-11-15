import Carbon.HIToolbox

/// A system-wide hotkey via Carbon `RegisterEventHotKey`. Needs no Accessibility permission.
final class HotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void

    /// `keyCode` is a virtual key code (e.g. `kVK_Space`), `modifiers` Carbon flags (e.g. `optionKey`).
    init?(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        self.action = action

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return OSStatus(eventNotHandledErr) }
                let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
                // Carbon delivers hotkey events on the main thread.
                MainActor.assumeIsolated { hotKey.action() }
                return noErr
            },
            1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handlerRef
        )

        let id = EventHotKeyID(signature: OSType(0x5247_4C43), id: 1) // "RGLC"
        let registerStatus = RegisterEventHotKey(
            UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &hotKeyRef
        )
        guard installStatus == noErr, registerStatus == noErr else {
            NSLog("Reglance: hotkey registration failed (handler \(installStatus), hotkey \(registerStatus))")
            return nil
        }
    }

    isolated deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
