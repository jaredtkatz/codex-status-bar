#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v watchexec >/dev/null 2>&1; then
  echo "The optional development loop needs watchexec." >&2
  echo "Install it with 'brew install watchexec', then rerun ./scripts/dev.sh." >&2
  echo "Normal builds do not require watchexec." >&2
  exit 127
fi

cleanup() {
  ./scripts/dev-relaunch.sh --stop
}
trap cleanup EXIT INT TERM

echo "Watching repository files. Press Ctrl-C to stop the development app."
watchexec \
  --project-origin . \
  --watch . \
  --debounce 250ms \
  --on-busy-update queue \
  -- ./scripts/dev-relaunch.sh
