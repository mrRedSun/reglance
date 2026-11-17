import ChatCore
import Foundation
import Observation
import SwiftUI

/// The models each backend offers the picker, as its CLI lists them. Kept in a cache so the
/// picker and the pill have names straight away; refreshed when the picker opens (at most
/// hourly) or Settings checks again, so launching the app starts no CLI.
@MainActor
@Observable
final class ModelLibrary {
    /// Demo mode shows its made-up list and never asks a CLI. Tests swap in a fixed library.
    /// Demo mode keeps every backend on, whatever the person switched off.
    static var shared = DemoMode.isEnabled
        ? ModelLibrary(fixed: [.claude: DemoContent.models, .codex: DemoContent.codexModels,
                               .opencode: DemoContent.openCodeModels],
                       defaults: Preferences.store)
        : ModelLibrary(cacheURL: AppPaths.root.appending(path: "Models.json"))

    private(set) var options: [Backend: [ModelOption]]
    /// Backends switched off in Settings. Claude stays on: agent mode, titles and the
    /// default model run on it.
    private(set) var disabled: Set<Backend>

    @ObservationIgnored private let cacheURL: URL?
    /// Never refreshed: demo mode and tests.
    @ObservationIgnored private let isFixed: Bool
    var isFixedForTests: Bool { isFixed }
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var refreshedAt: [Backend: Date] = [:]
    static let refreshInterval: TimeInterval = 60 * 60
    static let disabledKey = "disabledBackends"

    init(cacheURL: URL, defaults: UserDefaults = .standard) {
        self.cacheURL = cacheURL
        self.defaults = defaults
        isFixed = false
        disabled = Self.disabled(in: defaults)
        options = (try? Data(contentsOf: cacheURL))
            .flatMap { try? JSONDecoder().decode([String: [ModelOption]].self, from: $0) }
            .map { Dictionary(uniqueKeysWithValues: $0.compactMap { key, value in Backend(rawValue: key).map { ($0, value) } }) }
            ?? [:]
    }

    init(fixed options: [Backend: [ModelOption]], defaults: UserDefaults = .standard) {
        cacheURL = nil
        self.defaults = defaults
        isFixed = true
        disabled = Self.disabled(in: defaults)
        self.options = options
    }

    private static func disabled(in defaults: UserDefaults) -> Set<Backend> {
        Set((defaults.stringArray(forKey: disabledKey) ?? []).compactMap(Backend.init(rawValue:))).subtracting([.claude])
    }

    /// Enabled backends with at least one model, in picker order.
    var backends: [Backend] { Backend.allCases.filter { isEnabled($0) && !(options[$0] ?? []).isEmpty } }

    func isEnabled(_ backend: Backend) -> Bool { !disabled.contains(backend) }

    func setEnabled(_ backend: Backend, _ enabled: Bool) {
        guard backend != .claude else { return }
        if enabled { disabled.remove(backend) } else { disabled.insert(backend) }
        defaults.set(disabled.map(\.rawValue).sorted(), forKey: Self.disabledKey)
        if enabled { Task { await refresh([backend], force: true) } }
    }

    /// Asks enabled backends' CLIs for their models, unless they answered within the last
    /// hour. A CLI that can't be asked keeps its last list.
    func refresh(_ backends: [Backend] = Backend.allCases, force: Bool = false) async {
        guard !isFixed else { return }
        let now = Date()
        let due = backends.filter { backend in
            isEnabled(backend) && (force || refreshedAt[backend].map { now.timeIntervalSince($0) > Self.refreshInterval } ?? true)
        }
        guard !due.isEmpty else { return }
        for backend in due { refreshedAt[backend] = now }
        await withTaskGroup(of: (Backend, [ModelOption]?).self) { group in
            for backend in due { group.addTask { (backend, await backend.models()) } }
            for await (backend, models) in group {
                if let models { options[backend] = models }
            }
        }
        save()
    }

    private func save() {
        guard let cacheURL else { return }
        let byName = Dictionary(uniqueKeysWithValues: options.map { ($0.key.rawValue, $0.value) })
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(byName).write(to: cacheURL, options: .atomic)
    }

    /// What the picker offers for `backend`: the newest Claude and OpenAI model of each
    /// family, plus `selected` so an older chat keeps its model.
    func pickerOptions(for backend: Backend, selected: ChatModel) -> [ModelOption] {
        ModelFamily.latest(options[backend] ?? [], keeping: selected)
    }

    func option(for model: ChatModel) -> ModelOption? {
        options[model.backend]?.first { $0.model == model }
    }

    /// The CLI's name for the model, or one made from its id when the CLI no longer lists it.
    func name(for model: ChatModel) -> String {
        option(for: model)?.name ?? model.fallbackName
    }

    /// Efforts the model accepts. A model the library doesn't list (a chat saved with a
    /// model that is no longer offered) keeps Automatic only.
    func efforts(for model: ChatModel) -> [Effort] {
        option(for: model)?.efforts ?? [.automatic]
    }

    /// The model a composer switches to when it's locked to `backend` and holds another.
    func defaultModel(for backend: Backend) -> ChatModel? {
        let listed = options[backend] ?? []
        guard backend == .claude else { return listed.first?.model }
        // Claude's everyday model, whichever Sonnet the CLI lists now.
        return listed.first { $0.model.id.contains("sonnet") }?.model ?? listed.first?.model ?? .sonnet
    }

    /// The model a new chat starts on when `model` was chosen last: the newest of its
    /// family (Sonnet 5 becomes Sonnet 5.5, as the picker only offers the newest), or
    /// Claude's default when its backend is switched off.
    func usable(_ model: ChatModel) -> ChatModel {
        guard isEnabled(model.backend) else { return defaultModel(for: .claude) ?? .sonnet }
        return ModelFamily.newest(model, in: options[model.backend] ?? [])
    }
}

/// Keeps a composer's model on the backend the next message must use: the open chat's,
/// or Claude Code for a new agent chat. Switching a new chat to agent mode replaces a
/// Codex or OpenCode model with Claude's default; the replaced choice is kept, shown in
/// the agent row, and restored when agent mode is turned off.
struct ModelLock {
    private var saved: (model: ChatModel, effort: Effort)?

    /// The model agent mode replaced, while it's replaced.
    var switchedFrom: ChatModel? { saved?.model }

    mutating func apply(_ backend: Backend?, chat: Chat?, model: inout ChatModel, effort: inout Effort,
                        library: ModelLibrary = .shared) {
        guard let backend else {
            if let saved {
                model = saved.model
                effort = saved.effort
                self.saved = nil
            }
            return
        }
        guard model.backend != backend else { return }
        if let chat, chat.backend == backend {
            model = chat.model
            effort = chat.effort
        } else if let fallback = library.defaultModel(for: backend) {
            if chat == nil, saved == nil { saved = (model, effort) }
            model = fallback
            effort = .automatic
        }
    }
}
