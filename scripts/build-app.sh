#!/usr/bin/env bash
# Packages the lasso-conductor executable into a Lasso.app bundle so macOS
# recognizes it as a real app: a bare SwiftPM binary has no bundle identifier, so
# it never appears in the Screen Recording permission list and UNUserNotification
# banners (SPE-565) silently no-op. The bundle gives it a stable identity, a
# Developer ID signature, and an optional notarization + stapling pass (SPE-571).
#
# Usage:
#   scripts/build-app.sh [debug|release]        (default: release)
#
# Environment:
#   LASSO_SIGN_IDENTITY   override the auto-detected signing identity
#   LASSO_NOTARIZE=1      notarize + staple after signing (Developer ID only)
#   LASSO_NOTARY_PROFILE  notarytool keychain profile name (required to notarize)
#
# No App Sandbox and no special entitlements are needed: Screen Recording and
# Accessibility are TCC-gated (not entitlement-gated), and Chrome's native host
# reaches the Conductor through a user-only Unix-domain socket.
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE_ID="dev.lasso.conductor"
VERSION="$(tr -d '\r\n' < "$ROOT/VERSION")"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "error: VERSION must be a semantic version (for example 0.1.2)" >&2
    exit 1
fi

# Every public-facing component reports a version. Refuse to make an archive if
# someone updates only the app bundle and accidentally ships a mixed release.
MCP_VERSION="$(sed -nE 's/.*"version": "([0-9]+\.[0-9]+\.[0-9]+)".*/\1/p' \
    "$ROOT/Sources/LassoHub/MCPServer.swift" | head -1)"
EXTENSION_VERSION="$(plutil -extract version raw -o - -- "$ROOT/extension/manifest.json")"
if [ "$MCP_VERSION" != "$VERSION" ] || [ "$EXTENSION_VERSION" != "$VERSION" ]; then
    echo "error: VERSION ($VERSION), MCP ($MCP_VERSION), and extension ($EXTENSION_VERSION) must match" >&2
    exit 1
fi

swift build -c "$CONFIG" --product lasso-conductor
swift build -c "$CONFIG" --product lasso-relay-host
swift build -c "$CONFIG" --product lasso-mcp

APP="$ROOT/build/Lasso.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/lasso-conductor" "$APP/Contents/MacOS/Lasso"
cp "$BIN_DIR/lasso-relay-host" "$APP/Contents/MacOS/lasso-relay-host"
cp "$BIN_DIR/lasso-mcp" "$APP/Contents/MacOS/lasso-mcp"

# App icon (SPE-574). Prebuilt and committed; regenerate with scripts/icon/generate.sh.
if [ -f "$ROOT/scripts/icon/AppIcon.icns" ]; then
    cp "$ROOT/scripts/icon/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

# The optional Chrome extension is loaded unpacked from the application bundle.
# Strip Finder metadata while copying so it can never invalidate the app seal.
ditto --norsrc --noextattr "$ROOT/extension" "$APP/Contents/Resources/extension"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Lasso</string>
    <key>CFBundleDisplayName</key>
    <string>Lasso</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key>
    <string>Lasso</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Lasso: local spatial context for coding agents.</string>
</dict>
</plist>
PLIST

# TCC (Screen Recording) keys off the code signature. An ad-hoc signature's hash
# changes on every rebuild, so macOS treats each build as a new app and the grant
# is lost. Signing with a stable identity (Developer ID, else Apple Development)
# anchors the designated requirement on the team + bundle id, so the permission
# survives rebuilds. Fall back to ad-hoc only if no identity exists.
if [ -n "${LASSO_SIGN_IDENTITY:-}" ]; then
    IDENTITY="$LASSO_SIGN_IDENTITY"
else
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | grep -Eo 'Developer ID Application: [^"]+' | head -1 || true)"
    if [ -z "$IDENTITY" ]; then
        IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
            | grep -Eo 'Apple Development: [^"]+' | head -1 || true)"
    fi
fi
if [ -z "$IDENTITY" ]; then
    IDENTITY="-"
    echo "warning: no signing identity found, using ad-hoc (TCC grant will not persist across rebuilds)"
fi

HOST_BINARY="$APP/Contents/MacOS/lasso-relay-host"
codesign --force --options runtime \
    --identifier "xyz.allez.lasso.host" \
    --sign "$IDENTITY" "$HOST_BINARY"

codesign --force --deep --options runtime \
    --identifier "$BUNDLE_ID" \
    --sign "$IDENTITY" "$APP"

# Verify the signature is well-formed regardless of identity.
codesign --verify --strict --verbose=2 "$APP"

# Chrome derives an unpacked extension's stable id from the manifest's SPKI key.
# Hash the DER key, map the first 16 bytes' hex nibbles a-p, and allow only that
# origin to launch this native host.
EXTENSION_KEY="$(plutil -extract key raw -o - -- "$ROOT/extension/manifest.json")"
EXTENSION_ID="$(printf '%s' "$EXTENSION_KEY" \
    | openssl base64 -d -A \
    | openssl dgst -sha256 -binary \
    | head -c 16 \
    | xxd -p -c 32 \
    | tr '0123456789abcdef' 'abcdefghijklmnop')"
RUNTIME_EXTENSION_ID="$(sed -nE 's/.*extensionID = "([a-p]+)".*/\1/p' \
    "$ROOT/Sources/LassoConductorCore/NativeMessagingHostManifest.swift" | head -1)"
if [ "$EXTENSION_ID" != "$RUNTIME_EXTENSION_ID" ]; then
    echo "error: extension key id ($EXTENSION_ID) does not match runtime host id ($RUNTIME_EXTENSION_ID)" >&2
    exit 1
fi
HOST_MANIFEST_DIR="$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts"
HOST_MANIFEST="$HOST_MANIFEST_DIR/xyz.allez.lasso.host.json"
mkdir -p "$HOST_MANIFEST_DIR"
cat > "$HOST_MANIFEST" <<JSON
{
  "name": "xyz.allez.lasso.host",
  "description": "Lasso extension relay",
  "path": "$HOST_BINARY",
  "type": "stdio",
  "allowed_origins": ["chrome-extension://$EXTENSION_ID/"]
}
JSON
echo "Chrome extension id: $EXTENSION_ID"
echo "Installed native-messaging manifest: $HOST_MANIFEST"

IS_DEVELOPER_ID=false
case "$IDENTITY" in
    "Developer ID Application:"*) IS_DEVELOPER_ID=true ;;
esac

# Gatekeeper assessment is only meaningful for a Developer ID signature; ad-hoc /
# Apple Development builds are rejected by spctl until notarized, which is
# expected for a dev build.
if [ "$IS_DEVELOPER_ID" = true ]; then
    echo "Gatekeeper assessment:"
    spctl --assess --type exec --verbose=4 "$APP" 2>&1 || \
        echo "  (not yet accepted; notarize and staple for distribution)"
fi

echo "Built $APP  (signed by: $IDENTITY)"
echo "Run it with:  open \"$APP\""

# Produce a clean archive and validate the *extracted* app. Finder metadata
# (`._*` AppleDouble files) inside an app bundle changes sealed resources, so an
# archive is not shippable until this exact check succeeds.
package_release() {
    RELEASE_ZIP="$ROOT/build/Lasso-${VERSION}-macos.zip"
    rm -f "$RELEASE_ZIP"
    ditto -c -k --keepParent --norsrc --noextattr "$APP" "$RELEASE_ZIP"

    VERIFY_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lasso-release.XXXXXX")"
    ditto -x -k "$RELEASE_ZIP" "$VERIFY_DIR"
    codesign --verify --deep --strict --verbose=2 "$VERIFY_DIR/Lasso.app"
    if [ "${LASSO_NOTARIZE:-0}" = "1" ]; then
        spctl --assess --type exec --verbose=4 "$VERIFY_DIR/Lasso.app"
        xcrun stapler validate "$VERIFY_DIR/Lasso.app"
    fi
    rm -rf "$VERIFY_DIR"
    echo "Release archive: $RELEASE_ZIP"
}

# --- Optional notarization ---------------------------------------------------
# Notarization requires a Developer ID signature and stored notarytool
# credentials. Create the profile once with:
#   xcrun notarytool store-credentials <profile> --apple-id <id> \
#       --team-id <team> --password <app-specific-password>
if [ "${LASSO_NOTARIZE:-0}" != "1" ]; then
    package_release
    exit 0
fi
if [ "$IS_DEVELOPER_ID" != true ]; then
    echo "error: LASSO_NOTARIZE=1 requires a Developer ID signature (got: $IDENTITY)" >&2
    exit 1
fi
if [ -z "${LASSO_NOTARY_PROFILE:-}" ]; then
    echo "error: LASSO_NOTARIZE=1 requires LASSO_NOTARY_PROFILE (a notarytool keychain profile)" >&2
    exit 1
fi

ZIP="$ROOT/build/Lasso-notary.zip"
rm -f "$ZIP"
# notarytool takes a zip/pkg/dmg. Omit Finder metadata for the same reason as
# the final release archive.
ditto -c -k --keepParent --norsrc --noextattr "$APP" "$ZIP"

echo "Submitting to Apple notary service (profile: $LASSO_NOTARY_PROFILE)…"
xcrun notarytool submit "$ZIP" --keychain-profile "$LASSO_NOTARY_PROFILE" --wait

# Staple the ticket onto the .app so it validates offline.
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
rm -f "$ZIP"

echo "Notarized and stapled $APP"
package_release
