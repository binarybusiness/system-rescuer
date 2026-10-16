#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# A3 break. eos-sdboot: fill the ESP with the boot files and loader entries
# of kernels that are no longer installed (no /usr/lib/modules/<version>),
# leave the owner's own file on it, then cut the current kernel's initramfs
# short as a full disk would, with kernel-install's error in pacman.log. The
# stale entries keep the current entry's sort-key, so that systemd-boot orders
# them by version and boots the newest (this plugin's sort-key names the
# version, and sort-keys sort before versions).
# nixos-sdboot: its ESP is already nearly full of the boot files of five
# generations (no configurationLimit, as on the home server). `nixos-rebuild boot` to
# a new generation (the base's a3-next, whose initrd is new) set the profile,
# then ran out of space copying the initrd: the builder's partial `.tmp.`
# copy fills the ESP, the new generation has no entry, and the old one stays
# the default. The repair prunes old generations, which needs the owner's OK.
set -euo pipefail
# shellcheck source=../../bench/break-lib.sh
. "$(dirname "$0")/../../bench/break-lib.sh"
root=${1:?usage: break.sh <root> <base>} base=${2:?usage: break.sh <root> <base>}
[[ $BASE_LOADER == systemd-boot && $BASE_INITRAMFS =~ ^(dracut|nixos)$ ]] || { echo "break.sh: no A3 break for base $base" >&2; exit 1; }
esp=$root$BASE_ESP
avail() { df --output=avail -B1 "$esp" | tail -n 1; }

mkdir -p "$esp/owner"
printf 'Firmware settings before the BIOS update of 2025-03: SVM on, CSM off, fTPM on.\n' > "$esp/owner/bios-settings.txt"
head -c 2M /dev/urandom > "$esp/owner/bios-backup.rom"

if [[ $BASE_INITRAMFS == nixos ]]; then
    profiles=$root/nix/var/nix/profiles
    next=$(awk '$1 == "a3-next" {print $2}' "$root/var/lib/bench/generations")
    [[ -n $next && -d $root$next ]] || { echo "break.sh: no a3-next generation in the base" >&2; exit 1; }
    new=$(( $(nixos_generation "$root") + 1 ))
    initrd=$(nixos_efi_name "$root" "$next/initrd")
    [[ ! -e $esp$initrd ]] || { echo "break.sh: a3-next's initrd is already on the ESP" >&2; exit 1; }
    src=$(root_path "$root" "$next/initrd")
    (( $(avail) < $(stat -c %s "$src") )) || { echo "break.sh: a3-next's initrd fits the ESP ($(avail) bytes free)" >&2; exit 1; }
    ln -s "$next" "$profiles/system-$new-link"
    ln -sfn "system-$new-link" "$profiles/system"
    cat "$src" > "$esp$initrd$(tr -dc a-z0-9 < /dev/urandom | head -c 8).tmp." 2> /dev/null || true
    (( $(avail) < 1048576 )) || { echo "break.sh: the ESP still has $(avail) bytes free" >&2; exit 1; }
    exit 0
fi

mid=$(< "$root/etc/machine-id")
kver=$(kver "$root")
cur=$(esp_kernel_dir "$root")
entries=$esp/loader/entries
[[ -s $cur/linux && -s $cur/initrd ]] || { echo "break.sh: no boot files at ${cur#"$root"}" >&2; exit 1; }

size=$(( $(stat -c %s "$cur/linux") + $(stat -c %s "$cur/initrd") ))
# Older kernels, newest first, while another one fits.
n=0 oldest=''
for old in 7.1.{12,11,10,9,8,7,6,5,4,3,2,1}-arch1-1 7.0.{9,8,7,6,5,4,3,2,1}-arch1-1; do
    (( $(avail) > size + 1048576 )) || break
    mkdir -p "$esp/$mid/$old"
    cp "$cur/linux" "$cur/initrd" "$esp/$mid/$old/"
    sed "/^sort-key/!s/$kver/$old/g" "$entries/$mid-$kver.conf" > "$entries/$mid-$old.conf"
    n=$((n + 1)) oldest=$old
done
(( n >= 3 )) || { echo "break.sh: room for only $n stale kernels" >&2; exit 1; }
# The update rewrote the current initramfs and stopped a third of the way in,
# when the ESP was full; the oldest kernel's fallback image takes the rest.
part=$(( $(stat -c %s "$cur/initrd") / 3 ))
rm -f "$cur/initrd"
head -c "$(( $(avail) - part - 262144 ))" /dev/urandom > "$esp/$mid/$oldest/initrd-fallback"
head -c "$part" "$esp/$mid/$oldest/initrd" > "$cur/initrd"
(( $(avail) < 1048576 )) || { echo "break.sh: the ESP still has $(avail) bytes free" >&2; exit 1; }
pacman_log "$root" "[ALPM] upgraded linux ($kver)" "[ALPM] transaction completed" "[ALPM] running '90-kernel-install.hook'..." \
    "[ALPM-SCRIPTLET] Running kernel-install for $kver" "[ALPM-SCRIPTLET] dracut[F]: Creation of $BASE_ESP/$mid/$kver/initrd failed" \
    "[ALPM-SCRIPTLET] cp: error writing '$BASE_ESP/$mid/$kver/initrd': No space left on device"
