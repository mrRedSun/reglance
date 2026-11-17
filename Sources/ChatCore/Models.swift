import Foundation

/// A model on a backend, saved with each chat.
public struct ChatModel: Codable, Hashable, Sendable {
    public var backend: Backend
    /// What the CLI's `--model` / `-m` option takes, e.g. `claude-opus-5-5`, `gpt-5.5`
    /// or OpenCode's `provider/model`.
    public var id: String

    public init(backend: Backend, id: String) {
        self.backend = backend
        self.id = id
    }

    public static func claude(_ model: ClaudeModel) -> ChatModel { ChatModel(backend: .claude, id: model.rawValue) }
    public static let haiku = claude(.haiku)
    public static let sonnet = claude(.sonnet)
    public static let opus = claude(.opus)

    /// A readable name made from the id, for a model its CLI no longer lists:
    /// `claude-sonnet-5-5` becomes "Sonnet 5.5" and `openai/gpt-5.5` "GPT-5.5".
    /// The CLI's own name (`ModelOption.name`) wins whenever it's known.
    public var fallbackName: String {
        let name = id.split(separator: "/").last.map(String.init) ?? id
        if name.hasPrefix("claude-") {
            var parts = name.dropFirst("claude-".count).split(separator: "-").map(String.init)
            // A dated snapshot (`claude-sonnet-4-5-20250929`) reads as its version.
            if let last = parts.last, last.count == 8, last.allSatisfy(\.isNumber) { parts.removeLast() }
            guard let family = parts.first else { return name }
            return ([family.capitalized] + [parts.dropFirst().joined(separator: ".")]).filter { !$0.isEmpty }
                .joined(separator: " ")
        }
        if name.hasPrefix("gpt-") { return "GPT-" + name.dropFirst("gpt-".count) }
        return name
    }

    private enum CodingKeys: String, CodingKey { case backend, id }

    /// Chats saved before backends stored the Claude model id as a plain string.
    public init(from decoder: any Decoder) throws {
        if let legacy = try? decoder.singleValueContainer().decode(String.self) {
            self.init(backend: .claude, id: legacy)
            return
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(backend: try values.decode(Backend.self, forKey: .backend), id: try values.decode(String.self, forKey: .id))
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(backend, forKey: .backend)
        try values.encode(id, forKey: .id)
    }
}

/// One row of the model picker. Names, details and efforts come from each backend's CLI;
/// the app caches them between launches.
public struct ModelOption: Identifiable, Hashable, Codable, Sendable {
    public var model: ChatModel
    public var name: String
    /// A few words under the name, or empty.
    public var detail: String
    /// The efforts this model accepts; `.automatic` first. Only `.automatic` hides the column.
    public var efforts: [Effort]

    public var id: ChatModel { model }
    /// An SF Symbol for the model's family (`ModelSymbol`).
    public var symbol: String { ModelSymbol.symbol(for: model.id) }

    public init(model: ChatModel, name: String, detail: String = "", efforts: [Effort] = [.automatic]) {
        self.model = model
        self.name = name
        self.detail = detail
        self.efforts = efforts
    }
}

/// No CLI says how a model should look, so the popular Claude and OpenAI families get a
/// symbol from their id, on any backend (`openai/gpt-5.5` on OpenCode too). Others sparkle.
public enum ModelSymbol {
    public static func symbol(for id: String) -> String {
        let name = (id.split(separator: "/").last.map(String.init) ?? id).lowercased()
        if name.contains("codex") { return "chevron.left.forwardslash.chevron.right" }
        if name.contains("-mini") || name.contains("-nano") { return "hare" }
        if name.contains("-pro") { return "crown" }
        if name.firstMatch(of: /^o\d/) != nil { return "lightbulb" }
        if name.hasPrefix("gpt") { return "atom" }
        if name.contains("haiku") { return "bolt" }
        if name.contains("sonnet") { return "wand.and.stars" }
        if name.contains("opus") { return "brain" }
        if name.contains("fable") { return "book.closed" }
        return "sparkles"
    }
}

/// Claude and OpenAI model families, so the picker offers only the newest of each:
/// `claude-sonnet-5-5` replaces `claude-sonnet-5`, and `gpt-6-sol` replaces `gpt-5.6-sol`.
/// Other providers' models are always shown.
public enum ModelFamily {
    /// The family and version of a Claude or OpenAI model id, or nil for any other model.
    static func parse(_ id: String) -> (family: String, version: [Int])? {
        let name = (id.split(separator: "/").last.map(String.init) ?? id).lowercased()
        if name.hasPrefix("claude-") {
            // claude-<family>-<major>-<minor>[-<date>]
            var parts = name.dropFirst("claude-".count).split(separator: "-").map(String.init)
            if let last = parts.last, last.count == 8, last.allSatisfy(\.isNumber) { parts.removeLast() }
            guard let family = parts.first else { return nil }
            let version = parts.dropFirst().compactMap { Int($0) }
            guard !version.isEmpty, version.count == parts.count - 1 else { return nil }
            return ("claude-" + family, version)
        }
        // gpt-<version>[-<variant>] and o<version>[-<variant>]: the variant is the family.
        let prefix: String
        var rest: Substring
        if name.hasPrefix("gpt-") {
            prefix = "gpt"; rest = name.dropFirst("gpt-".count)
        } else if name.first == "o", name.dropFirst().first?.isNumber == true {
            prefix = "o"; rest = name.dropFirst()
        } else {
            return nil
        }
        let versionText = rest.prefix { $0.isNumber || $0 == "." }
        let version = versionText.split(separator: ".").compactMap { Int($0) }
        guard !version.isEmpty else { return nil }
        rest = rest.dropFirst(versionText.count)
        return (prefix + rest, version)
    }

    /// The newest model of each family, in the original order. `keeping` stays even when
    /// it's older, so a chat on it still finds its model in the picker.
    public static func latest(_ options: [ModelOption], keeping kept: ChatModel? = nil) -> [ModelOption] {
        var newest: [String: [Int]] = [:]
        for option in options {
            guard let (family, version) = parse(option.model.id) else { continue }
            if newest[family].map({ isOlder($0, than: version) }) ?? true { newest[family] = version }
        }
        return options.filter { option in
            guard option.model != kept, let (family, version) = parse(option.model.id),
                  let top = newest[family] else { return true }
            return !isOlder(version, than: top)
        }
    }

    /// The newest model in `options` of the same family as `model`, or `model` itself when
    /// it's already the newest or isn't a Claude or OpenAI model.
    public static func newest(_ model: ChatModel, in options: [ModelOption]) -> ChatModel {
        guard let (family, version) = parse(model.id) else { return model }
        var best = (model: model, version: version)
        for option in options where option.model.backend == model.backend {
            guard let (otherFamily, otherVersion) = parse(option.model.id), otherFamily == family,
                  isOlder(best.version, than: otherVersion) else { continue }
            best = (option.model, otherVersion)
        }
        return best.model
    }

    /// Compares versions part by part; a missing part counts as 0, so 5 is older than 5.5.
    static func isOlder(_ a: [Int], than b: [Int]) -> Bool {
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0, y = index < b.count ? b[index] : 0
            if x != y { return x < y }
        }
        return false
    }
}
