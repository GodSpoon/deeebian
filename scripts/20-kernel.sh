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

# Core drivers + their subsystems built-in (=y): boots with zero initramfs assumptions
for c in ATA ATA_PIIX BLK_DEV_SD SCSI \
         USB USB_SUPPORT UHCI_HCD OHCI_HCD EHCI_HCD USB_STORAGE \
         CFG80211 MAC80211 WIRELESS ATH5K ATL2 \
         SOUND SND SND_HDA SND_HDA_INTEL SND_HDA_GENERIC SND_HDA_CODEC_GENERIC SND_HDA_CODEC_REALTEK \
         DRM DRM_I915 EEEPC_LAPTOP \
         MEDIA_SUPPORT MEDIA_USB_SUPPORT MEDIA_CAMERA_SUPPORT \
         VIDEO_DEV V4L2_FWNODE VIDEOBUF2_CORE VIDEOBUF2_VMALLOC USB_VIDEO_CLASS \
         ZSMALLOC ZRAM CRYPTO_LZ4 \
         FB FB_VESA FRAMEBUFFER_CONSOLE VT INPUT \
         EXT4_FS VFAT_FS NLS_CODEPAGE_437 NLS_ISO8859_1; do
  sed -i -e "s/^# CONFIG_${c} is not set/CONFIG_${c}=y/" \
        -e "s/^CONFIG_${c}=m/CONFIG_${c}=y/" .config
done

# i915 is built in with no fbdev emulation, so nothing re-registers a console once DRM
# takes the display: you lose the text console and every virtual terminal (Ctrl+Alt+F1..F6).
# DRM_FBDEV_EMULATION gives the DRM framebuffer console; VGA_CONSOLE is kept as the early path.
sed -i -e 's/^# CONFIG_DRM_FBDEV_EMULATION is not set/CONFIG_DRM_FBDEV_EMULATION=y/' .config
# UVCVIDEO is a tristate under MEDIA_SUPPORT, not a menuconfig bool
sed -i -e 's/^# CONFIG_USB_VIDEO_CLASS is not set/CONFIG_USB_VIDEO_CLASS=y/' \
       -e 's/^CONFIG_USB_VIDEO_CLASS=m/CONFIG_USB_VIDEO_CLASS=y/' .config

# A 900 MHz Celeron M does not need a 1000 Hz tick; i386_defconfig defaults to HZ=1000.
# 250 Hz is the standard netbook choice (battery, fewer wakeups, negligible latency cost).
sed -i -e 's/^CONFIG_HZ_1000=y/CONFIG_HZ_250=y/' \
       -e 's/^CONFIG_HZ=1000/CONFIG_HZ=250/' \
       -e 's/^# CONFIG_HZ_250 is not set/CONFIG_HZ_250=y/' .config

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
