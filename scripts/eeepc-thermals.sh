#!/bin/bash
# eeepc-thermals — report temperatures, fan state, CPU frequency and governor on the
# ASUS Eee PC 701. READ-ONLY: it never writes the fan or cpufv.
#
# HONEST INTERFACE NOTE (verified against drivers/platform/x86/eeepc-laptop.c in Linux 6.12):
#   * The fan is driven by the Embedded Controller (EC). eeepc-laptop pokes EC registers
#     0x63 (FAN_PWM, duty) and 0xD3 (FAN_CTRL, manual/auto bit) and exposes them through the
#     hwmon class as pwm1 (0-255), pwm1_enable (1=manual, 2=auto) and fan1_input (RPM).
#     There IS a software fan knob — but on a 701 the EC's own automatic curve is the design,
#     and forcing manual PWM can make the fan run flat-out (noisier, more power) or stall
#     (dangerous). This script only READS these.
#   * /sys/devices/platform/eeepc/ also carries cpufv / available_cpufv / cpufv_disabled. On
#     PRODUCT_NAME == "701" the driver sets cpufv_disabled=1 and REFUSES writes, because using
#     it can hang this model. Read-only here; never write cpufv on a 701.
#   * Temperature: the Celeron M ULV 353 (Dothan) has no digital thermal sensor (no
#     X86_FEATURE_DTHERM), so coretemp does NOT load and there is no hwmon CPU temp. The only
#     possible source is the ACPI thermal zone (/sys/class/thermal/thermal_zone*/), which some
#     701 BIOSes expose and some do not; this script reports whatever exists and says so.
#   * cpufreq: the Celeron M has no Enhanced SpeedStep, so /sys/.../cpufreq does not exist.
#     The 630 MHz "idle" clock is fixed clock modulation, not a selectable P-state.
#
# Usage: eeepc-thermals [--watch SECONDS]
set -u
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
WATCH=0
while [ $# -gt 0 ]; do
  case "$1" in
    --watch) WATCH="${2:-5}" ;;
    -h|--help) grep '^#' "$0" | sed -n '1,5p'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

read1() { cat "$1" 2>/dev/null | tr -d '\n'; }

collect_thermal() {
  for z in /sys/class/thermal/thermal_zone*; do
    [ -d "$z" ] || continue
    local t; t=$(read1 "$z/type")
    local temp; temp=$(read1 "$z/temp")
    [ -n "$temp" ] || continue
    # milli-degrees C -> C with one decimal
    local c; c=$(awk -v m="$temp" 'BEGIN{printf "%.1f", m/1000}')
    printf '  %-14s %-8s %s C' "$(basename "$z")" "${t:-?}" "$c"
    local mode; mode=$(read1 "$z/mode"); [ -n "$mode" ] && printf '  mode=%s' "$mode"
    local pol; pol=$(read1 "$z/policy"); [ -n "$pol" ] && printf '  policy=%s' "$pol"
    # trip points, if any
    local trips=""
    for tp in "$z"/trip_point_*_temp; do
      [ -r "$tp" ] || continue
      local tv; tv=$(read1 "$tp")
      [ -n "$tv" ] || continue
      trips="$trips $(basename "$tp" | sed 's/trip_point_//;s/_temp//')=$(awk -v m="$tv" 'BEGIN{printf "%.0f", m/1000}')"
    done
    [ -n "$trips" ] && printf '  trips:%s' "$trips"
    printf '\n'
  done
}

collect_hwmon() {
  # any temp*_input from any hwmon chip (coretemp will be absent on Dothan, that is fine)
  local found=0
  for h in /sys/class/hwmon/hwmon*; do
    [ -d "$h" ] || continue
    local name; name=$(read1 "$h/name")
    for ti in "$h"/temp*_input; do
      [ -r "$ti" ] || continue
      local lab; lab=$(read1 "${ti%_input}_label")
      local mv; mv=$(read1 "$ti")
      [ -n "$mv" ] || continue
      printf '  %-10s %-10s %s C\n' "${name:-?}" "${lab:-temp}" "$(awk -v m="$mv" 'BEGIN{printf "%.1f", m/1000}')"
      found=1
    done
  done
  [ "$found" = 0 ] && echo "  (no hwmon temperature sensor — expected: Dothan Celeron M has no coretemp DTS)"
}

eeepc_hwmon_dir() {
  for h in /sys/class/hwmon/hwmon*; do
    [ -d "$h" ] || continue
    [ "$(read1 "$h/name")" = "eeepc" ] && { echo "$h"; return; }
  done
}

collect_fan() {
  local h; h=$(eeepc_hwmon_dir)
  if [ -n "$h" ]; then
    local rpm pwm en
    rpm=$(read1 "$h/fan1_input"); pwm=$(read1 "$h/pwm1"); en=$(read1 "$h/pwm1_enable")
    printf '  fan RPM        : %s\n' "${rpm:-<no tachometer reading>}"
    printf '  pwm1 (duty)    : %s / 255\n' "${pwm:-?}"
    case "${en:-}" in
      1) printf '  control        : MANUAL (pwm1_enable=1) — something has taken the fan off the EC curve\n' ;;
      2) printf '  control        : AUTO (pwm1_enable=2) — Embedded Controller curve in charge (normal/desired)\n' ;;
      *) printf '  control        : pwm1_enable=%s\n' "${en:-?}" ;;
    esac
  else
    echo "  (no eeepc hwmon device — is the eeepc-laptop module loaded?)"
  fi
  # ACPI fan objects, if the firmware declares any
  for f in /proc/acpi/fan/*; do
    [ -e "$f" ] || continue
    printf '  acpi fan %s: state=%s\n' "$(basename "$f")" "$(read1 "$f/state")"
  done
}

collect_cpufreq() {
  if [ -d /sys/devices/system/cpu/cpu0/cpufreq ]; then
    local gov drv cur mn mx
    drv=$(read1 /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver)
    gov=$(read1 /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)
    cur=$(read1 /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq)
    mn=$(read1 /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_min_freq)
    mx=$(read1 /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq)
    printf '  driver         : %s\n' "${drv:-?}"
    printf '  governor       : %s\n' "${gov:-?}"
    printf '  freq           : %s kHz (range %s..%s kHz)\n' "${cur:-?}" "${mn:-?}" "${mx:-?}"
  else
    printf '  cpufreq        : ABSENT — no P-states available.\n'
    printf '                   The Celeron M ULV 353 (Dothan) has no Enhanced SpeedStep.\n'
    printf '                   The 630 MHz "idle" clock is fixed clock modulation, not a\n'
    printf '                   frequency we can select. Nothing to govern, nothing to tune.\n'
  fi
  local bp; bp=$(awk -F': ' '/bogomips/{print $2; exit}' /proc/cpuinfo 2>/dev/null)
  printf '  bogomips       : %s\n' "${bp:-?}"
}

collect_misc() {
  local pp; pp=$(read1 /sys/firmware/acpi/platform_profile)
  [ -n "$pp" ] && printf '  platform_profile: %s (choices:%s)\n' "$pp" "$(read1 /sys/firmware/acpi/platform_profile_choices)"
  for b in /sys/class/power_supply/*; do
    [ -d "$b" ] || continue
    local ty; ty=$(read1 "$b/type")
    case "$ty" in
      Battery) printf '  battery        : %s%%  status=%s\n' "$(read1 "$b/capacity")" "$(read1 "$b/status")" ;;
      Mains)   printf '  AC             : online=%s\n' "$(read1 "$b/online")" ;;
    esac
  done
  local z=/sys/block/zram0
  if [ -d "$z" ]; then
    # mm_stat: orig_data_size compr_data_size mem_used_total ...
    if [ -r "$z/mm_stat" ]; then
      awk '{printf "  zram0          : %d MB -> %d MB (ratio %.1f:1)\n", $1/1048576, $2/1048576, ($2>0?$1/$2:0)}' "$z/mm_stat"
    fi
  fi
}

snapshot() {
  echo "=== eeepc-thermals — $(hostname) — $(date '+%Y-%m-%d %H:%M:%S') ==="
  echo "-- temperature --"
  collect_thermal
  collect_hwmon
  echo "-- fan --"
  collect_fan
  echo "-- CPU / frequency --"
  collect_cpufreq
  echo "-- platform --"
  collect_misc
  echo "-- eeepc platform attributes --"
  for a in /sys/devices/platform/eeepc/*; do
    [ -f "$a" ] || continue
    printf '  %-20s %s\n' "$(basename "$a")" "$(read1 "$a")"
  done
}

if [ "$WATCH" != 0 ]; then
  trap 'exit 0' INT TERM
  while :; do
    clear 2>/dev/null || true
    snapshot
    echo
    echo "(watch mode: refresh every ${WATCH}s — Ctrl-C to quit)"
    sleep "$WATCH"
  done
else
  snapshot
fi
