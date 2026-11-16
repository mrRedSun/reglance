import ChatCore
import Foundation
import Testing
@testable import Reglance

/// Keeps test windows invisible and the test runner in the background, so a test run
/// doesn't cover or take focus from what you're doing. Add `.headlessWindows` to every
/// suite or test that shows a window.
struct HeadlessWindows: SuiteTrait, TestTrait, TestScoping {
    var isRecursive: Bool { true }

    func provideScope(for test: Test, testCase: Test.Case?,
                      performing function: @Sendable () async throws -> Void) async throws {
        // Never switched back off: suites run in parallel and nothing in tests needs it off.
        await MainActor.run {
            WindowPresentation.isHeadless = true
            // Opening a window refreshes the models; tests must not start the real CLIs
            // or write the real cache.
            if !(ModelLibrary.shared.isFixedForTests) {
                ModelLibrary.shared = ModelLibrary(fixed: [.claude: DemoContent.models],
                                                   defaults: UserDefaults(suiteName: "model-library-tests")!)
            }
        }
        try await function()
    }
}

extension Trait where Self == HeadlessWindows {
    static var headlessWindows: Self { Self() }
}
