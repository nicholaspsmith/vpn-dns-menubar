#!/usr/bin/env bash
# Install vpn-dns-menubar:
#   1) build the standalone "VPN & DNS.app" and symlink it into ~/Applications
#   2) load the launchd DNS-sync agent (toggles Tailscale accept-dns with Mullvad
#      and enforces Mullvad/qbt-tunnel mutual exclusivity when that's installed)
# Optional: `./install.sh --swiftbar` also wires the retired SwiftBar plugin
# fallback (see README).
#
# The repo is the source of truth: the app symlink points at build/, and the
# launchd agent runs the watcher script straight out of the repo.
# Re-running is safe (idempotent).
set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- standalone app --------------------------------------------------------
"$SRC_DIR/scripts/build-app.sh"
mkdir -p "$HOME/Applications"
ln -sfn "$SRC_DIR/build/VPN & DNS.app" "$HOME/Applications/VPN & DNS.app"
echo "Linked app -> ~/Applications/VPN & DNS.app (SMAppService requires it there)"
/usr/bin/open "$HOME/Applications/VPN & DNS.app"

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
echo "Loaded launchd agent $LABEL (accept-dns + qbt-tunnel exclusivity follow Mullvad state)."

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

echo
echo "Optional: dedicated always-on Mullvad tunnel for qBittorrent:"
echo "  brew install wireguard-go wireguard-tools jq   # once"
echo "  sudo $SRC_DIR/qbt-tunnel/install-qbt-tunnel.sh"
