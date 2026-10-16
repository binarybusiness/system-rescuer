#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# A6 break: <root> is the scenario disk's root with its ESP at /boot/efi.
# Empty /boot/grub/grub.cfg (Debian) or /boot/grub2/grub.cfg (Fedora), and
# put a UUID no filesystem has into every ESP stub that searches for the root.
set -euo pipefail
root=${1:?usage: break.sh <root> <base>} base=${2:?usage: break.sh <root> <base>}
[[ $BASE_LOADER == grub ]] || { echo "break.sh: no A6 break for base $base" >&2; exit 1; }
cfg=''
for c in "$root/boot/grub/grub.cfg" "$root/boot/grub2/grub.cfg"; do [[ -s $c ]] && { cfg=$c; break; }; done
[[ -n $cfg ]] || { echo "break.sh: no grub.cfg in $root/boot" >&2; exit 1; }
: > "$cfg"
wrong=$(cat /proc/sys/kernel/random/uuid) n=0
for stub in "$root$BASE_ESP"/EFI/*/grub.cfg; do
    grep -qE 'search(\.fs_uuid| --fs-uuid)' "$stub" || continue
    sed -i -E "s/(search\.fs_uuid|search --fs-uuid --set=root) [0-9a-f-]{36}/\1 $wrong/" "$stub"
    grep -qF "$wrong" "$stub" || { echo "break.sh: ${stub#"$root"} kept its UUID" >&2; exit 1; }
    n=$((n + 1))
done
(( n )) || { echo "break.sh: no ESP stub searches for the root" >&2; exit 1; }
