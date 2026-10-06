#!/bin/bash
# 40-image.sh — runs on the Proxmox HOST (root).
# Assembles the 7 GiB MBR disk image: partition, mkfs (fixed UUID), rsync rootfs,
# initramfs, static grub.cfg, grub-install to MBR, compress.
set -euo pipefail

IMG_UUID="b0057a11-de12-b007-01ee-000000000001"
BASE=${EEEPC_BASE:-/var/lib/vz/eeepc}
IMG_SIZE=${EEEPC_IMAGE_SIZE:-7G}
MNT=${EEEPC_MNT:-/mnt/eeepc}
ROOTFS=$BASE/rootfs
IMG=$BASE/eeepc701-linux.img
KREL=$(ls -1 $ROOTFS/boot/vmlinuz-* | head -1 | sed 's/.*vmlinuz-//')

echo "kernel release: $KREL"

# --- create image + partition ---
rm -f "$IMG"
truncate -s "$IMG_SIZE" "$IMG"
parted -s "$IMG" mklabel msdos unit MiB mkpart primary ext4 1 100% set 1 boot on
parted -s "$IMG" print

LOOP=$(losetup --show -fP "$IMG")
trap 'umount -R "$MNT" 2>/dev/null; losetup -d "$LOOP"' EXIT
mkfs.ext4 -F -q -U "$IMG_UUID" -L EEEPC701 "${LOOP}p1"
mkdir -p "$MNT"
mount "${LOOP}p1" "$MNT"

# --- copy rootfs (exclude the bind-mounted kernel build tree) ---
rsync -aHAXx --exclude=/build "$ROOTFS/" "$MNT"/

# --- final in-image steps: initramfs + grub ---
mount --bind /dev "$MNT/dev"
mount --bind /dev/pts "$MNT/dev/pts"
mount -t proc proc "$MNT/proc"
mount -t sysfs sysfs "$MNT/sys"
cp /etc/resolv.conf "$MNT/etc/" || true

chroot "$MNT" update-initramfs -c -k "$KREL"

# Static GRUB config — full control, no os-prober, fast timeout
mkdir -p "$MNT/boot/grub"
cat > "$MNT/boot/grub/grub.cfg" <<EOF
set timeout=3
set default=0

insmod part_msdos
insmod ext2
search --no-floppy --fs-uuid --set=root $IMG_UUID

menuentry "EeePC Linux (kernel $KREL)" {
    linux /boot/vmlinuz-$KREL root=UUID=$IMG_UUID ro quiet rootwait
    initrd /boot/initrd.img-$KREL
}

menuentry "EeePC Linux — recovery shell" {
    linux /boot/vmlinuz-$KREL root=UUID=$IMG_UUID ro rootwait systemd.unit=rescue.target
    initrd /boot/initrd.img-$KREL
}

menuentry "EeePC Linux — serial console (ttyS0)" {
    linux /boot/vmlinuz-$KREL root=UUID=$IMG_UUID ro rootwait console=ttyS0,115200n8
    initrd /boot/initrd.img-$KREL
}
EOF

chroot "$MNT" grub-install --target=i386-pc --no-floppy --boot-directory=/boot "$LOOP"

umount -R "$MNT"
losetup -d "$LOOP"
trap - EXIT

echo "=== image assembled ==="
ls -lh "$IMG"

xz -T0 -9e -k "$IMG"   # keep raw img for VM test, publish the .xz
sha256sum "$IMG.xz" > "$IMG.xz.sha256"
ls -lh "$IMG.xz"
echo "=== done ==="
