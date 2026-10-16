#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# D4 break: <root> is the scenario disk's root with its ESP where the base
# keeps it. systemd-boot's menu hidden: timeout 0 (the base's own setting,
# written here so the scenario does not depend on it).
set -euo pipefail
root=${1:?usage: break.sh <root> <base> <disks-dir>}
conf=$root$BASE_ESP/loader/loader.conf
[[ -f $conf ]] || { echo "break.sh: no ${conf#"$root"}" >&2; exit 1; }
sed -i '/^[[:space:]]*timeout[[:space:]]/d' "$conf"
printf 'timeout 0\n' >> "$conf"
