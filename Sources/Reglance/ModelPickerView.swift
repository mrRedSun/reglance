import AppKit
import ChatCore
import SwiftUI

/// The pill opens the picker card, which grows out of it (see `modelPickerOverlay`).
struct ModelPickerPill: View {
    let model: ClaudeModel
    let effort: ClaudeEffort
    let isExpanded: Bool
    let action: () -> Void
    @Environment(\.modelPickerNamespace) private var heroNamespace

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(model.displayName).font(.system(size: 12.5, weight: .semibold))
                if effort != .automatic {
                    Text("· \(effort.displayName)").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    .opacity(0.7)
            }
            .padding(.leading, 10)
            .padding(.trailing, 8)
            .frame(height: 26)
            // A plain fill: the composer is already glass, and glass on glass muddies it.
            .background(.fill.tertiary, in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .background {
            // The hero's starting shape. Removed in the same transaction that inserts the
            // card's glass, so SwiftUI interpolates one frame into the other.
            if !isExpanded, let heroNamespace {
                Capsule().fill(.clear).matchedGeometryEffect(id: ModelPickerHero.id, in: heroNamespace)
            }
        }
        // The pill has become the card.
        .opacity(isExpanded ? 0 : 1)
        .fixedSize()
        .anchorPreference(key: ModelPickerAnchorKey.self, value: .bounds) { $0 }
        .padding(.bottom, 2)
        .help("Choose model and effort")
        .accessibilityLabel("Model and effort")
        .accessibilityValue("\(model.displayName), \(effort.displayName)")
    }
}

struct ModelPickerPanel: View {
    @Binding var model: ClaudeModel
    @Binding var effort: ClaudeEffort
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "slider.horizontal.3").foregroundStyle(.secondary)
                Text("Model & effort").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Done", action: onDone)
                    .font(.system(size: 12, weight: .semibold))
                    .buttonStyle(.plain)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.fill.tertiary, in: .capsule)
                    .accessibilityLabel("Done choosing model and effort")
            }

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    sectionTitle("Model")
                    ForEach(ClaudeModel.allCases) { choice in
                        PickerChoice(isSelected: model == choice, action: { model = choice }) {
                            HStack(spacing: 9) {
                                Image(systemName: choice.pickerSymbol)
                                    .font(.system(size: 15))
                                    .frame(width: 20)
                                    .foregroundStyle(model == choice ? Color.accentColor : .secondary)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("\(choice.displayName) 5.5").font(.system(size: 13, weight: .medium))
                                    Text(choice.pickerDetail).font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .accessibilityLabel("\(choice.displayName) 5.5")
                        .accessibilityValue(model == choice ? "Selected" : "")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                RoundedRectangle(cornerRadius: 0.5)
                    .fill(.separator)
                    .frame(width: 1)
                    .frame(maxHeight: .infinity)

                VStack(alignment: .leading, spacing: 2) {
                    sectionTitle("Effort").padding(.bottom, 3)
                    ForEach(ClaudeEffort.allCases) { level in
                        PickerChoice(isSelected: effort == level, verticalPadding: 6, action: { effort = level }) {
                            Text(level.displayName).font(.system(size: 12, weight: effort == level ? .medium : .regular))
                        }
                        .accessibilityLabel("\(level.displayName) effort")
                        .accessibilityValue(effort == level ? "Selected" : "")
                    }
                }
                .frame(width: 156, alignment: .leading)
            }
            .fixedSize(horizontal: false, vertical: true)

            Text("More effort allows deeper reasoning and can take longer.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 438)
        .accessibilityElement(children: .contain)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .padding(.bottom, 4)
    }
}

struct ModelPickerAnchorKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

enum ModelPickerHero {
    static let id = "modelPickerHero"
    /// The card reaches slightly past the pill, so the pill sits inside its corner.
    static let outset: CGFloat = 6
}

extension EnvironmentValues {
    @Entry var modelPickerNamespace: Namespace.ID? = nil
}

extension View {
    /// Hero picker: the pill's capsule grows into the card, which opens over the pill
    /// with its bottom-trailing corner on the pill's. Apply outside the
    /// GlassEffectContainer that holds the pill: the card is its own glass layer,
    /// because overlapping glass in one container fuses into a single shape.
    func modelPickerOverlay(isPresented: Bool, model: Binding<ClaudeModel>, effort: Binding<ClaudeEffort>,
                            reduceMotion: Bool, onDone: @escaping () -> Void,
                            onFrame: @escaping (CGRect) -> Void = { _ in }) -> some View {
        modifier(ModelPickerOverlay(isPresented: isPresented, model: model, effort: effort,
                                    reduceMotion: reduceMotion, onDone: onDone, onFrame: onFrame))
    }
}

private struct ModelPickerOverlay: ViewModifier {
    let isPresented: Bool
    @Binding var model: ClaudeModel
    @Binding var effort: ClaudeEffort
    let reduceMotion: Bool
    let onDone: () -> Void
    let onFrame: (CGRect) -> Void
    @Namespace private var namespace
    @State private var outsideClicks = OutsideClickMonitor()

    func body(content: Content) -> some View {
        content
            .environment(\.modelPickerNamespace, namespace)
            .onChange(of: isPresented, initial: true) { _, presented in
                if presented { outsideClicks.start(onOutside: onDone) } else { outsideClicks.stop() }
            }
            .onDisappear { outsideClicks.stop() }
            .overlayPreferenceValue(ModelPickerAnchorKey.self) { anchor in
                GeometryReader { proxy in
                    // Bottom-aligned, so a card taller than this view overflows upward
                    // instead of below the window.
                    ZStack(alignment: .bottomTrailing) {
                        Color.clear
                        if let anchor {
                            let pill = proxy[anchor]
                            card
                                .offset(x: pill.maxX + ModelPickerHero.outset - proxy.size.width,
                                        y: pill.maxY + ModelPickerHero.outset - proxy.size.height)
                        }
                    }
                    // Without the alignment a card taller than this view is centred on it
                    // and hangs below the window (the main window's composer is short).
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottomTrailing)
                }
            }
    }

    private var card: some View {
        ZStack(alignment: .bottomTrailing) {
            if isPresented {
                ModelPickerPanel(model: $model, effort: $effort, onDone: onDone)
                    // The glass sits behind the contents and morphs from the pill's frame.
                    .background {
                        Color.clear
                            .glassEffect(.regular, in: .rect(cornerRadius: ComposerShape.cornerRadius))
                            .matchedGeometryEffect(id: ModelPickerHero.id, in: namespace)
                    }
                    .transition(reduceMotion ? .opacity
                                : .opacity.combined(with: .scale(scale: 0.85, anchor: .bottomTrailing)))
            }
        }
        .fixedSize()
        // An empty frame while closed, so clicks pass through again.
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
            outsideClicks.cardFrame = $0
            onFrame($0)
        }
    }
}

/// Closes the picker on a click anywhere outside the card, like a transient popover.
/// A click elsewhere in the same window is consumed so it doesn't also press whatever
/// is underneath (such as the pill, which would reopen the card).
private final class OutsideClickMonitor {
    /// The card in its hosting view's coordinates.
    var cardFrame: CGRect = .zero
    private var monitors: [Any] = []

    func start(onOutside: @escaping () -> Void) {
        stop()
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        let local = NSEvent.addLocalMonitorForEvents(matching: clicks) { [weak self] event in
            guard let self, let hosting = event.window?.contentView, !self.cardFrame.isEmpty else { return event }
            let point = hosting.convert(event.locationInWindow, from: nil)
            if self.cardFrame.contains(point) { return event }
            onOutside()
            return nil
        }
        // Clicks in other apps (the floating panel lets clicks outside its glass through).
        let global = NSEvent.addGlobalMonitorForEvents(matching: clicks) { _ in onOutside() }
        monitors = [local, global].compactMap { $0 }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }

    isolated deinit { stop() }
}

private struct PickerChoice<Content: View>: View {
    let isSelected: Bool
    var verticalPadding: CGFloat = 10
    let action: () -> Void
    @ViewBuilder var content: Content
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                content
                Spacer(minLength: 4)
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.accentColor)
                    .opacity(isSelected ? 1 : 0)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, verticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? AnyShapeStyle(Color.accentColor.opacity(0.14))
                                     : AnyShapeStyle(.fill.quaternary.opacity(hovering ? 1 : 0)))
            }
            .contentShape(.rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private extension ClaudeModel {
    var pickerSymbol: String {
        switch self {
        case .haiku: "bolt"
        case .sonnet: "sparkles"
        case .opus: "brain"
        }
    }

    var pickerDetail: String {
        switch self {
        case .haiku: "Quick answers"
        case .sonnet: "Everyday balance"
        case .opus: "Deeper reasoning"
        }
    }
}
