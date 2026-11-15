import ChatCore
import Foundation

// Debug entry point that runs the same ChatController/ClaudeClient path as the app.
//
//   reglance-cli ask [--model haiku|sonnet|opus] [--chat <chat-id>] [--attach <path>]… [--stop-after <seconds>] <question>
//       Streams the reply to stdout and saves the chat like the app does.
//       --chat continues an existing chat (uses --resume with its session id).
//       --attach sends a file (image, PDF, or text) with the question; repeatable.
//       --stop-after cancels the reply after N seconds, like the stop button.
//   reglance-cli regenerate <chat-id>
//       Replaces the chat's last reply with a new one, like the regenerate button.
//   reglance-cli list
//       Lists saved chats.

func usage() -> Never {
    print("usage: reglance-cli ask [--model haiku|sonnet|opus] [--chat <chat-id>] [--attach <path>]… [--stop-after <seconds>] <question>\n       reglance-cli regenerate <chat-id>\n       reglance-cli list")
    exit(2)
}

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { usage() }
args.removeFirst()

let controller = ChatController()

switch command {
case "list":
    for chat in controller.chats {
        print("\(chat.id)  \(chat.updatedAt.formatted())  \(chat.model.displayName)  session=\(chat.sessionID ?? "-")  \"\(chat.title)\" (\(chat.messages.count) messages)")
    }

case "ask":
    var model = ClaudeModel.haiku
    var chatID: UUID?
    var stopAfter: Double?
    var attachments: [AttachmentDraft] = []
    var words: [String] = []
    while !args.isEmpty {
        let arg = args.removeFirst()
        switch arg {
        case "--model":
            guard let name = args.first, let m = ClaudeModel.allCases.first(where: { $0.displayName.lowercased() == name }) else { usage() }
            model = m; args.removeFirst()
        case "--chat":
            guard let raw = args.first, let id = UUID(uuidString: raw), controller.chat(id) != nil else {
                print("unknown chat id"); exit(1)
            }
            chatID = id; args.removeFirst()
        case "--attach":
            guard let path = args.first else { usage() }
            do {
                attachments.append(try AttachmentDraft(fileURL: URL(filePath: path)))
            } catch {
                print(error.localizedDescription); exit(1)
            }
            args.removeFirst()
        case "--stop-after":
            guard let raw = args.first, let seconds = Double(raw) else { usage() }
            stopAfter = seconds; args.removeFirst()
        default:
            words.append(arg)
        }
    }
    guard !words.isEmpty || !attachments.isEmpty else { usage() }

    let id = controller.send(words.joined(separator: " "), attachments: attachments, model: model, to: chatID)
    if let stopAfter {
        Task { try? await Task.sleep(for: .seconds(stopAfter)); controller.cancel(id) }
    }
    await streamReply(id)

case "regenerate":
    guard let raw = args.first, let id = UUID(uuidString: raw) else { usage() }
    guard controller.canRegenerate(id) else { print("can't regenerate this chat"); exit(1) }
    controller.regenerate(id)
    await streamReply(id)

default:
    usage()
}

/// Prints the reply as it grows by polling the observable chat, then a summary.
@MainActor func streamReply(_ id: UUID) async {
    var printed = 0
    while controller.isStreaming(id) {
        let text = controller.chat(id)?.messages.last?.text ?? ""
        if text.count > printed {
            FileHandle.standardOutput.write(Data(text.dropFirst(printed).utf8))
            printed = text.count
        }
        try? await Task.sleep(for: .milliseconds(20))
    }
    await controller.waitForReply(id)
    let chat = controller.chat(id)!
    let reply = chat.messages.last!
    FileHandle.standardOutput.write(Data(reply.text.dropFirst(printed).utf8))
    print("\n---")
    if let error = reply.error { print("error: \(error)") }
    print("chat_id: \(chat.id)")
    print("session_id: \(chat.sessionID ?? "-")")
    print("saved: \(ChatStore().fileURL(for: chat.id).path)")
    if let seconds = reply.thinkingDuration { print("thought_for: \(Int(seconds.rounded()))s") }
    // How the app's widget parser reads the reply.
    for segment in ReplySegment.split(reply.text) {
        switch segment {
        case .chart(let spec): print("widget: chart \(spec.type.rawValue) \"\(spec.title)\" \(spec.data.count) points, series \(spec.seriesNames)")
        case .html(let source): print("widget: html \(source.count) chars")
        case .document(let title, let body): print("widget: document \"\(title)\" \(body.split(separator: "\n").count) lines")
        case .markdown(let text) where text.contains("```chart") || text.contains("```html") || text.contains("```document"):
            print("widget: failed to parse, shown as code")
        case .markdown, .pending: break
        }
    }
    for step in reply.toolSteps ?? [] { print("tool: \(step.name) \(step.detail)") }
    for attachment in chat.messages.dropLast().last?.attachments ?? [] {
        print("attachment: \(attachment.kind.rawValue) \(attachment.name) -> \(controller.url(for: attachment).path)")
    }
}
