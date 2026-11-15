import AppKit
import ChatCore
import ImageIO
import SwiftUI

/// Attachments waiting in a prompt bar. Files are read and converted off the main thread.
@Observable
final class AttachmentTray {
    private(set) var drafts: [AttachmentDraft] = []
    /// Why the last file was rejected; cleared by the next add or send.
    var error: String?

    func add(fileURLs: [URL]) {
        error = nil
        let urls = fileURLs.filter(\.isFileURL)
        Task {
            for url in urls {
                let result = await Task.detached(priority: .userInitiated) {
                    Result { try AttachmentDraft(fileURL: url) }
                }.value
                append(result)
            }
        }
    }

    func add(imageData: Data) {
        error = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try AttachmentDraft(imageData: imageData, name: "Pasted image") }
            }.value
            append(result)
        }
    }

    func remove(_ id: UUID) {
        drafts.removeAll { $0.id == id }
    }

    /// Hands the drafts to `send` and empties the tray.
    func take() -> [AttachmentDraft] {
        defer { drafts = []; error = nil }
        return drafts
    }

    private func append(_ result: Result<AttachmentDraft, Error>) {
        switch result {
        case .success(let draft): drafts.append(draft)
        case .failure(let failure): error = failure.localizedDescription
        }
    }
}

extension View {
    /// Dropping files onto this view adds them to `tray`.
    func attachmentDrop(_ tray: AttachmentTray) -> some View {
        dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            tray.add(fileURLs: files)
            return true
        }
    }
}

// MARK: - Paste

/// ⌘V in a prompt bar's text field: files and image data become attachments; anything
/// with text on the pasteboard pastes as text, as before.
final class PasteInterceptor {
    weak var window: NSWindow?
    private var monitor: Any?

    func start(tray: AttachmentTray) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak tray] event in
            guard let self, let tray, let window = self.window, event.window === window,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers == "v",
                  let editor = window.firstResponder as? NSTextView, editor.isEditable,
                  Self.paste(into: tray) else { return event }
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private static let imageTypes: [NSPasteboard.PasteboardType] = [
        .png, .tiff, NSPasteboard.PasteboardType("public.jpeg"), NSPasteboard.PasteboardType("public.heic"),
    ]

    /// Returns false when the pasteboard should be pasted as text.
    private static func paste(into tray: AttachmentTray) -> Bool {
        let pasteboard = NSPasteboard.general
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            tray.add(fileURLs: urls)
            return true
        }
        guard !(pasteboard.types ?? []).contains(.string),
              let type = pasteboard.availableType(from: imageTypes),
              let data = pasteboard.data(forType: type) else { return false }
        tray.add(imageData: data)
        return true
    }
}

/// Reports the hosting window, for the paste monitor.
struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView { Reader(onWindow: onWindow) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Reader: NSView {
        let onWindow: (NSWindow?) -> Void
        init(onWindow: @escaping (NSWindow?) -> Void) {
            self.onWindow = onWindow
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func viewDidMoveToWindow() { onWindow(window) }
    }
}

// MARK: - Thumbnails and chips

/// Small decoded thumbnails, cached by file or draft.
enum Thumbnails {
    private static let cache = NSCache<NSString, CGImage>()

    static func image(for key: String, maxPixels: Int, source: @escaping @Sendable () -> CGImageSource?) async -> CGImage? {
        if let cached = cache.object(forKey: key as NSString) { return cached }
        let image = await Task.detached(priority: .utility) { () -> CGImage? in
            guard let source = source() else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }.value
        if let image { cache.setObject(image, forKey: key as NSString) }
        return image
    }
}

/// An image thumbnail or a file chip. Used in the prompt bar (removable) and in user bubbles.
struct AttachmentChip: View {
    enum Source: Equatable {
        case draft(AttachmentDraft)
        case file(URL)
    }

    let kind: Attachment.Kind
    let name: String
    let source: Source
    var onRemove: (() -> Void)?
    var imageSize: CGFloat = 48
    @State private var thumbnail: CGImage?

    var body: some View {
        Group {
            if kind == .image {
                Group {
                    if let thumbnail {
                        Image(decorative: thumbnail, scale: 2).resizable().scaledToFill()
                    } else {
                        Rectangle().fill(.primary.opacity(0.08))
                    }
                }
                .frame(width: imageSize, height: imageSize)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.primary.opacity(0.1), lineWidth: 0.5))
            } else {
                HStack(spacing: 6) {
                    Image(systemName: kind == .pdf ? "doc.richtext" : "doc.text")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Text(name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                }
                .padding(.leading, 9)
                .padding(.trailing, onRemove == nil ? 10 : 22)
                .frame(height: 30)
                .frame(maxWidth: 200)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.primary.opacity(0.08)))
            }
        }
        .overlay(alignment: kind == .image ? .topTrailing : .trailing) {
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.55))
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
                .padding(kind == .image ? 2 : 5)
                .help("Remove")
            }
        }
        .onTapGesture { if case .file(let url) = source { NSWorkspace.shared.open(url) } }
        .help(name)
        .task(id: source) { await loadThumbnail() }
    }

    private func loadThumbnail() async {
        guard kind == .image else { return }
        let pixels = Int(imageSize * 2)
        switch source {
        case .draft(let draft):
            let data = draft.data
            thumbnail = await Thumbnails.image(for: "draft-\(draft.id)-\(pixels)", maxPixels: pixels) {
                CGImageSourceCreateWithData(data as CFData, nil)
            }
        case .file(let url):
            thumbnail = await Thumbnails.image(for: "\(url.path)-\(pixels)", maxPixels: pixels) {
                CGImageSourceCreateWithURL(url as CFURL, nil)
            }
        }
    }
}
