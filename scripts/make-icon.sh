#!/usr/bin/env bash
# Regenerate the Wattly app icon from the CoreGraphics master generator.
# Draws the brand LightningGlyph (white) on the dark-mode panel background
# (#212225) at 1024×1024, then slices the 10 macOS iconset sizes into the
# asset catalog. Tweak colour/scale in make-icon.swift, then re-run this.
#
#   ./scripts/make-icon.sh
#
set -euo pipefail
cd "$(dirname "$0")/.."

ICONSET="Wattly/Assets.xcassets/AppIcon.appiconset"
MASTER="$(mktemp -t wattly_icon_master).png"

swift scripts/make-icon.swift "$MASTER"

# slot name : pixel size
slots=( "AppIcon-16:16" "AppIcon-16@2x:32" "AppIcon-32:32" "AppIcon-32@2x:64" \
        "AppIcon-128:128" "AppIcon-128@2x:256" "AppIcon-256:256" "AppIcon-256@2x:512" \
        "AppIcon-512:512" "AppIcon-512@2x:1024" )
for s in "${slots[@]}"; do
  name="${s%%:*}"; px="${s##*:}"
  sips -z "$px" "$px" "$MASTER" --out "$ICONSET/${name}.png" >/dev/null
done

rm -f "$MASTER"
echo "Regenerated 10 PNGs in $ICONSET (Contents.json already references them)."
