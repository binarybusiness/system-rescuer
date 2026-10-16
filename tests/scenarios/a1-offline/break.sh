#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# A1-offline break: <root> is the scenario disk's root filesystem with its ESP
# mounted where the base keeps it. A kernel reinstall was cut off while pacman
# was still writing the linux package's files: the kernel image under
# /usr/lib/modules is 0 bytes and half the modules are missing, so the boot
# files cannot be rebuilt from what is on disk, and the package must be
# installed again. The hook never ran: the ESP's kernel copy is 0 bytes and
# the initramfs images are gone, as in A1. The lock file remains and
# pacman.log stops at the transaction's start. The rescue system reaches no
# mirror (offline_repos), so the package comes from the stick.
set -euo pipefail
# shellcheck source=../../bench/break-lib.sh
. "$(dirname "$0")/../../bench/break-lib.sh"
root=${1:?usage: break.sh <root> <base>} base=${2:?usage: break.sh <root> <base>}
[[ $BASE_INITRAMFS == mkinitcpio ]] || { echo "break.sh: no A1-offline break for base $base" >&2; exit 1; }
k=$(kver "$root")
mods=$root/usr/lib/modules/$k
[[ -s $mods/vmlinuz ]] || { echo "break.sh: no kernel at ${mods#"$root"}/vmlinuz" >&2; exit 1; }
: > "$mods/vmlinuz"
# Every other module file, in a stable order: half the package's modules.
find "$mods/kernel" -type f -name '*.ko*' | sort | awk 'NR % 2' | xargs -r rm -f
: > "$root$BASE_ESP/vmlinuz-linux"
rm -f "$root$BASE_ESP"/initramfs-linux*.img
: > "$root/var/lib/pacman/db.lck"
pacman_log "$root" "[PACMAN] Running 'pacman -S linux'" "[ALPM] transaction started"
