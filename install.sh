#!/usr/bin/env bash
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# Copyright (c) 2026 Nicholas Smith

# Install vpn-dns-menubar:
#   1) build the standalone "VPN & DNS.app" and symlink it into ~/Applications
#   2) load the launchd DNS-sync agent (toggles Tailscale accept-dns with Mullvad)
# Optional: `./install.sh --swiftbar` also wires the retired SwiftBar plugin
# fallback (see README).
#
# The repo is the source of truth: the app symlink points at build/, and the
# launchd agent runs the watcher script straight out of the repo.
# Re-running is safe (idempotent).
set -euo pipefail

# Menubarn release rule — every push is a release. Arm the pre-push hook in
# every Menubarn repo cloned beside this one (local git config, so a fresh
# clone has none until this runs). StatusItemKit README, "Releases".
RELEASE_KIT="$(cd "$(dirname "$0")/.." && pwd)/StatusItemKit/scripts/release/adopt.sh"
if [ -x "$RELEASE_KIT" ]; then
    "$RELEASE_KIT" --hooks-only || echo "Release hook: adopt.sh failed" >&2
else
    echo "Release hook: StatusItemKit not found beside this repo — clone it and re-run" >&2
fi

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- standalone app --------------------------------------------------------
"$SRC_DIR/scripts/build-app.sh"
mkdir -p "$HOME/Applications"
ln -sfn "$SRC_DIR/build/VPN & DNS.app" "$HOME/Applications/VPN & DNS.app"
echo "Linked app -> ~/Applications/VPN & DNS.app (SMAppService requires it there)"

# Ask to turn on Start at Login. SMAppService can only register the calling
# process's own bundle, so this runs the installed binary's headless --login.
APP="$HOME/Applications/VPN & DNS.app"
BIN="$APP/Contents/MacOS/VPNDNSMenuBar"
PROC="${APP##*/}/Contents/MacOS/VPNDNSMenuBar"   # matches the symlink-resolved path too
if [ "$("$BIN" --login status 2>/dev/null)" = "on" ]; then
    echo "Start at Login: already on"
elif [ -t 0 ]; then
    read -r -p "Start VPN & DNS at login? [Y/n] " answer
    case "$answer" in
        [nN]*) echo "Start at Login: left off (turn it on from the menu)" ;;
        *) if "$BIN" --login on >/dev/null; then
               echo "Start at Login: on"
           else
               echo "Start at Login: could not register (turn it on from the menu)" >&2
           fi ;;
    esac
else
    echo "Start at Login: off (not asked: no terminal). Turn it on from the menu, or run"
    echo "    \"$BIN\" --login on"
fi

# `open` on a running app only activates it, so quit the old build first or the
# new one never launches. Wait for it to go so both don't briefly sit in the bar.
if pgrep -f "$PROC" >/dev/null; then
    osascript -e "tell application id \"$(defaults read "$APP/Contents/Info" CFBundleIdentifier)\" to quit" >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -f "$PROC" >/dev/null || break; sleep 0.5; done
    pkill -f "$PROC" 2>/dev/null || true
    sleep 1
fi
/usr/bin/open "$APP"

# --- launchd DNS-sync agent ------------------------------------------------
LABEL="com.nicholassmith.mullvad-tailscale-dns"
WATCH="$SRC_DIR/dns-watcher/mullvad-tailscale-dns-sync.sh"
LA="$HOME/Library/LaunchAgents"
PLIST="$LA/$LABEL.plist"
chmod +x "$WATCH"
mkdir -p "$LA"
sed -e "s|__SCRIPT__|$WATCH|g" "$SRC_DIR/dns-watcher/$LABEL.plist" > "$PLIST"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null || launchctl load -w "$PLIST"
echo "Loaded launchd agent $LABEL (accept-dns follows Mullvad state)."

# --- SwiftBar plugin (retired fallback; opt-in) ----------------------------
if [[ "${1:-}" == "--swiftbar" ]]; then
    PLUGIN_DIR="${SWIFTBAR_PLUGIN_DIR:-$HOME/.config/SwiftBar}"
    chmod +x "$SRC_DIR/vpn-dns-control.5s.sh" "$SRC_DIR/assets/open-native-menu.sh"
    mkdir -p "$PLUGIN_DIR"
    ln -sf "$SRC_DIR/vpn-dns-control.5s.sh" "$PLUGIN_DIR/vpn-dns-control.5s.sh"
    echo "Linked plugin -> $PLUGIN_DIR/vpn-dns-control.5s.sh"
    echo "  (keep assets OUT of $PLUGIN_DIR -- SwiftBar loads every file there as its own icon)"
    /usr/bin/open "swiftbar://refreshallplugins" 2>/dev/null || true
fi

echo
echo "Done. Use the menu's 'Start at Login' toggle, and hide the native"
echo "Mullvad/Tailscale icons (e.g. with Ice) so this is the only one visible."
echo "See README.md for details and uninstall steps."
