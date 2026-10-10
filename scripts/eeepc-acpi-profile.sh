#!/bin/bash
# Ask the firmware for a low-power profile, if (and only if) it exposes the interface.
# Silent and idempotent: a missing attribute or unaccepted value is NOT an error.
set -u
p=/sys/firmware/acpi/platform_profile
[ -w "$p" ] || exit 0
choices=$(cat /sys/firmware/acpi/platform_profile_choices 2>/dev/null || true)
case " $choices " in
  *" low-power "*) echo low-power > "$p" 2>/dev/null || true ;;
  *" quiet "*)     echo quiet     > "$p" 2>/dev/null || true ;;
esac
exit 0
