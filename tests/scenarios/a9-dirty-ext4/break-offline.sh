#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# A9, unmounted: point cache-a.dat's only extent at cache-b.dat's blocks and
# mark the filesystem as having errors, so the boot-time check runs and stops.
set -euo pipefail
dev=$1
start=$(debugfs -R "bmap /var/lib/pkgstats/cache-b.dat 0" "$dev" 2>/dev/null)
[[ $start =~ ^[0-9]+$ ]] || { echo "no block for cache-b.dat" >&2; exit 1; }
# An extent inode's i_block: a 3-word header, then (ee_block, ee_len|start_hi, start_lo).
debugfs -w -R "set_inode_field /var/lib/pkgstats/cache-a.dat block[5] $start" "$dev" 2>/dev/null
debugfs -w -R "ssv state 2" "$dev" 2>/dev/null
if e2fsck -n "$dev" > /dev/null 2>&1; then echo "the filesystem still checks clean" >&2; exit 1; fi
