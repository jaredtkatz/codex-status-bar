# Contributing

PRs are welcome. You don't need collaborator access: fork the repo, push a branch to your fork, and open a pull request back here.

## Submit a pull request

1. [Fork this repo](https://github.com/nickxma/codex-status-bar/fork) into your GitHub account.
2. Clone your fork and create a branch (replace `YOUR-USERNAME`):

   ```bash
   git clone https://github.com/YOUR-USERNAME/codex-status-bar.git
   cd codex-status-bar
   git remote add upstream https://github.com/nickxma/codex-status-bar.git
   git switch -c fix/your-change
   ```

3. Make your changes, run the checks below, and commit the files you changed.
4. Push to your fork:

   ```bash
   git push -u origin HEAD
   ```

5. Open a pull request with **base repository: `nickxma/codex-status-bar`**, **base: `main`**, and your fork's branch as the head. Describe the problem, what changed, and how you tested it. Include a screenshot for visible UI changes.

### Already cloned this repo or have changes ready?

Keep your existing checkout and changes. Create your fork on GitHub, then add it as a separate remote and push your current branch:

```bash
git remote add myfork https://github.com/YOUR-USERNAME/codex-status-bar.git
git push -u myfork HEAD
```

Commit any uncommitted changes before pushing. If `myfork` already exists, check `git remote -v` and use the remote that points to your own fork. Then open the pull request as described above.

If pushing to `nickxma/codex-status-bar` gives a permission error, push to your fork instead. Creating branches directly in this repo requires a collaborator invitation; opening a PR from your fork does not. GitHub may require a maintainer to approve the first CI run from a new contributor.

## Scope

Keep Codex Status Bar small, local, native, and dependency-free.

Welcome changes include correctness fixes, Codex Desktop lifecycle compatibility, performance improvements, accessibility, and restrained visual polish.

Existing Claude Desktop/CLI integration is also in scope. Out of scope: Codex CLI hooks, message-content parsing, usage or cost dashboards, telemetry, API calls, and unrelated agent providers.

## Local checks

Use a Mac with Xcode Command Line Tools installed. Local builds don't require Apple signing credentials or repository secrets.

Before submitting a change, run:

```bash
scripts/test.sh
swiftc -typecheck Sources/*.swift -framework Cocoa -framework ServiceManagement
bash -n build.sh
./build.sh
```

## Opt-in rebuild loop

For normal UI iteration, an optional `watchexec` loop can rebuild and relaunch the app after source
or bundled-resource changes:

```bash
brew install watchexec
./scripts/dev.sh
```

The command performs one build immediately, then watches the repository while honoring its ignore
files (so generated `build` output does not retrigger it). Changes that arrive during a build are
queued for one follow-up build. Development builds include debug symbols and disable optimization.
Only a successful, ad-hoc-signed build replaces and relaunches `build/dev/CodexStatusBar.app`; a
failed build leaves the last development instance running. Press Control-C to stop both the watcher
and its app.

This workflow is entirely opt-in: `watchexec` is not needed by normal builds, tests, CI, or releases.
Development launches skip automatic login-item registration and hook installation. They still use
the normal preferences and local session data, so settings and task rows recover after a relaunch;
ephemeral UI state such as an open menu does not. To prevent duplicate menu items and shared-state
races, the script refuses to launch while a CodexStatusBar instance outside this repository's
`build` directory is running.

For LLDB work, stop the watcher first so it does not replace the process being debugged, then use:

```bash
BUILD_DIR=build/dev DEVELOPMENT_BUILD=1 LOCAL_ADHOC=1 ./build.sh
lldb build/dev/CodexStatusBar.app/Contents/MacOS/CodexStatusBar
```

At the LLDB prompt, set `CODEX_STATUS_BAR_DEVELOPMENT=1` with
`settings set target.env-vars CODEX_STATUS_BAR_DEVELOPMENT=1`, then run the target.

Runtime injection was deliberately not added. This project has no Xcode project or Swift package,
and its UI is an imperative AppKit object graph rather than replaceable SwiftUI views. Injection
would add package, linker, runtime-loader, and view-host setup; it also cannot apply stored-property
layout changes. Whole-process relaunch exercises startup and monitor cleanup while keeping the
production dependency-free build unchanged.

Test behavioral changes in Codex Desktop. Use Conventional Commit prefixes such as `feat`, `fix`, `test`, `docs`, and `chore`.

The app version lives in `VERSION`. Release tags use the matching `v<version>` form.

## Maintainer release signing

Tagged releases are signed and notarized when these GitHub Actions secrets are configured:

- `APPLE_CERTIFICATE_BASE64`: the exported Developer ID Application certificate (`.p12`), base64 encoded
- `APPLE_CERTIFICATE_PASSWORD`: the `.p12` export password
- `APPLE_ID`: the Apple ID used for notarization
- `APPLE_TEAM_ID`: the Apple Developer team ID
- `APPLE_APP_SPECIFIC_PASSWORD`: an app-specific password for that Apple ID

Official release builds require a Developer ID identity and successful notarization. Missing signing prerequisites fail the release; ad-hoc builds remain available only for local development.
