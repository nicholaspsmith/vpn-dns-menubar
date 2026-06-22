#!/bin/zsh
# Opens the NATIVE Mullvad or Tailscale menu-bar dropdown by simulating a click
# on its status item via the Accessibility API. Called by the SwiftBar plugin.
#
# Requires: SwiftBar (the caller) granted Accessibility + Automation permission,
# AND the target app's menu-bar icon to be reachable on screen (a native menu
# anchors to its icon's position).
case "$1" in
  mullvad)   proc="Mullvad VPN" ;;
  tailscale) proc="Tailscale" ;;
  *) echo "usage: $0 mullvad|tailscale" >&2; exit 1 ;;
esac
/usr/bin/osascript -e "tell application \"System Events\" to tell process \"$proc\" to click menu bar item 1 of menu bar 2"
