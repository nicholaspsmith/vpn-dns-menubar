#!/bin/bash
# Regenerate Resources/bundle/candidates.json — the No-ID candidate cities, each
# with a representative relay IP and a freshly measured direct (tunnel-down) seed
# latency, sorted fastest-first.
#
# City set mirrors the user's Mullvad "No-ID" custom lists (jurisdictions with no
# adult-content age-verification law), split US vs non-US, minus New Zealand
# (active Copyright Tribunal torrent regime). Edit the two CITIES lists below when
# the No-ID lists change.
set -euo pipefail
cd "$(dirname "$0")/.."
MULLVAD=/usr/local/bin/mullvad
OUT=Resources/bundle/candidates.json

US_CITIES="was uyk bos chi det sea"
NONUS_CITIES="ca:mtr ca:tor ca:van ca:yyc mx:qro co:bog pe:lim al:tia rs:beg cl:scl ua:iev il:tlv ar:bue th:bkk ph:mnl"

RELAYS="$("$MULLVAD" relay list)"

ip_for() {   # $1=cc $2=cityCode -> first relay IPv4 for that city
  printf "%s\n" "$RELAYS" | awk -v cc="$1" -v code="$2" '
    $0 ~ "\\(" cc "\\)$" { inc=1; next }
    /^[A-Za-z].*\([a-z][a-z]\)$/ { inc=0 }
    inc && /^\t[A-Z]/ { city = ($0 ~ "\\(" code "\\)") ? 1 : 0 }
    inc && city && /^\t\t/ {
      if (match($0, /\([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/)) {
        print substr($0, RSTART+1, RLENGTH-1); exit
      }
    }'
}
name_for() {  # $1=cc $2=cityCode -> "City, ST" / "City"
  printf "%s\n" "$RELAYS" | awk -v cc="$1" -v code="$2" '
    $0 ~ "\\(" cc "\\)$" { inc=1; next }
    /^[A-Za-z].*\([a-z][a-z]\)$/ { inc=0 }
    inc && /^\t[A-Z]/ && $0 ~ "\\(" code "\\)" {
      c=$0; sub(/^\t/,"",c); sub(/ \(.*/,"",c); print c; exit
    }'
}

WAS_CONNECTED=0
"$MULLVAD" status | grep -q "^Connected" && WAS_CONNECTED=1
echo "Disconnecting Mullvad for direct measurement..." >&2
"$MULLVAD" disconnect >/dev/null 2>&1 || true
sleep 2

measure() {  # $1=cc $2=cityCode -> "cc|code|name|ip|ms"
  local cc="$1" code="$2" ip name min
  ip="$(ip_for "$cc" "$code")"; name="$(name_for "$cc" "$code")"
  if [ -z "$ip" ]; then echo "WARN: no relay for $cc/$code" >&2; return; fi
  min="$(ping -c 10 -i 0.2 -t 8 "$ip" 2>/dev/null | awk -F'= ' '/round-trip/{print $2}' | cut -d/ -f1)"
  [ -z "$min" ] && min=9999
  printf '%s|%s|%s|%s|%.0f\n' "$cc" "$code" "$name" "$ip" "$min"
}

US_ROWS=""; for code in $US_CITIES;    do US_ROWS+="$(measure us "$code")"$'\n'; done
NON_ROWS=""; for p in $NONUS_CITIES;   do NON_ROWS+="$(measure "${p%%:*}" "${p##*:}")"$'\n'; done

if [ "$WAS_CONNECTED" = 1 ]; then "$MULLVAD" connect >/dev/null 2>&1 || true; fi

mkdir -p "$(dirname "$OUT")"
GEN="$(date +%F)" python3 - "$US_ROWS" "$NON_ROWS" > "$OUT" <<'PY'
import os, sys, json
def parse(block):
    rows=[]
    for line in block.strip().splitlines():
        if not line.strip(): continue
        cc, code, name, ip, ms = line.split("|")
        rows.append({"city": name, "cc": cc, "cityCode": code, "ip": ip, "seedMs": int(float(ms))})
    rows.sort(key=lambda r: r["seedMs"])
    return rows
doc = {"generated": os.environ["GEN"], "us": parse(sys.argv[1]), "nonus": parse(sys.argv[2])}
print(json.dumps(doc, indent=2, ensure_ascii=False))
PY
echo "Wrote $OUT" >&2
