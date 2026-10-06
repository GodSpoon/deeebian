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
KMAJOR=${KVER%.*}
KTARBALL="linux-${KVER}.tar.xz"
KSHA_ALGO="164dc9d1f6c93c61a15e1f071c48379b467f2b17c469cce7223471968208ed03  ${KTARBALL}"
ARCHIVE="https://cdn.kernel.org/pub/linux/kernel/v${KMAJOR}.x/${KTARBALL}"

ROOTFS="$BASE/rootfs"
BUILD="$BASE/build"
export EEEPC_BASE="$BASE"
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

log "2. debootstrap Debian 12 (bookworm) i386"
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
mount --bind "$BUILD/linux-$KVER" "$ROOTFS/build/linux-$KVER"

log "4. bootstrap scripts into chroot"
mkdir -p "$ROOTFS/opt/build"
cp "$REPO_ROOT"/scripts/10-packages.sh "$REPO_ROOT"/scripts/20-kernel.sh \
   "$REPO_ROOT"/scripts/30-configure.sh "$REPO_ROOT"/scripts/90-cleanup.sh \
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
