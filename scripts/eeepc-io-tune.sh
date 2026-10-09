#!/bin/bash
# Tune the SD/USB block devices for a single slow card: no scheduler, modest read-ahead.
# Deliberately does NOT touch things that are no-ops on a uniprocessor (e.g. rq_affinity,
# which only decides which CPU gets the completion IRQ — there is only one).
set -u
tuned=0
for d in /sys/block/sd* /sys/block/mmcblk*; do
  [ -e "$d/queue" ] || continue           # exists only for whole disks, not partitions
  # 'none' removes blk-mq deadline reordering; with no seek cost there is nothing to reorder.
  if [ -w "$d/queue/scheduler" ]; then
    echo none > "$d/queue/scheduler" 2>/dev/null && tuned=1 || true
  fi
  # 256 KB read-ahead amortises the reader's per-request latency on sequential reads
  # (loading a binary, opening an app) without the 1 MB+ that would inflate random latency.
  [ -w "$d/queue/read_ahead_kb" ] && echo 256 > "$d/queue/read_ahead_kb" 2>/dev/null || true
  # a shallower queue means less work buffered behind a slow card (lower tail latency).
  [ -w "$d/queue/nr_requests" ]   && echo 64  > "$d/queue/nr_requests" 2>/dev/null || true
  # some USB card readers misreport rotational=1; forcing 0 stops the kernel assuming seeks
  # are expensive. No-op when it is already 0.
  [ -w "$d/queue/rotational" ]   && echo 0   > "$d/queue/rotational" 2>/dev/null || true
done
[ "$tuned" = 1 ] && echo "eeepc-io-tune: scheduler=none on the SD/mmc device(s)"
exit 0
