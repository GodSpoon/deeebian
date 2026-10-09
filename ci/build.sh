#!/bin/bash
# ci/build.sh — end-to-end image build from source, runnable in GitHub Actions or locally (root).
#
# Produces $BASE/eeepc701-linux.img.xz (+ .sha256) from scratch:
#   debootstrap bookworm i386 rootfs  ->  vanilla 6.12 LTS non-PAE kernel (built in chroot)
#   ->  system configuration  ->  7 GiB MBR image (GRUB i386-pc)  ->  xz
#
# Tunables (env):
#   EEEPc_BASE / EEEPC_BASE   build scratch dir      (default /var/lib/vz/eeepc)
#   KERNEL_VERSION            vanilla kernel version (default 6.12.112)
#   EEEPC_IMAGE_SIZE          raw image size         (default 7G)
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BASE=${EEEPC_BASE:-/var/lib/vz/eeepc}
KVER=${KERNEL_VERSION:-6.12.112}
# kernel.org publishes every 6.* release under vN.x/ (e.g. 6.12.112 -> v6.x/)
KDIR="v${KVER%%.*}.x"
KTARBALL="linux-${KVER}.tar.xz"
KSHA_ALGO="164dc9d1f6c93c61a15e1f071c48379b467f2b17c469cce7223471968208ed03  ${KTARBALL}"
ARCHIVE="https://cdn.kernel.org/pub/linux/kernel/${KDIR}/${KTARBALL}"

ROOTFS="$BASE/rootfs"
BUILD="$BASE/build"
export EEEPC_BASE="$BASE"
# Image mount point must NOT be inside a path that shadows $ROOTFS (40-image.sh mounts the
# freshly created image there). Keep it a sibling subdir so rootfs stays visible.
export EEEPC_MNT="${EEEPC_MNT:-$BASE/mnt}"
mkdir -p "$EEEPC_MNT"
export DEBIAN_FRONTEND=noninteractive

log() { printf '\n=== %s ===\n' "$*"; }

export TERM=dumb
log "0. environment"
nproc; df -h "$BASE" 2>/dev/null || df -h /; uname -a

mkdir -p "$BASE" "$BUILD"

log "1. host tooling + loop devices"
if [ "$(id -u)" -ne 0 ]; then echo "FATAL: must run as root"; exit 1; fi
apt-get update -qq
apt-get install -y --no-install-recommends \
  debootstrap debian-archive-keyring \
  qemu-user-static binfmt-support \
  parted dosfstools e2fsprogs xz-utils rsync ca-certificates \
  gcc libelf-dev flex bison bc libssl-dev libncurses-dev \
  make kmod cpio python3 >/dev/null
if [ ! -e /dev/loop0 ]; then
  log "1b. /dev/loop* missing — loading loop module and creating device nodes"
  modprobe loop || true
  for i in $(seq 0 15); do
    [ -e "/dev/loop$i" ] || mknod "/dev/loop$i" b 7 "$i" 2>/dev/null || true
  done
  [ -e /dev/loop-control ] || mknod /dev/loop-control c 10 237 2>/dev/null || true
fi
losetup -f >/dev/null && echo "loop devices OK" || { echo "FATAL: no loop device available"; exit 1; }

log "2. refresh debian-archive-keyring (base images often ship one too old for bookworm)"
KRDIR=/usr/share/keyrings
KRDEB=debian-archive-keyring_2025.1_all.deb
KRURL="https://deb.debian.org/debian/pool/main/d/debian-archive-keyring/$KRDEB"
KRSUM=9ea7778e443144ca490668737a8ab22dd3e748bb99e805e22ec055abeb3c7fac
_tmp=$(mktemp -d)
curl -fL --retry 3 -o "$_tmp/$KRDEB" "$KRURL"
echo "$KRSUM  $_tmp/$KRDEB" | sha256sum -c -
dpkg-deb -x "$_tmp/$KRDEB" "$_tmp/x"
cp -f "$_tmp"/x/usr/share/keyrings/debian-archive-keyring.gpg "$KRDIR/" 2>/dev/null || true
cp -f "$_tmp"/x/usr/share/keyrings/debian-archive-removed-keys.gpg "$KRDIR/" 2>/dev/null || true
rm -rf "$_tmp"
ls -l "$KRDIR"/debian-archive*.gpg

log "3. debootstrap Debian 12 (bookworm) i386"
rm -rf "$ROOTFS"
debootstrap --arch=i386 --variant=buildd --foreign bookworm "$ROOTFS" \
  http://deb.debian.org/debian
cp /usr/bin/qemu-i386-static "$ROOTFS/usr/bin/" 2>/dev/null || true
chroot "$ROOTFS" /debootstrap/debootstrap --second-stage
rm -f "$ROOTFS/usr/bin/qemu-i386-static"

# mount the build surface the scripts need
mount --bind /dev      "$ROOTFS/dev"      2>/dev/null || mount --rbind /dev "$ROOTFS/dev"
mount --bind /dev/pts  "$ROOTFS/dev/pts"
mount -t proc  proc    "$ROOTFS/proc"
mount -t sysfs sysfs   "$ROOTFS/sys"
mkdir -p "$ROOTFS/build"
cp /etc/resolv.conf "$ROOTFS/etc/resolv.conf"
echo "" > "$ROOTFS/etc/machine-id"

log "3. kernel source"
cd "$BUILD"
[ -f "$KTARBALL" ] || curl -fL --retry 3 -o "$KTARBALL" "$ARCHIVE"
echo "$KSHA_ALGO" | sha256sum -c -
rm -rf "$BUILD/linux-$KVER"
tar xf "$KTARBALL"
mkdir -p "$ROOTFS/build/linux-$KVER"
mount --bind "$BUILD/linux-$KVER" "$ROOTFS/build/linux-$KVER"

log "4. bootstrap scripts into chroot"
mkdir -p "$ROOTFS/opt/build"
cp "$REPO_ROOT"/scripts/10-packages.sh "$REPO_ROOT"/scripts/20-kernel.sh \
   "$REPO_ROOT"/scripts/30-configure.sh "$REPO_ROOT"/scripts/90-cleanup.sh \
   "$REPO_ROOT"/scripts/deeebian-report.sh "$REPO_ROOT"/scripts/wallpaper.py \
   "$REPO_ROOT"/scripts/battery-rejuv.sh \
   "$ROOTFS/opt/build/"
chmod +x "$ROOTFS"/opt/build/*.sh

log "5. packages"
chroot "$ROOTFS" /bin/bash /opt/build/10-packages.sh

log "6. kernel build (6.12 LTS i386, non-PAE)"
chroot "$ROOTFS" /bin/bash /opt/build/20-kernel.sh

log "7. system configuration"
chroot "$ROOTFS" /bin/bash /opt/build/30-configure.sh

log "8. cleanup / sanitize for cloning"
chroot "$ROOTFS" /bin/bash /opt/build/90-cleanup.sh

log "9. unmount chroot"
umount -R "$ROOTFS/build" 2>/dev/null || true
umount -R "$ROOTFS/proc"  2>/dev/null || true
umount -R "$ROOTFS/sys"   2>/dev/null || true
umount -R "$ROOTFS/dev"   2>/dev/null || true

log "10. assemble 7 GiB MBR image + GRUB + xz"
bash "$REPO_ROOT/scripts/40-image.sh"

log "11. artifacts"
ls -lh "$BASE/eeepc701-linux.img.xz" "$BASE/eeepc701-linux.img.xz.sha256"
sha256sum -c "$BASE/eeepc701-linux.img.xz.sha256" || true
