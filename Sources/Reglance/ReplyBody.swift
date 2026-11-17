import AppKit
import ChatCore
import Charts
import SwiftUI
import UniformTypeIdentifiers

/// An assistant reply: markdown with widget cards (design/widgets.md) in between.
/// Split again on every streamed chunk; finished segments are `Equatable` views, so
/// SwiftUI only re-renders the one still growing.
extension EnvironmentValues {
    @Entry var conversationTextSize: CGFloat = 14.5
}

/// Extra leading for conversation text, about a 1.65 line height (ChatGPT and t3code read at 1.6–1.75).
func conversationLineSpacing(_ textSize: CGFloat) -> CGFloat { textSize * 0.45 }

struct ReplyBody: View {
    let text: String
    let isStreaming: Bool
    @Environment(\.conversationTextSize) private var textSize

    var body: some View {
        let segments = ReplySegment.split(text, streaming: isStreaming)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(segments.indices, id: \.self) { index in
                SegmentView(segment: segments[index], textSize: textSize).equatable()
            }
        }
    }
}

private struct SegmentView: View, Equatable {
    let segment: ReplySegment
    let textSize: CGFloat

    var body: some View {
        switch segment {
        case .markdown(let text):
            MarkdownText(text)
                .font(.system(size: textSize))
                .lineSpacing(conversationLineSpacing(textSize))
        case .chart(let spec):
            ChartCard(spec: spec)
        case .html(let source):
            HTMLCard(source: source)
        case .document(let title, let body):
            DocumentCard(title: title, text: body)
        case .pending(let kind):
            PlaceholderCard(kind: kind)
        }
    }
}

// MARK: - Card chrome

/// The translucent 16pt card from design/chat-view.html (`.card`).
private struct CardBackground: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        content
            .background(shape.fill(.white.opacity(colorScheme == .dark ? 0.08 : 0.45)))
            .overlay(shape.strokeBorder(colorScheme == .dark ? .white.opacity(0.22) : .black.opacity(0.08), lineWidth: 0.5))
            .clipShape(shape)
    }
}

extension View {
    func cardBackground() -> some View { modifier(CardBackground()) }
}

/// Header ("CHART  Title  [buttons]") over the widget content.
struct WidgetCard<Actions: View, Content: View>: View {
    let kind: String
    let title: String
    @ViewBuilder var actions: Actions
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(kind.uppercased())
                    .font(.system(size: 11, weight: .medium))
                    .tracking(0.44)
                    .foregroundStyle(.tertiary)
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                actions
            }
            .frame(minHeight: 24)
            .padding(EdgeInsets(top: 9, leading: 12, bottom: 0, trailing: 8))
            content
        }
        .cardBackground()
    }
}

private struct PlaceholderCard: View {
    let kind: ReplySegment.WidgetKind

    var body: some View {
        let label = switch kind {
        case .chart: "Drawing chart…"
        case .html: "Building page…"
        case .document: "Writing document…"
        }
        ShimmerText(text: label)
            .font(.system(size: 13))
            .frame(maxWidth: .infinity)
            .frame(height: kind == .document ? 60 : 120)
            .cardBackground()
    }
}

struct PillButton: View {
    let title: String
    /// Sizes the pill when its title changes, so the row doesn't shift.
    var widestTitle: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                if let widestTitle { Text(widestTitle).hidden() }
                Text(title)
            }
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 11)
                .frame(height: 26)
                .background(Capsule().fill(.primary.opacity(hovering ? 0.16 : 0.1)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Chart

private struct ChartCard: View {
    let spec: ChartSpec
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        WidgetCard(kind: "Chart", title: spec.title) {
            CopyButton(help: "Copy as image") { renderImage().map { [$0] } }
        } content: {
            ChartBody(spec: spec)
                .frame(height: spec.type == .pie ? 190 : 170)
                .padding(EdgeInsets(top: 8, leading: 12, bottom: 10, trailing: 12))
        }
    }

    private func renderImage() -> NSImage? {
        let image = VStack(alignment: .leading, spacing: 10) {
            Text(spec.title).font(.system(size: 14, weight: .semibold))
            ChartBody(spec: spec).frame(width: 520, height: spec.type == .pie ? 220 : 200)
        }
        .padding(18)
        .background(colorScheme == .dark ? Color(white: 0.12) : .white)
        .environment(\.colorScheme, colorScheme)
        let renderer = ImageRenderer(content: image)
        renderer.scale = 2
        return renderer.nsImage
    }
}

/// Swift Charts rendering of the ```chart schema.
struct ChartBody: View {
    let spec: ChartSpec

    private static let bar = LinearGradient(colors: [Color(red: 0.49, green: 0.75, blue: 1), Color.accentColor.opacity(0.75)],
                                            startPoint: .top, endPoint: .bottom)
    private static let highlight = LinearGradient(colors: [Color(red: 1, green: 0.7, blue: 0.48), Color(red: 1, green: 0.48, blue: 0.35).opacity(0.8)],
                                                  startPoint: .top, endPoint: .bottom)
    private static let palette: [Color] = [.accentColor, Color(red: 1, green: 0.48, blue: 0.35), .teal, .purple, .pink, .yellow, .green, .indigo]

    var body: some View {
        let hasSeries = !spec.seriesNames.isEmpty
        let numeric = spec.hasNumericX && spec.type != .bar
        let xName = spec.xLabel ?? "x", yName = spec.yLabel ?? "y"
        let labelBars = spec.type == .bar && !hasSeries && spec.data.count <= 12

        Chart(spec.data.indices, id: \.self) { index in
            let point = spec.data[index]
            switch spec.type {
            case .bar:
                let mark = BarMark(x: .value(xName, point.x.label), y: .value(yName, point.y))
                    .cornerRadius(5)
                if let series = point.series {
                    mark.foregroundStyle(by: .value("Series", series))
                        .position(by: .value("Series", series))
                } else {
                    mark.foregroundStyle(point.highlight == true ? Self.highlight : Self.bar)
                        .annotation(position: .top, spacing: 2) {
                            if labelBars {
                                Text(point.y.formatted()).font(.system(size: 10.5, weight: .semibold))
                            }
                        }
                }
            case .pie:
                SectorMark(angle: .value(yName, point.y), innerRadius: .ratio(0.55), angularInset: 1.5)
                    .cornerRadius(4)
                    .foregroundStyle(by: .value(xName, point.x.label))
                    .opacity(spec.data.contains { $0.highlight == true } && point.highlight != true ? 0.55 : 1)
            case .line, .area, .scatter:
                if numeric, case .number(let x) = point.x {
                    xyMark(point, x: .value(xName, x), yName: yName)
                } else {
                    xyMark(point, x: .value(xName, point.x.label), yName: yName)
                }
            }
        }
        .chartXScale(domain: .automatic(includesZero: !numeric))
        .chartXAxis {
            if numeric {
                // Years: "2020", not "2,020", and no "2020.5" between whole-number points.
                AxisMarks(values: wholeNumberTicks.map { .stride(by: $0) } ?? .automatic) { value in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel { if let x = value.as(Double.self) { Text(x.formatted(.number.grouping(.never))) } }
                }
            } else {
                AxisMarks()
            }
        }
        .chartForegroundStyleScale(range: Self.palette)
        .chartLegend(hasSeries || spec.type == .pie ? .visible : .hidden)
        .chartLegend(position: spec.type == .pie ? .trailing : .bottom)
        .chartXAxisLabel(spec.type == .pie ? "" : spec.xLabel ?? "")
        .chartYAxisLabel(spec.type == .pie ? "" : spec.yLabel ?? "")
        .font(.system(size: 10.5))
    }

    /// Tick spacing for numeric x values that are all whole numbers (years, counts):
    /// a whole step giving at most ~8 ticks.
    private var wholeNumberTicks: Double? {
        let xs = spec.data.compactMap { if case .number(let x) = $0.x { x } else { nil } }
        guard xs.allSatisfy({ $0 == $0.rounded() }), let low = xs.min(), let high = xs.max(), high > low else { return nil }
        return max(1, ((high - low) / 8).rounded(.up))
    }

    @ChartContentBuilder
    private func xyMark<X: Plottable>(_ point: ChartSpec.Point, x: PlottableValue<X>, yName: String) -> some ChartContent {
        let y = PlottableValue.value(yName, point.y)
        switch spec.type {
        case .area:
            if let series = point.series {
                AreaMark(x: x, y: y).foregroundStyle(by: .value("Series", series))
            } else {
                AreaMark(x: x, y: y).foregroundStyle(Self.bar.opacity(0.6))
            }
        case .scatter:
            if let series = point.series {
                PointMark(x: x, y: y).foregroundStyle(by: .value("Series", series))
            } else {
                PointMark(x: x, y: y).foregroundStyle(point.highlight == true ? Self.highlight : Self.bar)
                    .symbolSize(point.highlight == true ? 90 : 45)
            }
        default:
            if let series = point.series {
                LineMark(x: x, y: y).foregroundStyle(by: .value("Series", series))
                    .lineStyle(StrokeStyle(lineWidth: 2))
            } else {
                LineMark(x: x, y: y).foregroundStyle(Color.accentColor)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                if point.highlight == true {
                    PointMark(x: x, y: y).foregroundStyle(Self.highlight).symbolSize(60)
                }
            }
        }
    }
}

// MARK: - Document

private struct DocumentCard: View {
    let title: String
    let text: String
    @State private var expanded = false

    var body: some View {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).count
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(LinearGradient(colors: [.white.opacity(0.9), Color(red: 0.92, green: 0.94, blue: 1).opacity(0.8)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: 34, height: 40)
                    .overlay(alignment: .bottom) {
                        Text("MD").font(.system(size: 8.5, weight: .bold)).foregroundStyle(Color.accentColor).padding(.bottom, 5)
                    }
                    .shadow(color: .black.opacity(0.2), radius: 1.5, y: 1)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                    Text("Markdown · \(lines) \(lines == 1 ? "line" : "lines")")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                CopyButton(style: .pill) { [text as NSString] }
                PillButton(title: "Save…", action: save)
            }
            .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 8))
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { expanded.toggle() } }
            .help(expanded ? "Hide contents" : "Show contents")

            if expanded {
                Divider().opacity(0.5)
                MarkdownText(text)
                    .font(.system(size: 13.5))
                    .lineSpacing(3)
                    .padding(12)
            }
        }
        .cardBackground()
    }

    private func save() {
        let panel = NSSavePanel()
        let name = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = name + ".md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        // Above the floating prompt panel.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        NSApp.activate()
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do { try text.write(to: url, atomically: true, encoding: .utf8) } catch { NSAlert(error: error).runModal() }
        }
    }
}
