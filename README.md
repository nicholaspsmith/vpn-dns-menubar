# vpn-dns-menubar

One macOS menu-bar icon that consolidates **Mullvad VPN** and **Tailscale** into a
single status dot, with a sectioned dropdown covering both apps plus the dedicated
qBittorrent tunnel — and a small launchd watcher with two duties: keep DNS working
when Mullvad and Tailscale run at once, and keep Mullvad and the qbt tunnel from
running at the same time (they destabilize each other; see Known limitations).

The primary deliverable is the standalone **"VPN & DNS.app"** (see
"Standalone Swift app" below). The original
[SwiftBar](https://github.com/swiftbar/SwiftBar) plugin remains in the repo as a
retired fallback. Hide the two native Mullvad/Tailscale menu-bar icons (e.g. with
[Ice](https://github.com/jordanbaird/Ice)) and let this be the only one.

## What you see

The menu bar shows **one icon**: a single status dot that tracks Mullvad.

| State | Dot |
|-------|-----|
| Connected | ![connected](screenshots/menubar-connected.png) |
| Connecting / Disconnecting | ![connecting](screenshots/menubar-connecting.png) |
| Blocked | ![blocked](screenshots/menubar-blocked.png) |
| Off / disconnected | ![off](screenshots/menubar-off.png) |

Clicking it opens a dropdown, grouped into three bold section headers:

```
Mullvad                                   ← bold section header
  ●  Connected — Denver, CO               → click toggles the VPN connection
  Split Tunnel: On                       ▸ toggle + excluded-app list
  Fastest US (No-ID)                     ▸ top-5 cities, ✓ = current
  Fastest Non-US (No-ID · torrent-safe)  ▸
──────────────────────────────────────────
qBittorrent                               ← bold section header
  ●  qBittorrent: via ca-mtr-wg-306       → click opens qBittorrent
  Restart qBittorrent Tunnel
  qBittorrent Exit                       ▸
──────────────────────────────────────────
Tailscale                                 ← bold section header
  ●  accept-dns (MagicDNS): ON            → click toggles accept-dns
  Status: Running                         → click opens the Tailscale app
  Disconnect Tailscale
──────────────────────────────────────────
Start at Login
──────────────────────────────────────────
Quit
```

Section headers are bold, full-contrast, non-clickable; informational rows render
at full contrast too (never the faint disabled gray). **Status rows carry a colored
dot**: the Mullvad row reuses the menu-bar mapping (green connected · orange
connecting/disconnecting · red blocked · grey off), and clicking it toggles the
connection — connect goes to Mullvad's own persisted relay selection (whatever
was last chosen via the fast-city submenus or the native app); the qBittorrent row is grey
(tunnel path down — torrents stalled, safe), orange (path up but qbt not
running/not routed), or green (fully active), and clicking it opens qBittorrent;
the accept-dns row is green (ON) / grey (OFF), and clicking it toggles
`tailscale set --accept-dns`. That toggle is a *temporary override* — the DNS
watcher (below) re-asserts its mapping on the next Mullvad connect/disconnect.

The two **fastest-city submenus** — "Fastest US (No-ID)" and "Fastest Non-US
(No-ID · torrent-safe)" — list the top-5 cities from the candidate list ranked by
latency. Clicking a city connects Mullvad to that city (setting the relay location
then running `mullvad connect`); clicking the currently-active city disconnects
(toggle behavior). A checkmark (✓) marks the city you're connected to, and a
freshness footer at the bottom of each submenu shows when the latencies were last
measured.

Latency is re-measured by direct ICMP pings (`/sbin/ping`) when the newest
measurement is older than **12 hours** (checked every 15 minutes and on
Mullvad-off transitions): normally while Mullvad is disconnected; if Mullvad is
connected and split tunneling is *already* on, the app temporarily adds
`/sbin/ping` to the split-tunnel exclusions so pings bypass the tunnel, verifies
the exclusion took (re-checking again before recording), then removes it. It
never turns split tunneling on or off itself — connected + split-tunneling-off
just waits for the next off-window — and it hides the transient exclusion from
the Split Tunnel submenu (with a startup sweep so a crash can't leave it
behind). On first run, and until a live measurement completes, the app falls
back to seed values baked into `Resources/bundle/candidates.json`. Measurements
persist across restarts in
`~/Library/Application Support/VPNDNSMenuBar/latency.json`. To refresh the
candidate list (update which cities qualify under No-ID rules):

```sh
scripts/refresh-candidates.sh
```

## Requirements

- macOS 13+ (the Swift app's platform floor)
- Xcode Command Line Tools (Swift 5.9+) to build the app — `xcode-select --install`
- [Mullvad VPN](https://mullvad.net/) (CLI at `/usr/local/bin/mullvad`) and
  [Tailscale](https://tailscale.com/) (the Mac app, not the standalone CLI)
- Optional: [Ice](https://github.com/jordanbaird/Ice) to hide the native icons;
  [SwiftBar](https://github.com/swiftbar/SwiftBar) (`brew install --cask swiftbar`)
  only if you wire the retired plugin fallback

## Install

```sh
git clone https://github.com/nicholaspsmith/vpn-dns-menubar.git
cd vpn-dns-menubar
./install.sh
```

`install.sh` is idempotent and:

1. **Builds "VPN & DNS.app"** (`scripts/build-app.sh`), symlinks it into
   `~/Applications` (SMAppService requires that location; the repo's `build/`
   stays the source of truth so rebuilds propagate), and opens it.
2. Generates the launchd plist from the template and **bootstraps the DNS-sync
   agent** (`com.nicholassmith.mullvad-tailscale-dns`) — DNS sync plus
   Mullvad/qbt-tunnel exclusivity.

Then use the menu's **Start at Login** toggle and hide the native
Mullvad/Tailscale icons. No Accessibility/Automation permission is needed.

`./install.sh --swiftbar` additionally symlinks the retired plugin fallback
`vpn-dns-control.5s.sh` into `~/.config/SwiftBar/` (override with
`SWIFTBAR_PLUGIN_DIR`) and refreshes SwiftBar — that path *does* need SwiftBar
granted Accessibility + Automation for its Mullvad row's native popover.

## Repo layout

| Path | Role |
|------|------|
| `vpn-dns-control.5s.sh` | **The SwiftBar plugin (retired fallback).** Symlinked into SwiftBar's plugin dir by `--swiftbar`; refresh interval (`.5s.`) is in the filename. |
| `assets/open-native-menu.sh` | Helper: `… mullvad\|tailscale` → AX-clicks the app's menu-bar item to open its native menu. |
| `assets/mullvad.png`, `tailscale.png` | App icons shown on the dropdown rows. |
| `assets/menubar-{green,orange,red,grey}.png` | Dot-only icons (24×44, 16px dot). **Unused fallback** — the bar is now an SF Symbol; kept in case the PNG route is wanted again. |
| `dns-watcher/mullvad-tailscale-dns-sync.sh` | The launchd watcher (driven by `mullvad status listen`): toggles Tailscale `accept-dns` and enforces Mullvad/qbt-tunnel mutual exclusivity. |
| `dns-watcher/com.nicholassmith.mullvad-tailscale-dns.plist` | LaunchAgent template (`__SCRIPT__` filled in by `install.sh`). |
| `install.sh` | Build + link the app and load the agent (`--swiftbar` also wires the plugin fallback). |

> ⚠️ **Only the plugin may live in SwiftBar's plugin dir.** SwiftBar loads *every*
> file there as its own menu-bar item, so a stray script/PNG/README would create
> phantom icons. That's why the assets live in `assets/` and only the plugin is
> symlinked.

## The dot: size & color (SwiftBar plugin fallback)

(The Swift app draws its dot natively via StatusItemKit; this section applies
only to the retired plugin.) The dot is an **inline SF Symbol token** — the
literal `:circle.fill:` in the plugin's title *text* — colored with `sfcolor`
and sized with `sfsize=6`:

```sh
echo ":circle.fill: | sfcolor=${mv_color} sfsize=6"
```

Knobs: change `sfsize` to resize, add `valign=-1` (or similar) if it sits too
high/low.

> **Hard-won gotcha.** The `sfimage=` *parameter* ignores both `size=` and
> `sfsize=` — SwiftBar forces it to `SymbolConfiguration(scale: .large)`, i.e. a
> giant dot. Only SF Symbols written **inline** as a `:token:` in the title text
> honor `sfsize` (verified in SwiftBar's source: `symbolize()` builds the symbol
> with `SymbolConfiguration(pointSize: sfsize ?? font.pointSize, ...)`).

## Native menu opening (the AX trick — SwiftBar plugin fallback)

(The Swift app no longer uses this: its Mullvad row toggles the connection via
the CLI instead.) macOS has no API to *re-open* another app's menu-bar
dropdown, so `assets/open-native-menu.sh` simulates a click on the status item
via System Events:

```applescript
tell application "System Events" to tell process "Mullvad VPN" to click menu bar item 1 of menu bar 2
```

This needs SwiftBar granted Accessibility + Automation. **Caveat:** a native menu
anchors to its icon's on-screen position, so if Ice hides the icon off-screen the
menu can pop off-screen. Tailscale therefore uses `open -a Tailscale` instead of its
native menu; Mullvad still uses the native popover.

## The DNS watcher (separate but related — the original problem)

Connecting Mullvad while Tailscale runs broke **all** DNS (no web, no iMessage):
Tailscale's DNS proxy (`accept-dns` / CorpDNS) forwards every query to a resolver
that's unreachable through Mullvad's tunnel. The fix is a launchd watcher that
disables Tailscale `accept-dns` while Mullvad is up and restores it the moment
Mullvad disconnects — event-driven via `mullvad status listen`, no polling.

The same watcher also enforces the Mullvad/qbt-tunnel mutual exclusivity (see
Known limitations under the qBittorrent tunnel): qbt WireGuard job booted out
on Mullvad connect, bootstrapped back on disconnect.

While Mullvad is connected, MagicDNS is off and the tailnet is unreachable (Mullvad
split-tunnel can't exclude Tailscale's system network extension — tested, doesn't
work). So reaching a tailnet host means `mullvad disconnect` → do the thing →
`mullvad connect`.

## Rebuilding the icons (SwiftBar plugin fallback)

(The Swift app has no PNG assets — its dot is drawn in code.) The plugin's
menu-bar **dot** needs no rebuild — it's an SF Symbol; resize via `sfsize=`.
Only the **dropdown-row** icons are PNGs (run from the repo root):

```sh
sips -s format png -z 36 36 "/Applications/Mullvad VPN.app/Contents/Resources/icon.icns" --out assets/mullvad.png
sips -s format png -z 36 36 "/Applications/Tailscale.app/Contents/Resources/AppIcon.icns"  --out assets/tailscale.png
open "swiftbar://refreshallplugins"
```

<details><summary>Fallback: rebuilding the dot-only menu-bar PNGs (unused)</summary>

Only needed if you switch the plugin's title line back to an `image=` PNG. Resize
via the circle radius (gap between the two points, here 22−14=8px) and/or the canvas
height, keeping the dot vertically centered.

```sh
for nc in green:#30d158 orange:#ff9f0a red:#ff453a grey:#98989d; do
  n=${nc%%:*}; c=${nc##*:}
  magick -size 24x44 xc:none \
    -fill "$c" -stroke "#00000040" -strokewidth 1 -draw "circle 12,22 12,14" \
    "assets/menubar-$n.png"
done
open "swiftbar://refreshallplugins"
```

</details>

## Standalone Swift app

The repo's primary deliverable is a standalone Swift menu-bar app,
`VPNDNSMenuBar` (bundle **"VPN & DNS.app"**), built on
[StatusItemKit](https://github.com/nicholaspsmith/StatusItemKit). It polls
`mullvad`/`tailscale` every 5s, shows the colored menu-bar dot, and builds the
sectioned dropdown described under "What you see": bold section headers,
per-row status dots, top-5 fastest-city submenus, the qBittorrent section, and
click-to-toggle rows (Mullvad connection, Tailscale, accept-dns). All output
parsing, label text, and probe/staleness decisions live in a pure, unit-tested
`VPNDNSCore` library.

```sh
./scripts/build-app.sh   # build/VPN & DNS.app (stable self-signed identity if present, else ad-hoc)
open "build/VPN & DNS.app"
```

Clicking the Mullvad row toggles the connection via the `mullvad` CLI —
connect goes to Mullvad's own persisted relay selection. (The old AppleScript
AX-click that opened the native popover is gone, and with it the app's
Accessibility/Automation requirement.) The SwiftBar plugin remains in the repo
unchanged, and the launchd DNS-sync agent under `dns-watcher/` is shared.

### Start at Login

Two ways to launch it automatically (use **one**, not both, or it may start twice):

- **In-app toggle** — the menu's **Start at Login** item registers the app via
  `SMAppService` (bundle-ID based, not a LaunchAgent). macOS requires the app to
  live in `/Applications` or `~/Applications`, so point a symlink there first
  (e.g. `~/Applications/VPN & DNS.app` → `build/VPN & DNS.app`), then toggle it.
- **macOS Login Items** — add the app under System Settings → General → Login Items
  ("Open at Login"). Same effect, and it doesn't require the in-app toggle.

## qBittorrent dedicated tunnel

An always-on Mullvad WireGuard tunnel that **only qBittorrent uses**, independent
of the Mullvad app: `wireguard-go` on a pinned `utun100` with a *scoped-only*
default route (the system routing table is untouched — only sockets explicitly
bound to `utun100` use it). When the Mullvad app is connected, the tunnel's
encrypted UDP rides inside it (like multihop); when disconnected, it goes
straight out, still encrypted. Torrents survive both transitions, and every
failure mode fails **closed**: no tunnel → qBittorrent has nothing to bind →
transfers stall instead of leaking. Registers its own Mullvad device (1 of the
account's 5 slots) and pins the lowest-latency relay from a fixed list of
non-US, torrent-lenient jurisdictions.

```sh
brew install wireguard-go wireguard-tools jq   # once
# quit qBittorrent first so the binding can be written
sudo qbt-tunnel/install-qbt-tunnel.sh
```

The installer registers the device via Mullvad's API (account number read from
the local `mullvad` CLI; the private key never leaves the machine), pins a
relay, loads the `com.nicholassmith.qbt-wireguard` LaunchDaemon, installs a
single-command sudoers rule for the menu's restart action, starts the SOCKS5
proxy agent (below), and points qBittorrent at it.

### Why a SOCKS5 proxy instead of qBittorrent's own interface binding

The obvious design — set qBittorrent's "Network interface" to `utun100` — is
**broken**, and silently: qBittorrent binds and logs "Successfully listening",
but then transmits **zero bytes** through the interface. Every tracker reports
`timed out`, DHT stays at 0 nodes, no peer connection is ever attempted, and
downloads sit at `stalledDL` forever. Verified by interface byte counters: with
qBittorrent running and a forced reannounce, `utun100` carried 0 bytes out,
while an ordinary process binding *the same address and port* completed UDP
tracker announces, TCP connections, and full BitTorrent handshakes. Binding by
device name, by address, both, disabling anonymous mode, changing relays, and
disabling split tunneling all made no difference — it is libtorrent-side.

So qBittorrent no longer touches the tunnel directly. `qbt-socks5-proxy.py`
(user LaunchAgent `com.nicholassmith.qbt-socks5`) listens on `127.0.0.1:1080`
and makes every outbound connection — TCP CONNECT **and** UDP ASSOCIATE, so
UDP trackers, DHT and µTP all work — from the tunnel address. qBittorrent is
configured with that proxy for BitTorrent, RSS, and general traffic, with
hostname lookups sent through it too.

This is also **stricter** than the original design: qBittorrent now holds no
sockets on the physical interface at all (verify with
`lsof -nP -i -a -p $(pgrep -x qbittorrent)` — everything is `127.0.0.1`), and
proxying DNS closes the tracker-hostname and RSS leaks the interface-binding
design could not. Still fail-closed: the proxy binds the tunnel address per
connection, so if the tunnel drops, `bind()` fails and connections are refused.

**Manual registration fallback** (if the API flow breaks): log into mullvad.net →
WireGuard configuration → generate a config for a new device, then put its
`PrivateKey` into `/etc/wireguard-qbt/qbt.conf` under `[Interface]` (nothing
else — `Address`/`DNS`/`MTU` are wg-quick keys and break `wg setconf`), write
`/etc/wireguard-qbt/device.json` as
`{"name":"<device>","pubkey":"<pub>","ipv4_address":"10.x.y.z"}`, and run
`sudo qbt-tunnel/pin-qbt-relay.sh`.

**Operations**
- Pinned relay died → torrents stall (safe); `sudo qbt-tunnel/pin-qbt-relay.sh`
  re-probes and re-pins.
- Switch exits from the menu: **qBittorrent Exit ▸** lists the candidate cities
  (checkmark = current, confirmed via am.i.mullvad.net); picking one re-pins
  instantly, and **Re-probe & Pin Fastest** redoes the full latency sweep. Both
  run the root-owned copy at `/usr/local/libexec/qbt-tunnel/pin-qbt-relay.sh`
  passwordless via the sudoers rule. `pin-qbt-relay.sh --list` prints the
  candidates; `--city <cc-city>` pins a specific city.
- Logs: `/var/log/qbt-wireguard.log`.
- Menu row (own "qBittorrent" section; click opens qBittorrent): label states
  `via <relay>` (confirmed exit) · `tunnel up · qbt not running` ·
  `qbt not using proxy` · `tunnel down — torrents stalled (safe)`, with a
  colored dot: green = fully active, orange = path up but qbt not
  running/routed, grey = tunnel path down.
  **Restart qBittorrent Tunnel** kicks the daemon (passwordless via
  `/etc/sudoers.d/qbt-tunnel`).

**Known limitations**
- **The Mullvad app and this tunnel are mutually exclusive — and the DNS
  watcher enforces it.** While the app is connected, this tunnel still
  completes its WireGuard handshake (its gateway `10.64.0.1` pings fine) but
  the relay forwards *nothing* to the internet — `ping 1.1.1.1` through it
  gets 100% loss, TCP never connects, torrents stall. Mullvad-inside-Mullvad
  does not work, and no split-tunnel arrangement fixes it: excluding
  `wireguard-go` (so the tunnel goes direct instead of nested) doesn't help
  either. The original design assumed nesting worked "like multihop"; it does
  not. Worse, the coexistence also destabilizes **Mullvad itself**: with
  `utun100` present (even as a zombie interface after the WireGuard job dies),
  the Mullvad daemon's MTU probes black-hole and its tunnel monitor reconnects
  every 2–11 minutes (diagnosed 2026-08-03; June baseline was ~5 reconnects in
  two weeks). The `mullvad-tailscale-dns` watcher therefore boots the
  `com.nicholassmith.qbt-wireguard` job **out** when Mullvad connects and
  bootstraps it back when Mullvad disconnects (two NOPASSWD sudoers entries in
  `qbt-tunnel/qbt-tunnel.sudoers`; transitions logged to syslog under
  `mullvad-ts-dns`). Menu-initiated connects (Mullvad row, fastest-city picks)
  tear the tunnel down *before* the handshake — the watcher reacting to the
  Connecting event lands mid-handshake and stutters the connect — so the
  watcher is the safety net for connects made from the Mullvad GUI/CLI.
  Torrents pause while the Mullvad app is connected and resume by themselves
  after. Failure is safe (stalled, never leaking).
- Mullvad **split tunneling breaks interface-bound sockets** generally: it
  forces excluded apps onto the physical interface and everything else through
  its tunnel, either way overriding a `utun100` binding — so the SOCKS5 proxy
  cannot reach the tunnel while it is on. It also requires Full Disk Access, or
  the daemon refuses to connect at all.
- One static relay (no auto-failover) and a static device key (no rotation).
- The proxy is single-process Python; fine at observed rates (4.5 MB/s across
  three torrents, 100+ concurrent connections) but it is not a tuned proxy.
- Incoming connections are impossible (Mullvad has no port forwarding), so
  qBittorrent reports `firewalled` — normal, outgoing peers still work.

(The DNS and RSS leaks previously listed here are now closed — see the SOCKS5
section above.)

### Uninstall (qbt tunnel only)

```sh
launchctl bootout "gui/$(id -u)/com.nicholassmith.qbt-socks5"
rm -f ~/Library/LaunchAgents/com.nicholassmith.qbt-socks5.plist
sudo launchctl bootout system/com.nicholassmith.qbt-wireguard
sudo rm -rf /Library/LaunchDaemons/com.nicholassmith.qbt-wireguard.plist \
    /usr/local/libexec/qbt-tunnel /etc/wireguard-qbt /etc/sudoers.d/qbt-tunnel
```

Also clear qBittorrent's proxy (Preferences → Connection → Proxy → None).

Then set qBittorrent's Preferences → Advanced → Network interface back to "Any"
and delete the device on mullvad.net (frees the slot).

## Uninstall

```sh
# app (toggle Start at Login off in the menu first, or remove it from Login Items)
pkill -x VPNDNSMenuBar
rm ~/Applications/"VPN & DNS.app"

# plugin (only if wired via --swiftbar)
rm ~/.config/SwiftBar/vpn-dns-control.5s.sh

# DNS watcher (also drops the Mullvad/qbt exclusivity enforcement — if the qbt
# tunnel is installed and was booted out by a connected Mullvad, restore it with:
# sudo launchctl bootstrap system /Library/LaunchDaemons/com.nicholassmith.qbt-wireguard.plist)
launchctl bootout "gui/$(id -u)/com.nicholassmith.mullvad-tailscale-dns"
rm ~/Library/LaunchAgents/com.nicholassmith.mullvad-tailscale-dns.plist
tailscale set --accept-dns=true   # restore default

# then re-show the native icons (relaunch the apps or drag them out of Ice)
```

## License

[MIT](LICENSE)
