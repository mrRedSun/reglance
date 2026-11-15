import ChatCore
import SwiftUI

/// The Liquid Glass prompt capsule (design/prompt-bar.html):
/// [attachment chips]
/// [Ask anything…] [Model ⌄] [send]
/// Used by the floating panel and by the main window's conversation view.
struct PromptBarView: View {
    @Binding var text: String
    @Binding var model: ClaudeModel
    @Binding var effort: ClaudeEffort
    /// Dropped and pasted files, shown as chips above the text.
    let tray: AttachmentTray
    var isStreaming: Bool
    /// Docked inside the expanded reply panel (design/chat-view.html): a tinted fill
    /// instead of its own glass, and a follow-up placeholder.
    var docked = false
    /// The floating surface supplies one stable material around the composer.
    var embedded = false
    /// Bump to move keyboard focus into the text field.
    var focusToken: Int
    var onSend: () -> Void
    var onStop: () -> Void
    /// The floating controller owns this binding so Esc closes the picker first.
    var pickerIsPresented: Binding<Bool>? = nil
    var usesExternalPicker = false
    /// Non-nil while agent mode is on: the folder the chat runs in. Shows the red warning.
    var agentDirectory: URL? = nil
    /// The Agent button (⌘⇧A).
    var onToggleAgent: () -> Void = {}
    /// Changes the agent folder. Nil once the chat exists, since its folder is fixed.
    var onChooseAgentDirectory: (() -> Void)? = nil

    @State private var localPickerIsPresented = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var pickerPresentation: Binding<Bool> { pickerIsPresented ?? $localPickerIsPresented }
    private var pickerMotion: Animation? {
        reduceMotion ? .easeOut(duration: 0.10) : .spring(response: 0.38, dampingFraction: 0.80)
    }

    /// One composer size for the floating bar and the chats window.
    private var editorInset: CGFloat { ComposerShape.editorInset }

    private var canSend: Bool {
        !tray.isPreparing && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !tray.drafts.isEmpty)
    }
    private var showsTray: Bool { !tray.drafts.isEmpty || tray.error != nil || tray.isPreparing }

    var body: some View {
        if usesExternalPicker {
            // The floating root owns the shared glass container and accessory.
            composer
        } else {
            GlassEffectContainer { composer }
                .modelPickerOverlay(isPresented: pickerPresentation.wrappedValue, model: $model, effort: $effort,
                                    reduceMotion: reduceMotion, onDone: dismissPicker)
            // The card floats over the conversation above the composer.
            .zIndex(1)
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let agentDirectory { agentRow(agentDirectory) }
            if showsTray { trayRow }
            inputRow
        }
        // Leading inset matches the design's text start now that the + button is gone.
        .padding(ComposerShape.padding)
        .background {
            if docked {
                RoundedRectangle(cornerRadius: ComposerShape.cornerRadius)
                    .fill(.primary.opacity(0.1))
                    .stroke(.white.opacity(0.2), lineWidth: 0.5)
            }
        }
        .glassEffect(embedded || docked ? .identity : .regular, in: .rect(cornerRadius: ComposerShape.cornerRadius))
        .overlay {
            if agentDirectory != nil {
                RoundedRectangle(cornerRadius: ComposerShape.cornerRadius)
                    .strokeBorder(AgentMode.color, lineWidth: 1.5)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.15), value: showsTray)
        .animation(.easeOut(duration: 0.15), value: agentDirectory)
    }

    private func agentRow(_ directory: URL) -> some View {
        HStack(spacing: 8) {
            AgentModeBadge()
            Group {
                if let onChooseAgentDirectory {
                    Button(action: onChooseAgentDirectory) {
                        HStack(spacing: 3) {
                            Label(AgentMode.displayPath(directory), systemImage: "folder")
                            Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).opacity(0.7)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Choose the folder Claude works in")
                } else {
                    Label(AgentMode.displayPath(directory), systemImage: "folder")
                        .help(directory.path)
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.top, 4)
    }

    private var trayRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(tray.drafts) { draft in
                    AttachmentChip(kind: draft.kind, name: draft.name, source: .draft(draft)) { tray.remove(draft.id) }
                }
                if tray.isPreparing {
                    ProgressView().controlSize(.small)
                    Text("Preparing attachment…").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                if let error = tray.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 2)
            .padding(.top, 2)
        }
        .scrollIndicators(.never)
    }

    private var inputRow: some View {
        HStack(alignment: .bottom, spacing: 4) {
            PromptEditor(text: $text, placeholder: docked ? "Ask a follow-up" : "Ask anything",
                         tray: tray, focusToken: focusToken, onSubmit: submit, onCancel: dismissPicker,
                         verticalInset: editorInset)
                .frame(minHeight: 20 + 2 * editorInset)

            AgentToggle(isOn: agentDirectory != nil, action: onToggleAgent)
                .padding(.bottom, editorInset - 5)

            ModelPickerPill(model: model, effort: effort, isExpanded: pickerPresentation.wrappedValue) {
                withAnimation(pickerMotion) { pickerPresentation.wrappedValue.toggle() }
            }
            // Keeps the pill and send button centred on the first line of a taller bar.
            .padding(.bottom, editorInset - 5)

            SendButton(state: isStreaming ? .stop : (canSend ? .ready : .idle),
                       tint: agentDirectory == nil ? .accentColor : AgentMode.color) {
                isStreaming ? onStop() : submit()
            }
            .padding(.bottom, editorInset - 5)
        }
    }

    private func submit() {
        guard canSend, !isStreaming else { return }
        dismissPicker()
        onSend()
    }

    private func dismissPicker() {
        guard pickerPresentation.wrappedValue else { return }
        withAnimation(pickerMotion) { pickerPresentation.wrappedValue = false }
    }
}

/// The one corner radius used by every composer and the surfaces around it: half the
/// height of a one-line composer, so it reads as a capsule rather than a squircle. Taller
/// states (several lines, attachments) keep the same radius.
enum ComposerShape {
    static let editorInset: CGFloat = 11
    static let padding = EdgeInsets(top: 7, leading: 14, bottom: 7, trailing: 7)
    /// 20pt line + 2 × 11pt editor inset + 2 × 7pt padding = 56pt.
    static var oneLineHeight: CGFloat { 20 + 2 * editorInset + padding.top + padding.bottom }
    static var cornerRadius: CGFloat { oneLineHeight / 2 }
    /// The reply panel around a docked composer, concentric with it.
    static let dockInset: CGFloat = 7
    static var panelCornerRadius: CGFloat { cornerRadius + dockInset }
}

/// Turns agent mode on or off. Red while on.
private struct AgentToggle: View {
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isOn ? "exclamationmark.shield.fill" : "exclamationmark.shield")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(isOn ? .white : .secondary)
                .frame(width: 26, height: 26)
                .background(isOn ? AnyShapeStyle(AgentMode.color) : AnyShapeStyle(.fill.tertiary), in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .keyboardShortcut("a", modifiers: [.command, .shift])
        .padding(.bottom, 2)
        .help(isOn ? "Turn off agent mode (⌘⇧A)" : "Agent mode: run Claude Code with permission prompts bypassed (⌘⇧A)")
        .accessibilityLabel("Agent mode")
        .accessibilityValue(isOn ? "On, permissions bypassed" : "Off")
    }
}

private struct SendButton: View {
    enum State { case idle, ready, stop }
    let state: State
    var tint: Color = .accentColor
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            ZStack {
                switch state {
                case .idle:
                    Circle().fill(.primary.opacity(0.1))
                    Image(systemName: "arrow.up").foregroundStyle(.secondary)
                case .ready:
                    Circle().fill(tint)
                        .shadow(color: tint.opacity(0.45), radius: 4, y: 2)
                    Image(systemName: "arrow.up").foregroundStyle(.white)
                case .stop:
                    // Inverted ink circle with a small rounded square, as in the design.
                    Circle().fill(.primary)
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(colorScheme == .dark ? Color(white: 0.13) : .white)
                        .frame(width: 10, height: 10)
                }
            }
            .font(.system(size: 14, weight: .bold))
            .frame(width: 30, height: 30)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(state == .idle)
        .help(state == .stop ? "Stop" : "Send")
        .animation(.easeOut(duration: 0.15), value: state)
    }
}
