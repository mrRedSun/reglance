import AppKit
import ChatCore
import SwiftUI

/// The floating panel's expanded state (design/chat-view.html): header, scrolling
/// messages, and the prompt bar docked at the bottom. The panel grows upward from the bar.
struct ReplyView<Bar: View>: View {
    let chat: Chat?
    let streamingReplyID: UUID?
    let canRegenerate: Bool
    var onNewChat: () -> Void
    var onOpenInWindow: () -> Void
    var onClose: () -> Void
    var onRegenerate: () -> Void
    @ViewBuilder var bar: Bar

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The message area opens at this fixed height so even short chats have room to read.
    private let scrollHeight: CGFloat = 470

    var body: some View {
        let messagesHeight = scrollHeight
        VStack(spacing: 0) {
            // The composer remains the same child before and after the first send.
            // Only the content above it is inserted; the glass is never swapped out.
            if let chat {
                header(chat)
                    .transition(.opacity)

                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        ForEach(chat.messages) { message in
                            MessageView(
                                message: message,
                                isStreaming: message.id == streamingReplyID,
                                isLast: message.id == chat.messages.last?.id,
                                canRegenerate: canRegenerate,
                                onRegenerate: onRegenerate
                            )
                        }
                    }
                    .padding(EdgeInsets(top: 10, leading: 22, bottom: 18, trailing: 22))
                    // Short chats start at the top; longer ones stay scrolled to the latest.
                    .frame(maxWidth: .infinity, minHeight: messagesHeight, alignment: .topLeading)
                }
                .scrollIndicators(.hidden)
                .defaultScrollAnchor(.bottom)
                .defaultScrollAnchor(.bottom, for: .sizeChanges)
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: messagesHeight)
                .mask {
                    VStack(spacing: 0) {
                        LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 14)
                        Rectangle()
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 10)
                    }
                }
                .transition(.opacity)
            }

            bar.padding(chat == nil ? EdgeInsets()
                        : EdgeInsets(top: 0, leading: ComposerShape.dockInset,
                                     bottom: ComposerShape.dockInset, trailing: ComposerShape.dockInset))
        }
        // Any empty glass (header, edges, gaps around the composer) moves the panel.
        .background { WindowDragRegion() }
        .glassEffect(.regular, in: .rect(cornerRadius: chat == nil ? ComposerShape.cornerRadius : ComposerShape.panelCornerRadius))
        .animation(ComposerMotion.layout(reduceMotion: reduceMotion), value: chat != nil)
    }

    private func header(_ chat: Chat) -> some View {
        HStack(spacing: 2) {
            if chat.isAgent {
                AgentModeBadge(permissions: chat.agentPermissions).padding(.trailing, 6)
            }
            Text(chat.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: 26)
                // Let clicks fall through to the drag region so the title moves the panel.
                .allowsHitTesting(false)

            HeaderButton(systemName: "square.and.pencil", help: "New chat (⌘N)", action: onNewChat)
            HeaderButton(systemName: "arrow.up.left.and.arrow.down.right", help: "Open in main window (⌘O)", action: onOpenInWindow)
            HeaderButton(systemName: "xmark", help: "Close (Esc)", action: onClose)
        }
        .padding(EdgeInsets(top: 14, leading: 22, bottom: 8, trailing: 12))
    }
}

// MARK: - Messages

/// Renders one message. Shared by the floating panel and the main window, so new message
/// content (charts, HTML artifacts, documents) only needs adding here.
struct MessageView: View {
    let message: Message
    /// This message's reply is still streaming.
    let isStreaming: Bool
    let isLast: Bool
    let canRegenerate: Bool
    var onRegenerate: () -> Void

    @State private var hovering = false
    @Environment(\.conversationTextSize) private var textSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let optionKey = OptionKey.shared

    var body: some View {
        switch message.role {
        case .user:
            VStack(alignment: .trailing, spacing: 6) {
                if let attachments = message.attachments, !attachments.isEmpty {
                    HStack(spacing: 6) {
                        Spacer(minLength: 96)
                        ForEach(attachments) { attachment in
                            AttachmentChip(kind: attachment.kind, name: attachment.name,
                                           source: .file(attachment.url()), imageSize: 64)
                        }
                    }
                }
                if !message.text.isEmpty {
                    HStack {
                        Spacer(minLength: 96)
                        Text(message.text)
                            .font(.system(size: textSize))
                            .lineSpacing(conversationLineSpacing(textSize))
                            .textSelection(.enabled)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 8)
                            .background {
                                let shape = UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 18,
                                                                   bottomTrailingRadius: 6, topTrailingRadius: 18)
                                shape.fill(.fill.secondary)
                            }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        case .assistant:
            VStack(alignment: .leading, spacing: 8) {
                StatusRow(message: message, isStreaming: isStreaming)

                if !message.text.isEmpty {
                    ReplyBody(text: message.text, isStreaming: isStreaming)
                }
                if let error = message.error {
                    Label(error, systemImage: error == "Stopped" ? "stop.circle" : "exclamationmark.triangle")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                if !isStreaming, !message.text.isEmpty {
                    let showsStats = optionKey.isHeld && message.usage != nil
                    HStack(spacing: 2) {
                        CopyButton(help: "Copy") { [message.text as NSString] }
                        if isLast, canRegenerate {
                            HeaderButton(systemName: "arrow.clockwise", help: "Regenerate", size: 24, action: onRegenerate)
                        }
                        if showsStats, let usage = message.usage {
                            NerdStatsView(usage: usage, showsContext: isLast)
                                .padding(.leading, 6)
                                .transition(reduceMotion ? .opacity : .opacity
                                    .combined(with: .scale(scale: 0.85, anchor: .leading))
                                    .combined(with: .blur))
                        }
                    }
                    .padding(.top, -2)
                    .opacity(isLast || hovering || showsStats ? 1 : 0)
                    .animation(reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.3, dampingFraction: 0.8),
                               value: showsStats)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onHover { hovering = $0 }
        }
    }
}

/// The status row above a reply. While streaming: "Thinking…", or the running step
/// ("Searching "…"", "Reading example.com", "Bash npm test") with a shimmer. Afterwards a
/// disclosure row ("Thought for 3s", "Ran 2 searches · 3s", "Used 4 tools · 9s") that
/// lists the steps and any thinking text.
private struct StatusRow: View {
    let message: Message
    let isStreaming: Bool
    @State private var expanded = false

    var body: some View {
        let steps = message.toolSteps ?? []
        if isStreaming, let live = liveText(steps) {
            HStack(spacing: 7) {
                PulseDot()
                ShimmerText(text: live).lineLimit(1)
            }
            .font(.system(size: 13))
        } else if let duration = message.thinkingDuration {
            let thoughts = message.thinking ?? ""
            let expandable = !thoughts.isEmpty || !steps.isEmpty
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    if expandable { expanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        if expandable {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .bold))
                                .rotationEffect(.degrees(expanded ? 90 : 0))
                        }
                        Text(summary(steps, seconds: max(1, Int(duration.rounded()))))
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .animation(.easeOut(duration: 0.2), value: expanded)

                if expanded {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(steps.indices, id: \.self) { index in
                            let step = steps[index]
                            Label {
                                Text(step.label).lineLimit(1).truncationMode(.middle)
                            } icon: {
                                Image(systemName: step.symbol)
                                    .font(.system(size: 10.5))
                            }
                            .help(step.detail)
                        }
                        if !thoughts.isEmpty {
                            Text(thoughts).lineSpacing(3).textSelection(.enabled)
                        }
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(.primary.opacity(0.14)).frame(width: 1.5)
                    }
                    .padding(.leading, 3)
                }
            }
        }
    }

    /// A step is running while no text has followed it yet.
    private func liveText(_ steps: [ToolStep]) -> String? {
        if let step = steps.last, step.textOffset == message.text.utf8.count {
            return step.liveLabel
        }
        return message.text.isEmpty ? "Thinking…" : nil
    }

    private func summary(_ steps: [ToolStep], seconds: Int) -> String {
        let searches = steps.filter(\.isSearch).count
        let pages = steps.filter(\.isFetch).count
        // Agent chats: anything besides the web tools (commands, edits, reads…).
        let others = steps.count - searches - pages
        let read = pages == 1 ? "1 page" : "\(pages) pages"
        var label = switch (searches, pages) {
        case (0, 0): others == 0 ? "Thought for \(seconds)s" : ""
        case (1, 0): "Searched the web"
        case (_, 0): "Ran \(searches) searches"
        case (0, _): "Read \(read)"
        default: "Ran \(searches == 1 ? "1 search" : "\(searches) searches"), read \(read)"
        }
        if others > 0 {
            let used = others == 1 ? "1 tool" : "\(others) tools"
            label = label.isEmpty ? "Used \(used)" : "\(label), used \(used)"
        }
        return steps.isEmpty ? label : "\(label) · \(seconds)s"
    }
}

private extension ToolStep {
    var isSearch: Bool { name == "WebSearch" }
    var isFetch: Bool { name == "WebFetch" }
    /// Agent tools that name a file show just its name.
    private var shortDetail: String {
        detail.hasPrefix("/") ? URL(filePath: detail).lastPathComponent : detail
    }
    /// One line in the expanded step list.
    var label: String {
        if isSearch { return detail }
        if isFetch { return host }
        return detail.isEmpty ? name : "\(name) \(shortDetail)"
    }
    /// The running step, e.g. "Searching "…"", "Reading example.com", "Bash git status".
    var liveLabel: String {
        if isSearch { return "Searching \u{201C}\(detail)\u{201D}" }
        if isFetch { return "Reading \(host)" }
        return label
    }
    var symbol: String {
        switch name {
        case "WebSearch": "magnifyingglass"
        case "WebFetch": "globe"
        case "Bash": "terminal"
        case "Edit", "Write", "MultiEdit", "NotebookEdit": "pencil"
        default: "wrench.and.screwdriver"
        }
    }
    /// "example.com" for a fetched URL.
    var host: String {
        guard let host = URL(string: detail)?.host() else { return detail }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

struct PulseDot: View {
    @State private var small = false

    var body: some View {
        Circle()
            .fill(Color.accentColor)
            .frame(width: 8, height: 8)
            .shadow(color: Color.accentColor, radius: 5)
            .scaleEffect(small ? 0.6 : 1)
            .opacity(small ? 0.5 : 1)
            .animation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true), value: small)
            .onAppear { small = true }
    }
}

/// A highlight sweeping left to right across dimmed text.
struct ShimmerText: View {
    let text: String
    @State private var sweep = false

    var body: some View {
        Text(text)
            .foregroundStyle(.tertiary)
            .overlay {
                GeometryReader { geometry in
                    LinearGradient(colors: [.clear, .primary, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: geometry.size.width)
                        .offset(x: sweep ? geometry.size.width : -geometry.size.width)
                        .animation(.linear(duration: 1.6).repeatForever(autoreverses: false), value: sweep)
                }
                .mask(Text(text))
            }
            .onAppear { sweep = true }
    }
}

private extension AnyTransition {
    /// Comes into focus as it appears, like the picker card's bloom.
    static var blur: AnyTransition {
        .modifier(active: BlurModifier(radius: 6), identity: BlurModifier(radius: 0))
    }
}

private struct BlurModifier: ViewModifier {
    let radius: CGFloat
    func body(content: Content) -> some View { content.blur(radius: radius) }
}
