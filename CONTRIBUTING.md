# Contributing

Keep Codex Status Bar small, local, native, and dependency-free.

Welcome changes include correctness fixes, Codex Desktop lifecycle compatibility, performance improvements, accessibility, and restrained visual polish.

Out of scope: Codex CLI hooks, message-content parsing, usage or cost dashboards, telemetry, API calls, and unrelated agent providers.

Before submitting a change, run:

```bash
scripts/test.sh
swiftc -typecheck Sources/*.swift -framework Cocoa
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
