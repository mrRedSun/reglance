import Testing
@testable import Reglance

@Test func playfulPromptsAreUniqueAndNeverRepeatBackToBack() {
    #expect(PlayfulPrompts.all.count == 40)
    #expect(Set(PlayfulPrompts.all).count == PlayfulPrompts.all.count)
    // Short enough for one line beside the composer's buttons.
    #expect(PlayfulPrompts.all.allSatisfy { $0.count <= 36 })
    var current = PlayfulPrompts.random()
    for _ in 0..<200 {
        let next = PlayfulPrompts.random(excluding: current)
        #expect(next != current)
        current = next
    }
}
