# Menu Readability + Latency Freshness

**Date:** 2026-08-02 (updated 2026-08-03)
**Status:** Approved (design); pending implementation plan
**Component:** `vpn-dns-menubar` (Swift, StatusItemKit)

## Overview

Four changes to the VPN & DNS menu and its latency plumbing:

1. **Restyle non-clickable items.** Today every non-clickable row is a plain
   disabled `NSMenuItem`, which AppKit renders in faint gray that is hard to read.
   Group headers get the native macOS section-header look; status/info rows get
   full-contrast text while remaining non-clickable.
2. **Collapse the fast-cities sections into submenus.** The "Fastest US (No-ID)"
   and "Fastest Non-US (No-ID · torrent-safe)" sections currently list their
   city rows inline in the top-level menu. Each section becomes one top-level item
   with a submenu.
3. **Top 5 cities per section** instead of top 3.
4. **12-hour freshness policy.** Replace "probe every 15 min while Mullvad is
   off" with one rule: probe only when the newest direct measurement is missing
   or older than 12 hours — and when Mullvad is connected, probe anyway via a
   split-tunnel-excluded `/sbin/ping`, but only if split tunneling is already on.

## Goals

- Non-clickable text is legible in both light and dark mode.
- Headers and informational rows are visually distinct from clickable actions.
- A shorter top-level menu: the inline fast-cities rows (2 headers + cities +
  footer) collapse to two submenu items.
- Latency rankings at most ~12 hours stale whenever the tunnel is down at some
  point in that window **or** split tunneling is on while connected — without
  the constant ping bursts of the current 15-minute cadence.

## Non-Goals

- No change to what "direct" means: through-tunnel (non-excluded) measurements
  are never recorded. Ranking honesty is preserved.
- Never auto-enable split tunneling (or flip any user-visible Mullvad state) for
  a probe. With Mullvad connected and split tunneling off, probing just waits.
- No changes to dot/status behavior or the qBittorrent tunnel.
- No view-based (custom `NSView`) menu items.

## Design

### Two styling helpers

Both are small private helpers in `main.swift`, replacing the repeated
"create item, `isEnabled = false`" pattern:

- **`headerItem(_ title:)`** — on macOS 14+ returns
  `NSMenuItem.sectionHeader(title:)` (the system's native small/bold section
  header). Behind `#available(macOS 14, *)`; the fallback for the package's
  macOS 13 floor is a disabled item with an `attributedTitle` in small bold
  system font, `secondaryLabelColor`.
  Used for: "Mullvad", "Tailscale" (top-level groups) and the
  "Excluded from VPN — click to remove" header in the Split Tunnel submenu.
- **`infoItem(_ title:)`** — a disabled item whose `attributedTitle` uses the
  standard menu font at full `labelColor`, so it reads at normal contrast but
  never highlights and takes no click.
  Used for: the qBittorrent tunnel status row, the Accept DNS row, the
  "Loading candidates…" placeholder in the qBittorrent Exit submenu, and the
  freshness footer (relocated, below).

Colors are semantic (`labelColor` / `secondaryLabelColor`), so light and dark
mode both work without further handling. Disabled items do not highlight on
hover, which keeps full-contrast info rows distinguishable from actions.

### Fast-cities submenus

`addFastSection` (inline header + rows) is replaced by a submenu builder:

- One top-level item per non-empty section, titled with the section header
  from core ("Fastest US (No-ID)", "Fastest Non-US (No-ID · torrent-safe)").
- The submenu holds the section's city rows unchanged: same titles, same
  checkmark-on-current-city (`state = .on`), same `toggleCity(_:)` action and
  `representedObject`.
- A section with no rows is skipped entirely (no empty submenu), as today.
- The freshness footer ("measured 5m ago (direct)") moves from the top level
  into **each** submenu: separator, then an info row at the bottom. At top
  level it would sit orphaned with no city rows next to it; the duplication is
  the price of keeping each dropdown self-contained.
- No checkmark on the parent items — the "Mullvad: Connected (…)" row already
  shows where you're connected.
- `fastCitiesMenu`'s `topN` default changes 3 → 5 in `VPNDNSCore`; existing
  tests that assume 3 are updated.

### 12-hour freshness policy

One rule replaces the unconditional 15-minute probing: **probe iff the newest
direct measurement is missing or older than 12 hours.** The rule is evaluated
on the existing 15-minute timer tick and on Mullvad-off transitions. When
stale, the probe method depends on current state:

| Mullvad | Split tunneling | Action |
|---------|-----------------|--------|
| off     | (any)           | plain direct probe, exactly as today |
| on      | on              | probe via split-tunnel-excluded `/sbin/ping` |
| on      | off             | skip; retry next tick (waits for an off-window) |

Two pure functions in `VPNDNSCore` carry the logic, unit-tested:

- `isLatencyStale(last: Date?, now: Date, maxAge: TimeInterval)` — nil or
  older than `maxAge` (12 h).
- `probeDecision(stale: Bool, mullvadOff: Bool, splitTunnelOn: Bool)` →
  `.probeDirect` / `.probeViaSplitTunnel` / `.skip`.

`LatencyProbe` in the app target consumes the decision; the ping fan-out,
concurrency gate, and parse logic are unchanged.

### Connected probe via split-tunnel exclusion

When the decision is `.probeViaSplitTunnel` (Mullvad connected, split
tunneling already on — never enabled by us):

1. `mullvad split-tunnel app add /sbin/ping`; on error, abort and skip.
2. Verify it took: `mullvad split-tunnel get` shows state on **and**
   `/sbin/ping` listed (reuses `parseSplitTunnel`). Excluded processes bypass
   the tunnel, so these pings are genuinely direct → recorded `direct: true`.
3. Run the normal ping fan-out.
4. At commit time, re-check `split-tunnel get` (state still on, ping still
   listed) — the same rigor as today's commit-time `isOff()` re-check. If the
   user toggled split tunneling off mid-probe, results are discarded.
5. `mullvad split-tunnel app remove /sbin/ping` (always, including on the
   discard paths).

### Safety & cleanup

- `/sbin/ping` is removed from exclusions right after every connected probe.
- On app startup, `/sbin/ping` is removed from the exclusion list if present
  (leftover from a crash mid-probe), so it can never linger.
- The Split Tunnel submenu filters `/sbin/ping` out of the displayed excluded
  apps — it is the app's transient plumbing, not a user exclusion.
- Failure worst case (e.g. Mullvad refuses the path): connected probes never
  run, and freshness degrades to off-window-only — today's behavior.

### Resulting top-level menu

```
Mullvad                        ← native section header
  Mullvad: Connected (Denver)
  Split Tunnel                ▸
  Fastest US (No-ID)          ▸
  Fastest Non-US (No-ID · …)  ▸
  qBittorrent Tunnel: OK       ← full-contrast info row
  Restart qBittorrent Tunnel
  qBittorrent Exit            ▸
─────────────────────────────
Tailscale                      ← native section header
  Tailscale: Connected
  Tailscale: Disconnect
  Accept DNS: On               ← full-contrast info row
─────────────────────────────
Start at Login
─────────────────────────────
Quit
```

## Error Handling

- Styling/submenu changes are presentation-only — no new failure modes.
- Connected probe: `app add` failure aborts the probe (skip, retry next
  tick); a mid-probe split-tunnel change is caught by the commit-time
  re-check and the results discarded; `app remove` runs on every exit path,
  with startup cleanup as the crash backstop.

## Testing

- New `VPNDNSCore` unit tests: `isLatencyStale` boundaries, the
  `probeDecision` truth table, `topN` = 5 defaults, and `/sbin/ping`
  filtering in the split-tunnel display list.
- The AppKit menu construction and the CLI calls in the app target stay
  untested, consistent with the rest of `main.swift`.
- **First implementation task is a manual spike** (~2 min): on this Mac, with
  Mullvad connected and split tunneling on, verify that an excluded
  `/sbin/ping` really reaches a relay outside the tunnel (RTT sanity +
  `mullvad split-tunnel get`). The whole connected-probe design rests on
  this; learn it before building on it.
- Manual verification after build: menu in light and dark mode — native
  section headers, full-contrast info rows that don't highlight, two
  fast-cities submenus with 5 cities each, checkmark on the current city,
  city click still toggles the VPN, footer at the bottom of each submenu.
- Rebuild propagates through the existing `~/Applications/VPN & DNS.app`
  symlink; no re-signing concerns beyond the normal `make-app.sh` flow.

## Alternatives Considered

- **Emulated headers everywhere** (attributed titles, no availability check):
  consistent across macOS versions but hand-rolls what the OS provides and
  drifts from native metrics. Rejected in favor of native
  `sectionHeader(title:)` with the emulated style as the macOS 13 fallback.
- **View-based menu items**: full styling control, but heavyweight and loses
  standard menu metrics/behavior. Rejected.
- **Footer once at top level, below both submenus**: avoids duplication but
  leaves the freshness line orphaned away from the rows it describes. Rejected.
- **Keep 15-min probing while off** (12 h rule only for connected): two
  cadences to reason about, and ~95 pings every 15 min for data that shifts
  little within a day. Rejected for the single staleness rule.
- **Auto-enable split tunneling for connected probes**: guarantees ≤12 h
  freshness unconditionally, but briefly activates the user's whole exclusion
  list (13 apps bypassing the VPN) and flips user-visible state. Rejected by
  the user.
- **Interface-bound ping (`ping -b en0`) instead of split tunnel**: Mullvad's
  firewall blocks non-tunnel traffic while connected, so bound pings would be
  dropped or, worse, silently unreliable. Rejected.

## Execution Amendments (2026-08-03)

What was actually built diverges from the design above in these ways, all
user-directed during execution:

- **Native `sectionHeader(title:)` rejected in practice.** Its fixed
  small/muted rendering reproduced the original hard-to-read problem. Headers
  are instead bold at normal menu size in a max-contrast dynamic color (pure
  black/white — `labelColor`'s ~85% alpha still read washed-out). The
  macOS 13/14 availability split is gone; one code path everywhere.
- **qBittorrent got its own menu section** (was inside the Mullvad group),
  its status row is clickable (opens qBittorrent) and carries a colored dot:
  grey = tunnel path down, orange = path up but qbt not running/routed,
  green = fully active (`qbtDotColor` in core). Label glyphs (○ ● ◐) dropped.
- **accept-dns row**: moved to the top of the Tailscale section, carries a
  green/grey dot (`acceptDNSDotColor`), and is clickable — toggles
  `tailscale set --accept-dns`. A manual toggle is a temporary override; the
  event-driven DNS watcher re-asserts its mapping on the next Mullvad
  connect/disconnect.
- **Mullvad status row** carries a dot too, reusing the existing
  `dotColor(for:)` menu-bar mapping (green/orange/red/grey).
- **Launch-time probe evaluation** waits for the first poll to commit real
  Mullvad/split-tunnel state (a `firstPollCommitted` trigger in `poll()`):
  the evaluation in `start()` ran against init defaults and always skipped,
  which would have delayed a launch probe by up to 15 minutes.

## Spike Result (2026-08-03) — PASS

Target: us-was relay 185.213.193.3 (seed 24 ms). Direct reference (tunnel
down): min 37.5 ms (jittery). Connected via ca-mtr (Montreal), through-tunnel
baseline: min 66.3 ms (+29 ms detour via exit). With split tunneling on and
`mullvad split-tunnel app add /sbin/ping`: min 25.5 ms, stddev 0.3 ms — right
at the seed value, nothing like the tunnel path. `app add /sbin/ping` is
accepted by the CLI, the exclusion takes effect immediately for new ping
processes, and `split-tunnel get` reports it for verification. The
connected-probe design is sound. State restored after (disconnected, split
tunneling off, ping removed).
