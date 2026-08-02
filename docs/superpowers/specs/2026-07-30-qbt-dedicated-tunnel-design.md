# qBittorrent Dedicated Mullvad Tunnel + Menu Row — Design

**Date:** 2026-07-30
**Status:** Approved (pending spec review)
**Repo:** vpn-dns-menubar (public — see Security notes)

## Problem

qBittorrent currently rides the system-wide Mullvad tunnel. Two failure modes:

1. When Mullvad is deliberately disconnected (e.g. for `ssh dino`), torrents either
   leak the real IP (before interface binding) or stall (after binding to the
   Mullvad app's utun).
2. The Mullvad app's utun number drifts between connects (observed utun12 ↔ utun15
   within one day), silently breaking any fixed interface binding.

Goal: qBittorrent traffic goes through Mullvad **always**, independent of the
system-wide Mullvad app's state, with status visible in VPN & DNS.app.

## Decisions (from brainstorming)

- **Architecture:** dedicated always-on WireGuard tunnel, native (not Docker/gluetun).
- **Exit relay:** fastest relay outside US jurisdiction in a torrent-lenient
  jurisdiction, chosen by latency probe. **Canada is included** in candidates.
- **Menu row:** status + a "Restart qBittorrent tunnel" action (no relay switcher yet).
- **Key registration:** hands-off via Mullvad app API using the account number from
  the local `mullvad` CLI; keypair generated locally; uses 1 of 5 device slots.

## Architecture

```
Mullvad account ──(one-time device registration)──► /etc/wireguard-qbt/qbt.conf  (root-only, git-ignored)
                                                          │
LaunchDaemon com.nicholassmith.qbt-wireguard ──► qbt-wg-up.sh ──► wireguard-go on pinned utun100
                                                          │           + scoped-only default route
qBittorrent (bound: utun100 + in-tunnel 10.x addr) ───────┘
VPN & DNS.app ──► QbtTunnelStatus row (status + restart action)
```

Key properties:

- **Pinned interface name `utun100`** — auto-assigned utuns take the lowest free
  numbers; nothing organically claims 100. No drift. The interface is always-on and
  survives system-Mullvad connect/disconnect cycles (only the encrypted UDP re-paths).
- **Scoped routing only** (`route add default -interface utun100 -ifscope utun100`) —
  the system routing table is untouched; only sockets explicitly bound to utun100
  use the tunnel. Zero interference with the Mullvad app or Tailscale.
- **Nesting:** with system Mullvad connected, the tunnel's encrypted UDP rides inside
  it (like multihop); disconnected, it goes straight out en0, still encrypted. The
  ISP sees Mullvad-bound WireGuard either way.
- **Fail closed everywhere:** any component failure leaves qBittorrent with nothing
  to bind → torrents stall; no path leaks the real IP.

## Components

### 1. Tunnel daemon — `qbt-tunnel/qbt-wg-up.sh` + `com.nicholassmith.qbt-wireguard.plist`

LaunchDaemon (system domain, RunAtLoad, KeepAlive) runs the script as root:

1. Start `wireguard-go` on explicit name `utun100`, foreground mode so launchd
   supervises and restarts it (implementation: verify the foreground env var /
   flag for the installed wireguard-go version before relying on it).
2. `wg setconf utun100 /etc/wireguard-qbt/qbt.conf`
3. `ifconfig utun100 inet <10.x> <10.x> mtu 1160 up`  **(amended 2026-08-02)**
   — The peer address is our OWN address. It was originally 10.64.0.1
   (Mullvad's in-tunnel gateway), which installs a *global* host route for that
   address; since every Mullvad tunnel uses the same gateway, that route
   hijacked the system Mullvad app's post-handshake connectivity ping into this
   tunnel and the app disconnected itself every time. 10.64.0.1 remains the
   liveness-ping target, reached via the scoped route below.
   — MTU 1160 fits inside the observed MTU-1260 system multihop tunnel with margin.
4. `route -q add -inet default -interface utun100 -ifscope utun100`
5. If `utun100` is already taken by a foreign interface: exit non-zero (launchd
   backs off; menu row shows tunnel down; fail closed).

IPv4-only in-tunnel. `PersistentKeepalive = 25` in the config. Binaries from
`/opt/homebrew/bin` (brew `wireguard-go`, `wireguard-tools`).

### 2. Key registration — one-time, inside `install.sh`

- `wg genkey` / `wg pubkey` locally.
- Account number read from the local Mullvad CLI (implementation: verify exact
  output format of `mullvad account get`).
- Register the public key as a new device via Mullvad's public app API
  (implementation: verify the current endpoint — account-number → auth token →
  create device — against Mullvad's documentation at build time). Response yields
  the device's **stable in-tunnel 10.x address**, written into the config and used
  as qBittorrent's bind address.
- Idempotent: skipped when `/etc/wireguard-qbt/qbt.conf` already exists.
- The device key is static (no auto-rotation): accepted trade-off; the in-tunnel
  address stays stable, which the double-keyed binding depends on.

### 3. Relay pinning — `qbt-tunnel/pin-qbt-relay.sh`

Run at install; re-runnable anytime (e.g. pinned relay decommissioned).

1. Candidates from `mullvad relay list` (WireGuard relays only), filtered to
   candidate jurisdictions (below).
2. Latency-probe candidates, reusing the approach of `scripts/refresh-candidates.sh`
   / `Latency.swift`; pick the lowest-latency relay.
3. Write `[Peer]` (relay pubkey, endpoint `ip:51820`, `AllowedIPs = 0.0.0.0/0`)
   into `/etc/wireguard-qbt/qbt.conf`; `launchctl kickstart -k` the daemon.

**Candidate jurisdictions (non-US, torrent-lenient), user-approved:**
Canada, Mexico, Colombia, Brazil, Argentina, Chile, Peru, Serbia, Albania,
Ukraine, Romania, Moldova, Spain, Switzerland, Thailand, Philippines, Netherlands.
From SC, Canada is the expected latency winner.

### 4. qBittorrent → SOCKS5 proxy **(superseded the binding design, 2026-08-01)**

The original plan bound qBittorrent to the interface directly
(`Session\Interface` + `Session\InterfaceAddress`). **That does not work.**
qBittorrent binds, logs "Successfully listening", and then transmits *zero
bytes*: every tracker reports `timed out`, DHT stays at 0 nodes, no peer
connection is attempted, downloads sit at `stalledDL` indefinitely. Verified
with interface byte counters (0 bytes out during a forced reannounce) while an
ordinary process binding the same address and port completed UDP announces, TCP
connections and full BitTorrent handshakes. Binding by device name, by address,
by both, disabling anonymous mode, changing relays and disabling split
tunneling all made no difference — the fault is libtorrent-side.

Instead, `qbt-tunnel/qbt-socks5-proxy.py` (user LaunchAgent
`com.nicholassmith.qbt-socks5`) listens on `127.0.0.1:1080` and makes every
outbound connection from the tunnel address, supporting both TCP CONNECT and
UDP ASSOCIATE so UDP trackers, DHT and µTP work. qBittorrent is configured with
that proxy for BitTorrent/RSS/misc plus hostname lookups, and holds no sockets
on the physical interface at all.

Still fail-closed (the proxy binds the tunnel address per connection), and
*stricter* than the original design: proxying DNS closes the tracker-hostname
and RSS leaks listed under Accepted Limitations below.

### 5. Menu row — `Sources/VPNDNSCore/QbtTunnelStatus.swift` + row in `main.swift`

Follows the `MullvadStatus`/`TailscaleStatus` pattern: polled off the main thread
with timeouts on every shell-out (per the 2026-07-07 click-freeze fix).

Checks per poll (cheap, local):
- `utun100` exists and holds the expected 10.x address (getifaddrs).
- Tunnel liveness: one ICMP ping to the in-tunnel gateway bound to utun100
  (`ping -c1 -b utun100`, short timeout).
- SOCKS5 proxy listening on 127.0.0.1:1080, and qBittorrent holding a
  connection to it (`lsof`, user-owned process, no root). **(amended
  2026-08-01: was "qBittorrent listening on the tunnel address", which no
  longer applies now that the proxy owns the binding.)**

Occasional check (every Nth poll and on menu open):
`curl --interface utun100 --max-time 3 https://am.i.mullvad.net/json` → shows the
confirmed exit relay hostname in the row.

Row states:
- `qBittorrent: ● via <relay>` — tunnel live, qbt bound and listening
- `qBittorrent: ● tunnel up · qbt not running`
- `qBittorrent: ◐ tunnel up · qbt not bound` — bound listener missing
- `qBittorrent: ○ tunnel down — torrents stalled (safe)`

Menu action **Restart qBittorrent tunnel** →
`sudo launchctl kickstart -k system/com.nicholassmith.qbt-wireguard`, allowed by a
one-line `/etc/sudoers.d/qbt-tunnel` NOPASSWD rule scoped to exactly that command.

Main status dot unchanged (row-level indicator only).

### 6. Installer — new idempotent section in `install.sh`

Order: brew deps → key registration (if needed) → relay pin → write LaunchDaemon +
sudoers drop-in → apply qBittorrent binding (prompting to quit the app if running)
→ rebuild VPN & DNS.app.

## Data flow

qBittorrent sockets (bound utun100/10.x) → wireguard-go encrypts → UDP to pinned
relay endpoint, routed by the system table (inside system Mullvad when connected;
bare-but-encrypted en0 otherwise) → relay decrypts → swarm/trackers see only the
relay exit IP. System Mullvad transitions cause only a seconds-long re-handshake.

## Failure handling

| Failure | Result | Recovery |
|---|---|---|
| Daemon dead / utun100 missing | qbt can't bind → stall, no leak | Menu restart action |
| utun100 claimed by foreign tunnel | Address mismatch → stall, no leak | Identify/stop the claimant, then kickstart (worst case: reboot) |
| Pinned relay down/decommissioned | Handshake dies → stall; row shows down | `pin-qbt-relay.sh` |
| Device key revoked | Same as relay down | Re-run registration |
| System Mullvad flap | Brief re-handshake, otherwise transparent | None needed |
| Sleep/wake | Keepalive re-handshakes | None needed |
| Reboot | LaunchDaemon restores tunnel before login | None needed |

## Accepted limitations (documented in README)

1. ~~**DNS metadata:** tracker hostname lookups use the system resolver.~~
   **Closed 2026-08-01** — hostname lookups now go through the SOCKS5 proxy.
2. ~~**qBittorrent GUI HTTP:** RSS fetches and update checks ignore the
   binding.~~ **Closed 2026-08-01** — the proxy covers RSS and misc traffic.
3. Static single relay (no auto-failover); static device key (no rotation).
4. The proxy is single-process Python. Fine at observed rates (4.5 MB/s across
   three torrents, 100+ concurrent connections) but not a tuned proxy.
5. No incoming connections (Mullvad has no port forwarding), so qBittorrent
   reports `firewalled`. Normal; outgoing peers still work.

The gluetun/Docker architecture (considered, deferred) is no longer needed to
close 1–2.

## Testing

- **Unit:** `QbtTunnelStatus` state derivation/parsing in `VPNDNSCoreTests`.
- **Manual matrix:**
  1. Mullvad connected → torrents flow; row shows relay exit.
  2. `mullvad disconnect` mid-torrent → flow continues, exit IP unchanged.
  3. Kill daemon mid-torrent → transfers stall; `lsof` shows no qbt sockets on
     en0; row shows tunnel down.
  4. Reboot → tunnel returns as utun100 unattended.
  5. Menu restart action recovers a wedged tunnel without a password prompt.
  6. Torrent-IP-checker magnet reports only the relay IP in all states.

## Security notes

- Repo is public: `/etc/wireguard-qbt/` (private key, account-derived config) is
  never committed; repo carries only templates/scripts. `.gitignore` guards any
  local scratch config.
- sudoers rule is single-command, absolute-path, NOPASSWD for user
  `nicholassmith` only.
- Verification steps flagged inline (wireguard-go foreground flag, `mullvad
  account get` format, current device-registration endpoint) are implementation
  prerequisites, not open design questions.
