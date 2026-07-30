#!/bin/bash
# One-time: generate a WireGuard keypair locally and register it as a new
# device on the Mullvad account (uses 1 of 5 device slots). Never logs or
# stores the account number or auth token anywhere but this process.
# Requires root (writes /etc/wireguard-qbt). Idempotent: refuses to overwrite.
set -euo pipefail

DIR="/etc/wireguard-qbt"
CONF="$DIR/qbt.conf"
DEVJSON="$DIR/device.json"
WG="/opt/homebrew/bin/wg"
JQ="/opt/homebrew/bin/jq"
CURL="/usr/bin/curl"
MULLVAD="/usr/local/bin/mullvad"
API="https://api.mullvad.net"

[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }
[ -f "$CONF" ] && { echo "$CONF already exists; delete it to re-register"; exit 0; }

ACCOUNT="$("$MULLVAD" account get | /usr/bin/awk '/Mullvad account:/{print $3}')"
[ -n "$ACCOUNT" ] || { echo "could not read account number from mullvad CLI"; exit 1; }

PRIV="$("$WG" genkey)"
PUB="$(printf '%s' "$PRIV" | "$WG" pubkey)"

TOKEN="$("$CURL" -sf -X POST "$API/auth/v1/token" \
    -H 'Content-Type: application/json' \
    -d "{\"account_number\":\"$ACCOUNT\"}" | "$JQ" -r .access_token)" \
    || { echo "auth failed — verify the endpoint against Mullvad docs, or use the manual fallback in README"; exit 1; }
[ -n "$TOKEN" ] && [ "$TOKEN" != "null" ] || { echo "no access_token in auth response"; exit 1; }

RESP="$("$CURL" -sf -X POST "$API/accounts/v1/devices" \
    -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
    -d "{\"pubkey\":\"$PUB\",\"hijack_dns\":false}")" \
    || { echo "device creation failed (5-device limit reached? endpoint moved?)"; exit 1; }

ADDR="$(printf '%s' "$RESP" | "$JQ" -r '.ipv4_address' | /usr/bin/cut -d/ -f1)"
NAME="$(printf '%s' "$RESP" | "$JQ" -r '.name')"
[ -n "$ADDR" ] && [ "$ADDR" != "null" ] || { echo "no ipv4_address in response: $RESP"; exit 1; }

/bin/mkdir -p "$DIR"
/bin/chmod 755 "$DIR"
umask 077
# Pure wg(8) format — Address/MTU are wg-quick keys and would break wg setconf.
printf '[Interface]\nPrivateKey = %s\n' "$PRIV" > "$CONF"
"$JQ" -n --arg name "$NAME" --arg pubkey "$PUB" --arg addr "$ADDR" \
    '{name:$name, pubkey:$pubkey, ipv4_address:$addr}' > "$DEVJSON"
/bin/chmod 644 "$DEVJSON"

echo "Registered device \"$NAME\" pubkey=$PUB addr=$ADDR"
echo "Config: $CONF (no [Peer] yet — run pin-qbt-relay.sh next)"
