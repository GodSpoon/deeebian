# Workstream patches — Eee PC 701 bring-up (2026-10-09)

Four parallel subagents each produced a patch against `review/2026-10-08` (`34a12fe`) in
isolated git worktrees. They are stored here **unmerged** because they conflict: WS-A and
WS-D both rewrite `scripts/30-configure.sh` and `scripts/10-packages.sh` independently, so
applying them in sequence will fight. Merge by hand.

| File | Workstream | Touches | Status |
|---|---|---|---|
| `wsA.patch` | A — desktop/terminal | `scripts/10-packages.sh`, `scripts/30-configure.sh` | audited: `bash -n` clean, XML well-formed |
| `wsB.patch` | B — WiFi kernel+firmware | `scripts/20-kernel.sh`, `scripts/10-packages.sh` | **independently verified** against a real 6.12.112 tree |
| `wsB_docs_wifi-analysis.md` | B — report | new `docs/wifi-analysis.md` | source-cited per-card analysis |
| `wsD.patch` | D — tooling/diagnostics | 4 files incl. `ci/`-adjacent | audited: `bash -n` clean |
| `wsC_backup-internal-ssd.sh` | C — SSD backup | new script (was untracked) | passed a 12-case refusal matrix on loop devices |
| `wsC_flash-card.sh` | C — safe flash | new script (was untracked) | same harness |
| `wsC_storage-resilience.md` | C — storage design | new `docs/` | options a–d, risk analysis |

## Audit results (parent, not the children's self-reports)

- **WS-B kernel symbols**: re-tested against a real 6.12.112 i386 tree through the actual
  6-pass converge loop → converged pass 3, `RTW88_8822CU`/`RTW88_8821CU`, `RTW88_USB`,
  `IWLWIFI`, `IWLDVM` all `=y`, all asserts PASS. A first single-pass test of mine wrongly
  showed failure; that was my harness not reproducing the loop, not a defect.
- **WS-A**: confirmed on the live 701 that zero `C-A-` keybinds existed and the tint2 launcher
  listed only `tint2conf`+`firefox` — so the reported gap is real.
- **WS-D**: verified the collector install path both halves; it found and fixed a latent hole
  (an `if [ -f ]` guard that would silently ship a box with no collector).
- **WS-C**: its loopback harness hit `sfdisk: command not found`, so the partition-table
  blueprint section of its meta output is untested on a minimal system.

## What is NOT verified

None of these run on the 701 yet — they are source patches. The desktop changes were never seen
rendered; the kernel additions were never booted. Merge A+D by hand, rebuild through CI, then
re-check on hardware with a fresh `scrot` screenshot and `eeepc-health`.

## Real hardware state (independent of these patches)

The internal 3.7 GB SSD (`/dev/sda`, `SILICONMOTION SM223AC`) was backed up read-only and the
image verified on both ends:
`sda-backup.img.gz`, 1,332,101,016 bytes,
sha256 `acaa3e5b2d785f08d9febd83d1bae00df3a15b8c47c262b2131af203385c8b74`.
That image lives in `backups/eeepc-internal-ssd/` (gitignored — do not commit it).
**It exists in one place only; copy it somewhere physically separate.**
