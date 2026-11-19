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
    /// Speech into `text`, from the mic button or ⌘⇧D.
    let dictation: Dictation

    /// Runs after an agent-mode alert or folder panel closes. The floating panel takes key
    /// focus back here; a normal window gets it back by itself.
    @ObservationIgnored var afterModal: () -> Void = {}
    /// Asks before agent mode first goes on; tests answer without an alert.
    @ObservationIgnored var confirmAgentMode: @MainActor () -> Bool = AgentMode.confirmEnabling
    @ObservationIgnored private let lastChoice: LastModelChoice
    @ObservationIgnored private var textBeforeHold: String?
    /// Off while a model comes from an opened chat rather than the person's choice.
    @ObservationIgnored private var recordsChoice = true

    init(chats: ChatController, lastChoice: LastModelChoice = LastModelChoice(), dictation: Dictation = Dictation()) {
        self.chats = chats
        self.lastChoice = lastChoice
        self.dictation = dictation
        model = ModelLibrary.shared.usable(lastChoice.model)
        effort = lastChoice.effort
    }

    var chat: Chat? { chats.chat(chatID) }
    var isStreaming: Bool { chats.isStreaming(chatID) }
    /// The reply streaming now; a steered message moves it further down the chat.
    var streamingReplyID: UUID? { chats.streamingReply(in: chatID) }
    var canRegenerate: Bool { chatID.map(chats.canRegenerate) ?? false }

    /// The agent folder the composer shows: an open chat's own, or the one set up for the next chat.
    var shownAgentDirectory: URL? { chat.map(\.agentDirectory) ?? agentDirectory }

    /// The backend the next message must use: the open chat's, or Claude Code for a new
    /// agent chat (agent mode runs on Claude Code only). Nil leaves every backend open.
    var lockedBackend: Backend? { chat?.backend ?? (agentDirectory != nil ? .claude : nil) }

    /// Sends the draft to the open chat, or starts one. While the chat replies, the draft
    /// steers the reply (`ChatController.send`). Callers choose the animation.
    func send() {
        // What was said so far goes with the message; nothing arrives after it.
        dictation.cancel()
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
        dictation.cancel()
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
        dictation.cancel()
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
        if isAgentModeOn {
            withAnimation(ComposerMotion.layout()) {
                agentDirectory = nil
                chatID = nil
            }
        } else {
            let confirmed = confirmAgentMode()
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

    /// The open chat is an agent chat, or the next new chat will be one.
    private var isAgentModeOn: Bool { chat?.isAgent ?? (agentDirectory != nil) }

    /// "/" typed into an empty composer turns agent mode on, like the Agent button. Returns
    /// whether it did, so the slash isn't typed; declined, the slash is typed as usual.
    func slashTypedFirst() -> Bool {
        guard text.isEmpty, !isAgentModeOn else { return false }
        toggleAgentMode()
        return agentDirectory != nil
    }

    /// Delete in an empty composer turns agent mode off before an agent chat starts. Returns
    /// whether it did. An open agent chat stays open: Delete never leaves a conversation.
    func deleteInEmptyComposer() -> Bool {
        guard text.isEmpty, chatID == nil, agentDirectory != nil else { return false }
        toggleAgentMode()
        return true
    }

    /// Only before the chat starts: an agent chat's folder is fixed once it exists.
    func chooseAgentDirectory() {
        if let directory = AgentMode.chooseDirectory() { agentDirectory = directory }
        afterModal()
        focusToken += 1
    }

    /// Starts dictating into the text, or stops and keeps the last words.
    func toggleDictation() {
        if dictation.isActive { dictation.finish() } else { startDictation() }
        focusToken += 1
    }

    private func startDictation() {
        dictation.start(text: { [weak self] in self?.text ?? "" }, write: { [weak self] in self?.text = $0 })
    }

    /// Return held: dictate, unless dictation is on already (⌘⇧D), and remember the text
    /// to go back to if Return is let go too soon.
    func beginHoldToTalk() {
        guard !dictation.isActive else { return }
        textBeforeHold = text
        startDictation()
    }

    /// Return let go in time: returns once the last words are in, ready to send.
    func endHoldToTalk() async {
        textBeforeHold = nil
        await finishDictation()
    }

    /// Return let go too soon: the recording goes and the text is back to what was typed.
    func abandonHoldToTalk() {
        guard let before = textBeforeHold else { return }
        textBeforeHold = nil
        dictation.cancel()
        text = before
    }

    /// Stops dictating and returns once the last words are in the text. Still starting
    /// (permission prompt, model download): nothing was heard, so it stops at once.
    private func finishDictation() async {
        guard dictation.state == .listening else { return dictation.cancel() }
        dictation.finish()
        await dictation.waitUntilDone()
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
