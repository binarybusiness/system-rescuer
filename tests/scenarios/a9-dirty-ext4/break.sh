#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# A9, mounted: two ordinary files whose blocks break-offline.sh makes shared.
set -euo pipefail
mkdir -p "$1/var/lib/pkgstats"
head -c 64K /dev/urandom > "$1/var/lib/pkgstats/cache-a.dat"
head -c 64K /dev/urandom > "$1/var/lib/pkgstats/cache-b.dat"
