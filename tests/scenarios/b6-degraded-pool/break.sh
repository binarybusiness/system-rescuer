#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# B6 break: <root> is the scenario disk's root, and <disks-dir> gets the
# pool's surviving member as pool-a.img. The pool is made of two 256 MiB disks
# with data and metadata mirrored, holds the owner's photos, and loses its
# second disk; fstab mounts it at /srv/pool without nofail.
set -euo pipefail
# shellcheck source=../../bench/break-lib.sh
. "$(dirname "$0")/../../bench/break-lib.sh"
root=${1:?usage: break.sh <root> <base> <disks-dir>} disks=${3:?usage: break.sh <root> <base> <disks-dir>}
uuid=$(photo_pool "$disks")
rm "$disks/pool-b.img"
mkdir -p "$root/srv/pool"
printf '\n# Photo pool: btrfs RAID1 over two disks\nUUID=%s\t/srv/pool\tbtrfs\tdefaults\t0 0\n' "$uuid" >> "$root/etc/fstab"
