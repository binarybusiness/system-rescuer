#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# A10 break: <root> is the scenario disk's root. Fill a little under half its
# free space with old packages in pacman's cache (real ones from this host's
# cache, none of them installed on the disk, so `pacman -Sc` would remove
# them), the rest with the owner's videos, and the last blocks with a
# download cut short.
set -euo pipefail
root=${1:?usage: break.sh <root> <base> <disks-dir>}
cache=$root/var/cache/pacman/pkg
# Free space as df shows it (blocks available to the owner): ext4 keeps a
# few clusters for its own metadata that no file can take, even root's.
avail_bytes() { echo $(( $(stat -f -c '%a * %S' "$root") )); }
free_bytes() { echo $(( $(stat -f -c '%f * %S' "$root") )); }
mkdir -p "$cache/download-Xk3f9a" "$root/home/bench/Videos"
want=$(( $(free_bytes) * 45 / 100 )) got=0
while read -r size pkg; do
    (( got < want )) || break
    name=$(basename "$pkg")
    [[ ! -d $root/var/lib/pacman/local/${name%-*.pkg.tar.zst} ]] || continue
    (( got + size <= want + 50 * 1048576 )) || continue
    cp --reflink=auto "$pkg" "$cache/"
    got=$((got + size))
done < <(find /var/cache/pacman/pkg -maxdepth 1 -name '*.pkg.tar.zst' -size +20M -printf '%s %p\n' | sort -rn)
(( got >= want / 2 )) || { echo "break.sh: only $got bytes of packages to copy from /var/cache/pacman/pkg" >&2; exit 1; }
# ext4 needs room for the file's own extent blocks: retry with a wider margin.
sync -f "$root"
for margin in 8 16 32 64; do
    fallocate -l $(( $(free_bytes) - margin * 1048576 )) "$root/home/bench/Videos/holiday-2025.mkv" 2> /dev/null && break
    rm -f "$root/home/bench/Videos/holiday-2025.mkv"
done
[[ -f $root/home/bench/Videos/holiday-2025.mkv ]] || { echo "break.sh: no room for the videos" >&2; exit 1; }
dd if=/dev/zero of="$cache/download-Xk3f9a/linux-firmware-20261001-1-any.pkg.tar.zst.part" bs=64K status=none 2> /dev/null || true
sync -f "$root"
(( $(avail_bytes) < 1048576 )) || { echo "break.sh: $(avail_bytes) bytes still available" >&2; exit 1; }
