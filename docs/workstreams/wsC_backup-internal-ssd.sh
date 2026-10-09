#!/bin/bash
# backup-internal-ssd.sh — hash-verified image backup of the Eee PC 701's internal
# 4 GiB SSD (/dev/sda, the untouched 2007 Xandros factory disk).
#
# WHY THIS EXISTS FIRST
#   The 701 currently boots entirely from the removable SD card. The internal SSD
#   is untouched. Before *anything* is written to that 2007-era flash device, its
#   exact byte content must exist elsewhere and be provably identical. This script
#   produces that provable copy. Nothing in docs/storage-resilience.md that writes
#   /dev/sda is allowed to run until this has succeeded and its result has been
#   restored and booted in a VM.
#
# SAFETY, BY CONSTRUCTION (read before editing)
#   * The source is opened READ-ONLY (sha256sum, dd if=...). There is no `of=/dev/*`
#     anywhere in this file: the only thing it ever writes is a regular file.
#   * Source == destination is refused three ways:
#       - the output must not be a block device at all;
#       - the destination directory's backing filesystem must not be the source
#         disk or any of its partitions;
#       - the destination must not be the source device node itself.
#   * A source with any mounted filesystem or active swap is refused: a live source
#     gives a torn, unrepeatable image.
#   * --dry-run runs every check and prints the exact plan; it writes nothing and
#     does not read the whole device.
#   * The finished file is verified by hashing the source and the file and
#     requiring the two hashes to be equal. The .sha256 sidecar it writes is what
#     flash-card.sh consumes when you restore.
#
# Usage:
#   sudo ./backup-internal-ssd.sh -o /path/to/backup/dir
#   sudo ./backup-internal-ssd.sh -i /dev/sda -o /mnt/big --dry-run
#   sudo ./backup-internal-ssd.sh -V /mnt/big/sda-backup-20261009-120000.img
#
set -euo pipefail

SRC=/dev/sda
OUTDIR=
VERIFY_ONLY=
DRY_RUN=0
FORCE=0
BS=4M

die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
note() { printf '%s\n' "$*"; }

usage() {
  cat <<'USAGE'
backup-internal-ssd.sh — make a hash-verified image of the 701's internal SSD.

  sudo ./backup-internal-ssd.sh -o DIR            back up /dev/sda into DIR
  sudo ./backup-internal-ssd.sh -i DEV -o DIR     back up DEV instead
  sudo ./backup-internal-ssd.sh -o DIR --dry-run  run every check, write nothing
  sudo ./backup-internal-ssd.sh -V IMG            verify existing IMG vs the source
  sudo ./backup-internal-ssd.sh -o DIR --force    overwrite an existing image

The source is only ever READ. The output is always a regular FILE; this script has
no code path that writes to a block device. It refuses when the destination would
live on the source disk, and it refuses a source with mounted filesystems.
USAGE
}

# ---- helpers ----------------------------------------------------------------
realpath_of() { readlink -f -- "$1" 2>/dev/null || printf '%s\n' "$1"; }
devno()       { stat -c '%t:%T' -- "$1" 2>/dev/null || true; }

parent_disk() { # partition -> its whole disk; a whole disk -> itself
  local dev name d
  dev=$(realpath_of "$1")
  name=$(basename "$dev")
  if [ -e "/sys/class/block/$name/partition" ]; then
    d=$(basename "$(readlink -f "/sys/class/block/$name/..")")
    printf '/dev/%s\n' "$d"
  else
    printf '%s\n' "$dev"
  fi
}

fs_bdev() { # the block device backing a path (empty for tmpfs/overlay/etc.)
  findmnt -rn -o SOURCE --target "$1" 2>/dev/null | head -1 || true
}

# absolute path to this script, for the sudo re-exec
SELF=$0
case "$SELF" in
  /*)   ;;
  */*)  SELF="$PWD/$SELF" ;;
  *)    SELF=$(command -v "$SELF" 2>/dev/null || printf '%s' "$SELF") ;;
esac

# ---- arguments --------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    -i|--source)     SRC=${2:?source device required}; shift 2 ;;
    -o|--out)        OUTDIR=${2:?output directory required}; shift 2 ;;
    -V|--verify-only) VERIFY_ONLY=${2:?image required}; shift 2 ;;
    -n|--dry-run)    DRY_RUN=1; shift ;;
    -f|--force)      FORCE=1; shift ;;
    -h|--help)       usage; exit 0 ;;
    *)               die "unknown argument: $1 (try --help)" ;;
  esac
done

if [ -z "$VERIFY_ONLY" ] && [ -z "$OUTDIR" ]; then
  die "no output directory. Use -o DIR (or -V IMG to verify an existing image).
  A destination is required on purpose: this script never guesses where your only copy goes."
fi

# ---- privilege --------------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
  command -v sudo >/dev/null 2>&1 || die "must run as root (reading a block device needs it)"
  exec sudo -- bash "$SELF" "$@"
fi

# ---- source guards ----------------------------------------------------------
[ -e "$SRC" ] || die "source $SRC does not exist"
[ -b "$SRC" ] || die "source $SRC is not a block device"
SRC=$(realpath_of "$SRC")
SRC_SIZE=$(blockdev --getsize64 "$SRC")
SRC_DISK=$(parent_disk "$SRC")
SRC_DEVID=$(devno "$SRC")
[ -n "$SRC_SIZE" ] && [ "$SRC_SIZE" -gt 0 ] || die "cannot read the size of $SRC"

if [ -e "/sys/class/block/$(basename "$SRC")/partition" ]; then
  note "NOTE: $SRC is a single partition, not the whole disk. A full-disk backup is"
  note "      taken from $(parent_disk "$SRC"). Continuing with the partition you named."
fi

live=$(awk -v d="$SRC_DISK" '$1 ~ "^"d"([0-9]+|p[0-9]+)?$" {print $2}' /proc/mounts 2>/dev/null || true)
[ -z "$live" ] || die "$SRC_DISK is in use (mounted at: $live).
  Backing up a live device gives a torn, unrepeatable image. Unmount it first."

live_swap=$(awk -v d="$SRC_DISK" '$1 ~ "^"d"([0-9]+|p[0-9]+)?$" {print $1}' /proc/swaps 2>/dev/null || true)
[ -z "$live_swap" ] || die "$SRC_DISK has active swap ($live_swap). Swap it off first."

# ---- verify-only mode -------------------------------------------------------
if [ -n "$VERIFY_ONLY" ]; then
  [ -f "$VERIFY_ONLY" ] || die "verify target $VERIFY_ONLY is not a regular file"
  VIMG=$(realpath_of "$VERIFY_ONLY")
  note "Hashing source $SRC (read-only)…"
  A=$(sha256sum "$SRC" | awk '{print $1}')
  note "Hashing image  $VIMG…"
  B=$(sha256sum "$VIMG" | awk '{print $1}')
  note "  source sha256 : $A"
  note "  image  sha256 : $B"
  [ "$A" = "$B" ] || die "MISMATCH — $VIMG is NOT a faithful copy of $SRC."
  note "MATCH — $VIMG is byte-identical to $SRC."
  exit 0
fi

# ---- destination guards -----------------------------------------------------
command -v findmnt >/dev/null 2>&1 || die "findmnt (util-linux) is missing; cannot prove the destination is not the source disk. Refusing."
[ -d "$OUTDIR" ] || die "output directory $OUTDIR does not exist (create it first; this script will not guess a location)"
OUTDIR=$(realpath_of "$OUTDIR")

DST_FS=$(fs_bdev "$OUTDIR")
if [ -n "$DST_FS" ] && [ -b "$DST_FS" ]; then
  DST_FS_DISK=$(parent_disk "$DST_FS")
  DST_FS_DEVID=$(devno "$DST_FS")
  [ "$(realpath_of "$DST_FS_DISK")" != "$(realpath_of "$SRC_DISK")" ] || die \
    "SOURCE == DESTINATION: $OUTDIR lives on $DST_FS (disk $DST_FS_DISK), which IS the
  source disk $SRC_DISK. Writing there would destroy the very device being backed up."
  [ "$DST_FS_DEVID" != "$SRC_DEVID" ] || die \
    "SOURCE == DESTINATION: $OUTDIR is on $DST_FS, the source device itself."
fi

STAMP=$(date +%Y%m%d-%H%M%S)
DISKNAME=$(basename "$SRC")
IMG="$OUTDIR/${DISKNAME}-backup-${STAMP}.img"

[ -b "$IMG" ] && die "refusing to write: $IMG is a block device. This script only writes regular files."
if [ -e "$IMG" ]; then
  [ "$FORCE" -eq 1 ] || die "$IMG already exists (use --force to overwrite)"
fi

avail_kb=$(df -Pk --output=avail "$OUTDIR" 2>/dev/null | tail -1 | tr -d ' ' || true)
[ -n "$avail_kb" ] || avail_kb=$(df -Pk "$OUTDIR" | awk 'NR==2 {print $4}')
need_kb=$(( SRC_SIZE / 1024 + 131072 ))          # image + 128 MiB margin for sidecars
[ "$avail_kb" -ge "$need_kb" ] || die \
  "not enough free space in $OUTDIR: need ~$(( need_kb / 1024 )) MiB, have $(( avail_kb / 1024 )) MiB"

# ---- plan -------------------------------------------------------------------
note "=============================================================="
note " deeebian — internal SSD backup (READ-ONLY on the source)"
note "=============================================================="
note " source device : $SRC"
lsblk -dno NAME,SIZE,MODEL,SERIAL,TRAN "$SRC" 2>/dev/null | sed 's/^/                 /' || true
note " source size   : $SRC_SIZE bytes ($(( SRC_SIZE / 1024 / 1024 )) MiB)"
note " source disk   : $SRC_DISK"
note " image file    : $IMG"
note " sidecars      : $(basename "$IMG").sha256, $(basename "$IMG").meta.txt"
note " free space    : $(( avail_kb / 1024 )) MiB"
note ""
note " partition table now present on the source:"
lsblk -no NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT "$SRC" 2>/dev/null | sed 's/^/   /' || true
note ""

if [ "$DRY_RUN" -eq 1 ]; then
  note "--dry-run: nothing was read from or written to any device."
  note "Would run:"
  note "  1. sha256sum $SRC                       # pass 1 of 2 — source hash"
  note "  2. dd if=$SRC of=$IMG bs=$BS conv=fsync status=progress"
  note "  3. sync; sha256sum $IMG                # pass 2 of 2 — verify"
  note "  4. compare the two hashes; refuse and keep the file on mismatch"
  exit 0
fi

# ---- backup -----------------------------------------------------------------
note "Pass 1/2 — hashing the source (read-only). On a 900 MHz CPU this takes minutes…"
SRC_SHA=$(sha256sum "$SRC" | awk '{print $1}')
note "  source sha256 = $SRC_SHA"

note "Pass 2/2 — copying $SRC -> $IMG"
t0=$(date +%s)
dd if="$SRC" of="$IMG" bs="$BS" conv=fsync status=progress
sync
t1=$(date +%s)

IMG_SIZE=$(stat -c %s "$IMG")
[ "$IMG_SIZE" -eq "$SRC_SIZE" ] || die "image size $IMG_SIZE != device size $SRC_SIZE — the copy is short.
  Keep $IMG for inspection and re-run. Do NOT proceed to any step that writes $SRC."

DST_SHA=$(sha256sum "$IMG" | awk '{print $1}')
note "  image  sha256 = $DST_SHA"

if [ "$SRC_SHA" != "$DST_SHA" ]; then
  die "HASH MISMATCH — the image is NOT a trustworthy copy of $SRC.
  This means either the source flash read inconsistently (a failing 2007-era SSD looks
  exactly like this) or the destination media is bad. DO NOT run any step that writes
  $SRC. Re-run this backup; if the mismatch repeats, image the device with ddrescue
  instead and keep both the image and its mapfile.
  The failed image was left at: $IMG"
fi

# ---- sidecars ---------------------------------------------------------------
printf '%s  %s\n' "$DST_SHA" "$(basename "$IMG")" > "$IMG.sha256"

{
  echo "deeebian internal SSD backup"
  echo "date          : $(date -Is)"
  echo "source        : $SRC"
  echo "source sha256 : $SRC_SHA"
  echo "image         : $(basename "$IMG")"
  echo "image sha256  : $DST_SHA"
  echo "size bytes    : $IMG_SIZE"
  echo "copy seconds  : $(( t1 - t0 ))"
  echo "kernel        : $(uname -sr)"
  echo
  echo "=== lsblk ==="
  lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,UUID,MOUNTPOINT "$SRC" 2>&1 || true
  echo
  echo "=== blkid ==="
  blkid "$SRC"* 2>&1 || true
  echo
  echo "=== sfdisk -d (partition table; keep this — it is the restore blueprint) ==="
  sfdisk -d "$SRC" 2>&1 || true
  echo
  echo "=== parted (sectors) ==="
  parted -s "$SRC" unit s print 2>&1 || true
  echo
  echo "=== device identity ==="
  cat "/sys/class/block/$(basename "$SRC")/device/model" 2>/dev/null || true
  cat "/sys/class/block/$(basename "$SRC")/device/rev"   2>/dev/null || true
  echo
  echo "=== health probe (informational; a 2007 SSD usually reports nothing) ==="
  smartctl -a "$SRC" 2>&1 || echo "smartctl unavailable or the device reports no SMART"
  hdparm -I "$SRC" 2>&1 | head -30 || true
} > "$IMG.meta.txt" 2>&1

chmod 0644 "$IMG" "$IMG.sha256" "$IMG.meta.txt"

# ---- report -----------------------------------------------------------------
note ""
note "=============================================================="
note " BACKUP OK — verified by hash"
note "=============================================================="
note " image   : $IMG  ($(( IMG_SIZE / 1024 / 1024 )) MiB)"
note " sha256  : $DST_SHA"
note " sidecar : $(basename "$IMG").sha256"
note " meta    : $(basename "$IMG").meta.txt"
note ""
note " Do this now, before any other step:"
note "   1. copy the .img + .sha256 + .meta.txt to a SECOND, physically different"
note "      location (NAS or offline USB). One copy is not a backup."
note "   2. run this again and confirm the two runs report the SAME source sha256 —"
note "      that proves the flash reads consistently."
note "   3. prove the image boots: run it under QEMU (scripts/50-vmtest.sh boots a"
note "      raw image through GRUB to the desktop)."
note ""
note " Restore this image to a card later (DESTRUCTIVE to the target):"
note "   sudo ./flash-card.sh /dev/sdX $IMG"
note ""
note " Restore it to the internal SSD itself: STOP. See docs/storage-resilience.md —"
note " that is the highest-risk action in this project and needs explicit approval."
exit 0
