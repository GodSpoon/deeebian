# Deeebian — storage resilience and the internal SSD

**Scope:** the ASUS Eee PC 701 4G — 4 GB internal SSD (`/dev/sda`, 2007-era flash) and the
removable SD card the OS currently runs from. This document is a **plan**, not an executed
change. Nothing that writes to `/dev/sda` may run until the conditions in §10 are met.
**Status of the device as verified:** the machine boots entirely from the SD card
(`/dev/sdb1`, mounted `/`). The internal SSD is untouched ASUS Xandros factory layout —
`sda1` 2.3 G, `sda2` 1.4 G, `sda3` 7.8 M, `sda4` 7.8 M.

---

## 1. The problem in one paragraph

Right now the 701 is one of the least reliable computers it could be: the entire operating
system lives on a **removable** card, and the **fixed** disk sits unused. Pull the card and the
machine does not boot and has no recovery path; corrupt the card and the same. Meanwhile a
2007-era flash device — the single component most likely to fail, and the one you cannot buy a
replacement for — is idle. The goal is not "put the OS on the SSD"; it is **to always have a
known-good way back**, so that whichever way the OS is arranged, a failure of the SD card, the
SSD, or a bad write is a 20-minute recovery instead of a dead machine. The backup comes first.

## 2. Current boot path (from the repo), and why it matters

`scripts/40-image.sh` builds a **7 GiB MBR image**: one `ext4` partition, GRUB `i386-pc` in the
MBR, and a **static** `/boot/grub/grub.cfg`. Every GRUB entry locates the root by **UUID**:

```
search --no-floppy --fs-uuid --set=root b0057a11-de12-b007-01ee-000000000001
linux /boot/vmlinuz-<krel> root=UUID=b0057a11-… ro quiet rootwait
```

`scripts/30-configure.sh` writes `/etc/fstab` with the same UUID and installs
`expand-root.service`, a first-boot oneshot that runs `growpart` + `resize2fs` on whatever
partition `findmnt /` reports, then touches `/var/lib/eeepc-expanded`.

Three consequences drive the whole design:

1. **UUID-based root is portable but not self-locating.** Two copies of the image (the SD and
   the SSD) would carry the **same** filesystem UUID. That is a feature *and* a hazard — see §7.
2. **`expand-root` grows and writes the root partition and filesystem on first boot.** If the
   internal SSD is ever the root, first boot **writes** to it (a destructive resize). If the SD
   root is re-used, it re-grows only if `/var/lib/eeepc-expanded` is missing (it is removed by
   `90-cleanup.sh` before imaging, so a *fresh* image always grows; an already-booted system does
   not).
3. **Kernel + initramfs live in the root partition** (`/boot` is not separate). So "root" and
   "boot" are the same filesystem on the same device. That shapes option (b) below.

## 3. What the four existing Xandros partitions are

The factory 701 shipped **Xandros Linux** on the internal SSD with a rescue/restore scheme:
`sda1` the main system, `sda2` a second system, and `sda3`/`sda4` small service partitions. We have
not read their contents, so we cannot yet say what is inside `sda4` — but the size (7.8 MB) and
position are consistent with ASUS's documented **"Flash BIOS recovery"** region used together
with the Fn-key/BIOS restore procedure on some Eee models. **Treat all four as
possibly-load-bearing for a factory recovery path until proven otherwise.** They are the only
thing on that disk that was put there by the factory and might be the only working ASUS-level
recovery for a machine with no other firmware-level rescue.

**Preserve or repurpose?** Preserve, until the backup is taken and their contents read. Then, the
conservative decision is **preserve `sda3`/`sda4` regardless** (they cost ~16 MB) and only consider
reusing `sda1`/`sda2` (3.7 G total) once you have decided the Xandros recovery path is worthless
to you — which you can only claim *after* reading them. Any repurposing is a write to `/dev/sda`
and falls under §9/§10.

## 4. Option (a) — a recovery card (lowest risk, do this first)

**What:** a second SD card holding the **same image**, kept out of the machine, plus the
hash-verified backup of the SSD on external media.

**Boot behaviour:** zero change to how the machine boots today. If the working card dies, you
insert the recovery card and boot exactly as before.

**Cost:** one ≤32 GB SDHC card. **Risk:** none to the SSD (writes only to the card).

**Why it is the baseline:** it converts "dead machine" into "swap the card". It is the only option
that requires **no write to the internal SSD at all**, so it can be done immediately after §10's
backup step and it protects against the *actual* present failure (card loss), not a hypothetical
one.

**Do it with:** `scripts/flash-card.sh /dev/sdX <image.img>` — it writes, syncs, reads the image
back off the card, compares sha256, and ejects only on a match.

## 5. Option (b) — `/boot` on the internal SSD, root on the SD card; what happens if the SD is gone

**The idea:** put GRUB + kernel + initramfs on the SSD (fixed, always present, rarely written)
and keep the bulk of the OS on the SD. The theory is that a missing SD then still gives you a
GRUB menu and maybe a rescue.

**What actually happens if the SD card is missing — this is the part to be honest about:**

- **GRUB still starts.** GRUB's core image lives in the MBR, so the menu appears from the SSD.
- **The kernel will not boot.** Deeebian's root is the SD. With the SD absent there is nothing to
  mount as `/`, so the kernel panics with `VFS: Unable to mount root fs` — **after** a ~10–30 s
  wait, not instantly, because `rootwait` (in the shipped GRUB entries) tells it to wait for the
  device to appear.
- **A stock initramfs does not save you.** Deeebian's initramfs is the Debian default: it finds
  and mounts root and hands off. It has no useful "root missing" shell. You get a hang or a
  panic, not a prompt. This is exactly the gap option (d) fixes.
- **Nothing on the SSD can take over**, because the SSD only holds `/boot` (a few hundred MB);
  there is no second root there to fall back to.

**So option (b) alone buys almost nothing.** It moves where GRUB and the kernel live, which is
the part that is already the safest (the SSD is only *read* at boot, never written). The failure
mode you are worried about — "SD removed → machine won't boot" — is **unchanged** by (b) unless it
is paired with (d). Its only real merit is that a *corrupted kernel on the SD* could be replaced
from the SSD copy; you can get that same safety more simply with the recovery card in (a).

**Verdict:** (b) is not worth a write to the SSD on its own. Keep `/boot` in the root filesystem
(the current design, which keeps the build simple) and spend the effort on (a) + (d).

## 6. Option (c) — whole OS on the 3.7 GB SSD, SD as data

**What:** the full Deeebian image on the internal SSD; the SD becomes overflow storage (or a
second recovery OS).

**Feasibility:** yes. The shipped rootfs is ~2.4 G used of a 7167 MiB partition (see the review), so
it fits the SSD with room to spare. `expand-root.sh` would grow the SSD root to fill ~3.7 G on
first boot.

**Why it is attractive:** exactly the stated goal — an OS that does not depend on a card being
present; the SD then becomes hot-swappable removable *data*, which is what a netbook SD slot is
good for.

**Why it is the highest-risk change in the project:** it requires writing the internal SSD, and
the 701's SSD is **2007-era flash soldered into the machine.** It is the one component you cannot
replace. See §9. It must be *last*, not first.

**If adopted, keep a card slot bootable.** Do **not** repurpose away the ability to boot from the
SD reader. The correct end state of (c) is: OS on SSD, **and** a recovery card that still boots,
**and** the SSD's factory content preserved in the backup. Never trade away your last known-good
image to gain disk space.

## 7. The UUID trap when two copies exist

`40-image.sh` bakes a **fixed** UUID (`b0057a11-…`) into every image. If the SSD root and the SD
root are both copies of that image, **both filesystems have the same UUID**. Consequences:

- `search --no-floppy --fs-uuid --set=root <UUID>` in GRUB can match **either** device. The menu
  may offer one "Deeebian" entry that boots whichever disk the firmware enumerates first.
- `/etc/fstab`'s `UUID=<same> /` is likewise ambiguous; the kernel mounts whichever appears first.
- This is not fatal (both are valid roots) but it makes the system's behaviour depend on
  enumeration order, which is exactly the kind of non-determinism that turns a recovery into a
  debugging session.

**Mitigation, if you run two roots deliberately:** give them distinct UUIDs and let GRUB pick per
entry (`search --fs-uuid <ssd-uuid>` vs `<sd-uuid>`), or set `root=PARTUUID=` instead. If you run
**one** OS (the recommended (a)+(d)), this does not arise.

## 8. Option (d) — a rescue initramfs that drops to a useful shell when root is absent

**This is the highest-value change in the document and it writes nothing to the SSD.** It makes
"the SD is missing" a *recoverable* event instead of a panic.

**Design:** a second initramfs variant whose init, when it cannot locate/mount root, drops to a
busybox shell with the tools you actually need — `blkid`, `lsblk`, `mount`, `fsck`, `dd`,
`sha256sum`, `e2fsprogs` — so you can plug in a card, identify it, and either mount it and
`switch_root`, or re-flash it from a backup image already on another device.

Two ways to get it, in increasing order of effort:

1. **GRUB fallback entry + `break=` (smallest step).** Add a menu entry using the same kernel but
   `break=mount` (Debian initramfs) plus `rootdelay`. When root is missing it stops at the
   initramfs shell instead of panicking. This is almost free: it is a `grub.cfg` edit
   (`40-image.sh`), no new build. It gives a shell **only if** the initramfs itself is present —
   which it is, because it is loaded from the SSD/card before root matters.
2. **A dedicated rescue initramfs (robust step).** Build a second initramfs with a script that:
   tries the root UUID; on failure, probes every block device, prints them, and `exec`s a shell;
   offers to `mount` a chosen partition and continue. Ship it as `/boot/initrd.img-rescue` and
   add a GRUB entry `Deeebian — rescue (no root)`. This works even when the SD is absent, because
   the kernel and this initramfs come from GRUB's own device (the SSD or the recovery card).

**Recommendation:** do (1) now (it is a one-line GRUB addition, no rebuild risk) and (2) as part
of the next image build. Combined with (a), the machine then has: a known-good card, a known-good
image, and a boot path that reaches a shell when the root device is gone.

## 9. Why writing the 2007 SSD is the riskiest action in the project

Concretely, and why it needs **explicit** approval rather than a default:

- **It is unreplaceable.** The 701's SSD is a 2007-era flash module — not a 2.5" drive you can
  swap. If it dies, this specific netbook has no internal storage, and the project's stated goal
  (a fixed-disk OS) is gone permanently. There is no part to order.
- **It cannot be health-checked.** Consumer 2007 SSDs generally expose **no SMART**, no wear
  counter, no reallocated-sector count. You cannot ask it how tired it is; the first sign of wear
  is often a write that silently does not stick. A backup lets you *detect* this (a second read
  that hashes differently) but not predict it.
- **Writes are the stress, and the OS writes constantly.** Unlike `/boot`, a root filesystem
  writes logs, apt caches, timestamps. On a worn chip the very act of installing there can be what
  kills it.
- **A bad write can take the whole boot down, including the SD path.** The 701's SSD and SD
  reader share the IDE/USB controller path. A write that hangs the SSD can wedge the ATA channel
  so the machine will not boot from the SD card either — turning a working machine into a
  non-booting one in one command. This is the failure that makes "one command from bricking"
  literal.
- **Getting it wrong is asymmetric.** A mistaken `dd of=/dev/sda` when you meant `/dev/sdb`
  destroys the factory Xandros layout, the possible ASUS recovery region, and your only copy of
  the OS-internal state, in seconds, with no undo and (per the above) possibly no boot.

Everything in this plan exists to make that action a **deliberate, verified, last** step — never a
side effect of testing.

## 10. Staged recommendation, with the exact verification gates

**Stage 0 — take the backup (no device is written).**
Run `sudo scripts/backup-internal-ssd.sh -o /somewhere/with/4GiB`. It reads `/dev/sda`
read-only, refuses a mounted source, refuses a destination on the source disk, hashes the source,
`dd`s to a **regular file**, hashes the file, and refuses to declare success unless the two hashes
match. Result: `<sda>-backup-<stamp>.img` + `.sha256` + `.meta.txt` (the meta file captures
`sfdisk -d`, `blkid`, `lsblk` and the health probes — it is the restore blueprint).

**Stage 1 — prove the backup, before going near the SSD.**
1. **Copy the image + `.sha256` + `.meta.txt` to a second, physically different location**
   (NAS or an offline USB disk). One copy is not a backup.
2. **Run the backup again and confirm the two runs report the SAME source sha256.** Two
   independent reads agreeing is your evidence that the flash reads *consistently* — the closest
   thing to a health check a 2007 SSD will give you.
3. **Verify the file against the device:** `sudo scripts/backup-internal-ssd.sh -i /dev/sda -V <img>`.
4. **Boot the backup in QEMU.** `scripts/50-vmtest.sh` boots a raw image through GRUB to the
   desktop under KVM with a definitively non-PAE CPU. Point it at the backup image
   (`EEEPC_BASE`/loop device), confirm GRUB appears, the kernel loads, and the system reaches
   multi-user. A backup you have never restored is a hope, not a backup.
5. Only if 1–4 all pass is the SSD's content **proven recoverable**.

**Stage 2 — the cheap resilience wins (still no SSD write).**
- Make the **recovery card** (option a) with `flash-card.sh`.
- Add the **GRUB rescue entry** (option d-1) so a missing/failed root drops to a shell.
- Decide whether to build the dedicated **rescue initramfs** (option d-2) into the next image.

**Stage 3 — only now, and only with your explicit go-ahead, consider writing the SSD (option c).**
- Re-read §9 to the person who owns the machine and get a clear "yes".
- Take a **fresh** Backup immediately before (the SSD may read differently now).
- Prefer the **least-writable** layout: if you put the OS on the SSD, keep `/var/log` in RAM
  (already done — journald `Storage=volatile`), `/tmp` on tmpfs (already done), `noatime` (already
  done), and consider mounting the SD as the writable data area so the SSD is largely read.
- **Keep a bootable recovery card** and never repurpose away the SD-boot capability.
- Write with `flash-card.sh --force-ssd` (it shows the model/size and requires the typed
  `SMALL-DEVICE` acknowledgement) — **not** a bare `dd`.

**The single decision to make:** the user's stated goal allows *either* "(a)+(d): OS stays on
removable media, but recovery is bulletproof" *or* "(c): OS on the fixed SSD". Both are valid.
(a)+(d) is available **today with no SSD write and no irreplaceable risk**. (c) is the bigger
change and is the one that can brick the machine. Recommendation: **do (a)+(d) now; treat (c) as
a later, separately-approved experiment**, and only after Stage 1 has proved the backup.

## 11. What this document does not claim

- We have **not** read the contents of `sda1`–`sda4`; "preserve" is the conservative default, not
  a proven ASUS requirement.
- We have **not** confirmed the SSD exposes SMART, nor how it behaves under sustained writes;
  that requires the hardware, which we deliberately do not have.
- The QEMU boot of the *backup image* has **not** been run here — `50-vmtest.sh` is the tool for
  it and it must be run on the build host before Stage 3.

## 12. Tooling in this repo

| File | Writes | Purpose |
|---|---|---|
| `scripts/backup-internal-ssd.sh` | a **regular file** only | read-only, hash-verifying backup of `/dev/sda`; refuses source==destination; `--dry-run`, `--verify-only` |
| `scripts/flash-card.sh` | the **one named device** | image a card/disk; size+model shown, typed confirmation, refuses the root disk and `sda`, `dd`+sync+hash-verify+eject |
| `docs/storage-resilience.md` | — | this analysis |
