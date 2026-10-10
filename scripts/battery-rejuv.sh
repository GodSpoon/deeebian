#!/bin/bash
# battery-rejuv.sh — battery conditioning + fuel-gauge recalibration for the ASUS Eee PC 701.
#
# The 701 pack is 2x 18650 Li-ion in series (7.4 V nominal, ~4400 mAh) behind a BMS.
# An aged or long-idle pack's fuel gauge (the BMS coulomb counter) drifts, so it reports a
# wrong "100%" and a wrong runtime. One full discharge -> full recharge cycle lets the gauge
# re-learn the real endpoints. This does NOT repair physically worn cells; it resynchronises
# the gauge. Expect the *reported* full capacity to DROP if the gauge had been optimistic —
# that is the point: after this, "20% left" means 20% left.
#
# Usage (needs root: systemd-inhibit + writing backlight/sysfs):
#   sudo battery-rejuv status      # live telemetry only, changes nothing
#   sudo battery-rejuv drain       # deep-discharge to the floor, then stop (unplugged)
#   sudo battery-rejuv charge      # monitor a recharge up to a true 100%
#   sudo battery-rejuv full        # drain, then prompt to plug in and watch to 100%
#   sudo battery-rejuv restore     # undo the "keep awake" settings if a run died
#
# Options: --yes (skip confirmations)  --gentle (no CPU load while draining)  --log FILE
#
# SAFETY: the drain stops at FLOOR_PCT (default 6%) OR FLOOR_UV (default 6.6 V = 3.3 V/cell),
# whichever comes first, and holds an idle-suspend inhibitor for the whole run. A Li-ion must
# never be taken below ~3.0 V/cell; the firmware hard-cut is the last line of defence, not the
# plan. Do not run the 701 unattended on a surface that blocks its (weak) fan.
set -uo pipefail

# ---------------------------------------------------------------- tunables ----
FLOOR_PCT=${BATTERY_FLOOR_PCT:-6}      # stop draining at/below this %
FLOOR_UV=${BATTERY_FLOOR_UV:-6600000}  # stop draining at/below this pack voltage (uV) = 3.3 V/cell
CEIL_PCT=${BATTERY_CEIL_PCT:-100}      # charge target
SAMPLE=5                               # telemetry poll interval (s)
TOP_OFF_MIN=${BATTERY_TOPOFF_MIN:-30}  # keep charging this long after "Full" (trickle/balance)
LOG=${BATTERY_LOG:-/run/battery-rejuv.log}   # /run = tmpfs: no SD-card wear
GENTLE=0
ASSUME_YES=0

# ---------------------------------------------------------------- args ---------
CMD=""; while [ $# -gt 0 ]; do
  case "$1" in
    status|telemetry|drain|discharge|charge|full|restore)
      CMD="$1"; [ "$CMD" = telemetry ] && CMD=status; [ "$CMD" = discharge ] && CMD=drain; shift ;;
    --gentle) GENTLE=1; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    --log) LOG="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$CMD" ] || CMD=full

log()  { printf '%s  %s\n' "$(date '+%H:%M:%S')" "$*" | tee -a "$LOG"; }
say()  { printf '%s\n' "$*"; }
die()  { say "ERROR: $*" >&2; exit 1; }
need_root() { [ "$(id -u)" = 0 ] || die "run as root: sudo battery-rejuv $CMD"; }

# ------------------------------------------------------- device discovery -----
BAT=""; AC=""
SYSFS_PS=${SYSFS_PS:-/sys/class/power_supply}
for d in "$SYSFS_PS"/*; do
  [ -r "$d/type" ] || continue
  case "$(cat "$d/type" 2>/dev/null)" in
    Battery) [ -n "$BAT" ] || BAT="$d" ;;
    Mains)   [ -n "$AC" ]  || AC="$d"  ;;
  esac
done
[ -n "$BAT" ] || die "no battery found under /sys/class/power_supply (is eeepc-laptop loaded?)"

f() { # f <attr> : read a sysfs attribute, empty if absent
  [ -r "$BAT/$1" ] && cat "$BAT/$1" 2>/dev/null || true
}
cap_pct()  { local v; v=$(f capacity);      [ -n "$v" ] && printf '%s' "$v"; }
voltage_uv(){ # pack voltage in uV, from voltage_now (uV) or voltage_min/now scaled
  local v; v=$(f voltage_now)
  if [ -z "$v" ]; then v=$(f voltage_avg); fi
  [ -n "$v" ] && printf '%s' "$v" || printf '0'; }
status_str(){ local v; v=$(f status); [ -n "$v" ] && printf '%s' "$v" || printf 'Unknown'; }
on_ac()     { [ -n "$AC" ] && [ "$(cat "$AC/online" 2>/dev/null)" = 1 ]; }

volts() { awk -v u="$(voltage_uv)" 'BEGIN{printf "%.2f", u/1000000}'; }

banner() { say ""; say "  pack:  $BAT"; say "  %:     $(cap_pct)%"; say "  volts: $(volts) V"; say "  state: $(status_str)"; say "  AC:    $(on_ac && echo plugged || echo unplugged)"; say ""; }

# ------------------------------------------------------------ keep-awake ------
XSET=(xset -display :0 s off -dpms s noblank)
keep_awake() {
  # Blank the screen never; hold an inhibit lock so logind cannot idle/low-battery suspend.
  command -v xset >/dev/null && { [ -f /home/sam/.Xauthority ] && export XAUTHORITY=/home/sam/.Xauthority; "${XSET[@]}" >/dev/null 2>&1 || true; }
  if [ -z "${REJUV_INHIBITED:-}" ] && command -v systemd-inhibit >/dev/null; then
    export REJUV_INHIBITED=1
    exec systemd-inhibit --what=idle:sleep:handle-lid-switch --why="battery recalibration in progress" \
         --mode=block /bin/bash "$0" "$@"
  fi
}
restore_awake() {
  log "restoring normal power management"
  command -v xset >/dev/null && { [ -f /home/sam/.Xauthority ] && export XAUTHORITY=/home/sam/.Xauthority; xset -display :0 s default dpms >/dev/null 2>&1 || true; }
  # nudge TLP to re-apply (it is not stopped, just re-triggered)
  systemctl restart tlp >/dev/null 2>&1 || true
}

# ---------------------------------------------------- controlled drain load ---
LOAD_PIDS=()
start_load() {
  [ "$GENTLE" = 1 ] && { log "gentle mode: no CPU load added"; return; }
  local n; n=$(nproc 2>/dev/null || echo 1)
  for _ in $(seq 1 "$n"); do
    ( while :; do :; done ) & LOAD_PIDS+=("$!")
  done
  log "started $n CPU load spinner(s) (pid ${LOAD_PIDS[*]})"
}
stop_load() {
  for p in "${LOAD_PIDS[@]:-}"; do [ -n "${p:-}" ] && kill "$p" 2>/dev/null || true; done
  LOAD_PIDS=()
}

# ----------------------------------------------------------------- modes ------
do_status() { banner; say "full_design: $(f charge_full_design)  full_now: $(f charge_full)  cycles: $(f cycle_count)"; }

do_drain() {
  need_root
  local kw=(drain); [ "$GENTLE" = 1 ] && kw+=(--gentle); [ "$ASSUME_YES" = 1 ] && kw+=(--yes); kw+=(--log "$LOG")
  keep_awake "${kw[@]}"
  local c v
  on_ac && die "AC is plugged in — unplug the charger to discharge (drain needs the pack on its own)"
  log "draining to ${FLOOR_PCT}% or $(awk -v u="$FLOOR_UV" 'BEGIN{printf "%.2f", u/1000000}') V (floor)"
  start_load
  trap 'stop_load; restore_awake' INT TERM
  while :; do
    c=$(cap_pct); v=$(voltage_uv)
    log "state=discharging  cap=${c:-?}%  volts=$(volts)V"
    if [ -n "$c" ] && [ "$c" -le "$FLOOR_PCT" ]; then log "reached ${c}% (target ${FLOOR_PCT}%) — floor reached"; break; fi
    if [ -n "$v" ] && [ "$v" -le "$FLOOR_UV" ]; then log "reached $(volts)V (floor $(awk -v u="$FLOOR_UV" 'BEGIN{printf "%.2f", u/1000000}')V) — floor reached"; break; fi
    on_ac && { log "AC plugged in mid-drain — stopping so the recharge can start cleanly"; break; }
    sleep "$SAMPLE"
  done
  stop_load
  say ""; say "Drain complete. NOW plug the charger in and run:  sudo battery-rejuv charge"
  say "(or just run:  sudo battery-rejuv full  and let it do both.)"; say ""
  log "drain finished at ${c:-?}% / $(volts)V"
}

do_charge() {
  need_root
  local kw=(charge); [ "$GENTLE" = 1 ] && kw+=(--gentle); [ "$ASSUME_YES" = 1 ] && kw+=(--yes); kw+=(--log "$LOG")
  keep_awake "${kw[@]}"
  on_ac || die "AC is NOT plugged in — plug the charger in to charge"
  log "monitoring charge to ${CEIL_PCT}% (top-off ${TOP_OFF_MIN} min after Full)"
  local c v st full_since=0
  while :; do
    c=$(cap_pct); st=$(status_str)
    log "state=${st}  cap=${c:-?}%  volts=$(volts)V"
    if [ -n "$c" ] && [ "$c" -ge "$CEIL_PCT" ]; then
      if [ "$full_since" = 0 ]; then full_since=$(date +%s); log "reached ${c}% — holding ${TOP_OFF_MIN} min trickle to balance the cells"; fi
      [ $(( $(date +%s) - full_since )) -ge $(( TOP_OFF_MIN * 60 )) ] && { log "top-off done"; break; }
    fi
    on_ac || { log "AC removed — charge paused"; break; }
    sleep "$SAMPLE"
  done
  say ""; say "Charge cycle complete at ${c:-?}%."; say "Unplug and use normally; the gauge should now track reality."; say ""
  restore_awake
}

do_full() {
  if [ "$ASSUME_YES" != 1 ]; then
    say ""
    say "Battery recalibration will now: (1) run the pack flat to ~${FLOOR_PCT}% under load,"
    say "then wait while you plug in, (2) charge to 100% and hold for a top-off."
    say "This takes a few hours. The machine must stay on and awake, on a hard surface."
    printf "Continue? [y/N] "; read -r a; case "$a" in y|Y|yes) ;; *) die "aborted" ;; esac
  fi
  do_drain
  # wait for the charger to appear
  say "Waiting for the charger (plug it in now)..."
  local waited=0
  while ! on_ac; do sleep 5; waited=$((waited+5)); [ "$waited" -ge 600 ] && die "no charger detected after 10 min"; done
  log "charger detected"
  do_charge
}

# ------------------------------------------------------------------ main -------
{ [ "$CMD" = status ] || [ "$CMD" = restore ]; } || : > "$LOG"
case "$CMD" in
  status)  do_status ;;
  drain)   do_drain ;;
  charge)  do_charge ;;
  full)    do_full ;;
  restore) need_root; restore_awake; say "restored." ;;
  *)       die "unknown command: $CMD" ;;
esac
