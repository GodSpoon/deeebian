#!/bin/bash
set -u
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
QUICK=0
LABEL=""
while [ $# -gt 0 ]; do
  case "$1" in
    --quick) QUICK=1 ;;
    --label) LABEL="${2:-}"; shift ;;
    -h|--help) grep '^#' "$0" | sed -n '1,6p'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

STAMP=$(date +%Y%m%d-%H%M%S)
OUT="/var/log/eeepc-bench-${STAMP}.txt"
# Make /var/log if it somehow is not there (it is tmpfs-backed in this image via journald
# only for the journal; /var/log itself is on the SD). Write there so results survive reboot.
mkdir -p /var/log 2>/dev/null || true
: > "$OUT" 2>/dev/null || { echo "cannot write $OUT — falling back to stdout only" >&2; OUT=""; }

# everything below is teed to the file and stdout
if [ -n "$OUT" ]; then exec > >(tee "$OUT") 2>&1; fi

now_ns() { date +%s%N 2>/dev/null || echo $(( $(date +%s) * 1000000000 )); }
ms_between() { echo $(( ($2 - $1) / 1000000 )); }
hr() { printf '%s\n' '------------------------------------------------------------'; }

echo "=== eeepc-bench — $(hostname) — $(date '+%Y-%m-%d %H:%M:%S %Z') ==="
[ -n "$LABEL" ] && echo "label            : $LABEL"
echo "kernel           : $(uname -sr)  ($(uname -m))"
echo "uptime           : $(cut -d. -f1 /proc/uptime) s"
echo "cpu              : $(awk -F': ' '/model name/{print $2; exit}' /proc/cpuinfo)"
echo "cores            : $(grep -c '^processor' /proc/cpuinfo)"
echo "bogomips         : $(awk -F': ' '/bogomips/{print $2; exit}' /proc/cpuinfo)"
echo "memtotal         : $(awk '/MemTotal/{printf "%.0f MB", $2/1024}' /proc/meminfo)"
echo "quick mode       : $QUICK (1 = no SD write test, no terminal-launch test)"
if [ -r /etc/eeepc-version ]; then echo "image            : $(cat /etc/eeepc-version)"; fi
hr

# --- 1. boot time -------------------------------------------------------------------
echo "## BOOT"
if command -v systemd-analyze >/dev/null 2>&1; then
  systemd-analyze 2>/dev/null | sed 's/^/  /'
  echo "  -- top offenders (blame) --"
  systemd-analyze blame 2>/dev/null | head -12 | sed 's/^/  /'
else
  echo "  (systemd-analyze not available)"
fi
hr

# --- 2. CPU throughput --------------------------------------------------------------
echo "## CPU"
# fixed 8 MiB buffer on tmpfs (no SD writes); reused by the compression test below
BUF="/tmp/eeepc-bench-buf.$$"
if head -c 8388608 /dev/urandom > "$BUF" 2>/dev/null; then
  SZ=8
  t0=$(now_ns); gzip -c "$BUF" > /dev/null 2>&1; t1=$(now_ns)
  ms=$(ms_between "$t0" "$t1"); [ "$ms" -lt 1 ] && ms=1
  awk -v mb="$SZ" -v ms="$ms" 'BEGIN{printf "  gzip 8MiB      : %d ms  (%.1f MB/s)\n", ms, mb/(ms/1000.0)}'
  t0=$(now_ns); sha256sum "$BUF" > /dev/null 2>&1; t1=$(now_ns)
  ms=$(ms_between "$t0" "$t1"); [ "$ms" -lt 1 ] && ms=1
  awk -v mb="$SZ" -v ms="$ms" 'BEGIN{printf "  sha256 8MiB    : %d ms  (%.1f MB/s)\n", ms, mb/(ms/1000.0)}'
  rm -f "$BUF"
else
  echo "  (could not build test buffer on /tmp — is tmpfs mounted?)"
fi
t0=$(now_ns)
awk 'BEGIN{for(i=0;i<3000000;i++){x=i*1.0001+7; s+=x} printf ""}' 2>/dev/null
t1=$(now_ns); ms=$(ms_between "$t0" "$t1"); [ "$ms" -lt 1 ] && ms=1
awk -v ms="$ms" 'BEGIN{printf "  awk int loop   : %d ms  (%.2f Miter/s)\n", ms, 3.0/(ms/1000.0)}'
hr

# --- 3. memory + zram ---------------------------------------------------------------
echo "## MEMORY"
# Read /proc/meminfo directly rather than using `free` — procps is not guaranteed present
# and the image's own philosophy is to read /proc, not to trust a tool that may be absent.
awk '/^(MemTotal|MemFree|MemAvailable|Buffers|Cached|Dirty)/{printf "  %-14s %8.1f MB\n", $1, $2/1024}
     /^(SwapTotal|SwapFree)/{printf "  %-14s %8.1f MB\n", $1, $2/1024}' /proc/meminfo
echo "  -- swap --"
if [ -r /proc/swaps ]; then sed 's/^/  /' /proc/swaps; fi
if [ -r /sys/block/zram0/mm_stat ]; then
  # columns: orig_data_size compr_data_size mem_used_total mem_limit ...
  awk '{printf "  zram0          : orig %d MB -> compr %d MB  (ratio %.2f:1, mem %d MB)\n", $1/1048576, $2/1048576, ($2>0?$1/$2:0), $3/1048576}' /sys/block/zram0/mm_stat
  echo "  zram algo      : $(cat /sys/block/zram0/comp_algorithm 2>/dev/null || echo '?')"
fi
hr

# --- 4. SD card I/O ----------------------------------------------------------------
echo "## DISK (SD card)"
ROOTSRC=$(findmnt -n -o SOURCE / 2>/dev/null || echo '?')
echo "  root device    : $ROOTSRC"
DOPTS=$(findmnt -n -o OPTIONS / 2>/dev/null || echo '?')
echo "  root options   : $DOPTS"
ROOTDEV=$(echo "$ROOTSRC" | sed 's/[0-9]*$//; s/p$//')
[ -r "/sys/block/$(basename "$ROOTDEV")/queue/scheduler" ] && \
  echo "  scheduler      : $(cat "/sys/block/$(basename "$ROOTDEV")/queue/scheduler")"
[ -r "/sys/block/$(basename "$ROOTDEV")/queue/read_ahead_kb" ] && \
  echo "  read_ahead_kb  : $(cat "/sys/block/$(basename "$ROOTDEV")/queue/read_ahead_kb")"

# sequential read: hdparm if present (and it is in the image), else dd
if command -v hdparm >/dev/null 2>&1 && [ -b "$ROOTDEV" ]; then
  hdparm -t "$ROOTDEV" 2>/dev/null | sed 's/^/  /'
else
  echo "  (hdparm not available/root device not a block dev — using dd below)"
fi

# A dedicated scratch file on the real card (NOT /tmp, which is tmpfs here).
SDBENCH="/var/tmp/eeepc-bench.$$"
DROP_OK=0
[ -w /proc/sys/vm/drop_caches ] && DROP_OK=1
drop() { [ "$DROP_OK" = 1 ] && { sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true; }; }

if [ "$QUICK" = 0 ]; then
  echo "  -- sequential write (32 MiB, then removed) --"
  if dd if=/dev/zero of="$SDBENCH" bs=1M count=32 conv=fsync 2>/dev/null; then
    sync
    t0=$(now_ns)
    dd if=/dev/zero of="$SDBENCH" bs=1M count=32 conv=fsync 2>/dev/null
    t1=$(now_ns); ms=$(ms_between "$t0" "$t1"); [ "$ms" -lt 1 ] && ms=1
    awk -v ms="$ms" 'BEGIN{printf "  write          : %d ms  (%.2f MB/s)\n", ms, 32.0/(ms/1000.0)}'
  else
    echo "  write          : SKIPPED (cannot write $SDBENCH — read-only fs?)"
    SDBENCH=""
  fi
else
  echo "  write          : SKIPPED (--quick; this is the only SD-wear step)"
fi

if [ -n "${SDBENCH:-}" ] && [ -f "$SDBENCH" ]; then
  # sequential read, cache dropped
  drop
  t0=$(now_ns)
  dd if="$SDBENCH" of=/dev/null bs=1M 2>/dev/null
  t1=$(now_ns); ms=$(ms_between "$t0" "$t1"); [ "$ms" -lt 1 ] && ms=1
  awk -v ms="$ms" 'BEGIN{printf "  seq read       : %d ms  (%.2f MB/s)\n", ms, 32.0/(ms/1000.0)}'

  # 4k random-ish read: 64 direct reads at random 4k offsets. O_DIRECT bypasses page cache.
  # NB: the per-dd process spawn on a 900 MHz core is part of the number — reported as-is,
  # and the average ms/op is the figure to compare between runs.
  n=64; ok=0
  t0=$(now_ns)
  i=0
  while [ "$i" -lt "$n" ]; do
    off=$(( (RANDOM % 8192) ))
    dd if="$SDBENCH" of=/dev/null bs=4k count=1 skip="$off" iflag=direct 2>/dev/null && ok=$((ok+1))
    i=$((i+1))
  done
  t1=$(now_ns); ms=$(ms_between "$t0" "$t1"); [ "$ms" -lt 1 ] && ms=1
  awk -v ms="$ms" -v ok="$ok" 'BEGIN{printf "  4k rand read   : %d ops in %d ms  (%.1f IOPS, %.2f ms/op)\n", ok, ms, ok/(ms/1000.0), ms/ok}'
  rm -f "$SDBENCH"
else
  echo "  seq read       : SKIPPED (no test file)"
fi
hr

# --- 5. X11 responsiveness ----------------------------------------------------------
echo "## X11 / DESKTOP"
XOK=0
if [ -S /tmp/.X11-unix/X0 ]; then export DISPLAY=:0; XOK=1
elif [ -S /tmp/.X11-unix/X1 ]; then export DISPLAY=:1; XOK=1
elif [ -n "${DISPLAY:-}" ]; then XOK=1
fi
if [ "$XOK" = 1 ] && command -v xwininfo >/dev/null 2>&1; then
  echo "  display        : ${DISPLAY:-?}"
  # X request round-trip: 50 synchronous server round-trips (xwininfo -root)
  t0=$(now_ns)
  i=0; while [ "$i" -lt 50 ]; do xwininfo -root >/dev/null 2>&1; i=$((i+1)); done
  t1=$(now_ns); ms=$(ms_between "$t0" "$t1"); [ "$ms" -lt 1 ] && ms=1
  awk -v ms="$ms" 'BEGIN{printf "  X round-trip   : 50 reqs in %d ms  (%.2f ms/request)\n", ms, ms/50.0}'
  echo "  X clients      : $(xlsclients 2>/dev/null | wc -l)"
  if [ "$QUICK" = 0 ]; then
    # terminal open time: what the user actually waits for on Ctrl+Alt+T
    if command -v lxterminal >/dev/null 2>&1; then
      t0=$(now_ns); lxterminal -e true >/dev/null 2>&1; t1=$(now_ns)
      ms=$(ms_between "$t0" "$t1"); [ "$ms" -lt 1 ] && ms=1
      echo "  lxterminal open: ${ms} ms"
    fi
    if command -v xmessage >/dev/null 2>&1; then
      t0=$(now_ns); xmessage -timeout 1 -buttons '' 'bench' >/dev/null 2>&1; t1=$(now_ns)
      ms=$(ms_between "$t0" "$t1"); [ "$ms" -lt 1 ] && ms=1
      echo "  xmessage map   : ${ms} ms (includes 1 s on-screen timeout)"
    fi
  else
    echo "  window open    : SKIPPED (--quick)"
  fi
else
  echo "  (no reachable X server — desktop benchmarks skipped; re-run from the running session)"
fi
hr

# --- 6. governor / thermal state (context for the numbers above) --------------------
echo "## GOVERNOR / THERMAL"
if [ -d /sys/devices/system/cpu/cpu0/cpufreq ]; then
  echo "  cpufreq        : present ($(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver 2>/dev/null)/$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null))"
else
  echo "  cpufreq        : ABSENT (no Enhanced SpeedStep on this CPU — expected)"
fi
for z in /sys/class/thermal/thermal_zone*; do
  [ -d "$z" ] || continue
  printf '  %s: type=%s temp=%s\n' "$(basename "$z")" "$(cat "$z/type" 2>/dev/null)" "$(cat "$z/temp" 2>/dev/null)"
done
H=$(for h in /sys/class/hwmon/hwmon*; do [ "$(cat "$h/name" 2>/dev/null)" = eeepc ] && echo "$h"; done)
if [ -n "$H" ]; then
  echo "  fan: rpm=$(cat "$H/fan1_input" 2>/dev/null) pwm1=$(cat "$H/pwm1" 2>/dev/null) pwm1_enable=$(cat "$H/pwm1_enable" 2>/dev/null)"
else
  echo "  fan: no eeepc hwmon"
fi
hr
echo "=== eeepc-bench complete — saved to ${OUT:-<stdout only>} ==="
echo "Compare runs with:  diff <(sed 's/[0-9]\\+ ms/N ms/g' /var/log/eeepc-bench-BEFORE.txt) \\"
echo "                          <(sed 's/[0-9]\\+ ms/N ms/g' /var/log/eeepc-bench-AFTER.txt)"
