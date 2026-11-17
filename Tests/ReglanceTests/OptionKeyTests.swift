import AppKit
import Testing
@testable import Reglance

private func settle() async {
    for _ in 0..<20 { await Task.yield() }
}

@Test func holdingOptionAloneRevealsTheStatsAndReleasingHidesThem() async {
    let key = OptionKey()
    key.revealDelay = .zero
    key.flagsChanged([.option])
    await settle()
    #expect(key.isHeld)
    key.flagsChanged([])
    #expect(!key.isHeld)
}

@Test func optionChordsAndTypingKeepTheStatsHidden() async {
    let key = OptionKey()
    key.revealDelay = .zero
    key.flagsChanged([.option, .command])
    await settle()
    #expect(!key.isHeld)

    // ⌥E types é: the stats stay hidden until ⌥ is released and pressed again.
    key.flagsChanged([.option])
    await settle()
    key.keyDown(with: [.option])
    #expect(!key.isHeld)
    key.flagsChanged([.option, .shift])
    key.flagsChanged([.option])
    await settle()
    #expect(!key.isHeld)

    key.flagsChanged([])
    key.flagsChanged([.option])
    await settle()
    #expect(key.isHeld)
}

@Test func aQuickOptionChordNeverFlashesTheStats() async throws {
    let key = OptionKey()
    key.revealDelay = .milliseconds(200)
    key.flagsChanged([.option])
    key.flagsChanged([])
    try await Task.sleep(for: .milliseconds(300))
    #expect(!key.isHeld)
}

@Test func statsNumbersStayShort() {
    #expect(NerdStatsView.count(940) == "940")
    #expect(NerdStatsView.count(1000) == "1k")
    #expect(NerdStatsView.count(12_400) == "12k")
    #expect(NerdStatsView.count(3_450) == "3.5k")
    #expect(NerdStatsView.count(1_000_000) == "1M")
    #expect(NerdStatsView.price(0.0042) == "$0.0042")
    #expect(NerdStatsView.price(0.0125) == "$0.013")
    #expect(NerdStatsView.price(1.5) == "$1.50")
}
