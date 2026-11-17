import Foundation
@testable import ChatCore

extension ChatStore {
    /// A store in a fresh temporary folder. Pair it with `defer { store.removeDirectory() }`.
    static func temporary() -> ChatStore {
        ChatStore(directory: FileManager.default.temporaryDirectory.appending(path: "reglance-tests-\(UUID().uuidString)"))
    }

    func removeDirectory() {
        try? FileManager.default.removeItem(at: directory)
    }
}
