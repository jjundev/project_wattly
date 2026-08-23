#!/bin/zsh
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
label="dev.jjundev.WattlyFanDaemon"
helper="/Library/PrivilegedHelperTools/$label"
plist="/Library/LaunchDaemons/$label.plist"
plist_template="$root/Resources/com.dev.jjundev.WattlyFanDaemon.plist"
uid="$(id -u)"

transfer_ownership=false
if [[ "$#" -gt 1 ]] || { [[ "$#" -eq 1 ]] && [[ "$1" != "--transfer-ownership" ]]; }; then
  print -u2 "Usage: $0 [--transfer-ownership]"
  exit 64
fi
[[ "$#" -eq 1 ]] && transfer_ownership=true

[[ "$uid" -gt 0 ]] || {
  print -u2 "Run as the login user, not root."
  exit 64
}

if [[ -e "$plist" ]]; then
  installed_uid=$(/usr/libexec/PlistBuddy -c 'Print :EnvironmentVariables:WATTLY_ALLOWED_UID' "$plist" 2>/dev/null) || installed_uid=""
  if [[ "$installed_uid" != <-> ]] || [[ "$installed_uid" -le 0 ]]; then
    $transfer_ownership || {
      print -u2 "Installed helper owner metadata is invalid; rerun with --transfer-ownership."
      exit 65
    }
  elif [[ "$installed_uid" -ne "$uid" ]]; then
    $transfer_ownership || {
      print -u2 "Helper is owned by UID $installed_uid; rerun with --transfer-ownership."
      exit 65
    }
  fi
fi

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

# The login-user preflight above is advisory only. Keep the authoritative ownership check and every
# replacement step in one elevated shell so a plist changed while sudo authentication was pending
# cannot be replaced unless this invocation explicitly authorized ownership transfer.
sudo /bin/sh -s -- "$uid" "$transfer_ownership" "$plist" "$helper" "$dir/WattlyFanDaemon" "$tmp" "$label" <<'ROOT_TRANSACTION'
set -eu
expected_owner_uid="$1"
allow_ownership_transfer="$2"
installed_plist="$3"
helper_path="$4"
daemon_path="$5"
replacement_plist="$6"
daemon_label="$7"
ownership_lock='/var/run/Wattly/wattly-helper-install.lock'
install -d -o root -g wheel -m 755 /var/run/Wattly
if ! /usr/bin/shlock -f "$ownership_lock" -p "$$"; then
  echo 'Ownership replacement is already in progress.' >&2
  exit 75
fi
chmod 644 "$ownership_lock"
cleanup_ownership_lock() { rm -f "$ownership_lock"; }
trap cleanup_ownership_lock EXIT
trap 'exit 75' HUP INT TERM

validate_installed_owner() {
  if [ -e "$installed_plist" ]; then
    installed_uid=$(/usr/libexec/PlistBuddy -c 'Print :EnvironmentVariables:WATTLY_ALLOWED_UID' "$installed_plist" 2>/dev/null) || installed_uid=""
    case "$installed_uid" in
      ''|*[!0-9]*) ownership_changed=true ;;
      *)
        if [ "$installed_uid" -le 0 ] || [ "$installed_uid" -ne "$expected_owner_uid" ]; then
          ownership_changed=true
        else
          ownership_changed=false
        fi
        ;;
    esac
    if [ "$ownership_changed" = true ] && [ "$allow_ownership_transfer" != true ]; then
      echo 'Helper ownership changed; rerun with --transfer-ownership.' >&2
      exit 65
    fi
  fi
}

validate_installed_owner
"$daemon_path" --verify-battery-release
validate_installed_owner
was_running=false
if launchctl print "system/$daemon_label" >/dev/null 2>&1; then
  was_running=true
  launchctl bootout "system/$daemon_label"
fi
if ! "$daemon_path" --verify-battery-release; then
  $was_running && launchctl bootstrap system "$installed_plist"
  exit 74
fi
install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools /Library/LaunchDaemons
install -o root -g wheel -m 755 "$daemon_path" "$helper_path"
install -o root -g wheel -m 644 "$replacement_plist" "$installed_plist"
launchctl bootstrap system "$installed_plist"
launchctl kickstart -k "system/$daemon_label"
launchctl print "system/$daemon_label" >/dev/null
ROOT_TRANSACTION
