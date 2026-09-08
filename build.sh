#!/bin/bash
# Builds CodexStatusBar.app (and optionally a .dmg with: ./build.sh --dmg).
set -euo pipefail
cd "$(dirname "$0")"

APP="build/CodexStatusBar.app"
BIN="$APP/Contents/MacOS/CodexStatusBar"
VERSION="$(tr -d '[:space:]' < VERSION)"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Invalid VERSION: $VERSION" >&2
  exit 2
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

BUILD_ARCH="${BUILD_ARCH:-$(uname -m)}"
case "$BUILD_ARCH" in
  arm64|x86_64)
    echo "Compiling native $BUILD_ARCH binary…"
    swiftc -O -target "$BUILD_ARCH-apple-macos13.0" Sources/*.swift -o "$BIN" -framework Cocoa -framework ServiceManagement -lsqlite3
    ;;
  universal)
    echo "Compiling universal binary (arm64 + x86_64)…"
    swiftc -O -target arm64-apple-macos13.0  Sources/*.swift -o "$BIN.arm64"  -framework Cocoa -framework ServiceManagement -lsqlite3
    swiftc -O -target x86_64-apple-macos13.0 Sources/*.swift -o "$BIN.x86_64" -framework Cocoa -framework ServiceManagement -lsqlite3
    lipo -create "$BIN.arm64" "$BIN.x86_64" -output "$BIN"
    rm -f "$BIN.arm64" "$BIN.x86_64"
    ;;
  *) echo "Unsupported BUILD_ARCH: $BUILD_ARCH" >&2; exit 2 ;;
esac

mkdir -p "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>CodexStatusBar</string>
  <key>CFBundleDisplayName</key><string>Codex Status Bar</string>
  <key>CFBundleIdentifier</key><string>com.nickxma.codexstatusbar</string>
  <key>CFBundleExecutable</key><string>CodexStatusBar</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

cp assets/completion.mp3 "$APP/Contents/Resources/completion.mp3"
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp hooks/update.js hooks/lifecycle.js hooks/install.js "$APP/Contents/Resources/"

# --- Signing / notarization ---
# For a clean (no Gatekeeper warning) release you need, set up once on this Mac:
#   1. A "Developer ID Application" certificate in your keychain (Xcode > Settings > Accounts).
#   2. A notarytool credential profile:
#        xcrun notarytool store-credentials "codex-statusbar" \
#          --apple-id you@example.com --team-id <team-id> --password <app-specific-password>
# Then `./build.sh --dmg` auto-signs + notarizes. Without a cert it falls back to an
# ad-hoc dev build (runnable locally; users would need right-click > Open once).
TEAM_ID="${TEAM_ID:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-codex-statusbar}"
NOTARY_KEYCHAIN="${NOTARY_KEYCHAIN:-}"
NOTARY_AUTH=(--keychain-profile "$NOTARY_PROFILE")
if [[ -n "$NOTARY_KEYCHAIN" ]]; then
  NOTARY_AUTH+=(--keychain "$NOTARY_KEYCHAIN")
fi

# Use the requested team when supplied; otherwise use the first Developer ID Application
# identity in the current keychain search list. An empty result falls through to the local,
# ad-hoc-signed build path.
IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application" || true)"
if [[ -n "$TEAM_ID" ]]; then
  IDENTITIES="$(printf '%s\n' "$IDENTITIES" | grep "$TEAM_ID" || true)"
fi
SIGN_ID="$(printf '%s\n' "$IDENTITIES" | head -1 | sed -E 's/.*"(.*)"/\1/')"

# Tagged GitHub builds are official releases even when the workflow does not set a flag.
if [[ "${GITHUB_ACTIONS:-}" == "true" && "${GITHUB_REF_TYPE:-}" == "tag" && "${1:-}" == "--dmg" ]]; then
  REQUIRE_SIGNING=1
fi
if [[ "${LOCAL_ADHOC:-}" == "1" ]]; then
  SIGN_ID=""
fi

if [[ "${REQUIRE_SIGNING:-}" == "1" && ( -z "$SIGN_ID" || "${SKIP_NOTARIZE:-}" == "1" ) ]]; then
  echo "Release requires Developer ID signing and notarization." >&2
  exit 1
fi

# Strip extended attributes (Finder info, quarantine, etc.) that bundled resources can
# carry — codesign rejects them ("resource fork, Finder information, ... not allowed").
xattr -cr "$APP"

if [[ -n "$SIGN_ID" ]]; then
  echo "Signing with Developer ID: $SIGN_ID"
  codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP"
else
  echo "No matching Developer ID cert found — ad-hoc signing (local dev build)."
  codesign --force --sign - "$APP" >/dev/null 2>&1 || true
fi
echo "Built $APP"

if [[ "${1:-}" == "--dmg" ]]; then
  # Notarize + staple the APP first, so a copied-out .app is independently notarized.
  # The DMG itself is notarized + stapled later (below) — that's the check a downloader
  # actually hits, so the image must carry its own ticket to open without a warning.
  if [[ "${SKIP_NOTARIZE:-}" != "1" && -n "$SIGN_ID" ]]; then
    echo "Notarizing the app via profile '$NOTARY_PROFILE' (can take a minute)…"
    rm -f build/app-notarize.zip
    ditto -c -k --keepParent "$APP" build/app-notarize.zip
    xcrun notarytool submit build/app-notarize.zip "${NOTARY_AUTH[@]}" --wait
    xcrun stapler staple "$APP"
    rm -f build/app-notarize.zip
    echo "App notarized + stapled."
  fi

  echo "Packaging DMG…"
  DMG="build/CodexStatusBar.dmg"
  STAGE="build/dmg-stage"
  rm -rf "$STAGE" "$DMG" "$DMG.sha256" build/rw.dmg
  mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"

  # Eject any stale "Codex Status Bar" volumes from earlier builds first. Otherwise a name
  # collision mounts this one as "Codex Status Bar 2", the hardcoded /Volumes path below points
  # at the wrong volume (layout capture silently fails), and the stale mounts pile up in Finder.
  for d in $(hdiutil info | awk '/Codex Status Bar/ {print $1}'); do hdiutil detach "$d" >/dev/null 2>&1 || true; done

  # Lay out the window on a read-write image to capture its .DS_Store, then build the final
  # image from the folder (see below).
  hdiutil create -volname "Codex Status Bar" -srcfolder "$STAGE" -ov -format UDRW build/rw.dmg >/dev/null
  device="$(hdiutil attach -readwrite -noverify -noautoopen build/rw.dmg | grep -E '^/dev/' | head -1 | awk '{print $1}')"
  sleep 1
  osascript <<'OSA' || echo "(Finder layout skipped — DMG still has the app + Applications shortcut)"
tell application "Finder"
  tell disk "Codex Status Bar"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {400, 200, 880, 540}
    set vo to the icon view options of container window
    set arrangement of vo to not arranged
    set icon size of vo to 100
    set text size of vo to 12
    set position of item "CodexStatusBar.app" of container window to {130, 150}
    set position of item "Applications" of container window to {350, 150}
    update without registering applications
    delay 1
    close
  end tell
end tell
OSA
  # Capture the layout Finder just wrote (.DS_Store), then discard the writable image and build
  # the final compressed image straight from the folder. Building from a folder never mounts a
  # writable volume, so macOS's fseventsd never creates a hidden .fseventsd in the shipped DMG.
  # (Removing .fseventsd from a mounted volume does not stick: the removal is itself an event
  # fseventsd logs, which recreates the folder.)
  cp "/Volumes/Codex Status Bar/.DS_Store" "$STAGE/.DS_Store" 2>/dev/null || true
  hdiutil detach "$device" >/dev/null || true
  rm -f build/rw.dmg
  # Scrub any hidden folder that may have accrued (.fseventsd, .Trashes, .Spotlight-V100, …),
  # keeping only the intentional .DS_Store that carries the window layout.
  find "$STAGE" -maxdepth 1 -name ".*" ! -name ".DS_Store" -exec rm -rf {} + 2>/dev/null || true
  hdiutil create -volname "Codex Status Bar" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
  rm -rf "$STAGE"

  # Guard: the shipped image must hold nothing but the app, the Applications symlink, and the
  # .DS_Store layout file. Mount read-only and abort before notarizing if any stray hidden entry
  # slipped in (the recurring .fseventsd/.Trashes problem).
  vdev="$(hdiutil attach -nobrowse -noautoopen -readonly "$DMG" | grep -E '^/dev/' | tail -1 | awk '{print $1}')"
  stray="$(find "/Volumes/Codex Status Bar" -maxdepth 1 -name ".*" ! -name ".DS_Store" 2>/dev/null)"
  hdiutil detach "$vdev" >/dev/null 2>&1 || true
  if [[ -n "$stray" ]]; then
    echo "ERROR: DMG has stray hidden entries, aborting before notarize:"; echo "$stray"; exit 1
  fi
  echo "DMG verified clean (no stray hidden folders)."

  # Sign, then notarize + staple the DMG so the downloaded image opens with no Gatekeeper
  # warning. Stapling writes the ticket into the read-only image's metadata; it does not
  # mount-and-write the inner filesystem, so .fseventsd does not come back.
  if [[ -n "$SIGN_ID" ]]; then
    codesign --force --timestamp --sign "$SIGN_ID" "$DMG"
    if [[ "${SKIP_NOTARIZE:-}" != "1" ]]; then
      echo "Notarizing the DMG via profile '$NOTARY_PROFILE' (can take a minute)…"
      xcrun notarytool submit "$DMG" "${NOTARY_AUTH[@]}" --wait
      xcrun stapler staple "$DMG"
      echo "DMG notarized + stapled."
    else
      echo "SKIP_NOTARIZE=1 — DMG signed but NOT notarized (layout test only)."
    fi
  fi
  if [[ "${REQUIRE_SIGNING:-}" == "1" ]]; then
    codesign --verify --deep --strict "$APP"
    xcrun stapler validate "$APP"
    xcrun stapler validate "$DMG"
    spctl --assess --type execute "$APP"
  fi
  shasum -a 256 "$DMG" > "$DMG.sha256"
  echo "Built checksum $DMG.sha256"
  echo "Built $DMG"
fi
