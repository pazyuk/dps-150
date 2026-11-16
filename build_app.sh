#!/bin/bash
# Builds "DPS-150 Control.app" in dist/.
#   ./build_app.sh            — build only (ad-hoc signature)
#   ./build_app.sh --install  — build and copy to /Applications
#
# Environment variables (all optional; CI sets them for the App Store):
#   VERSION, BUILD   — CFBundleShortVersionString / CFBundleVersion (default 1.0 / 1)
#   BUNDLE_ID        — default ge.dps150.control
#   SWIFT_FLAGS      — e.g. "--arch arm64 --arch x86_64" for a universal build
#   SANDBOX=1        — sign with the App Sandbox (as in the App Store)
#   UPDATE_REPO      — GitHub "owner/repository" for update checks;
#                      defaults to git remote origin, not used in a SANDBOX build
#   SIGN_ID          — codesign identity; default "-" (ad-hoc)
#   TEAM_ID, PROFILE — Team ID and path to the provisioning profile (App Store only)
set -e
cd "$(dirname "$0")"
APP="DPS-150 Control"
OUT="dist/$APP.app/Contents"
VERSION=${VERSION:-1.0}
BUILD=${BUILD:-1}
BUNDLE_ID=${BUNDLE_ID:-ge.dps150.control}
UPDATE_REPO=${UPDATE_REPO-$(git remote get-url origin 2>/dev/null | sed -nE 's#.*github\.com[:/](.+)$#\1#p' | sed 's#\.git$##')}
UPDATE_KEY=""
if [ -z "$SANDBOX" ] && [ -n "$UPDATE_REPO" ]; then
  UPDATE_KEY="<key>DPSUpdateRepo</key><string>$UPDATE_REPO</string>"
fi

# shellcheck disable=SC2086
swift build -c release $SWIFT_FLAGS
# shellcheck disable=SC2086
BIN=$(swift build -c release $SWIFT_FLAGS --show-bin-path)
rm -rf "dist/$APP.app" && mkdir -p "$OUT/MacOS" "$OUT/Resources"
cp "$BIN/DPS150Control" "$OUT/MacOS/$APP"
cp -R Resources/*.lproj "$OUT/Resources/"   # localizations: macOS picks the language

ICONSET=.build/icon.iconset
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s assets/icon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) assets/icon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$OUT/Resources/icon.icns"

cat > "$OUT/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>$APP</string>
  <key>CFBundleExecutable</key><string>$APP</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleIconFile</key><string>icon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>ITSAppUsesNonExemptEncryption</key><false/>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
  <key>NSHumanReadableCopyright</key><string>© 2026 Alexey Pazyuk. GPL-3.0-or-later.</string>
  <key>NSHighResolutionCapable</key><true/>
  $UPDATE_KEY
</dict></plist>
EOF

SIGN_ARGS=(--force --sign "${SIGN_ID:--}")
# real signature: hardened runtime and a timestamp (required for notarization)
[ -n "$SIGN_ID" ] && [ "$SIGN_ID" != "-" ] && [ -z "$SANDBOX" ] && SIGN_ARGS+=(--options runtime --timestamp)
if [ -n "$SANDBOX" ]; then
  ENT=.build/app.entitlements
  {
    echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
    echo '<plist version="1.0"><dict>'
    echo '  <key>com.apple.security.app-sandbox</key><true/>'
    echo '  <key>com.apple.security.device.serial</key><true/>'                    # /dev/cu.usbmodem…
    echo '  <key>com.apple.security.files.user-selected.read-write</key><true/>'   # CSV via the save dialog
    if [ -n "$TEAM_ID" ]; then
      echo "  <key>com.apple.application-identifier</key><string>$TEAM_ID.$BUNDLE_ID</string>"
      echo "  <key>com.apple.developer.team-identifier</key><string>$TEAM_ID</string>"
    fi
    echo '</dict></plist>'
  } > "$ENT"
  SIGN_ARGS+=(--entitlements "$ENT" --options runtime)
fi
[ -n "$PROFILE" ] && cp "$PROFILE" "$OUT/embedded.provisionprofile"
codesign "${SIGN_ARGS[@]}" "dist/$APP.app"

echo "✓ Done: dist/$APP.app ($VERSION, build $BUILD)"
if [ "$1" = "--install" ]; then
  rm -rf "/Applications/$APP.app"
  cp -R "dist/$APP.app" /Applications/
  echo "✓ Installed to /Applications"
fi
