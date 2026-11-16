# Contributing to ReGlance

Thanks for helping. This file covers building, testing and how the code fits together. The [README](README.md) is the user-facing page. [AGENTS.md](AGENTS.md) has the product and design rules every change follows. Read its Product and Design sections before proposing a feature.

Bugs and ideas go in [GitHub issues](https://github.com/mrRedSun/reglance/issues).

## Requirements

- macOS 26 or later (Liquid Glass), Apple Silicon
- Swift 6.2+ toolchain (Xcode 26 or later)
- Claude Code installed and logged in
- ffmpeg, only for regenerating the README images (`brew install ffmpeg`)

## Build and run

```sh
scripts/build-app.sh          # builds build/ReGlance.app (release, ad-hoc signed)
scripts/build-app.sh --open   # builds and launches it
```

The app opens its chats window at launch. You can copy `build/ReGlance.app` to `/Applications`.

For development:

```sh
swift build
swift test
swift run Reglance     # runs the app unbundled
```

Write a failing test before fixing a bug. AppKit tests have a few traps (no key window, SwiftUI probing sizes); AGENTS.md lists them.

## Demo mode

Demo mode runs the app on made-up chats with canned replies. Use it to show ReGlance off, record it, or take screenshots without exposing real conversations:

```sh
REGLANCE_DEMO=1 build/ReGlance.app/Contents/MacOS/Reglance
```

- `REGLANCE_DEMO=1` (or the `--demo` argument) uses a fresh temporary data folder each launch. `REGLANCE_DEMO=/some/folder` uses that folder and keeps it between launches.
- Replies come from `DemoClient` in-process. Nothing is sent to Claude.
- Agent mode settings go to a separate `app.reglance.demo` defaults domain, and the chats window doesn't save its frame.
- The chats and replies live in `Sources/ChatCore/DemoContent.swift`.

## README images

`scripts/capture-readme.sh` regenerates every screenshot and GIF in `docs/images/`, in light and dark. Each scene launches the app in demo mode with `REGLANCE_DEMO_SCENE`, which stages one shot over a gradient backdrop (`Sources/Reglance/DemoScene.swift`). The script then captures the region the app reports.

```sh
scripts/capture-readme.sh               # every scene, about two minutes
scripts/capture-readme.sh hero picker   # only these
```

Your terminal needs Screen Recording permission. Leave the mouse alone while it runs and turn on Do Not Disturb. To add a scene, add a case to `DemoScene.Name`, stage it in `play`, add it to the script's default list, and reference `docs/images/<scene>-light|dark` in the README.

## Terminal client

`reglance-cli` goes through the same `ChatController` and `ClaudeClient` code as the app and saves to the same chat history:

```sh
swift run reglance-cli ask --model haiku "Which dogs can't bark?"
swift run reglance-cli ask --chat <chat-id> "Why do they yodel?"     # follow-up via --resume
swift run reglance-cli ask --model opus --effort high "Explain this"   # explicit effort
swift run reglance-cli regenerate <chat-id>                          # replace the last reply
swift run reglance-cli ask --stop-after 2 "Write a long essay"       # cancel, like the stop button
swift run reglance-cli ask --attach shot.png "What's in this?"       # attachments; repeatable
swift run reglance-cli ask --agent ~/Projects/app "Run the tests"     # agent chat: auto mode
swift run reglance-cli list
```

## How it talks to Claude

Each message goes to `claude -p --input-format stream-json` as one JSON user message on stdin: images as base64 image blocks, PDFs as document blocks, text files inlined. The system prompt is in `Sources/ChatCore/SystemPrompt.swift`. It fills in today's date and the user's region, units and currency from macOS settings. In ordinary chats, the only tools enabled are WebSearch and WebFetch.

Each follow-up runs `claude -p … --resume <session> --fork-session`. Every reply therefore has its own session id, and regenerate resumes the session from before the last turn. The CLI keeps those sessions in its own store (`~/.claude/projects/`).

The app looks for `claude` in the usual install locations (`~/.local/bin`, Homebrew, npm, bun). If it isn't there, it asks the login shell, because apps launched from Finder don't get the shell `PATH`.

### Codex

Install Codex (`brew install --cask codex`) and run `codex` once to sign in; Settings checks both. Each turn starts its own `codex app-server` (JSON-RPC over stdio, ready in well under a second) in `CodexWorkdir/`, with Reglance's system prompt as the thread's base instructions, so replies stream token by token. A follow-up forks the previous reply's thread (`thread/fork`), so every reply has its own id, like Claude's `--fork-session`. Stop sends `turn/interrupt` and ends the process. The picker's models come from `model/list` (`reglance-cli models` prints them).

Codex reads your own `~/.codex`, where its sign-in lives; Reglance never copies credentials. To keep a chat to web search, it disables every MCP server named in your `config.toml` and the shell, apps, plugins, browser, computer-use and memories features, and runs each thread read-only with approvals off. If Codex still starts an MCP server or anything but a web search, the reply stops with an error. Your global `~/.codex/AGENTS.md` is still loaded, because Codex has no setting to skip it, and Codex chats appear in your Codex history. PDFs aren't supported.

### OpenCode

Install OpenCode 2 (`brew install opencode`) and sign in to a provider with `opencode auth login`; Settings checks the version and the signed-in providers. OpenCode lists every model of every signed-in provider, so Settings has a list where you turn on the ones the picker shows.

Reglance runs its own `opencode serve` (the v2 API) on 127.0.0.1, on a free port, behind a random password per launch, and stops it when Reglance quits. It starts on the first OpenCode request and restarts when the system prompt changes (the date or your preferences), never during a reply. The server reads a private config folder (`OpenCodeWorkdir/Config`), so your OpenCode MCP servers, plugins and instructions stay out while your sign-ins still work. That config defines one agent, `reglance`, with Reglance's system prompt and permissions that deny everything except web fetch and search; anything else that starts stops the reply. Each reply is its own session, forked from the previous reply's, and Stop interrupts it. Images and PDFs work when the model accepts them.

Rich replies (charts, HTML widgets, documents) are fenced code blocks with a custom language tag. `design/widgets.md` has the format.

## Where things live

Everything is stored under `~/Library/Application Support/Reglance/`:

- `Chats/<id>.json`: one file per chat (title, timestamps, model, effort, pin/archive state, agent folder, Claude session id, messages).
- `Chats/<id>/`: copies of that chat's attachments.
- `ClaudeWorkdir/`: the empty working directory the `claude` subprocess runs in for ordinary chats, so no project files or `CLAUDE.md` get picked up. Agent chats run in their chosen folder.

## Code layout

- `Sources/ChatCore`: no UI. `ClaudeClient` (subprocess, stream-json parsing, cancel), `SystemPrompt`, `ClaudeLocator`, `Chat`/`Message`, `Attachment`, `ReplyContent` (splits replies into markdown and widget blocks), `ChatStore` (JSON persistence), `ChatController` (shared observable state), `DemoMode` and `DemoContent`.
- `Sources/Reglance`: the app. `FloatingPanel` (non-activating panel), `HotKey` (Carbon global hotkey, no Accessibility permission needed, and the saved shortcut), `PromptBarView` (the one composer both windows use), `ReplyView` (expanded panel and `MessageView`, which renders every message in both windows), `ReplyBody` (markdown, chart and document cards), `HTMLWidget` (sandboxed web view), `Attachments`, `PromptEditor` (native text and screenshot paste), `MainWindow`, `SettingsWindow` (login item, shortcut recorder, personal preferences, agent permissions and the provider doctor, whose checks live in `ChatCore/ClaudeDoctor`), `AgentMode` (agent-mode confirmations, permissions, folder picker, badge), `DemoScene` (README shots), `WindowDragRegion`, `MarkdownText`.
- `Sources/reglance-cli`: the terminal client.
- `Formula/reglance.rb`: the Homebrew formula. `scripts/build-app.sh` does the same build locally.
- `scripts/make-icon.swift`: draws the app icon and writes `Resources/AppIcon.icns`. Rerun it after changing the drawing.
- `scripts/capture-readme.sh`: regenerates `docs/images/`.
- `design/`: HTML mockups the UI follows.

## Releases

Homebrew builds from source: `Formula/reglance.rb` points at a tagged tarball and its sha256. To release, tag the commit, push the tag, then update the formula's URL and checksum.

## Not done yet

- Dictation.
