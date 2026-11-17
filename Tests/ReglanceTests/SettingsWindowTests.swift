import AppKit
import SwiftUI
import Testing
@testable import Reglance

@Suite(.serialized, .headlessWindows)
@MainActor
struct SettingsWindowTests {
    /// Puts a view in a window sized by SwiftUI and returns the window's content height.
    /// Waits until SwiftUI's preferred size has reached the window and holds for 100ms.
    private func settledHeight(of window: NSWindow) async -> CGFloat {
        var last = -1.0, since = ContinuousClock.now
        await waitUntil {
            let height = window.contentLayoutRect.height
            if height != last { last = height; since = .now }
            return ContinuousClock.now - since >= .milliseconds(100)
        }
        return last
    }

    private func contentHeight(of view: some View) async throws -> CGFloat {
        _ = NSApplication.shared
        let host = NSHostingController(rootView: view)
        host.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: host)
        WindowPresentation.prepare(window)
        window.orderFront(nil)
        defer { window.close() }
        return await settledHeight(of: window)
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
        #expect(await waitUntil { window.title == "General" })
        let height = await settledHeight(of: window)
        #expect(height <= SettingsPane<EmptyView>.maxHeight)
        #expect(height > 200)
    }
}
