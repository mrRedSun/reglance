import AppKit
import ChatCore
import Observation
import SwiftUI
import Testing
@testable import Reglance

@MainActor
@Observable
private final class PickerSelection {
    var model: ChatModel = .sonnet
    var effort: Effort = .automatic
    var done = false
    var isPresented = false
    var cardFrame: CGRect = .zero
}

/// The pill and its card, as the composer lays them out.
private struct OverlayFixture: View {
    @Bindable var selection: PickerSelection

    var body: some View {
        ModelPickerPill(model: selection.model, effort: selection.effort, isExpanded: selection.isPresented) {}
            .padding(20)
            .frame(width: 520, height: 420, alignment: .bottomTrailing)
            .modelPickerOverlay(isPresented: selection.isPresented, model: $selection.model,
                                effort: $selection.effort, backend: nil, reduceMotion: false, onDone: {},
                                onFrame: { selection.cardFrame = $0 })
    }
}

private struct PickerFixture: View {
    @Bindable var selection: PickerSelection

    var body: some View {
        GlassEffectContainer {
            ModelPickerPanel(model: $selection.model, effort: $selection.effort, onDone: { selection.done = true })
        }
        .padding(24)
    }
}

@Suite(.serialized, .headlessWindows)
@MainActor
struct ModelPickerTests {
    @Test func modelAndEffortAreIndependentColumns() async throws {
        _ = NSApplication.shared
        let selection = PickerSelection()
        let hosting = NSHostingView(rootView: PickerFixture(selection: selection))
        let size = hosting.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        WindowPresentation.prepare(window)
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        hosting.layoutSubtreeIfNeeded()
        func click(x: CGFloat, fromTop y: CGFloat) {
            let point = NSPoint(x: x, y: hosting.isFlipped ? y : hosting.bounds.height - y)
            let location = hosting.convert(point, to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                                               timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil,
                                               eventNumber: 1, clickCount: 1, pressure: 1)!
                window.sendEvent(event)
            }
        }
        click(x: 120, fromTop: 233)
        await waitUntil { selection.done }
        #expect(selection.model == .opus && selection.effort == .automatic)
        #expect(selection.done, "Choosing a model closes the picker")
        selection.done = false
        click(x: 370, fromTop: 193)
        await waitUntil { selection.done }
        #expect(selection.model == .opus && selection.effort == .high)
        #expect(selection.done, "Choosing an effort closes the picker")
        selection.done = false
        click(x: size.width - 55, fromTop: 50)
        #expect(await waitUntil { selection.done })
    }

    @Test func barRemembersTheLastModelAndEffort() throws {
        let suite = "picker-choice-test-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = ComposerSession(chats: makeChats(), lastChoice: LastModelChoice(defaults: defaults))
        #expect(first.model == .sonnet && first.effort == .automatic)
        first.model = .opus
        first.effort = .high
        let next = ComposerSession(chats: makeChats(), lastChoice: LastModelChoice(defaults: defaults))
        #expect(next.model == .opus && next.effort == .high)
        // A choice made in the chats window reaches a bar that's already loaded.
        LastModelChoice(defaults: defaults).model = .haiku
        next.adoptLastChoice()
        #expect(next.model == .haiku && next.effort == .high)
        // A Codex or OpenCode choice keeps its backend.
        let codex = ChatModel(backend: .codex, id: "gpt-5.5")
        next.model = codex
        #expect(LastModelChoice(defaults: defaults).model == codex)
        // A choice saved before backends existed has no backend key and is a Claude model.
        defaults.removeObject(forKey: "lastModelBackend")
        defaults.set(ClaudeModel.opus.rawValue, forKey: "lastModel")
        #expect(LastModelChoice(defaults: defaults).model == .opus)
    }

    @Test func expandedPickerFitsTheFloatingWindowAndClosesOnHide() async throws {
        _ = NSApplication.shared
        let controller = FloatingPanelController(chats: makeChats(), openInWindow: { _ in })
        let bar = controller.composer
        defer { controller.hide() }
        #expect(await showSettled(controller))
        let window = controller.panel.frame
        let hosting = try #require(controller.panel.contentView)
        bar.pickerIsPresented = true
        #expect(await waitUntil { !controller.pickerFrame.isEmpty })
        #expect(controller.panel.frame == window, "The picker grows inside the panel, not by resizing it")
        #expect(hosting.bounds.contains(controller.pickerFrame), "The picker must fit inside the panel: \(controller.pickerFrame)")
        controller.hide()
        #expect(!bar.pickerIsPresented)
    }
}
