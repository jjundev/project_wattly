#!/bin/zsh
set -euo pipefail

label="dev.jjundev.WattlyFanDaemon"

sudo launchctl bootout "system/$label" 2>/dev/null || true
sudo rm -f "/Library/LaunchDaemons/$label.plist" "/Library/PrivilegedHelperTools/$label"
