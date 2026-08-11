# Remove the qBittorrent Dedicated Tunnel; Show the Mullvad Device in the Menu

**Date:** 2026-08-11
**Status:** Approved (design); Part 1 live teardown executed; pending implementation plan
**Component:** `vpn-dns-menubar` (Swift menu bar app, DNS watcher, `qbt-tunnel/`)

Two changes, implemented together because both land in `main.swift`:

- **Part 1** — purge the qBittorrent dedicated tunnel (below).
- **Part 2** — the Mullvad group header shows the machine's registered device
  name: `Mullvad - Fair Sheep` instead of `Mullvad`.

## Part 1 Overview

Delete the Mac-side qBittorrent dedicated tunnel in its entirety — the
`wireguard-go` LaunchDaemon on `utun100`, the SOCKS5 proxy agent, the relay
pinner, the sudoers rules, the menu's qBittorrent section, and the DNS watcher's
Mullvad/qbt mutual-exclusivity duty — and revoke its Mullvad device
("Proper Gecko"), returning that slot to the account.

This reverses the design in
`docs/superpowers/specs/2026-07-30-qbt-dedicated-tunnel-design.md`. That design
solved a real problem, but its premise no longer holds: the torrenting workload
now lives on the home server, and the Mac-side tunnel is idle infrastructure
that costs a device slot and destabilizes the Mullvad daemon.

## Background: what the investigation found

Three facts established on 2026-08-11 drove this:

1. **"Proper Gecko" is this Mac's `utun100`, not the server's.** Its key material
   is at `/etc/wireguard-qbt/device.json` on this Mac (pubkey `B/Ys1OHy…`,
   `ipv4_address` 10.161.129.185, matching the live interface) and it appears on
   the account as a device created 2026-07-31.
2. **qBittorrent does not run on this Mac.** `/Applications/qBittorrent.app` is
   installed but has no process. The only live piece of the stack is the SOCKS5
   proxy agent on `127.0.0.1:1080`, serving a client that never connects. The
   tunnel has been carrying no torrent traffic.
3. **The torrenting is on `dino` (hpe-dinosaur), fully independent.** It runs its
   own `mullvad-daemon.service` on device **Free Deer** (registered 2026-02-17),
   with `qbittorrent-nox` in a rootful podman container inside the `mullvad`
   network namespace, alongside `stremio-server` and
   `netns-portforward@tcp-{8090,11470,12470}`. Nothing in this repo touches it.

The account held four devices when this was written — Joyful Badger (this Mac's
app), Free Deer (dino), Dear Bear (unidentified), Proper Gecko (this Mac's idle
qbt tunnel) — of which the last was pure waste.

Device inventory moved the same day, for an unrelated reason: this Mac had been
sharing the Joyful Badger device with another Mac (one WireGuard key on two
machines, which breaks on Mullvad's periodic key rotation). Both machines were
re-logged in, retiring Joyful Badger and creating **Fair Sheep** (this Mac) and
**Clear Turtle** (the other Mac). Proper Gecko was then revoked, leaving four:
Free Deer, Dear Bear, Fair Sheep, Clear Turtle.

Two known defects also disappear with the tunnel, both documented in the README's
"Known limitations":

- `utun100`'s mere presence — even as a zombie interface — makes the Mullvad
  daemon's MTU probes black-hole and its tunnel monitor reconnect every 2–11
  minutes (diagnosed 2026-08-03).
- The Mullvad app and this tunnel are mutually exclusive, which is why the DNS
  watcher grew a second duty and why the menu had to tear the tunnel down before
  `mullvad connect` (commit `e81c2d1`).

## Goals

- Free the "Proper Gecko" device slot.
- Remove `utun100` permanently, eliminating the documented reconnect-flap cause.
- Return `dns-watcher/mullvad-tailscale-dns-sync.sh` to a single duty: toggling
  Tailscale `accept-dns` with Mullvad state.
- Simplify the menu's Mullvad connect path by deleting the pre-connect teardown.
- Leave the repo with no dead code or documentation describing the removed
  feature.
- Make the menu state which Mullvad device this machine is registered as, so a
  shared or unexpected device identity is visible at a glance instead of
  requiring `mullvad account get` — the failure mode that went unnoticed while
  two Macs shared Joyful Badger.

## Non-Goals

- **No change to `dino`.** Its Mullvad device, netns, containers, and port
  forwards are out of scope.
- No replacement torrent path on this Mac. If qBittorrent is ever wanted here
  again, it is a fresh design (riding the app's tunnel via the proxy was
  considered and set aside — see Alternatives).
- Not uninstalling `/Applications/qBittorrent.app`.
- No change to Tailscale handling, the fast-cities menus, latency probing, or
  split-tunnel logic.

## Design

### 1. Live system teardown

Stop using the key, then revoke it — in this order:

```sh
launchctl bootout "gui/$(id -u)/com.nicholassmith.qbt-socks5"
rm -f ~/Library/LaunchAgents/com.nicholassmith.qbt-socks5.plist
sudo launchctl bootout system/com.nicholassmith.qbt-wireguard
sudo rm -rf /Library/LaunchDaemons/com.nicholassmith.qbt-wireguard.plist \
            /usr/local/libexec/qbt-tunnel /etc/wireguard-qbt /etc/sudoers.d/qbt-tunnel
ifconfig utun100                                   # must report "does not exist"
mullvad account revoke-device "proper gecko"       # last
```

**Executed 2026-08-11**, except the final `rm -rf`: the sudoers rule only ever
granted passwordless `launchctl`, so the root-owned files
(`/Library/LaunchDaemons/com.nicholassmith.qbt-wireguard.plist`,
`/usr/local/libexec/qbt-tunnel`, `/etc/wireguard-qbt`,
`/etc/sudoers.d/qbt-tunnel`) await an interactive sudo. They are inert — the
daemon is booted out and `utun100` is gone. The device is revoked.

`qBittorrent.app` keeps a proxy setting pointing at the now-dead
`127.0.0.1:1080`. This is deliberate: if it is ever launched, it fails closed
(no proxy, no traffic) rather than sending torrent traffic out the physical
interface. Clearing it is explicitly *not* part of this work.

### 2. Repo surgery (purge, not deprecate)

| Path | Change |
| --- | --- |
| `qbt-tunnel/` (9 files) | delete outright |
| `dns-watcher/mullvad-tailscale-dns-sync.sh` | remove `set_qbt_tunnel()`, `QBT_LABEL`, `QBT_PLIST`, both calls in the state loop, and the header comments describing the second duty |
| `Sources/VPNDNSCore/QbtTunnelStatus.swift` | delete (107 lines) |
| `Sources/VPNDNSCore/QbtExitCandidates.swift` | delete (30 lines) |
| `Tests/VPNDNSCoreTests/QbtTunnelStatusTests.swift` | delete (98 lines) |
| `Tests/VPNDNSCoreTests/QbtExitCandidatesTests.swift` | delete (25 lines) |
| `Sources/VPNDNSMenuBar/main.swift` | strip the `QBT_IFACE`/`QBT_DEVJSON`/`QBT_GATEWAY` constants, `qbtState`/`qbtLastRelay`/`qbtExitCandidates` state, `pollQbtBlocking`, the polling calls and candidate refresh, the qBittorrent menu section, `teardownQbtTunnelBlocking` and both call sites, `openQbt`, and `buildQbtExitItem` |
| `install.sh` | drop the three qbt references (header comment, agent-loaded message, qbt installer hint) |
| `README.md` | delete the "qBittorrent dedicated tunnel" section and every scattered qbt mention (intro, menu sketch, dot legend, watcher duties table, architecture notes) |
| `~/.claude/CLAUDE.md` | rewrite the DNS watcher bullet: single duty again, no exclusivity, no qbt sudoers (user-approved 2026-08-11) |

Purge rather than keep-as-optional: the feature's core premise is disproven (it
cannot coexist with the Mullvad app, and the workload moved), so in-tree dead
code documenting a broken design costs more than it saves. Git history remains
the record, including `register-device.sh` if a device ever needs re-minting.

Removing `teardownQbtTunnelBlocking()` retires the `e81c2d1` workaround: the
pre-connect teardown existed solely to keep `utun100` from stuttering the
handshake, and the watcher's safety net for GUI/CLI connects goes with it.

### 3. Part 2 — device name in the Mullvad group header

The group header at `main.swift:339` becomes `Mullvad - <device name>` (for this
machine, `Mullvad - Fair Sheep`), falling back to bare `Mullvad`.

Source of truth is `mullvad account get`, whose output carries a
`Device name:    Fair Sheep` line. Neither `mullvad status -v` nor any readable
file has it — `/etc/mullvad-vpn/device.json` is `0600 root:wheel` and the app
runs as the user.

- **New `Sources/VPNDNSCore/MullvadDevice.swift`** — `parseMullvadDeviceName(_:)
  -> String?`, a pure function over CLI text, mirroring `MullvadStatus.swift`'s
  parsing style. Returns `nil` when the `Device name:` line is absent (logged
  out) or its value is empty.
- **New `Tests/VPNDNSCoreTests/MullvadDeviceTests.swift`** — normal output,
  logged-out output, multi-word names, surrounding whitespace, missing line.
- **`main.swift`** — `deviceName: String?` held on the main thread, refreshed on
  `pollQueue` at startup and every 12th tick (~60s, the cadence the retired qbt
  exit-IP curl used) via `Shell.run("/usr/local/bin/mullvad", ["account", "get"],
  timeout: 5)`. The name only changes on login/logout, so this is generous.
  Header title: `deviceName.map { "Mullvad - \($0)" } ?? "Mullvad"`.

Routine decisions, recorded so they are not re-litigated: the separator is a
literal `" - "` as requested rather than an en dash; logged-out renders bare
`Mullvad` rather than an error string; the header stays non-clickable.

## Verification

- `swift build && swift test` — green, with the two qbt test files gone and no
  remaining references.
- `grep -ri "qbt\|qbittorrent"` across the repo returns nothing outside
  `docs/superpowers/` (historical specs and plans are left intact).
- Rebuilt app relaunches; menu shows Mullvad and Tailscale sections with **no**
  qBittorrent section, and the Mullvad row still connects/disconnects.
- `ifconfig utun100` → does not exist; `launchctl list | grep qbt` → empty.
- `mullvad account list-devices` → three devices, no Proper Gecko.
- A Mullvad connect/disconnect cycle still flips Tailscale `accept-dns`, logged
  under syslog tag `mullvad-ts-dns`, with no qbt transition lines.
- Menu header reads `Mullvad - Fair Sheep` on this machine, and matches
  `mullvad account get`'s `Device name:` exactly.
- The logged-out fallback is covered by `MullvadDeviceTests` rather than by
  logging the machine out; a bad parse must degrade to bare `Mullvad`, never to
  an empty or malformed header.
- Post-change observation (not a gate): Mullvad reconnect frequency should fall
  back toward the June baseline of roughly five reconnects in two weeks.

## Risks and one-way doors

- **Revoking the device is irreversible.** Re-creating it means burning a slot
  again, and `register-device.sh` will only exist in git history (the manual
  mullvad.net registration fallback also remains, documented in the README
  section being deleted — it survives in history).
- **Sudoers removal.** `/etc/sudoers.d/qbt-tunnel` is qbt-only by construction;
  confirm it holds nothing else before deleting.
- **Menu regression risk.** `main.swift` loses roughly 130 lines across seven
  regions; the polling loop and menu builder must be checked for orphaned
  variables and for the tick/candidate-refresh arithmetic that referenced qbt
  state.

## Alternatives considered

- **Point the SOCKS5 proxy at the Mullvad app's tunnel** (dynamic `bind_addr()`
  via `mullvad status -v` plus a `SIOCGIFADDR` ioctl), keeping a Mac-side torrent
  path with zero extra devices and a menu warning when the app's exit is not in
  the torrent-lenient city list. Rejected: qBittorrent does not run on this Mac,
  so it preserves a path nothing uses.
- **Move the qbt tunnel to another VPN provider.** Frees the Mullvad slot and
  would add port forwarding, but adds a subscription and keeps a second tunnel
  interface — the likely cause of the daemon instability regardless of provider.
- **Reuse the Mullvad app's device key for `utun100`.** Zero extra devices, but
  the app rotates its key, silently breaking the tunnel, and it does nothing
  about the coexistence instability.
- **Keep the slot and revoke a stale device instead.** Does not address the idle
  tunnel or the flap.

## Out of scope, noted for follow-up

`dino`'s `mullvad status` reports **Disconnected**, and a `curl` from inside its
`mullvad` netns returned nothing — suggesting the server's torrenting is
currently stalled (fail-closed, not leaking, as far as was checked). This is a
separate investigation and deliberately not part of this change.
