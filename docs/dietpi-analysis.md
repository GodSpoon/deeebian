# DietPi analysis for the ASUS Eee PC 701 4G image (`deeebian`)

Scope: what DietPi actually is at the source level, which of its design decisions are worth
porting to our purpose-built Debian 12 / i386 image, and — just as important — what must **not**
be copied. All claims below are verified against the DietPi `dev` branch source and the official
docs, not against marketing pages. Every file path, unit name, fstab line and number is taken from
the repository or docs; URLs are listed in [Sources](#sources).

Target hardware recap: Celeron M ULV 353 @ 900 MHz (Dothan, **non-PAE**), Intel 915GM @ 800×480,
Atheros AR5007EG (`ath5k`), Attansic L2 (`atl2`), ALC662, internal SD reader on **USB** mass
storage, 512 MB stock RAM (≤ 2 GB), 4 GB internal SSD, boots from SD/USB.

---

## 1. DietPi architecture summary

### 1.1 What it is, technically

DietPi is **not a distribution with its own package base**. It is a curated Debian rootfs plus a
large Bash "userland framework" that is layered onto Debian (Bookworm/Trixie/Forky; Raspbian for
ARMv6). The repo's own language breakdown is `bash` + `debian`; there is no C, no init of its own,
no kernel of its own for most boards ("we maintain own kernel sources only for a small number of
SBCs … instead, we focus on userland development"). It keeps Debian's `apt`, systemd, and package
set; it does *not* replace them. The value is in three things: (a) a minimal base package set,
(b) an opinionated set of `dietpi-*` Bash tools, and (c) an unattended first-boot automation
mechanism.

The layout is deliberately split across two anchors:

- **`/boot/dietpi/`** — the scripts (git-tracked, updated as a unit):
  `dietpi/` holds the top-level tools (`dietpi-software`, `dietpi-config`, `dietpi-services`,
  `dietpi-update`, `dietpi-launcher`, `dietpi-backup`, `dietpi-drive_manager`, `dietpi-network`,
  …), `dietpi/func/` holds the shared functions (`dietpi-globals`, `dietpi-ramlog`,
  `dietpi-logclear`, `dietpi-set_cpu`, `dietpi-set_hardware`, `dietpi-set_swapfile`, `dietpi-wifidb`,
  `dietpi-obtain_hw_model`, …), and `preboot`/`postboot`/`dietpi-login` are the boot hooks.
- **`/var/lib/dietpi/services/`** — the tiny root-level service scripts that must run before
  `/boot` is fully usable at the earliest boot stage: `fs_partition_resize.sh`,
  `dietpi-firstboot.bash`, `dietpi-wifi-monitor.sh`, `dietpi-fs_automount.sh`.

Everything sources **`/boot/dietpi/func/dietpi-globals`**, a ~thousands-of-lines function library
that provides `G_WHIP_*` (whiptail dialogs), `G_AGI/G_AGP/G_AGUP/…` (apt wrappers),
`G_CONFIG_INJECT` (idempotent config edits), `G_DIETPI-NOTIFY`, `G_GET_NET`, `G_EXEC`, etc.

### 1.2 How images are built and bootstrapped

The build system lives in `.build/images/`. The pipeline (`.build/images/dietpi-build`) is:

1. Create a raw image file, partition it (`parted`, GPT or msdos), `mkfs` the root and optional
   FAT `/boot` partition, mount it, and write `/etc/fstab`. Root is mounted
   `noatime,lazytime`; the **FAT boot partition exists primarily so that `dietpi.txt` can be edited
   from Windows/macOS** before first boot.
2. Build the rootfs with **`mmdebstrap`**:
   `mmdebstrap --mode=root --format=dir --skip=check/empty,check/qemu --variant=apt --include="$packages" …`.
   Base `packages` include: `apt,bash-completion,ca-certificates,cron,curl,fdisk,gpg,htop,
   iputils-ping,locales,login,mawk,mount,nano,parted,passwd,procps,psmisc,sudo,systemd-sysv,tzdata,
   udev,wget,`**`whiptail`**`,…` plus (physical machines) `console-setup,ethtool,fake-hwclock,kmod,
   rfkill,systemd-timesyncd,usbutils`, plus network `dropbear,ifupdown,dhcpcd-base`, plus WiFi
   `hdparm,iw,wpasupplicant,wireless-regdb`. DietPi's default SSH server is **Dropbear**, its
   default networking is **ifupdown + wpa_supplicant** (not NetworkManager).
3. Copy `rootfs/` over the base, then **boot the image in QEMU** and run
   `.build/images/dietpi-installer` inside it to finalise kernel/bootloader/firmware and move
   kernel + config into `/boot`.
4. `.build/images/dietpi-imager` shrinks the image, converts it, and compresses it.

Crucially, the build and the installer **download code from GitHub at build time**
(`curl … raw.githubusercontent.com/$G_GITOWNER/DietPi/$G_GITBRANCH/dietpi/func/dietpi-globals`,
`…/.build/images/dietpi-installer`) and debootstrap from live mirrors. There is no offline build
path. Also relevant: `.build/images/dietpi-build`'s `HW_MODEL` table knows **only ARM SBCs plus
`20) VM` and `21) NativePC`, and `NativePC` forces `HW_ARCH=10` (x86_64)**. There is **no i386
target** in DietPi's build system.

The rootfs also carries a few `/etc` policy files worth noting because they are pure, portable
"lightness" wins:

- `/etc/apt/apt.conf.d/97dietpi`: `APT::Install-Recommends "false";`, `Acquire::Languages "none";`,
  `Acquire::GzipIndexes "true";`, `…::KeepCompressedAs "xz";` — fewer bytes downloaded and **fewer
  writes to the SD card** on every `apt update`.
- `/etc/sysctl.d/97-dietpi.conf`: `vm.swappiness=1` (intended for a *disk* swap file),
  `kernel.printk = 4 4 1 7` (quiet console), `net.ipv4.ping_group_range = 0 2147483647`.
- `/etc/tmpfiles.d/dietpi.conf`: `d /run/dietpi 0777`.
- Boot-time tmpfs in fstab: `tmpfs /tmp tmpfs noatime,lazytime,nodev,nosuid,mode=1777` and
  `tmpfs /var/log tmpfs size=50M,noatime,lazytime,nodev,nosuid`.

### 1.3 The first-boot automation (`dietpi.txt`, `dietpi-setup`, boot chain)

The boot order (verified against the systemd units in `rootfs/etc/systemd/system/` and the wiki):

```
dietpi-fs_partition_resize.service   → /var/lib/dietpi/services/fs_partition_resize.sh
dietpi-ramlog.service                → /boot/dietpi/func/dietpi-ramlog 0
dietpi-preboot.service               → /boot/dietpi/preboot
dietpi-firstboot.service             → /var/lib/dietpi/services/dietpi-firstboot.bash  (once)
dietpi-postboot.service              → /boot/dietpi/postboot
```

- `fs_partition_resize.sh` maximises the last partition (`sfdisk -fN…` + `resize2fs`), and, on
  boards with a trailing `DIETPISETUP` partition, imports `dietpi.txt`, `dietpi-wifi.txt`,
  `Automation_Custom_*.sh` from it before deleting it. It re-enables itself across an intermediate
  reboot for GPT partition tables.
- `dietpi-preboot` runs `dietpi-obtain_hw_model` and then `dietpi-set_cpu` (governor, min/max
  freq, ondemand `up_threshold`/`sampling_rate`).
- `dietpi-firstboot.bash` is the automation core. It parses `/boot/dietpi.txt` with
  `sed -n '/^[[:blank:]]*KEY=/{s/^[^=]*=//p;q}'`, applies timezone/locale/keyboard/hostname/APT
  mirror, **regenerates the machine-id** (`rm /etc/machine-id; systemd-machine-id-setup`) and the
  SSH host keys (`dropbearkey`), applies `AUTO_SETUP_SSH_PUBKEY` and the SSH password-login policy,
  configures networking via `dietpi-network`, forces a time sync, then writes `0 > /boot/dietpi/.install_stage`
  and disables itself.
- On first *login*, `/etc/bashrc.d/dietpi.bash` → `/boot/dietpi/dietpi-login` completes the rest
  (banner, licence, `dietpi-update`, `dietpi-software` first-run prompts).
- `dietpi-postboot` creates the swap file, runs the survey, checks for updates in the background,
  runs user scripts in `/var/lib/dietpi/postboot.d/`, and prints the banner.

`/boot/dietpi.txt` is a 367-line key=value config. Representative defaults:
`AUTO_SETUP_AUTOMATED=0` (unattended off by default), `AUTO_SETUP_GLOBAL_PASSWORD=dietpi`,
`AUTO_SETUP_NET_ETHERNET_ENABLED=1`, `AUTO_SETUP_NET_WIFI_ENABLED=0`,
`AUTO_SETUP_SWAPFILE_SIZE=1`, `AUTO_SETUP_RAMLOG_MAXSIZE=50`, `AUTO_SETUP_LOGGING_INDEX=-1`,
`CONFIG_CPU_GOVERNOR=schedutil`, `CONFIG_CHECK_DIETPI_UPDATES=1`, `CONFIG_CHECK_APT_UPDATES=1`.
Unattended operation is triggered by `AUTO_SETUP_AUTOMATED=1`; the result is logged to
`/var/tmp/dietpi/logs/dietpi-firstrun-setup.log`.

### 1.4 Licensing and what it means for us

DietPi is **GPL-2.0** (`LICENSE`, GPLv2 June 1991; the GitHub repo is flagged `GPL-2.0 license`).
Practical consequences:

- **Copying a code file** (e.g. lifting `dietpi-ramlog`, `dietpi-services`, `dietpi-globals`
  verbatim into our image or repo) makes our derived file a GPLv2 work: we must ship the source,
  keep the copyright/licence notices, and license that file GPLv2. That is fine if we *want*
  `deeebian` to carry GPLv2 files, but it must be a conscious choice and the notices must stay.
- **Ideas, algorithms and techniques are not copyrightable.** The *concept* of "mount `/var/log`
  on tmpfs and persist only the empty file/dir skeleton with `cp -a --attributes-only`", the
  *concept* of a `[Service] Nice=/CPUSchedulingPolicy=` drop-in, the boot-chain ordering, the
  `dietpi.txt` config-file-automation model, the RAM-limit choices — all of these we can
  **reimplement in our own shell** with no licence obligation. This report recommends the
  reimplement path for essentially everything, which also avoids dragging in the ARM-centric
  `dietpi-globals` framework.

Net: treat DietPi as a **design reference**, not a code source. Where a mechanism is 2–20 lines of
generic Bash (RAMlog's `cp --attributes-only`, the tmpfs fstab line, a nice-value drop-in), we
write our own; where it is a large framework (`dietpi-software`, `dietpi-globals`, `dietpi-update`)
we take only the idea.

---

## 2. Feature-by-feature table

Resource-cost figures are DietPi's own published measurements on a Raspberry Pi Zero W
(512 MB, Trixie 32-bit, tested 2026-03-31): **42 MiB RAM, 9 running processes, 702 MiB disk,
215 packages, 27.8 s boot** — i.e. a whole console system in ~42 MiB. Our shipped image measures
~155 MB at console and ~250–350 MB at the desktop (VM measurement, README). "Applicable?" column
asks specifically: 900 MHz single-core, 512 MB–2 GB RAM, slow SD, non-PAE i386.

| Feature | What it does (mechanism, real paths) | Measured cost | Applicable to the 701? | Verdict |
|---|---|---|---|---|
| **dietpi-software** | Whiptail catalogue + installer for ~200 curated apps; per-app Bash install blocks keyed by integer IDs; `AUTO_SETUP_INSTALL_SOFTWARE_ID=<id>` for unattended. Pulls packages from app vendors, often ARM-specific. | One interactive Bash process while running; 0 when idle. The *framework* it depends on (`dietpi-globals`) is heavy to source. | The **idea** yes (a small "install extra software" menu); the **catalogue** no — it is ARM/SBC-shaped. | **IDEA** — reimplement a ~15-entry `eeepc-software` menu in our own shell; do not port the ID database or `dietpi-globals`. |
| **dietpi-config** | Whiptail menu for display/audio/performance/network/locale/security/autostart, plus `dietpi-config <n>` CLI shortcuts. | Interactive Bash only. | The **idea** yes and valuable on an 800×480 panel; the **contents** (GPU mem split, RPi camera, HiFiBerry audio, overclock profiles) are ARM-only. | **IDEA** — reimplement a small `eeepc-config` (governor, wifi, resolution, hostname/password, swap). |
| **DietPi-RAMlog** | `dietpi-ramlog.service` (oneshot, `RemainAfterExit=yes`); tmpfs mount in fstab `tmpfs /var/log tmpfs size=50M,noatime,lazytime,nodev,nosuid`; script stores/restores only the **empty** file skeleton with ownership/perms: `cp -af --attributes-only /var/log/. /var/lib/dietpi/logs/dietpi-ramlog_store/` on shutdown, `cp -an --attributes-only … /var/log/` on boot; hourly `/etc/cron.hourly/dietpi` → `dietpi-logclear` frees RAM (#1) or appends to disk (#2). | ~50 MiB tmpfs ceiling, ~KBs actually resident; eliminates continuous `/var/log` writes. Requires a small amount of RAM for the tmpfs. | **Very applicable** — this is the single biggest SD-wear win and matches our "no card wear" goal. | **IDEA** (reimplement) — but see §4: prefer `journald Storage=volatile` over mounting `/var/log` tmpfs, because the two conflict (DietPi issue #7750). |
| **dietpi-backup / Drive Manager** | `dietpi-backup` = rsync snapshot to a chosen target, include/exclude filter file, N-backup rotation, optional daily cron, restore-at-first-boot via `AUTO_SETUP_BACKUP_RESTORE`. `dietpi-drive_manager` = mount/format/resize/spin-down drives, move userdata & swap, set filesystems read-only, NFS/Samba mounts. | Interactive Bash; an rsync run is CPU/IO heavy on 900 MHz + slow SD (minutes). | Idea of "known-good snapshot" yes; the drive-management breadth (NTFS/exFAT/Btrfs/XFS formatting, NFS/Samba) is overkill for a single-partition netbook. | **IDEA (later priority)** — a minimal `eeepc-backup` (rsync to `/mnt`, one snapshot, no rotation UI). |
| **dietpi-services priority control** | Interactive service control *plus* per-service scheduling drop-ins: writes `/etc/systemd/system/<svc>.service.d/dietpi-process_tool.conf` with `[Service]` and any of `CPUAffinity=`, `CPUSchedulingPolicy=`, `Nice=`, `CPUSchedulingPriority=`, `IOSchedulingClass=`, `IOSchedulingPriority=`; presets ("Highest/High/Low/Lowest Priority"). | Pure systemd drop-ins; zero runtime cost until a service is actually scheduled. Fully supported by **systemd 252** (bookworm). | **Very applicable** — on a single 900 MHz core, de-prioritising background daemons (nice 19 / idle I/O class) measurably keeps the desktop responsive. | **IDEA** — hand-write 2–3 drop-ins (no tool). This is the highest-value/lowest-effort idea in the list. |
| **dietpi-update** | Git-based updater: fetches `raw.githubusercontent.com/MichaIng/DietPi/master/.update/version` (currently `G_REMOTE_VERSION_CORE=10 SUB=8 RC=0`, `G_MIN_DEBIAN=7`), applies `.update/pre-patches` and `.update/patches`, can run non-interactively (`dietpi-update 1`) or just report (`dietpi-update 2` → `/run/dietpi/.update_available`, shown in the banner). | Background network check at boot; negligible RAM. | The **git-patch mechanism** is DietPi-specific; the **idea** ("check updates in background, surface in banner") is portable. | **SKIP the code**, **IDEA the notification** — use Debian's own `apt`/`unattended-upgrades` for actual updates. |
| **dietpi-launcher** | Whiptail menu listing every `dietpi-*` tool; `dietpi-launcher` → run the chosen script. | One interactive Bash process. | Yes as a **pattern**; trivially reimplementable for our few tools. | **IDEA** — fold into `eeepc-menu`. |
| **First-boot automation** (`dietpi.txt`, `dietpi-firstboot.bash`) | Boot-time parse of `/boot/dietpi.txt`, apply hostname/locale/timezone/keyboard/APT mirror/password; regenerate machine-id and SSH host keys; apply SSH pubkeys & password-login policy; configure network; `AUTO_SETUP_AUTOMATED=1` for fully unattended. Log to `/var/tmp/dietpi/logs/dietpi-firstrun-setup.log`. | One oneshot Bash at first boot only. | **Highly applicable** and it directly addresses our weakness #3 (no first-boot config) and clone-safety. | **IDEA (high priority)** — reimplement `/boot/eeepc.txt` + `eeepc-firstboot.sh`. We already do machine-id/host-key regen; this adds the *config* half. |
| **Log-to-RAM** | See RAMlog row. DietPi's default (`AUTO_SETUP_LOGGING_INDEX=-1`) is "clear `/var/log` hourly, never touch disk"; `-2` appends to `/root/logfile_storage` hourly. | frees the continuous-write stream; costs a small tmpfs. | Yes. | **IDEA (high priority)** — prefer journald `Storage=volatile` (`/run/log/journal`), simpler and conflict-free. |
| **Minimal process count / RAM footprint** | Minimal base package set (`--variant=apt`, no recommends), no `rsyslog` unless requested, no `cron`-heavy daemons, tmpfs for `/tmp` and `/var/log`, `kernel.printk=4 4 1 7`. Result: 9 processes, 42 MiB on a Pi Zero. | 42 MiB vs 96 MiB Raspberry Pi OS Lite (44%). | **Applicable in spirit** — our console baseline (~155 MB) is already low; our **desktop** is the real cost. | **IDEA** — audit units and cut the desktop's heavyweight parts (see §3, P1-6: replace lightdm). |
| **Dropbear vs OpenSSH** | DietPi ships **Dropbear** by default (small, ~110–200 KB binary), selectable to OpenSSH via `dietpi-software`. `SOFTWARE_DISABLE_SSH_PASSWORD_LOGINS`, `AUTO_SETUP_SSH_PUBKEY`. Host keys regenerated on first boot via `dropbearkey`. | Dropbear RSS ≈ 0.5–1.2 MB vs OpenSSH `sshd` ≈ 1–5 MB (multiple measurements; Dropbear spawns 1 process per session, OpenSSH 2). Disk: Dropbear ≪ OpenSSH. | Marginal on 512 MB (≈0.2–0.8 % of RAM); meaningful on the 4 GB SSD. **Loses built-in SFTP/SCP** if OpenSSH is removed. | **IDEA (optional)** — keep **OpenSSH** as baseline (we document `scp`/`sftp` and it is battle-tested), offer Dropbear as an opt-in for the 512 MB/4 GB-disk case. Not worth a forced change. |
| **WiFi config tooling** | `dietpi-config`/`dietpi-network` scan+connect; `dietpi-set_hardware wifimodules enable` runs `rfkill unblock wifi` (**"Failsafe, unblock all WiFi adapters"**, DietPi issue #1627) and `modprobe`; `dietpi-set_hardware wificountrycode` sets `iw reg set`; `dietpi-wifi-monitor.sh` pings the gateway every 10 s and `ifdown`/`ifup` on loss. | `dietpi-wifi-monitor` = one tiny Bash loop + ping every 10 s (negligible, but a wakeup every 10 s costs battery). | **Directly applicable** — our weakness #1 (AR5007EG soft-blocked/ACPI-off at boot) is exactly the case DietPi's `rfkill unblock wifi` failsafe targets. | **IDEA (highest priority)** — add an `rfkill unblock wifi` boot unit and a NetworkManager-aware watchdog. |
| **Overclocking / profiles** | `dietpi-config` "Performance Options" set CPU governor, min/max freq, Intel pstate %, turbo, and per-board overclock profiles from `config.txt`. | Config-time only. | The **RPi profiles** (`arm_freq`, `over_voltage`, `config.txt`) are **ARM-only → SKIP**. The **cpufreq governor** part is portable and useful. | **IDEA (governor only)** — expose a governor choice; the Dothan has SpeedStep so `ondemand`/`powersave`/`performance` are meaningful. Ignore all `config.txt`/pstate logic. |
| **Whiptail menu UX** | Every tool is a whiptail dialog; `dietpi-globals` supplies `G_WHIP_MENU`/`G_WHIP_INPUTBOX`/`G_WHIP_YESNO`. Runs over the console/pty, no X needed. | `whiptail` is ~tens of KB + `libnewt`; one short-lived process per invocation. Already a DietPi base package. | **Very applicable** — perfect for an 800×480 text console, needs no X, and we want a config/software menu. | **IDEA (adopt `whiptail`)** — build `eeepc-config`/`eeepc-software`/`eeepc-menu` on `whiptail`; don't port `dietpi-globals`. |
| **Update mechanism** | See dietpi-update. Additionally `CONFIG_CHECK_APT_UPDATES=1/2` and a background check writing `/run/dietpi/.apt_updates` for the banner. | Background apt metadata fetch; write-heavy on SD unless `KeepCompressedAs xz`. | The apt-side ideas are portable; DietPi's git patcher is not. | **IDEA** — `unattended-upgrades` (security only) + `apt` `97dietpi`-style list compression + a login banner line. |

---

## 3. Prioritised implementation plan for the Eee PC 701 image

Ordering is deliberate: **P1 items are for the 512 MB machine and the SD card's health** and should
land first; P2 is first-boot/clone-safety UX; P3 is menus; P4 is maintenance. Each item names the
real file path, the real package, and (where useful) the command. Nothing here requires code copied
from DietPi.

### P1 — RAM and SD-card survival (do these first)

**P1-1. Move the journal to RAM (replace the 30 MiB on-disk cap).**
File: `/etc/systemd/journald.conf.d/50-eeepc.conf`

```ini
[Journal]
Storage=volatile          # log to /run/log/journal (tmpfs) — never touches the SD
RuntimeMaxUse=16M         # RAM ceiling for the journal
SystemMaxUse=0
ForwardToSyslog=no
```

Why `volatile` and not a `/var/log` tmpfs: on bookworm, if `/var/log/journal` exists *and*
`/var/log` is a tmpfs that gets cleared, journald's startup logs are wiped (DietPi issue #7750).
`Storage=volatile` keeps the journal in `/run/log/journal` while leaving `/var/log` on disk for
the few tools that need it — no conflict, and it removes the biggest continuous-write stream.
This supersedes our current `SystemMaxUse=30M` on-disk journal.

**P1-2. Boot-time Wi-Fi bring-up safety net (fixes weakness #1).**
Files: `/usr/local/sbin/eeepc-wifi-fix.sh`, `/etc/systemd/system/eeepc-wifi-fix.service`

```ini
# eeepc-wifi-fix.service
[Unit]
Description=Unblock and bring up AR5007EG before NetworkManager
Before=NetworkManager.service network-pre.target
Wants=network-pre.target
After=systemd-modules-load.service
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/eeepc-wifi-fix.sh
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
```

`eeepc-wifi-fix.sh` (own shell, ~10 lines): `rfkill unblock all`; `rfkill list` to log state;
`modprobe ath5k` (harmless if built-in); `iw reg set <CC>` if a country is configured;
`[ -e /sys/class/net/wlan0 ] || sleep 2`. This is DietPi's "Failsafe, unblock all WiFi adapters"
idea (`dietpi-set_hardware`, `rfkill unblock wifi`) applied to our specific failure mode.

**P1-3. Wi-Fi link watchdog.**
Files: `/usr/local/sbin/eeepc-wifi-monitor.sh`, `/etc/systemd/system/eeepc-wifi-monitor.service`.
Loop: every 10–15 s, if `nmcli -t -f GENERAL.STATE dev show wlan0` is not `connected` **and** the
gateway does not answer one ping, run `nmcli device disconnect wlan0 && nmcli device connect wlan0`.
Model it on `dietpi-wifi-monitor.sh` (which pings the default gateway and `ifdown`/`ifup`s), but
drive NetworkManager (our stack), not ifupdown. Add `ExecStartPost`/battery-friendly `TICKRATE`.

**P1-4. Re-tune zram for 512 MB.**
Our unit hard-codes `disksize=1073741824` (1 GB). On a 512 MB machine that overcommits ~3×. Make
the size dynamic in `/etc/systemd/system/zram-swap.service`: read `MemTotal` and use
`max(512MiB, MemTotal)` at ≤ 1 GB RAM, up to 2 GB at 2 GB. Consider replacing the hand-rolled unit
with the distro `zram-tools` package (present in bookworm) — it ships `zramswap.service` and
`/etc/default/zramswap` (`ALGO=lz4`, `PERCENT=50`), which is fewer lines for us to maintain.

**P1-5. De-prioritise background services (DietPi's services-priority idea).**
Files (drop-ins): `/etc/systemd/system/tlp.service.d/10-eeepc-prio.conf`,
`…/earlyoom.service.d/…`, `…/avahi-daemon.service.d/…`

```ini
[Service]
Nice=19
IOSchedulingClass=idle
```

All three keys are valid in systemd 252 (bookworm). On a single 900 MHz core this keeps interactive
work ahead of housekeeping. Do **not** ship the `dietpi-services` tool; hand-write the drop-ins.

**P1-6. Cut the desktop's RAM cost (the largest single consumer on 512 MB).**
Our measured ~250–350 MB at the desktop is dominated by `lightdm` + GTK greeter + `nm-applet` +
`volumeicon`. Recommended: replace `lightdm` autologin with a systemd oneshot that runs the session
directly (autologin on `tty1` → `xinit /usr/bin/openbox-session` via a `getty@tty1` override, or a
minimal `eeepc-desktop.service` `ExecStart=/usr/bin/startx`), dropping the greeter and its GTK
stack. Keep `tint2`, `pcmanfm`, `lxterminal`; consider dropping `volumeicon` (bind `amixer` to the
existing XF86 keys instead — already in `rc.xml`). Target: keep the 512 MB desktop usable, not
merely bootable.

**P1-7. APT "fewer writes" policy (DietPi's `97dietpi` idea).**
File: `/etc/apt/apt.conf.d/97eeepc` — set `Acquire::Languages "none";`,
`Acquire::GzipIndexes "true";`, `Acquire::IndexTargets::deb::Packages::KeepCompressedAs "xz";`,
`APT::Install-Recommends "false";` (we already do this), `Dir::Cache::srcpkgcache "";`.
Direct, measured effect: less download and fewer SD writes per `apt update`.

### P2 — first-boot automation and clone safety

**P2-1. `/boot/eeepc.txt` + `eeepc-firstboot.sh` + `eeepc-firstboot.service` (weakness #3).**
Mirror the DietPi model: a plain key=value file at `/boot/eeepc.txt` parsed with
`sed -n '/^[[:blank:]]*KEY=/{s/^[^=]*=//p;q}'`, applied **once** by a oneshot unit ordered
`After=local-fs.target` and `Before=NetworkManager.service getty-pre.target`. Keys:
`EEEPC_HOSTNAME=`, `EEEPC_USER=`, `EEEPC_USER_PASSWORD_HASH=`, `EEEPC_ROOT_PASSWORD_HASH=`,
`EEEPC_LOCALE=`, `EEEPC_TIMEZONE=`, `EEEPC_KEYBOARD=`, `EEEPC_WIFI_SSID=`, `EEEPC_WIFI_PSK=`,
`EEEPC_WIFI_CC=`, `EEEPC_GOVERNOR=`, `EEEPC_AUTOMATED=0|1`. It then deletes itself
(`systemctl disable eeepc-firstboot` + `mv /boot/eeepc.txt{,.applied}`).
Because our root is a single ext4 partition, note the UX difference vs DietPi: the SD must be
mounted on a Linux box to edit `/boot/eeepc.txt` (macOS cannot write ext4 reliably). If we want
Windows/macOS editing we need a small FAT partition — an explicit trade-off, not a default.

**P2-2. Consolidate clone-safety + growpart into first boot.**
We already regenerate machine-id and SSH host keys (`30-configure.sh`, `90-cleanup.sh`) and grow the
root (`expand-root.sh`). Fold them under the firstboot unit so the ordering is explicit
(growpart → host-key regen → machine-id → config), matching DietPi's `fs_partition_resize →
ramlog → preboot → firstboot → postboot` chain.

**P2-3. Ship the on-device diagnostics collector (weakness #2).**
File: `/usr/local/sbin/eeepc-diag.sh` — writes one text file
(`/root/eeepc-diag-$(date +%F-%H%M).txt`) with `uname -a`, `cat /proc/cpuinfo`, `free -m`,
`lsblk`, `lspci -nnk`, `lsusb`, `dmesg`, `journalctl -b`, `rfkill list`, `nmcli dev status`,
`iw dev wlan0 info`, `systemctl --failed`, `systemctl list-units --type=service --state=running`,
`cat /boot/config-* | grep -E 'CONFIG_(X86_PAE|HIGHMEM4G|ATH5K|DRM_I915)'`, and `ip a`. Run it
from the first-boot path *and* expose it as a menu entry. DietPi's analogue is `dietpi-bugreport`
(collect + optionally upload); ours must work **fully offline** and write to the SD so it can be
read on another machine.

### P3 — configuration and software menus (whiptail)

**P3-1. `eeepc-config`.** Install `whiptail` (DietPi ships it in the base package list). Menus:
Wi-Fi (`nmcli device wifi list` / connect), display (`xrandr` / `xorg.conf` for 800×480),
CPU governor (`cpufreq-set` or write `scaling_governor`), swap/zram size, hostname & password,
timezone/locale/keyboard, and "run diagnostics". This reimplements `dietpi-config`'s *shape*
without its ARM options; CLI shortcuts like `eeepc-config 4` (governor) are cheap to add.

**P3-2. `eeepc-software` (weakness #6).** A short curated list — e.g. `netsurf`, `firefox-esr`,
`mpv`, `sylpheed`, `abiword`, `gpicview`, `galculator`, `htop`, `tmux`, `rsync` — each backed by a
single `apt-get install` line, with a confirmation dialog and a log to `/var/log/eeepc-software.log`.

**P3-3. `eeepc-menu`.** A `dietpi-launcher`-style top menu launching the above plus
`eeepc-backup` and the update banner. Bind it to a key in `~/.config/openbox/rc.xml`.

### P4 — maintenance

**P4-1. `eeepc-backup`.** Minimal rsync snapshot: `rsync -aHAXx --delete --exclude=/mnt/*
--exclude=/proc/* --exclude=/sys/* --exclude=/tmp/* / /mnt/eeepc-backup/` to an SD/USB target, with
a `--dry-run` mode and a size check. One snapshot, no rotation UI (DietPi's rotation/filter file
is more than a netbook needs).

**P4-2. Unattended security updates.** `apt install unattended-upgrades`; restrict to
`${distro_id}:${distro_codename}-security`, and set `APT::Periodic::Download-Upgradeable-Packages "0"`,
`Unattended-Upgrade::AutoFixInterruptedDpkg "true"`. Add a one-line "N updates available" notice to
`/etc/motd` via a small `motd.d` script (the DietPi banner idea).

---

## 4. What NOT to copy (explicit warnings)

**ARM / Raspberry Pi assumptions — never port these:**

- `config.txt` semantics: `arm_freq`, `core_freq`, `sdram_freq`, `over_voltage`, `temp_limit`,
  `arm_64bit`, `dtoverlay=`, the whole `RPi_Set_Clock_Speeds()` block in
  `dietpi-firstboot.bash`. There is no `config.txt`, no VideoCore, no device tree overlay on a 701.
- `/boot/firmware`, `raspi-firmware`, `raspberrypi-sys-mods`, `raspberrypi-archive-keyring`,
  `armbian-firmware`, U-Boot (`boot.scr`, `dietpiEnv.txt`, `boot.ini`), `extlinux.conf`
  (VisionFive2/StarFive branches) — none apply; we use **GRUB i386-pc** with a static
  `/boot/grub/grub.cfg`.
- Device-node naming: DietPi's ARM images assume `/dev/mmcblk0pN`. **On the 701 the SD reader is
  USB mass storage → `/dev/sdXN`.** Our `expand-root.sh` already handles both; keep that, but never
  copy a script that hard-codes `mmcblk`.
- `armhf`/`arm64`/ARMv6 mirror logic, `raspbian-archive-keyring`, `uname`-spoofing for 32-bit
  ARM, `qemu-user-static` / `systemd-binfmt` emulation glue — all ARM-only.
- `dietpi-build`'s `HW_MODEL` table: it targets ARM boards plus `VM(20)`/`NativePC(21)`, and
  `NativePC` **forces x86_64** (`G_HW_ARCH=10`). There is **no i386 build target** in DietPi at
  all. DietPi cannot build our image; don't try to bend it.

**systemd / Debian-version assumptions:**

- DietPi `dev` targets Trixie (G_DISTRO 8) and Forky (9); bookworm is G_DISTRO 7. Bookworm ships
  **systemd 252** (`252.39-1~deb12u2`). Anything the code does because it assumes ≥ 253/254 must
  be dropped or worked around. Concretely: `lsblk --properties-by blkid` (DietPi notes it is
  "From Trixie on") is not available — use `blkid` as DietPi itself does for bookworm; avoid
  `systemd-creds`/credential features and the `ImportCredential=`/`LoadCredential=` workaround
  block (that whole block exists only to patch *newer* units on QEMU).
- Our own drop-ins (`Nice=`, `IOSchedulingClass=`, `CPUSchedulingPolicy=`, `CPUAffinity=`) **are**
  fine on 252 — don't confuse "don't copy newer-systemd code" with "don't use these keys".
- `fstab` `lazytime` (used throughout DietPi) needs kernel ≥ 4.0 — fine for us, but we currently
  use `noatime,commit=60`; pick one strategy, don't stack contradictory options.

**RAM / disk-size assumptions:**

- DietPi's headline "42 MiB" is a *console* system and includes sourcing the large
  `dietpi-globals` at login. Do not assume 512 MB is comfortable for a **desktop**; our own ~250–350 MB
  desktop figure proves it isn't. Cutting the desktop (P1-6) matters more than copying any DietPi
  script.
- **Do not copy `vm.swappiness=1`.** DietPi sets it because it ships a *disk* swapfile
  (`AUTO_SETUP_SWAPFILE_SIZE=1`, `/var/swap`). We deliberately run **zram** with
  `vm.swappiness=150` so the kernel prefers fast RAM swap. Copying `swappiness=1` would defeat our
  design. (The `kernel.printk = 4 4 1 7` line *is* worth copying.)
- **Do not copy the RAMlog + journald combination as-is.** Mounting `/var/log` on a 50 MiB tmpfs
  while journald persists to `/var/log/journal` produces exactly the failure in DietPi issue #7750
  (logs cleared hourly, fail2ban broken). Use `Storage=volatile` instead (P1-1). If you do mount
  `/var/log` tmpfs, you must also force journald off `/var/log/journal`.
- Image size: DietPi images are ~1024 MiB. Our image is **7 GiB** to fill SD cards via growpart —
  that will **not** fit the 701's **4 GB internal SSD**. If the internal SSD is ever a target,
  build a smaller variant (e.g. 3.5 GiB, `EEEPC_IMAGE_SIZE=3600M`) rather than reusing the SD image.

**Network-at-build-time assumptions:**

- DietPi's builder and `dietpi-installer` **curl their own code from GitHub and debootstrap from
  live mirrors** on every run (`raw.githubusercontent.com/…/dietpi-globals`,
  `…/.build/images/dietpi-installer`). There is no offline build path to copy from. Our
  `ci/build.sh` likewise assumes network (kernel.org tarball, Debian mirrors, keyring fetch) — keep
  that, but do not add *first-boot* steps that require the network to reach a usable state. The
  image must boot to a working console/desktop **offline**; network is an enhancement, not a
  prerequisite (this is also why the AR5007EG soft-block must not be able to brick first boot).

**Licensing / scope:**

- Lifting `dietpi-globals`, `dietpi-software`, `dietpi-update`, `dietpi-drive_manager`,
  `dietpi-backup` or `dietpi-config` wholesale is a **GPLv2 derivative work**: you must ship
  sources, retain notices, and license the copies GPLv2. These files are also ARM/SBC-shaped and
  depend on the framework. Reimplement the *behaviour* in our own ~dozens-of-lines scripts
  (no licence obligations for ideas) and keep `deeebian`'s licence story clean.
- Do not port `dietpi-software`'s integer-ID catalogue or its vendor/ARM package names; our package
  set is plain Debian i386 bookworm.

---

## Sources

- DietPi repository (branch `dev`): <https://github.com/MichaIng/DietPi> — `LICENSE`,
  `dietpi.txt`, `dietpi/dietpi-services`, `dietpi/dietpi-update`, `dietpi/dietpi-launcher`,
  `dietpi/dietpi-software`, `dietpi/preboot`, `dietpi/postboot`,
  `dietpi/func/dietpi-ramlog`, `dietpi/func/dietpi-logclear`, `dietpi/func/dietpi-set_cpu`,
  `dietpi/func/dietpi-set_hardware`, `dietpi/func/dietpi-set_swapfile`,
  `rootfs/etc/systemd/system/*.service`, `rootfs/etc/cron.hourly/dietpi`,
  `rootfs/etc/apt/apt.conf.d/97dietpi`, `rootfs/etc/sysctl.d/97-dietpi.conf`,
  `rootfs/etc/tmpfiles.d/dietpi.conf`, `rootfs/etc/bashrc.d/dietpi.bash`,
  `rootfs/var/lib/dietpi/services/{fs_partition_resize.sh,dietpi-firstboot.bash,dietpi-wifi-monitor.sh}`,
  `.build/images/dietpi-build`, `.build/images/dietpi-installer`, `.update/version`.
  Raw files: `https://raw.githubusercontent.com/MichaIng/DietPi/dev/<path>`.
- DietPi docs: Overview <https://dietpi.com/docs/>; Install <https://dietpi.com/docs/install/>;
  Usage/automation <https://dietpi.com/docs/usage/>; DietPi Tools
  <https://dietpi.com/docs/dietpi_tools/>; Software Installation
  <https://dietpi.com/docs/dietpi_tools/software_installation/>; System Configuration
  <https://dietpi.com/docs/dietpi_tools/system_configuration/>; System Maintenance
  <https://dietpi.com/docs/dietpi_tools/system_maintenance/>; Misc Tools
  <https://dietpi.com/docs/dietpi_tools/misc_tools/>; Log System
  <https://dietpi.com/docs/software/log_system/>; SSH
  <https://dietpi.com/docs/software/ssh/>.
- DietPi OS stats & comparison (42 MiB / 9 processes / 702 MiB on RPi Zero W):
  <https://dietpi.com/stats.html> and blog <https://dietpi.com/blog/?p=888>.
- DietPi booting process wiki: <https://github-wiki-see.page/m/MichaIng/DietPi/wiki/Booting-process>.
- DietPi issue #7750 (RAMlog vs journald `/var/log/journal` conflict):
  <https://github.com/MichaIng/DietPi/issues/7750>.
- DietPi issue #1627 (rfkill unblock wifi failsafe): referenced in `dietpi/func/dietpi-set_hardware`.
- Dropbear vs OpenSSH memory: <https://lowendbox.com/blog/replacing-openssh-with-dropbear/>,
  <https://www.ezeelogin.com/blog/dropbear-a-lightweight-ssh-solution/>.
- Debian bookworm systemd version (`252.39-1~deb12u2`): <https://packages.debian.org/bookworm/systemd>.
- `deeebian` local files inspected: `README.md`, `scripts/{10-packages,20-kernel,30-configure,40-image,90-cleanup}.sh`,
  `ci/build.sh`, `dist/eeepc701-linux.img.xz` (7 GiB image), git remote `GodSpoon/deeebian` @ `main`.
