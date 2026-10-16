#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# D2 break: <root> is the scenario disk's root with its ESP where the base
# keeps it, Windows' boot files on it. Copy them over the fallback loader, as
# Windows does, and delete every firmware boot entry and the boot order.
set -euo pipefail
# shellcheck source=../../bench/break-lib.sh
. "$(dirname "$0")/../../bench/break-lib.sh"
root=${1:?usage: break.sh <root> <base> <disks-dir>}
esp=$root$BASE_ESP
install -D -m 644 "$esp/EFI/Microsoft/Boot/bootmgfw.efi" "$esp/EFI/BOOT/BOOTX64.EFI"
install -m 644 "$esp/EFI/Microsoft/Boot/startup.nsh" "$esp/EFI/BOOT/startup.nsh"
mapfile -t all < <(efi_query "$BENCH_VARS" entries | cut -f1)
efi_delete "$BENCH_VARS" "${all[@]}" BootOrder
