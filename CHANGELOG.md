# Changelog

Every push to `main` is a release. Before pushing, add a `## [X.Y.Z] - YYYY-MM-DD`
section at the top with `- ` entries (minor for features, patch for fixes); if an
`## [Unreleased]` section is waiting, turn it into that section. GitHub tags it
and publishes the section as the release notes; a push or pull request
without one is refused (`[no release]` in the tip commit is the only exception).
Versions follow [Semantic Versioning](https://semver.org/). The full rule:
[StatusItemKit — Releases](https://github.com/nicholaspsmith/StatusItemKit#releases-every-push-is-one).

## [1.7.0] - 2026-10-07

- No user-visible changes.

## [1.6.0] - 2026-10-07

- Latency and throughput are now measured only when you ask: a new **Measure** submenu holds Measure Latency Now and Measure Throughput Now. The app no longer pings relays on its own (every 12 hours, at launch, or when Mullvad turned off) and no longer runs the daily throughput test that hopped your connection between cities while you were away
- Measure Latency Now is greyed out, with the reason, while Mullvad is connected and split tunnelling is off, since pings would then time the tunnel instead of the relays

## [1.5.4] - 2026-10-07

- The app icon matches Iguanamous as he is now drawn in the menu bar

## [1.5.3] - 2026-10-06

- The DNS watcher no longer flips Tailscale's DNS on and off several times a second: on each Mullvad event it reads Mullvad's current state instead of trusting the event, so `*.ts.net` names keep resolving while Mullvad is disconnected

## [1.5.2] - 2026-10-06

- Ticking a checkbox in the menu no longer closes it: Settings ▸ Fastest Lists' list toggles stay open so you can tick several in a row

## [1.5.1] - 2026-10-05

- New app icon: Iguanamous as she looks in the menu bar

## [1.5.0] - 2026-10-05

- feat: a Settings submenu at the foot of the menu holds Fastest Lists (ranking and which lists show) and the Icon picker, along with Start at Login and the version, the same Settings submenu every Menumon app now has. Quit stays below it
- The throughput run has its own top-level **Throughput** row (Measure Throughput Now, or progress and Cancel while a run is going)

## [1.4.0] - 2026-10-05

- The menu-bar mascot is now Iguanamous, an iguana. Everything it shows is unchanged: the tail wraps the branch for Tailscale, the tongue wraps it for Mullvad, the eye turns cyan for accept-dns, and the body colour follows the connection
- New app icon to match
- Icon ▸ Chameleon is now Icon ▸ Iguana; your choice of icon carries over

## [1.3.0] - 2026-10-03

- The automatic throughput test now runs at most once a day (or when you pick Measure Throughput Now), instead of every 15 minutes whenever the last attempt recorded nothing. With an expired Mullvad account every attempt failed, so the app kept connecting you, failing, and leaving the connection blocked

## [1.2.0] - 2026-10-02

- feat: once a minute Caveepyan licks: her tongue flicks at the air, or unwinds from the branch, reels in and wraps it again, in turn with the other animated Menumon mascots
- Mascot renamed: the chameleon is Caveepyan

## [1.1.2] - 2026-09-28

- The README's menu screenshot and example menu no longer show a Mullvad device name, relay city or IP address

## [1.1.1] - 2026-09-28

- `install.sh` now asks whether to turn on Start at Login (skipped when it is already on, or when there is no terminal to ask in) instead of turning it on unasked, then relaunches the app, quitting any running copy first so the new build takes over

## [1.1.0] - 2026-09-26

### Fastest lists by throughput

- Fastest Lists can now rank cities by measured throughput as well as latency ("Rank by Latency" / "Rank by Throughput").
- "Measure Throughput Now" tunnels through every candidate city, times Cloudflare speed-test downloads, then puts your previous relay choice and connection back the way they were.
- The measurement also runs on its own when results are more than 7 days old, while Mullvad is off and you're away from the Mac.

## [1.0.0] - 2026-09-23

- feat: the menu shows the version it was built from
- LICENSE: name the copyright holder above the MPL text
- License: Mozilla Public License 2.0
- feat: the accept-dns row's dot matches the eye
- docs: re-render the states strip for the longer chameleon
- docs: re-render the states strip for the new body
- feat: the three status rows become one row, three times
- docs: re-render the states strip for the crest
- docs: the resting chameleon is olive now
- feat: the eye shows accept-dns, and the README describes the new signals
- docs: the chameleon's new states strip
- docs: document the --login flag
- feat: --login on|off|status, and register Start at Login on install
- feat: regional fastest lists (Canada, Latin America, Europe, Asia) with a Fastest Lists show/hide menu
- docs: green chameleon states
- docs: the hard hat
- feat: chameleon colours itself by connection — spots and curled tail for Tailscale, yellow and tongue for Mullvad
- docs: Curtain is now Barn
- docs: Apollo Monitor described without the vendor name
- docs: drop instructions that assume other software the reader may not use
- docs: no Ice-specific instructions
- docs: the character menu-bar icon, rendered from code, and what its states mean
- feat: chameleon shows its tail for Tailscale and its tongue for Mullvad
- feat: chameleon grows one tail per live connection (Mullvad, Tailscale)
- feat: chameleon icon that takes the status colour (Icon ▸ Chameleon, default; Dot still available)
- feat: app icon from the Menubarn mascot
- docs: mention the Menubarn widget library
- docs: why a standalone app beats a SwiftBar plugin
- docs: add the Menubarn mascot to the README
- Fix Tailscale "Status: Unknown": inject TERM into every Tailscale CLI call
- Advertise the menu-bar suite, and add a menu screenshot
- feat: yield the status item during a curtain peek
- feat: show the registered Mullvad device in the menu header
- feat: parse the Mullvad device name from `mullvad account get`
- docs: remove the qBittorrent tunnel from the repo and docs
- refactor: remove the qBittorrent tunnel from the menu app
- docs: implementation plan for qbt removal + device name header
- fix: watcher no longer resurrects the qbt tunnel
- docs: record qbt teardown, add device name to Mullvad header
- docs: spec for removing the qBittorrent dedicated tunnel
- fix: tear qbt tunnel down before mullvad connect, not during
- feat: install.sh installs the Swift app first; SwiftBar behind --swiftbar
- docs: align README, watcher header, install.sh with shipped behavior
- fix: DNS watcher enforces Mullvad/qbt-tunnel mutual exclusivity
- feat: Mullvad row click toggles the connection
- docs: README + spec — sections/dots, top-5 submenus, 12h freshness
- feat: status dot on the Mullvad row (reuses the menu-bar dot mapping)
- feat: 12h latency freshness; connected probes via split-tunnel exclusion
- docs: spike result — split-tunnel-excluded ping verified (PASS)
- feat: accept-dns row — status dot, click-to-toggle, first in Tailscale section
- feat: qBittorrent gets its own menu section with a colored status dot
- feat: startup cleanup of probe exclusion + filtered split-tunnel display
- feat: fast-cities sections become submenus with footer inside
- feat: bold max-contrast section headers + full-contrast info rows in menu
- feat: hide the probe's transient /sbin/ping exclusion from display
- feat: staleness check + probe decision for 12h freshness policy
- feat: top-5 fastest cities per section (was top-3)
- docs: implementation plan — menu readability + latency freshness
- docs: top-5 cities + 12h freshness policy in menu readability design
- docs: menu readability design — native headers, info rows, city submenus
- docs: the Mullvad app and this tunnel are mutually exclusive
- docs: bring the design spec in line with what was actually built
- fix: stop claiming 10.64.0.1, which broke the system Mullvad app
- fix: route qBittorrent through a tunnel-bound SOCKS5 proxy
- fix: retry launchd bootstrap after async bootout (I/O error 5 race)
- feat: qBittorrent exit switcher submenu (city re-pin + full re-probe)
- feat: group dropdown into Mullvad and Tailscale sections
- feat: split-tunnel submenu — toggle, excluded-app list, Add App picker
- docs: qBittorrent dedicated tunnel section
- feat: qBittorrent tunnel status row + restart action in menu
- feat: qbt tunnel installer, sudoers rule, install.sh pointer
- feat: latency-probed relay pinning for the qbt tunnel
- feat: one-time Mullvad device registration for the qbt tunnel
- feat: qbt tunnel daemon script + LaunchDaemon plist (pinned utun100, scoped route)
- feat: QbtTunnelStatus parsers, state derivation, row labels
- plan: qbt dedicated tunnel implementation plan (8 tasks)
- spec: dedicated always-on Mullvad WireGuard tunnel for qBittorrent + menu row
- Don't relaunch the Tailscale GUI from the status poll
- Run poll() off the main thread so a slow CLI can't freeze the menu
- fix: probe keeps last-good on failed ping; city toggle off main thread
- feat: Tailscale on/off toggle menu item
- docs: add Task 8 (Tailscale toggle) to plan
- fix: make probe off-state access thread-safe; main-confine running flag
- feat: fastest No-ID city sections with toggle + latency probe
- fix: refresh-candidates.sh aborts instead of writing short-count JSON
- feat: refresh-candidates.sh to regenerate candidates.json
- feat: fastCitiesMenu model + freshness text
- feat: LatencyStore — ranking + persistence
- feat: city toggle + current-city helpers
- feat: candidate pool model + loader + candidates.json
- feat: parsePingMinRTT — read min RTT from ping output
- docs: spec + plan for fastest No-ID city menu sections
- docs: document Start at Login options in the README
- feat: dot turns blue when Tailscale is running
- docs: note the standalone Swift app
- feat: VPNDNSMenuBar app (dot, 3-row menu, polling)
- feat: VPN presentation model (colors + row labels)
- feat: Tailscale BackendState + CorpDNS parsing
- feat: package skeleton + Mullvad status parsing
- docs: add Swift app implementation plan
- docs: add menu-bar dot states (connected/connecting/blocked/off) to README
- feat: consolidated Mullvad + Tailscale SwiftBar menu-bar icon + DNS watcher
