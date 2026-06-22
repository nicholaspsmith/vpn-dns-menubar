# vpn-dns-menubar

One macOS menu-bar icon that consolidates **Mullvad VPN** and **Tailscale** into a
single status dot, with a click-through dropdown to each app — plus a small launchd
watcher that keeps DNS working when both run at once.

It's a [SwiftBar](https://github.com/swiftbar/SwiftBar) plugin. Hide the two native
Mullvad/Tailscale menu-bar icons (e.g. with [Ice](https://github.com/jordanbaird/Ice))
and let this be the only one.

## What you see

The menu bar shows **one icon**: a single status dot that tracks Mullvad:

🟢 connected · 🟠 connecting/disconnecting · 🔴 blocked · ⚪ off

Clicking it opens a dropdown:

```
●                                    ← the menu-bar title (status dot)
──────────────────────────────────────
accept-dns (MagicDNS): ON/OFF        (non-clickable status)
──────────────────────────────────────
Mullvad: Connected — us-bos-wg-001   → click opens the NATIVE Mullvad menu
Tailscale: Running                   → click opens the Tailscale app
```

The two bottom rows' **labels are the live status**, and clicking them acts: Mullvad
opens its real popover (location picker, etc.); Tailscale opens its app. Text is
green when connected/running and grey when off/stopped.

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
