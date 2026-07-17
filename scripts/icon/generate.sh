#!/usr/bin/env bash
# Renders the Lasso app icon and builds AppIcon.icns. Run when the icon design
# changes; the resulting AppIcon.icns is committed so build-app.sh needs no
# rendering step. Requires macOS (AppKit + iconutil).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ICONSET="$HERE/Lasso.iconset"

rm -rf "$ICONSET"
swift "$HERE/AppIcon.swift" "$ICONSET"
iconutil -c icns "$ICONSET" -o "$HERE/AppIcon.icns"
rm -rf "$ICONSET"
echo "Built $HERE/AppIcon.icns"
