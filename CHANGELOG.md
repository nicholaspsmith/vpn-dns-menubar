# Changelog

Every push to `main` is a release. Before pushing, add a `## [X.Y.Z] - YYYY-MM-DD`
section at the top with `- ` entries (minor for features, patch for fixes); if an
`## [Unreleased]` section is waiting, turn it into that section. GitHub tags it
and publishes the section as the release notes; a push without one is refused.
Versions follow [Semantic Versioning](https://semver.org/). The full rule:
[StatusItemKit — Releases](https://github.com/nicholaspsmith/StatusItemKit#releases-every-push-is-one).

## [Unreleased]

- feat: rank the fastest lists by measured throughput as well as latency

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
