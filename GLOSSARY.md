# Glossary

The words this project uses for its own concepts. Use them in code, issues and docs.

**ReGlance / Reglance.** ReGlance is the product name: window titles, the menu bar, the README. Reglance, with a lower-case g, is the code name: the Swift module and executable, the data folder `~/Library/Application Support/Reglance`, the `app.reglance` bundle id and the Homebrew formula. *Not to be confused with* each other in prose: user-facing text says ReGlance.

**Backend.** One of the CLIs a chat runs on: Claude Code (`claude -p`), Codex (`codex app-server`) or OpenCode (`opencode serve`). The `Backend` enum. A chat never moves to another backend.

**Chat.** One conversation, saved as a JSON file with its messages, model, effort and session id (`Chat`). *Not to be confused with* the chats window, which lists them.

**Turn.** One message sent and the reply it gets back. Each turn starts or resumes a backend session. Messages steered into a turn join it, each with a reply of its own.

**Steering.** Sending a message while a reply streams: Return or the send button adds it to the running turn instead of waiting for the next one (`Steering`; Claude Code's stdin, Codex's `turn/steer`, an OpenCode prompt to the busy session). The reply splits where the CLI takes the message, which can be after the current model call ends. A message the turn ends without taking, finished or stopped, is sent as the next turn. The send button turns into Stop only while the composer is empty.

**Reply.** The assistant message a turn produces: streamed text, thinking, tool steps and usage. Shown by `MessageView`.

**Session.** The backend's own record of a conversation, kept by the CLI, not by ReGlance. A chat stores the latest session id; each reply stores the session right after it. Each turn *forks* the previous reply's session rather than resuming it in place, so earlier ids stay unchanged and regenerate can go back one reply.

**Agent mode.** A chat that runs Claude Code with the person's full environment in a chosen folder, approved by auto mode or with permissions bypassed. Fixed when the chat starts and Claude Code only. Turned on with the Agent button, ⌘⇧A, or "/" typed into an empty composer (the slash isn't kept); Delete in the empty composer turns it off before the chat starts. *Not to be confused with* an ordinary chat, which is locked to web search.

**Lockdown.** What keeps an ordinary chat to web search: ReGlance's system prompt, no skills, MCP, plugins or shell, and a check that ends the turn if any other tool appears (`CodexLockdown`, `CodexClient.allowedItemTypes`, `OpenCodeStreamParser.allowedTools`).

**Guard.** The small shell (`ParentGuard`, shown as `reglance-guard`) between ReGlance and a long-lived CLI server, so the server stops however ReGlance ends, crashes included. *Not to be confused with* the lockdown.

**Composer.** The text field with the agent toggle, model pill and send button (`PromptBarView`). There is one composer view, used by both windows. Each window has its own composer session (`ComposerSession`): the draft, attachments, model, effort and agent folder, and the actions both windows share.

**Floating bar.** The non-activating panel opened with ⌥Space (`FloatingPanel`). It grows upward into a reply panel once a chat starts.

**Chats window.** The main window: a sidebar of chats and archive, and the open conversation with its own composer (`MainWindow`).

**Picker.** The card that grows out of the model pill, listing each backend's models and efforts (`ModelPickerView`). Names and efforts come from each CLI's model list, cached in `Models.json`.

**Model lock.** Keeps the composer's model on the backend the next message must use: the open chat's, or Claude Code for a new agent chat. A replaced model returns when agent mode is turned off (`ModelLock`).

**Widget.** A fenced block in a reply that renders as a card: ```` ```chart ````, ```` ```html ```` or ```` ```document ```` (`ReplyContent`, `ReplyBody`, `HTMLWidget`).

**Demo mode / demo scene.** Demo mode swaps real chats and CLIs for made-up content (`DemoMode`, `DemoContent`). A demo scene is one scripted shot of it that `scripts/capture-readme.sh` records for `docs/images/` (`DemoScene`).

**Dictation.** Speech typed into the composer as you talk, on-device with Apple's dictation model (`Dictation`, `SpeechRecognizer`). The mic button or ⌘⇧D starts and stops it, and the composer glows orange like the menu bar mic indicator while it listens; holding Return starts it too (hold to talk): the mic comes on after 200 ms, so a tap still just sends, and letting go after 2 s sends the speech, while letting go sooner throws it away. *Not to be confused with* sending audio: the models only ever get text.

**Nerd stats.** The token, cache, speed, cost and context figures shown under replies while ⌥ is held on its own (`TokenUsage`, `NerdStatsView`, `OptionKey`).
