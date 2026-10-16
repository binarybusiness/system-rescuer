#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# D3 break: delete Windows Boot Manager's firmware entry.
set -euo pipefail
# shellcheck source=../../bench/break-lib.sh
. "$(dirname "$0")/../../bench/break-lib.sh"
efi_remove "$BENCH_VARS" "$(efi_entry "$BENCH_VARS" '^Windows Boot Manager$')"
