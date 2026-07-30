#!/bin/bash
# Pick the lowest-latency Mullvad WireGuard relay in the approved (non-US,
# torrent-lenient) jurisdictions and pin it as the qbt tunnel's [Peer].
# Re-run whenever the pinned relay dies. Requires root.
set -euo pipefail

CONF="/etc/wireguard-qbt/qbt.conf"
WG="/opt/homebrew/bin/wg"
JQ="/opt/homebrew/bin/jq"
CURL="/usr/bin/curl"
MULLVAD="/usr/local/bin/mullvad"
# Spec-approved jurisdictions (Canada explicitly in).
ALLOWED='["al","ar","br","ca","ch","cl","co","es","md","mx","nl","pe","ph","ro","rs","th","ua"]'

[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }
[ -f "$CONF" ] || { echo "missing $CONF (run register-device.sh first)"; exit 1; }

if "$MULLVAD" status 2>/dev/null | /usr/bin/head -1 | /usr/bin/grep -q Connected; then
    echo "note: system Mullvad is connected — probes run through it; relative order is still usable"
fi

# One candidate per city (first active relay), TSV: hostname ip pubkey
CANDIDATES="$("$CURL" -sf --max-time 15 https://api.mullvad.net/app/v1/relays | "$JQ" -r --argjson allowed "$ALLOWED" '
    [.wireguard.relays[]
     | select(.active)
     | select((.hostname | split("-")[0]) as $cc | $allowed | index($cc))]
    | group_by(.hostname | split("-")[0:2] | join("-"))
    | map(.[0])
    | .[] | [.hostname, .ipv4_addr_in, .public_key] | @tsv')"
[ -n "$CANDIDATES" ] || { echo "no candidates from relay API"; exit 1; }

BEST_MS=999999; BEST_LINE=""
while IFS=$'\t' read -r host ip key; do
    ms="$(/sbin/ping -q -c 3 -i 0.3 -t 4 "$ip" 2>/dev/null \
        | /usr/bin/awk -F' = ' '/round-trip/ {split($2,a,"/"); print a[1]}')"
    [ -n "$ms" ] || { echo "  $host unreachable"; continue; }
    echo "  $host ${ms}ms"
    if [ "$(echo "$ms < $BEST_MS" | /usr/bin/bc)" -eq 1 ]; then
        BEST_MS="$ms"; BEST_LINE="$host	$ip	$key"
    fi
done <<< "$CANDIDATES"
[ -n "$BEST_LINE" ] || { echo "no relay reachable"; exit 1; }

IFS=$'\t' read -r HOST IP KEY <<< "$BEST_LINE"
echo "pinning $HOST ($IP) ${BEST_MS}ms"

PRIV_LINE="$(/usr/bin/grep '^PrivateKey' "$CONF")"
umask 077
{
    printf '[Interface]\n%s\n\n' "$PRIV_LINE"
    printf '# pinned: %s\n[Peer]\nPublicKey = %s\nAllowedIPs = 0.0.0.0/0\nEndpoint = %s:51820\nPersistentKeepalive = 25\n' \
        "$HOST" "$KEY" "$IP"
} > "$CONF.tmp"
/bin/mv "$CONF.tmp" "$CONF"

/bin/launchctl kickstart -k system/com.nicholassmith.qbt-wireguard 2>/dev/null \
    || echo "daemon not loaded yet (fine during first install)"
echo "pinned $HOST"
