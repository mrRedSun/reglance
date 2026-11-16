import AppKit
import SwiftUI
import Testing
@testable import Reglance

@Suite(.serialized, .headlessWindows)
@MainActor
struct SettingsWindowTests {
    /// Puts a view in a window sized by SwiftUI and returns the window's content height.
    private func contentHeight(of view: some View) async throws -> CGFloat {
        _ = NSApplication.shared
        let host = NSHostingController(rootView: view)
        host.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: host)
        WindowPresentation.prepare(window)
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(300))
        return window.contentLayoutRect.height
    }

    @Test func aTallPaneStopsAtTheMaximumHeight() async throws {
        let height = try await contentHeight(of: SettingsPane {
            Section { ForEach(0..<60) { Text("Row \($0)") } }
        })
        #expect(height == SettingsPane<EmptyView>.maxHeight)
    }

    @Test func aShortPaneFitsItsContents() async throws {
        let height = try await contentHeight(of: SettingsPane {
            Section { Toggle("One setting", isOn: .constant(true)) }
        })
        #expect(height > 20 && height < 200)
    }

    @Test func theRealWindowOpensOnTheGeneralTabWithinTheLimit() async throws {
        _ = NSApplication.shared
        let suite = "settings-window-test-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = SettingsWindowController(hotKey: HotKeySettings(defaults: defaults, register: { _ in true }))
        // Not `show()`: that runs the provider checks, which start the real CLIs.
        let window = controller.window
        WindowPresentation.prepare(window)
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(500))
        #expect(window.title == "General")
        #expect(window.contentLayoutRect.height <= SettingsPane<EmptyView>.maxHeight)
        #expect(window.contentLayoutRect.height > 200)
    }
}
