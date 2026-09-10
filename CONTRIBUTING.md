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
