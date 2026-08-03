# vpn-dns-menubar

One macOS menu-bar icon that consolidates **Mullvad VPN** and **Tailscale** into a
single status dot, with a click-through dropdown to each app — plus a small launchd
watcher that keeps DNS working when both run at once.

It's a [SwiftBar](https://github.com/swiftbar/SwiftBar) plugin. Hide the two native
Mullvad/Tailscale menu-bar icons (e.g. with [Ice](https://github.com/jordanbaird/Ice))
and let this be the only one.

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
  ●  Connected — Denver, CO               → click opens the NATIVE Mullvad menu
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
connecting/disconnecting · red blocked · grey off); the qBittorrent row is grey
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

- macOS 11+ (the dot uses an SF Symbol)
- [SwiftBar](https://github.com/swiftbar/SwiftBar) — `brew install --cask swiftbar`
- [Mullvad VPN](https://mullvad.net/) (CLI at `/usr/local/bin/mullvad`) and
  [Tailscale](https://tailscale.com/) (the Mac app, not the standalone CLI)
- Optional: [Ice](https://github.com/jordanbaird/Ice) to hide the native icons;
  ImageMagick (`brew install imagemagick`) only if you rebuild the fallback PNGs

## Install

```sh
git clone https://github.com/nicholaspsmith/vpn-dns-menubar.git
cd vpn-dns-menubar
./install.sh
```

`install.sh` is idempotent and:

1. **Symlinks** `vpn-dns-control.5s.sh` into `~/.config/SwiftBar/` (override the
   target with `SWIFTBAR_PLUGIN_DIR`). The repo stays the source of truth — the
   plugin finds its `assets/` via its own real path, so nothing else is copied.
2. Generates the launchd plist from the template and **bootstraps the DNS-sync
   agent** (`com.nicholassmith.mullvad-tailscale-dns`).
3. Refreshes SwiftBar.

Then grant **SwiftBar** Accessibility + Automation permission (System Settings →
Privacy & Security) so the Mullvad row can open the native popover, and hide the
native Mullvad/Tailscale icons.

## Repo layout

| Path | Role |
|------|------|
| `vpn-dns-control.5s.sh` | **The plugin.** Symlinked into SwiftBar's plugin dir; refresh interval (`.5s.`) is in the filename. |
| `assets/open-native-menu.sh` | Helper: `… mullvad\|tailscale` → AX-clicks the app's menu-bar item to open its native menu. |
| `assets/mullvad.png`, `tailscale.png` | App icons shown on the dropdown rows. |
| `assets/menubar-{green,orange,red,grey}.png` | Dot-only icons (24×44, 16px dot). **Unused fallback** — the bar is now an SF Symbol; kept in case the PNG route is wanted again. |
| `dns-watcher/mullvad-tailscale-dns-sync.sh` | The launchd watcher (driven by `mullvad status listen`). |
| `dns-watcher/com.nicholassmith.mullvad-tailscale-dns.plist` | LaunchAgent template (`__SCRIPT__` filled in by `install.sh`). |
| `install.sh` | Symlink the plugin + load the agent. |

> ⚠️ **Only the plugin may live in SwiftBar's plugin dir.** SwiftBar loads *every*
> file there as its own menu-bar item, so a stray script/PNG/README would create
> phantom icons. That's why the assets live in `assets/` and only the plugin is
> symlinked.

## The dot: size & color

The dot is an **inline SF Symbol token** — the literal `:circle.fill:` in the
plugin's title *text* — colored with `sfcolor` and sized with `sfsize=6`:

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

## Native menu opening (the AX trick)

macOS has no API to *re-open* another app's menu-bar dropdown, so
`assets/open-native-menu.sh` simulates a click on the status item via System Events:

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

While Mullvad is connected, MagicDNS is off and the tailnet is unreachable (Mullvad
split-tunnel can't exclude Tailscale's system network extension — tested, doesn't
work). So reaching a tailnet host means `mullvad disconnect` → do the thing →
`mullvad connect`.

## Rebuilding the icons

The menu-bar **dot** needs no rebuild — it's an SF Symbol; resize via `sfsize=`.
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

The repo also ships a standalone Swift menu-bar app, `VPNDNSMenuBar`
(bundle **"VPN & DNS.app"**), built on
[StatusItemKit](https://github.com/nicholaspsmith/StatusItemKit). It's a
native AppKit reimplementation of the SwiftBar plugin: it polls
`mullvad`/`tailscale` every 5s, shows a colored status dot tracking Mullvad
state, and drops down a three-row menu (accept-dns/MagicDNS state, a Mullvad
row, and a Tailscale row) plus Start at Login and Quit. All output parsing
lives in a pure, unit-tested `VPNDNSCore` library.

```sh
./scripts/build-app.sh          # produces build/VPN & DNS.app (ad-hoc signed)
open "build/VPN & DNS.app"
```

Clicking the Mullvad row opens Mullvad's native popover via an AppleScript
AX-click, so the app needs **Accessibility + Automation** permission granted
to "VPN & DNS" (you'll be prompted on first use). The SwiftBar plugin remains
available and unchanged, and the launchd DNS-sync agent under `dns-watcher/`
is shared and untouched.

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
- **The Mullvad app and this tunnel are mutually exclusive.** While the app is
  connected, this tunnel still completes its WireGuard handshake (its gateway
  `10.64.0.1` pings fine) but the relay forwards *nothing* to the internet —
  `ping 1.1.1.1` through it gets 100% loss, TCP never connects, torrents stall.
  Mullvad-inside-Mullvad does not work, and no split-tunnel arrangement fixes
  it: excluding `wireguard-go` (so the tunnel goes direct instead of nested)
  doesn't help either. The original design assumed nesting worked "like
  multihop"; it does not. So: **run the Mullvad app disconnected while
  torrenting.** Failure is safe (stalled, never leaking), just not obvious.
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
# plugin
rm ~/.config/SwiftBar/vpn-dns-control.5s.sh

# DNS watcher
launchctl bootout "gui/$(id -u)/com.nicholassmith.mullvad-tailscale-dns"
rm ~/Library/LaunchAgents/com.nicholassmith.mullvad-tailscale-dns.plist
tailscale set --accept-dns=true   # restore default

# then re-show the native icons (relaunch the apps or drag them out of Ice)
```

## License

[MIT](LICENSE)
