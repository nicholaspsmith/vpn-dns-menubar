#!/usr/bin/env bash
# Install vpn-dns-menubar:
#   1) symlink the SwiftBar plugin into SwiftBar's plugin dir
#   2) load the launchd DNS-sync agent (toggles Tailscale accept-dns with Mullvad)
#
# The repo is the source of truth: the plugin self-locates its ./assets via its
# real path, and the launchd agent runs the script straight out of the repo.
# Re-running is safe (idempotent).
set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="${SWIFTBAR_PLUGIN_DIR:-$HOME/.config/SwiftBar}"

# --- SwiftBar plugin -------------------------------------------------------
chmod +x "$SRC_DIR/vpn-dns-control.5s.sh" "$SRC_DIR/assets/open-native-menu.sh"
mkdir -p "$PLUGIN_DIR"
ln -sf "$SRC_DIR/vpn-dns-control.5s.sh" "$PLUGIN_DIR/vpn-dns-control.5s.sh"
echo "Linked plugin -> $PLUGIN_DIR/vpn-dns-control.5s.sh"
echo "  (keep assets OUT of $PLUGIN_DIR -- SwiftBar loads every file there as its own icon)"

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
echo "Loaded launchd agent $LABEL (Tailscale accept-dns follows Mullvad state)."

# --- refresh ---------------------------------------------------------------
/usr/bin/open "swiftbar://refreshallplugins" 2>/dev/null || true
echo
echo "Done. Hide the native Mullvad/Tailscale icons (e.g. with Ice) so this is the"
echo "only one visible. SwiftBar needs Accessibility + Automation permission for the"
echo "Mullvad row's native popover. See README.md for details and uninstall steps."
