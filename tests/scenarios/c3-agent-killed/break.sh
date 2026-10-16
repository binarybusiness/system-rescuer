#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# C3 break: <root> is the scenario disk's root. Delete the initramfs, so the
# boot entry fails, as in B3 without its bystander disks.
set -euo pipefail
# shellcheck source=../../bench/break-lib.sh
. "$(dirname "$0")/../../bench/break-lib.sh"
delete_initramfs "${1:?usage: break.sh <root> <base> <disks-dir>}"
