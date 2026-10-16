#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# D1 break: delete the firmware entries that start Linux from the shared ESP
# and put Windows Boot Manager first.
set -euo pipefail
# shellcheck source=../../bench/break-lib.sh
. "$(dirname "$0")/../../bench/break-lib.sh"
mapfile -t linux < <(efi_on_disk "$BENCH_VARS" "$BENCH_DISK" "$efi_ms_path")
(( ${#linux[@]} )) || { echo "break.sh: no Linux entry in the firmware" >&2; exit 1; }
efi_remove "$BENCH_VARS" "${linux[@]}"
efi_first "$BENCH_VARS" "$(efi_entry "$BENCH_VARS" '^Windows Boot Manager$')"
