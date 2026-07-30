#!/bin/bash
# Dedicated always-on Mullvad WireGuard tunnel for qBittorrent.
# Run as root by the com.nicholassmith.qbt-wireguard LaunchDaemon (KeepAlive).
# Fail-closed by design: any error exits non-zero -> no utun100 -> qBittorrent
# has nothing to bind and torrents stall rather than leak.
set -euo pipefail

IFACE="utun100"
CONF="/etc/wireguard-qbt/qbt.conf"
DEVJSON="/etc/wireguard-qbt/device.json"
GATEWAY="10.64.0.1"
MTU=1160
WG_GO="/opt/homebrew/bin/wireguard-go"
WG="/opt/homebrew/bin/wg"
JQ="/opt/homebrew/bin/jq"

[ -f "$CONF" ] || { echo "missing $CONF (run install-qbt-tunnel.sh)"; exit 1; }
grep -q '^\[Peer\]' "$CONF" || { echo "no [Peer] in $CONF (run pin-qbt-relay.sh)"; exit 1; }
ADDR="$("$JQ" -r .ipv4_address "$DEVJSON")"
[ -n "$ADDR" ] && [ "$ADDR" != "null" ] || { echo "no ipv4_address in $DEVJSON"; exit 1; }

# A leftover utun100 means a previous wireguard-go didn't die cleanly (interface
# vanishes with its process) — or something foreign claimed the name. Try to
# clear our own stale instance once, then refuse (fail closed, never hijack).
if /sbin/ifconfig "$IFACE" >/dev/null 2>&1; then
    /usr/bin/pkill -f "wireguard-go.*$IFACE" 2>/dev/null || true
    sleep 1
    if /sbin/ifconfig "$IFACE" >/dev/null 2>&1; then
        echo "$IFACE exists and is not ours; refusing to hijack"
        exit 1
    fi
fi

# Foreground (-f) so this script stays alive holding the tunnel; launchd's
# KeepAlive restarts us when wireguard-go exits for any reason.
"$WG_GO" -f "$IFACE" &
WGPID=$!
trap '/bin/kill "$WGPID" 2>/dev/null || true' EXIT

for _ in $(seq 1 50); do
    /sbin/ifconfig "$IFACE" >/dev/null 2>&1 && break
    /bin/kill -0 "$WGPID" 2>/dev/null || { echo "wireguard-go died during startup"; exit 1; }
    sleep 0.1
done

"$WG" setconf "$IFACE" "$CONF"
/sbin/ifconfig "$IFACE" inet "$ADDR/32" "$GATEWAY" mtu "$MTU" up
# Scoped-only default route: invisible to normal lookups; used solely by
# sockets explicitly bound to utun100 (qBittorrent). System table untouched.
/sbin/route -q -n add -inet -ifscope "$IFACE" default -interface "$IFACE" || true

echo "$(date '+%F %T') $IFACE up addr=$ADDR peer=$("$WG" show "$IFACE" endpoints | /usr/bin/head -1)"
wait "$WGPID"
