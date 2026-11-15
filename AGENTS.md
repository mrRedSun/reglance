# Reglance

A lightweight native macOS chat bar for Claude (⌥Space), plus a chats window. The README is the user-facing marketing page, CONTRIBUTING.md covers building, demo mode and code layout, and this file covers how to work on it.

## Product

- **Light and fast first.** Prefer native AppKit and SwiftUI over dependencies. Drop a feature before making the app heavier.
- **A plain chat, not a coding agent.** Claude runs as headless `claude -p` with a minimal system prompt, no skills or MCP, and only WebSearch and WebFetch. Anything that acts on the Mac waits for agent mode (GitHub issue #1).
- **Hide what isn't built.** An unfinished control (dictation, the + button) stays out of the UI until it works.

## Design

- **Apple-native, Liquid Glass.** Follow Apple's HIG: glass only on the floating controls layer (bars, composer, picker card), one glass surface per control, semantic system colors, the system accent color, and one tinted primary action (send).
- **Glass that overlaps stays separate.** Shapes in one `GlassEffectContainer` fuse into one blob when they overlap, so a card over the bar gets its own glass layer.
- **One composer.** `PromptBarView` serves the floating bar and the chats window. Fix input, paste, picker, and sizing there once; the windows differ only in who owns the glass and whether it grows into a reply panel.
- **One radius.** Corner radii come from `ComposerShape` (half a one-line composer's height, a capsule). Surrounding panels stay concentric with it.
- **Motion is springy and Apple-style**, with hero transitions (the model pill grows into its card). Nothing jumps: the floating panel keeps one tall transparent frame and its glass grows upward inside it, so the window never resizes mid-animation.
- **Native window behaviour over SwiftUI emulation.** The sidebar is always shown and window tabbing is off. Reach for the AppKit primitive (split view items, menu validation, responder actions) before reimplementing it.

## Working with the user

- **The user is the visual tester.** Make the change, run `swift test`, rebuild with `scripts/build-app.sh --open`, and say what to look at. They judge how it looks and feels. Screenshots, screen recordings, and offscreen renders are out: they cost tokens and once captured private windows.
- **Ask when a request has two readings** ("taller" could mean the empty bar or more lines before scrolling). One short question beats building the wrong one.
- **Read layout and animation bugs as the user describes them.** "Jumping" means something moves or pops, not easing. Ask what exactly moves when unsure.
- **Chats are the user's data.** `~/Library/Application Support/Reglance` and the CLI's `~/.claude/projects/*Reglance*` sessions hold real conversations. Tests use temporary directories. Inspect structure (field names, counts), not message contents.

## Testing gotchas

Reproduce a bug with a failing test before fixing it. AppKit tests here have traps:

- **No key window.** The test runner isn't the active app, so a window can't reliably become key and synthesized keystrokes get lost in the full suite. Test the gate instead: `validateUserInterfaceItem` for menu commands, then call the action.
- **SwiftUI probes sizes.** It measures views at several widths (some 40pt) before settling. Sizing code must measure without mutating live views (the composer once wrapped one word per line this way).
- **Measure the real window.** A hand-built fixture can pass while the real window fails. When a fixture can't reproduce a bug, measure the actual `MainWindowController` or `FloatingPanelController` views.
- **Order-dependent tests** usually mean leftover window state; run the suite twice before trusting a fix.

## README and marketing

The README sells the app to users: hook first (hero GIF, one-line pitch, install), then the feature table, then details folded into `<details>`. Developer material goes in CONTRIBUTING.md.

- **Same change, same commit.** When a user-visible feature ships, changes or is removed, update the README's feature table, shortcuts table and details in that change. Hidden, unfinished controls stay out of the README too.
- **Images come from demo mode.** Every image in `docs/images/` comes from a `DemoScene` captured by `scripts/capture-readme.sh`, in light and dark. A new feature worth showing gets a new scene and a README row. A design change that alters what a scene shows means the user reruns the script: name the scenes to recapture (`scripts/capture-readme.sh hero chats`) in your summary. The script is theirs to run, because it takes over the screen.
- **Demo content is made up.** Keep demo chats and replies in `DemoContent.swift`, and leave real chats out of images and examples.

## Releases

Homebrew builds from source (`Formula/reglance.rb`, tagged tarball plus sha256). Commit, tag, push, and publish only when the user asks.
