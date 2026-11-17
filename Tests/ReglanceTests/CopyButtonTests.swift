import AppKit
import Testing
@testable import Reglance

@Suite struct CopyButtonTests {
    let board = NSPasteboard(name: NSPasteboard.Name("ReglanceTests.copy.\(UUID().uuidString)"))

    @Test func writingReplacesThePasteboardAndReportsSuccess() {
        board.clearContents()
        board.setString("old", forType: .string)
        #expect(CopyButton.write(["reply text" as NSString], to: board))
        #expect(board.string(forType: .string) == "reply text")
        board.releaseGlobally()
    }

    @Test func nothingToCopyLeavesThePasteboardAndReportsFailure() {
        board.clearContents()
        board.setString("old", forType: .string)
        #expect(!CopyButton.write([], to: board))
        #expect(board.string(forType: .string) == "old")
        board.releaseGlobally()
    }
}
