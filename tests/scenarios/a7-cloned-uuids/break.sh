#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# A7, mounted: nothing to change in the files; the UUIDs change unmounted
# (break-offline.sh). A systemd-boot base needs a LUKS root (crypttab); a
# GRUB base's plain root is cloned as it is.
set -euo pipefail
[[ $BASE_LOADER == grub || -f ${1:?usage: break.sh <root> <base>}/etc/crypttab ]] \
    || { echo "break.sh: A7 needs a LUKS root (crypttab) on a $BASE_LOADER base" >&2; exit 1; }
