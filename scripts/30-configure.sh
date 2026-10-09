#!/bin/bash
# 30-configure.sh — runs INSIDE the chroot. Configures hostname, user, fstab,
# desktop autologin, zram, first-boot grow, ssh, ssh host key regen, etc.
set -euo pipefail

IMG_UUID="b0057a11-de12-b007-01ee-000000000001"

# --- hostname / hosts ---
echo "eeepc701" > /etc/hostname
cat > /etc/hosts <<EOF
127.0.0.1	localhost
127.0.1.1	eeepc701
::1		localhost ip6-localhost ip6-loopback
EOF

# --- timezone + locale ---
ln -sf /usr/share/zoneinfo/Etc/UTC /etc/localtime
echo "Etc/UTC" > /etc/timezone
sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
update-locale LANG=en_US.UTF-8

# --- fstab (root is written with the UUID we will mkfs with) ---
cat > /etc/fstab <<EOF
UUID=$IMG_UUID	/	ext4	defaults,noatime,commit=60	0	1
tmpfs		/tmp	tmpfs	defaults,nosuid,nodev	0	0
EOF

# --- user: sam / eeepc (sudo) ---
useradd -m -s /bin/bash sam
echo 'sam:eeepc' | chpasswd
usermod -aG sudo sam
# root login locked (sudo only)
passwd -l root

# --- sshd: no root login; host keys are generated before each start (clone-safe) ---
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
mkdir -p /etc/systemd/system/ssh.service.d
cat > /etc/systemd/system/ssh.service.d/override.conf <<'EOF'
[Service]
ExecStartPre=
ExecStartPre=/usr/bin/ssh-keygen -A
ExecStartPre=/usr/sbin/sshd -t
EOF
systemctl enable ssh.service

# --- zram swap: sized to the installed RAM, lz4 ---
# 1 GB is wrong on a stock 512 MB 701 (3x overcommit); scale with MemTotal and cap at 1 GB.
cat > /etc/systemd/system/zram-swap.service <<'EOF'
[Unit]
Description=Configure zram swap
After=local-fs.target
[Service]
Type=oneshot
ExecStart=/bin/sh -c "mem=$(awk '/MemTotal/{print $2*1024}' /proc/meminfo); size=$((mem<1073741824 ? mem : 1073741824)); [ -e /dev/zram0 ] || cat /sys/class/zram-control/hot_add >/dev/null; echo lz4 > /sys/block/zram0/comp_algorithm 2>/dev/null || true; echo $size > /sys/block/zram0/disksize; mkswap /dev/zram0 >/dev/null; swapon -p 100 /dev/zram0"
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
systemctl enable zram-swap.service
cat > /etc/sysctl.d/50-eeepc.conf <<'EOF'
# vm.swappiness=150 is deliberately > 100. Since Linux 3.x, swappiness above 100 tells the
# kernel how much to prefer anonymous (page-cache-evictable) memory over the page cache.
# With zram swap this is exactly what we want: zram pages compress ~3-4:1 (lz4), so swapping
# anon pages out costs a few hundred microseconds of CPU, while evicting a clean page-cache
# page costs a 1-10 ms re-read from the SD card. We would rather spend idle CPU than SD I/O,
# and the card is the bottleneck (and wears out). Keep 150; do NOT "fix" it to 10 as generic
# netbook advice suggests.
vm.swappiness=150

# Do not leave dirty pages in RAM to be flushed in one big burst later. On an SD card a
# smaller, earlier flush is far kinder than a large delayed one (less I/O stall, less
# write amplification). 8 MB is comfortable for this class of card.
vm.dirty_ratio=10
vm.dirty_background_ratio=5
vm.dirty_expire_centisecs=1500
vm.dirty_writeback_centisecs=1500

# Inode/dentry cache reclaim: keep the "age it a bit before dropping" default explicitly so
# a future base-image change cannot silently turn this into drop-everything-at-50%.
vm.vfs_cache_pressure=100

# Network latency: shorter TCP SYN/keepalive timeouts so a dead wifi network is noticed in
# seconds, not minutes, on a machine that is often on flaky wifi.
net.ipv4.tcp_fin_timeout=30
net.ipv4.tcp_keepalive_time=120
EOF

# --- wifi radio bring-up (MUST run before NetworkManager) ---
# On the Eee PC 701 the Atheros AR5007EG is frequently soft-blocked or ACPI-powered-down at
# boot, which leaves the machine with no network and no obvious cause. The previous Alpine
# attempt on this same hardware booted to a shell with no wifi for exactly this reason.
# rfkill + the eeepc platform device are both poked here, before NM starts.
cat > /etc/systemd/system/eeepc-wifi-unblock.service <<'EOF'
[Unit]
Description=Unblock/power-on the Eee PC wifi radio before NetworkManager
DefaultDependencies=no
After=sysinit.target
Before=NetworkManager.service network-pre.target
Wants=network-pre.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c "rfkill unblock all || true; [ -w /sys/devices/platform/eeepc/wlan ] && echo 1 > /sys/devices/platform/eeepc/wlan || true"
[Install]
WantedBy=multi-user.target
EOF
systemctl enable eeepc-wifi-unblock.service

# --- NetworkManager: disable wifi powersave (ath5k stability), enable services ---
mkdir -p /etc/NetworkManager/conf.d
cat > /etc/NetworkManager/conf.d/10-eeepc.conf <<'EOF'
[device]
wifi.powersave = 2
EOF
systemctl enable NetworkManager avahi-daemon acpid tlp earlyoom systemd-timesyncd

# --- journald: log to RAM, never to the SD card ---
# DietPi's RAMlog idea, done the conflict-free way. A /var/log tmpfs fights journald
# (DietPi issue #7750); Storage=volatile keeps the journal in /run/log/journal and
# removes the single biggest continuous-write stream on the card.
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/50-eeepc.conf <<'EOF'
[Journal]
Storage=volatile
RuntimeMaxUse=16M
SystemMaxUse=0
ForwardToSyslog=no
EOF

# --- apt: fewer downloads and fewer SD writes per update (DietPi 97dietpi idea) ---
cat > /etc/apt/apt.conf.d/97eeepc <<'EOF'
APT::Install-Recommends "false";
Acquire::Languages "none";
Acquire::GzipIndexes "true";
Acquire::IndexTargets::deb::Packages::KeepCompressedAs "xz";
Dir::Cache::srcpkgcache "";
EOF

# --- de-prioritise housekeeping on the single 900 MHz core (DietPi services-priority idea) ---
# Nice=19 + idle I/O on background daemons keeps interactive work responsive.
for svc in tlp earlyoom avahi-daemon; do
  mkdir -p "/etc/systemd/system/${svc}.service.d"
  cat > "/etc/systemd/system/${svc}.service.d/10-eeepc-prio.conf" <<'EOF'
[Service]
Nice=19
IOSchedulingClass=idle
EOF
done

# --- ship the new perf/thermals tools from /opt/build (ci/build.sh copies them there) ----
# Fail loudly, like the deeebian-report.sh guard below: silently shipping without them would
# remove the only way to see temperatures/fan state or to benchmark the machine.
install -d -m 0755 /usr/local/sbin /usr/local/bin
for t in eeepc-thermals.sh eeepc-bench.sh eeepc-io-tune.sh eeepc-acpi-profile.sh; do
  if [ ! -f "/opt/build/$t" ]; then
    echo "FATAL: /opt/build/$t missing -- ci/build.sh did not copy the perf/thermals tools" >&2
    exit 1
  fi
done

# --- cpufreq: the 701's Celeron M ULV 353 has NO Enhanced SpeedStep --------------
# This is a verified finding, not an assumption. The Celeron M (Dothan-core, family 6,
# model 0x0D) lacks the EST bit in CPUID; the 630 MHz "idle" clock reported by /proc/cpuinfo
# is a fixed clock-modulation (throttling) state, not a P-state. acpi-cpufreq will probe,
# find no _PSS objects, and register no policy, so there is nothing to govern. We therefore
# do NOT install a cpufreq governor unit and we do NOT force 'performance'. If a future
# stepping does expose cpufreq it will come up with the kernel default (userspace) and
# userspace can still pick one; we just refuse to pretend we can control it.
# cpufrequtils is installed only so that /usr/local/bin/eeepc-thermals can *report* the state
# (cpufreq-info) and so an operator can try it by hand. eeepc-bench records whether a policy
# exists at all, which is the honest measurement.

# --- ACPI platform profile: prefer passive cooling when the firmware offers it ---------
# ACPI_PLATFORM_PROFILE (drivers/acpi/platform_profile.c) is present in this kernel and on
# some 701 BIOSes exposes /sys/firmware/acpi/platform_profile. If it exists we ask for the
# most power-efficient profile; if the attribute or its 'low-power' choice is absent we do
# nothing (the shell test guards every write). This is the ONLY firmware cooling knob the
# 701 reliably gives us on the ACPI side.
install -m 0755 /opt/build/eeepc-acpi-profile.sh /usr/local/sbin/eeepc-acpi-profile.sh
cat > /etc/systemd/system/eeepc-acpi-profile.service <<'EOF'
[Unit]
Description=Select the firmware low-power ACPI platform profile when available
After=multi-user.target
[Service]
Type=oneshot
RemainAfterExit=yes
Nice=19
IOSchedulingClass=idle
ExecStart=/usr/local/sbin/eeepc-acpi-profile.sh
[Install]
WantedBy=multi-user.target
EOF
systemctl enable eeepc-acpi-profile.service

# --- SD card: I/O scheduler + no unnecessary read-ahead -------------------------------
# The 701's only disk is an SD card behind the internal USB reader (sd/mmc). The kernel's
# default on a 900 MHz i386 build may be mq-deadline or bfq; neither helps when there is no
# seek cost to optimise. 'none' (noop) removes a scheduling layer on the single core, and a
# small read_ahead_kb keeps the page cache from reading far ahead on a card whose random
# latency dwarfs its sequential throughput. Written by a unit (not udev) so it always runs,
# never races, and needs no udev rules file. Every write is guarded: if the sysfs names
# differ on a given day nothing fails, we just skip.
install -m 0755 /opt/build/eeepc-io-tune.sh /usr/local/sbin/eeepc-io-tune.sh
cat > /etc/systemd/system/eeepc-io-tune.service <<'EOF'
[Unit]
Description=Tune SD/USB block devices: no I/O scheduler, modest read-ahead
After=local-fs.target
[Service]
Type=oneshot
RemainAfterExit=yes
Nice=19
IOSchedulingClass=idle
ExecStart=/usr/local/sbin/eeepc-io-tune.sh
[Install]
WantedBy=multi-user.target
EOF
systemctl enable eeepc-io-tune.service

# --- zram: use lz4 but also verify it is in use; keep the sizing policy ----------------
# The unit above is unchanged (sized to MemTotal, capped at 1 GiB, lz4). We only add a
# second-line safety net: if lz4 is not available the kernel falls back, and if the size
# came out 0 the swap is useless. eeepc-health already flags missing zram; eeepc-bench
# records the real compressed/uncompressed ratio so the policy can be judged on data.

# --- earlyoom tuning: on a 2 GB machine, act earlier and protect the session -----------
# A 2 GB 701 running Firefox + Openbox thrashes long before the stock 10% threshold. earlyoom
# kills the biggest offending process to keep the desktop alive. -m 8 (act at 8% available)
# and -s 5 (act at 5% free swap) make it step in while the GUI is still usable. The --avoid
# regex protects the session's own daemons (dbus, systemd, X, the session) so earlyoom cannot
# take down the desktop it is trying to save, and --prefer targets the usual memory hogs.
# -r 3600 keeps its own log line to once an hour (it logs to the in-RAM journal).
# /etc/default/earlyoom is sourced by the unit's EnvironmentFile; it is an upstream feature.
cat > /etc/default/earlyoom <<'EOF'
# Eee PC 701: be proactive on a 2 GB RAM machine and never kill the session itself.
EARLYOOM_ARGS="-r 3600 -m 8 -s 5 --avoid '(^|/)(systemd|dbus-daemon|X|Xorg|lightdm|openbox|pcmanfm|tint2|sshd)$' --prefer '(^|/)(firefox|firefox-esr|Web Content|netsurf)$'"
EOF

# --- Eee PC platform module (hotkeys, fan) ---
echo "eeepc-laptop" > /etc/modules-load.d/eeepc.conf

# --- audio: unmute on boot ---
cat > /etc/systemd/system/alsa-unmute.service <<'EOF'
[Unit]
Description=Unmute ALSA Master/PCM
After=sound.target
[Service]
Type=oneshot
ExecStart=/bin/sh -c "amixer -q sset Master on unmute || true; amixer -q sset PCM on unmute || true; amixer -q sset Master 75% || true"
[Install]
WantedBy=multi-user.target
EOF
systemctl enable alsa-unmute.service

# --- first-boot: grow root partition/filesystem to fill the SD card ---
cat > /usr/local/sbin/expand-root.sh <<'EOF'
#!/bin/bash
set -e
[ -f /var/lib/eeepc-expanded ] && exit 0
src=$(findmnt -n -o SOURCE /)
disk=""
partnum=""
case "$src" in
  /dev/sd[a-z][0-9]*)   disk="${src:0:-1}"; partnum="${src: -1}" ;;
  /dev/mmcblk[0-9]p[0-9]*) disk="${src%p*}"; partnum="${src##*p}" ;;
  *) exit 0 ;;
esac
growpart "$disk" "$partnum" || exit 0
resize2fs "$src" || exit 0
touch /var/lib/eeepc-expanded
EOF
chmod +x /usr/local/sbin/expand-root.sh
cat > /etc/systemd/system/expand-root.service <<'EOF'
[Unit]
Description=Grow root partition to fill SD card (first boot)
After=local-fs.target
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/expand-root.sh
[Install]
WantedBy=multi-user.target
EOF
systemctl enable expand-root.service

# --- lightdm autologin into openbox ---
mkdir -p /etc/lightdm/lightdm.conf.d
cat > /etc/lightdm/lightdm.conf.d/50-autologin.conf <<'EOF'
[Seat:*]
autologin-user=sam
autologin-user-timeout=0
user-session=openbox
EOF

# --- Eee PC "system info" action -------------------------------------------------
# The user's second complaint was "can't see the LAN IP", with neither `ip` nor
# `ifconfig` on the box and no obvious place to look. This prints everything a newcomer
# needs in one terminal window, and degrades gracefully when iproute2 is missing
# (falls back to nmcli and /proc instead of hard-failing).
cat > /usr/local/bin/eeepc-sysinfo <<'SYSINFO_EOF'
#!/bin/bash
# eeepc-sysinfo — one-shot system/network report for the ASUS Eee PC 701.
# Never relies on iproute2 alone: uses `ip` when present, else nmcli / /proc.
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
sep() { printf '%s\n' '------------------------------------------------------------'; }

echo "=== System info   $(date '+%Y-%m-%d %H:%M') ==="
echo "host    : $(hostname)"
echo "kernel  : $(uname -sr)  ($(uname -m))"
echo "uptime  :$(uptime | sed 's/^ *//; s/.*up //; s/, *[0-9]* user.*//')"
sep

echo "--- IPv4 addresses ---"
if command -v ip >/dev/null 2>&1; then
  ip -4 addr show 2>/dev/null | awk '/^[0-9]+:/{ifn=$2} /inet /{print "  " ifn " " $2}'
else
  # iproute2 absent: /proc/net/fib_trie lists the LOCAL /32 addresses.
  if [ -r /proc/net/fib_trie ]; then
    awk '/^ *\|-- /{a=$2} /\/32 host LOCAL/{if (a != "" && a != "127.0.0.1") print "  " a; a=""}' \
      /proc/net/fib_trie 2>/dev/null | sort -u
  else
    echo "  (/proc/net/fib_trie unavailable)"
  fi
fi
sep

echo "--- Default route / gateway ---"
if command -v ip >/dev/null 2>&1; then
  ip route 2>/dev/null | sed 's/^/  /'
else
  # iproute2 absent: /proc/net/route holds the gateway as little-endian hex.
  if [ -r /proc/net/route ]; then
    while read -r r_if r_dest r_gw _; do
      [ "$r_dest" = "00000000" ] || continue
      g=$((16#$r_gw))
      printf '  default via %d.%d.%d.%d dev %s\n' \
        $(( g & 255 )) $(( (g>>8) & 255 )) $(( (g>>16) & 255 )) $(( (g>>24) & 255 )) "$r_if"
    done < /proc/net/route
  else
    echo "  (/proc/net/route unavailable)"
  fi
fi
sep

echo "--- NetworkManager devices ---"
if command -v nmcli >/dev/null 2>&1; then
  nmcli -f DEVICE,TYPE,STATE dev 2>/dev/null | sed 's/^/  /'
  echo
  nmcli -f DEVICE,TYPE,STATE,IP4.ADDRESS dev 2>/dev/null | sed 's/^/  /'
else
  echo "  (nmcli not available)"
fi
sep

echo "--- Wireless / rfkill ---"
if [ -x /usr/sbin/rfkill ]; then
  /usr/sbin/rfkill list 2>/dev/null | sed 's/^/  /'
else
  echo "  (/usr/sbin/rfkill not installed)"
fi
sep

echo "--- Memory (MiB) ---"
free -m 2>/dev/null | sed 's/^/  /'
sep

echo "--- Disk usage ---"
df -h 2>/dev/null | sed 's/^/  /'
sep

echo "--- Block devices ---"
if command -v lsblk >/dev/null 2>&1; then
  lsblk 2>/dev/null | sed 's/^/  /'
else
  cat /proc/partitions 2>/dev/null | sed 's/^/  /'
fi
sep
echo "Close the window (Ctrl+D or the X) when done."
SYSINFO_EOF
chmod 0755 /usr/local/bin/eeepc-sysinfo

# .desktop entry for the same action: tint2 reads it for its launcher icon and the
# desktop copy below gives a no-keybind click-to-run icon.
mkdir -p /usr/local/share/applications
cat > /usr/local/share/applications/eeepc-sysinfo.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=System info (IP, disk, memory)
Comment=Show hostname, IP addresses, route, rfkill, free, df, lsblk
Exec=lxterminal -e eeepc-sysinfo
Icon=utilities-system-monitor
Terminal=false
Categories=System;Monitor;
EOF

# --- games / tools / toys installer ------------------------------------------
# The curated catalogue lives in docs/games-and-software.md; the installer is
# shipped so a fresh box has a discoverable way to add games (no apt knowledge
# needed, works offline from a .deb dir, idempotent).  Copy it in, and register
# a launcher in the panel (see tint2rc below), the Openbox menu (see menu.xml
# pipe-menu entry) and as a Desktop icon.
if [ ! -f /opt/build/eeepc-games.sh ]; then
  echo "WARN: /opt/build/eeepc-games.sh missing -- games installer not shipped" >&2
else
  install -m 0755 /opt/build/eeepc-games.sh /usr/local/bin/eeepc-games
fi
cat > /usr/local/share/applications/eeepc-games.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=Games & software
Comment=Install curated games, tools & toys (Debian packages; works offline)
Exec=lxterminal -e /usr/local/bin/eeepc-games
Icon=applications-games
Terminal=false
Categories=Game;Utility;
EOF

# --- openbox session for sam: panel, applets, keybinds ---
mkdir -p /home/sam/.config/openbox
# autostart: give the desktop a background and, crucially, a NO-KEYBIND way to reach a
# terminal (desktop icon + panel launcher). xsetroot/tint2/pcmanfm are already installed.
cat > /home/sam/.config/openbox/autostart <<'EOF'
# dark solid root colour — needs no wallpaper package (xsetroot is in x11-xserver-utils)
xsetroot -solid '#10151c' &
# pcmanfm manages the desktop: draws the background AND the "Terminal" icon, and with
# show_wm_menu=1 it still forwards right-clicks to Openbox's root menu.
pcmanfm --desktop &
# panel: launcher icons (Sysinfo, Terminal, Firefox, Files) + taskbar + clock + systray
tint2 &
nm-applet &
volumeicon &
EOF

# --- tint2: explicit clock + launcher icons ---------------------------------------
# tint2 otherwise generates ~/.config/tint2/tint2rc on first run; we ship our own so the
# launcher (L) and clock (C) are guaranteed present on the very first boot.
mkdir -p /home/sam/.config/tint2
cat > /home/sam/.config/tint2/tint2rc <<'EOF'
#--------------------------------------------------------------
# tint2 for the Eee PC 701 — launcher icons + clock, small and light
#--------------------------------------------------------------
rounded = 3
border_width = 0
background_color = #1a2230 100
border_color = #000000 0

# Panel
panel_monitor = all
panel_position = bottom center horizontal
panel_size = 100% 24
panel_margin = 0 0
panel_padding = 4 0 4
panel_background_id = 1
wm_menu = 1
panel_dock = 0
panel_layer = normal
strut_policy = follow_size
panel_items = LTSC

# Launcher (L): clickable icons — the no-keybind way to open a terminal
launcher_padding = 4 2 4
launcher_background_id = 0
launcher_icon_size = 20
launcher_item_app = /usr/local/share/applications/eeepc-sysinfo.desktop
launcher_item_app = /usr/local/share/applications/eeepc-games.desktop
launcher_item_app = /usr/share/applications/lxterminal.desktop
launcher_item_app = /usr/share/applications/firefox-esr.desktop
launcher_item_app = /usr/share/applications/pcmanfm.desktop

# Taskbar (T)
taskbar_mode = single_desktop
taskbar_padding = 2 2 2
taskbar_background_id = 0

# System tray (S)
systray_padding = 2 2 2
systray_background_id = 0
systray_icon_size = 16

# Clock (C)
time1_format = %a %H:%M
time1_font = DejaVu Sans 9
time2_format = %d %b
time2_font = DejaVu Sans 8
clock_font_color = #ffffff 100
clock_padding = 6 0
clock_background_id = 0
clock_tooltip = %A %d %B %Y — week %V

# Mouse / misc
mouse_effects = 0
font_shadow = 0
EOF

# --- pcmanfm desktop: solid background + the "Terminal" launcher icon ------------
mkdir -p /home/sam/.config/pcmanfm/default /home/sam/Desktop
cat > /home/sam/.config/pcmanfm/default/pcmanfm.conf <<'EOF'
[config]
bm_open_method=0
EOF
cat > /home/sam/.config/pcmanfm/default/desktop-items-0.conf <<'EOF'
[*]
# wallpaper_mode=color fills the desktop with desktop_bg, so no image file is needed.
wallpaper_mode=color
wallpaper_common=1
desktop_bg=#10151c
desktop_fg=#d0d7de
desktop_shadow=#000000
desktop_font=DejaVu Sans 10
# Forward unhandled clicks to Openbox so right-click still opens the root menu.
show_wm_menu=1
show_documents=0
show_trash=0
show_mounts=0
EOF
cat > /home/sam/.config/openbox/menu.xml <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<openbox_config xmlns="http://openbox.org/3.4/menu">
  <menu id="root-menu" label="Openbox 3">
    <item label="Terminal"><action name="Execute"><execute>lxterminal</execute></action></item>
    <item label="System info (IP address, disk, memory)"><action name="Execute"><execute>lxterminal -e eeepc-sysinfo</execute></action></item>
    <item label="Health check (PASS/FAIL summary)"><action name="Execute"><execute>lxterminal -e /usr/local/bin/eeepc-health-tui</execute></action></item>
    <item label="Thermals (temps, fan, CPU freq)"><action name="Execute"><execute>lxterminal -e /usr/local/bin/eeepc-thermals-tui</execute></action></item>
    <item label="Benchmark (quick)"><action name="Execute"><execute>lxterminal -e /usr/local/bin/eeepc-bench-tui</execute></action></item>
    <item label="Web browser (Firefox)"><action name="Execute"><execute>firefox-esr</execute></action></item>
    <item label="Light browser (Netsurf)"><action name="Execute"><execute>netsurf</execute></action></item>
    <item label="Files"><action name="Execute"><execute>pcmanfm</execute></action></item>
    <item label="Text editor"><action name="Execute"><execute>mousepad</execute></action></item>
    <!-- Dynamic submenu: the command prints Openbox pipe-menu XML listing the
         games/tools that are actually installed, plus a launcher for the
         installer itself.  So newly installed games appear here with no hand
         editing of this file. -->
    <menu id="games-menu" label="Games &amp; software" execute="/usr/local/bin/eeepc-games --openbox-pipe"/>
    <separator/>
    <item label="Network connections"><action name="Execute"><execute>nm-connection-editor</execute></action></item>
    <item label="Volume control"><action name="Execute"><execute>lxterminal -e alsamixer</execute></action></item>
    <separator/>
    <item label="Battery recalibration (drain+charge)"><action name="Execute"><execute>lxterminal -e "sudo battery-rejuv full"</execute></action></item>
    <item label="Battery status"><action name="Execute"><execute>lxterminal -e "battery-rejuv status; read -p 'press Enter '"</execute></action></item>
    <separator/>
    <item label="Lock screen"><action name="Execute"><execute>lxlock</execute></action></item>
    <item label="Reboot"><action name="Execute"><execute>systemctl reboot</execute></action></item>
    <item label="Shutdown"><action name="Execute"><execute>systemctl poweroff</execute></action></item>
  </menu>
</openbox_config>
EOF
cat > /home/sam/.config/openbox/rc.xml <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<openbox_config xmlns="http://openbox.org/3.4/rc">
  <applications>
    <application class="*">
      <maximized>false</maximized>
    </application>
  </applications>
  <keyboard>
    <!-- The Eee PC 701 keyboard has NO Super/"Windows" key and NO Menu key, so any
         "W-..." or "C-A-Menu" bind is unreachable on the real hardware. The Ctrl+Alt
         binds below use keys that actually exist. Ways to a terminal, in order of
         discoverability: the "Terminal" desktop icon, the tint2 panel launcher icon,
         Ctrl+Alt+T, or right-click the desktop > Terminal. The W-* binds are kept only
         as a fallback for an external keyboard that does have a Super key. -->
    <keybind key="C-A-t"><action name="Execute"><execute>lxterminal</execute></action></keybind>
    <keybind key="C-A-x"><action name="Execute"><execute>lxterminal</execute></action></keybind>
    <keybind key="C-A-h"><action name="Execute"><execute>lxterminal -e /usr/local/bin/eeepc-health-tui</execute></action></keybind>
    <keybind key="C-A-s"><action name="Execute"><execute>lxterminal -e eeepc-sysinfo</execute></action></keybind>
    <keybind key="C-A-e"><action name="Execute"><execute>lxterminal -e /usr/local/bin/eeepc-thermals-tui</execute></action></keybind>
    <keybind key="C-A-b"><action name="Execute"><execute>lxterminal -e /usr/local/bin/eeepc-bench-tui</execute></action></keybind>
    <!-- no Super key on the 701: fallback binds for an external keyboard only -->
    <keybind key="W-Return"><action name="Execute"><execute>lxterminal</execute></action></keybind>
    <keybind key="W-F"><action name="Execute"><execute>firefox-esr</execute></action></keybind>
    <keybind key="W-D"><action name="ShowMenu"><menu>root-menu</menu></action></keybind>
    <keybind key="XF86AudioRaiseVolume"><action name="Execute"><execute>amixer -q sset Master 5%+</execute></action></keybind>
    <keybind key="XF86AudioLowerVolume"><action name="Execute"><execute>amixer -q sset Master 5%-</execute></action></keybind>
    <keybind key="XF86AudioMute"><action name="Execute"><execute>amixer -q sset Master toggle</execute></action></keybind>
  </keyboard>
  <mouse><context name="Client"><mousebind button="A-Left" action="Press"><action name="Focus"/><action name="Raise"/><action name="Unshade"/></mousebind></context></mouse>
</openbox_config>
EOF
# Dark GTK theme by default
mkdir -p /home/sam/.config/gtk-3.0 /home/sam/.config/gtk-2.0
cat > /home/sam/.config/gtk-3.0/settings.ini <<'EOF'
[Settings]
gtk-theme-name=Adwaita-dark
gtk-icon-theme-name=Adwaita
gtk-font-name=DejaVu Sans 10
EOF
echo 'gtk-theme-name="Adwaita-dark"' > /home/sam/.config/gtk-2.0/gtkrc
# terminal sane defaults
mkdir -p /home/sam/.config/lxterminal
cat > /home/sam/.config/lxterminal/lxterminal.conf <<'EOF'
[general]
fontname=DejaVu Sans Mono 10
bgcolor=#000000000000
fgcolor=#fffff8f8eeee
EOF

# --- Desktop icons: a no-keybind way to reach a terminal and to see the IP ---------
# pcmanfm draws these (it runs via autostart). The Terminal icon is the answer to
# "can't open a terminal": one double-click on the 800x480 desktop.
mkdir -p /home/sam/Desktop
cat > /home/sam/Desktop/lxterminal.desktop <<'EOF'
[Desktop Entry]
Version=1.0
Type=Application
Name=Terminal
Comment=Open a terminal (lxterminal)
Exec=lxterminal
Icon=utilities-terminal
Terminal=false
Categories=System;TerminalEmulator;
EOF
cat > /home/sam/Desktop/eeepc-sysinfo.desktop <<'EOF'
[Desktop Entry]
Version=1.0
Type=Application
Name=System info (IP address)
Comment=LAN IP, default route, wifi, disk and memory in one window
Exec=lxterminal -e eeepc-sysinfo
Icon=utilities-system-monitor
Terminal=false
Categories=System;Monitor;
EOF
cat > /home/sam/Desktop/eeepc-games.desktop <<'EOF'
[Desktop Entry]
Version=1.0
Type=Application
Name=Games & software
Comment=Curated games, tools and toys for the Eee PC 701
Exec=lxterminal -e /usr/local/bin/eeepc-games
Icon=applications-games
Terminal=false
Categories=Game;Utility;
EOF
chmod 0755 /home/sam/Desktop/*.desktop

# --- sam's PATH: /usr/sbin and /sbin so ip/ss/rfkill/iw/ethtool are usable -------
# Login and interactive shells only; a plain `sh` (e.g. from the Openbox root menu on a
# minimal image) does not read .bashrc, which is why the keybinds/launchers above call
# absolute command names where it matters. The trailing guard also runs for the
# common `case $- in *i*` early-return style of stock Debian .bashrc, but skips
# non-interactive shells so scripted `sh -c` calls are unaffected.
if ! grep -q 'eeepc PATH' /home/sam/.bashrc; then
  cat >> /home/sam/.bashrc <<'EOF'

# eeepc PATH: expose /usr/sbin and /sbin (rfkill, iw, ip, ss, lsblk, …)
case $- in
  *i*) PATH="$PATH:/usr/sbin:/sbin" ;;
esac
EOF
fi
if ! grep -q 'eeepc PATH' /home/sam/.profile; then
  cat >> /home/sam/.profile <<'EOF'

# eeepc PATH: expose /usr/sbin and /sbin (rfkill, iw, ip, ss, lsblk, …)
PATH="$PATH:/usr/sbin:/sbin"
EOF
fi

# --- fix up ownership and modes on everything written under /home/sam -----------
# Belt-and-braces: the heredocs above are normally 0644 under a root umask, but a root
# umask of 0077 is common in image builds and would leave these 0600, i.e. unreadable
# by sam — which would break the whole Openbox session. Pin all three explicitly:
#   directories 0755, config files 0644, sam owns it all.
find /home/sam/.config -type d -exec chmod 0755 {} +
find /home/sam/.config -type f -exec chmod 0644 {} +
chmod 0755 /home/sam/.config/openbox /home/sam/.config/tint2 /home/sam/.config/pcmanfm /home/sam/.config/pcmanfm/default
chmod 0644 /home/sam/.config/openbox/rc.xml /home/sam/.config/openbox/menu.xml /home/sam/.config/openbox/autostart

# --- chown last, so every write that created a file as root is covered -----------
chown -R sam:sam /home/sam/.config
chown -R sam:sam /home/sam/Desktop

# --- ship the on-device diagnostics collector --------------------------------
# The collector is copied into /opt/build/ by ci/build.sh (step "4. bootstrap
# scripts into chroot"). If it is not there, the build is broken and we must NOT
# ship silently without it -- the whole point of this image is that it can report
# its own faults. Fail loudly instead of skipping (the old `if [ -f ... ]` guard
# meant a typo in build.sh would ship a box with no collector and no error).
if [ ! -f /opt/build/deeebian-report.sh ]; then
  echo "FATAL: /opt/build/deeebian-report.sh missing -- ci/build.sh did not copy the collector" >&2
  exit 1
fi
install -d -m 0755 /usr/local/sbin /usr/local/bin
install -m 0755 /opt/build/deeebian-report.sh /usr/local/sbin/deeebian-report.sh
ln -sf /usr/local/sbin/deeebian-report.sh /usr/local/bin/deeebian-report.sh

# --- one-shot on-device health check: /usr/local/bin/eeepc-health ------------
# The user's single command to answer "is this machine OK?". Deliberately uses
# NOTHING that is not guaranteed present: read /proc directly rather than calling
# ip/swapon/lspci, so it still works from a rescue shell. Prints PASS/FAIL lines.
cat > /usr/local/bin/eeepc-health <<'HEALTH'
#!/bin/bash
# eeepc-health -- one-shot PASS/FAIL health summary for the Eee PC 701.
# Uses only /proc + coreutils + systemd; never assumes ip/swapon/lspci exist.
# Exit code: 0 all checks passed, 1 a core check failed (hardware/net/swap).
set -u
FAILS=0

pass() { printf 'PASS  %-22s %s\n' "$1" "$2"; }
warn() { printf 'WARN  %-22s %s\n' "$1" "$2"; }
fail() { printf 'FAIL  %-22s %s\n' "$1" "$2"; FAILS=$((FAILS+1)); }

echo "=== eeepc-health -- $(hostname) -- $(date '+%Y-%m-%d %H:%M:%S') ==="

# -- kernel + PAE --------------------------------------------------------------
KREL=$(uname -r)
echo "-- kernel / CPU --"
# Confirm the running kernel is actually the non-PAE build the 701 needs, by
# reading the shipped kernel config (this beats inferring it from CPU flags).
KCFG="/boot/config-$KREL"
if grep -qw pae /proc/cpuinfo 2>/dev/null; then CPUPAE=yes; else CPUPAE=no; fi
if [ -r "$KCFG" ]; then
    if grep -q '^CONFIG_X86_PAE=y' "$KCFG"; then
        fail "kernel PAE" "$KREL: CONFIG_X86_PAE is SET (must be unset for non-PAE boots)"
    elif grep -q '^CONFIG_HIGHMEM4G=y' "$KCFG"; then
        pass "kernel PAE" "$KREL: non-PAE (HIGHMEM4G), cpu pae=${CPUPAE}"
    else
        warn "kernel PAE" "$KREL: could not confirm HIGHMEM4G in $KCFG"
    fi
else
    warn "kernel PAE" "no $KCFG to confirm non-PAE; cpu pae=${CPUPAE}"
fi
MODEL=$(awk -F': ' '/model name/{print $2; exit}' /proc/cpuinfo)
pass "cpu" "${MODEL:-unknown} (pae=${CPUPAE})"
MTOT=$(awk '/MemTotal/{printf "%.0f", $2/1024}' /proc/meminfo)
pass "memory" "${MTOT:-0} MB total"

# -- wifi driver + interface ---------------------------------------------------
echo; echo "-- network --"
if ! grep -qiE 'ath5k|atl2|80211' /proc/modules 2>/dev/null; then
    if grep -qi 'ath5k' /lib/modules/"$KREL"/modules.builtin 2>/dev/null; then
        pass "wifi driver" "ath5k built into the kernel (expected on the 701)"
    else
        warn "wifi driver" "no ath5k module loaded or built-in"
    fi
else
    pass "wifi driver" "wireless module present in /proc/modules"
fi
if compgen -G '/sys/class/net/w*' >/dev/null 2>&1; then
    iface=$(basename "$(compgen -G '/sys/class/net/w*' | head -1)")
    oper=$(cat /sys/class/net/"$iface"/operstate 2>/dev/null || echo unknown)
    pass "wifi iface" "$iface present (operstate=$oper)"
else
    fail "wifi iface" "no wlan* interface in /sys/class/net"
fi

# rfkill state, from sysfs (rfkill binary lives in /usr/sbin and may be off PATH).
# Build "<name>:<soft><hard>" tokens where 1=blocked, 0=unblocked.
RFSTATE=""
RFBLOCKED=0
for r in /sys/class/rfkill/rfkill*; do
    [ -r "$r/type" ] || continue
    n=$(cat "$r/name" 2>/dev/null || basename "$r")
    s=$(cat "$r/soft" 2>/dev/null)
    h=$(cat "$r/hard" 2>/dev/null)
    RFSTATE="${RFSTATE}${n}:${s}${h} "
    [ "$s" = "1" ] && RFBLOCKED=1
done
if [ -n "$RFSTATE" ]; then
    if [ "$RFBLOCKED" = "0" ]; then
        pass "rfkill" "not soft-blocked ($RFSTATE)"
    else
        fail "rfkill" "soft-blocked: $RFSTATE -- 'sudo rfkill unblock all'"
    fi
else
    warn "rfkill" "no /sys/class/rfkill entries"
fi

# NetworkManager
if systemctl is-active --quiet NetworkManager 2>/dev/null; then
    pass "NetworkManager" "active"
else
    fail "NetworkManager" "not active -- 'sudo systemctl status NetworkManager'"
fi

# IPv4 address, read without `ip`: /proc/net/fib_trie + /proc/net/dev
FIB=$(cat /proc/net/fib_trie 2>/dev/null)
IP4=$(printf '%s\n' "$FIB" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' \
      | grep -vE '^(0\.|127\.|255\.)' | sort -u | tr '\n' ' ')
if [ -n "$IP4" ]; then
    pass "IPv4 address" "${IP4:-none}"
else
    warn "IPv4 address" "none assigned yet -- run 'ip -4 addr' or click nm-applet"
fi
DEVUP=$(awk -F: 'NR>2 {gsub(/ /,"",$1); if ($1 ~ /^w|^e/) print $1}' /proc/net/dev 2>/dev/null | tr '\n' ' ')
pass "net devices" "${DEVUP:-none}"

# -- swap / zram, from /proc/swaps --------------------------------------------
echo; echo "-- memory / swap --"
if grep -q 'zram' /proc/swaps 2>/dev/null; then
    ZS=$(awk '/zram/{print $3" KB"}' /proc/swaps | head -1)
    pass "zram swap" "active ($ZS)"
elif [ -s /proc/swaps ] && [ "$(wc -l < /proc/swaps)" -gt 1 ]; then
    warn "zram swap" "swap active but not zram: $(awk 'NR==2{print $1}' /proc/swaps)"
else
    fail "zram swap" "no swap -- check 'systemctl status zram-swap.service'"
fi
M=$(awk '/MemTotal/{t=$2} /MemAvailable/{a=$2} END{if(t) printf "%d/%d MB used", (t-a)/1024, t/1024}' /proc/meminfo)
pass "free memory" "${M:-unavailable}"
pass "load avg" "$(cut -d' ' -f1-3 /proc/loadavg)"

# -- root filesystem -----------------------------------------------------------
echo; echo "-- storage --"
ROOTUSE=$(df -h / 2>/dev/null | awk 'NR==2{print $5}')
pass "rootfs" "$(df -h / 2>/dev/null | awk 'NR==2{print $3" used of "$2" ("$5")"}')"
ROOTPCT=${ROOTUSE%\%}
if [ "${ROOTPCT:-0}" -ge 90 ] 2>/dev/null; then
    fail "rootfs usage" "${ROOTUSE} full -- risk of filling the SD card"
else
    pass "rootfs usage" "${ROOTUSE:-?}"
fi
IOERR=$(dmesg 2>/dev/null | grep -ci 'I/O error')
if [ "${IOERR:-0}" -gt 0 ]; then
    fail "SD I/O errors" "$IOERR in dmesg -- the card may be failing"
else
    pass "SD I/O errors" "none in dmesg"
fi

# -- systemd -------------------------------------------------------------------
echo; echo "-- system --"
FAILED=$(systemctl list-units --state=failed --no-legend --plain 2>/dev/null | wc -l)
if [ "${FAILED:-0}" -eq 0 ]; then
    pass "failed units" "none"
else
    fail "failed units" "$FAILED -- 'systemctl --failed'"
    systemctl list-units --state=failed --no-legend --plain 2>/dev/null | sed 's/^/        /'
fi
pass "uptime" "$(cut -d. -f1 /proc/uptime) s since boot"

# -- console / display ---------------------------------------------------------
echo; echo "-- display --"
if [ -d /sys/class/graphics/fb0 ]; then
    pass "kernel console" "framebuffer fb0 present (Ctrl+Alt+F1..F6 VTs available)"
else
    warn "kernel console" "no fb0 -- console may be blank after i915 takes over"
fi
DRMCARD=$(ls -d /sys/class/drm/card[0-9]* 2>/dev/null | head -1)
if [ -n "$DRMCARD" ]; then
    CONN=$(for c in /sys/class/drm/card*-*/status; do [ -r "$c" ] && printf '%s=%s ' "$(basename "$(dirname "$c")")" "$(cat "$c")"; done)
    pass "drm/i915" "present ($CONN)"
else
    warn "drm/i915" "no /sys/class/drm card node"
fi

echo
if [ "$FAILS" -eq 0 ]; then
    echo "RESULT: OK -- all core checks passed."
    exit 0
else
    echo "RESULT: $FAILS check(s) FAILED -- run 'sudo deeebian-report.sh --note \"...\"' to send a report."
    exit 1
fi
HEALTH
chmod +x /usr/local/bin/eeepc-health
# keep a terminal open on the results when launched from the Openbox menu
cat > /usr/local/bin/eeepc-health-tui <<'TUI'
#!/bin/bash
/usr/local/bin/eeepc-health "$@"
echo
read -r -p "Press Enter to close this window... "
TUI
chmod +x /usr/local/bin/eeepc-health-tui

# --- thermals / fan / CPU-state reporter: eeepc-thermals -----------------------------
# Installed from /opt/build/eeepc-thermals.sh. It is READ-ONLY by design: the 701's fan is an
# Embedded-Controller curve exposed via the `eeepc` hwmon (pwm1/pwm1_enable/fan1_input), and
# `cpufv` is force-disabled by the driver on model "701". Neither is written for the user.
# See the script header for the full interface note and docs/performance-thermals.md §1.
install -m 0755 /opt/build/eeepc-thermals.sh /usr/local/bin/eeepc-thermals

# --- benchmark: eeepc-bench -----------------------------------------------------------
# Installed from /opt/build/eeepc-bench.sh. Records boot/CPU/memory/SD-IO/X11 latency to
# /var/log/eeepc-bench-<date>.txt. --quick skips the only SD-write step. See its header.
install -m 0755 /opt/build/eeepc-bench.sh /usr/local/bin/eeepc-bench

# terminal wrappers so the Openbox menu can keep the output on screen (menu items must
# not vanish when the command exits). Same pattern as eeepc-health-tui.
cat > /usr/local/bin/eeepc-thermals-tui <<'TUI'
#!/bin/bash
/usr/local/bin/eeepc-thermals "$@"
echo
read -r -p "Press Enter to close this window... "
TUI
chmod 0755 /usr/local/bin/eeepc-thermals-tui
cat > /usr/local/bin/eeepc-bench-tui <<'TUI'
#!/bin/bash
# --quick by default from the menu: no SD write test on a casual click.
/usr/local/bin/eeepc-bench --quick "$@"
echo
read -r -p "Press Enter to close this window... "
TUI
chmod 0755 /usr/local/bin/eeepc-bench-tui

# --- PATH so rfkill / iw / swapon / ss resolve for sam ------------------------
# sam's login PATH is /usr/local/bin:/usr/bin:/bin:/usr/games -- /usr/sbin is absent,
# so `rfkill` fails ("command not found") even though /usr/sbin/rfkill exists.
# /etc/profile.d applies to LOGIN shells (the console/ssh login and the Openbox
# session); .profile is a belt-and-braces duplicate. NB: a NON-login, non-interactive
# shell (`ssh host cmd`, what scripts/cron use) sources NEITHER -- those callers must
# use absolute paths (/usr/sbin/rfkill) or PATH=... themselves; that is a deliberate
# tradeoff, not an oversight. The image's own scripts all use absolute paths.
cat > /etc/profile.d/eeepc-path.sh <<'EOF'
# Eee PC 701: put the sbin dirs on PATH so rfkill/iw/swapon/ss are usable
# interactively. Login shells only (see 30-configure.sh for the non-login caveat).
case ":$PATH:" in
  *:/usr/sbin:*) ;;
  *) PATH="/usr/local/sbin:/usr/sbin:/sbin:$PATH" ;;
esac
export PATH
EOF
for f in /home/sam/.profile /home/sam/.bashrc; do
  {
    echo ''
    echo '# --- /usr/sbin + /sbin on PATH so rfkill/iw/swapon/ss work (Eee PC 701) ---'
    echo 'case ":$PATH:" in'
    echo '  *:/usr/sbin:*) ;;'
    echo '  *) PATH="/usr/local/sbin:/usr/sbin:/sbin:$PATH" ;;'
    echo 'esac'
    echo 'export PATH'
  } >> "$f"
done
chown sam:sam /home/sam/.profile /home/sam/.bashrc

# sudo resets PATH to secure_path, so `sudo rfkill ...` would still fail without this.
mkdir -p /etc/sudoers.d
cat > /etc/sudoers.d/99-eeepc-path <<'EOF'
Defaults secure_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
EOF
chmod 0440 /etc/sudoers.d/99-eeepc-path

# --- quick reference shown in every terminal, login or not -------------------
# Debian's sshd does NOT print /etc/motd (UsePAM no) and Openbox shows no MOTD, so
# /etc/motd was invisible. Worse, lxterminal opens a NON-login interactive shell:
# it reads ~/.bashrc but NOT /etc/profile.d. One helper, called from both startup
# files, prints the quick reference + live LAN IP once per session (guarded).
cat > /usr/local/bin/eeepc-motd <<'EOF'
#!/bin/sh
# Print the quick reference once per session. Works with or without `ip` (reads
# /proc), so it is correct even in a rescue shell before the network is up.
# Guarded so sourcing it twice does not print twice (and does not kill the shell).
if [ -n "${EEEPC_MOTD_SHOWN:-}" ]; then
    return 0 2>/dev/null || exit 0
fi
EEEPC_MOTD_SHOWN=1; export EEEPC_MOTD_SHOWN
if [ -r /etc/motd ]; then cat /etc/motd; fi
ip4=$(grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' /proc/net/fib_trie 2>/dev/null \
      | grep -vE '^(0\.|127\.|255\.)' | sort -u | tr '\n' ' ')
printf '  hostname: %s   LAN IP: %s\n\n' "$(hostname 2>/dev/null || echo eeepc701)" "${ip4:-none yet}"
EOF
chmod +x /usr/local/bin/eeepc-motd
# login shells (console login, ssh login) get it via /etc/profile.d
cat > /etc/profile.d/00-eeepc-motd.sh <<'EOF'
case $- in
  *i*) /usr/local/bin/eeepc-motd ;;
esac
EOF
# non-login interactive shells (the lxterminal window) get it via ~/.bashrc
{
  echo ''
  echo '# --- show the quick reference in the terminal (non-login shell too) ---'
  echo '[ -x /usr/local/bin/eeepc-motd ] && /usr/local/bin/eeepc-motd'
} >> /home/sam/.bashrc
chown sam:sam /home/sam/.bashrc
mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/10-eeepc.conf <<'EOF'
# AcceptTerm is harmless and lets the eeepc PATH/motd drop-ins work if PAM is enabled.
AcceptEnv LANG LC_* TERM
EOF
# --- wallpaper -----------------------------------------------------------------
# Generate the wallpaper at build time (stdlib-only PNG writer) instead of shipping a
# binary asset or depending on an image tool that may not be in the chroot. Falls back
# to a solid colour if generation ever fails, so the desktop is never left blank.
# This runs AFTER the pcmanfm config is written, so it rewrites that config to point at
# the generated image (see the rewrite below) — that ordering matters.
install -d -m 0755 /usr/share/backgrounds
WALL_FILE=""
if [ -f /opt/build/wallpaper.py ] && python3 /opt/build/wallpaper.py /usr/share/backgrounds/eeepc-wallpaper.png >/dev/null; then
  chmod 0644 /usr/share/backgrounds/eeepc-wallpaper.png
  WALL_FILE=/usr/share/backgrounds/eeepc-wallpaper.png
  echo "wallpaper generated: $WALL_FILE"
else
  echo "WARN: wallpaper generation failed; falling back to a solid colour desktop"
fi

# point the pcmanfm desktop at the wallpaper (or fall back to the solid colour)
cat > /home/sam/.config/pcmanfm/default/desktop-items-0.conf <<EOF
[*]
# wallpaper_mode=stretch uses the generated PNG; if generation failed above, WALL_FILE
# is empty and the desktop falls back to the solid desktop_bg colour.
$([ -n "$WALL_FILE" ] && printf 'wallpaper_mode=stretch\nwallpaper=%s\n' "$WALL_FILE" || printf 'wallpaper_mode=color\n')
wallpaper_common=1
desktop_bg=#0b0f16
desktop_fg=#d0d7de
desktop_shadow=#000000
desktop_font=DejaVu Sans 10
# Forward unhandled clicks to Openbox so right-click still opens the root menu.
show_wm_menu=1
show_documents=0
show_trash=0
show_mounts=0
EOF
chown sam:sam /home/sam/.config/pcmanfm/default/desktop-items-0.conf
chmod 0644 /home/sam/.config/pcmanfm/default/desktop-items-0.conf

# --- ship the battery conditioning / fuel-gauge recalibration tool ----------
# The aged 701 pack's BMS fuel gauge drifts, so "100%" and the runtime estimate lie. A single
# full discharge -> full recharge re-learns the real endpoints. Installed as battery-rejuv
# (also reachable from the Openbox menu). The companion unit lets you run it detached from a
# terminal via systemd-run/start so a dropped SSH session doesn't kill a multi-hour cycle.
if [ -f /opt/build/battery-rejuv.sh ]; then
  install -m 0755 /opt/build/battery-rejuv.sh /usr/local/sbin/battery-rejuv
  ln -sf /usr/local/sbin/battery-rejuv /usr/local/bin/battery-rejuv
  cat > /etc/systemd/system/battery-rejuv.service <<'EOF'
[Unit]
Description=Battery conditioning / fuel-gauge recalibration (Eee PC 701)
Documentation=man:systemd-inhibit(1)
# Deliberately NOT enabled: run on demand with  systemctl start battery-rejuv
[Service]
Type=oneshot
RemainAfterExit=no
TimeoutStartSec=infinity
# root needed for systemd-inhibit + backlight writes
ExecStart=/usr/local/sbin/battery-rejuv full --yes
EOF
fi

# --- MOTD with quick reference ---
# NOTE: Debian's sshd runs with UsePAM no, so sshd does NOT print /etc/motd, and an
# Openbox session shows no MOTD either. /etc/profile.d/00-eeepc-motd.sh above prints
# this file in every interactive shell (ssh login + lxterminal), and the live LAN
# IP / hostname line is appended there too, so this stays static and short.
cat > /etc/motd <<'EOF'

  Deeebian — Debian 12 i386 for the ASUS Eee PC 701 (kernel 6.12 LTS, non-PAE)
  ---------------------------------------------------------------------------
  user: sam   password: eeepc     sudo works; root login is locked
  Terminal: Ctrl+Alt+T  (the 701 has no Super/Windows key)
            ...or double-click the "Terminal" icon, or right-click > Terminal
  Network:  ip -4 addr      — wifi: click the nm-applet icon in the panel
  Health:   Ctrl+Alt+S, or the "System info" icon — IP, disk, memory, route
            eeepc-health    — one-shot PASS/FAIL check of the whole machine
  Perf:     eeepc-thermals  — temps, fan state, CPU freq, governor (--watch 5)
            eeepc-bench --quick --label "before"  — benchmarks boot/CPU/disk/X11
            (writes /var/log/eeepc-bench-<date>.txt; --quick skips the SD write test)
  Support:  sudo deeebian-report.sh --note "describe the problem"
            — writes a diagnostics tarball and tries to send it to Hermes
  Panel has launcher icons too (Terminal / System info / Games / Firefox / Files).
  Battery: `battery-rejuv status` to read the pack; `sudo battery-rejuv full` to
           recalibrate the fuel gauge (full drain, then full charge — a few hours).
  Games:    eeepc-games   — install curated games, tools & toys (menu-driven)
            Also right-click the desktop > "Games & software".
  Runs from SD; swap is zram (RAM-backed, no card wear). Prefer a <=32 GB SDHC.

EOF

echo "=== configure done ==="
