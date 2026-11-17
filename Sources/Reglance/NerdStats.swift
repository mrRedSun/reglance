import AppKit
import ChatCore
import Observation
import SwiftUI

/// Holding ⌥ on its own reveals the stats under replies, the way ⌥ reveals extra menu items.
/// Only ⌥ counts: ⌥⇧, ⌥⌘ and typing ⌥E (é) leave the stats hidden.
@Observable
final class OptionKey {
    static let shared = OptionKey()

    private(set) var isHeld = false
    /// A short wait before showing, so a ⌥ chord (⌥Space, ⌥E) doesn't flash the stats.
    @ObservationIgnored var revealDelay: Duration = .milliseconds(120)
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var reveal: Task<Void, Never>?
    /// A key was typed during this ⌥ press; stay hidden until ⌥ is released.
    @ObservationIgnored private var typedWithOption = false

    /// Watches the app's own key events; windows of other apps never reveal anything.
    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            switch event.type {
            case .flagsChanged: self?.flagsChanged(event.modifierFlags)
            case .keyDown: self?.keyDown(with: event.modifierFlags)
            default: break
            }
            return event
        }
        // ⌥ released in another app never reaches us.
        for name in [NSApplication.didResignActiveNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.hide() }
            }
        }
    }

    func flagsChanged(_ flags: NSEvent.ModifierFlags) {
        let modifiers = flags.intersection([.option, .shift, .command, .control, .function])
        if !modifiers.contains(.option) { typedWithOption = false }
        guard modifiers == .option, !typedWithOption else { return hide() }
        guard reveal == nil, !isHeld else { return }
        reveal = Task { [weak self, revealDelay] in
            try? await Task.sleep(for: revealDelay)
            guard let self, !Task.isCancelled else { return }
            self.reveal = nil
            self.isHeld = true
        }
    }

    func keyDown(with flags: NSEvent.ModifierFlags) {
        guard flags.contains(.option) else { return }
        typedWithOption = true
        hide()
    }

    private func hide() {
        reveal?.cancel()
        reveal = nil
        if isHeld { isHeld = false }
    }
}

/// The ⌥ stats under a reply: tokens in and out, the cached share, speed and cost, and on the
/// latest reply how much of the context window is left. Plain text on a quiet fill: it sits in
/// the content layer, so no glass.
struct NerdStatsView: View {
    let usage: TokenUsage
    /// The latest reply shows the context meter; it's what the next message builds on.
    let showsContext: Bool

    var body: some View {
        HStack(spacing: 10) {
            if showsContext, let left = usage.contextLeft, let context = usage.context, let window = usage.contextWindow {
                HStack(spacing: 5) {
                    ContextRing(used: 1 - left)
                    Text("\(Int((left * 100).rounded(.down)))% left")
                        .foregroundStyle(left < 0.1 ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                }
                .help("Context: \(Self.count(context)) of \(Self.count(window)) tokens used")
                Divider().frame(height: 10)
            }
            stat("arrow.up", Self.count(usage.input),
                 help: usage.cachedInput > 0 ? "\(usage.input.formatted()) input tokens, \(usage.cachedInput.formatted()) from cache"
                                             : "\(usage.input.formatted()) input tokens")
            stat("arrow.down", Self.count(usage.output), help: "\(usage.output.formatted()) output tokens, reasoning included")
            if usage.cachedInput > 0, usage.input > 0 {
                stat("bolt", "\(Int((Double(usage.cachedInput) / Double(usage.input) * 100).rounded()))%",
                     help: "Share of the input read from the prompt cache")
            }
            if let speed = usage.outputPerSecond {
                stat("gauge.with.needle", "\(Int(speed.rounded())) tok/s", help: "Output tokens per second, from send to finish")
            }
            if let cost = usage.cost, cost > 0 {
                stat("dollarsign", Self.price(cost), help: "Price at API rates, as the CLI reports it")
            }
        }
        .font(.system(size: 11, weight: .medium).monospacedDigit())
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background(Capsule().fill(.fill.tertiary))
        .fixedSize()
    }

    private func stat(_ symbol: String, _ value: String, help: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 8.5, weight: .bold)).foregroundStyle(.tertiary)
            Text(value)
        }
        .help(help)
    }

    /// 940, 12.4k, 1.2M.
    static func count(_ value: Int) -> String {
        switch value {
        case ..<1000: "\(value)"
        case ..<1_000_000: compact(Double(value) / 1000) + "k"
        default: compact(Double(value) / 1_000_000) + "M"
        }
    }

    private static func compact(_ value: Double) -> String {
        value < 10 ? String(format: "%.1f", value).replacingOccurrences(of: ".0", with: "") : "\(Int(value.rounded()))"
    }

    /// $0.0042, $0.013, $1.25.
    static func price(_ cost: Double) -> String {
        cost < 0.01 ? String(format: "$%.4f", cost) : cost < 1 ? String(format: "$%.3f", cost) : String(format: "$%.2f", cost)
    }
}

/// A small ring that fills as the context window does: accent, then orange, then red.
private struct ContextRing: View {
    let used: Double

    var body: some View {
        let tint: Color = used > 0.9 ? .red : used > 0.75 ? .orange : .accentColor
        ZStack {
            Circle().stroke(.primary.opacity(0.15), lineWidth: 2)
            Circle()
                .trim(from: 0, to: max(0.02, min(1, used)))
                .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 11, height: 11)
    }
}
