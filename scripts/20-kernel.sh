#!/bin/bash
# 20-kernel.sh — runs INSIDE the i386 chroot (kernel source bind-mounted at /build)
# Builds a vanilla 6.12 LTS i386 kernel, NON-PAE (CONFIG_HIGHMEM4G) with Eee PC 701
# drivers built in. Non-PAE boots on both PAE and non-PAE CPUs.
set -euo pipefail

KSRC=$(ls -d /build/linux-6.12.* | head -1)
cd "$KSRC"

make i386_defconfig

# --- config edits via sed (scripts/config helper was removed upstream) ---
# Processor: Pentium M (Dothan family 6) — matches the Celeron M ULV 353
sed -i -e 's/^CONFIG_M686=y/# CONFIG_M686 is not set/' \
       -e 's/^# CONFIG_MPENTIUMM is not set/CONFIG_MPENTIUMM=y/' .config

# ASSERT non-PAE build (olddefconfig below must not re-enable it)
sed -i -e 's/^CONFIG_X86_PAE=y/# CONFIG_X86_PAE is not set/' \
       -e 's/^# CONFIG_HIGHMEM4G is not set/CONFIG_HIGHMEM4G=y/' .config

# --- Force the built-in "=y" driver set, converging through kconfig dependencies ------
# kconfig OMITS the children of a disabled symbol from .config entirely — with MEDIA_SUPPORT
# unset there is no "# CONFIG_USB_VIDEO_CLASS is not set" line at all for a sed to match, and
# VIDEO_DEV is a hidden symbol driven only by its `default`. A single sed pass therefore CANNOT
# set a dependency chain; that is exactly why the first v1.1.0 run died with
# "FATAL: uvcvideo (webcam) not built-in", and why FRAMEBUFFER_CONSOLE (depends on FB) failed too.
# Set what is reachable, let `olddefconfig` materialise the newly-reachable symbols, repeat until
# the set stops improving, then ASSERT. Bounded at 6 passes; olddefconfig is cheap.
WANT="ATA ATA_PIIX BLK_DEV_SD SCSI \
      USB USB_SUPPORT UHCI_HCD OHCI_HCD EHCI_HCD USB_STORAGE \
      CFG80211 MAC80211 WIRELESS ATH5K ATH5K_PCI ATL2 \
      SOUND SND SND_HDA SND_HDA_INTEL SND_HDA_GENERIC SND_HDA_CODEC_GENERIC SND_HDA_CODEC_REALTEK \
      DRM DRM_KMS_HELPER DRM_FBDEV_EMULATION DRM_I915 EEEPC_LAPTOP \
      MEDIA_SUPPORT MEDIA_USB_SUPPORT MEDIA_CAMERA_SUPPORT MEDIA_SUPPORT_FILTERS \
      VIDEO_DEV V4L2_FWNODE V4L2_ASYNC VIDEOBUF2_CORE VIDEOBUF2_VMALLOC USB_VIDEO_CLASS \
      ZSMALLOC ZRAM CRYPTO_LZ4 \
      FB FB_CORE FB_VESA FRAMEBUFFER_CONSOLE VT VT_CONSOLE INPUT \
      SERIAL_8250 SERIAL_8250_CONSOLE \
      EXT4_FS VFAT_FS NLS_CODEPAGE_437 NLS_ISO8859_1"

PREV=""
for pass in 1 2 3 4 5 6; do
  for c in $WANT; do
    sed -i -e "s/^# CONFIG_${c} is not set/CONFIG_${c}=y/" \
           -e "s/^CONFIG_${c}=m/CONFIG_${c}=y/" .config
  done
  make olddefconfig >/dev/null 2>&1
  CUR=$(grep -E "^CONFIG_($(echo $WANT | tr ' ' '|'))=y$" .config | sort | tr '\n' ' ')
  got=$(echo "$CUR" | wc -w); tot=$(echo $WANT | wc -w)
  echo "kconfig pass $pass: $got/$tot of the wanted set built in"
  [ "$CUR" = "$PREV" ] && { echo "kconfig converged at pass $pass"; break; }
  PREV="$CUR"
done

# A 900 MHz Celeron M does not need a 1000 Hz tick; i386_defconfig defaults to HZ=1000.
# 250 Hz is the standard netbook choice (battery, fewer wakeups, negligible latency cost).
# NB: the generic loop above cannot set HZ_250 — "CONFIG_HZ_250" does not match the
# "# CONFIG_HZ_250 is not set" line, because sed's leading '# ' is literal.
sed -i -e 's/^CONFIG_HZ_1000=y/# CONFIG_HZ_1000 is not set/' \
       -e 's/^# CONFIG_HZ_250 is not set/CONFIG_HZ_250=y/' \
       -e 's/^CONFIG_HZ=1000/CONFIG_HZ=250/' .config

# Keep debug noise off
sed -i -e 's/^CONFIG_DEBUG_INFO=y/# CONFIG_DEBUG_INFO is not set/' \
       -e 's/^CONFIG_DEBUG_INFO_BTF=y/# CONFIG_DEBUG_INFO_BTF is not set/' \
       -e 's/^CONFIG_GDB_SCRIPTS=y/# CONFIG_GDB_SCRIPTS is not set/' .config

make olddefconfig

# --- hard assertions ---
grep -q '^CONFIG_X86_PAE=y' .config && { echo "FATAL: PAE enabled"; exit 1; }
grep -q '^CONFIG_HIGHMEM4G=y' .config || { echo "FATAL: HIGHMEM4G missing"; exit 1; }
grep -q '^CONFIG_DRM_I915=y' .config || { echo "FATAL: i915 not built-in"; exit 1; }
grep -q '^CONFIG_ATH5K=y' .config || { echo "FATAL: ath5k not built-in"; exit 1; }
# The console and the webcam are asserted because the docs/README advertise both. Without
# FRAMEBUFFER_CONSOLE the text console dies when i915 takes over (no VTs either), and without
# MEDIA_SUPPORT/USB_VIDEO_CLASS there is no webcam at all.
grep -q '^CONFIG_FRAMEBUFFER_CONSOLE=y' .config || { echo "FATAL: no framebuffer console (no VTs on the 701)"; exit 1; }
grep -q '^CONFIG_DRM_FBDEV_EMULATION=y' .config || { echo "FATAL: no DRM fbdev emulation (console dies at i915 init)"; exit 1; }
grep -q '^CONFIG_MEDIA_SUPPORT=y' .config || { echo "FATAL: no media subsystem (webcam advertised but absent)"; exit 1; }
grep -q '^CONFIG_USB_VIDEO_CLASS=y' .config || { echo "FATAL: uvcvideo (webcam) not built-in"; exit 1; }
grep -q '^CONFIG_HZ_1000=y' .config && { echo "FATAL: HZ=1000 on a 900 MHz netbook"; exit 1; }
echo "CONFIG checks passed:"; grep -E 'CONFIG_(X86_PAE|HIGHMEM4G|MPENTIUMM|DRM_I915|ATH5K|ATL2|USB_STORAGE|ATA_PIIX|FRAMEBUFFER_CONSOLE|DRM_FBDEV_EMULATION|MEDIA_SUPPORT|USB_VIDEO_CLASS|HZ)=' .config | sort -u

make -j"$(nproc)" LOCALVERSION=-eeepc bzImage modules

KREL=$(make -s kernelrelease LOCALVERSION=-eeepc)
echo "kernelrelease=$KREL"

make LOCALVERSION=-eeepc modules_install
cp arch/x86/boot/bzImage "/boot/vmlinuz-$KREL"
cp System.map "/boot/System.map-$KREL"
cp .config "/boot/config-$KREL"

echo "=== kernel build done: $KREL ==="
