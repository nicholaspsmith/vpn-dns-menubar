#!/bin/bash
# Pin / switch the qbt tunnel's Mullvad exit relay (approved non-US,
# torrent-lenient jurisdictions only).
#   (no args)         probe all candidate cities, pin the fastest (root)
#   --city <cc-city>  pin that city's first active relay, no probe (root)
#   --list            print candidates as TSV "code<TAB>City, Country<TAB>hostname<TAB>ip" (no root)
set -euo pipefail

CONF="/etc/wireguard-qbt/qbt.conf"
JQ="/opt/homebrew/bin/jq"
CURL="/usr/bin/curl"
MULLVAD="/usr/local/bin/mullvad"
# Spec-approved jurisdictions (Canada explicitly in).
ALLOWED='["al","ar","br","ca","ch","cl","co","es","md","mx","nl","pe","ph","ro","rs","th","ua"]'

MODE="probe"; CITY=""
case "${1:-}" in
    --list) MODE="list" ;;
    --city) MODE="city"; CITY="${2:?usage: pin-qbt-relay.sh --city <cc-city>}" ;;
    "") ;;
    *) echo "usage: pin-qbt-relay.sh [--list | --city <cc-city>]"; exit 2 ;;
esac

# One candidate per city, TSV: code display hostname ip pubkey
CANDIDATES="$("$CURL" -sf --max-time 15 https://api.mullvad.net/app/v1/relays | "$JQ" -r --argjson allowed "$ALLOWED" '
    .locations as $locs
    | [.wireguard.relays[]
       | select(.active)
       | select((.location | split("-")[0]) as $cc | $allowed | index($cc))]
    | group_by(.location)
    | map(.[0])
    | .[] | [.location, ($locs[.location].city + ", " + $locs[.location].country),
             .hostname, .ipv4_addr_in, .public_key] | @tsv')"
[ -n "$CANDIDATES" ] || { echo "no candidates from relay API"; exit 1; }

if [ "$MODE" = "list" ]; then
    printf '%s\n' "$CANDIDATES" | /usr/bin/cut -f1-4
    exit 0
fi

[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }
[ -f "$CONF" ] || { echo "missing $CONF (run register-device.sh first)"; exit 1; }

if [ "$MODE" = "city" ]; then
    LINE="$(printf '%s\n' "$CANDIDATES" | /usr/bin/awk -F'\t' -v c="$CITY" '$1==c {print; exit}')"
    [ -n "$LINE" ] || { echo "city $CITY not in candidate list"; exit 1; }
    HOST="$(printf '%s\n' "$LINE" | /usr/bin/cut -f3)"
    IP="$(printf '%s\n' "$LINE" | /usr/bin/cut -f4)"
    KEY="$(printf '%s\n' "$LINE" | /usr/bin/cut -f5)"
    echo "pinning $HOST ($IP) — selected city $CITY, no probe"
else
    if "$MULLVAD" status 2>/dev/null | /usr/bin/head -1 | /usr/bin/grep -q Connected; then
        echo "note: system Mullvad is connected — probes run through it; relative order is still usable"
    fi
    BEST_MS=999999; BEST_LINE=""
    while IFS=$'\t' read -r code display host ip key; do
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
fi

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
