#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# A2 break (nixos-sdboot): `nixos-rebuild boot` set the system profile to a new
# generation (the base's a2-next, which shares the kernel and initrd with the
# current one), and its boot loader step was cut off while it rewrote the
# boot files, as the home server's was: the new generation's entry is written and is
# the default, the kernel every generation shares is 0 bytes, and every
# initrd is gone. break-offline.sh leaves the ESP's dirty bit and the root's
# unreplayed journal that the power loss left.
set -euo pipefail
# shellcheck source=../../bench/break-lib.sh
. "$(dirname "$0")/../../bench/break-lib.sh"
root=${1:?usage: break.sh <root> <base>} base=${2:?usage: break.sh <root> <base>}
[[ $BASE_INITRAMFS == nixos && $BASE_LOADER == systemd-boot ]] || { echo "break.sh: no A2 break for base $base" >&2; exit 1; }
esp=$root$BASE_ESP
profiles=$root/nix/var/nix/profiles
next=$(awk '$1 == "a2-next" {print $2}' "$root/var/lib/bench/generations")
[[ -n $next && -d $root$next ]] || { echo "break.sh: no a2-next generation in the base" >&2; exit 1; }
cur=$(nixos_generation "$root") new=$(( $(nixos_generation "$root") + 1 ))
entry=$esp/loader/entries/nixos-generation-$cur.conf
[[ -f $entry ]] || { echo "break.sh: no entry for generation $cur" >&2; exit 1; }

# The profile, as nix-env --set leaves it.
ln -s "$next" "$profiles/system-$new-link"
ln -sfn "system-$new-link" "$profiles/system"

# Every generation boots the one kernel; the builder had truncated it, and
# removed the initrds, when the power went.
kernel=$(awk '$1 == "linux" {print $2}' "$entry")
[[ $kernel == "$(nixos_efi_name "$root" "$next/kernel")" ]] \
    || { echo "break.sh: a2-next's kernel is not generation $cur's" >&2; exit 1; }
: > "$esp$kernel"
rm -f "$esp"/EFI/nixos/*-initrd.efi

# The new generation's entry, in the builder's own format, and the default.
old_top=$(sed -nE 's/^options .*init=([^ ]+)\/init( .*)?$/\1/p' "$entry")
sed -e "s|$old_top|$next|g" -e "s|^initrd .*|initrd $(nixos_efi_name "$root" "$next/initrd")|" \
    -e "s|Generation $cur |Generation $new |" "$entry" > "$esp/loader/entries/nixos-generation-$new.conf"
sed -i "s|^default .*|default nixos-generation-$new.conf|" "$esp/loader/loader.conf"
