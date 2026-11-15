import ChatCore
import Observation
import SwiftUI

/// The models each backend offers the picker. Claude's are fixed; the others come from
/// their CLIs, which only answer when installed, so a missing backend has no section.
@MainActor
@Observable
final class ModelLibrary {
    static let shared = ModelLibrary()

    private(set) var options: [Backend: [ModelOption]] = [.claude: ClaudeBackend.models]

    /// Backends with at least one model, in picker order.
    var backends: [Backend] { Backend.allCases.filter { !(options[$0] ?? []).isEmpty } }

    /// Asks each CLI for its models again. Demo mode stays on Claude's made-up chats.
    func refresh() async {
        guard !DemoMode.isEnabled else { return }
        for backend in Backend.allCases where backend != .claude {
            options[backend] = await backend.models()
        }
    }

    func option(for model: ChatModel) -> ModelOption? {
        options[model.backend]?.first { $0.model == model }
    }

    /// Efforts the model accepts. A model the library doesn't list (a chat saved with a
    /// model that is no longer offered) keeps Automatic only.
    func efforts(for model: ChatModel) -> [Effort] {
        option(for: model)?.efforts ?? [.automatic]
    }

    /// The model a composer switches to when it's locked to `backend` and holds another.
    func defaultModel(for backend: Backend) -> ChatModel? {
        backend == .claude ? .sonnet : options[backend]?.first?.model
    }
}

extension View {
    /// Keeps a composer's model on `backend` (an open chat's backend, or Claude for a new
    /// agent chat), so the pill never shows a model the next message wouldn't use.
    func lockModel(_ model: Binding<ChatModel>, effort: Binding<Effort>, to backend: Backend?, chat: Chat?) -> some View {
        onChange(of: backend, initial: true) { _, backend in
            guard let backend, model.wrappedValue.backend != backend else { return }
            if let chat, chat.backend == backend {
                model.wrappedValue = chat.model
                effort.wrappedValue = chat.effort
            } else if let fallback = ModelLibrary.shared.defaultModel(for: backend) {
                model.wrappedValue = fallback
                effort.wrappedValue = .automatic
            }
        }
    }
}
