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
    /// Non-nil while agent mode is on: the folder the chat runs in. Shows the agent glow.
    var agentDirectory: URL? = nil
    /// How the agent chat approves actions: blue for auto mode, red when bypassed.
    var agentPermissions: AgentPermissions = .auto
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
            GlassEffectContainer { composer.agentGlowAnchor() }
                .agentGlow(isOn: agentDirectory != nil, color: agentPermissions.color,
                           cornerRadius: ComposerShape.cornerRadius)
                .modelPickerOverlay(isPresented: pickerPresentation.wrappedValue, model: $model, effort: $effort,
                                    reduceMotion: reduceMotion, onDone: dismissPicker)
            // The card floats over the conversation above the composer.
            .zIndex(1)
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let agentDirectory {
                agentRow(agentDirectory).transition(.opacity.combined(with: .offset(y: 8)))
            }
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
        .animation(.easeOut(duration: 0.15), value: showsTray)
    }

    private func agentRow(_ directory: URL) -> some View {
        HStack(spacing: 8) {
            AgentModeBadge(permissions: agentPermissions)
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

            AgentToggle(isOn: agentDirectory != nil, permissions: agentPermissions, action: onToggleAgent)
                .padding(.bottom, editorInset - 5)

            ModelPickerPill(model: model, effort: effort, isExpanded: pickerPresentation.wrappedValue) {
                withAnimation(pickerMotion) { pickerPresentation.wrappedValue.toggle() }
            }
            // Keeps the pill and send button centred on the first line of a taller bar.
            .padding(.bottom, editorInset - 5)

            SendButton(state: isStreaming ? .stop : (canSend ? .ready : .idle),
                       tint: agentDirectory == nil ? .accentColor : agentPermissions.color) {
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
    static let sendButtonSize: CGFloat = 30
    /// The send button sits in the capsule's round end with the same gap above, below and
    /// to its right: (56 − 30) / 2 = 13pt.
    static var padding: EdgeInsets {
        EdgeInsets(top: 7, leading: 14, bottom: 7, trailing: (oneLineHeight - sendButtonSize) / 2)
    }
    /// 20pt line + 2 × 11pt editor inset + 2 × 7pt padding = 56pt.
    static var oneLineHeight: CGFloat { 20 + 2 * editorInset + 2 * 7 }
    static var cornerRadius: CGFloat { oneLineHeight / 2 }
    /// The reply panel around a docked composer, concentric with it.
    static let dockInset: CGFloat = 7
    static var panelCornerRadius: CGFloat { cornerRadius + dockInset }
    /// The grey behind the composer's buttons. A plain tint rather than a system fill:
    /// system fills blend with the glass behind them and vanished while it reshaped.
    static let controlFill = Color.primary.opacity(0.1)
}

/// The glass the agent glow surrounds, published from inside a GlassEffectContainer.
struct AgentGlowAnchorKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

extension View {
    /// Marks this glass as the one the agent glow surrounds.
    func agentGlowAnchor() -> some View {
        anchorPreference(key: AgentGlowAnchorKey.self, value: .bounds) { $0 }
    }

    /// Draws the agent glow behind this view, around the glass marked with
    /// `agentGlowAnchor()`. Apply outside the GlassEffectContainer: content inside the
    /// glass is held back while the glass reshapes, so a glow there appeared only once the
    /// composer had finished growing.
    func agentGlow(isOn: Bool, color: Color, cornerRadius: CGFloat) -> some View {
        backgroundPreferenceValue(AgentGlowAnchorKey.self) { anchor in
            GeometryReader { proxy in
                if let anchor {
                    let rect = proxy[anchor]
                    AgentGlow(color: color, cornerRadius: cornerRadius, isOn: isOn)
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                }
            }
        }
    }
}

/// The glow around an agent composer or reply panel: a tight glow on the edge and a wider
/// halo, only outside the shape, with no hard border. Always in place and driven by
/// `isOn`, so it spreads out on the same animation that grows the composer, not on a timer
/// of its own.
struct AgentGlow: View {
    let color: Color
    let cornerRadius: CGFloat
    let isOn: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        let spread: CGFloat = isOn ? 1 : 0
        ZStack {
            shape.stroke(color.opacity(0.5 * spread), lineWidth: 8).blur(radius: 2 + 12 * spread)
            shape.stroke(color.opacity(0.9 * spread), lineWidth: 1.5).blur(radius: 3)
        }
        .mask { OutsideShape(shape: shape).fill(style: FillStyle(eoFill: true)) }
        .opacity(spread)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Everything around a shape, out to where the glow fades: the shape cut out of a larger rect.
private nonisolated struct OutsideShape: Shape {
    let shape: RoundedRectangle

    func path(in rect: CGRect) -> Path {
        var path = Path(rect.insetBy(dx: -40, dy: -40))
        path.addPath(shape.path(in: rect))
        return path
    }
}

/// Turns agent mode on or off. Blue (auto) or red (bypassed) while on.
private struct AgentToggle: View {
    let isOn: Bool
    let permissions: AgentPermissions
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isOn ? permissions.symbol + ".fill" : permissions.symbol)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(isOn ? .white : .secondary)
                .frame(width: 26, height: 26)
                .background(isOn ? AnyShapeStyle(permissions.color) : AnyShapeStyle(ComposerShape.controlFill), in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .keyboardShortcut("a", modifiers: [.command, .shift])
        .padding(.bottom, 2)
        .help(isOn ? "Turn off agent mode (⌘⇧A)"
              : permissions == .auto ? "Agent mode: run Claude Code in auto mode (⌘⇧A)"
              : "Agent mode: run Claude Code with permission prompts bypassed (⌘⇧A)")
        .accessibilityLabel("Agent mode")
        .accessibilityValue(isOn ? (permissions == .auto ? "On, auto mode" : "On, permissions bypassed") : "Off")
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
            .frame(width: ComposerShape.sendButtonSize, height: ComposerShape.sendButtonSize)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(state == .idle)
        .help(state == .stop ? "Stop" : "Send")
        .animation(.easeOut(duration: 0.15), value: state)
    }
}
