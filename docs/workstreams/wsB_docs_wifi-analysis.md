# WiFi capability analysis for the deeebian Eee PC 701 image

Target: ASUS Eee PC 701 4G (2007), Intel Celeron M ULV 353 @ 900 MHz, single core,
2 GB RAM, boots from SD card. Kernel: vanilla Linux 6.12 LTS i386, **non-PAE**,
drivers built in (`=y`). Image: Debian 12 (bookworm) i386.

Goal: decide which wireless hardware is worth supporting out-of-the-box, wire it
into the build so it is built into the kernel image and shipped firmware, and
document how to test it on the real device.

All driver/Kconfig/firmware claims below were checked against the actual Linux
6.12 sources (elixir.bootlin.com and raw.githubusercontent.com/torvalds/linux at
tag `v6.12`), the kernel driver database (cateee.net/lkddb), pci.ids / usb.ids, the
linux-wireless docs, linux-hardware.org probe databases, and packages.debian.org
bookworm. Sources are listed at the bottom.

---

## 1. Per-card table

| | Card | Bus / ID | Driver (Linux 6.12) | Kconfig chain | Firmware | Debian package | In-tree? |
|---|---|---|---|---|---|---|---|
| **A** | Atheros AR2425 (internal) | PCIe `168c:001c` | `ath5k` | `CONFIG_ATH5K` + `CONFIG_ATH5K_PCI`, under `MAC80211`/`WLAN`/`CFG80211` | **None** (driver loads EEPROM from the card) | — | **In-tree** |
| **B1** | Realtek 802.11ac dongle, `0bda:c811` | USB `0bda:c811` | `rtw88_8821cu` | `CONFIG_RTW88` (dep `MAC80211`) + `CONFIG_RTW88_8821CU` (dep `USB`, selects `RTW88_CORE`,`RTW88_USB`,`RTW88_8821C`) | **Yes** — `/lib/firmware/rtw88/rtw8821c_fw.bin` | `firmware-realtek` (20230210-5, bookworm, all) | **In-tree** (since 6.2) |
| **B2** | Realtek 802.11ac, `0bda:5485` | USB | **none** — this ID is enumerated as a *USB hub* (class 09, `drivers/usb/core/hub.c`), not a wireless NIC | n/a | n/a | n/a | — (not a wifi device as seen by Linux) |
| **B3** | Realtek 802.11ac, `0bda:2d01` | USB | **none in-tree** — not present in any rtw88 USB ID table, nor in the vendor rtl8821cu list | n/a | n/a | n/a | **No** (would need a vendor/DKMS driver after ID confirmation) |
| **C1** | Broadcom BCM943228HM4LD2 = BCM43228 | PCIe `14e4:4359` | **No open in-tree wifi driver.** `brcmsmac` only claims BCMA core revisions 17/23/24; BCM43228 is rev 25+. `brcmfmac`'s BCM4359 entry is chip ID `0x4359` exposed at PCI device ID **`0x43ef`** (BCM4359), **not** `0x4359`. Only `bcma` (the PCI→BCMA bridge) binds `14e4:4359`. | open: `CONFIG_BCMA`+`CONFIG_BCMA_HOST_PCI` (bridge, not usable wifi on its own); proprietary: `broadcom-sta` | proprietary `wl` needs none; the unused brcmfmac path would need `brcmfmac4359c-pcie.bin` | (prop. driver is `broadcom-sta-dkms`, not in bookworm) | **`wl` is out-of-tree/proprietary** |
| **C2** | Intel Centrino Advanced-N 6250 (WiMAX), Dell 9CT6K | PCIe `8086:0087` | `iwlwifi` + `iwldvm` (DVM firmware, *not* iwlmvm) | `CONFIG_IWLWIFI` (dep `PCI`&&`HAS_IOMEM`&&`CFG80211`) + `CONFIG_IWLDVM` (dep `MAC80211`) | **Yes** — `/lib/firmware/iwlwifi-6050-5.ucode` (the 6250 is `IWL_DEVICE_6050` ⇒ fw prefix `iwlwifi-6050`) | `firmware-iwlwifi` (20230210-5, bookworm, all) | **In-tree** |
| *(bonus)* | Intel Centrino Advanced-N 6205 | PCIe `8086:0082` etc. | `iwlwifi` + `iwldvm` | same as C2 | `iwlwifi-6000g2a-6.ucode` | `firmware-iwlwifi` | **In-tree** |

### Notes and evidence

**A — Atheros AR2425.** Already in the shipped WANT list (`ATH5K`, `ATH5K_PCI`) and
asserted. On the real 701 the driver loads (`ath5k: phy0: Atheros AR2425 chip found`)
and `wlp1s0` exists in NetworkManager, not rfkill-blocked. It needs **configuration,
not code**. ath5k requires no firmware blob; the radio calibration lives in the card's
EEPROM (dmesg: `ath: EEPROM regdomain: 0x60`). Nothing to add.

**B — Realtek USB.** The in-kernel `rtw88` USB driver `rtw_8821cu` (module
`rtw88_8821cu`) matched IDs at v6.12 are exactly:
`0bda:{2006,8731,8811,b820,b82b,c80c,c811,c820,c821,c82a,c82b}`, plus `2001:331d`
(D-Link), `7392:c811`/`7392:d811` (Edimax).
- `0bda:c811` **is** in that table ⇒ driven by `rtw88_8821cu`, firmware
  `rtw88/rtw8821c_fw.bin` (present in bookworm `firmware-realtek`).
- `0bda:5485` is **not** in any rtw88 table. Linux enumerates it as a *4-port USB 2.0
  hub* (interface class 09-00-01), handled by the generic USB hub driver. It is not a
  wireless NIC on this bus; either the ID was captured from a hub/composite descriptor
  or it is a device in a non-NIC mode. No wifi driver applies.
- `0bda:2d01` is **not** in any rtw88 table and is **not** in the vendor
  rtl8811cu/rtl8821cu/rtl8731au driver's supported-ID list either. It cannot be claimed
  for rtw88 without evidence. It is very likely a different/ newer Realtek part (or a
  different mode); it needs a fresh `lsusb -v` / `usb-devices` capture on the real
  hardware before any support claim. **Do not assume** it shares the 8821CU class.
- The `rtl8821cu` community drivers are **out-of-tree / DKMS**. On a 900 MHz single-core
  Celeron M a DKMS module **can never be compiled on-device** (a full kernel module build
  is hours at best and needs the full kernel source + toolchain that 90-cleanup.sh strips
  from the image). If a driver is DKMS it must be **cross-built into the image at build
  time or shipped prebuilt** — it cannot be produced at first boot. For `0bda:c811` this
  is moot: the in-tree `rtw88` driver already covers it.

**C1 — Broadcom BCM43228 (`14e4:4359`).** `pci.ids` maps `14e4:4359` to "BCM43228
802.11a/b/g/n"; subvendor `103c:182c` is the HP/`BCM943228HM4L` variant — i.e. the
BCM943228HM4LD2 in hand. The open `brcmsmac` driver's BCMA core-ID table matches only
core revisions 17/23/24 (`BCMA_CORE(…, 24, …)` for the 802.11 core), which is
BCM4313/43224/43225 — **not** BCM43228. The `brcmfmac` PCIe driver does list a
`BRCM_PCIE_4359_DEVICE_ID`, but `brcm_hw_ids.h` defines that as **`0x43ef`** (the BCM4359
chip), which is a different device from `0x4359` (BCM43228). Consequently the only
in-tree driver that binds `14e4:4359` is `bcma` (the PCI host bridge, `host_pci.c`),
which alone does not give you a working wifi interface — every linux-hardware.org probe
for this ID reports "limited/failed" with the open stack, and users fall back to the
proprietary **`wl`** (`broadcom-sta`), which is **out-of-tree** and not packaged for
bookworm. Supporting this card in-image would mean shipping a proprietary DKMS module
cross-built against our kernel — high effort, licence/redistribution problems, and a
card that is strictly worse than the alternatives here (802.11n 2×2, 2.4/5 GHz, but the
701 can't exploit 5 GHz well and it adds a second radio). **Not worth it.**

**C2 — Intel Centrino Advanced-N 6250 (`8086:0087`).** `pci.ids` → "Centrino Advanced-N +
WiMAX 6250 [Kilmer Peak]". Linux 6.12 `iwlwifi/pcie/drv.c` lists
`IWL_PCI_DEVICE(0x0087, 0x1301/0x1306/0x1321/0x1326, iwl6050_2{agn,abg}_cfg)`. Those
`iwl6050_*_cfg` entries use `IWL_DEVICE_6050`, i.e. firmware prefix `iwlwifi-6050`
(API 5) — **not** `iwlwifi-6000g2a`. They belong to the **DVM** family, so the driver
needs `CONFIG_IWLDVM=y` (iwlmvm is for newer MVM parts). Firmware file:
`iwlwifi-6050-5.ucode`, shipped in bookworm `firmware-iwlwifi`. This is a clean,
fully-open, in-tree option. (The 6205/`iwlwifi-6000g2a-6.ucode` case is also covered by
the same two symbols if the user fits a 6205 instead.)

---

## 2. Recommendation (ranked)

1. **Use the internal Atheros AR2425 (A) — highest payoff, near-zero effort.**
   It is already built in, needs no firmware, and the driver + radio are confirmed
   working on the real unit. The blocker is purely configuration: join an SSID and
   NetworkManager will associate. Do nothing in the build; document/testing only.
   Caveat: 802.11b/g only, 1×1 — fine for a 2007 netbook.

2. **Add `iwlwifi` + `iwldvm` for the Intel 6250 (C2) — low effort, good payoff.**
   Two Kconfig symbols, both fully in-tree, no DKMS, no proprietary code, firmware is a
   ~1 MB `.ucode` in a package we already need to add. Gives a second, independently
   testable radio (802.11a/b/g/n 2×2) with no external dongle sticking out of an already
   cramped netbook. **Recommended and implemented.**

3. **Add `rtw88` + `rtw88_8821cu` for the `0bda:c811` dongle (B1) — low effort, enables
   the dongle the user owns three of.** In-tree since 6.2, firmware in `firmware-realtek`.
   **Recommended and implemented.** It also future-proofs: if the user later plugs one of
   the three dongles in, it just works. (The other two dongle IDs are unresolved — see
   caveats — and are explicitly *not* claimed.)

4. **BCM943228HM4LD2 / BCM43228 (C1) — not worth it.** No open in-tree driver for
   `14e4:4359`; requires proprietary out-of-tree `wl`. Skip.

5. **`0bda:5485` / `0bda:2d01` — not supported.** `5485` is a hub; `2d01` is unverified.
   Skip until real-hardware IDs are captured.

### Why exactly these two kernel additions (and no more)

Only symbols justified by the recommendation above were added. Everything else (ath5k,
the whole USB/SCSI/net stack) was already present. Notably **not** added, with reasons:

- `RTW88_8822BU/8822CU/8723DU/8703B` etc. — no owned hardware needs them; each adds
  driver code and is not evidenced by the user's gear.
- `BRCMFMAC`/`BRCMSMAC` — the BCM43228 is not covered by either; adding them would grow
  the kernel for no benefit on this machine.
- `IWLMEI`, `IWLMVM` — MVM/MEI are for much newer Intel parts; the 6250 is DVM.
- Any rtl8xxxu / vendor dongle driver — DKMS-only or unnecessary.

Size impact is small: `rtw88_8821cu` pulls `RTW88_8821C`+`RTW88_USB`+`RTW88_CORE`;
`iwlwifi`+`iwldvm` is the DVM core only. On a 7 GiB image the added firmware packages
are the only measurable cost (`firmware-iwlwifi` + `firmware-realtek`).

---

## 3. What was changed and why

`scripts/20-kernel.sh`
- Appended to the existing `WANT=` list: `RTW88 RTW88_8821CU IWLWIFI IWLDVM`.
  These ride the existing bounded converge loop (6 passes, `make olddefconfig` between),
  which is the only reliable way to set a dependency chain (kconfig omits children of a
  disabled parent, and hidden symbols can't be sed-set).
- Added four matching assertions after the loop, so CI fails loudly if any is missing:
  `CONFIG_RTW88_8821CU=y`, `CONFIG_IWLWIFI=y`, `CONFIG_IWLDVM=y` (plus the existing set).
  Also extended the human-readable `CONFIG checks passed` grep line to echo the new
  symbols.

`scripts/10-packages.sh`
- Added `firmware-iwlwifi firmware-realtek` to the main install list. These are the
  bookworm packages that ship `iwlwifi-6050-5.ucode` (Intel 6250) and
  `rtw88/rtw8821c_fw.bin` (RTL8821CU/8811CU) respectively. Both are `non-free-firmware`,
  which `sources.list` already enables. No `firmware-atheros` (ath5k needs none) and no
  `firmware-brcm80211` (BCM43228 is unsupported by the open drivers).

Boot-from-SD design is untouched: no change to partitioning, GRUB, initramfs, or the
root=UUID scheme. Only the in-kernel driver set and the installed firmware grow.

---

## 4. How to TEST each option on the real 701

Run after booting the image. All commands are safe/read-only except `nmcli` connect.

### A — internal Atheros AR2425 (ath5k)

```sh
lspci -nn | grep -i 168c                 # expect 168c:001c
lsmod | grep ath5k                      # built-in => may not appear in lsmod; that's fine
dmesg | grep -iE 'ath5k|ath:'           # expect "AR2425 chip found", EEPROM regdomain
rfkill list                             # eeepc-wlan: Soft blocked: no / Hard blocked: no
ip link show wlp1s0                     # interface exists?
nmcli device status                     # wlp1s0 should be "disconnected", not "unmanaged"
nmcli device wifi list                  # should show nearby SSIDs
nmcli device wifi connect '<SSID>' password '<password>'
ip addr show wlp1s0                     # expect an inet address after connect
```
If it never associates, it is a configuration/password issue, not a driver issue
(verified: driver loads, radio on, interface present).

### B1 — Realtek RTL8811CU/RTL8821CU dongle (`0bda:c811`)

```sh
lsusb                                   # expect "0bda:c811 Realtek ... 802.11ac NIC"
dmesg | grep -iE 'rtw88|rtw_8821cu'      # expect rtw88 probe + firmware load
ls -l /lib/firmware/rtw88/rtw8821c_fw.bin   # firmware present?
modinfo rtw88_8821cu 2>/dev/null        # built-in => may be absent; driver is =y
nmcli device wifi list                  # new wlanX should appear
dmesg | grep -i 'firmware'              # confirm rtw8821c_fw.bin requested/loaded
```
If the dongle enumerates as a USB **hub** (`lsusb` shows class 09) or as `0bda:5485`,
it is not the NIC path — see caveats.

### C2 — Intel Centrino Advanced-N 6250 (`8086:0087`)

```sh
lspci -nn | grep -i 8086                 # expect 8086:0087
dmesg | grep -i iwlwifi                 # "Detected Intel(R) Centrino(R) Advanced-N + WiMAX 6250"
ls -l /lib/firmware/iwlwifi-6050-5.ucode   # firmware present? (6250 uses the 6050 fw)
nmcli device wifi list
rfkill list                             # a new phyX entry for the Intel radio
```
If dmesg shows a firmware-API mismatch or "no suitable firmware", it means a firmware
version mismatch — check `iwlwifi-6050-*.ucode` is installed and that `IWLDVM` (not just
`IWLWIFI`) is built in.

### C1 — Broadcom BCM43228 (expected to be unsupported)

```sh
lspci -nn | grep -i 14e4                 # expect 14e4:4359
lspci -k -d 14e4:4359                   # "Kernel driver in use:" — expect bcma only, no wifi
dmesg | grep -iE 'brcm|bcma'           # no brcmsmac/brcmfmac claim
# There will be no wlan interface for it with the open stack; only proprietary wl works.
```

---

## 5. Caveats / not fully verified (needs real hardware)

- **`0bda:2d01` is unresolved.** It is in no in-tree driver table and in no vendor
  rtl88xx list I could find. It is *not* claimed by `rtw88_8821cu`. Confirm with
  `lsusb -v -d 0bda:2d01` and `usb-devices` on the real machine before assuming anything.
- **`0bda:5485` is a USB hub** by its Linux enumeration (class 09). If the user's notes
  labelled it a wifi dongle, the ID may have been mis-transcribed or captured from a
  composite device. Re-capture with `lsusb -v`.
- **Firmware filenames/versions** are from the bookworm package file lists
  (`firmware-nonfree 20230210-5`). A `bookworm-backports` firmware package (newer
  `firmware-nonfree`) could carry different/extra files; we deliberately stay on bookworm
  main to keep the image reproducible. If a newer dongle needs newer fw, switch that
  package to backports.
- **BCM43228 (`14e4:4359`)**: the "no open driver" conclusion is based on the BCMA core
  revision table and the `0x4359` vs `0x43ef` device-ID distinction; it matches
  linux-hardware.org reports, but I could not test the card physically.
- **No CI/kernel build was executed here** (this worktree is off the build host). The
  Kconfig symbols and driver coverage are verified from 6.12 source; the *actual* converge
  and the assertions run in `ci/build.sh`. `bash -n` was run on both scripts (see below).
- **Runtime behaviour** of rtw88/iwlwifi on this exact 900 MHz, non-PAE, 2 GB machine is
  untested until the image is built and flashed.

---

## Sources

- Linux 6.12 sources (tag `v6.12`, torvalds/linux via raw.githubusercontent.com and
  elixir.bootlin.com): `drivers/net/wireless/realtek/rtw88/Kconfig`,
  `rtw8821cu.c`; `drivers/net/wireless/intel/iwlwifi/Kconfig`, `pcie/drv.c`,
  `cfg/6000.c`; `drivers/net/wireless/broadcom/brcm80211/Kconfig`,
  `brcmsmac/mac80211_if.c`, `brcmfmac/pcie.c`, `include/brcm_hw_ids.h`;
  `drivers/bcma/host_pci.c`; `include/linux/bcma/bcma.h`.
- cateee.net/lkddb: `RTW88`, `RTW88_8821CU`, `IWLWIFI`, `BRCMSMAC`, `BRCMFMAC`.
- wireless.docs.kernel.org: brcm80211, iwlwifi.
- linux-hardware.org: `usb:0bda-c811`, `pci:14e4-4359-*`.
- pci.ids (pci-ids.ucw.cz) and usb.ids (usb-ids.gowdy.us / linux-usb.org).
- packages.debian.org/bookworm: `firmware-iwlwifi`, `firmware-realtek`,
  `firmware-brcm80211` (file lists), `firmware-nonfree` source.
- morrownr rtl8821cu supported-device-IDs list (vendor driver scope).
