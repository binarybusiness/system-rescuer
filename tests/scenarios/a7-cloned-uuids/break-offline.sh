#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# A7, unmounted: give the clone new random UUIDs, as a cloning tool does for
# the copy so that both disks can be attached at once.
#   LUKS root (eos-sdboot): the btrfs filesystem and its LUKS container.
#   plain ext4 root (debian-grub): the ext4 filesystem, every partition's
#   GUID, the disk's GUID and the ESP's serial number.
set -euo pipefail
dev=${1:?usage: break-offline.sh <root-device> [<luks-partition>]} luks=${2:-}
if [[ -n $luks ]]; then
    old=$(cryptsetup luksUUID "$luks")
    btrfstune -f -u "$dev" > /dev/null
    cryptsetup luksUUID -q --uuid "$(cat /proc/sys/kernel/random/uuid)" "$luks"
    [[ $(cryptsetup luksUUID "$luks") != "$old" ]] || { echo "break-offline.sh: the LUKS UUID did not change" >&2; exit 1; }
    exit 0
fi
[[ $(blkid -s TYPE -o value "$dev") == ext4 ]] || { echo "break-offline.sh: A7 needs a LUKS or ext4 root, not $dev" >&2; exit 1; }
disk=/dev/$(lsblk -dno PKNAME "$dev")
[[ $disk != /dev/ ]] || { echo "break-offline.sh: no disk holds $dev" >&2; exit 1; }
old=$(blkid -s UUID -o value "$dev")
# tune2fs changes the UUID of a cleanly checked filesystem only.
e2fsck -fy "$dev" > /dev/null || (( $? < 4 ))
tune2fs -U random "$dev" > /dev/null
[[ $(blkid -s UUID -o value "$dev") != "$old" ]] || { echo "break-offline.sh: the ext4 UUID did not change" >&2; exit 1; }
sfdisk -q --disk-id "$disk" "$(cat /proc/sys/kernel/random/uuid)"
for part in "$disk"p*; do
    n=${part##*p}
    sfdisk -q --part-uuid "$disk" "$n" "$(cat /proc/sys/kernel/random/uuid)"
    if [[ $(blkid -s TYPE -o value "$part" 2> /dev/null) == vfat ]]; then
        fatlabel -i "$part" "$(od -An -tx4 -N4 /dev/urandom | tr -d ' ')"
    fi
done
