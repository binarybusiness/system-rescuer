#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# D8 break: D1's, on a machine whose Windows has BitLocker on (win11-eval).
exec "$(dirname "$0")/../d1-windows-update-took-over/break.sh" "$@"
