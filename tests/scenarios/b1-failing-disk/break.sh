#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# B1 break: <root> is the scenario disk's root, and <disks-dir> gets
# bad-sectors: the disk sectors of the inode-table block holding the root
# directory's inode (inode 2) and of the first block of the owner's thesis,
# whose reads tests/scenario.sh then fails through blkdebug.
set -euo pipefail
root=${1:?usage: break.sh <root> <base> <disks-dir>} disks=${3:?usage: break.sh <root> <base> <disks-dir>}
dev=$(findmnt -no SOURCE "$root")
start=$(< "/sys/class/block/$(basename "$dev")/start")
sync -f "$root"
bs=$(stat -f -c %S "$root")
inode_block=$(debugfs -R 'imap <2>' "$dev" 2> /dev/null | sed -nE 's/.*located at block ([0-9]+),.*/\1/p')
file_block=$(filefrag -e -b"$bs" "$root/home/bench/Documents/thesis.odt" | awk -F'[:. ]+' '$2 == 0 {print $5; exit}')
[[ $inode_block =~ ^[0-9]+$ && $file_block =~ ^[0-9]+$ ]] || { echo "break.sh: no block for the root inode ($inode_block) or the thesis ($file_block)" >&2; exit 1; }
for block in "$inode_block" "$file_block"; do
    for ((s = 0; s < bs / 512; s++)); do echo $((start + block * bs / 512 + s)); done
done > "$disks/bad-sectors"
