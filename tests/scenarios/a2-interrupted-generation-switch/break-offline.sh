#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# A2, unmounted: what the power loss left on the filesystems. The ESP's FAT
# dirty bit is set, and the root ext4 has a committed journal transaction
# that was never replayed (needs_recovery): a write through a device-mapper
# copy of the partition is synced to the journal, then the copy fails every
# further write, so the unmount checkpoints nothing.
set -euo pipefail
dev=$1
disk=/dev/$(lsblk -no PKNAME "$dev")
esp=$(lsblk -nrpo NAME,PARTTYPE "$disk" | awk '$2 == "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" {print $1}')
[[ -b $esp ]] || { echo "no ESP on $disk" >&2; exit 1; }

# The dirty bit: bit 0 of the extended BPB's reserved byte (FAT32 at 0x41,
# FAT12 and FAT16 at 0x25).
if [[ $(dd if="$esp" bs=1 skip=$((0x52)) count=8 status=none) == 'FAT32   ' ]]; then off=$((0x41)); else off=$((0x25)); fi
byte=$(dd if="$esp" bs=1 skip="$off" count=1 status=none | od -An -tu1 | tr -d ' ')
printf '%b' "\\x$(printf %02x $((byte | 1)))" | dd of="$esp" bs=1 seek="$off" conv=notrunc status=none
# fsck.fat exits 1 when it finds the bit, so its output is read, not its status.
fsck=$(fsck.fat -n "$esp" 2>&1 || true)
grep -qi 'dirty bit' <<< "$fsck" || { echo "the ESP's dirty bit did not take" >&2; exit 1; }

map=bench-a2-$$ mnt=$(mktemp -d)
size=$(blockdev --getsz "$dev")
dmsetup create "$map" --table "0 $size linear $dev 0"
# set -e holds inside the trap too: what is already gone must not fail the exit.
trap 'umount "$mnt" 2> /dev/null || true; dmsetup remove --force "$map" 2> /dev/null || true; rmdir "$mnt" || true' EXIT
mount "/dev/mapper/$map" "$mnt"
printf '%s switch-to-configuration: installing the boot loader\n' "$(date -u +%FT%TZ)" >> "$mnt/var/log/bench-a2-switch.log"
sync
dmsetup suspend --nolockfs "$map"
dmsetup load "$map" --table "0 $size error"
dmsetup resume "$map"
umount "$mnt" 2> /dev/null || true
dmsetup remove --force "$map"
features=$(dumpe2fs -h "$dev" 2> /dev/null | grep '^Filesystem features:' || true)
[[ $features == *needs_recovery* ]] \
    || { echo "the root's journal was replayed after all" >&2; exit 1; }
