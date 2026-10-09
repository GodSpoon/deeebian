# deeebian

**A purpose-built 32-bit Linux for the ASUS Eee PC 701 4G** (2007 netbook — Celeron M ULV 353 @ 900 MHz,
Intel 915GM, Atheros AR5007EG wifi, 2 GB RAM).

Built to be flashed to an SD card and booted on the real hardware. Runs entirely out of RAM-backed
swap, so the card is never written for paging — fast and gentle on the card.

- **Base:** Debian 12 (bookworm) i386 — the last Debian with a 32-bit kernel/installer
- **Kernel:** vanilla **6.12 LTS, i386, non-PAE** (`CONFIG_HIGHMEM4G`), Pentium-M tuned,
  every 701 driver **built into `vmlinuz`** — boots on both PAE and non-PAE steppings
- **Desktop:** Openbox + tint2 + pcmanfm + lxterminal, lightdm autologin
- **Power / RAM:** `tlp` + zram swap (1 GB lz4) + `earlyoom`, no disk swap, /tmp on tmpfs,
  ext4 `noatime,commit=60`, journald capped at 30 MB
- **Clone-safe:** machine-id and SSH host keys regenerated on first boot

---

## Put it on an SD card

> **Card note: SDXC works.** This was originally believed to be an SD/SDHC-only reader and the
> docs said to stay at <=32 GB. That is **wrong**: this image has been booted on real hardware
> from a **128 GB SDXC** card in the 701's own internal reader, and the kernel enumerates it as a
> plain USB mass-storage device with no capacity limit (`244277248` 512-byte sectors ≈ 116 GiB).
> Use any card you have; 16 GB or more is comfortable, and the first boot grows the root
> filesystem to fill whatever you insert. (If a particular card is *not* seen by the BIOS, that is
> a card/media quirk, not a capacity limit — try another card.)

Get the image from the [Releases page](../../releases), then write it to the card.

**Step 1 — find the card (get this wrong and you wipe your disk):**

```bash
lsblk
```

**Step 2 — write it** (`/dev/sdX` = the whole card, e.g. `/dev/sdb`, *not* `/dev/sdb1`):

```bash
curl -L -o eeepc701-linux.img.xz \
  https://github.com/GodSpoon/deeebian/releases/latest/download/eeepc701-linux.img.xz

xz -dc eeepc701-linux.img.xz | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync
sync
```

One-liner (streams straight to the card, no temp file):

```bash
curl -L https://github.com/GodSpoon/deeebian/releases/latest/download/eeepc701-linux.img.xz \
  | xz -dc | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync
```

Verify the download first if you like:

```bash
sha256sum -c eeepc701-linux.img.xz.sha256
```

Windows/macOS: **balenaEtcher** or **Raspberry Pi Imager** — pick the `.img.xz` directly.

**Step 3 — boot the 701:** power on, tap **F2** at POST → *Boot* → move the **SD card reader**
to first boot device (the BIOS sees the internal reader as USB mass storage); or tap **Esc**
for the one-time boot menu and pick the card. First boot grows the root filesystem to fill the card.

## Login & use

| | |
|---|---|
| User / password | `sam` / `eeepc` — has sudo, change with `passwd`; root is locked |
| Menu | right-click desktop, or **Ctrl+Alt+Menu** |
| Terminal | **Ctrl+Alt+T** (the 701 keyboard has no Super/Windows key) |
| Health check | `eeepc-health` — PASS/FAIL summary of kernel, wifi, network, swap, disk |
| LAN IP | `ip -4 addr` (iproute2 + net-tools are installed) |
| Browser | **Super+F** (Firefox ESR; Netsurf installed for light pages) |
| Wifi | click the **nm-applet** icon in the panel |
| Report a problem | `sudo deeebian-report.sh --note "what is wrong"` — writes a diagnostics tarball |
| Games & toys | `eeepc-games` — install curated games/tools/toys (menu); see [`docs/games-and-software.md`](docs/games-and-software.md) |
| SSH | `ssh sam@eeepc701.local` |
| Update | `sudo apt update && sudo apt upgrade` |
| Battery status | `battery-rejuv status` |
| Recalibrate battery | `sudo battery-rejuv full` (or menu → Battery recalibration) |

## Why it stays light

| Concern | What we do | Effect |
|---|---|---|
| RAM | zram swap 1 GB lz4, `swappiness=150`, `earlyoom`, **no disk swap** | Paging happens in RAM; the SD card is never written for memory pressure — faster, and no card wear |
| Power | `tlp`, `wifi.powersave=2` (ath5k stability), acpid, capped journald | Longest battery on the original cells |
| Battery gauge | `battery-rejuv` (on-device tool) | One full drain→recharge re-teaches the BMS the pack's real endpoints |
| Card life | ext4 `noatime,commit=60`, /tmp on tmpfs, doc-files stripped, 30 MB journal | Fewer small random writes |
| Boot | all 701 drivers built into the kernel | Boots even if the initramfs is ever damaged |

Measured on the shipped image in a 2 GB VM: **~155 MB RAM at the console, ~250-350 MB at the desktop**.
Firefox ESR 128 runs but is slow — this is a 900 MHz 2007 CPU; Netsurf is the pleasant path.

## Battery care

The 701's pack is **2×18650 Li-ion in series (7.4 V nominal, ~4400 mAh)** behind a BMS. An aged or
long-idle pack's *fuel gauge* (the BMS coulomb counter) drifts, so it reports a wrong "100%" and a
wrong runtime. One **full discharge → full recharge** makes the gauge re-learn the real endpoints.
This does **not** repair worn cells — it resynchronises the gauge. Expect the reported full
capacity to *drop* afterwards if the gauge had been optimistic; that is the point.

The tool is installed as **`battery-rejuv`** (source: `scripts/battery-rejuv.sh`):

```bash
battery-rejuv status     # live telemetry (volts, %, state), changes nothing
sudo battery-rejuv full  # drain to the floor, then prompt to charge to a true 100% + top-off
sudo battery-rejuv drain # just the discharge (do it on battery, unplugged)
sudo battery-rejuv charge# just monitor a recharge to 100%
sudo battery-rejuv restore # undo the "keep awake" settings if a run died
```

It also appears in the Openbox menu (**Battery recalibration**). Safety rails: the drain stops at
`BATTERY_FLOOR_PCT` (default 6%) **or** `BATTERY_FLOOR_UV` (default 6.6 V = 3.3 V/cell), whichever
comes first; the firmware hard-cut is the last line of defence, never the plan. A `systemd-inhibit`
lock (`idle:sleep:handle-lid-switch`) keeps the machine awake and off idle-suspend for the whole
run, and all logging goes to `/run` (tmpfs) so a multi-hour cycle writes nothing to the SD card.

For a hands-off run detached from your terminal: `sudo systemctl start battery-rejuv`
(oneshot unit, not enabled at boot). Regression test: `sudo scripts/test-battery-rejuv.sh`
exercises the drain/charge state machines against a fake `power_supply` tree.

## Hardware support

| Component | Driver | Status |
|---|---|---|
| Celeron M ULV 353 | — | non-PAE kernel, boots on all steppings |
| Intel 915GM 800x480 LVDS | i915 (built-in) | native panel EDID |
| Atheros AR5007EG wifi | ath5k (built-in, no blob) | works |
| Attansic/Atheros L2 ethernet | atl2 (built-in) | works |
| Realtek ALC662 audio | snd-hda-intel, auto-unmute on boot | works |
| Internal SD reader | usb-storage (built-in) | bootable from BIOS; **SD, SDHC and SDXC all verified** (128 GB SDXC boots) |
| Webcam | uvcvideo (built-in) | works |
| Fn keys / fan | eeepc-laptop | loaded at boot |

## Known limitations

- **Stock 512 MB RAM is the real constraint.** The tuning below assumes the memory upgrade to
  2 GB. At 512 MB the Openbox desktop is tight — Netsurf is the pleasant browser; Firefox ESR
  will swap heavily. zram swap is sized to installed RAM automatically.
- Flash-heavy websites are slow — 900 MHz, 2007. Use Netsurf or text browsing.
- No Bluetooth stack (the 701 has no Bluetooth).
- Touchpad side-scroll strip acts as a plain scroll edge under libinput.
- Timezone defaults to UTC: `sudo timedatectl set-timezone America/Chicago`.
- bookworm's i386 archive freezes with the distro (Debian LTS/ELTS continues security support).

---

## Building it yourself

Two paths. Both produce the same `eeepc701-linux.img.xz`.

### A. In GitHub Actions (no local hardware needed)

`.github/workflows/build-image.yml` builds the whole image from scratch on `ubuntu-22.04`:
debootstrap i386 → compile the 6.12 LTS non-PAE kernel inside the chroot → configure →
assemble the 7 GiB MBR image with GRUB → `xz` → upload artifact (+ create a release when you push a `v*` tag).

**Actions → build-image → Run workflow** (leave the tag empty for artifact-only, or set one to publish a release).
Expect roughly 25-45 minutes: i386 code runs natively on the x86-64 runner (no CPU emulation), so it is
mostly the kernel `bzImage` compile plus the `xz` of the 7 GiB image.

Push a tag to publish automatically:

```bash
git tag v1.1.0 && git push origin v1.1.0
```

### B. On a local Linux host (root, ~30 min-1 h on a 16-core box)

```bash
sudo EEEPC_BASE=/var/lib/vz/eeepc KERNEL_VERSION=6.12.112 bash ci/build.sh
```

Requires `debootstrap`, i386 execution (native i386 CPU, or `qemu-user-static` + binfmt on amd64),
loop devices and ~15 GB free. On Proxmox you usually need to load the loop module first:
`modprobe loop; for i in $(seq 0 15); do mknod /dev/loop$i b 7 $i; done`.

### Pipeline stages (`scripts/`)

| Script | Runs in | Does |
|---|---|---|
| `10-packages.sh` | chroot | apt sources, package set, preseeding, doc stripping |
| `20-kernel.sh` | chroot (kernel tree at `/build`) | 6.12 LTS i386 non-PAE config, drivers built-in, hard asserts |
| `30-configure.sh` | chroot | hostname, user, fstab, autologin, zram, tlp, first-boot grow, ssh |
| `90-cleanup.sh` | chroot | purge toolchain, sanitize machine-id + host keys for cloning |
| `40-image.sh` | build host (root) | 7 GiB MBR image, fixed UUID, initramfs, static grub.cfg, grub-install, xz |
| `50-vmtest.sh` | build host (root) | KVM boot tests (non-PAE CPU + full BIOS boot) |
| `ci/build.sh` | build host (root) | orchestrates all of the above end-to-end |

`60-ssh-fix.sh` / `61-fixes.sh` backport the two bugs found during bring-up (sshd host-key
ordering, zram via sysfs) into already-built trees. `70-*`–`75-*` are the serial-console
debug harnesses used to verify the boot path.

## Repo layout

```
scripts/     build pipeline (see table above)
ci/build.sh  one-shot end-to-end builder (used by CI and locally)
.github/     Actions workflow
docs/        build report page (index.html + report.html); games-and-software.md = the curated catalogue
testshots/   VM screendumps from verification
```

Build report with design rationale and VM verification: [`docs/report.html`](docs/report.html).
