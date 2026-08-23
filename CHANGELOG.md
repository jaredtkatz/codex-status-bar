# Changelog

## 0.5.0 — 2026-08-22

- Made every active-task row open its exact conversation through Codex Desktop's native thread
  deep link, including Remote Control tasks.
- Added a lightweight wiggle animation to the monochrome status mark while a task is active, with
  automatic Reduce Motion support.

## 0.4.9 — 2026-08-22

- Simplified the menu to active tasks only. Completed and cancelled tasks disappear immediately,
  while their lifecycle state remains available internally for completion sounds and cleanup.

## 0.4.8 — 2026-08-22

- Restored active and recently completed rows after Codex 0.149 removed the schema-v4 aggregate
  thread snapshot from Desktop logs.
- Reconciled every visible row against Codex Desktop's current catalog title so chat renames mirror
  the Mac app exactly instead of retaining a stale title or workspace fallback.
- Added current `turn/start` lifecycle parsing while retaining the older aggregate parser as a
  compatibility fallback.

## 0.4.7 — 2026-08-08

- Replaced five-times-per-second state-directory polling with filesystem notifications plus a
  one-second safety refresh, preserving prompt task updates while eliminating idle scans.
- Cached Codex's remote connection configuration and skipped SSH polling for hosts with no assigned
  tasks; active SSH snapshots now use a five-second interval.
- Consolidated Desktop log consumption into one incremental pass, cached log discovery, and reduced
  catalog database refreshes from every five seconds to every 30 seconds.
- Removed the repeated ServiceManagement XPC lookup from the five-second runtime heartbeat.

## 0.4.6 — 2026-08-06

- Backported Mick Cesanek's notification-driven Desktop-app detection from Claude Status Bar
  0.4.4, eliminating ten full running-application enumerations per second while preserving an
  immediate refresh when Codex launches.
- Confirmed the other upstream CPU fixes are already native to this edition: title rendering is
  change-gated, the static status icon is reused, and session JSON is reparsed only after its
  modification time changes. Upstream animation-frame and transcript-tail caches do not apply
  because this edition has neither animated pets nor transcript polling.

## 0.4.5 — 2026-08-06

- Reconcile the menu with Codex Desktop's cross-host task registry so genuinely active local, SSH,
  and Remote Control tasks appear together, with no cap on active tasks.
- Rediscover active local and SSH sessions whose rollout files originated on an older date.
- Keep the five-task cap limited to completed history and retain automation/helper filtering.
- Added live lifecycle monitoring for Codex Desktop threads running on configured SSH remote
  machines, using Codex's existing host aliases, bounded authentication, and SSH multiplexing.
- Use Codex Desktop's remote-project assignments—not the remote transcript's misleading source
  label—to retain top-level delegated tasks while filtering unassigned internal helpers.
- Made **Show timer** consistently control both the menu-bar clock and active-task row clocks.
- Expire working markers after 30 minutes without lifecycle activity so interrupted turns cannot
  remain under **Active tasks** for hours when Codex omits a cancellation event.

## 0.4.4 — 2026-08-08

- Changed the resting menu-bar spark to a native monochrome template icon so it matches the other
  macOS menu-bar icons in light and dark appearances.

## 0.4.3 — 2026-08-06

- Added a current product screenshot and public issue/security guidance.
- Updated GitHub Actions to their Node 24 releases.
- Added optional CI signing and notarization support without embedding maintainer credentials.
- Removed the inherited upstream Apple Team ID from the build script.
- Added a single version source and a SHA-256 checksum beside the release DMG.

## 0.4.2

- Replaced the inherited pixel-pet app artwork with the same Claude spark used by the menu-bar app.
- Removed obsolete Codex plugin, hook, and SVG artifacts left over from the pre-Desktop-only editions.

## 0.4.1

- Split the vague Sessions list into clear **Active tasks** and **Recently completed** sections.
- Show **Open Codex** under a simple Codex heading when there is no task history to display.

## 0.4.0

- Added native launch-at-login support, enabled by default with an in-app toggle.
- Made completion sound after every turn the explicit first-run default.
- Defined deterministic session behavior: all active tasks plus the five most recent completed tasks for 15 minutes.
- Removed the self-quit behavior so the login utility can detect Codex opening later.
- Added a 12-hour active-state safety timeout for missed terminal events.
- Fixed fractional lifecycle timestamps so relaunching cannot make old completed tasks look new.
- Filtered internal, CLI, automation, and untitled helper sessions from the user-task list.
- Updated installation, troubleshooting, privacy, and contribution documentation for the Desktop-only app.

## 0.3.1

- Display the exact Codex task title from the local session index.
- Propagate task-title renames through filesystem events.
- Keep the workspace folder name only as a fallback when no title is available.

## 0.3.0

- Simplified the app to zero-setup Codex Desktop support only.
- Removed CLI hooks, the bundled hook helper, hook setup UI, and hook configuration entirely.
- Removed redundant APP badges and their rendering code.

## 0.2.0

- Added live Codex Desktop support through local lifecycle event watching.
- Replaced recursive session polling with filesystem events for faster startup and lower idle work.
- Added Claude-style rotating thinking words and independent timer controls.
- Added configurable completion sounds.
- Added the Claude spark menu-bar icon and app icon.
- Collapsed duplicate resting Desktop sessions by workspace.
- Removed the Codex pet picker, sprite renderer, configuration writes, animation timer, tests, and bundled pet atlas.
- Removed the temporary Desktop completion-notification bridge and all machine-specific paths.
- Changed the release bundle identifier to `com.nickxma.codexstatusbar`.

## 0.1.0

- Forked the original Claude Status Bar architecture for Codex.
- Added documented Codex lifecycle hook support for CLI and Desktop.
- Added explicit first-launch confirmation before hook installation.
- Added safe, idempotent `~/.codex/hooks.json` merging and backup.
- Replaced Node hook scripts with a universal native Swift helper.
- Replaced Claude artwork with the selected custom Codex pet atlas from `~/.codex/pets`, including idle, working, and waiting states.
- Added bounded `turn_aborted` event detection so Esc clears working state.
- Removed message parsing, upstream release checks, and external runtime dependencies.
