import Foundation

/// What one reply used, as its CLI reported it. Shown under the reply while ⌥ is held.
public struct TokenUsage: Codable, Equatable, Sendable {
    /// Prompt tokens sent over all of the turn's model calls, cached ones included.
    public var input: Int
    /// The part of `input` read from the prompt cache.
    public var cachedInput: Int
    /// Generated tokens, reasoning included.
    public var output: Int
    /// Tokens the conversation holds after this reply: the last call's prompt plus its output.
    public var context: Int?
    /// The model's context window, when the CLI reports it.
    public var contextWindow: Int?
    /// API-rate price in US dollars, when the CLI reports one (Claude Code and OpenCode).
    public var cost: Double?
    /// Seconds from sending until the last usage report. Set by `ChatController`.
    public var duration: TimeInterval?

    public init(input: Int, cachedInput: Int = 0, output: Int, context: Int? = nil, contextWindow: Int? = nil,
                cost: Double? = nil, duration: TimeInterval? = nil) {
        self.input = input
        self.cachedInput = cachedInput
        self.output = output
        self.context = context
        self.contextWindow = contextWindow
        self.cost = cost
        self.duration = duration
    }

    /// Generated tokens per second over the whole reply, or nil without a duration.
    public var outputPerSecond: Double? {
        guard let duration, duration > 0, output > 0 else { return nil }
        return Double(output) / duration
    }

    /// The share of the context window still free, 0...1, or nil when either side is unknown.
    public var contextLeft: Double? {
        guard let context, let contextWindow, contextWindow > 0 else { return nil }
        return max(0, 1 - Double(context) / Double(contextWindow))
    }
}

extension Int {
    /// JSON numbers arrive as Int or Double depending on the producer.
    init?(json value: Any?) {
        switch value {
        case let int as Int: self = int
        case let double as Double: self = Int(double)
        default: return nil
        }
    }
}
