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
vm.swappiness=150
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

# --- openbox session for sam: panel, applets, keybinds ---
mkdir -p /home/sam/.config/openbox
cat > /home/sam/.config/openbox/autostart <<'EOF'
tint2 &
nm-applet &
volumeicon &
EOF
cat > /home/sam/.config/openbox/menu.xml <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<openbox_config xmlns="http://openbox.org/3.4/menu">
  <menu id="root-menu" label="Openbox 3">
    <item label="Terminal"><action name="Execute"><execute>lxterminal</execute></action></item>
    <item label="Web browser (Firefox)"><action name="Execute"><execute>firefox-esr</execute></action></item>
    <item label="Light browser (Netsurf)"><action name="Execute"><execute>netsurf</execute></action></item>
    <item label="Files"><action name="Execute"><execute>pcmanfm</execute></action></item>
    <item label="Text editor"><action name="Execute"><execute>mousepad</execute></action></item>
    <separator/>
    <item label="Network connections"><action name="Execute"><execute>nm-connection-editor</execute></action></item>
    <item label="Volume control"><action name="Execute"><execute>lxterminal -e alsamixer</execute></action></item>
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
chown -R sam:sam /home/sam/.config

# --- ship the on-device diagnostics collector --------------------------------
# The collector existed in the repo but was never installed into the image, so the
# "run deeebian-report.sh on the 701" monitoring path did not actually exist on the box.
if [ -f /opt/build/deeebian-report.sh ]; then
  install -m 0755 /opt/build/deeebian-report.sh /usr/local/sbin/deeebian-report.sh
  ln -sf /usr/local/sbin/deeebian-report.sh /usr/local/bin/deeebian-report.sh
fi

# --- MOTD with quick reference ---
cat > /etc/motd <<'EOF'

  Deeebian — Debian 12 (bookworm) i386 for the ASUS Eee PC 701, kernel 6.12 LTS (non-PAE)
  ----------------------------------------------------------------------------------------
  user: sam   password: eeepc   (change with: passwd)
  sudo works for sam. Root login is locked.

  Desktop: Openbox. Right-click desktop for menu. Panel: tint2.
  Wifi: click the nm-applet icon in the panel.
  This system runs from SD; swap is zram (RAM-backed, no SD wear).
  Boot needs a <=32 GB SDHC card — the 701 reader cannot use SDXC.

EOF

echo "=== configure done ==="
