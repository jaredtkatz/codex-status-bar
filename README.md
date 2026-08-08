<p align="center">
  <img src="assets/AppIcon.png" width="128" alt="Codex Status Bar icon">
</p>

# Codex Status Bar

A tiny native macOS menu-bar app that shows live Codex Desktop task state.

It watches Codex Desktop's local lifecycle event stream. There is no setup, account, helper process, or hook configuration.

<p align="center">
  <img src="assets/status-menu.png" width="420" alt="Codex Status Bar showing active Codex tasks and its timer, thinking words, launch-at-login, and completion-sound controls">
</p>

## Lineage and credit

This edition builds on [Lasse's Codex Status Bar](https://github.com/lassejlv/codex-status-bar), which adapted [Mick Cesanek's original Claude Status Bar](https://github.com/m1ckc3s/claude-status-bar) for Codex. Their architecture, interface ideas, and MIT-licensed work made this project possible.

- **Mick Cesanek** created the original Claude Status Bar and its native macOS menu-bar design.
- **Lasse** created the first Codex fork, including Codex lifecycle support and the pet-based interface.
- **This edition** is maintained by [Nick Mauro](https://github.com/nickxma) as a focused, zero-setup companion for Codex Desktop.

The original MIT copyright and license are preserved in [LICENSE](LICENSE), with additional detail in [ACKNOWLEDGEMENTS.md](ACKNOWLEDGEMENTS.md).

## How this edition differs

| Area | Earlier Codex fork | This edition |
| --- | --- | --- |
| Codex surfaces | CLI and Desktop integration | Codex Desktop only |
| Setup | Codex hooks and a bundled helper | No hooks, helper, account, or configuration |
| Activity detection | Hook-driven status plus Desktop compatibility | Event-driven local Desktop lifecycle monitoring |
| Menu | Pet selection, animation, and mixed session rows | Exact task titles, thinking words, timer, sound, and clear active/recent groups |
| Session list | Multiple Codex surfaces and workspace-oriented rows | Top-level user tasks only; internal runs, automations, CLI sessions, and helpers are filtered out |
| Completed tasks | General idle-session retention | Five most recent completions for 15 minutes |
| Background behavior | Tied to Codex/session lifecycle | Lightweight login utility that is ready whenever Codex opens |
| Distribution | Source-oriented fork | Tested universal DMG for Apple Silicon and Intel, built by GitHub Actions |

This is a substantial derivative, not an official successor. Upstream credit does not imply that Mick or Lasse endorses or maintains this edition.

## What it shows

- A monochrome spark that automatically matches the macOS menu bar in light and dark appearances.
- A rotating Claude-style thinking word while Codex works (`Pondering…`, `Brewing…`, `Tinkering…`).
- The full elapsed time of the current turn, including thinking and tool use.
- A yellow indicator when Codex needs permission.
- Independent **Thinking words** and **Show timer** toggles.
- A completion sound after every turn by default, optionally limited to turns longer than 1, 5, or 15 minutes.
- Automatic launch at login, with an in-app toggle.
- Exact Codex task titles for every active or recently completed session.

The app is local-only. It does not read message content, collect telemetry, use an API key, or require Node, npm, Bun, or another runtime. For Codex Desktop it watches file changes rather than repeatedly scanning the session tree, then inspects only lifecycle event names and session metadata.

## Build and install

Requires macOS 13 or later.

### Install the app

1. Download the latest `CodexStatusBar.dmg` from [Releases](https://github.com/nickxma/codex-status-bar/releases/latest).
2. Drag **CodexStatusBar** into Applications.
3. Open the app. Releases are signed and notarized when maintainer credentials are available; otherwise macOS may require you to right-click the app and choose **Open** once.

Each release also includes `CodexStatusBar.dmg.sha256` for download verification.

The app launches at login by default. Disable **Launch at login** from its menu at any time.

### Build from source

Building requires Xcode Command Line Tools.

```bash
./build.sh
open build/CodexStatusBar.app
```

For a DMG:

```bash
./build.sh --dmg
```

Builds are native to the current Mac by default. A release runner with full Xcode can produce a universal binary with `BUILD_ARCH=universal ./build.sh --dmg`.

Move the app to `/Applications` or `~/Applications`, then open it once. It enables **Launch at login** by default and remains as a lightweight menu-bar utility so it can notice Codex opening later.

## Session behavior

- A session appears when Codex records its first real `task_started` lifecycle event. Merely opening a conversation does not add a row.
- Every active task is shown, ordered by recent activity.
- After completion or cancellation, up to five of the most recently completed tasks remain visible for 15 minutes.
- Completed state files are removed after 15 minutes. Active states have a 12-hour safety timeout in case Codex exits without writing a terminal event.
- Row names come from Codex's local task-title index. The workspace folder name is used only when the task has no indexed title.

## Testing

```bash
scripts/test.sh
swiftc -typecheck Sources/*.swift -framework Cocoa
./build.sh
```

See [PRIVACY.md](PRIVACY.md), [TROUBLESHOOTING.md](TROUBLESHOOTING.md), and [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT

## Trademark / not affiliated

This is an unofficial open-source project. It is not affiliated with, endorsed by, or sponsored by OpenAI or Anthropic. Codex and OpenAI are trademarks of OpenAI. Claude and the Claude spark logo are trademarks of Anthropic. The spark is used in the same nominative, noncommercial spirit as the upstream Claude Status Bar project; the MIT license does not grant trademark rights.
