#!/bin/zsh
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
label="dev.jjundev.WattlyFanDaemon"
helper="/Library/PrivilegedHelperTools/$label"
plist="/Library/LaunchDaemons/$label.plist"
plist_template="$root/Resources/com.dev.jjundev.WattlyFanDaemon.plist"
uid="$(id -u)"

[[ "$uid" -gt 0 ]] || {
  print -u2 "Run as the login user, not root."
  exit 64
}

if pgrep -x "Macs Fan Control" >/dev/null || \
  launchctl print system/com.crystalidea.macsfancontrol.smcwrite >/dev/null 2>&1; then
  print -u2 "Quit and uninstall Macs Fan Control before installing Wattly fan control."
  exit 1
fi

xcodebuild -project "$root/Wattly.xcodeproj" -scheme Wattly -configuration Debug build
dir="$(xcodebuild -project "$root/Wattly.xcodeproj" -scheme Wattly -configuration Debug \
  -showBuildSettings | awk -F ' = ' '/TARGET_BUILD_DIR/ {print $2; exit}')"
[[ -x "$dir/WattlyFanDaemon" ]] || {
  print -u2 "Daemon product missing."
  exit 1
}

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
sed "s/__WATTLY_ALLOWED_UID__/$uid/g" "$plist_template" > "$tmp"

sudo launchctl bootout "system/$label" 2>/dev/null || true
sudo install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools /Library/LaunchDaemons
sudo install -o root -g wheel -m 755 "$dir/WattlyFanDaemon" "$helper"
sudo install -o root -g wheel -m 644 "$tmp" "$plist"
sudo launchctl bootstrap system "$plist"
sudo launchctl kickstart -k "system/$label"
sudo launchctl print "system/$label" >/dev/null
