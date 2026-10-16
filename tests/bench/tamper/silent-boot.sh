#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# Oracle self-test (tests/scenario.sh --tamper): the disk's boot prints
# nothing on the serial console (its systemd-boot entries lose
# console=ttyS0), so the boot oracle sees no end marker. A scenario whose disk
# must stay broken (boots=0) must then fail the boot oracle as inconclusive,
# not pass it as still broken.
set -euo pipefail
shopt -s nullglob
entries=("$1"/boot/loader/entries/*.conf "$1"/efi/loader/entries/*.conf)
(( ${#entries[@]} )) || { echo "silent-boot: no systemd-boot entry under $1/boot or $1/efi" >&2; exit 1; }
sed -i -E 's/[[:space:]]console=ttyS[^[:space:]]*//g' "${entries[@]}"
! grep -q 'console=ttyS' "${entries[@]}"
