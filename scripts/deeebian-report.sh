#!/bin/bash
# deeebian-report.sh — collect full diagnostics from a Deeebian (Eee PC 701) system and
# send them to Hermes for review. Run as the normal user (sudo used where needed).
#
# Usage:
#   deeebian-report.sh                 # collect + upload to Hermes
#   deeebian-report.sh --local         # collect only, print tarball path
#   deeebian-report.sh --show          # just print the quick-reference / status banner
#   deeebian-report.sh --note "wifi drops every 10 min"   # attach a problem description
#
# Exit codes: 0 = tarball produced (and, if not --local, uploaded);
#             1 = tarball produced but no upload target reachable (so an unattended
#                 caller is NOT misled into thinking the report reached Hermes);
#             2 = bad usage. Nothing calls this automatically yet, so the exit codes
#             are informational; any future first-boot/unit caller should tolerate 1.
#
# Upload target: Hermes inbox on the homelab (scp prompts for sam's password unless
# an SSH key is already authorized). Override with DEEEPC_INBOX_HOST.
set -u

NOTE=""
LOCAL_ONLY=0
SHOW=0
while [ $# -gt 0 ]; do
    case "$1" in
        --local) LOCAL_ONLY=1; shift ;;
        --show) SHOW=1; shift ;;
        --note) NOTE="${2:-}"; shift 2 ;;
        -h|--help) grep '^#' "$0" | head -12; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

# --show: the desktop "System info" path. Print the quick reference and the live
# LAN IP, then exit -- no collection, no tarball, always exit 0. Works with or
# without `ip` (reads /proc/net/fib_trie), so it is safe before the PATH fix lands.
if [ "$SHOW" = "1" ]; then
    [ -r /etc/motd ] && cat /etc/motd
    ip4=$(grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' /proc/net/fib_trie 2>/dev/null \
          | grep -vE '^(0\.|127\.|255\.)' | sort -u | tr '\n' ' ')
    printf '  hostname: %s   LAN IP: %s\n\n' "$(hostname)" "${ip4:-none yet}"
    exit 0
fi

STAMP=$(date +%Y%m%d-%H%M%S)
HOST=$(hostname)
OUT="/tmp/deeebian-report-${HOST}-${STAMP}"
D="$OUT/data"
mkdir -p "$D"

runc() { # runc <file> <cmd...> : capture stdout+stderr
    local f="$1"; shift
    { echo "### $*"; echo; "$@" 2>&1; echo; } > "$D/$f" 2>&1
}

echo "Deeebian support report — collecting..."

# --- identity / system ---
runc uname.txt        uname -a
runc os-release.txt   cat /etc/os-release
runc cmdline.txt      cat /proc/cmdline
runc cpuinfo.txt      cat /proc/cpuinfo
runc meminfo.txt      free -m
runc uptime.txt       uptime
runc blkid.txt        cat /etc/fstab
runc grub.cfg.txt     cat /boot/grub/grub.cfg

# --- hardware inventory ---
runc lspci.txt        lspci -nnk
runc lsusb.txt        lsusb -t
runc lsusb-verbose.txt lsusb -v
runc lsblk.txt        lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT,MODEL
runc df.txt           df -h
runc mount.txt        mount

# --- expected-hardware self-check (Eee PC 701 matrix) ---
{
    echo "Expected 701 hardware probes (lspci -nn):"
    echo
    for dev in "168c:001c:Atheros AR5007EG wifi (ath5k)" \
               "1969:2048:Attansic/Atheros L2 ethernet (atl2)" \
               "8086:2590:Intel 915GM graphics (i915)" \
               "8086:2668:Intel ICH7 HDA audio (snd-hda-intel)"; do
        id="${dev%%:*}"; rest="${dev#*:}"; id="${id}"; name="${rest#*:}"
        if lspci -nn | grep -qi "$id"; then
            echo "  [FOUND]    $name"
        else
            echo "  [MISSING]  $name  (pci id $id)"
        fi
    done
    echo
    echo "USB webcam probe (uvcvideo):"
    lsusb | grep -i -E "camera|webcam|video|0ac8|046d|eb1a" || echo "  no obvious webcam in lsusb output"
    echo
    echo "Kernel driver binding summary (lspci -nnk / lsusb -t excerpts):"
    lspci -nnk | grep -A2 -i -E "network|ethernet|vga|audio|multimedia"
} > "$D/hardware-check.txt" 2>&1

# --- kernel / boot logs ---
runc dmesg.txt        dmesg
runc journal-errors.txt journalctl -b -p err --no-pager
runc journal-tail.txt journalctl -b -n 200 --no-pager
runc failed-units.txt systemctl --failed --no-pager
runc units.txt        systemctl --no-pager --type=service --state=running
runc boot-time.txt    bash -c "systemd-analyze; systemd-analyze critical-chain; systemd-analyze blame | head -25"

# --- eeepc platform specifics ---
{
    echo "=== /sys/devices/platform/eeepc ==="
    find /sys/devices/platform/eeepc -maxdepth 2 2>/dev/null | head -40
    for f in /sys/devices/platform/eeepc/*; do
        [ -f "$f" ] && [ -r "$f" ] && echo "--- $f" && cat "$f" 2>/dev/null
    done
    echo; echo "=== backlight ==="
    find /sys/class/backlight -maxdepth 2 2>/dev/null -exec sh -c 'echo "--- {}"; cat {}/brightness {}/max_brightness 2>/dev/null' \;
    echo; echo "=== battery / ac ==="
    for b in /sys/class/power_supply/*; do
        [ -d "$b" ] && echo "--- $b" && for f in "$b"/*; do [ -f "$f" ] && [ -r "$f" ] && echo "  $(basename "$f")=$(cat "$f" 2>/dev/null)"; done
    done
} > "$D/eeepc-platform.txt" 2>&1

# --- graphics / display ---
runc xrandr.txt       bash -c "DISPLAY=:0 xrandr --verbose 2>&1 | head -80"
runc drm.txt          bash -c "ls -la /sys/class/drm/; for f in /sys/class/drm/card*-*/status; do echo \"--- \$f\"; cat \$f; done"
runc xorg-log.txt     bash -c "tail -120 /var/log/Xorg.0.log 2>/dev/null || journalctl -u lightdm -b --no-pager | tail -60"

# --- audio ---
runc aplay.txt        aplay -l
runc amixer.txt       amixer contents
runc audio-service.txt systemctl --no-pager status alsa-unmute.service

# --- network ---
runc nm-devices.txt   nmcli device
runc nm-conn.txt      nmcli -f NAME,UUID,TYPE,DEVICE connection show
runc ip-addr.txt      ip addr
runc ip-route.txt     ip route
runc iw.txt           bash -c "iw dev 2>/dev/null; iwconfig 2>/dev/null"
runc wpa.txt          systemctl --no-pager status wpa_supplicant.service
{
    gw=$(ip route | awk '/default/ {print $3; exit}')
    [ -n "$gw" ] && ping -c 3 -W 2 "$gw" 2>&1
    ping -c 3 -W 2 1.1.1.1 2>&1
    getent hosts github.com 2>&1
} > "$D/connectivity.txt" 2>&1

# --- storage / SD health ---
runc sd-messages.txt  bash -c "dmesg | grep -i -E 'sd |mmc|usb-storage|ata[0-9]|I/O error|buffer' | tail -60"
runc smart.txt        bash -c "sudo -n smartctl -a /dev/sda 2>&1 || smartctl -a /dev/sda 2>&1 || echo 'smartctl unavailable'"
runc ioerrors.txt     bash -c "sudo -n dmesg -l err,crit,alert 2>/dev/null || true"

# --- memory / swap / zram ---
runc zram.txt         bash -c "swapon --show; zramctl 2>/dev/null; cat /sys/block/zram0/comp_algorithm /sys/block/zram0/disksize 2>/dev/null; cat /proc/swaps"

# --- packages / versions ---
{
    echo "Key package versions:"
    dpkg-query -W -f='${Package}\t${Version}\n' 2>/dev/null | grep -E "^(linux-image|network-manager|xserver-xorg|openbox|tint2|firefox-esr|netsurf|lightdm|zram|earlyoom|firmware-atheros|grub-pc|systemd|dbus|alsa-utils|pulseaudio|pipewire)" | sort
    echo; echo "Held / broken packages:"
    dpkg --get-selections | grep -v install$ || true
    echo; apt-get -s upgrade 2>&1 | tail -5
} > "$D/packages.txt" 2>&1

# --- user note ---
if [ -n "$NOTE" ]; then
    printf 'User-reported issue:\n%s\n' "$NOTE" > "$D/USER-NOTE.txt"
fi

# --- summary (read first) ---
{
    echo "Deeebian support report — $HOST — $(date -Is)"
    echo "Kernel: $(uname -r)   Arch: $(uname -m)   Uptime: $(uptime -p 2>/dev/null)"
    echo "CPU:    $(grep -m1 'model name' /proc/cpuinfo)   PAE flag: $(grep -o -m1 pae /proc/cpuinfo || echo none)"
    echo "RAM:    $(free -m | awk '/Mem:/ {print $2" MB total, "$3" used"}')   Swap: $(swapon --show=NAME,SIZE,USED --noheadings 2>/dev/null | tr '\n' ' ')"
    echo "Rootfs: $(df -h / | awk 'NR==2 {print $3" used of "$2" ("$5")"}')"
    echo "Failed units: $(systemctl --failed --no-legend 2>/dev/null | wc -l)"
    systemctl --failed --no-legend --plain 2>/dev/null | sed 's/^/  FAILED: /'
    echo "Journal errors this boot: $(journalctl -b -p err --no-legend 2>/dev/null | wc -l)"
    echo "dmesg error/warn lines: $(dmesg -l err,crit,alert,warn 2>/dev/null | wc -l)"
    echo "Storage I/O errors: $(dmesg 2>/dev/null | grep -ci 'I/O error')"
    echo "Network: $(nmcli -t -f DEVICE,STATE,CONNECTION device | grep -v unmanaged | tr '\n' ' ')"
    [ -n "$NOTE" ] && echo "User note: $NOTE"
    echo; echo "Files in this report: $(ls "$D" | wc -l) (see data/)"
} > "$OUT/SUMMARY.txt"

# --- pack ---
TARBALL="${OUT}.tar.gz"
tar -C "$OUT" -czf "$TARBALL" SUMMARY.txt data
rm -rf "$OUT"
echo
echo "Report written: $TARBALL ($(du -h "$TARBALL" | cut -f1))"

[ "$LOCAL_ONLY" = "1" ] && exit 0

# --- upload to Hermes inbox ---
# Override with DEEEPC_INBOX_HOST=<host> if your homelab address differs.
# NOTE: sam@hermes-prod.nb.rip no longer resolves; the NetBird address below does.
TARGETS="${DEEEPC_INBOX_HOST:-sam@100.69.56.74}"
for t in $TARGETS; do
    echo "Uploading to $t:deeebian-inbox/ ..."
    if scp -o ConnectTimeout=8 -o BatchMode=yes "$TARBALL" "$t:deeebian-inbox/" 2>/dev/null; then
        UPLOADED=1; break
    fi
    # interactive fallback (password prompt)
    if scp -o ConnectTimeout=8 "$TARBALL" "$t:deeebian-inbox/" 2>/dev/null; then
        UPLOADED=1; break
    fi
    echo "  $t unreachable, trying next..."
done

if [ "${UPLOADED:-0}" = "1" ]; then
    echo
    echo "Done. Hermes has been notified via the inbox watcher and will review,"
    echo "file an issue, and work the fix pipeline. Keep this file: $TARBALL"
else
    echo
    echo "Could not reach Hermes. Options:"
    echo "  - connect this Eee PC to your home LAN and re-run this script, or"
    echo "  - copy $TARBALL to any machine that can reach Hermes and:"
    echo "      scp $TARBALL ${DEEEPC_INBOX_HOST:-sam@100.69.56.74}:deeebian-inbox/"
    exit 1
fi
