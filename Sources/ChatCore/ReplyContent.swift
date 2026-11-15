import Foundation

/// A reply split into markdown and widget blocks (design/widgets.md).
public enum ReplySegment: Equatable, Sendable {
    public enum WidgetKind: String, CaseIterable, Sendable {
        case chart, html, document
    }

    case markdown(String)
    case chart(ChartSpec)
    case html(String)
    case document(title: String, body: String)
    /// A widget whose closing fence hasn't streamed in yet.
    case pending(WidgetKind)

    /// Splits `text` at ```chart / ```html / ```document fences. Other fenced code stays in
    /// the markdown, and fences inside it are ignored. A widget that fails to parse becomes
    /// a plain code block. While `streaming`, an unfinished last line that starts a fence is
    /// held back so a half-typed "```cha" doesn't flash as a code block.
    public static func split(_ text: String, streaming: Bool = false) -> [ReplySegment] {
        var segments: [ReplySegment] = []
        var markdown: [Substring] = []
        /// Backtick count of the open fence, and the widget kind if it's a widget.
        var fence: (length: Int, widget: WidgetKind?)?
        var body: [Substring] = []

        func flushMarkdown() {
            let joined = markdown.joined(separator: "\n")
            if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { segments.append(.markdown(joined)) }
            markdown = []
        }

        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if streaming, let last = lines.last, !text.hasSuffix("\n"),
           last.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
            lines.removeLast()
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let ticks = trimmed.prefix(while: { $0 == "`" }).count

            if let open = fence {
                let closes = ticks >= open.length && trimmed.dropFirst(ticks).allSatisfy(\.isWhitespace)
                if let widget = open.widget {
                    if closes {
                        segments.append(make(widget, body: body.joined(separator: "\n")))
                        body = []
                        fence = nil
                    } else {
                        body.append(line)
                    }
                } else {
                    markdown.append(line)
                    if closes { fence = nil }
                }
                continue
            }

            if ticks >= 3 {
                let tag = trimmed.dropFirst(ticks).trimmingCharacters(in: .whitespaces).lowercased()
                if let widget = WidgetKind(rawValue: tag) {
                    flushMarkdown()
                    fence = (ticks, widget)
                } else {
                    markdown.append(line)
                    fence = (ticks, nil)
                }
                continue
            }
            markdown.append(line)
        }

        if let open = fence, let widget = open.widget {
            // Still streaming (or the reply was cut off mid-widget).
            let source = body.joined(separator: "\n")
            segments.append(streaming ? .pending(widget) : codeBlock(widget, source))
        } else {
            flushMarkdown()
        }
        return segments
    }

    private static func codeBlock(_ kind: WidgetKind, _ body: String) -> ReplySegment {
        .markdown("```\(kind.rawValue)\n\(body)\n```")
    }

    private static func make(_ kind: WidgetKind, body: String) -> ReplySegment {
        let fallback = codeBlock(kind, body)
        switch kind {
        case .chart:
            guard let spec = try? ChartSpec.decode(body) else { return fallback }
            return .chart(spec)
        case .html:
            return body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : .html(body)
        case .document:
            let (title, markdown) = parseDocument(body)
            return .document(title: title, body: markdown)
        }
    }

    /// The first line is `title: <name>`; the rest is markdown.
    static func parseDocument(_ body: String) -> (title: String, body: String) {
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.first?.trimmingCharacters(in: .whitespaces),
              first.lowercased().hasPrefix("title:") else { return ("Document", body) }
        let title = first.dropFirst("title:".count).trimmingCharacters(in: .whitespaces)
        let rest = lines.dropFirst().drop(while: { $0.trimmingCharacters(in: .whitespaces).isEmpty })
        return (title.isEmpty ? "Document" : title, rest.joined(separator: "\n"))
    }
}

/// The ```chart JSON schema from design/widgets.md.
public struct ChartSpec: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case bar, line, area, pie, scatter }

    public enum XValue: Codable, Equatable, Hashable, Sendable {
        case text(String)
        case number(Double)

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Double.self) { self = .number(number) }
            else { self = .text(try container.decode(String.self)) }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .text(let text): try container.encode(text)
            case .number(let number): try container.encode(number)
            }
        }

        /// For category axes and pie labels.
        public var label: String {
            switch self {
            case .text(let text): text
            case .number(let number): number.formatted(.number.grouping(.never))   // years: "2020"
            }
        }
    }

    public struct Point: Codable, Equatable, Sendable {
        public var x: XValue
        public var y: Double
        public var series: String?
        public var highlight: Bool?
    }

    public var type: Kind
    public var title: String
    public var xLabel: String?
    public var yLabel: String?
    public var data: [Point]

    enum CodingKeys: String, CodingKey {
        case type, title, data
        case xLabel = "x_label"
        case yLabel = "y_label"
    }

    /// Limits from the schema: at most 50 points and 5 series.
    public static let maxPoints = 50
    public static let maxSeries = 5

    struct Invalid: Error {}

    public static func decode(_ json: String) throws -> ChartSpec {
        var spec = try JSONDecoder().decode(ChartSpec.self, from: Data(json.utf8))
        guard !spec.data.isEmpty, spec.data.allSatisfy({ $0.y.isFinite }) else { throw Invalid() }
        spec.data = Array(spec.data.prefix(maxPoints))
        let series = spec.seriesNames
        if series.count > maxSeries {
            let kept = Set(series.prefix(maxSeries))
            spec.data.removeAll { !kept.contains($0.series ?? "") }
        }
        return spec
    }

    /// Series names in first-appearance order; empty when the chart has a single series.
    public var seriesNames: [String] {
        var seen: [String] = []
        for name in data.compactMap(\.series) where !seen.contains(name) { seen.append(name) }
        return seen
    }

    /// Line, area and scatter charts use a numeric x axis when every x is a number.
    public var hasNumericX: Bool {
        data.allSatisfy { if case .number = $0.x { true } else { false } }
    }
}
