# Privacy

Codex Status Bar runs locally and collects no telemetry.

For Codex Desktop, the app watches recently active JSONL files under `~/.codex/sessions`, task names in `~/.codex/session_index.jsonl`, the local task catalog in `~/.codex/sqlite/codex-dev.db`, and lifecycle/state lines in Codex Desktop's local logs. It parses only task identity, title, host, session metadata, and structured lifecycle state. It does not access user or assistant message bodies. Filesystem events wake the local monitor when a session changes.

For SSH connections already configured in Codex Desktop, the app makes bounded, non-interactive SSH reads of remote task titles, session metadata, and lifecycle envelopes. It does not connect directly to Remote Control hosts. The app makes no other network requests and does not modify Codex configuration. When **Launch at login** is enabled, it registers itself using macOS's native login-item service.
