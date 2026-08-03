# Menu Readability — Header/Info Styling + Fast-Cities Submenus

**Date:** 2026-08-02
**Status:** Approved (design); pending implementation plan
**Component:** `vpn-dns-menubar` (Swift, StatusItemKit)

## Overview

Two readability changes to the VPN & DNS menu, both confined to menu construction
in the app target (`Sources/VPNDNSMenuBar/main.swift`):

1. **Restyle non-clickable items.** Today every non-clickable row is a plain
   disabled `NSMenuItem`, which AppKit renders in faint gray that is hard to read.
   Group headers get the native macOS section-header look; status/info rows get
   full-contrast text while remaining non-clickable.
2. **Collapse the fast-cities sections into submenus.** The "Fastest US (No-ID)"
   and "Fastest Non-US (No-ID · torrent-safe)" sections currently list their three
   city rows inline in the top-level menu. Each section becomes one top-level item
   with a submenu.

## Goals

- Non-clickable text is legible in both light and dark mode.
- Headers and informational rows are visually distinct from clickable actions.
- A shorter top-level menu: six inline fast-cities rows (2 headers + up to 6
  cities + footer) collapse to two submenu items.

## Non-Goals

- No changes to `VPNDNSCore` — all label *text* logic (`fastCitiesMenu`,
  `MenuSection`, row titles, freshness footer) stays where it is, already tested.
- No changes to dot/status behavior, polling, or any command execution.
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

None new — the change is presentation-only. Menu construction has no failure
modes beyond what exists today.

## Testing

- No new unit tests: `VPNDNSCore` is untouched, and the changed code is AppKit
  menu construction in the app target, which has no test harness (consistent
  with the rest of `main.swift`).
- Manual verification: rebuild, open the menu in light and dark mode, confirm
  headers render as native section headers, info rows read at full contrast and
  don't highlight, both fast-cities submenus list cities with the checkmark on
  the current city, and clicking a city still toggles the VPN.
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
