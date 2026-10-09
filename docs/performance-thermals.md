# deeebian — performance, thermals and fan behaviour

**Target:** ASUS Eee PC 701 4G — Celeron M ULV 353 @ 900 MHz (single core), Intel 915GM,
2 GB RAM, vanilla 6.12.112 LTS i386 non-PAE, boots from SD.
**Author:** Hermes (perf/thermals workstream), 2026-10-09.
**Scope of changes:** `scripts/10-packages.sh`, `scripts/20-kernel.sh`, `scripts/30-configure.sh`.
No new services are *enabled* except two tiny oneshot tuners; nothing was added that increases
SD writes or heat without saying so below.

> **Read §1 first.** It records what the hardware and the kernel driver actually expose, verified
> against the 6.12 driver source, because the single most important result of this work is a set
> of *negative* findings: several "obvious" optimisations for this machine do not exist.

---

## 1. Verified hardware / driver facts (the honest interface)

These were checked against the actual Linux 6.12 source, not assumed. They change what is worth
doing, so they are stated before the changes that depend on them.

### 1.1 The fan **is** software-visible, but the EC owns it

`drivers/platform/x86/eeepc-laptop.c` registers an hwmon device named **`eeepc`** with exactly
three attributes:

| sysfs | meaning | access |
|---|---|---|
| `fan1_input` | fan tachometer, RPM | read-only |
| `pwm1` | fan duty, 0–255 (100 % EC units scaled to 255) | read/write |
| `pwm1_enable` | `1` = manual PWM, `2` = EC automatic | read/write |

The driver reaches the fan by poking **EC registers 0x63 (FAN_PWM) and 0xD3 (FAN_CTRL, bit 0x02)**.
So there *is* a software fan knob. On the 701 the Embedded Controller's own automatic curve is
the design; forcing `pwm1_enable=1` and driving `pwm1` by hand can make the fan run flat-out
(hotter airflow helps, but noise/power/dust rise) or stall (dangerous). **This image therefore
only *reads* the fan; it never writes `pwm1`/`pwm1_enable`.** `eeepc-thermals` reports the state and
tells you which mode the fan is in.

### 1.2 `cpufv` exists but is **disabled and unsafe** on a 701

The platform device `/sys/devices/platform/eeepc/` carries `cpufv`, `available_cpufv` and
`cpufv_disabled`. The driver's DMI check does:

```c
if (strcmp(model, "701") == 0 || strcmp(model, "702") == 0) {
        eeepc->cpufv_disabled = true;
        pr_info("model %s does not officially support setting cpu speed\n", model);
        pr_info("cpufv disabled to avoid instability\n");
}
```

Writes to `cpufv` return `-EPERM`. The comment in the driver says Asus removed the feature and
that **using it can hang this model**. We do not touch it. (`cpufv` is a FSB/multiplier control,
not a cpufreq governor, and it is exactly the sort of "free performance" knob that would brick a
bring-up box.)

### 1.3 **cpufreq does not work on this CPU — the premise in the task is wrong for the 701**

The task asked to "consider a CPU governor choice… the Celeron M ULV has no Enhanced SpeedStep
on *some* steppings — verify rather than assume." **Verified: the 701's Celeron M ULV 353 has no
Enhanced SpeedStep at all.**

- FreeBSD's Eee PC page states plainly: *"the Eee PC 701 CPU has no Enhanced Speedstep support"*,
  and its recommended control is `acpi_throttle()` (a duty-cycle throttle), not P-states.
- The CPU is a Dothan-core (family 6, model 0x0D) Celeron M. Intel's own product briefs market the
  *Pentium M* (Dothan) with EIST; the **Celeron M ULV 353 is the EIST-disabled bin**. The 900 MHz
  → "630 MHz normal run" figure in the ASUS service manual is clock modulation (throttling), not
  a selectable P-state.
- Consequence in Linux: `acpi-cpufreq` probes, finds **no `_PSS` objects**, and registers **no
  cpufreq policy**. There is no `/sys/devices/system/cpu/cpu0/cpufreq/`, nothing for a governor to
  set, and `cpufreq-info` reports "no or unknown cpufreq driver is active on this CPU" (this
  exact symptom is reported by other Eee 701 owners on Arch and Debian forums).

**Therefore:** we install **no** governor unit and force **no** `performance`. We install
`cpufrequtils` only so the state can be *reported* (`eeepc-thermals`) and so an operator can try
it by hand on the off-chance a later stepping exposes it. `eeepc-bench` records whether a policy
exists at all, so the claim is measured on real hardware rather than trusted.

> If a future unit *does* expose cpufreq, the right default for this workload is **`conservative`**
> (ramps gently, good for battery) or **`ondemand`** with a long `sampling_down_factor`, *not*
> `performance` (which pegs 900 MHz and runs hotter for no interactive benefit on a passively
> cooled box). But that branch is almost certainly dead on a 701.

### 1.4 There is no CPU temperature sensor either

The 701's Dothan Celeron M has **no digital thermal sensor (DTS)**. `coretemp.c` in 6.12 matches
only `X86_MATCH_VENDOR_FEATURE(INTEL, X86_FEATURE_DTHERM, NULL)`; Dothan lacks `DTHERM`, so
`coretemp` does **not** load and there is no `temp1_input` from it. The only temperature that can
exist is the **ACPI thermal zone** `/sys/class/thermal/thermal_zone*/` (driver `acpitz`), and
whether the 701 BIOS exposes one must be confirmed on metal. `eeepc-thermals` prints whatever
exists and says plainly when nothing does.

**Kernel-config consequence (fixed):** the build forces and asserts `HWMON`, `THERMAL` and
`ACPI_THERMAL =y`. In the pinned 6.12.112 tree these are already `=y` (verified empirically — see
§3.5), pulled in by `default y`/`select THERMAL`; naming them in `WANT` makes the dependency
explicit and the new asserts stop a future defconfig change from silently removing the ACPI
thermal zone or the fan hwmon that the whole thermal story rests on.

### 1.5 `thermal_zone` mode/policy is worth watching, not driving

If the BIOS exposes an `acpitz` zone, the kernel's `step_wise` governor will try to throttle on
the passive trip point — which on a CPU with no cpufreq has no cooling device to act on. So the
zone is a *thermometer*, not a control loop, here. We report `mode`/`policy`/trip points but do
not set them.

---

## 2. What changed, and why (mechanism → expected effect → risk)

### 2.1 Thermals & fan

| Change | Mechanism | Expected effect on a 701 | Risk / caveat |
|---|---|---|---|
| `/usr/local/bin/eeepc-thermals` | Reads `/sys/class/thermal/*`, hwmon temp sensors, the `eeepc` fan hwmon, `/sys/.../cpufreq` (or its absence), `platform_profile`, battery, zram ratio; `--watch N` live view | One command shows temps, fan RPM/PWM/mode, CPU freq state and governor | None; read-only. On a 701 the temp and cpufreq sections will (correctly) say "none/absent" unless the BIOS exposes an `acpitz` zone |
| `eeepc-acpi-profile.service` → `/usr/local/sbin/eeepc-acpi-profile.sh` | Writes the **lowest-power** value to `/sys/firmware/acpi/platform_profile` *if* the firmware exposes that attribute (`ACPI_PLATFORM_PROFILE` is in this kernel) | If the 701 BIOS exposes it, tells the firmware to prefer efficient cooling — the only firmware cooling knob the ACPI path offers | Guarded, silent, idempotent. If the attribute exists but rejects the value, nothing happens. **Not verifiable without hardware** |
| Fan policy | **Read-only by design.** We document that `pwm1`/`pwm1_enable` exist but leave the EC in charge | Avoids the flat-out/noisy and stall failure modes; a passively cooled 2007 netbook's EC curve is already tuned for its own thermal envelope | Someone who *wants* manual PWM can still do it by hand; we do not automate it |
| `cpufrequtils` package | Enables `cpufreq-info` for reporting | Honest reporting of the (absent) cpufreq state | Adds `cpufrequtils` (008-2, i386 ✔) and its small deps; negligible size |

### 2.2 Performance & responsiveness

The user's real complaint was *"barely anything is going on with the desktop"* — i.e. latency, not
throughput. Every change below targets latency, SD I/O, or wakeups.

| Change | Mechanism | Expected effect | Heat / writes / boot impact |
|---|---|---|---|
| **SD I/O scheduler → `none`, `read_ahead_kb=256`, `nr_requests=64`, `rotational=0`** (`eeepc-io-tune.service`) | On a card with no seek cost, `mq-deadline`'s reordering is pure overhead on a single core; a shallower queue lowers tail latency behind a slow card; modest read-ahead amortises per-request reader latency on sequential reads (opening apps) without inflating random latency. `rotational=0` stops some USB readers' misreported seek assumptions | Snappier app launches and file opens; more predictable interactive I/O | **No extra heat, no extra writes.** Runs once at boot (oneshot), idle-priority, guarded per attribute |
| **`vm.dirty_ratio=10`, `dirty_background_ratio=5`, `dirty_expire_centisecs=1500`, `dirty_writeback_centisecs=1500`** | Flush dirty pages in smaller, earlier batches instead of one large delayed burst | Less long SD stalls (the classic "machine freezes for a second" on a slow card); less write amplification | **Marginally more frequent small writes**, but the same bytes; explicitly chosen because a smaller earlier flush is kinder to a slow card than a large one. Stated because it does touch writeback |
| **Keep `vm.swappiness=150`** | Since Linux 3.x, >100 biases the kernel toward swapping *anonymous* pages instead of evicting page cache. With lz4 zram (~3–4:1), swapping anon costs microseconds of CPU; re-reading an evicted page costs milliseconds from the SD | More RAM available to the desktop; fewer SD re-reads | **CPU, not heat-critical.** Justified in §2.3 below; deliberately *not* "fixed" to 10 |
| **`earlyoom -m 8 -s 5` + `--avoid` the session + `--prefer` browsers** (`/etc/default/earlyoom`) | Acts at 8 % available RAM / 5 % free swap (stock is 10 %); protects `systemd/dbus-daemon/X/Xorg/lightdm/openbox/pcmanfm/tint2/sshd`; prefers `firefox/netsurf` | On a 2 GB box running Firefox, frees memory *before* the desktop thrashes instead of after; the session daemon can no longer be the victim | No heat/write cost. `-r 3600` keeps its log to one line/hour (in-RAM journal) |
| **`net.ipv4.tcp_fin_timeout=30`, `tcp_keepalive_time=120`** | Shorter TCP teardown/keepalive | A dead/roaming wifi network is noticed in seconds, not minutes; frees sockets sooner | None |
| **No new preload/readahead daemon** | See §2.4 | — | Deliberately rejected |

### 2.3 Why `vm.swappiness=150` stays (the "justify keeping or changing it" ask)

Generic netbook advice says set swappiness low (10) to avoid swap thrash. **That advice is for
disk swap and does not apply here**, for two reasons:

1. **The swap is zram, not the SD.** Swapping a page to zram costs lz4 compression of ~4 KiB
   (microseconds). Reclaiming a clean page-cache page costs a **re-read from a slow SD card**
   (milliseconds, and it wears the card). The relative cost of "swap out anon" vs "drop cache" is
   inverted from a disk-swap system.
2. **swappiness > 100 is the documented mechanism to bias anon swap over cache reclaim.** A value
   of 10 would tell the kernel to *keep* anon resident and *evict page cache instead* — the exact
   opposite of what we want, and the exact thing that makes a slow-SD machine stutter.

So 150 is kept, and the reasoning is now written into `/etc/sysctl.d/50-eeepc.conf` so no future
maintainer "fixes" it. `eeepc-bench` records the real zram compression ratio so the policy can be
judged on numbers, not folklore.

### 2.4 Things I deliberately **rejected** (cargo cult for this machine)

- **`preload` / readahead daemons.** These help when RAM ≫ working set. On a 2 GB machine whose
  bottleneck is a ~5–20 MB/s SD card, a background preloader competes for both RAM *and* the SD
  it is trying to preload from — it would make things worse and add wakeups. Rejected.
- **Forcing `performance` governor.** There is no cpufreq; and even if there were, pinning 900 MHz
  on a passively cooled box is a heat regression. Rejected.
- **`vm.vfs_cache_pressure` tweaks / `vm.drop_caches` in a cron.** Dropping caches periodically
  forces exactly the SD re-reads we are trying to avoid. We pin `vfs_cache_pressure=100` (the
  sane default) so a base change cannot silently make it drop-happy, and do nothing else.
- **`rq_affinity=0`** — dropped from the I/O tuner: it only chooses which CPU handles a completion
  IRQ and is a no-op on a uniprocessor. Not worth the line.
- **A zram `writeback` device.** Writing compressed pages back to the SD would add card wear and
  latency for no benefit on a 2 GB machine whose anon working set fits in compressed RAM. Rejected.
- **LightDM replacement / greeter removal.** Tempting (see §4, P1) but it is a *user-visible*
  change to a working desktop and needs on-metal `systemd-analyze` numbers first; deferred rather
  than guessed. No change was made.
- **`transparent_hugepage`, `mitigations=off`, etc.** The task is about responsiveness, not
  benchmark numbers, and disabling mitigations to win a number is not something to ship silently.
  Not done.

---

## 3. Benchmarking — `/usr/local/bin/eeepc-bench`

### 3.1 How to run a before/after comparison

```sh
# ON THE CURRENT IMAGE, before flashing the new one:
sudo eeepc-bench --label "before"          # full run (writes 32 MiB to SD once)
#   or, to avoid any card wear on a casual run:
sudo eeepc-bench --quick --label "before"

# ... flash / install the new image, boot it, settle for ~2 minutes ...

sudo eeepc-bench --label "after"
```

Each run writes **`/var/log/eeepc-bench-<YYYYmmdd-HHMMSS>.txt`** *and* prints the same text, so it
works over SSH, from a serial console, or from a terminal opened on the desktop.

Compare the two text files with your eyes, or structurally:

```sh
diff <(grep -E 'ms|MB/s|IOPS|ratio' /var/log/eeepc-bench-BEFORE.txt) \
     <(grep -E 'ms|MB/s|IOPS|ratio' /var/log/eeepc-bench-AFTER.txt)
```

**Important:** the X11 and boot numbers are only meaningful **from the running graphical session**
(`DISPLAY` reachable), and boot numbers must be a *cold* boot on the real card. A run over SSH with
no X server still records everything else and clearly says the desktop part was skipped.

### 3.2 What it measures, and why those proxies

| Section | Metrics | Why this proxy |
|---|---|---|
| `## BOOT` | `systemd-analyze` total + `blame` top 12 | Boot time is a first-order "feels fast" metric and the place the greeter/desktop cost shows up |
| `## CPU` | gzip of a fixed 8 MiB buffer (MB/s), `sha256sum` of it (MB/s), an `awk` integer loop (Miter/s) | Package-free compression + hashing + integer throughput: lets you tell whether a change helped or hurt the CPU instead of guessing. The buffer is on **tmpfs**, so no SD writes |
| `## MEMORY` | `/proc/meminfo` fields, `/proc/swaps`, zram `orig`/`compr` + ratio | Judges the zram/swappiness policy on real compression numbers |
| `## DISK` | root device + mount options + scheduler + read-ahead; `hdparm -t` (if present); `dd bs=1M` sequential write (32 MiB) and read; a 64 × 4 KiB `O_DIRECT` random-read loop | The SD is the bottleneck; sequential and random are both needed, and random is what interactive stutter actually feels like |
| `## X11 / DESKTOP` | 50 × `xwininfo -root` round-trips (ms/request), X client count, wall-clock `lxterminal` open, `xmessage` map | The X round-trip is the pure input-latency proxy; the terminal-open time is what the user waits for on Ctrl+Alt+T. No FPS/`x11perf` dependency |
| `## GOVERNOR / THERMAL` | cpufreq presence, thermal zones, fan state | Records the facts of §1 so the CPU/thermal numbers are interpreted correctly |

### 3.3 Graceful degradation (no iozone/hdparm required)

- `hdparm` is used for sequential read **when present**; otherwise `dd` is used. (`hdparm` is now
  in the image anyway, 9.65, i386 ✔.) `iozone` is **not** used at all.
- Random read is pure `dd iflag=direct` — no package needed.
- Memory is read from `/proc/meminfo`, **not** from `free` (procps is not guaranteed present).
- X tests use `x11-utils` binaries (`xwininfo`/`xlsclients`/`xmessage`), which are **already in the
  image** (verified: all three ship in `x11-utils`). If `lxterminal` is missing, that one line is
  skipped; if there is no X server, the whole section says so and continues.
- The `systemd-analyze` section degrades to "(not available)" if systemd-analyze is absent.

### 3.4 SD wear disclosure

The **only** SD-wear step is the 32 MiB sequential write test (written once, then read, then
deleted). It is skipped by `--quick`, and the menu entry `Benchmark (quick)` uses `--quick` by
default precisely so a casual click does not wear the card. Everything else is read-only or CPU.
**Do not run `eeepc-bench` in a loop.**

### 3.5 Offline verification performed (see §5 for what is *not* verified)

- `bash -n` clean on all touched repo scripts; `bash -n` + `shellcheck -S warning` clean on every
  embedded script, extracted from the heredocs and checked individually.
- All package names cross-checked against `packages.debian.org/bookworm` **and** an actual
  `bookworm`/`i386` apt index: `cpufrequtils 008-2`, `hdparm 9.65+ds-1`, plus the already-present
  `x11-utils`. `earlyoom 1.7-1` and `tlp 1.5.0-2` confirmed.
- The **kernel config converge loop and all asserts were run against a real `linux-6.12.112`
  tree** in a Debian bookworm container (tarball sha256 matched the pinned value). Result:
  converge at pass 4, **all asserts PASS**, with `CONFIG_HWMON=y`, `CONFIG_THERMAL=y`,
  `CONFIG_ACPI_THERMAL=y`, `CONFIG_HZ=250`, `CONFIG_MPENTIUMM=y` etc. This is the strongest
  offline evidence available for the kernel change.
- `eeepc-thermals` was run against a synthetic 701-like sysfs tree and parses every field
  correctly (temperatures, trips, fan RPM/PWM/mode, cpufreq-absent branch, zram ratio, battery,
  `cpufv_disabled`). `eeepc-bench` was executed end-to-end on the build host (which has no `/sys`
  or `/proc/cpuinfo`), exercising every graceful-degradation path.

---

## 4. Prioritised further optimisations (with tradeoffs)

**P0 — do these on the first hardware boot (measurement, not change):**
1. Run `eeepc-thermals` and `sudo eeepc-bench --label before` on the *current* image, then again
   on the new one, and compare. Until this exists, every claim below is unverified.
2. Confirm what the 701 BIOS actually exposes: does `/sys/class/thermal/thermal_zone*` exist? Does
   the `eeepc` hwmon fan node report a real RPM? Does `/sys/firmware/acpi/platform_profile` exist?
   The answers decide whether the thermal half of this work has anything to act on.

**P1 — desktop/boot cost (likely the biggest "feels slow" win, but user-visible, so gated on P0):**
3. **LightDM → direct Openbox autologin.** LightDM + lightdm-gtk-greeter pull a Python GTK greeter
   and a session manager into RAM before the session starts. A `getty@tty1` autologin + `startx`
   (or a `systemd` user unit) would drop boot time and tens of MB of RAM. *Tradeoff:* loses the
   greeter's session/locale niceties and needs care to keep the console/keybind path intact. Do it
   only after `systemd-analyze blame` shows the greeter is a real cost.
4. **Audit remaining services.** `avahi-daemon` (mDNS) and `NetworkManager` are both on the boot
   path; avahi is only useful if `.local` resolution is actually wanted. Disabling avahi saves a
   daemon and some wakeups. *Tradeoff:* `eeepc701.local` stops resolving; `ssh sam@<ip>` still
   works. Low risk, but a behaviour change — decide from the bench's boot section.
5. **`tlp` interaction with no cpufreq.** With no P-states, much of TLP's CPU scheduling is moot;
   its disk/PCI/wifi power tuning still matters. Re-check after P0 that TLP is not fighting our
   `swappiness`/dirty settings or the SD scheduler.

**P2 — storage:**
6. **`ext4` mount `noatime,commit=60` (already shipped).** Consider `nodiratime` (tiny) and
   confirming `discard` is *off* (some cards garbage-collect better without it, and it adds write
   work). *Tradeoff:* leaving `discard` off relies on the card's own GC. Measure first.
7. **`/var/log` and `~/.cache` on tmpfs.** journald is already volatile; moving browser/profile
   caches to tmpfs removes steady background writes. *Tradeoff:* caches are lost on reboot (fine)
   and consume RAM (on 2 GB, mind Firefox). Optional, data-driven.

**P3 — only if P0 shows headroom:**
8. **Compile the kernel with `CONFIG_PREEMPT` instead of `PREEMPT_VOLUNTARY`** for lower single-core
   interactive latency. *Tradeoff:* slightly less throughput, larger kernel. Marginal on a single
   core; do not do it blind.
9. **`zram` algorithm `lz4` → `lzo-rle`** if the bench shows a poor compression ratio with lz4 (a
   bigger win on some data at a small CPU cost). Decide from `mm_stat`.

**Explicitly not recommended:** preload-style readahead daemons, periodic `drop_caches`, a zram
writeback device, forcing manual fan PWM, and setting `cpufv`. Each is either cargo cult on this
hardware or actively risky (see §§1 and 2.4).

---

## 5. What is **not** verified — needs real hardware

Stated plainly so no one mistakes source correctness for a hardware result:

1. **No temperatures and no FPS were measured.** There is no 701 in this workstream. Every
   "expected effect" above is a mechanism argument, not a measurement.
2. **Whether the 701 BIOS exposes an ACPI thermal zone at all** is unknown. If it does not,
   `eeepc-thermals` will correctly report no temperature, and the thermal half of this work has no
   sensor to read (there is no DTS on Dothan — §1.4).
3. **Whether the `eeepc` hwmon fan node reports a real RPM** on this unit (some 701s have a fan
   tachometer, some readings are stale/rubbish) is unknown.
4. **Whether `/sys/firmware/acpi/platform_profile` exists and accepts `low-power`** on the 701 is
   unknown; the service is written to no-op safely if not.
5. **The cpufreq-absent finding (§1.3)** is derived from CPUID/architecture and public reports.
   `eeepc-bench` will record definitively on metal whether any cpufreq policy appears. If one
   *does*, this workstream's "no governor" decision should be revisited (use `conservative`).
6. **Actual SD throughput and the effect of the I/O tuner** are unmeasured. The tuner's writes are
   guarded against missing sysfs names, but whether the card/reader honours `scheduler`/`rotational`
   on this kernel is for the bench to show.
7. **The boot-time and X-latency deltas from these changes** are unmeasured; some changes (I/O
   tuner, sysctls) may be neutral on a given card. That is why the bench exists.

---

## 6. Findings that contradict assumptions in the brief

- **"The image has `CONFIG_THERMAL` and `CONFIG_X86_ACPI_CPUFREQ`"** — true, but *`CONFIG_X86_ACPI_CPUFREQ` is useless here*: the driver is present, the CPU has no P-states, so no policy is
  ever registered. Presence of the driver ≠ availability of cpufreq. (Verified empirically: the
  symbol is `=y` in the config we generated, and the Celeron M still has no EST.)
- **"the eeepc-laptop module (fan …)"** — the module exposes the fan via **hwmon**, not under
  `/sys/devices/platform/eeepc/`; the platform dir has `cpufv`/`camera`/`cardr`/`disp` and friends.
  Scripting that looks for a fan node under `/sys/devices/platform/eeepc/` would find nothing.
  (§1.1)
- **"consider a CPU governor choice"** — there is **no governor to choose** on a 701; the premise
  assumes cpufreq exists. The honest action is to document the absence and not ship a placebo.
  (§1.3)
- **"`vm.swappiness` is currently 150 for zram — justify keeping or changing it"** — kept, and the
  generic advice to lower it is wrong here for the reason in §2.3.
- **A web source suggested `HWMON`/`THERMAL` are unset in `i386_defconfig`** — **false for the
  pinned 6.12.112 tree**; they resolve to `=y`. Corrected before it became a wrong comment in the
  kernel script (§1.4, §3.5).

---

## 7. Files

New standalone tools (copied into the chroot by `ci/build.sh`, installed by `30-configure.sh`
from `/opt/build` — same pattern as the existing `deeebian-report.sh` / `wallpaper.py`):

- `scripts/eeepc-thermals.sh` → `/usr/local/bin/eeepc-thermals` (+ `-tui` wrapper in-script)
- `scripts/eeepc-bench.sh` → `/usr/local/bin/eeepc-bench` (+ `-tui` wrapper in-script)
- `scripts/eeepc-io-tune.sh` → `/usr/local/sbin/eeepc-io-tune.sh`
- `scripts/eeepc-acpi-profile.sh` → `/usr/local/sbin/eeepc-acpi-profile.sh`

Modified:

- `ci/build.sh` — copy the four new tools into `/opt/build`.
- `scripts/10-packages.sh` — add `cpufrequtils hdparm`.
- `scripts/20-kernel.sh` — name `HWMON THERMAL ACPI_THERMAL` in `WANT`, assert all three.
- `scripts/30-configure.sh` — sysctl tuning + rationale; install + enable the `platform_profile`
  and SD I/O tuner services; `earlyoom` tuning; install the new tools (+ their TUI wrappers);
  Openbox menu items and `C-A-e` / `C-A-b` keybinds; MOTD entries.
- `docs/performance-thermals.md` — this document.

