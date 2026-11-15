# Reglance

A floating chat bar for quick questions to Claude on macOS. Press ⌥Space anywhere, including over full-screen apps, and a Liquid Glass bar appears. Ask something, paste a link or drop in a screenshot, and the answer streams into a panel that grows up from the bar. Every chat is saved, and you can reopen it in the main window and keep going.

It's for everyday questions, not coding. Reglance runs your installed `claude` CLI (Claude Code) with your settings, CLAUDE.md, MCP servers, skills and local tools turned off. The only tools it allows are web search and reading web pages, so it can check a product link or look something up, but it can't touch files or run commands on your Mac. It uses your existing Claude login, so there's no API key to set up.

Answers can include charts, small interactive HTML pages (sandboxed, with no network access) and Markdown documents you can save.

## Install

You need macOS 26 or later, [Homebrew](https://brew.sh), and Apple's developer tools. If you don't have Xcode, install the free command line tools first:

```sh
xcode-select --install
```

Reglance talks to Claude through [Claude Code](https://code.claude.com/docs/en/setup). Install it, then run `claude` once in a terminal to log in.

Then install the app:

```sh
brew tap mrRedSun/reglance https://github.com/mrRedSun/reglance
brew install mrRedSun/reglance/reglance
ln -sf "$(brew --prefix)/opt/reglance/Reglance.app" /Applications/Reglance.app
open /Applications/Reglance.app
```

Homebrew builds the app on your Mac, which takes about a minute. Because it's built locally, macOS opens it without the "unidentified developer" warning. The app isn't notarized by Apple and isn't in the official Homebrew catalog.

Press ⌥Space to show the bar. Reglance has no Dock icon; use its menu bar icon to open your chats or quit.

### Update

```sh
brew update && brew upgrade reglance
```

### Uninstall

```sh
brew uninstall reglance
rm /Applications/Reglance.app
brew untap mrRedSun/reglance
```

Your chats stay in `~/Library/Application Support/Reglance`. Delete that folder to remove them too.

## Requirements for building from source

- macOS 26 or later (Liquid Glass), Apple Silicon
- Swift 6.2+ toolchain (Xcode 26 or later)
- Claude Code installed and logged in

## Build and run

```sh
scripts/build-app.sh          # builds build/Reglance.app (release, ad-hoc signed)
scripts/build-app.sh --open   # builds and launches it
```

The app has no Dock icon. Use the menu bar icon to show the prompt bar, open the chats window, or quit. You can copy `build/Reglance.app` to `/Applications`.

For development:

```sh
swift build
swift test
swift run Reglance     # runs the app unbundled
```

### Keys

| Key | Action |
| --- | --- |
| ⌥Space | Show or hide the prompt bar |
| Return | Send |
| ⌥Return | New line |
| Esc | Hide the panel |
| ⌘N | New chat (expanded panel) |
| ⌘O | Open the chat in the main window (expanded panel) |
| ⌘V | Paste text, or attach a copied image or file |

Drop files onto the bar or the main window's input to attach them. Images are scaled down to 1568px on the long edge. PDFs and other files can be up to 10 MB, and text files up to 1 MB.

## Terminal client

`reglance-cli` goes through the same `ChatController` and `ClaudeClient` code as the app and saves to the same chat history:

```sh
swift run reglance-cli ask --model haiku "Which dogs can't bark?"
swift run reglance-cli ask --chat <chat-id> "Why do they yodel?"     # follow-up via --resume
swift run reglance-cli regenerate <chat-id>                          # replace the last reply
swift run reglance-cli ask --stop-after 2 "Write a long essay"       # cancel, like the stop button
swift run reglance-cli ask --attach shot.png "What's in this?"       # attachments; repeatable
swift run reglance-cli list
```

## Where things live

Everything is stored under `~/Library/Application Support/Reglance/`:

- `Chats/<id>.json`: one file per chat (title, timestamps, model, Claude session id, messages).
- `Chats/<id>/`: copies of that chat's attachments.
- `ClaudeWorkdir/`: the empty working directory the `claude` subprocess runs in, so no project files or `CLAUDE.md` get picked up.

Each message goes to `claude -p --input-format stream-json` as one JSON user message on stdin: images as base64 image blocks, PDFs as document blocks, text files inlined. The system prompt is in `Sources/ChatCore/SystemPrompt.swift`; it fills in today's date and your region, units and currency from macOS settings. The only tools enabled are WebSearch and WebFetch.

Each follow-up runs `claude -p … --resume <session> --fork-session`. Every reply therefore has its own session id, and regenerate resumes the session from before the last turn. The CLI keeps those sessions in its own store (`~/.claude/projects/`).

The app looks for `claude` in the usual install locations (`~/.local/bin`, Homebrew, npm, bun). If it isn't there, it asks your login shell, because apps launched from Finder don't get your shell `PATH`.

## Code layout

- `Sources/ChatCore`: no UI. `ClaudeClient` (subprocess, stream-json parsing, cancel), `SystemPrompt`, `ClaudeLocator`, `Chat`/`Message`, `Attachment`, `ReplyContent` (splits replies into markdown and widget blocks), `ChatStore` (JSON persistence), `ChatController` (shared observable state).
- `Sources/Reglance`: the menu bar app. `FloatingPanel` (non-activating panel), `HotKey` (Carbon global hotkey, no Accessibility permission needed), `PromptBarView`, `ReplyView` (expanded panel and `MessageView`, which renders every message in both windows), `ReplyBody` (markdown, chart and document cards), `HTMLWidget` (sandboxed web view), `Attachments`, `MainWindow`, `MarkdownText`.
- `Formula/reglance.rb`: the Homebrew formula; `scripts/build-app.sh` does the same build locally.
- `Sources/reglance-cli`: the terminal client.
- `design/`: HTML mockups the UI follows.

## Not done yet

- Dictation.
- An app icon.
- The ⌥Space shortcut is fixed and can't be changed in settings.
