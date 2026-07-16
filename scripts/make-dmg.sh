#!/bin/zsh
# Builds Wattly.app (Release, ad-hoc signed per project.yml) — which embeds
# WattlyFanDaemon at Contents/Helpers via the project.yml copy-files
# dependency — and packages it into a distributable DMG under build/.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
scheme="Wattly"
config="Release"

xcodebuild -project "$root/Wattly.xcodeproj" -scheme "$scheme" -configuration "$config" \
  -destination 'platform=macOS' clean build

settings="$(xcodebuild -project "$root/Wattly.xcodeproj" -scheme "$scheme" -configuration "$config" \
  -showBuildSettings)"
build_dir="$(awk -F ' = ' '/ BUILT_PRODUCTS_DIR / {print $2; exit}' <<<"$settings")"
version="$(awk -F ' = ' '/ MARKETING_VERSION / {print $2; exit}' <<<"$settings")"

app_src="$build_dir/Wattly.app"
helper="$app_src/Contents/Helpers/WattlyFanDaemon"

[[ -d "$app_src" ]] || { print -u2 "Wattly.app not found at $app_src"; exit 1; }
[[ -x "$helper" ]] || { print -u2 "WattlyFanDaemon helper missing from $app_src/Contents/Helpers — embed phase did not run."; exit 1; }

dist="$root/build/dmg"
staging="$dist/staging"
out="$root/build/Wattly-$version.dmg"

rm -rf "$staging" "$out"
mkdir -p "$staging"

ditto "$app_src" "$staging/Wattly.app"
ln -s /Applications "$staging/Applications"

hdiutil create -volname "Wattly" -srcfolder "$staging" -ov -format UDZO "$out"

rm -rf "$dist"

print "Created $out"
