#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# D7 break: delete Linux's firmware entries and add a Windows Boot Manager
# entry for an ESP on a disk the machine no longer has, first in the boot
# order. Its PARTUUID is left in <disks-dir>/dangling-partuuid for the check.
set -euo pipefail
# shellcheck source=../../bench/break-lib.sh
. "$(dirname "$0")/../../bench/break-lib.sh"
disks=${3:?usage: break.sh <root> <base> <disks-dir>}
mapfile -t linux < <(efi_on_disk "$BENCH_VARS" "$BENCH_DISK" "$efi_ms_path")
(( ${#linux[@]} )) || { echo "break.sh: no Linux entry in the firmware" >&2; exit 1; }
efi_remove "$BENCH_VARS" "${linux[@]}"
# The missing disk: a GPT with an ESP, made only to take its entry from.
gone=$(mktemp)
truncate -s 64M "$gone"
sfdisk -q "$gone" <<< $'label: gpt\nsize=60MiB, type=uefi' || { rm -f "$gone"; exit 1; }
python3 "$efi_py" partuuids "$gone" > "$disks/dangling-partuuid"
entry=$(efi_add "$BENCH_VARS" "$(python3 "$efi_py" option 'Windows Boot Manager' "$gone" esp '\EFI\Microsoft\Boot\bootmgfw.efi')" first)
rm -f "$gone"
echo "break.sh: $entry Windows Boot Manager for the missing disk $(cat "$disks/dangling-partuuid"), first" >&2
