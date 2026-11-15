import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import ChatCore

@Test func encodesUserMessageWithAttachments() throws {
    let line = ClaudeClient.userMessageLine([
        .image(mediaType: "image/jpeg", data: Data([1, 2, 3])),
        .document(mediaType: "application/pdf", data: Data([4]), title: "a.pdf"),
        .text("What's this?"),
    ])
    #expect(line.last == UInt8(ascii: "\n"))
    let object = try #require(try JSONSerialization.jsonObject(with: line.dropLast()) as? [String: Any])
    #expect(object["type"] as? String == "user")
    let message = try #require(object["message"] as? [String: Any])
    #expect(message["role"] as? String == "user")
    let content = try #require(message["content"] as? [[String: Any]])
    #expect(content.map { $0["type"] as? String } == ["image", "document", "text"])
    let image = try #require(content[0]["source"] as? [String: String])
    #expect(image == ["type": "base64", "media_type": "image/jpeg", "data": "AQID"])
    #expect(content[1]["title"] as? String == "a.pdf")
    #expect((content[1]["source"] as? [String: String])?["media_type"] == "application/pdf")
    #expect(content[2]["text"] as? String == "What's this?")
}

@Test func storesAttachmentsAndBuildsContentBlocks() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "reglance-tests-\(UUID().uuidString)")
    let store = ChatStore(directory: directory)
    let file = directory.appending(path: "notes.md")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try "# Hi".write(to: file, atomically: true, encoding: .utf8)

    let draft = try AttachmentDraft(fileURL: file)
    #expect(draft.kind == .text && draft.name == "notes.md")
    let chatID = UUID()
    let attachment = try store.saveAttachment(draft, chatID: chatID)
    #expect(attachment.path == "\(chatID.uuidString)/\(draft.id.uuidString).md")

    var message = Message(role: .user, text: "Summarise")
    message.attachments = [attachment]
    #expect(try store.contentBlocks(for: message) == [.text("<file name=\"notes.md\">\n# Hi\n</file>"), .text("Summarise")])

    message.attachments = [Attachment(id: UUID(), kind: .image, name: "gone.jpg", mediaType: "image/jpeg", path: "missing.jpg")]
    #expect(throws: AttachmentError.unreadable(name: "gone.jpg")) { try store.contentBlocks(for: message) }
}

@Test func downscalesImagesToJPEG() throws {
    // 3000×1000 RGBA PNG, transparent.
    let context = try #require(CGContext(data: nil, width: 3000, height: 1000, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let png = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
    #expect(CGImageDestinationFinalize(destination))

    let draft = try AttachmentDraft(imageData: png as Data, name: "Screenshot.png")
    #expect(draft.kind == .image && draft.mediaType == "image/jpeg" && draft.name == "Screenshot.jpg")
    let source = try #require(CGImageSourceCreateWithData(draft.data as CFData, nil))
    let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    #expect(properties[kCGImagePropertyPixelWidth] as? Int == 1568)
    #expect(properties[kCGImagePropertyPixelHeight] as? Int == 523)

    #expect(throws: AttachmentError.unsupported(name: "x.png")) { try AttachmentDraft(imageData: Data([0, 1]), name: "x.png") }
}
