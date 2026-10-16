#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# B2 break: erase the partition table of the disk holding <root-device> as
# `wipefs -a` on the whole disk does (the protective MBR's boot signature and
# both GPT headers' signatures), leaving the partition entries.
set -euo pipefail
dev=${1:?usage: break-offline.sh <root-device>}
disk=/dev/$(lsblk -no PKNAME "$dev")
wipefs -a -q "$disk"
! sfdisk -d "$disk" > /dev/null 2>&1 || { echo "break-offline.sh: $disk still has a partition table" >&2; exit 1; }
