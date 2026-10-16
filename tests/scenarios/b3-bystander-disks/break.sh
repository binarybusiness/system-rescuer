#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# B3 break: <root> is the scenario disk's root; <disks-dir> gets the
# bystanders: pool-a.img and pool-b.img, a healthy btrfs RAID1 pool with the
# owner's photos, mounted at /srv/pool with nofail, and windows-data.img, a
# GPT disk with one NTFS data partition. The break deletes the initramfs.
set -euo pipefail
# shellcheck source=../../bench/break-lib.sh
. "$(dirname "$0")/../../bench/break-lib.sh"
root=${1:?usage: break.sh <root> <base> <disks-dir>} disks=${3:?usage: break.sh <root> <base> <disks-dir>}
uuid=$(photo_pool "$disks")
w=$disks/windows-data.img f=$(mktemp) lw=''
release() {
    losetup -d ${lw:+"$lw"} 2> /dev/null || true
    rm -f "$f"
}
trap release EXIT
truncate -s 128M "$w"
printf 'label: gpt\ntype=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7, name="Basic data partition"\n' | sfdisk -q "$w"
lw=$(losetup -fP --show "$w")
udevadm settle
mkfs.ntfs -q -F -f -L Data "${lw}p1" > /dev/null
head -c 3M /dev/urandom > "$f"
ntfscp -q -f "${lw}p1" "$f" budget-2026.xlsx > /dev/null
release
trap - EXIT
mkdir -p "$root/srv/pool"
printf '\n# Photo pool: btrfs RAID1 over two disks\nUUID=%s\t/srv/pool\tbtrfs\tdefaults,nofail\t0 0\n' "$uuid" >> "$root/etc/fstab"
delete_initramfs "$root"
