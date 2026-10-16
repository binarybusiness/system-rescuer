#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# B2 break, mounted part: keep the disk's partition layout in <disks-dir> for
# the scenario's check; break-offline.sh erases the table.
set -euo pipefail
root=${1:?usage: break.sh <root> <base> <disks-dir>} disks=${3:?usage: break.sh <root> <base> <disks-dir>}
sfdisk -d "/dev/$(lsblk -no PKNAME "$(findmnt -no SOURCE "$root")")" > "$disks/layout.sfdisk"
