# vpn-dns-menubar

<p align="center"><img src="docs/mascot.png" width="160" alt="Iguanamous, VPN &amp; DNS's menu-bar character, on its app icon"></p>

<p align="center">Part of <strong><a href="https://menumon.nicksmith.software">Menumon</a></strong>.</p>

<p align="center"><img src="docs/animation.png" alt="Iguanamous licking: tongue in (left), and unwinding from the branch and wrapping it again (right)"></p>

![The VPN & DNS menu](screenshots/menu.png)

A macOS menu-bar app, **"VPN & DNS.app"**, that shows **Mullvad VPN** and
**Tailscale** as one icon with one dropdown, plus a launchd watcher that keeps
DNS working while both run at once. Hide the native Mullvad and Tailscale
menu-bar icons (System Settings ▸ Menu Bar on macOS 27) and use this one.

**Version 1.5.0** · [Changelog](https://github.com/nicholaspsmith/vpn-dns-menubar/releases)

## What you see

The icon is Iguanamous, an iguana on a branch.

![The menu-bar icon](docs/menubar-icon.png)

Each connection is one thing she does, so the icon shows every state at once:

| State | Icon |
|---|---|
| Nothing connected | Olive body, tail rolled up, tongue in |
| Tailscale running | Tail wrapped round the branch |
| Mullvad connected | Tongue wrapped round the branch ahead |
| accept-dns (MagicDNS) on | Cyan eye (same cyan as the MagicDNS row's dot) |
| Either VPN up | Green body |
| Mullvad connecting / disconnecting | Orange body |
| Mullvad blocked | Red body |

Now and then Iguanamous licks: with her tongue in, it flicks out twice; with it
wrapped round the branch, it unwinds, reels in and wraps the branch again. When
several Menumon mascots are running they take turns, a second apart:
Archimedes (Claude Usage), Menu Pimp (Mac Daddy), Carol (SoundChain), Iguanamous
(VPN & DNS), then Armonitor (Monitor Lizard), counting only the ones running.
The animation is skipped when Reduce Motion is on.

**Settings ▸ Icon ▸ Dot** swaps the iguana for a single coloured status dot;
**Settings ▸ Icon ▸ Iguana** brings her back.

## The menu

```
Mullvad - Device Name                    ← section header (this Mac's Mullvad device)
  ●  Connection — City, ST · ON          → click connects / disconnects
  Split Tunnel: On                       ▸ toggle, excluded apps, Add App…
  Fastest US (No-ID)                     ▸ top-5 cities, ✓ = current
  Fastest Non-US (No-ID · torrent-safe)  ▸
  Fastest Canada (No-ID)                 ▸
  Fastest Latin America (No-ID)          ▸
  Fastest Europe (No-ID)                 ▸
  Fastest Asia (No-ID)                   ▸
  Throughput                             ▸ Measure Throughput Now, or progress + Cancel
──────────────────────────────────────────
Tailscale                                ← section header
  ●  Connection · ON                     → click brings Tailscale up / down
  ◍  MagicDNS — accept-dns · ON          → click toggles accept-dns
  Open Tailscale App
──────────────────────────────────────────
Settings                                 ▸ Fastest Lists ▸ ranking, which lists show
                                           Icon ▸ Dot / Iguana
                                           ──────
                                           Start at Login
                                           ──────
                                           Version X.Y.Z
Quit VPN & DNS                           ⌘Q
```

The Settings submenu is StatusItemKit's shared `SettingsMenu`; the app adds
Fastest Lists and its own Icon picker above Start at Login.

Section headers and informational rows render at full contrast, never the
disabled grey.

**Status rows.** All three share one shape — coloured dot, name, detail, state
as the last word — and clicking one toggles what it describes.

- **Mullvad**: dot is green connected, orange connecting or disconnecting, red
  blocked, grey off. In-between states are named rather than forced into
  ON/OFF. Connecting uses Mullvad's own persisted relay selection.
- **Tailscale**: dot is green running, orange starting or needs-login, grey
  otherwise. The click brings the backend up or down.
- **MagicDNS**: cyan ON, grey OFF; the click runs `tailscale set --accept-dns`.
  This is a temporary override: the DNS watcher re-asserts its mapping on the
  next Mullvad connect or disconnect.

**Fastest-city submenus.** Each lists the top five cities from the candidate
pool, ranked by latency or by measured throughput. "Fastest US" and "Fastest
Non-US" split the pool in two; "Canada", "Latin America" (Mexico, Colombia,
Peru, Chile, Argentina), "Europe" (Albania, Serbia, Ukraine) and "Asia"
(Thailand, Philippines) slice the non-US half by region. Israel appears only in
Non-US. Every city in the pool qualifies under No-ID rules. Clicking a city sets
the relay location and runs `mullvad connect`; clicking the current city (✓)
disconnects. A footer shows when latency and throughput were last measured.

**Settings ▸ Fastest Lists ▸** picks **Rank by Latency** (default) or **Rank
by Throughput** and ticks which of the six submenus appear (all by default;
ticking leaves the menu open, so several can be changed at once).
Every choice persists. **Throughput ▸** starts or cancels a throughput run.

### Latency

Latency is measured with direct ICMP pings (`/sbin/ping`) when the newest
measurement is more than **12 hours** old, checked every 15 minutes and whenever
Mullvad turns off.

- Normally it runs while Mullvad is disconnected.
- If Mullvad is connected and split tunnelling is already on, the app adds
  `/sbin/ping` to the split-tunnel exclusions, verifies the exclusion took,
  pings, then removes it. The transient exclusion is hidden from the Split
  Tunnel submenu, and a startup sweep removes it if a crash left it behind.
- It never turns split tunnelling on or off itself; connected with split
  tunnelling off, it waits for the next disconnected window.

Until the first live measurement completes, the app uses seed values from
`Resources/bundle/candidates.json`. Results persist in
`~/Library/Application Support/VPNDNSMenuBar/latency.json`.

### Throughput

Throughput can only be measured by tunnelling through each relay, so a run
walks every candidate city in turn (about 21 cities, 15–20 s each, 6–7 minutes
in all). For each city it sets the relay location, waits for the tunnel to land
there, then times a download from and an upload to Cloudflare's speed-test
endpoints (`speed.cloudflare.com/__down` and `__up`): a probe (10 MB down, 2 MB
up), then a transfer sized to take about five seconds at the probed rate,
capped at Cloudflare's 90 MB per-request limit. A city whose tunnel or transfer
fails keeps its previous result. When the run finishes or you click **Cancel**,
it restores the relay constraint it found (`mullvad relay get`, including a
custom list) and reconnects or disconnects to match the starting state.

A run moves your traffic between cities and drops long-lived connections, so it
runs:

- on demand, from **Throughput ▸ Measure Throughput Now** (the row shows
  progress, e.g. "Throughput · measuring 4/21"); or
- automatically **at most once a day**, only when no run has started in the last
  24 hours, Mullvad is disconnected, and there has been no keyboard or mouse
  input for 10 minutes. The 24 hours count from a run's start, so a run where
  every city fails (an expired account, say) does not retry until the next day.

A run that has started always completes. In throughput mode rows read
`Chicago, IL — ↓ 412 ↑ 88 Mbps`, sorted by download; untested cities sort last
as `Chicago, IL — 24 ms · not tested`. Results persist in
`~/Library/Application Support/VPNDNSMenuBar/throughput.json`.

### Candidate cities

To regenerate the candidate pool (which cities qualify under No-ID rules):

```sh
scripts/refresh-candidates.sh
```

## Requirements

- macOS 13+
- Xcode Command Line Tools (Swift 5.9+) to build — `xcode-select --install`
- [Mullvad VPN](https://mullvad.net/) (CLI at `/usr/local/bin/mullvad`) and
  [Tailscale](https://tailscale.com/) (the Mac app, not the standalone CLI)

No Accessibility or Automation permission is needed.

## Install

```sh
git clone https://github.com/nicholaspsmith/vpn-dns-menubar.git
cd vpn-dns-menubar
./install.sh
```

`install.sh` is idempotent. It:

1. Builds "VPN & DNS.app" (`scripts/build-app.sh`), symlinks it into
   `~/Applications` (SMAppService needs that location; `build/` stays the
   source of truth, so rebuilds propagate), and opens it.
2. Generates the launchd plist from the template and bootstraps the DNS watcher
   (`com.nicholassmith.mullvad-tailscale-dns`).
3. Offers to turn on Start at Login (when run in a terminal), and arms the
   release `pre-push` hook.

To build and run without installing:

```sh
./scripts/build-app.sh   # → build/VPN & DNS.app (stable self-signed identity if present, else ad-hoc)
open "build/VPN & DNS.app"
```

Run the tests with `swift test`.

### Start at Login

Toggle **Settings ▸ Start at Login** in the menu, or from the shell:

```sh
"$HOME/Applications/VPN & DNS.app/Contents/MacOS/VPNDNSMenuBar" --login on   # or: off, status
```

Start at Login uses `SMAppService.mainApp`, which can only register the calling
process's own bundle, so the command must be the *installed* binary. A bare
`--login`, or `--login status`, reports the state without changing it. Don't
also add the app under System Settings ▸ General ▸ Login Items, or it may start
twice.

## How it works

The app (`VPNDNSMenuBar`) is built on
[StatusItemKit](https://github.com/nicholaspsmith/StatusItemKit). It polls
`mullvad` and `tailscale` every 5 s and rebuilds the menu each time it opens.
It only queries Tailscale while the Tailscale app is running, because the
Tailscale binary launches the app when it isn't. All output parsing, label
text, and probe/staleness decisions live in the pure, unit-tested `VPNDNSCore`
library.

### The DNS watcher

With Tailscale's `accept-dns` (CorpDNS) on, Tailscale's DNS proxy forwards every
query to a resolver that is unreachable through Mullvad's tunnel, so connecting
Mullvad breaks all DNS. The watcher, a launchd agent driven by `mullvad status
listen` (event-driven, no polling), turns `accept-dns` off while Mullvad is
connected, connecting or blocked, and back on when it disconnects.

While Mullvad is connected the tailnet is unreachable: Mullvad's split tunnel
cannot exclude Tailscale's system network extension. To reach a tailnet host,
`mullvad disconnect`, do the thing, then `mullvad connect`.

### Repo layout

| Path | Role |
|------|------|
| `Sources/VPNDNSCore/` | Pure logic: status parsing, presentation, fast cities, latency/throughput stores. |
| `Sources/VPNDNSMenuBar/` | The AppKit app: menu, icon, probes, `--login`. |
| `Tests/` | Unit tests for `VPNDNSCore`. |
| `Resources/bundle/candidates.json` | Candidate city pool with seed latencies (`scripts/refresh-candidates.sh`). |
| `scripts/build-app.sh` | Builds and signs `build/VPN & DNS.app`. |
| `dns-watcher/mullvad-tailscale-dns-sync.sh` | The DNS watcher. |
| `dns-watcher/com.nicholassmith.mullvad-tailscale-dns.plist` | LaunchAgent template (`__SCRIPT__` filled in by `install.sh`). |
| `install.sh` | Builds and links the app, loads the watcher. |

## Uninstall

```sh
# app (turn Start at Login off in the menu first)
pkill -x VPNDNSMenuBar
rm ~/Applications/"VPN & DNS.app"

# DNS watcher
launchctl bootout "gui/$(id -u)/com.nicholassmith.mullvad-tailscale-dns"
rm ~/Library/LaunchAgents/com.nicholassmith.mullvad-tailscale-dns.plist
tailscale set --accept-dns=true   # restore default

# then re-show the native icons (System Settings ▸ Menu Bar)
```

## Releasing

Every push to `main` is a release. Before pushing, add a dated
`## [X.Y.Z] - YYYY-MM-DD` section to the top of [`CHANGELOG.md`](CHANGELOG.md)
(minor for features, patch for fixes; turn a waiting `## [Unreleased]` into
it). When it reaches `main`, GitHub tags `vX.Y.Z` and publishes the section as
a release titled `vX.Y.Z`. Without a new version:

- the `pre-push` hook refuses the push;
- a pull request **cannot merge** — `release / check` is required on `main`;
- a push that reaches `main` anyway fails the release workflow.

The one exception is `[no release]` in the tip commit's message, for changes
nothing a user runs (setup, CI, developer docs): it passes every check with no
version bump and no tag. Never tag or create a release by hand, and never
`gh pr merge --admin` past a failing check — fix the PR. After merging,
`git pull` for the tag and rebuild. `install.sh` re-arms the hook on a fresh
clone. See [StatusItemKit — Releases](https://github.com/nicholaspsmith/StatusItemKit#releases-every-push-is-one)
for the full rule.

## License

Copyright (c) 2026 Nicholas Smith. Licensed under the
[Mozilla Public License 2.0](LICENSE). You may use, modify, sell and
redistribute this software, including inside proprietary products, provided
the copyright notice and license stay on these files and any modified
versions of them are made available under the same license.

## The menu-bar suite

Part of a suite of macOS menu-bar apps that share one framework, one
build-and-sign script, and one installer. They are designed to sit in the
same bar together: consistent menus, a common **Icon** picker, and cooperative
hiding so no icon strands another.

| App | What it does |
|---|---|
| [Claude Usage](https://github.com/nicholaspsmith/claude-usage-menubar) | Claude Code plan limits, resets, and live agent sessions |
| [Apollo Monitor](https://github.com/nicholaspsmith/apollo-monitor-menubar) | Apollo audio-interface monitor level |
| [Battery Time](https://github.com/nicholaspsmith/battery-time-menubar) | Time remaining, power mode, and 24h usage |
| **VPN & DNS** | An iguana for Mullvad + Tailscale state, with a DNS watcher |
| [Mac Daddy](https://github.com/nicholaspsmith/mac-daddy-menubar) | Kills media trackers, trashes stale downloads, reaps hung processes, watches the UA mixer engine, and sweats as your process count climbs |
| [KeyLight](https://github.com/nicholaspsmith/keylight-menubar) | Ctrl+brightness keys remapped to keyboard backlight |
| [Monitor Lizard](https://github.com/nicholaspsmith/monitor-lizard-menubar) | External-monitor brightness, contrast and resolution, Night Shift, and the built-in screen from dimmer than macOS allows to XDR |
| [Homestead](https://github.com/nicholaspsmith/home-assistant-menubar) | Home Assistant dashboards and device controls in the menu |
| [SoundChain](https://github.com/nicholaspsmith/soundchain-menubar) | One chain of Audio Unit effects over all system audio |
| [Menu Crane](https://github.com/nicholaspsmith/menu-crane) | A ⌘Space launcher for apps, arithmetic, unit conversions and emoji |
| [MacRecorder](https://github.com/nicholaspsmith/MacRecorder) | Screen recording with system audio |
| [Barn](https://github.com/nicholaspsmith/menubar-barn) | macOS 26 and earlier only: hides a block of status icons by width (on macOS 27, use System Settings ▸ Menu Bar) |

| Framework | |
|---|---|
| [StatusItemKit](https://github.com/nicholaspsmith/StatusItemKit) | Status-item lifecycle, polling, menus, meter and mascot icons, the shared Icon picker |
| [HotkeyKit](https://github.com/nicholaspsmith/HotkeyKit) | CGEventTap engine for intercepting and remapping global keys |

Install the whole suite on a fresh Mac with
[macOS Dev Environment Setup](https://github.com/nicholaspsmith/MacOS-Dev-Environment-Setup):

```bash
git clone https://github.com/nicholaspsmith/MacOS-Dev-Environment-Setup.git
cd MacOS-Dev-Environment-Setup && ./bootstrap.sh --all
```
