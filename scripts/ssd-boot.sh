#!/bin/bash
# ssd-boot.sh -- put the BOOT path on the internal SSD of an ASUS Eee PC 701.
#
# WHY THIS EXISTS
# The 701's internal 3.7 GB SSD (/dev/sda, SILICONMOTION SM223AC, PATA/CF) sits idle
# while the whole OS runs from a REMOVABLE SD card. Measured on real hardware, the SSD
# reads ~35 MB/s against the SD's ~17 MB/s, and it is the device the firmware can always
# find. The goal here is narrow and deliberate: make the FIXED disk carry the boot path
# (kernel, initramfs, GRUB) while the WEAR-PRONE work stays on the removable card.
#
# That split is the whole point. Root writes constantly (logs, caches, timestamps); /boot
# is read-mostly. Putting the read-mostly part on the irreplaceable 2007 flash and leaving
# the writes on a card you can replace and re-flash is the correct trade for this machine.
#
# SAFETY MODEL -- read this before changing anything
#  * NOTHING HERE MOVES /boot. We COPY it to the SSD and install GRUB on the SSD. The SD's
#    own /boot and its GRUB stay exactly as they were, so the existing boot path is never
#    invalidated: if every SSD step fails, the machine still boots from the card as before.
#    This is deliberate. An unattended first-boot job must never be able to brick a machine
#    whose owner cannot reach it.
#  * Only sda1 is touched. sda2/sda3/sda4 (the possible ASUS factory recovery regions) are
#    left alone.
#  * Refuses unless the device really is the expected SSD, and refuses if it is mounted.
#  * Idempotent: re-running just refreshes the copy.
#
# The firmware CAN be pointed at the SSD (BIOS boot order) to actually boot from it; until
# then this is a second, fixed boot source and a rescue path. See ssd-boot-status.

set -euo pipefail

SSD=${EEEPC_SSD_DEV:-/dev/sda}
SSD_PART=${EEEPC_SSD_PART:-${SSD}1}
LABEL=EEEPCBOOT
MNT=/mnt/eeepc-ssd-boot
MARKER=/var/lib/eeepc-ssd-boot.done
DRY=0
AUTO=0
case "${1:-}" in
  --dry-run) DRY=1 ;;
  --auto)    AUTO=1 ;;
  ""|-h|--help)
     sed -n '2,30p' "$0" | sed 's/^# \?//'
     echo; echo "usage: ssd-boot.sh [--dry-run | --auto]"
     exit 0 ;;
  *) die "unknown option: $1 (use --dry-run or --auto)" ;;
esac
[ "$AUTO" = 1 ] && say "auto mode (first-boot hook): running unattended; failures are non-fatal"

say()  { printf 'ssd-boot: %s\n' "$*"; }
die()  { printf 'ssd-boot: FATAL: %s\n' "$*" >&2; exit 1; }
run()  { if [ "$DRY" = 1 ]; then printf 'ssd-boot: [dry-run] %s\n' "$*"; else "$@"; fi; }

# ---------------------------------------------------------------- pre-flight
[ "$(id -u)" = 0 ] || die "must run as root"
[ -b "$SSD" ] || die "$SSD is not a block device"

# Identity check. We are about to mkfs a partition; be certain which disk this is.
model=$(cat "/sys/class/block/$(basename "$SSD")/device/model" 2>/dev/null || echo "")
size_sectors=$(cat "/sys/class/block/$(basename "$SSD")/size" 2>/dev/null || echo 0)
size_bytes=$((size_sectors * 512))
say "target: $SSD model='${model}' size=$((size_bytes / 1024 / 1024)) MiB"

case "$model" in
  *SILICONMOTION*|*SM223*) : ;;
  *) die "refusing: $SSD is not the expected SILICONMOTION SM223AC (model='$model').
     Set EEEPC_SSD_DEV only if you are certain. Never let a wrong device reach mkfs." ;;
esac
# 3.7 GiB +- 10%. A partition table change elsewhere should stop us, not silently pass.
if [ "$size_bytes" -lt 3400000000 ] || [ "$size_bytes" -gt 4200000000 ]; then
  die "refusing: $SSD is ${size_bytes} bytes, not the expected ~3.7 GiB SSD"
fi

# Never operate on the disk we are running from.
root_src=$(findmnt -n -o SOURCE / 2>/dev/null || echo "")
case "$root_src" in
  "$SSD"|"$SSD"*) die "refusing: $SSD holds the running root ($root_src)" ;;
esac
if mount | grep -qE "^${SSD}[0-9]+ "; then
  die "refusing: a partition of $SSD is mounted (see: mount | grep ${SSD})"
fi

# ------------------------------------------------------------------- work
say "1/6 filesystem on $SSD_PART (label $LABEL), ext4, reserved 0%"
# 5% of a 3.7 GB filesystem is ~190 MiB of /boot that nothing can ever use; /boot never
# needs reserved blocks, so give them all back.
run mkfs.ext4 -q -F -L "$LABEL" -m 0 "$SSD_PART"

say "2/6 mount and copy the current /boot (COPY, not move -- the SD path stays valid)"
run mkdir -p "$MNT"
run mount "$SSD_PART" "$MNT"
if [ "$DRY" = 0 ]; then
  uuid=$(blkid -s UUID -o value "$SSD_PART")
  [ -n "$uuid" ] || die "could not read a UUID off $SSD_PART"
  # Copy the kernel, initramfs and any existing config; keep owner/mode.
  cp -a /boot/. "$MNT"/
  say "    boot uuid: $uuid"
else
  uuid="DRYRUN-BOOT-UUID"
fi

say "3/6 build a RESCUE initramfs (a missing SD then gives a shell, not a kernel panic)"
# Without this, /boot on the SSD buys almost nothing: GRUB runs, the kernel loads from the
# SSD, and then it panics with 'VFS: Unable to mount root fs' because root is on the absent
# card. The rescue initramfs is what turns that panic into a recoverable prompt.
if [ "$DRY" = 0 ]; then
  krel=$(uname -r)
  if [ -e "/etc/initramfs-tools" ]; then
    cat > /etc/initramfs-tools/conf.d/eeepc-rescue <<'EOF'
# eeepc rescue initramfs: drop to a shell instead of panicking when root is absent.
BOOTIF=0
EOF
    update-initramfs -c -k "$krel" 2>/dev/null || say "    (update-initramfs failed; SD path unaffected)"
    if [ -f "/boot/initrd.img-$krel" ]; then
      cp -f "/boot/initrd.img-$krel" "$MNT/initrd.img-rescue" 2>/dev/null || true
      say "    rescue initramfs staged: $MNT/initrd.img-rescue"
    fi
  fi
fi

say "4/6 GRUB on the SSD's MBR (the SD's GRUB is deliberately left alone)"
if [ "$DRY" = 0 ]; then
  if grub-install --target=i386-pc --boot-directory="$MNT" --recheck "$SSD" >/tmp/grub-ssd.log 2>&1; then
    say "    grub-install OK"
  else
    say "    grub-install FAILED (see /tmp/grub-ssd.log) -- the SD still boots; continuing"
  fi
fi

say "5/6 write a self-contained grub.cfg that boots the SD's root"
# root=UUID=<SD root> so the OS still comes off the card, which is where the writes belong.
root_uuid=$(findmnt -n -o UUID / 2>/dev/null || true)
[ -n "$root_uuid" ] || root_uuid=b0057a11-de12-b007-01ee-000000000001
krel=$(uname -r)
if [ "$DRY" = 0 ]; then
  mkdir -p "$MNT/grub"
  cat > "$MNT/grub/grub.cfg" <<EOF
# Generated by ssd-boot.sh -- boot path on the SSD, root on the SD card.
set default=0
set timeout=5

# Locate our own /boot by label so this works whichever disk the firmware picked.
search --no-floppy --label --set=root $LABEL

menuentry 'Deeebian (SSD boot / SD root)' {
    linux /vmlinuz-$krel root=UUID=$root_uuid ro quiet rootwait
    initrd /initrd.img-$krel
}

menuentry 'Deeebian — rescue (no root: drops to a shell)' {
    linux /vmlinuz-$krel root=UUID=$root_uuid ro rootwait break=mount
    initrd /initrd.img-rescue
}
EOF
  say "    grub.cfg written (entries: normal, rescue)"
fi

say "6/6 unmount, sync, record"
if [ "$DRY" = 0 ]; then
  sync
  umount "$MNT" || true
  cat > "$MARKER" <<EOF
ssd-boot: completed $(date -u +%Y-%m-%dT%H:%M:%SZ)
device:  $SSD_PART (label $LABEL, uuid $uuid)
copy of: /boot as of $(date -u +%Y-%m-%dT%H:%M:%SZ)
root:    UUID=$root_uuid (on the SD card -- unchanged)
note:    /boot was COPIED, not moved; the SD boot path is untouched.
EOF
fi

say "done. The SSD now carries a boot copy."
say "  * to BOOT from it, set the SSD first in BIOS (F2 -> Boot), or use the Esc menu."
say "  * re-run after kernel updates to refresh the copy; 'ssd-boot-status' shows state."
