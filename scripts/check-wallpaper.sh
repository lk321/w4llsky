#!/bin/zsh
# Live health check for W4llsky. Nothing is "fixed" until this agrees on the real Mac.
#
#   scripts/check-wallpaper.sh         one snapshot, with WARN lines for broken invariants
#   scripts/check-wallpaper.sh watch   one line per change until Ctrl-C: lock, unlock,
#                                      sleep or unplug while it runs, then read it back
#
# What healthy looks like (CLAUDE.md, "Verifying a change"):
#   desktop visible   app 2-8% CPU, saver `paused` (W4llsky covers it) at ~0%
#   locked            app ~0%, saver `playing` at a few % — never `none` with the display on
#   battery saver     app holds no video, saver `still`, both RSS down
set -u
SUPPORT="$HOME/Library/Application Support/W4llsky"

proc() { # name pid -> "name[pid] cpu% footprint video=open|closed"
  [[ -z "$2" ]] && { print -n "$1[-]"; return }
  local cpu=$(ps -o %cpu= -p $2 | tr -d ' ')
  # phys_footprint is what Activity Monitor calls Memory; RSS keeps freed pages around.
  local mem=$(footprint -p $2 2>/dev/null | awk '/phys_footprint:/ {print $2 $3; exit}')
  local open=$(lsof -p $2 2>/dev/null | grep -c '\.mp4$')
  print -n "$1[$2] ${cpu%.*}% ${mem:-?} video=$([[ $open -gt 0 ]] && print open || print closed)"
}

flags() {
  local f=""
  [[ -e "$SUPPORT/DesktopCovered" ]] && f+=" covered"
  [[ -e "$SUPPORT/PowerSaving" ]] && f+=" power-saving"
  print -n "flags:${f:- none}"
}

snapshot() {
  local app=$(pgrep -x W4llsky | head -1)
  local saver=$(pgrep -x legacyScreenSaver | head -1)
  print "$(proc app "$app")  $(proc saver "$saver")  $(flags)"
}

if [[ "${1:-}" == watch ]]; then
  last=""
  /usr/bin/log stream --predicate 'subsystem == "com.personal.W4llsky.saver"' --style compact 2>/dev/null \
    | grep --line-buffered 'W4llsky' | sed -u 's/^[^ ]* \([^ ]*\).*playback\] /\1 saver: /' &
  trap "kill $! 2>/dev/null" EXIT
  while sleep 1; do
    line=$(snapshot)
    [[ "$line" != "$last" ]] && print "$(date +%T) $line"
    last=$line
  done
fi

pressure=$(sysctl -n kern.memorystatus_vm_pressure_level)
print "memory pressure: $pressure (1 normal, 2 warn: ignored on purpose, 4 critical: releases)"
print "thermal: $(pmset -g therm | grep -i 'level\|limit' | tr -s ' ' | paste -sd, - || print unknown)"
print "power: $(pmset -g batt | sed -n 2p | sed 's/^ *-InternalBattery-0 ([^)]*)//' || true)"
snapshot
print "saver's last decisions:"
/usr/bin/log show --last 2h --predicate 'subsystem == "com.personal.W4llsky.saver"' --style compact 2>/dev/null \
  | grep -o 'pid [0-9]*: .*' | tail -4 | sed 's/^/  /'

app=$(pgrep -x W4llsky | head -1)
[[ -e "$SUPPORT/PowerSaving" && -n "$app" ]] && lsof -p $app 2>/dev/null | grep -q '\.mp4' \
  && print "WARN: saving battery but W4llsky still holds a video: its decoder wasn't released"
[[ "$pressure" == 2 && -n "$app" ]] && [[ "$(ps -o %cpu= -p $app | cut -d. -f1 | tr -d ' ')" == 0 ]] \
  && print "WARN: memory at warn and W4llsky at 0% — fine if a window covers the desktop, the old bug if not"
exit 0
