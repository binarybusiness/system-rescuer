#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# B8 break: A1's, on the scenario disk (Debian) only.
set -euo pipefail
exec "$(dirname "$0")/../a1-interrupted-update/break.sh" "$@"
