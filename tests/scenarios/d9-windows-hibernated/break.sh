#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# D9 break: D1's, on a machine whose Windows is hibernated (win11-hibernated).
exec "$(dirname "$0")/../d1-windows-update-took-over/break.sh" "$@"
