import AppKit
import ChatCore
import SwiftUI

// Small buttons shared by the reply panel, messages and cards.

struct HeaderIcon: View {
    let systemName: String
    var size: CGFloat = 26
    var hovering = false

    var body: some View {
        Image(systemName: systemName)
            .contentTransition(.symbolEffect(.replace))
            .font(.system(size: size * 0.46, weight: .medium))
            .foregroundStyle(hovering ? .primary : .secondary)
            .frame(width: size, height: size)
            .background(Circle().fill(.primary.opacity(hovering ? 0.12 : 0)))
            .contentShape(Circle())
    }
}

/// A copy control that confirms with "Copied" (a checkmark for the icon style) for a moment.
struct CopyButton: View {
    enum Style { case icon, pill }

    var style: Style = .icon
    var help = "Copy"
    /// What to copy; nil when there's nothing to copy (a chart that failed to render).
    let items: () -> [NSPasteboardWriting]?
    @State private var copied = false

    static let confirmation: Duration = .seconds(1.5)

    var body: some View {
        Group {
            switch style {
            case .icon:
                HeaderButton(systemName: copied ? "checkmark" : "doc.on.doc", help: copied ? "Copied" : help,
                             size: 24, action: copy)
            case .pill:
                PillButton(title: copied ? "Copied" : "Copy", widestTitle: "Copied", action: copy)
            }
        }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: Self.confirmation)
            withAnimation { copied = false }
        }
    }

    private func copy() {
        guard let items = items(), Self.write(items) else { return }
        withAnimation { copied = true }
        AccessibilityNotification.Announcement("Copied").post()
    }

    /// Replaces the pasteboard's contents; false when nothing was written.
    static func write(_ items: [NSPasteboardWriting], to pasteboard: NSPasteboard = .general) -> Bool {
        guard !items.isEmpty else { return false }
        pasteboard.clearContents()
        return pasteboard.writeObjects(items)
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
