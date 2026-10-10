#!/bin/bash
# test-battery-rejuv.sh — exercise scripts/battery-rejuv.sh against a fake power_supply tree.
#
# Runs the drain/charge state machines for real (no mocking of the loop itself) by pointing
# SYSFS_PS at a temp directory that mimics /sys/class/power_supply/BAT0 + AC0. Run as root
# (the script under test refuses to run otherwise). Safe: touches only the temp dir.
#
#   sudo scripts/test-battery-rejuv.sh [path/to/battery-rejuv.sh]
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT=${1:-$HERE/battery-rejuv.sh}
AS_ROOT=""; [ "$(id -u)" = 0 ] || AS_ROOT="sudo -E"

T=$(mktemp -d /tmp/rejuvtest.XXXXXX) || exit 1
trap '$AS_ROOT rm -rf "$T"' EXIT
PS="$T/power_supply"; mkdir -p "$PS/BAT0" "$PS/AC0"

cat > "$PS/BAT0/type" <<<'Battery'
echo 4400000 > "$PS/BAT0/charge_full_design"; echo 3300000 > "$PS/BAT0/charge_full"
echo 250     > "$PS/BAT0/cycle_count"
echo 7800000 > "$PS/BAT0/voltage_now"
cat > "$PS/AC0/type" <<<'Mains'
echo Discharging > "$PS/BAT0/status"; echo 0 > "$PS/AC0/online"

FAIL=0
check() { # check <desc> <expect> <got>
  if [ "$2" = "$3" ]; then echo "  ok   — $1"; else echo "  FAIL — $1 (want $2, got $3)"; FAIL=1; fi
}

echo "TEST 1: status prints telemetry"
SYSFS_PS="$PS" $AS_ROOT bash "$SCRIPT" status >/dev/null; check "status exit 0" 0 $?

echo "TEST 2: drain stops at capacity floor"
echo 30 > "$PS/BAT0/capacity"
# simulate the pack sagging while the loop polls (background: drop 4%/0.2s toward 0)
( c=30; while [ "$c" -gt 0 ]; do sleep 0.2; c=$((c-4)); [ "$c" -lt 0 ] && c=0; echo "$c" > "$PS/BAT0/capacity"; done ) &
SIM=$!
SYSFS_PS="$PS" BATTERY_FLOOR_PCT=20 BATTERY_FLOOR_UV=100000 BATTERY_LOG="$T/d.log" \
  $AS_ROOT bash "$SCRIPT" drain --gentle --yes --log "$T/d.log" >/dev/null; rc=$?
wait "$SIM" 2>/dev/null
check "drain exit 0" 0 $rc
grep -q "floor reached" "$T/d.log"; check "drain hit the floor" 0 $?

echo "TEST 3: drain refuses while AC is plugged in"
echo 1 > "$PS/AC0/online"; echo 50 > "$PS/BAT0/capacity"
SYSFS_PS="$PS" BATTERY_LOG="$T/d2.log" \
  $AS_ROOT bash "$SCRIPT" drain --gentle --yes --log "$T/d2.log" >/dev/null 2>&1
check "drain aborts on AC" 1 $?

echo "TEST 4: charge reaches ceil and tops off"
echo Charging > "$PS/BAT0/status"; echo 90 > "$PS/BAT0/capacity"
# simulate the pack filling (background: rise 4%/0.2s toward 100)
( c=90; while [ "$c" -lt 100 ]; do sleep 0.2; c=$((c+4)); [ "$c" -gt 100 ] && c=100; echo "$c" > "$PS/BAT0/capacity"; done ) &
SIM=$!
SYSFS_PS="$PS" BATTERY_TOPOFF_MIN=0 BATTERY_LOG="$T/c.log" \
  $AS_ROOT bash "$SCRIPT" charge --yes --log "$T/c.log" >/dev/null; rc=$?
wait "$SIM" 2>/dev/null
check "charge exit 0" 0 $rc
grep -q "top-off done" "$T/c.log"; check "charge topped off" 0 $?

echo "TEST 5: charge refuses when unplugged"
echo 0 > "$PS/AC0/online"
SYSFS_PS="$PS" BATTERY_LOG="$T/c2.log" \
  $AS_ROOT bash "$SCRIPT" charge --yes --log "$T/c2.log" >/dev/null 2>&1
check "charge aborts without AC" 1 $?

echo
[ "$FAIL" = 0 ] && echo "ALL TESTS PASSED" || echo "SOME TESTS FAILED"
exit $FAIL
