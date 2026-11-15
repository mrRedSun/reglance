import AppKit
import ChatCore
import SwiftUI

/// The floating panel's expanded state (design/chat-view.html): header, scrolling
/// messages, and the prompt bar docked at the bottom. The panel grows upward from the bar.
struct ReplyView<Bar: View>: View {
    let chat: Chat
    let isStreaming: Bool
    let canRegenerate: Bool
    /// For the history menu, most recent first.
    let recentChats: [Chat]
    var onSelectChat: (UUID) -> Void
    var onNewChat: () -> Void
    var onOpenInWindow: () -> Void
    var onClose: () -> Void
    var onRegenerate: () -> Void
    @ViewBuilder var bar: Bar

    @State private var contentHeight: CGFloat = 0
    /// Messages scroll beyond this height (the design's `.scroll { max-height }`).
    private let maxScrollHeight: CGFloat = 470

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(chat.messages) { message in
                        MessageView(
                            message: message,
                            isStreaming: isStreaming && message.id == chat.messages.last?.id,
                            isLast: message.id == chat.messages.last?.id,
                            canRegenerate: canRegenerate,
                            onRegenerate: onRegenerate
                        )
                    }
                }
                .padding(EdgeInsets(top: 6, leading: 16, bottom: 14, trailing: 16))
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollIndicators(.hidden)
            .defaultScrollAnchor(.bottom)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(max(contentHeight, 1), maxScrollHeight))
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 14)
                    Rectangle()
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 10)
                }
            }

            bar.padding(EdgeInsets(top: 0, leading: 7, bottom: 7, trailing: 7))
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }

    private var header: some View {
        HStack(spacing: 2) {
            Text(chat.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Menu {
                ForEach(recentChats.prefix(20)) { recent in
                    Button(recent.title) { onSelectChat(recent.id) }
                }
                Divider()
                Button("Show All Chats…", action: onOpenInWindow)
            } label: {
                HeaderIcon(systemName: "clock.arrow.circlepath")
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Chat history")

            HeaderButton(systemName: "square.and.pencil", help: "New chat (⌘N)", action: onNewChat)
                .keyboardShortcut("n")
            HeaderButton(systemName: "arrow.up.left.and.arrow.down.right", help: "Open in main window (⌘O)", action: onOpenInWindow)
                .keyboardShortcut("o")
            HeaderButton(systemName: "xmark", help: "Close (Esc)", action: onClose)
        }
        .padding(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 8))
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
    @Environment(\.colorScheme) private var colorScheme

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
                            .font(.system(size: 14.5))
                            .lineSpacing(2)
                            .textSelection(.enabled)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 8)
                            .background {
                                let shape = UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 18,
                                                                   bottomTrailingRadius: 6, topTrailingRadius: 18)
                                shape.fill(.white.opacity(colorScheme == .dark ? 0.18 : 0.6))
                                    .stroke(.primary.opacity(0.06), lineWidth: 0.5)
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
                    HStack(spacing: 2) {
                        HeaderButton(systemName: "doc.on.doc", help: "Copy", size: 24) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(message.text, forType: .string)
                        }
                        if isLast, canRegenerate {
                            HeaderButton(systemName: "arrow.clockwise", help: "Regenerate", size: 24, action: onRegenerate)
                        }
                    }
                    .padding(.top, -2)
                    .opacity(isLast || hovering ? 1 : 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onHover { hovering = $0 }
        }
    }
}

/// The status row above a reply. While streaming: "Thinking…", or the running web step
/// ("Searching "…"", "Reading example.com") with a shimmer. Afterwards a disclosure row
/// ("Thought for 3s", "Ran 2 searches · 3s") that lists the steps and any thinking text.
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
                                Text(step.isSearch ? step.detail : step.host).lineLimit(1).truncationMode(.middle)
                            } icon: {
                                Image(systemName: step.isSearch ? "magnifyingglass" : "globe")
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
            return step.isSearch ? "Searching \u{201C}\(step.detail)\u{201D}" : "Reading \(step.host)"
        }
        return message.text.isEmpty ? "Thinking…" : nil
    }

    private func summary(_ steps: [ToolStep], seconds: Int) -> String {
        let searches = steps.filter(\.isSearch).count
        let pages = steps.count - searches
        let read = pages == 1 ? "1 page" : "\(pages) pages"
        let label = switch (searches, pages) {
        case (0, 0): "Thought for \(seconds)s"
        case (1, 0): "Searched the web"
        case (_, 0): "Ran \(searches) searches"
        case (0, _): "Read \(read)"
        default: "Ran \(searches == 1 ? "1 search" : "\(searches) searches"), read \(read)"
        }
        return steps.isEmpty ? label : "\(label) · \(seconds)s"
    }
}

private extension ToolStep {
    var isSearch: Bool { name == "WebSearch" }
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
            .fill(Color.accentBlue)
            .frame(width: 8, height: 8)
            .shadow(color: Color.accentBlue, radius: 5)
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

// MARK: - Buttons

struct HeaderIcon: View {
    let systemName: String
    var size: CGFloat = 26
    var hovering = false

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.46, weight: .medium))
            .foregroundStyle(hovering ? .primary : .secondary)
            .frame(width: size, height: size)
            .background(Circle().fill(.primary.opacity(hovering ? 0.12 : 0)))
            .contentShape(Circle())
    }
}

struct HeaderButton: View {
    let systemName: String
    let help: String
    var size: CGFloat = 26
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HeaderIcon(systemName: systemName, size: size, hovering: hovering)
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
    }
}
