#!/bin/zsh
set -euo pipefail

label="dev.jjundev.WattlyFanDaemon"
project_root="${0:A:h}/.."
build_settings="$(xcodebuild -project "$project_root/Wattly.xcodeproj" -scheme WattlyFanDaemon -configuration Debug -showBuildSettings)"
target_build_dir="$(print -r -- "$build_settings" | awk -F ' = ' '/^[[:space:]]*TARGET_BUILD_DIR = / { print $2; exit }')"
executable_path="$(print -r -- "$build_settings" | awk -F ' = ' '/^[[:space:]]*EXECUTABLE_PATH = / { print $2; exit }')"
verifier="$target_build_dir/$executable_path"

if [[ ! -x "$verifier" ]]; then
  print -u2 "Current Debug WattlyFanDaemon verifier is missing: $verifier"
  exit 1
fi

sudo "$verifier" --verify-battery-release
was_running=false
if sudo launchctl print "system/$label" >/dev/null 2>&1; then
  was_running=true
  sudo launchctl bootout "system/$label"
fi
if ! sudo "$verifier" --verify-battery-release; then
  if $was_running; then
    sudo launchctl bootstrap system "/Library/LaunchDaemons/$label.plist"
  fi
  exit 74
fi
sudo rm -f "/Library/PrivilegedHelperTools/$label" \
  "/Library/LaunchDaemons/$label.plist" \
  "/Library/Application Support/Wattly/battery-control-v1.json"
sudo rmdir "/Library/Application Support/Wattly" 2>/dev/null || true
