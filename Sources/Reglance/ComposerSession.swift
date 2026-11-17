import AppKit
import ChatCore
import Observation
import SwiftUI

/// One composer's draft and choices. The floating bar and the chats window each own one, and
/// both windows' buttons and shortcuts call these methods, so a composer feature is written once.
@Observable
final class ComposerSession {
    let chats: ChatController
    var text = ""
    /// Replaced, not emptied, when a draft is thrown away: a file still being prepared then
    /// lands in the old tray instead of the next chat.
    private(set) var attachments = AttachmentTray()
    var model: ChatModel { didSet { if recordsChoice, model != oldValue { lastChoice.model = model } } }
    var effort: Effort { didSet { if recordsChoice, effort != oldValue { lastChoice.effort = effort } } }
    /// The open chat; nil means the next send starts a new one.
    var chatID: UUID?
    /// Agent mode for the next new chat: the folder it runs in. Off for every new chat.
    /// Its permissions come from Settings when the chat starts (`AgentMode.permissions`).
    var agentDirectory: URL?
    /// Bump to move keyboard focus into the text field.
    var focusToken = 0
    var pickerIsPresented = false
    /// Keeps the model on the backend the next message must use.
    private(set) var modelLock = ModelLock()

    /// Runs after an agent-mode alert or folder panel closes. The floating panel takes key
    /// focus back here; a normal window gets it back by itself.
    @ObservationIgnored var afterModal: () -> Void = {}
    @ObservationIgnored private let lastChoice: LastModelChoice
    /// Off while a model comes from an opened chat rather than the person's choice.
    @ObservationIgnored private var recordsChoice = true

    init(chats: ChatController, lastChoice: LastModelChoice = LastModelChoice()) {
        self.chats = chats
        self.lastChoice = lastChoice
        model = ModelLibrary.shared.usable(lastChoice.model)
        effort = lastChoice.effort
    }

    var chat: Chat? { chats.chat(chatID) }
    var isStreaming: Bool { chats.isStreaming(chatID) }
    var canRegenerate: Bool { chatID.map(chats.canRegenerate) ?? false }

    /// The agent folder the composer shows: an open chat's own, or the one set up for the next chat.
    var shownAgentDirectory: URL? { chat.map(\.agentDirectory) ?? agentDirectory }

    /// The backend the next message must use: the open chat's, or Claude Code for a new
    /// agent chat (agent mode runs on Claude Code only). Nil leaves every backend open.
    var lockedBackend: Backend? { chat?.backend ?? (agentDirectory != nil ? .claude : nil) }

    /// Sends the draft to the open chat, or starts one. Callers choose the animation.
    func send() {
        guard !isStreaming else { return }
        chatID = chats.send(text, attachments: attachments.take(), model: model, effort: effort,
                            agentDirectory: agentDirectory, agentPermissions: AgentMode.permissions, to: chatID)
        text = ""
    }

    func stop() {
        if let chatID { chats.cancel(chatID) }
    }

    func regenerate() {
        if let chatID { chats.regenerate(chatID, model: model, effort: effort) }
    }

    /// A blank composer for a new chat: the draft and agent mode go too.
    func startNewChat() {
        pickerIsPresented = false
        chatID = nil
        agentDirectory = nil
        discardDraft()
        focusToken += 1
    }

    /// Shows another chat (nil for a new one). The draft belongs to the chat it was typed
    /// for, so it goes; the model follows the chat, or the last choice for a new chat.
    func open(_ id: UUID?) {
        guard id != chatID else { return }
        pickerIsPresented = false
        chatID = id
        agentDirectory = nil
        discardDraft()
        if let chat { withoutRecording { model = chat.model; effort = chat.effort } } else { adoptLastChoice() }
    }

    /// Picks up a choice made in the other window since this composer was last used.
    func adoptLastChoice() {
        model = ModelLibrary.shared.usable(lastChoice.model)
        effort = lastChoice.effort
    }

    /// A chat keeps the mode it was created with, so switching while one is open starts a
    /// new chat. The draft stays in the composer.
    func toggleAgentMode() {
        pickerIsPresented = false
        let isOn = chat?.isAgent ?? (agentDirectory != nil)
        if isOn {
            withAnimation(ComposerMotion.layout()) {
                agentDirectory = nil
                chatID = nil
            }
        } else {
            let confirmed = AgentMode.confirmEnabling()
            afterModal()
            if confirmed {
                withAnimation(ComposerMotion.layout()) {
                    agentDirectory = AgentMode.directory
                    chatID = nil
                }
            }
        }
        focusToken += 1
    }

    /// Only before the chat starts: an agent chat's folder is fixed once it exists.
    func chooseAgentDirectory() {
        if let directory = AgentMode.chooseDirectory() { agentDirectory = directory }
        afterModal()
        focusToken += 1
    }

    func setPickerPresented(_ isPresented: Bool) {
        guard pickerIsPresented != isPresented else { return }
        withAnimation(ComposerMotion.picker()) { pickerIsPresented = isPresented }
    }

    /// Moves the model onto `lockedBackend`, or back to the choice agent mode replaced.
    func applyModelLock() {
        var newModel = model, newEffort = effort
        modelLock.apply(lockedBackend, chat: chat, model: &newModel, effort: &newEffort)
        if newModel != model { model = newModel }
        if newEffort != effort { effort = newEffort }
    }

    private func discardDraft() {
        text = ""
        attachments = AttachmentTray()
    }

    private func withoutRecording(_ body: () -> Void) {
        recordsChoice = false
        body()
        recordsChoice = true
    }
}
