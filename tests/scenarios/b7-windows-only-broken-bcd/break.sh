#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# B7 break, with the scenario disk's root mounted: Windows' BCD on its own
# ESP (win-standin.img, the ESP at 1 MiB) becomes 0 bytes, and every firmware
# entry for the scenario disk goes, so Windows Boot Manager is the machine's
# only system. break-offline.sh then blanks the scenario disk.
set -euo pipefail
# shellcheck source=../../bench/break-lib.sh
. "$(dirname "$0")/../../bench/break-lib.sh"
disks=${3:?usage: break.sh <root> <base> <disks-dir>}
win=$disks/win-standin.img empty=$(mktemp)
[[ -s $win ]] || { echo "break.sh: B7 needs with=win-standin (with_esp=own)" >&2; exit 1; }
mcopy -o -i "$win@@1M" "$empty" ::/EFI/Microsoft/Boot/BCD || { echo "break.sh: cannot empty the BCD" >&2; exit 1; }
rm -f "$empty"
mapfile -t linux < <(efi_on_disk "$BENCH_VARS" "$BENCH_DISK")
(( ${#linux[@]} )) || { echo "break.sh: no firmware entry for the scenario disk" >&2; exit 1; }
efi_remove "$BENCH_VARS" "${linux[@]}" || { echo "break.sh: cannot remove ${linux[*]}" >&2; exit 1; }
