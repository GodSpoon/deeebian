#!/bin/bash
# 10-packages.sh — runs INSIDE the i386 chroot
# Target package set for the Eee PC 701 image (Debian 12 bookworm, i386)
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

cat > /etc/apt/sources.list <<'EOF'
deb http://deb.debian.org/debian bookworm main contrib non-free non-free-firmware
deb http://deb.debian.org/debian bookworm-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware
deb http://deb.debian.org/debian bookworm-backports main contrib non-free non-free-firmware
EOF

cat > /etc/apt/apt.conf.d/99eeepc <<'EOF'
APT::Install-Recommends "true";
APT::Install-Suggests "false";
Acquire::Retries "5";
EOF

# Keep the image small: skip /usr/share/doc (keep copyright files)
cat > /etc/dpkg/dpkg.cfg.d/01_nodoc <<'EOF'
path-exclude=/usr/share/doc/*
path-include=/usr/share/doc/*/copyright
path-exclude=/usr/share/lintian/*
path-exclude=/usr/share/linda/*
EOF

# Preseed keyboard + timezone so nothing is interactive
debconf-set-selections <<'EOF'
keyboard-configuration keyboard-configuration/layout select us
keyboard-configuration keyboard-configuration/variant select English (US)
tzdata tzdata/Areas select Etc
tzdata tzdata/Zones/Etc select UTC
locales locales/default-environment-locale select en_US.UTF-8
locales locales/locales_to_be_generated multiselect en_US.UTF-8 UTF-8
EOF

apt-get update
apt-get install -y --no-install-recommends locales tzdata keyboard-configuration console-setup

# Networking: iproute2 provides `ip`/`ss` (landing at /bin/ip + /sbin/ip via
# usrmerge) and net-tools provides `ifconfig`/`route`/`netstat` (/sbin). Neither
# was in the image, which is why there was no way to see the LAN IP on-device.
apt-get install -y \
  systemd-sysv dbus sudo kmod cpio initramfs-tools grub-pc \
  network-manager network-manager-gnome wpasupplicant iw wireless-tools rfkill \
  iproute2 net-tools \
  openssh-server avahi-daemon \
  curl wget rsync tmux htop ncdu less file nano pciutils usbutils \
  alsa-utils volumeicon-alsa \
  earlyoom tlp \
  cpufrequtils hdparm \
  cloud-guest-utils e2fsprogs dosfstools ntfs-3g exfatprogs \
  xserver-xorg-core xserver-xorg xserver-xorg-video-intel \
  xserver-xorg-video-fbdev xserver-xorg-video-vesa xserver-xorg-input-libinput \
  x11-xserver-utils x11-utils xdg-user-dirs xdg-utils \
  openbox tint2 pcmanfm lxterminal mousepad lightdm lightdm-gtk-greeter \
  lxqt-policykit \
  firefox-esr netsurf-gtk feh \
  fonts-dejavu-core fonts-liberation \
  acpi acpid intel-microcode \
  systemd-timesyncd \
  firmware-iwlwifi firmware-realtek

# Kernel build toolchain — needed in the chroot to compile 20-kernel.sh, removed later by 90-cleanup.sh
apt-get install -y --no-install-recommends \
  build-essential gcc make binutils libc6-dev \
  bison flex libelf-dev libssl-dev libncurses-dev bc dwarves kmod cpio

# --- games, tools, toys: the fun that makes a netbook worth picking up ---------
# Shipped IN the image (not merely offered by eeepc-games) so a fresh card boots
# to a machine with something to do. ~82 packages / ~170 MiB installed, verified
# against the real bookworm i386 index. All are text-mode or light 2D, which is
# what this 900 MHz / 800x480 / no-3D box actually runs well.
#
# The larger, more demanding titles (scummvm + the freeware adventures, openttd,
# supertux, gnugo, cataclysm-dda) are deliberately NOT shipped: eeepc-games offers
# them and the catalogue documents them. Every package here is in Debian main, so
# nothing proprietary is redistributed by this repo.
#
# NOTE: do not put `#` "comments" inside a backslash-continued command -- the shell
# runs them as subshells. Each group is its own install call for that reason.

# roguelikes + dungeon crawls (the strongest category on this hardware)
apt-get install -y nethack-console nethack-common crawl moria slashem angband \
  boohu omega-rpg gearhead meritous hyperrogue
# interactive fiction interpreters (huge free corpus at the IF Archive)
apt-get install -y frotz glulxe jzip scottfree open-adventure dmagnetic
# card, board and abstract strategy
apt-get install -y ace-of-penguins gnubg gnuchess xboard fairymax pente grhino \
  xshogi gtkboard tty-solitaire xmahjongg
# puzzles and logic
apt-get install -y sgt-puzzles 2048 tetzle tworld xdemineur black-box colorcode \
  pipewalker hexalate berusky sudoku nudoku xye zaz wizznic xbubble enigma
# terminal arcade
apt-get install -y vitetris petris tint bastet ninvaders pacman4console nsnake \
  greed moon-buggy asciijump
# classic FPS via GPL source ports; Freedoom is the freely-redistributable data set
apt-get install -y chocolate-doom prboom-plus freedoom dosbox
# toys, demos and time-wasters
apt-get install -y cowsay figlet toilet fortune-mod fortunes-debian-hints cmatrix \
  sl lolcat nyancat bb xscreensaver xscreensaver-data asciinema sox schism \
  milkytracker pt2-clone espeak libaa-bin rig bsdgames tty-clock
# artwork / themes / icons, so the desktop is not a grey void
apt-get install -y desktop-base

echo "=== packages done ==="
apt-get clean
