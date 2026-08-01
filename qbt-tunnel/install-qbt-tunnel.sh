#!/bin/bash
# Install the dedicated qBittorrent Mullvad tunnel. Idempotent; run with sudo:
#   sudo qbt-tunnel/install-qbt-tunnel.sh
set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
LABEL="com.nicholassmith.qbt-wireguard"
LIBEXEC="/usr/local/libexec/qbt-tunnel"
DIR="/etc/wireguard-qbt"
JQ="/opt/homebrew/bin/jq"

[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }
[ -n "${SUDO_USER:-}" ] || { echo "run via sudo (need SUDO_USER)"; exit 1; }

# --- deps (brew refuses root, so only check here) --------------------------
for bin in wireguard-go wg jq; do
    [ -x "/opt/homebrew/bin/$bin" ] || {
        echo "missing /opt/homebrew/bin/$bin — first run: brew install wireguard-go wireguard-tools jq"
        exit 1
    }
done

# --- device + relay --------------------------------------------------------
/bin/mkdir -p "$DIR" && /bin/chmod 755 "$DIR"
[ -f "$DIR/qbt.conf" ] || "$SRC_DIR/register-device.sh"
/usr/bin/grep -q '^\[Peer\]' "$DIR/qbt.conf" || "$SRC_DIR/pin-qbt-relay.sh"

# --- daemon: root-owned COPY (root must never exec user-writable files) ----
/bin/mkdir -p "$LIBEXEC"
/usr/bin/install -o root -g wheel -m 755 "$SRC_DIR/qbt-wg-up.sh" "$LIBEXEC/qbt-wg-up.sh"
# Root-owned copy for the menu's relay switcher (sudoers targets this path).
/usr/bin/install -o root -g wheel -m 755 "$SRC_DIR/pin-qbt-relay.sh" "$LIBEXEC/pin-qbt-relay.sh"
/usr/bin/install -o root -g wheel -m 644 "$SRC_DIR/$LABEL.plist" "/Library/LaunchDaemons/$LABEL.plist"
/bin/launchctl bootout "system/$LABEL" 2>/dev/null || true
/bin/launchctl bootstrap system "/Library/LaunchDaemons/$LABEL.plist"

# --- sudoers (validate before install; a bad file locks sudo out) ----------
/usr/sbin/visudo -cf "$SRC_DIR/qbt-tunnel.sudoers"
/usr/bin/install -o root -g wheel -m 440 "$SRC_DIR/qbt-tunnel.sudoers" /etc/sudoers.d/qbt-tunnel

# --- qBittorrent double-keyed binding --------------------------------------
QBT_INI="/Users/$SUDO_USER/.config/qBittorrent/qBittorrent.ini"
ADDR="$("$JQ" -r .ipv4_address "$DIR/device.json")"
if [ ! -f "$QBT_INI" ]; then
    echo "! $QBT_INI not found — set Preferences > Advanced > Network interface manually"
elif /usr/bin/pgrep -x qbittorrent >/dev/null; then
    echo "! qBittorrent is running (it rewrites its config on quit) — quit it and re-run this installer"
else
    /usr/bin/awk -v addr="$ADDR" '
        /^Session\\Interface=/ { next }
        /^Session\\InterfaceName=/ { next }
        /^Session\\InterfaceAddress=/ { next }
        { print }
        /^\[BitTorrent\]$/ {
            print "Session\\Interface=utun100"
            print "Session\\InterfaceName=utun100"
            print "Session\\InterfaceAddress=" addr
        }' "$QBT_INI" > "$QBT_INI.tmp"
    /usr/sbin/chown "$SUDO_USER" "$QBT_INI.tmp"
    /bin/mv "$QBT_INI.tmp" "$QBT_INI"
    echo "qBittorrent bound to utun100 / $ADDR"
fi

# --- verify ----------------------------------------------------------------
sleep 3
if /sbin/ifconfig utun100 2>/dev/null | /usr/bin/grep -q "inet $ADDR "; then
    echo "utun100 up with $ADDR"
    /sbin/ping -q -c 1 -t 3 -b utun100 10.64.0.1 >/dev/null 2>&1 \
        && echo "in-tunnel gateway reachable — tunnel LIVE" \
        || echo "! gateway ping failed — check /var/log/qbt-wireguard.log"
else
    echo "! utun100 not up — check /var/log/qbt-wireguard.log"
fi
echo "Done. Rebuild the app (scripts/build-app.sh) to get the menu row."
