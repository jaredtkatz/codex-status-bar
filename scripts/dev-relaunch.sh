#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

ROOT="$PWD"
ACTIVE_DIR="$ROOT/build/dev"
STAGING_DIR="$ROOT/build/dev-next"
APP="$ACTIVE_DIR/CodexStatusBar.app"
BIN="$APP/Contents/MacOS/CodexStatusBar"
LOG="$ROOT/build/dev.log"

app_pids() {
  pgrep -x CodexStatusBar 2>/dev/null || true
}

command_for_pid() {
  ps -p "$1" -o command= 2>/dev/null || true
}

stop_repo_dev_apps() {
  local pid command_path attempt
  local -a pids=()

  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    command_path="$(command_for_pid "$pid")"
    case "$command_path" in
      "$ROOT"/build/*/CodexStatusBar.app/Contents/MacOS/CodexStatusBar)
        pids+=("$pid")
        ;;
    esac
  done < <(app_pids)

  ((${#pids[@]} == 0)) && return 0
  kill -TERM "${pids[@]}" 2>/dev/null || true
  for attempt in {1..50}; do
    local still_running=0
    for pid in "${pids[@]}"; do
      if kill -0 "$pid" 2>/dev/null; then still_running=1; break; fi
    done
    ((still_running == 0)) && return 0
    sleep 0.1
  done

  echo "Development app did not quit within 5 seconds; forcing it to stop." >&2
  kill -KILL "${pids[@]}" 2>/dev/null || true
}

foreign_app_paths() {
  local pid command_path
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    command_path="$(command_for_pid "$pid")"
    [[ -n "$command_path" ]] || continue
    case "$command_path" in
      "$ROOT"/build/*/CodexStatusBar.app/Contents/MacOS/CodexStatusBar) ;;
      *) printf '%s\n' "$command_path" ;;
    esac
  done < <(app_pids)
}

if [[ "${1:-}" == "--stop" ]]; then
  stop_repo_dev_apps
  exit 0
fi

foreign="$(foreign_app_paths)"
if [[ -n "$foreign" ]]; then
  echo "Another CodexStatusBar instance is already running:" >&2
  printf '  %s\n' "$foreign" >&2
  echo "Quit the installed copy or other checkout before using the development loop." >&2
  exit 1
fi

# Build away from the live bundle. A compiler or signing failure therefore leaves the current
# development process untouched and preserves the last successfully launched bundle.
if ! BUILD_DIR="$STAGING_DIR" DEVELOPMENT_BUILD=1 LOCAL_ADHOC=1 ./build.sh; then
  echo "Build failed; the current development app is still running." >&2
  exit 1
fi

stop_repo_dev_apps
rm -rf "$ACTIVE_DIR"
mv "$STAGING_DIR" "$ACTIVE_DIR"

mkdir -p "$(dirname "$LOG")"
CODEX_STATUS_BAR_DEVELOPMENT=1 nohup "$BIN" >"$LOG" 2>&1 &
pid=$!
sleep 0.5
if ! kill -0 "$pid" 2>/dev/null; then
  echo "Development app exited during startup. Recent log output:" >&2
  tail -n 30 "$LOG" >&2 || true
  exit 1
fi

echo "Relaunched development app (pid $pid). Log: $LOG"
