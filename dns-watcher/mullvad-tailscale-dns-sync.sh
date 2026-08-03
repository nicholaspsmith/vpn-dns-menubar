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

# The Mullvad app and the qbt WireGuard tunnel are mutually exclusive (see
# README): a live — or zombie — utun100 alongside a connected Mullvad app makes
# Mullvad's own tunnel flap (MTU probes black-hole, monitor reconnects every
# few minutes), and qbt-nested-in-Mullvad forwards nothing anyway. Enforce it:
# tunnel torn down while Mullvad is up, restored when Mullvad goes away.
# Both launchctl invocations are NOPASSWD sudoers entries (qbt-tunnel.sudoers);
# each is idempotent — the error from booting out an unloaded job (or
# bootstrapping a loaded one) is suppressed, and the log line fires only on a
# real transition.
QBT_LABEL="com.nicholassmith.qbt-wireguard"
QBT_PLIST="/Library/LaunchDaemons/$QBT_LABEL.plist"
set_qbt_tunnel() {
  want="$1"   # up | down
  [ -f "$QBT_PLIST" ] || return 0   # qbt tunnel not installed on this machine
  if [ "$want" = "down" ]; then
    /usr/bin/sudo -n /bin/launchctl bootout "system/$QBT_LABEL" 2>/dev/null \
      && /usr/bin/logger -t "$LOG_TAG" "Mullvad up -> qbt tunnel booted out"
  else
    /usr/bin/sudo -n /bin/launchctl bootstrap system "$QBT_PLIST" 2>/dev/null \
      && /usr/bin/logger -t "$LOG_TAG" "Mullvad down -> qbt tunnel bootstrapped"
  fi
}

# Map a top-level Mullvad status line to the desired Tailscale DNS state and
# qbt tunnel state.
# (Detail lines are indented, so only column-0 state words match these patterns.)
apply() {
  case "$1" in
    Connected*|Connecting*|Blocked*) set_accept_dns false; set_qbt_tunnel down ;;
    Disconnected*|Disconnecting*)    set_accept_dns true;  set_qbt_tunnel up   ;;
  esac
}

# 1) Sync to whatever state we're in right now (handles launchd start / restart).
apply "$("$MULLVAD" status 2>/dev/null | /usr/bin/head -1)"

# 2) React to every future state change (event-driven; no polling).
"$MULLVAD" status listen 2>/dev/null | while IFS= read -r line; do
  apply "$line"
done
