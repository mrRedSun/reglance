import Foundation

/// Opt-in placeholders for an empty composer, in place of "Ask anything". A new one shows
/// each time the bar opens or a chat starts. Off by default; turned on in Settings.
enum PlayfulPrompts {
    static let defaultsKey = "playfulPrompts"

    static let all = [
        "Do your worst",
        "Go on, stump me",
        "Hit me with it",
        "Try me",
        "Fire away",
        "Out with it",
        "Spill it",
        "Your move",
        "Dare you to ask",
        "Make it interesting",
        "Got a weird one?",
        "Settle a debate",
        "Bring me a puzzle",
        "Pitch me something",
        "Shower thought?",
        "What's bugging you?",
        "What's on your mind?",
        "What are we figuring out?",
        "What are we learning today?",
        "Ask the thing you searched twice",
        "Ask before you overthink it",
        "Type now, think later",
        "Wonder out loud",
        "Curiosity welcome",
        "No question too small",
        "There are no dumb questions",
        "Something on the tip of your tongue?",
        "Need a second opinion?",
        "Let's think it through",
        "Let's untangle something",
        "Let's get to the bottom of it",
        "Recipe, refund or riddle?",
        "Explain it like I'm five?",
        "One quick question…",
        "Make me useful",
        "Ask boldly",
        "Questions go here",
        "Surprise me",
        "What's the plan?",
        "Anything. Literally anything.",
    ]

    /// A random prompt, never `current` again, so reopening always shows a new one.
    static func random(excluding current: String? = nil) -> String {
        all.filter { $0 != current }.randomElement() ?? all[0]
    }
}
