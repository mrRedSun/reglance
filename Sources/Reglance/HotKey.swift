import AppKit
import Carbon.HIToolbox
import Observation

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

/// A key plus Carbon modifier flags, as `RegisterEventHotKey` takes them.
struct HotKeyCombo: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32

    static let `default` = HotKeyCombo(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey))

    /// Nil unless the key is held with ⌘, ⌥ or ⌃, so a global shortcut can't swallow plain typing.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.isDisjoint(with: [.command, .option, .control]) else { return nil }
        var modifiers = 0
        if flags.contains(.control) { modifiers |= controlKey }
        if flags.contains(.option) { modifiers |= optionKey }
        if flags.contains(.shift) { modifiers |= shiftKey }
        if flags.contains(.command) { modifiers |= cmdKey }
        self.init(keyCode: UInt32(event.keyCode), modifiers: UInt32(modifiers))
    }

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    var menuModifiers: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        return flags
    }

    /// The menu item's key equivalent. Carbon matches the physical key, so on a non-Latin
    /// layout this is the key's character on the Latin (ASCII-capable) layout, as macOS shows it.
    /// ⌘ is applied so layouts like "Dvorak – QWERTY ⌘" show the key they type with ⌘ held.
    var keyEquivalent: String {
        Self.specialKeys[Int(keyCode)]?.equivalent ?? latinCharacter ?? ""
    }

    /// Modifiers in Apple's order (⌃⌥⇧⌘), then the key: "⌥Space", "⇧⌘K".
    var displayString: String {
        let symbols: [(Int, String)] = [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")]
        let prefix = symbols.filter { modifiers & UInt32($0.0) != 0 }.map(\.1).joined()
        return prefix + (Self.specialKeys[Int(keyCode)]?.name ?? keyEquivalent.uppercased())
    }

    private var latinCharacter: String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let data = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let layout = Unmanaged<CFData>.fromOpaque(data).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = layout.withUnsafeBytes { bytes in
            UCKeyTranslate(bytes.bindMemory(to: UCKeyboardLayout.self).baseAddress, UInt16(keyCode),
                           UInt16(kUCKeyActionDisplay), (modifiers & UInt32(cmdKey)) >> 8, UInt32(LMGetKbdType()),
                           OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length).lowercased()
    }

    private static func function(_ key: Int) -> String { String(UnicodeScalar(UInt32(key))!) }

    private static let specialKeys: [Int: (name: String, equivalent: String)] = {
        var keys: [Int: (name: String, equivalent: String)] = [
            kVK_Space: ("Space", " "), kVK_Return: ("↩", "\r"), kVK_Tab: ("⇥", "\t"),
            kVK_Delete: ("⌫", "\u{8}"), kVK_ForwardDelete: ("⌦", function(NSDeleteFunctionKey)),
            kVK_Escape: ("⎋", "\u{1b}"),
            kVK_LeftArrow: ("←", function(NSLeftArrowFunctionKey)), kVK_RightArrow: ("→", function(NSRightArrowFunctionKey)),
            kVK_UpArrow: ("↑", function(NSUpArrowFunctionKey)), kVK_DownArrow: ("↓", function(NSDownArrowFunctionKey)),
            kVK_Home: ("↖", function(NSHomeFunctionKey)), kVK_End: ("↘", function(NSEndFunctionKey)),
            kVK_PageUp: ("⇞", function(NSPageUpFunctionKey)), kVK_PageDown: ("⇟", function(NSPageDownFunctionKey)),
        ]
        let fKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                     kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
        for (index, keyCode) in fKeys.enumerated() {
            keys[keyCode] = ("F\(index + 1)", function(NSF1FunctionKey + index))
        }
        return keys
    }()
}

/// The shortcut that shows the floating bar: saved, registered, and paused while a new one is recorded.
@Observable
final class HotKeySettings {
    private(set) var combo: HotKeyCombo
    private(set) var isRecording = false
    private(set) var error: String?

    private static let defaultsKey = "showBarShortcut"
    private let defaults: UserDefaults
    /// Registers the combo in place of the current one and reports success. Nil unregisters.
    private let register: (HotKeyCombo?) -> Bool

    init(defaults: UserDefaults = .standard, register: @escaping (HotKeyCombo?) -> Bool) {
        self.defaults = defaults
        self.register = register
        combo = defaults.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode(HotKeyCombo.self, from: $0) } ?? .default
        if !register(combo) { error = Self.unavailable(combo) }
    }

    func startRecording() {
        error = nil
        isRecording = true
        _ = register(nil)
    }

    func cancelRecording() {
        guard isRecording else { return }
        isRecording = false
        _ = register(combo)
    }

    func record(_ new: HotKeyCombo) {
        isRecording = false
        guard register(new) else {
            error = Self.unavailable(new)
            _ = register(combo)
            return
        }
        error = nil
        combo = new
        defaults.set(try? JSONEncoder().encode(new), forKey: Self.defaultsKey)
    }

    func reset() { record(.default) }

    private static func unavailable(_ combo: HotKeyCombo) -> String {
        "Couldn't use \(combo.displayString). macOS or another app may already use it."
    }
}
