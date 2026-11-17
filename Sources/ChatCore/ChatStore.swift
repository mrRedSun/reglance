import Foundation

/// Locations under ~/Library/Application Support/Reglance, or the demo folder in demo mode.
public enum AppPaths {
    public static var root: URL {
        DemoMode.directory ?? URL.applicationSupportDirectory.appending(path: "Reglance", directoryHint: .isDirectory)
    }
    /// One JSON file per chat.
    public static var chats: URL { root.appending(path: "Chats", directoryHint: .isDirectory) }
    /// The empty folder a backend's CLI runs in for ordinary chats, so no project files or
    /// instructions get picked up.
    public static func workdir(for backend: Backend) -> URL {
        root.appending(path: backend.descriptor.workdirName, directoryHint: .isDirectory)
    }
}

/// Stores each chat as `<id>.json`, and its attachments in the folder `<id>/`.
public struct ChatStore: Sendable {
    public let directory: URL

    public init(directory: URL = AppPaths.chats) {
        self.directory = directory
    }

    public func loadAll() -> [Chat] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(Chat.self, from: Data(contentsOf: $0)) }
            .sorted(by: Chat.precedes)
    }

    public func save(_ chat: Chat) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(chat).write(to: fileURL(for: chat.id), options: .atomic)
    }

    public func fileURL(for id: UUID) -> URL {
        directory.appending(path: "\(id.uuidString).json")
    }

    /// Deletes only this chat's JSON and attachment copies. CLI sessions are owned by Claude.
    public func delete(_ id: UUID) throws {
        let manager = FileManager.default
        let attachments = directory.appending(path: id.uuidString, directoryHint: .isDirectory)
        for url in [attachments, fileURL(for: id)] {
            do {
                try manager.removeItem(at: url)
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                // Deleting a chat whose files have already gone is safe to repeat.
            }
        }
    }

    /// Copies a draft into the chat's folder and returns the record that references it.
    public func saveAttachment(_ draft: AttachmentDraft, chatID: UUID) throws -> Attachment {
        let attachment = Attachment(
            id: draft.id, kind: draft.kind, name: draft.name, mediaType: draft.mediaType,
            path: "\(chatID.uuidString)/\(draft.id.uuidString).\(draft.fileExtension)"
        )
        let url = attachment.url(in: directory)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try draft.data.write(to: url, options: .atomic)
        return attachment
    }

    /// The message content sent to Claude: attachments first (as the API recommends), then the text.
    public func contentBlocks(for message: Message) throws -> [ContentBlock] {
        var blocks: [ContentBlock] = try (message.attachments ?? []).map { attachment in
            guard let data = try? Data(contentsOf: attachment.url(in: directory)) else {
                throw AttachmentError.unreadable(name: attachment.name)
            }
            switch attachment.kind {
            case .image: return .image(mediaType: attachment.mediaType, data: data)
            case .pdf: return .document(mediaType: attachment.mediaType, data: data, title: attachment.name)
            case .text: return .text("<file name=\"\(attachment.name)\">\n\(String(decoding: data, as: UTF8.self))\n</file>")
            }
        }
        if !message.text.isEmpty { blocks.append(.text(message.text)) }
        return blocks
    }
}
