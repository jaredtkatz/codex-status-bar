#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/tests
swiftc Tests/DesktopSessionMonitorTests.swift Sources/DesktopSessionMonitor.swift Sources/DesktopTaskRegistryMonitor.swift Sources/RemoteSessionMonitor.swift Sources/StatusPolicy.swift Sources/DesktopLiveStatusMonitor.swift Sources/CodexStateStore.swift -o build/tests/DesktopSessionMonitorTests -framework Cocoa -lsqlite3
build/tests/DesktopSessionMonitorTests
node --check hooks/update.js
node --check hooks/lifecycle.js
node --check hooks/install.js
node Tests/HookTests.js
bash -n build.sh scripts/dev.sh scripts/dev-relaunch.sh
