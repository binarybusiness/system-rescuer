#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# A8 break: <root> is the scenario disk's root. An fstab line for an archive
# disk (a USB drive the owner has since unplugged) without nofail.
set -euo pipefail
root=${1:?usage: break.sh <root> <base> <disks-dir>}
mkdir -p "$root/srv/archive"
printf '\n# Archive disk (USB, ext4)\nUUID=%s\t/srv/archive\text4\tdefaults\t0 2\n' "$(cat /proc/sys/kernel/random/uuid)" >> "$root/etc/fstab"
