#!/bin/zsh
# <bitbar.title>VPN &amp; DNS Control</bitbar.title>
# <bitbar.version>v1.0</bitbar.version>
# <bitbar.author>Claude Code</bitbar.author>
# <bitbar.desc>One menu-bar icon consolidating Mullvad VPN + Tailscale, with live accept-dns status.</bitbar.desc>
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideLastUpdated>true</swiftbar.hideLastUpdated>
# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>
# <swiftbar.hideSwiftBar>true</swiftbar.hideSwiftBar>
#
# Consolidated Mullvad + Tailscale menu-bar control. The two native icons are
# hidden by Ice; this plugin is the single visible icon. The bar shows just a
# status dot tracking the Mullvad connection; clicking opens the dropdown below.
# See the repo README.md for the full design + removal steps.
#
# Refresh interval is encoded in the filename (.5s. = every 5 seconds).

MULLVAD=/usr/local/bin/mullvad
TS=/Applications/Tailscale.app/Contents/MacOS/Tailscale
OPEN=/usr/bin/open
# Assets live in ./assets next to this script. SwiftBar runs the plugin via a
# symlink in its plugin dir, so resolve THIS file's real path (:A) and take its
# dir (:h) -- that lands us in the repo regardless of where the symlink lives.
# (Assets must stay out of SwiftBar's plugin dir, else each loads as its own icon.)
SELF="${(%):-%x}"
DIR="${SELF:A:h}/assets"

# ---------------------------------------------------------------- gather state
mv_status="$("$MULLVAD" status 2>/dev/null)"
mv_state="$(print -r -- "$mv_status" | /usr/bin/head -1 | /usr/bin/awk '{print $1}')"
mv_relay="$(print -r -- "$mv_status" | /usr/bin/awk -F': *' '/Relay:/{print $2; exit}')"
mv_loc="$(print -r -- "$mv_status" | /usr/bin/awk -F': *' '/Visible location:/{print $2; exit}')"

corpdns="$("$TS" debug prefs 2>/dev/null | /usr/bin/awk -F'[:,]' '/"CorpDNS"/{gsub(/[ \t"]/,"",$2);print $2; exit}')"
ts_backend="$("$TS" status --json 2>/dev/null | /usr/bin/awk -F'"' '/"BackendState"/{print $4; exit}')"
[ -z "$ts_backend" ] && ts_backend="Unknown"

# ------------------------------------------------------------- title (the bar)
# Color palette (vivid, dark-mode friendly)
C_GREEN="#30d158"; C_ORANGE="#ff9f0a"; C_RED="#ff453a"; C_GREY="#98989d"
C_BLUE="#0a84ff"; C_INDIGO="#5e5ce6"

case "$mv_state" in
  Connected)                 mv_sym="lock.fill";                          mv_word="Connected"; mv_color="$C_GREEN";  mv_dot="green" ;;
  Connecting|Disconnecting)  mv_sym="lock.rotation";                      mv_word="$mv_state"; mv_color="$C_ORANGE"; mv_dot="orange" ;;
  Blocked)                   mv_sym="lock.trianglebadge.exclamationmark"; mv_word="Blocked";   mv_color="$C_RED";    mv_dot="red" ;;
  *)                         mv_sym="lock.open";                          mv_word="Off";       mv_color="$C_GREY";   mv_dot="grey" ;;
esac

if [ "$corpdns" = "true" ]; then
  dns_sym="checkmark.shield.fill"; dns_word="ON";  dns_color="$C_GREEN"
else
  dns_sym="xmark.shield.fill";     dns_word="OFF"; dns_color="$C_ORANGE"
fi

case "$ts_backend" in
  Running)             ts_color="$C_GREEN" ;;
  NeedsLogin|Starting) ts_color="$C_ORANGE" ;;
  Stopped|NoState)     ts_color="$C_GREY" ;;
  *)                   ts_color="$C_GREY" ;;
esac

# Menu-bar title: just a status dot tracking Mullvad state
# (green=connected, orange=transitioning, red=blocked, grey=off).
# The dot is an INLINE SF Symbol token (:circle.fill:) in the title text, NOT the
# sfimage= param. Per SwiftBar's source, sfimage= forces SymbolConfiguration
# scale=.large and ignores size=/sfsize= (that's the giant dot we kept getting);
# only inline :tokens: honor sfsize (point size) + sfcolor. Bump sfsize to
# enlarge; if the dot sits too high/low, add e.g. valign=-1. The menubar-*.png
# dot images are an unused fallback.
echo ":circle.fill: | sfcolor=${mv_color} sfsize=6"
echo "---"

# ------------------------------------------------------------------- dropdown
# accept-dns status (non-clickable)
echo "accept-dns (MagicDNS): ${dns_word} | sfimage=${dns_sym} sfcolor=${dns_color} color=${dns_color}"
echo "---"

# Clickable status items: the label IS the live status; clicking opens the app.
# Use the REAL app icons (base64 PNGs) + status colors.
HELPER="$DIR/open-native-menu.sh"
MV_IMG="$(/usr/bin/base64 -i "$DIR/mullvad.png" 2>/dev/null | /usr/bin/tr -d '\n')"
TS_IMG="$(/usr/bin/base64 -i "$DIR/tailscale.png" 2>/dev/null | /usr/bin/tr -d '\n')"

if [ "$mv_state" = "Connected" ]; then
  mv_label="Mullvad: Connected — ${mv_relay:-?}"
else
  mv_label="Mullvad: ${mv_word}${mv_loc:+ — $mv_loc}"
fi
# Mullvad: click opens the native Mullvad menu (location picker, etc.)
echo "${mv_label} | bash=$HELPER param1=mullvad terminal=false image=${MV_IMG} color=${mv_color}"
# Tailscale: click opens the Tailscale app
echo "Tailscale: ${ts_backend} | bash=$OPEN param1=-a param2=Tailscale terminal=false image=${TS_IMG} color=${ts_color}"
