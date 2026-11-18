import ChatCore
import SwiftUI

/// The Liquid Glass prompt capsule (design/prompt-bar.html):
/// [attachment chips]
/// [Ask anything…] [Model ⌄] [send]
/// Used by the floating panel and by the main window's conversation view.
struct PromptBarView: View {
    @Bindable var session: ComposerSession
    /// Docked inside the expanded reply panel (design/chat-view.html): a tinted fill
    /// instead of its own glass, and a follow-up placeholder.
    var docked = false
    /// The floating surface supplies one stable material around the composer, and shows
    /// the picker card itself.
    var embedded = false
    /// How sending changes the layout: the floating bar grows into its reply panel.
    var sendAnimation: Animation? = nil

    @AppStorage(PlayfulPrompts.defaultsKey, store: Preferences.store) private var playfulPrompts = false
    @State private var playfulPrompt = PlayfulPrompts.random()
    /// Observed so a composer already in agent mode recolours when Settings changes.
    @AppStorage(AgentMode.bypassKey, store: AgentMode.defaults) private var bypassesPermissions = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var placeholder: String {
        if session.dictation.isActive { return "Listening…" }
        if docked { return "Ask a follow-up" }
        return playfulPrompts ? playfulPrompt : "Ask anything"
    }

    private var tray: AttachmentTray { session.attachments }
    private var agentDirectory: URL? { session.shownAgentDirectory }
    /// An open chat shows its own mode; Settings decides for the next chat.
    private var agentPermissions: AgentPermissions {
        session.chat?.agentPermissions ?? (bypassesPermissions ? .bypass : .auto)
    }

    /// One composer size for the floating bar and the chats window.
    private var editorInset: CGFloat { ComposerShape.editorInset }

    private var canSend: Bool {
        !tray.isPreparing && (!session.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !tray.drafts.isEmpty)
    }
    private var showsTray: Bool { !tray.drafts.isEmpty || tray.error != nil || tray.isPreparing }

    var body: some View {
        layers.onChange(of: session.lockedBackend, initial: true) { session.applyModelLock() }
    }

    @ViewBuilder private var layers: some View {
        if embedded {
            // The floating root owns the shared glass container and accessory.
            composer
        } else {
            GlassEffectContainer { composer.glowAnchor() }
                .edgeGlow(agent: agentDirectory != nil ? agentPermissions.color : nil,
                          isListening: session.dictation.state == .listening,
                          cornerRadius: ComposerShape.cornerRadius)
                .modelPickerOverlay(isPresented: session.pickerIsPresented, model: $session.model,
                                    effort: $session.effort, backend: session.lockedBackend,
                                    reduceMotion: reduceMotion, onDone: { session.setPickerPresented(false) })
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
            if let error = session.dictation.error {
                Label(error, systemImage: "mic.slash")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.top, 2)
            }
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
                if session.chat == nil {
                    Button(action: session.chooseAgentDirectory) {
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
            if let replaced = session.modelLock.switchedFrom, replaced.backend != .claude {
                // Agent mode runs on Claude Code only; the earlier model returns when it's off.
                Text("Runs on Claude Code")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help("\(ModelLibrary.shared.name(for: replaced)) comes back when agent mode is off.")
            }
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
            PromptEditor(text: $session.text, placeholder: placeholder,
                         tray: tray, focusToken: session.focusToken, onSubmit: submit,
                         onCancel: { session.setPickerPresented(false) },
                         onHoldToTalk: session.beginHoldToTalk,
                         onReleaseToSend: { Task { await session.endHoldToTalk(); submit() } },
                         onReleaseTooSoon: session.abandonHoldToTalk,
                         verticalInset: editorInset)
                .frame(minHeight: 20 + 2 * editorInset)
                // In SwiftUI, not drawn by the text view: a hierarchical style on glass adapts
                // to what's behind it, where AppKit's placeholder grey went muddy on dark or
                // colourful backgrounds. Placed where the editor starts its first line.
                .overlay(alignment: .topLeading) {
                    if session.text.isEmpty {
                        Text(placeholder)
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .padding(.leading, 4)
                            .padding(.top, editorInset)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                // Opening the bar or starting a chat bumps the token: a new playful prompt.
                .onChange(of: session.focusToken) { playfulPrompt = PlayfulPrompts.random(excluding: playfulPrompt) }

            DictationButton(state: session.dictation.state, action: session.toggleDictation)
                .padding(.bottom, editorInset - 5)

            AgentToggle(isOn: agentDirectory != nil, permissions: agentPermissions, action: session.toggleAgentMode)
                .padding(.bottom, editorInset - 5)

            ModelPickerPill(model: session.model, effort: session.effort, isExpanded: session.pickerIsPresented) {
                session.setPickerPresented(!session.pickerIsPresented)
            }
            // Keeps the pill and send button centred on the first line of a taller bar.
            .padding(.bottom, editorInset - 5)

            SendButton(state: session.isStreaming ? .stop : (canSend ? .ready : .idle),
                       tint: agentDirectory == nil ? .accentColor : agentPermissions.color) {
                session.isStreaming ? session.stop() : submit()
            }
            .padding(.bottom, editorInset - 5)
        }
    }

    private func submit() {
        guard canSend, !session.isStreaming else { return }
        session.setPickerPresented(false)
        withAnimation(sendAnimation) { session.send() }
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

/// The glass the edge glow surrounds, published from inside a GlassEffectContainer.
struct GlowAnchorKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

extension View {
    /// Marks this glass as the one the edge glow surrounds.
    func glowAnchor() -> some View {
        anchorPreference(key: GlowAnchorKey.self, value: .bounds) { $0 }
    }

    /// Draws the edge glow behind this view, around the glass marked with `glowAnchor()`:
    /// the microphone's orange while dictation listens, else the agent's colour in agent
    /// mode (nil when off). Apply outside the GlassEffectContainer: content inside the glass
    /// is held back while the glass reshapes, so a glow there appeared only once the
    /// composer had finished growing.
    func edgeGlow(agent: Color?, isListening: Bool, cornerRadius: CGFloat) -> some View {
        backgroundPreferenceValue(GlowAnchorKey.self) { anchor in
            GeometryReader { proxy in
                if let anchor {
                    let rect = proxy[anchor]
                    EdgeGlow(color: isListening ? .microphoneInUse : agent ?? .clear, cornerRadius: cornerRadius,
                             isOn: isListening || agent != nil)
                        // Agent mode spreads with the composer's own animation; the mic has none.
                        .animation(.easeInOut(duration: 0.35), value: isListening)
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                }
            }
        }
    }
}

/// The glow around the composer or reply panel in agent mode or while dictating: a tight
/// glow on the edge and a wider halo, only outside the shape, with no hard border. Always in
/// place and driven by `isOn`, so it spreads out on the same animation that grows the
/// composer, not on a timer of its own.
struct EdgeGlow: View {
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

/// Starts and stops dictation (⌘⇧D). While listening the waveform moves.
private struct DictationButton: View {
    let state: Dictation.State
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                switch state {
                case .off: Image(systemName: "mic")
                case .starting: ProgressView().controlSize(.mini)
                case .listening: Image(systemName: "waveform").symbolEffect(.variableColor.iterative, isActive: true)
                }
            }
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(state == .listening ? .primary : .secondary)
            .frame(width: 26, height: 26)
            .background(Color.primary.opacity(state == .listening ? 0.2 : 0.1), in: .circle)
            .contentShape(.circle)
            .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .keyboardShortcut("d", modifiers: [.command, .shift])
        .padding(.bottom, 2)
        .help(state == .off ? "Dictate (⌘⇧D)" : "Stop dictating (⌘⇧D)")
        .accessibilityLabel("Dictation")
        .accessibilityValue(state == .off ? "Off" : "Listening")
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

extension Color {
    /// The orange of macOS's microphone-in-use indicator.
    static let microphoneInUse = Color.orange
}
