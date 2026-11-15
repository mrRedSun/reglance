import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A file sent with a user message. The file itself is a copy in the chat's folder
/// (`Chats/<chat-id>/`), so the chat keeps working after the original moves.
public struct Attachment: Codable, Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// Downscaled JPEG, sent as an image block.
        case image
        /// Sent as a document block.
        case pdf
        /// UTF-8 text, inlined into the message as a text block.
        case text
    }

    public var id: UUID
    public var kind: Kind
    /// The original file name, shown in chips.
    public var name: String
    public var mediaType: String
    /// Relative to the chats directory: `<chat-id>/<attachment-id>.<ext>`.
    public var path: String

    public func url(in chatsDirectory: URL = AppPaths.chats) -> URL {
        chatsDirectory.appending(path: path)
    }
}

public enum AttachmentError: LocalizedError, Equatable, Sendable {
    case tooLarge(name: String, limit: String)
    case unsupported(name: String)
    case unreadable(name: String)

    public var errorDescription: String? {
        switch self {
        case .tooLarge(let name, let limit): "\(name) is larger than \(limit)."
        case .unsupported(let name): "\(name) isn't an image, PDF, or text file."
        case .unreadable(let name): "Couldn't read \(name)."
        }
    }
}

/// An attachment in the prompt bar that hasn't been sent yet. Preparing it reads and
/// converts the file once, so sending is just a copy.
public struct AttachmentDraft: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let kind: Attachment.Kind
    public let name: String
    public let mediaType: String
    /// JPEG for images, the original bytes otherwise.
    public let data: Data

    /// Images are downscaled to this long edge (Claude's recommended maximum).
    public static let maxImageEdge = 1568
    static let maxFileBytes = 10_000_000
    /// Image originals may be bigger, since only the downscaled copy is kept.
    static let maxImageBytes = 50_000_000
    /// Inlined text counts against the context window.
    static let maxTextBytes = 1_000_000

    init(kind: Attachment.Kind, name: String, mediaType: String, data: Data) {
        self.id = UUID()
        self.kind = kind
        self.name = name
        self.mediaType = mediaType
        self.data = data
    }

    /// Reads a dropped or pasted file. Call off the main thread: images are re-encoded.
    public init(fileURL: URL) throws {
        let name = fileURL.lastPathComponent
        let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey, .isDirectoryKey])
        if values?.isDirectory == true { throw AttachmentError.unsupported(name: name) }
        let type = values?.contentType ?? UTType(filenameExtension: fileURL.pathExtension) ?? .data
        let size = values?.fileSize ?? 0

        if type.conforms(to: .image) {
            guard size <= Self.maxImageBytes else { throw AttachmentError.tooLarge(name: name, limit: "50 MB") }
            guard let data = try? Data(contentsOf: fileURL) else { throw AttachmentError.unreadable(name: name) }
            try self.init(imageData: data, name: name)
            return
        }
        guard size <= Self.maxFileBytes else { throw AttachmentError.tooLarge(name: name, limit: "10 MB") }
        guard let data = try? Data(contentsOf: fileURL) else { throw AttachmentError.unreadable(name: name) }
        if type.conforms(to: .pdf) {
            self.init(kind: .pdf, name: name, mediaType: "application/pdf", data: data)
        } else if type.conforms(to: .text) || Self.looksLikeText(data) {
            guard data.count <= Self.maxTextBytes else { throw AttachmentError.tooLarge(name: name, limit: "1 MB") }
            guard String(data: data, encoding: .utf8) != nil else { throw AttachmentError.unsupported(name: name) }
            self.init(kind: .text, name: name, mediaType: "text/plain", data: data)
        } else {
            throw AttachmentError.unsupported(name: name)
        }
    }

    /// Image bytes in any ImageIO format (PNG, TIFF from the pasteboard, HEIC, …),
    /// downscaled to `maxImageEdge` and re-encoded as JPEG on a white background.
    public init(imageData: Data, name: String) throws {
        guard let jpeg = Self.downscaledJPEG(imageData) else { throw AttachmentError.unsupported(name: name) }
        let base = (name as NSString).deletingPathExtension
        self.init(kind: .image, name: base + ".jpg", mediaType: "image/jpeg", data: jpeg)
    }

    static func looksLikeText(_ data: Data) -> Bool {
        !data.prefix(4096).contains(0) && String(data: data.prefix(4096), encoding: .utf8) != nil
    }

    static func downscaledJPEG(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,   // apply EXIF orientation
            kCGImageSourceThumbnailMaxPixelSize: min(maxImageEdge, max(width, height)),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }

        // Flatten onto white: JPEG has no alpha, and transparent screenshots would turn black.
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(rect)
        context.draw(image, in: rect)
        guard let flat = context.makeImage() else { return nil }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, flat, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    var fileExtension: String {
        switch kind {
        case .image: "jpg"
        case .pdf: "pdf"
        case .text: (name as NSString).pathExtension.isEmpty ? "txt" : (name as NSString).pathExtension
        }
    }
}
