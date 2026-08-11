#!/bin/zsh
# mullvad-tailscale-dns-sync
#
# WHY THIS EXISTS:
# Tailscale's DNS proxy ("accept-dns" / CorpDNS) intercepts ALL DNS queries and
# forwards them to Tailscale's resolver. While the Mullvad VPN is connected, that
# resolver is unreachable through Mullvad's tunnel, so EVERY DNS lookup fails ->
# no websites load (Arc) and iMessage can't reach Apple's servers.
#
# FIX: disable Tailscale accept-dns while Mullvad is up, and restore it the moment
# Mullvad disconnects (so MagicDNS / the tailnet keep working normally). This watcher
# reacts to Mullvad connection-state changes for BOTH the GUI app and the CLI.
#
# Managed by launchd: com.nicholassmith.mullvad-tailscale-dns (see ../install.sh).
# To remove: launchctl bootout gui/$(id -u)/com.nicholassmith.mullvad-tailscale-dns
#            rm ~/Library/LaunchAgents/com.nicholassmith.mullvad-tailscale-dns.plist
#            tailscale set --accept-dns=true   # restore default
# (full uninstall steps are in the repo README)

TS=/Applications/Tailscale.app/Contents/MacOS/Tailscale
MULLVAD=/usr/local/bin/mullvad
LOG_TAG=mullvad-ts-dns

set_accept_dns() {
  want="$1"   # true | false
  cur=$("$TS" debug prefs 2>/dev/null | /usr/bin/awk -F'[:,]' '/"CorpDNS"/{gsub(/[ \t"]/,"",$2);print $2; exit}')
  if [ "$cur" != "$want" ]; then
    "$TS" set --accept-dns="$want" >/dev/null 2>&1
    /usr/bin/logger -t "$LOG_TAG" "Mullvad state change -> accept-dns=$want (was CorpDNS=$cur)"
  fi
}

# Map a top-level Mullvad status line to the desired Tailscale DNS state.
# (Detail lines are indented, so only column-0 state words match these patterns.)
apply() {
  case "$1" in
    Connected*|Connecting*|Blocked*) set_accept_dns false ;;
    Disconnected*|Disconnecting*)    set_accept_dns true  ;;
  esac
}

# 1) Sync to whatever state we're in right now (handles launchd start / restart).
apply "$("$MULLVAD" status 2>/dev/null | /usr/bin/head -1)"

# 2) React to every future state change (event-driven; no polling).
"$MULLVAD" status listen 2>/dev/null | while IFS= read -r line; do
  apply "$line"
done
