#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# B7 break, with the filesystems unmounted: the whole scenario disk reads as
# zeros, a disk with nothing on it yet (the loop device's discard punches
# holes in the overlay).
set -euo pipefail
part=${1:?usage: break-offline.sh <root-device>}
[[ $part =~ ^(/dev/loop[0-9]+)p[0-9]+$ ]] || { echo "break-offline.sh: $part is not a loop partition" >&2; exit 1; }
loop=${BASH_REMATCH[1]}
blkdiscard -f "$loop" || { echo "break-offline.sh: cannot discard $loop" >&2; exit 1; }
sync
[[ -z $(blkid -p "$loop" 2>/dev/null) ]] || { echo "break-offline.sh: $loop still has a signature" >&2; exit 1; }
