import ChatCore
import Foundation

/// Where the app keeps its own preferences. Demo mode uses a separate domain so its choices
/// never reach the real ones, and tests swap in a throwaway domain.
enum Preferences {
    static var store: UserDefaults = DemoMode.isEnabled ? UserDefaults(suiteName: "app.reglance.demo")! : .standard
}

/// The model and effort last chosen in either composer; new chats start with them.
struct LastModelChoice {
    private static let modelKey = "lastModel"
    /// Missing before Codex and OpenCode: a saved model without it is a Claude model.
    private static let backendKey = "lastModelBackend"
    private static let effortKey = "lastEffort"
    var defaults = Preferences.store

    var model: ChatModel {
        get {
            guard let id = defaults.string(forKey: Self.modelKey) else { return .sonnet }
            let backend = defaults.string(forKey: Self.backendKey).flatMap(Backend.init(rawValue:)) ?? .claude
            return ChatModel(backend: backend, id: id)
        }
        nonmutating set {
            defaults.set(newValue.id, forKey: Self.modelKey)
            defaults.set(newValue.backend.rawValue, forKey: Self.backendKey)
        }
    }

    var effort: Effort {
        get { defaults.string(forKey: Self.effortKey).flatMap(Effort.init(rawValue:)) ?? .automatic }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Self.effortKey) }
    }
}

/// How long the bar may stay hidden before it reopens on a new chat. Zero means never.
enum NewChatAfter {
    static let defaultsKey = "newChatAfterSeconds"
    static let defaultValue: TimeInterval = 5 * 60
    static let options: [(title: String, seconds: TimeInterval)] = [
        ("1 minute", 60), ("5 minutes", 5 * 60), ("15 minutes", 15 * 60), ("1 hour", 60 * 60), ("Never", 0),
    ]

    static func current(in defaults: UserDefaults = Preferences.store) -> TimeInterval {
        defaults.object(forKey: defaultsKey) as? TimeInterval ?? defaultValue
    }
}
