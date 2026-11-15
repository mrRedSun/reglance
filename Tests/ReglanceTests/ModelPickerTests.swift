import AppKit
import ChatCore
import Observation
import SwiftUI
import Testing
@testable import Reglance

@MainActor
@Observable
private final class PickerSelection {
    var model: ClaudeModel = .sonnet
    var effort: ClaudeEffort = .automatic
    var done = false
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

@Suite(.serialized)
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
        click(x: 370, fromTop: 193)
        try await Task.sleep(for: .milliseconds(30))
        #expect(selection.model == .opus && selection.effort == .high)
        click(x: size.width - 55, fromTop: 50)
        try await Task.sleep(for: .milliseconds(20))
        #expect(selection.done)
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
}
