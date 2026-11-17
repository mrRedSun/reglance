import Foundation

/// The short title generated after a chat's first reply. Every backend asks its own model
/// with `SystemPrompt.titleInstructions` and this prompt, then cleans the answer.
public enum ChatTitle {
    /// The question and the start of the answer, each cut to 1500 characters.
    static func prompt(question: String, answer: String) -> String {
        "Question:\n\(question.prefix(1500))\n\nStart of the answer:\n\(answer.prefix(1500))"
    }

    /// Trims a model reply to one plain line, or nil when it's empty.
    public static func clean(_ output: String) -> String? {
        let line = output.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let title = line.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\"'“”‘’.#*")))
        guard !title.isEmpty else { return nil }
        return title.count > 60 ? String(title.prefix(60)) + "…" : title
    }
}
