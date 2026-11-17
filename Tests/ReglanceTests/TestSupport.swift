import AppKit
import ChatCore
import Foundation
@testable import Reglance

/// Every test's files live under one folder, removed when the test process exits.
nonisolated private let testRoot = FileManager.default.temporaryDirectory
    .appending(path: "ReglanceTests-\(ProcessInfo.processInfo.processIdentifier)")
nonisolated private let removeTestRootAtExit: Void = {
    atexit { try? FileManager.default.removeItem(at: testRoot) }
}()

/// A fresh folder for one test.
func testDirectory(_ name: String = "test") -> URL {
    _ = removeTestRootAtExit
    return testRoot.appending(path: "\(name)-\(UUID())")
}

/// Chats in a throwaway folder. The default client is demo mode's canned replies, so a test
/// that sends never starts a real CLI.
func makeChats(client: any ChatStreamingClient = DemoClient()) -> ChatController {
    ChatController(store: ChatStore(directory: testDirectory("chats")), client: client)
}

/// Preferences that never reach the test runner's real defaults domain.
func testDefaults() -> UserDefaults {
    let suite = "reglance-tests-\(UUID())"
    return UserDefaults(suiteName: suite)!
}

/// A composer whose model choices go to throwaway preferences.
func makeComposer(chats: ChatController = makeChats()) -> ComposerSession {
    ComposerSession(chats: chats, lastChoice: LastModelChoice(defaults: testDefaults()))
}

/// The first view of `type` in `view`'s subtree.
func findView<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
    if let match = view as? T { return match }
    return view.subviews.lazy.compactMap { findView(type, in: $0) }.first
}

/// Polls until `condition` holds, for at most `timeout`; returns whether it held. Use it
/// instead of a fixed sleep: AppKit and SwiftUI settle at their own pace, slower on CI.
@discardableResult
func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now >= deadline { return false }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return true
}

/// The window's prompt editor, once SwiftUI has put it in the window.
func editor(in window: NSWindow) async -> PromptTextView? {
    var found: PromptTextView?
    await waitUntil {
        found = window.contentView.flatMap { findView(PromptTextView.self, in: $0) }
        return found?.window != nil
    }
    return found
}

/// Shows the floating bar and waits for its glass to be presented.
func showSettled(_ controller: FloatingPanelController) async -> Bool {
    controller.show()
    let presented = await waitUntil { controller.isPresented }
    controller.panel.contentView?.layoutSubtreeIfNeeded()
    return presented
}
