#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# A5 break: <root> is the scenario disk's root with its ESP at /boot. Remove
# the fallback loader; scenario.conf's fresh_vars=1 empties the firmware's
# boot entries.
set -euo pipefail
root=${1:?usage: break.sh <root> <base> <disks-dir>}
rm "$root/boot/EFI/BOOT/BOOTX64.EFI"
