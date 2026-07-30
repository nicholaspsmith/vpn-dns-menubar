# qBittorrent Dedicated Mullvad Tunnel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An always-on, boot-started Mullvad WireGuard tunnel on pinned `utun100` that only qBittorrent uses (scoped routing, fail-closed), plus a status + restart row in VPN & DNS.app.

**Architecture:** A LaunchDaemon supervises `wireguard-go` on `utun100` with an interface-scoped default route so the system routing table is untouched. qBittorrent is double-key bound (interface name + in-tunnel address). One-time device registration via Mullvad's app API; relay pinned by latency probe over approved jurisdictions. The menu app polls tunnel/binding state off-main, per its existing pattern.

**Tech Stack:** bash (daemon + installer scripts), launchd, wireguard-go + wireguard-tools (brew), jq, Swift 5.9 SPM (VPNDNSCore/VPNDNSMenuBar, StatusItemKit), XCTest.

**Spec:** `docs/superpowers/specs/2026-07-30-qbt-dedicated-tunnel-design.md`

## Global Constraints

- Branch: `feature/qbt-dedicated-tunnel`. Repo is PUBLIC: no account numbers, keys, tokens, or generated configs may be committed. Secrets live in `/etc/wireguard-qbt/` (dir `755` root; `qbt.conf` `600` root; `device.json` `644` — non-secret metadata).
- Interface name `utun100`; in-tunnel gateway `10.64.0.1`; MTU `1160`; IPv4-only; `PersistentKeepalive = 25`.
- LaunchDaemon label `com.nicholassmith.qbt-wireguard`. Root-executed scripts are COPIED to `/usr/local/libexec/qbt-tunnel/` (root-owned) — a root daemon must never execute user-writable files, so "repo as source of truth" is deliberately broken here; the installer re-copies on every run.
- All scripts: `#!/bin/bash`, `set -euo pipefail`, absolute paths for every binary (`/opt/homebrew/bin/wg`, `/sbin/ifconfig`, `/usr/local/bin/mullvad`, …).
- `qbt.conf` is pure `wg(8)` format for `wg setconf`: `Address`/`MTU`/`DNS` keys are wg-quick extensions and MUST NOT appear in it (setconf rejects them). The address lives in `device.json` and is applied via `ifconfig`.
- Swift: shell-outs only via StatusItemKit `Shell.run(path, args, timeout:)`, only on background queues; state committed on main (repo pattern from the 2026-07-07 click-freeze fix). Pure logic in `VPNDNSCore` with tests; `main.swift` stays thin.
- Allowed relay jurisdictions (hostname country prefix): `al ar br ca ch cl co es md mx nl pe ph ro rs th ua`.
- Swift tests: `swift test` from repo root. App build: `scripts/build-app.sh`.

---

### Task 1: QbtTunnelStatus core logic (VPNDNSCore, TDD)

**Files:**
- Create: `Sources/VPNDNSCore/QbtTunnelStatus.swift`
- Test: `Tests/VPNDNSCoreTests/QbtTunnelStatusTests.swift`

**Interfaces:**
- Consumes: nothing new (stdlib only; style matches `TailscaleStatus.swift` naive line parsers).
- Produces (used verbatim by Task 6):
  - `struct QbtDevice: Equatable { let address: String }`
  - `func parseQbtDevice(_ json: String) -> QbtDevice?`
  - `func parseIfconfigHasAddress(_ out: String, address: String) -> Bool`
  - `func parseQbtListening(_ lsofOut: String, address: String) -> Bool`
  - `func parseExitHostname(_ amIJson: String) -> String?`
  - `enum QbtTunnelState: Equatable { case notInstalled, tunnelDown, qbtNotRunning, qbtNotBound, active(relay: String?) }`
  - `func deriveQbtState(installed: Bool, ifaceUp: Bool, alive: Bool, qbtRunning: Bool, qbtListening: Bool, relay: String?) -> QbtTunnelState`
  - `func qbtRowLabel(_ s: QbtTunnelState) -> String`

- [ ] **Step 1: Write the failing tests**

Create `Tests/VPNDNSCoreTests/QbtTunnelStatusTests.swift`:

```swift
import XCTest
@testable import VPNDNSCore

final class QbtTunnelStatusTests: XCTestCase {
    func testParseQbtDevice() {
        let json = #"{"name":"Cool Otter","pubkey":"abc=","ipv4_address":"10.151.12.34"}"#
        XCTAssertEqual(parseQbtDevice(json), QbtDevice(address: "10.151.12.34"))
        XCTAssertNil(parseQbtDevice("{}"))
        XCTAssertNil(parseQbtDevice(""))
    }

    func testParseIfconfigHasAddress() {
        let up = """
        utun100: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1160
        \tinet 10.151.12.34 --> 10.64.0.1 netmask 0xffffffff
        """
        XCTAssertTrue(parseIfconfigHasAddress(up, address: "10.151.12.34"))
        XCTAssertFalse(parseIfconfigHasAddress(up, address: "10.151.12.3"))   // prefix must not match
        XCTAssertFalse(parseIfconfigHasAddress("ifconfig: interface utun100 does not exist", address: "10.151.12.34"))
    }

    func testParseQbtListening() {
        let lsof = """
        COMMAND     PID          USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
        qbittorre 39025 nicholassmith   25u  IPv4  0xdead      0t0  TCP 10.151.12.34:13794 (LISTEN)
        """
        XCTAssertTrue(parseQbtListening(lsof, address: "10.151.12.34"))
        XCTAssertFalse(parseQbtListening(lsof, address: "10.9.9.9"))
        XCTAssertFalse(parseQbtListening("", address: "10.151.12.34"))
    }

    func testParseExitHostname() {
        let json = #"{"ip":"1.2.3.4","mullvad_exit_ip_hostname":"ca-mtr-wg-306","organization":"X"}"#
        XCTAssertEqual(parseExitHostname(json), "ca-mtr-wg-306")
        XCTAssertNil(parseExitHostname(#"{"ip":"1.2.3.4"}"#))
    }

    func testDeriveQbtState() {
        XCTAssertEqual(deriveQbtState(installed: false, ifaceUp: false, alive: false, qbtRunning: false, qbtListening: false, relay: nil), .notInstalled)
        XCTAssertEqual(deriveQbtState(installed: true, ifaceUp: false, alive: false, qbtRunning: true, qbtListening: false, relay: nil), .tunnelDown)
        XCTAssertEqual(deriveQbtState(installed: true, ifaceUp: true, alive: false, qbtRunning: true, qbtListening: true, relay: nil), .tunnelDown)
        XCTAssertEqual(deriveQbtState(installed: true, ifaceUp: true, alive: true, qbtRunning: false, qbtListening: false, relay: "x"), .qbtNotRunning)
        XCTAssertEqual(deriveQbtState(installed: true, ifaceUp: true, alive: true, qbtRunning: true, qbtListening: false, relay: "x"), .qbtNotBound)
        XCTAssertEqual(deriveQbtState(installed: true, ifaceUp: true, alive: true, qbtRunning: true, qbtListening: true, relay: "ca-mtr-wg-306"), .active(relay: "ca-mtr-wg-306"))
    }

    func testQbtRowLabels() {
        XCTAssertEqual(qbtRowLabel(.active(relay: "ca-mtr-wg-306")), "qBittorrent: ● via ca-mtr-wg-306")
        XCTAssertEqual(qbtRowLabel(.active(relay: nil)), "qBittorrent: ● tunneled")
        XCTAssertEqual(qbtRowLabel(.qbtNotRunning), "qBittorrent: ● tunnel up · qbt not running")
        XCTAssertEqual(qbtRowLabel(.qbtNotBound), "qBittorrent: ◐ tunnel up · qbt not bound")
        XCTAssertEqual(qbtRowLabel(.tunnelDown), "qBittorrent: ○ tunnel down — torrents stalled (safe)")
        XCTAssertEqual(qbtRowLabel(.notInstalled), "qBittorrent: not installed")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd ~/Code/vpn-dns-menubar && swift test --filter QbtTunnelStatusTests 2>&1 | tail -5`
Expected: compile FAILURE ("cannot find 'parseQbtDevice' in scope").

- [ ] **Step 3: Write the implementation**

Create `Sources/VPNDNSCore/QbtTunnelStatus.swift`:

```swift
import Foundation

/// Non-secret metadata about the dedicated qbt tunnel device, read from
/// /etc/wireguard-qbt/device.json (world-readable; the private key is not in it).
public struct QbtDevice: Equatable {
    public let address: String
    public init(address: String) { self.address = address }
}

/// Extract "ipv4_address" from device.json. Same quote-token technique as
/// parseTailscaleBackend: works for single- or multi-line JSON without a decoder.
public func parseQbtDevice(_ json: String) -> QbtDevice? {
    for line in json.split(separator: "\n") {
        guard line.contains("\"ipv4_address\"") else { continue }
        let parts = line.split(separator: "\"")
        if let idx = parts.firstIndex(of: "ipv4_address"), idx + 2 < parts.count {
            return QbtDevice(address: String(parts[idx + 2]))
        }
    }
    return nil
}

/// True when `ifconfig utun100` output shows exactly this inet address.
/// Trailing space in the needle prevents "10.1.2.3" matching "10.1.2.34".
public func parseIfconfigHasAddress(_ out: String, address: String) -> Bool {
    out.contains("inet \(address) ")
}

/// True when lsof output has a LISTEN line bound to the tunnel address.
public func parseQbtListening(_ lsofOut: String, address: String) -> Bool {
    for line in lsofOut.split(separator: "\n")
    where line.contains("\(address):") && line.contains("(LISTEN)") {
        return true
    }
    return false
}

/// Exit relay hostname from https://am.i.mullvad.net/json.
public func parseExitHostname(_ amIJson: String) -> String? {
    for line in amIJson.split(separator: "\n") {
        guard line.contains("\"mullvad_exit_ip_hostname\"") else { continue }
        let parts = line.split(separator: "\"")
        if let idx = parts.firstIndex(of: "mullvad_exit_ip_hostname"), idx + 2 < parts.count {
            return String(parts[idx + 2])
        }
    }
    return nil
}

public enum QbtTunnelState: Equatable {
    case notInstalled          // no device.json — feature absent; hide the rows
    case tunnelDown            // utun100 missing, wrong address, or dead handshake
    case qbtNotRunning         // tunnel live, qBittorrent not running
    case qbtNotBound           // tunnel live, qbt running but no listener on the tunnel address
    case active(relay: String?)
}

public func deriveQbtState(installed: Bool, ifaceUp: Bool, alive: Bool,
                           qbtRunning: Bool, qbtListening: Bool, relay: String?) -> QbtTunnelState {
    if !installed { return .notInstalled }
    if !(ifaceUp && alive) { return .tunnelDown }
    if !qbtRunning { return .qbtNotRunning }
    if !qbtListening { return .qbtNotBound }
    return .active(relay: relay)
}

public func qbtRowLabel(_ s: QbtTunnelState) -> String {
    switch s {
    case .notInstalled: return "qBittorrent: not installed"
    case .tunnelDown: return "qBittorrent: ○ tunnel down — torrents stalled (safe)"
    case .qbtNotRunning: return "qBittorrent: ● tunnel up · qbt not running"
    case .qbtNotBound: return "qBittorrent: ◐ tunnel up · qbt not bound"
    case .active(let relay):
        if let relay { return "qBittorrent: ● via \(relay)" }
        return "qBittorrent: ● tunneled"
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter QbtTunnelStatusTests 2>&1 | tail -3`
Expected: all tests PASS. Also run the full suite once (`swift test 2>&1 | tail -3`) — no regressions.

- [ ] **Step 5: Commit**

```bash
git add Sources/VPNDNSCore/QbtTunnelStatus.swift Tests/VPNDNSCoreTests/QbtTunnelStatusTests.swift
git commit -m "feat: QbtTunnelStatus parsers, state derivation, row labels"
```

---

### Task 2: Tunnel daemon script + LaunchDaemon plist

**Files:**
- Create: `qbt-tunnel/qbt-wg-up.sh`
- Create: `qbt-tunnel/com.nicholassmith.qbt-wireguard.plist`

**Interfaces:**
- Consumes: `/etc/wireguard-qbt/qbt.conf` (written by Tasks 3–4), `/etc/wireguard-qbt/device.json` (`.ipv4_address`).
- Produces: live `utun100` with scoped default route; log at `/var/log/qbt-wireguard.log`. Task 5's installer copies both files into place.

- [ ] **Step 1: Write `qbt-tunnel/qbt-wg-up.sh`**

```bash
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
```

- [ ] **Step 2: Write `qbt-tunnel/com.nicholassmith.qbt-wireguard.plist`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.nicholassmith.qbt-wireguard</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/libexec/qbt-tunnel/qbt-wg-up.sh</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>10</integer>
    <key>StandardOutPath</key>
    <string>/var/log/qbt-wireguard.log</string>
    <key>StandardErrorPath</key>
    <string>/var/log/qbt-wireguard.log</string>
</dict>
</plist>
```

- [ ] **Step 3: Verify syntax**

Run: `bash -n qbt-tunnel/qbt-wg-up.sh && plutil -lint qbt-tunnel/com.nicholassmith.qbt-wireguard.plist`
Expected: no bash output; `OK` from plutil.

- [ ] **Step 4: Commit**

```bash
chmod +x qbt-tunnel/qbt-wg-up.sh
git add qbt-tunnel/qbt-wg-up.sh qbt-tunnel/com.nicholassmith.qbt-wireguard.plist
git commit -m "feat: qbt tunnel daemon script + LaunchDaemon plist (pinned utun100, scoped route)"
```

---

### Task 3: Device registration script

**Files:**
- Create: `qbt-tunnel/register-device.sh`

**Interfaces:**
- Consumes: `/usr/local/bin/mullvad account get` (line `Mullvad account:    <digits>`); Mullvad app API.
- Produces: `/etc/wireguard-qbt/qbt.conf` (`[Interface]` + `PrivateKey` only, mode 600) and `/etc/wireguard-qbt/device.json` (`{"name":…,"pubkey":…,"ipv4_address":"10.x.y.z"}`, mode 644). Task 4 appends the `[Peer]`; Task 2's daemon and Task 6's app read these.

- [ ] **Step 1: Write `qbt-tunnel/register-device.sh`**

```bash
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
```

- [ ] **Step 2: Verify syntax**

Run: `bash -n qbt-tunnel/register-device.sh`
Expected: no output.

- [ ] **Step 3: Verify the API endpoints are current (read-only check, no device created)**

Run: `curl -s -o /dev/null -w '%{http_code}\n' -X POST https://api.mullvad.net/auth/v1/token -H 'Content-Type: application/json' -d '{"account_number":"0000000000000000"}'`
Expected: `400` or `401`-family (endpoint exists, bad account). If `404`: the API moved — check Mullvad's open-source app sources for the current auth + device-creation paths and update BOTH curl calls before proceeding.

- [ ] **Step 4: Commit**

```bash
chmod +x qbt-tunnel/register-device.sh
git add qbt-tunnel/register-device.sh
git commit -m "feat: one-time Mullvad device registration for the qbt tunnel"
```

---

### Task 4: Relay pin script

**Files:**
- Create: `qbt-tunnel/pin-qbt-relay.sh`

**Interfaces:**
- Consumes: `https://api.mullvad.net/app/v1/relays` (`.wireguard.relays[]`: `.hostname`, `.ipv4_addr_in`, `.public_key`, `.active`); existing `PrivateKey` line in `/etc/wireguard-qbt/qbt.conf`.
- Produces: rewritten `qbt.conf` with `[Peer]` (winner relay); daemon kicked. Re-runnable anytime.

- [ ] **Step 1: Write `qbt-tunnel/pin-qbt-relay.sh`**

```bash
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
```

- [ ] **Step 2: Verify syntax and the jq filter against the live API**

Run: `bash -n qbt-tunnel/pin-qbt-relay.sh`
Expected: no output.
Run the candidate query standalone (read-only):

```bash
curl -sf --max-time 15 https://api.mullvad.net/app/v1/relays | jq -r --argjson allowed '["ca","mx"]' '
    [.wireguard.relays[] | select(.active)
     | select((.hostname | split("-")[0]) as $cc | $allowed | index($cc))]
    | group_by(.hostname | split("-")[0:2] | join("-")) | map(.[0])
    | .[] | [.hostname, .ipv4_addr_in, .public_key] | @tsv' | head -5
```

Expected: a few TSV lines like `ca-mtr-wg-001  <ip>  <base64key>`. If the JSON shape differs (empty output), inspect `curl -sf https://api.mullvad.net/app/v1/relays | jq 'keys'` and fix the filter paths before committing.

- [ ] **Step 3: Commit**

```bash
chmod +x qbt-tunnel/pin-qbt-relay.sh
git add qbt-tunnel/pin-qbt-relay.sh
git commit -m "feat: latency-probed relay pinning for the qbt tunnel"
```

---

### Task 5: Installer, sudoers rule, install.sh pointer

**Files:**
- Create: `qbt-tunnel/install-qbt-tunnel.sh`
- Create: `qbt-tunnel/qbt-tunnel.sudoers`
- Modify: `install.sh` (append pointer at end)
- Modify: `.gitignore` (create if absent)

**Interfaces:**
- Consumes: Tasks 2–4 scripts (same repo dir); `SUDO_USER` for the qBittorrent ini path and sudoers rule.
- Produces: fully installed tunnel; qBittorrent ini keys `Session\Interface=utun100`, `Session\InterfaceName=utun100`, `Session\InterfaceAddress=<addr>` under `[BitTorrent]`.

- [ ] **Step 1: Write `qbt-tunnel/qbt-tunnel.sudoers`**

```
# Menu-bar restart action for the qbt tunnel — exactly one command, nothing else.
nicholassmith ALL=(root) NOPASSWD: /bin/launchctl kickstart -k system/com.nicholassmith.qbt-wireguard
```

- [ ] **Step 2: Write `qbt-tunnel/install-qbt-tunnel.sh`**

```bash
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
```

- [ ] **Step 3: Append pointer to `install.sh` and guard `.gitignore`**

Append to the end of `install.sh`:

```bash
echo
echo "Optional: dedicated always-on Mullvad tunnel for qBittorrent:"
echo "  brew install wireguard-go wireguard-tools jq   # once"
echo "  sudo $SRC_DIR/qbt-tunnel/install-qbt-tunnel.sh"
```

Create/append `.gitignore`:

```
qbt-tunnel/*.conf
qbt-tunnel/*.key
qbt-tunnel/device.json
```

- [ ] **Step 4: Verify syntax**

Run: `bash -n qbt-tunnel/install-qbt-tunnel.sh && bash -n install.sh && visudo -cf qbt-tunnel/qbt-tunnel.sudoers`
Expected: no bash errors; `qbt-tunnel/qbt-tunnel.sudoers: parsed OK`.

- [ ] **Step 5: Commit**

```bash
chmod +x qbt-tunnel/install-qbt-tunnel.sh
git add qbt-tunnel/install-qbt-tunnel.sh qbt-tunnel/qbt-tunnel.sudoers install.sh .gitignore
git commit -m "feat: qbt tunnel installer, sudoers rule, install.sh pointer"
```

---

### Task 6: Menu row + restart action in VPN & DNS.app

**Files:**
- Modify: `Sources/VPNDNSMenuBar/main.swift` (App class: state vars, poll, build, action)

**Interfaces:**
- Consumes from Task 1: `QbtDevice`, `parseQbtDevice`, `parseIfconfigHasAddress`, `parseQbtListening`, `parseExitHostname`, `QbtTunnelState`, `deriveQbtState(installed:ifaceUp:alive:qbtRunning:qbtListening:relay:)`, `qbtRowLabel(_:)`; existing `parsePingMinRTT`, `Shell.run(_:_:timeout:)`.
- Produces: menu rows; restart via `sudo -n /bin/launchctl kickstart -k system/com.nicholassmith.qbt-wireguard` (must match the sudoers rule from Task 5 exactly).

- [ ] **Step 1: Add constants and state to `App`**

Below the existing `private let TS = …` line at the top of main.swift add:

```swift
private let QBT_IFACE = "utun100"
private let QBT_DEVJSON = "/etc/wireguard-qbt/device.json"
private let QBT_GATEWAY = "10.64.0.1"
private let QBT_DAEMON = "system/com.nicholassmith.qbt-wireguard"
```

Inside `App`, next to `private var corpDNS = false`, add:

```swift
private var qbtState: QbtTunnelState = .notInstalled
private var qbtLastRelay: String?     // main-thread; last confirmed exit hostname
private var pollTick = 0              // main-thread; drives the every-12th curl
```

- [ ] **Step 2: Add the blocking poll helper to `App`**

```swift
// Runs on pollQueue (never main). Cheap local checks every tick; the exit-IP
// curl only every 12th tick (~60s) or until a relay name is first learned.
private func pollQbtBlocking(tick: Int, lastRelay: String?) -> (QbtTunnelState, String?) {
    guard let devJson = try? String(contentsOfFile: QBT_DEVJSON, encoding: .utf8),
          let dev = parseQbtDevice(devJson) else { return (.notInstalled, nil) }
    let ifOut = Shell.run("/sbin/ifconfig", [QBT_IFACE], timeout: 3) ?? ""
    let ifaceUp = parseIfconfigHasAddress(ifOut, address: dev.address)
    var alive = false
    if ifaceUp {
        let ping = Shell.run("/sbin/ping", ["-q", "-c", "1", "-t", "2", "-b", QBT_IFACE, QBT_GATEWAY], timeout: 4) ?? ""
        alive = parsePingMinRTT(ping) != nil
    }
    var relay = lastRelay
    if alive && (relay == nil || tick % 12 == 0) {
        let json = Shell.run("/usr/bin/curl",
            ["--interface", QBT_IFACE, "--max-time", "3", "-s", "https://am.i.mullvad.net/json"],
            timeout: 6) ?? ""
        if let fresh = parseExitHostname(json) { relay = fresh }
    }
    let running = !(Shell.run("/usr/bin/pgrep", ["-x", "qbittorrent"], timeout: 3) ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    var listening = false
    if running {
        let lsof = Shell.run("/usr/sbin/lsof",
            ["-nP", "-a", "-c", "qbittorre", "-iTCP", "-sTCP:LISTEN"], timeout: 5) ?? ""
        listening = parseQbtListening(lsof, address: dev.address)
    }
    return (deriveQbtState(installed: true, ifaceUp: ifaceUp, alive: alive,
                           qbtRunning: running, qbtListening: listening, relay: relay), relay)
}
```

- [ ] **Step 3: Wire into `poll()`**

In `poll()`, on the main thread before `pollQueue.async`, add:

```swift
let tick = pollTick
pollTick += 1
let lastRelay = qbtLastRelay
```

Inside the `pollQueue.async` closure, after the `dns` line add:

```swift
let qbt = self.pollQbtBlocking(tick: tick, lastRelay: lastRelay)
```

Inside the `DispatchQueue.main.async` commit block, after `self.corpDNS = dns` add:

```swift
self.qbtState = qbt.0
self.qbtLastRelay = qbt.1
```

- [ ] **Step 4: Add menu rows in `build(_:)` and the restart action**

In `build(_:)`, directly after the `tsToggle` item (before the `NSMenuItem.separator()` that precedes fast cities), add:

```swift
if qbtState != .notInstalled {
    menu.addItem(NSMenuItem.separator())
    let qbt = NSMenuItem(title: qbtRowLabel(qbtState), action: nil, keyEquivalent: "")
    qbt.isEnabled = false
    menu.addItem(qbt)
    let restart = NSMenuItem(title: "Restart qBittorrent Tunnel", action: #selector(restartQbtTunnel), keyEquivalent: "")
    restart.target = self
    menu.addItem(restart)
}
```

Add the action alongside the other `@objc` methods:

```swift
// sudo -n: fail instead of prompting (a GUI app can't answer); the
// /etc/sudoers.d/qbt-tunnel rule must match this command exactly.
@objc private func restartQbtTunnel() {
    DispatchQueue.global().async { [weak self] in
        _ = Shell.run("/usr/bin/sudo",
            ["-n", "/bin/launchctl", "kickstart", "-k", "system/com.nicholassmith.qbt-wireguard"],
            timeout: 15)
        DispatchQueue.main.async { self?.poll() }
    }
}
```

- [ ] **Step 5: Build and test**

Run: `swift build 2>&1 | tail -3 && swift test 2>&1 | tail -3`
Expected: build succeeds; full suite passes.

- [ ] **Step 6: Commit**

```bash
git add Sources/VPNDNSMenuBar/main.swift
git commit -m "feat: qBittorrent tunnel status row + restart action in menu"
```

---

### Task 7: README section

**Files:**
- Modify: `README.md` (new `## qBittorrent dedicated tunnel` section before any uninstall section, matching existing tone)

- [ ] **Step 1: Write the section**

Content must cover, in this order (prose matching the README's existing voice):

1. What it is: always-on Mullvad WireGuard tunnel on pinned `utun100`, scoped routing, only qBittorrent uses it; survives system-Mullvad connect/disconnect; fails closed.
2. Install: `brew install wireguard-go wireguard-tools jq` then `sudo qbt-tunnel/install-qbt-tunnel.sh` (quit qBittorrent first so the binding applies). Uses 1 of 5 Mullvad device slots.
3. Manual fallback for registration: log into mullvad.net → WireGuard configuration → generate for a new device; put `PrivateKey` into `/etc/wireguard-qbt/qbt.conf` `[Interface]` and write `/etc/wireguard-qbt/device.json` with `{"name":"<device>","pubkey":"<pub>","ipv4_address":"10.x.y.z"}`; then `sudo qbt-tunnel/pin-qbt-relay.sh`.
4. Operations: re-pin a dead relay (`sudo qbt-tunnel/pin-qbt-relay.sh`); logs (`/var/log/qbt-wireguard.log`); menu row states and the restart action.
5. Accepted limitations (from the spec, verbatim intent): tracker-hostname DNS via system resolver; qBittorrent GUI HTTP (RSS/update checks) not covered; static single relay; static key.
6. Uninstall: `sudo launchctl bootout system/com.nicholassmith.qbt-wireguard; sudo rm -rf /Library/LaunchDaemons/com.nicholassmith.qbt-wireguard.plist /usr/local/libexec/qbt-tunnel /etc/wireguard-qbt /etc/sudoers.d/qbt-tunnel`, revert qBittorrent's Network interface to none, and delete the device in the Mullvad account.

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: qBittorrent dedicated tunnel section"
```

---

### Task 8: Live install + verification matrix (user-assisted)

**Files:** none (operational task). Requires the real machine; parts need the user.

- [ ] **Step 1: Install deps and run the installer**

```bash
brew install wireguard-go wireguard-tools jq
# quit qBittorrent first (menu > Quit) so the binding applies
sudo ~/Code/vpn-dns-menubar/qbt-tunnel/install-qbt-tunnel.sh
```

Expected: device registered, relay pinned (probe output lists candidates + winner), `utun100 up`, `tunnel LIVE`, `qBittorrent bound`.
First verify `wireguard-go -f` semantics: `/opt/homebrew/bin/wireguard-go --help 2>&1 | grep -A1 '\-f'` — if `-f` is not "foreground", fix `qbt-wg-up.sh` (env `WG_PROCESS_FOREGROUND=1` is the fallback) before the installer run.

- [ ] **Step 2: Rebuild and relaunch the app; launch qBittorrent**

```bash
~/Code/vpn-dns-menubar/scripts/build-app.sh
open ~/Applications/"VPN & DNS.app"; open -a qbittorrent
```

Expected: menu shows `qBittorrent: ● via <relay>` within ~60s; `lsof -nP -a -c qbittorre -iTCP -sTCP:LISTEN` shows only the `10.x` tunnel address (plus loopback).

- [ ] **Step 3: Spec verification matrix**

1. System Mullvad connected → add a test torrent (e.g. a Linux ISO magnet) → transfers flow; row shows relay.
2. `mullvad disconnect` mid-transfer → transfers continue within ~10s; `curl --interface utun100 -s https://am.i.mullvad.net/json` shows the SAME pinned relay before and after.
3. `sudo launchctl bootout system/com.nicholassmith.qbt-wireguard` mid-transfer → transfers stall; `lsof` shows qbt sockets gone from en0/all interfaces; row: `○ tunnel down — torrents stalled (safe)`. Then `sudo launchctl bootstrap system /Library/LaunchDaemons/com.nicholassmith.qbt-wireguard.plist` → recovers.
4. Menu "Restart qBittorrent Tunnel" → no password prompt; row returns to `●` within ~15s.
5. Torrent-IP check: add the checkmytorrentip (or ipleak.net torrent) magnet → reported IP == pinned relay, in BOTH system-Mullvad states.
6. USER-ASSISTED: reboot → `ifconfig utun100` up unattended before login completes; torrents resume after launching qBittorrent.

- [ ] **Step 4: Record results + final commit if fixes were needed**

Any fix discovered here gets its own commit; then re-run the affected matrix row.

---

## Self-Review (completed)

- Spec coverage: daemon (T2), registration (T3), pinning + jurisdictions (T4), installer/sudoers/binding (T5), menu row + restart (T1+T6), README limitations (T7), test matrix (T8). Scoped route + pinned name in T2; double-key binding in T5; fail-closed paths in T2/T5/T8.
- Placeholders: none — all code inline; the two runtime-verify items (API endpoint shape, `wireguard-go -f`) are explicit steps with expected outputs and fallbacks (T3.3, T4.2, T8.1).
- Type consistency: `deriveQbtState(installed:ifaceUp:alive:qbtRunning:qbtListening:relay:)` and `qbtRowLabel` identical in T1 tests, T1 impl, T6 usage; sudoers command string identical in T5 file and T6 action.
