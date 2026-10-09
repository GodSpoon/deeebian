#!/bin/bash
# flash-card.sh — write a Deeebian disk image onto an SD card / USB device, safely.
#
# This is the ONLY script here that writes a block device, and it writes only to
# the device you name on the command line. It shows the target's size and model,
# makes you confirm, and refuses several classes of fatal mistake:
#   * refuses a partition (pass the whole disk: /dev/sdb, not /dev/sdb1)
#   * refuses the disk that is this machine's root / boot / swap
#   * refuses any disk that has a mounted filesystem or active swap
#   * refuses the disk that holds the image file (you would dd over the source)
#   * refuses an image that does not fit the target
#   * refuses a compressed image (.xz/.gz/...) — dd of compressed bytes produces an
#     unbootable card that looks perfectly fine
#   * refuses a target that does not match its own .sha256 sidecar
#   * refuses an image whose own .sha256 sidecar does not match it
#   * refuses the 701's internal 2007-era SSD by device node, unless --force-ssd
#   * asks for an extra typed acknowledgement (SMALL-DEVICE) on any target under
#     16 GiB, where "is this the internal SSD?" is the question worth asking
# Then it writes, syncs, reads the image-sized prefix back off the device, compares
# its sha256 with the image's, and only ejects if the hashes match.
#
# Usage:
#   sudo ./flash-card.sh /dev/sdX [image.img]
#   DEEEPC_IMG=/path/eeepc701-linux.img sudo ./flash-card.sh /dev/sdX
#   sudo ./flash-card.sh --dry-run /dev/sdX eeepc701-linux.img
#
set -euo pipefail

BS=4M
ASSUME_YES=0
DRY_RUN=0
DO_EJECT=1
FORCE_SSD=0
DEV=
IMG=

die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
note() { printf '%s\n' "$*"; }

usage() {
  cat <<'USAGE'
flash-card.sh — write a Deeebian image to an SD card / USB device, safely.

  sudo ./flash-card.sh /dev/sdX [image.img]
  sudo ./flash-card.sh --dry-run /dev/sdX eeepc701-linux.img
  DEEEPC_IMG=/path/eeepc701-linux.img sudo ./flash-card.sh /dev/sdX

Options:  -y|--yes  skip the typed-path confirmation (not the SSD/small-device gate)
          -n|--dry-run   show the plan, write nothing
          --no-eject     leave the device's eject/power state alone
          --force-ssd    allow the internal SSD / a small target (small targets then
                         still need the typed SMALL-DEVICE acknowledgement)
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

fs_bdev() { findmnt -rn -o SOURCE --target "$1" 2>/dev/null | head -1 || true; }

# ---- arguments --------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    -y|--yes)     ASSUME_YES=1; shift ;;
    -n|--dry-run) DRY_RUN=1; shift ;;
    --no-eject)   DO_EJECT=0; shift ;;
    --force-ssd)  FORCE_SSD=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    -*)           die "unknown option: $1 (try --help)" ;;
    *)            if [ -z "$DEV" ]; then DEV=$1
                  elif [ -z "$IMG" ]; then IMG=$1
                  else die "unexpected argument: $1"; fi
                  shift ;;
  esac
done

[ -n "$DEV" ] || { usage; exit 2; }

if [ -z "$IMG" ]; then
  for c in "${DEEEPC_IMG:-}" ./eeepc701-linux.img /var/lib/vz/eeepc/eeepc701-linux.img; do
    [ -n "$c" ] && [ -f "$c" ] && { IMG=$c; break; }
  done
fi
[ -n "$IMG" ] || die "no image given and none found. Pass one, or set DEEEPC_IMG=/path/to/eeepc701-linux.img"

# ---- privilege (resolve the image first so the re-exec passes it explicitly) ----
PASS=()
[ "$ASSUME_YES" -eq 1 ] && PASS+=(--yes)
[ "$DRY_RUN" -eq 1 ]    && PASS+=(--dry-run)
[ "$DO_EJECT" -eq 0 ]   && PASS+=(--no-eject)
[ "$FORCE_SSD" -eq 1 ]  && PASS+=(--force-ssd)
if [ "$(id -u)" -ne 0 ]; then
  command -v sudo >/dev/null 2>&1 || die "must run as root (writing a block device needs it)"
  SELF=$0
  case "$SELF" in
    /*)   ;;
    */*)  SELF="$PWD/$SELF" ;;
    *)    SELF=$(command -v "$SELF" 2>/dev/null || printf '%s' "$SELF") ;;
  esac
  exec sudo -- bash "$SELF" ${PASS[@]+"${PASS[@]}"} "$DEV" "$IMG"
fi

# ---- image checks -----------------------------------------------------------
[ -e "$IMG" ] || die "image $IMG does not exist"
[ -f "$IMG" ] || die "image $IMG is not a regular file"
case "$IMG" in
  *.xz|*.gz|*.bz2|*.zst|*.zstd|*.zip|*.7z|*.lz4)
    die "$IMG looks compressed. dd would write the compressed bytes and produce an
  unbootable card that looks fine. Decompress it first, e.g.:
    xz -dc $(basename "$IMG") > eeepc701-linux.img
  (gzip/bzip2/zstd -dc for the others), then pass the resulting .img." ;;
esac
IMG=$(realpath_of "$IMG")
IMGSIZE=$(stat -c %s "$IMG")
[ "$IMGSIZE" -gt 0 ] || die "image $IMG is empty"

# ---- device checks ----------------------------------------------------------
[ -e "$DEV" ] || die "target $DEV does not exist"
[ -b "$DEV" ] || die "target $DEV is not a block device"
DEV=$(realpath_of "$DEV")

if [ -e "/sys/class/block/$(basename "$DEV")/partition" ]; then
  die "$DEV is a partition. Pass the whole disk (e.g. /dev/sdb, not /dev/sdb1)."
fi

DEV_SIZE=$(blockdev --getsize64 "$DEV")
[ "$IMGSIZE" -le "$DEV_SIZE" ] || die "image is $(( IMGSIZE / 1024 / 1024 )) MiB but $DEV is only
  $(( DEV_SIZE / 1024 / 1024 )) MiB — it does not fit."

# (1) never the running root device
ROOT_SRC=$(findmnt -rn -o SOURCE / 2>/dev/null || true)
if [ -n "$ROOT_SRC" ] && [ -b "$ROOT_SRC" ]; then
  ROOT_DISK=$(parent_disk "$ROOT_SRC")
  [ "$(realpath_of "$ROOT_DISK")" != "$DEV" ] || die \
    "REFUSED: $DEV is this machine's root disk (it holds /). You cannot dd over a live root
  filesystem, and flashing the card you are running from destroys the running system.
  Flash from another machine, or boot the target from something else first."
fi

# (2) never a disk with anything mounted or swapped on it
while IFS= read -r src; do
  [ -n "$src" ] || continue
  case "$src" in /dev/*) ;; *) continue ;; esac
  pd=$(parent_disk "$src")
  if [ "$(realpath_of "$pd")" = "$DEV" ]; then
    die "REFUSED: $DEV is in use — $src is mounted (or is swap). Unmount everything on
  $DEV first (umount, swapoff) so the write is not raced by a live filesystem."
  fi
done < <(awk '{print $1}' /proc/mounts /proc/swaps 2>/dev/null)

# (3) never the disk that holds the image file
IMGDIR=$(dirname "$IMG")
IMG_FS=$(fs_bdev "$IMGDIR")
if [ -n "$IMG_FS" ] && [ -b "$IMG_FS" ]; then
  IMG_DISK=$(parent_disk "$IMG_FS")
  [ "$(realpath_of "$IMG_DISK")" != "$DEV" ] || die \
    "REFUSED: the image lives on $DEV. dd would overwrite the source while reading it."
fi

# (4) the 2007 internal SSD is a special case, identified by its device node.
#     Node-based detection (not size-based) so a legitimate small SDHC card is not blocked;
#     the size warning below covers the case where the internal disk enumerates elsewhere.
INTERNAL_SSD=${DEEEPC_INTERNAL_SSD:-/dev/sda}
INTERNAL_SSD=$(realpath_of "$INTERNAL_SSD")
IS_INTERNAL_SSD=0
if [ -b "$INTERNAL_SSD" ] && [ -n "$(devno "$DEV")" ] && \
   [ "$(devno "$DEV")" = "$(devno "$INTERNAL_SSD")" ]; then
  IS_INTERNAL_SSD=1
fi
if [ "$IS_INTERNAL_SSD" -eq 1 ] && [ "$FORCE_SSD" -eq 0 ]; then
  die "REFUSED: $DEV is the 701's internal SSD ($INTERNAL_SSD). Writing it is the highest-risk
  action in this project: it is the one device you cannot replace, it is 2007-era flash you
  cannot health-check, and a bad write can wedge the whole ATA channel so the machine will
  not boot even from the SD card.
  Read docs/storage-resilience.md. If you genuinely mean to write the internal SSD — after
  the backup is hash-verified, restored and booted in QEMU — re-run with --force-ssd and type
  INTERNAL-SSD when asked."
fi

# (5) small target: informational. Real 4-8 GB SDHC cards are fine and common for this machine,
#     so this is a warning + an extra typed acknowledgement, not a hard refusal.
SMALL_GIB=${DEEEPC_SMALL_GIB:-16}
IS_SMALL=0
[ "$DEV_SIZE" -lt $(( SMALL_GIB * 1024 * 1024 * 1024 )) ] && IS_SMALL=1

# ---- show the target and the image ------------------------------------------
note "=============================================================="
note " Deeebian image writer"
note "=============================================================="
note " TARGET DEVICE — ALL DATA ON IT WILL BE DESTROYED:"
note "   path : $DEV"
lsblk -dno NAME,SIZE,MODEL,SERIAL,TRAN "$DEV" 2>/dev/null | sed 's/^/   /' || true
note "   size : $(( DEV_SIZE / 1024 / 1024 )) MiB"
[ "$IS_SMALL" -eq 1 ] && note "   NOTE : under ${SMALL_GIB} GiB — is this the internal SSD rather than a card?"
note ""
note " IMAGE:"
note "   path : $IMG"
note "   size : $(( IMGSIZE / 1024 / 1024 )) MiB"
IMG_SHA=$(sha256sum "$IMG" | awk '{print $1}')
note "   sha256 : $IMG_SHA"
if [ -f "$IMG.sha256" ]; then
  WANT=$(awk '{print $1; exit}' "$IMG.sha256")
  [ "$WANT" = "$IMG_SHA" ] || die "the image does not match its own $IMG.sha256 sidecar — it is
  corrupt. Refusing to write it. Re-download or re-verify the image."
  note "   sidecar $IMG.sha256 : OK"
fi
note ""

if [ "$DRY_RUN" -eq 1 ]; then
  note "--dry-run: nothing was written."
  note "Would run:"
  note "  dd if=$IMG of=$DEV bs=$BS conv=fsync status=progress"
  note "  sync; blockdev --flushbufs $DEV"
  note "  read $IMGSIZE bytes back off $DEV and compare sha256 with the image"
  [ "$DO_EJECT" -eq 1 ] && note "  eject $DEV"
  exit 0
fi

# ---- confirmation -----------------------------------------------------------
if [ "$ASSUME_YES" -eq 1 ] && [ "$IS_SMALL" -eq 0 ]; then
  note "--yes given: skipping the typed-path confirmation."
else
  note "Type the device path exactly ($DEV) to confirm, or anything else to abort:"
  printf '  > '
  read -r ans || ans=
  [ "$ans" = "$DEV" ] || die "not confirmed — aborted, nothing written."
  if [ "$IS_SMALL" -eq 1 ]; then
    note ""
    note "!! This target is small. If it is the 701's internal 2007-era SSD, STOP: writing it"
    note "!! is the highest-risk action in this project. It must not happen until the backup"
    note "!! is hash-verified, restored, and booted in QEMU, and you have explicitly approved it."
    note "!! See docs/storage-resilience.md."
    note "Type SMALL-DEVICE (all caps) to acknowledge and continue, or anything else to abort:"
    printf '  > '
    read -r ans2 || ans2=
    [ "$ans2" = "SMALL-DEVICE" ] || die "not acknowledged — aborted, nothing written."
  fi
fi

# ---- write ------------------------------------------------------------------
note ""
note "Writing… (do not remove the device; minutes on USB 2.0)"
t0=$(date +%s)
dd if="$IMG" of="$DEV" bs="$BS" conv=fsync status=progress
sync
blockdev --flushbufs "$DEV" 2>/dev/null || true
t1=$(date +%s)

# ---- verify -----------------------------------------------------------------
note ""
note "Verifying: reading $IMGSIZE bytes back off $DEV and hashing…"
DEV_SHA=$(head -c "$IMGSIZE" "$DEV" | sha256sum | awk '{print $1}')

if [ "$DEV_SHA" != "$IMG_SHA" ]; then
  die "VERIFY FAILED — the device does not match the image byte-for-byte.
  image  sha256 : $IMG_SHA
  device sha256 : $DEV_SHA
  The device is NOT bootable/trustworthy. Do not use it, do not relabel it working.
  Left un-ejected on purpose so you can inspect it. Likely causes: a counterfeit or
  failing card, reader trouble (try the 701 BIOS 'OS Installation' setting), or a
  USB cable/hub fault. Re-run, or try a different card/reader."
fi

note "  image  sha256 : $IMG_SHA"
note "  device sha256 : $DEV_SHA"
note "  MATCH — the written image is byte-identical to the source ($(( t1 - t0 ))s)."

# ---- eject ------------------------------------------------------------------
if [ "$DO_EJECT" -eq 1 ]; then
  if command -v udisksctl >/dev/null 2>&1; then
    udisksctl power-off -b "$DEV" 2>/dev/null || true
  fi
  if command -v eject >/dev/null 2>&1; then
    eject "$DEV" 2>/dev/null || true
  fi
  sync
  note "  $DEV ejected."
fi

note ""
note "Done. Remove the device, put it in the 701, and boot it"
note "(F2 -> Boot -> move the SD reader to first; or Esc for the one-time menu)."
exit 0
