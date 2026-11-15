import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import Reglance

private func makeDefaults() -> UserDefaults {
    let name = "HotKeySettingsTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

private func keyDown(_ characters: String, keyCode: Int, modifiers: NSEvent.ModifierFlags) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                     windowNumber: 0, context: nil, characters: characters,
                     charactersIgnoringModifiers: characters, isARepeat: false, keyCode: UInt16(keyCode))!
}

// Letters depend on the keyboard layout, so exact labels are checked with Space and F-keys.
private let commandShiftF5 = HotKeyCombo(keyCode: UInt32(kVK_F5), modifiers: UInt32(cmdKey | shiftKey))

@MainActor
@Test func shortcutDefaultsToOptionSpaceAndRegistersIt() {
    var registered: [HotKeyCombo?] = []
    let settings = HotKeySettings(defaults: makeDefaults()) { registered.append($0); return true }
    #expect(settings.combo == .default)
    #expect(settings.combo.displayString == "⌥Space")
    #expect(registered == [.default])
    #expect(settings.error == nil)
}

@MainActor
@Test func recordedShortcutIsRegisteredSavedAndRestoredOnNextLaunch() {
    let defaults = makeDefaults()
    var registered: [HotKeyCombo?] = []
    let settings = HotKeySettings(defaults: defaults) { registered.append($0); return true }
    settings.startRecording()
    #expect(settings.isRecording)
    #expect(registered.last == .some(nil)) // paused, so pressing the old shortcut doesn't toggle the bar
    settings.record(commandShiftF5)
    #expect(!settings.isRecording)
    #expect(registered.last == commandShiftF5)
    #expect(settings.combo.displayString == "⇧⌘F5")

    let relaunched = HotKeySettings(defaults: defaults) { _ in true }
    #expect(relaunched.combo == commandShiftF5)
}

@MainActor
@Test func cancellingRecordingRestoresTheCurrentShortcut() {
    var registered: [HotKeyCombo?] = []
    let settings = HotKeySettings(defaults: makeDefaults()) { registered.append($0); return true }
    settings.startRecording()
    settings.cancelRecording()
    #expect(!settings.isRecording)
    #expect(registered.last == .default)
    #expect(settings.combo == .default)
}

@MainActor
@Test func failedRegistrationKeepsTheOldShortcutAndReportsIt() {
    let defaults = makeDefaults()
    let settings = HotKeySettings(defaults: defaults) { $0 != commandShiftF5 }
    settings.startRecording()
    settings.record(commandShiftF5)
    #expect(settings.combo == .default)
    #expect(settings.error != nil)
    #expect(HotKeySettings(defaults: defaults) { _ in true }.combo == .default)
}

@MainActor
@Test func resetReturnsToOptionSpace() {
    let settings = HotKeySettings(defaults: makeDefaults()) { _ in true }
    settings.record(commandShiftF5)
    settings.reset()
    #expect(settings.combo == .default)
}

@MainActor
@Test func comboFromKeyEventNeedsCommandOptionOrControl() {
    #expect(HotKeyCombo(event: keyDown("k", keyCode: kVK_ANSI_K, modifiers: [])) == nil)
    #expect(HotKeyCombo(event: keyDown("K", keyCode: kVK_ANSI_K, modifiers: [.shift])) == nil)
    let combo = HotKeyCombo(event: keyDown("", keyCode: kVK_F5, modifiers: [.control, .option, .function]))
    #expect(combo?.displayString == "⌃⌥F5")
    #expect(combo?.modifiers == UInt32(controlKey | optionKey))
    #expect(combo?.menuModifiers == [.control, .option])
    #expect(combo?.keyEquivalent == String(UnicodeScalar(UInt32(NSF5FunctionKey))!))
    let letter = HotKeyCombo(event: keyDown("k", keyCode: kVK_ANSI_K, modifiers: [.command]))
    #expect(letter?.keyEquivalent.count == 1)
    #expect(letter?.displayString == "⌘" + (letter?.keyEquivalent.uppercased() ?? "?"))
    #expect(HotKeyCombo(event: keyDown(" ", keyCode: kVK_Space, modifiers: [.command]))?.displayString == "⌘Space")
}
