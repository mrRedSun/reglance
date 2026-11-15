import ChatCore
import SwiftUI

/// The Liquid Glass prompt capsule (design/prompt-bar.html):
/// [attachment chips]
/// [Ask anything…] [Model ⌄] [send]
/// Used by the floating panel and by the main window's conversation view.
struct PromptBarView: View {
    @Binding var text: String
    @Binding var model: ClaudeModel
    /// Dropped and pasted files, shown as chips above the text.
    let tray: AttachmentTray
    var isStreaming: Bool
    /// Docked inside the expanded reply panel (design/chat-view.html): a tinted fill
    /// instead of its own glass, and a follow-up placeholder.
    var docked = false
    /// Bump to move keyboard focus into the text field.
    var focusToken: Int
    var onSend: () -> Void
    var onStop: () -> Void

    @FocusState private var fieldFocused: Bool
    @State private var isMultiline = false
    @State private var paste = PasteInterceptor()

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !tray.drafts.isEmpty
    }
    private var showsTray: Bool { !tray.drafts.isEmpty || tray.error != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showsTray { trayRow }
            inputRow
        }
        // Leading inset matches the design's text start now that the + button is gone.
        .padding(docked ? EdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 6)
                        : EdgeInsets(top: 7, leading: 14, bottom: 7, trailing: 7))
        .background {
            if docked {
                RoundedRectangle(cornerRadius: 19)
                    .fill(.primary.opacity(0.1))
                    .stroke(.white.opacity(0.2), lineWidth: 0.5)
            }
        }
        .glassEffect(docked ? .identity : .regular, in: .rect(cornerRadius: isMultiline || showsTray ? 18 : 22))
        .animation(.easeOut(duration: 0.15), value: isMultiline)
        .animation(.easeOut(duration: 0.15), value: showsTray)
        .background(WindowReader { paste.window = $0 })
        .onAppear {
            fieldFocused = true
            paste.start(tray: tray)
        }
        .onDisappear { paste.stop() }
        .onChange(of: focusToken) { fieldFocused = true }
    }

    private var trayRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(tray.drafts) { draft in
                    AttachmentChip(kind: draft.kind, name: draft.name, source: .draft(draft)) { tray.remove(draft.id) }
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
            TextField(docked ? "Ask a follow-up" : "Ask anything", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .lineLimit(1...5)
                .tint(Color.accentBlue)
                .focused($fieldFocused)
                .padding(.horizontal, 4)
                .padding(.vertical, 5)
                .frame(minHeight: 30)
                .onSubmit(submit)
                .onGeometryChange(for: Bool.self) { $0.size.height > 34 } action: { isMultiline = $0 }

            ModelPicker(model: $model)

            SendButton(state: isStreaming ? .stop : (canSend ? .ready : .idle)) {
                isStreaming ? onStop() : submit()
            }
        }
    }

    private func submit() {
        guard canSend, !isStreaming else { return }
        onSend()
    }
}

private struct ModelPicker: View {
    @Binding var model: ClaudeModel

    var body: some View {
        Menu {
            Picker("Model", selection: $model) {
                Text("Haiku · instant").tag(ClaudeModel.haiku)
                Text("Sonnet").tag(ClaudeModel.sonnet)
                Text("Opus · thinking").tag(ClaudeModel.opus)
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 3) {
                Text(model.displayName)
                    .font(.system(size: 12.5, weight: .semibold))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .opacity(0.7)
            }
            .padding(.leading, 10)
            .padding(.trailing, 8)
            .frame(height: 26)
            .background(Capsule().fill(.primary.opacity(0.1)))
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.bottom, 2) // centre the 26pt pill on the 30pt buttons
    }
}

private struct SendButton: View {
    enum State { case idle, ready, stop }
    let state: State
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
                    Circle().fill(Color.accentBlue)
                        .shadow(color: Color.accentBlue.opacity(0.45), radius: 4, y: 2)
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

extension Color {
    /// #0a84ff, the send button blue from the design.
    static let accentBlue = Color(red: 10 / 255, green: 132 / 255, blue: 1)
}
