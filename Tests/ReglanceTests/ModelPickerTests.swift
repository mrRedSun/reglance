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
        try await Task.sleep(for: .milliseconds(100))
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
        try await Task.sleep(for: .milliseconds(30))
        #expect(selection.model == .opus && selection.effort == .automatic)
        #expect(selection.done, "Choosing a model closes the picker")
        selection.done = false
        click(x: 370, fromTop: 193)
        try await Task.sleep(for: .milliseconds(30))
        #expect(selection.model == .opus && selection.effort == .high)
        #expect(selection.done, "Choosing an effort closes the picker")
        selection.done = false
        click(x: size.width - 55, fromTop: 50)
        try await Task.sleep(for: .milliseconds(20))
        #expect(selection.done)
    }

    @Test func barRemembersTheLastModelAndEffort() throws {
        let suite = "picker-choice-test-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = FloatingBarModel(lastChoice: LastModelChoice(defaults: defaults))
        #expect(first.model == .sonnet && first.effort == .automatic)
        first.model = .opus
        first.effort = .high
        let next = FloatingBarModel(lastChoice: LastModelChoice(defaults: defaults))
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
        let directory = FileManager.default.temporaryDirectory.appending(path: "picker-window-test-\(UUID())")
        let bar = FloatingBarModel()
        let controller = FloatingPanelController(chats: ChatController(store: ChatStore(directory: directory)),
                                                 model: bar, openInWindow: { _ in })
        controller.show()
        defer { controller.hide() }
        // Wait out the entrance spring so the bar is opaque before measuring it.
        try await Task.sleep(for: .milliseconds(600))
        func glassTop() -> CGFloat? {
            // The topmost non-transparent content: the picker sits above the composer.
            guard let hosting = controller.panel.contentView,
                  let image = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
            hosting.cacheDisplay(in: hosting.bounds, to: image)
            for y in 0..<image.pixelsHigh {
                for x in stride(from: 0, to: image.pixelsWide, by: 8) where (image.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.2 {
                    return CGFloat(y) / (CGFloat(image.pixelsHigh) / hosting.bounds.height)
                }
            }
            return nil
        }
        let window = controller.panel.frame
        let collapsedTop = try #require(glassTop())
        bar.pickerIsPresented = true
        try await Task.sleep(for: .milliseconds(600))
        let expandedTop = try #require(glassTop())
        #expect(controller.panel.frame == window, "The picker grows inside the panel, not by resizing it")
        #expect(collapsedTop - expandedTop > 150, "\(collapsedTop) -> \(expandedTop)")
        #expect(expandedTop > 0, "The picker must fit inside the panel")
        controller.hide()
        #expect(!bar.pickerIsPresented)
    }

    @Test func closingShrinksTheCardBackInsteadOfRemovingIt() async throws {
        _ = NSApplication.shared
        let selection = PickerSelection()
        let hosting = NSHostingView(rootView: OverlayFixture(selection: selection))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        /// The topmost drawn row, from the top, in points.
        func contentTop() -> CGFloat? {
            guard let image = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
            hosting.cacheDisplay(in: hosting.bounds, to: image)
            for y in 0..<image.pixelsHigh {
                for x in stride(from: 0, to: image.pixelsWide, by: 4) where (image.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.2 {
                    return CGFloat(y) / (CGFloat(image.pixelsHigh) / hosting.bounds.height)
                }
            }
            return nil
        }
        try await Task.sleep(for: .milliseconds(100))
        let pillTop = try #require(contentTop())
        withAnimation(BloomMotion.animation) { selection.isPresented = true }
        try await Task.sleep(for: .milliseconds(900))
        let openTop = try #require(contentTop())
        #expect(pillTop - openTop > 150, "\(pillTop) -> \(openTop)")
        withAnimation(BloomMotion.animation) { selection.isPresented = false }
        try await Task.sleep(for: .milliseconds(60))
        // Mid-close the card is still on screen, on its way back into the pill.
        let closingTop = try #require(contentTop())
        #expect(pillTop - closingTop > 40, "The card vanished instead of shrinking back: \(pillTop) -> \(closingTop)")
        try await Task.sleep(for: .milliseconds(1500))
        #expect(selection.cardFrame.isEmpty, "\(selection.cardFrame)")
        #expect(abs((contentTop() ?? 0) - pillTop) < 1)
    }
}
