#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# D6 break: A1's.
set -euo pipefail
exec "$(dirname "$0")/../a1-interrupted-update/break.sh" "$@"
