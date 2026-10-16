#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# Build or reuse a cached base image for the scenario bench: a
# real install with a BOOT-OK serial unit, booted once so that, like an
# installed machine, its boot loader is registered in the firmware. It is kept
# as ~/.cache/system-rescuer/bases/<base>-<recipe>.img, with .vars.fd (the
# OVMF variables of that first boot) and .json (sha256s, build date and recipe
# hash) beside it, owned by the invoking user; <recipe> is the start of the
# recipe hash. A changed recipe builds beside the old one rather than over it,
# because runs from a frozen tree with the old recipe may still have overlays
# on it (and an encrypted base's passphrase changes with each build); remove
# old builds by hand when no run uses them. A base whose sha256 no longer
# matches is refused, because something wrote to it instead of to an overlay.
# Scenario runs use a copy-on-write overlay of the base (base_overlay in
# tests/bench/lib.sh). The image's path is the last line on stdout; its
# variables are beside it.
#
#   sudo tests/base-image.sh arch-sdboot             # build once, then reuse
#   tests/base-image.sh arch-sdboot                  # reuse only; no root needed
#   sudo tests/base-image.sh arch-sdboot --rebuild   # build it again
#   sudo tests/base-image.sh arch-sdboot --boot      # also boot an overlay to BOOT-OK
#
# A base is tests/bases/<base>.sh, which tests/bench/lib.sh's base_load
# sources (so it only defines). It sets
#
#   base_summary    one line for this help;
#   base_esp        where the installed system mounts its ESP (/boot, /efi);
#   base_initramfs  what builds its initramfs (mkinitcpio, dracut, ...);
#   base_loader     its boot loader (systemd-boot, grub);
#   base_luks       1 when its root is encrypted: each build makes a passphrase;
#   base_recipe     the functions base_build calls, for the recipe hash;
#
# and defines base_build <image> [passphrase-file], which builds the disk
# into the image as root with the steps lib.sh shares (disk_create,
# luks_create, bench_mount, run_logged, finish_root). Its hostname is the
# base's name, which its BOOT-OK marker prints, and its first boot (lib.sh's
# install_first_boot_unit) registers its boot loader. tests/scenario.sh hands
# the facts to break scripts as BASE_ESP, BASE_INITRAMFS and BASE_LOADER.
set -euo pipefail
# shellcheck source=bench/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/bench/lib.sh"
bench_init base-image

note() { printf 'base-image: %s\n' "$*" >&2; }
usage="usage: tests/base-image.sh <base> [--rebuild] [--boot]; bases: $(base_names | paste -sd' ')"
base='' rebuild='' boot=''
for arg; do
    case $arg in
        --rebuild) rebuild=1 ;;
        --boot) boot=1 ;;
        -*) fail "unknown option $arg; $usage" ;;
        *) [[ -z $base ]] || fail "$usage"; base=$arg ;;
    esac
done

[[ -n $base ]] || fail "$usage"
base_load "$base"

# The recipe hash covers base_build, the functions it names and the shared
# steps. An encrypted base keeps its LUKS passphrase beside it as
# .passphrase (0600, a new one for each build), which the bench types at its
# console and gives the stand-in owner; it is test data, never a real secret,
# but it stays out of argv and of every run's record all the same.
bases=$bench_cache/bases
recipe_hash=$(declare -f base_build "${base_recipe[@]}" "${build_recipe[@]}" | sha256sum | cut -d' ' -f1)
stem=$bases/$base-${recipe_hash:0:12}
img=$stem.img meta=$stem.json vars=$stem.vars.fd passfile=${base_luks:+$stem.passphrase}
bench_user_dir "$bases"
lock=$bases/$base.lock
[[ -e $lock ]] || { : > "$lock"; chown "$bench_user:" "$lock" 2>/dev/null || true; }
exec 9< "$lock"
flock 9  # one builder per base; concurrent runs wait for it

build=$rebuild
if [[ -z $build && -f $img && -f $vars && -f $meta && ( -z $passfile || -s $passfile ) && $(jq -r .recipe "$meta") == "$recipe_hash" ]]; then
    [[ $(file_sha "$img") == "$(jq -r .sha256 "$meta")" && $(file_sha "$vars") == "$(jq -r .vars_sha256 "$meta")" ]] \
        || fail "$img no longer matches its recorded sha256 (written to instead of an overlay?); refusing to reuse it: sudo tests/base-image.sh $base --rebuild"
    note "reusing $base, built $(jq -r .built "$meta"), sha256 verified"
elif [[ -z $build ]]; then
    build=1
    note "$base is not built yet for this recipe; building it"
fi

if [[ -n $build ]]; then
    [[ $EUID -eq 0 ]] || fail "building $base needs root: sudo tests/base-image.sh $base"
    part=$img.part
    remove_part() { rm -f -- "$part" "$vars.part" "$meta.part" ${passfile:+"$passfile.part"}; }
    bench_exit_hooks+=(remove_part)
    rm -f -- "$part"
    start=$SECONDS
    # No newline: cryptsetup's --key-file uses every byte.
    [[ -z $passfile ]] || ( umask 077; head -c 18 /dev/urandom | base64 | tr -d '/+=\n' > "$passfile.part" )
    base_build "$part" ${passfile:+"$passfile.part"}
    first_boot "$part" "$vars.part" ${passfile:+"$passfile.part"}
    jq -n --arg base "$base" --arg sha "$(file_sha "$part")" --arg built "$(date -u +%FT%TZ)" \
        --arg vars "$(file_sha "$vars.part")" \
        --arg recipe "$recipe_hash" --argjson bytes "$(stat -c %s "$part")" \
        '{base: $base, sha256: $sha, vars_sha256: $vars, built: $built, recipe: $recipe, bytes: $bytes}' > "$meta.part"
    chown "$bench_user:" "$part" "$vars.part" "$meta.part" ${passfile:+"$passfile.part"}
    [[ -z $passfile ]] || mv -f -- "$passfile.part" "$passfile"
    mv -f -- "$part" "$img"
    mv -f -- "$vars.part" "$vars"
    mv -f -- "$meta.part" "$meta"
    note "built $base in $((SECONDS - start)) s"
fi

if [[ -n $boot ]]; then
    runs=$bench_cache/runs
    bench_user_dir "$runs"
    overlay=$runs/$base-boot-$$.img
    base_overlay "$img" "$overlay"
    cp "$vars" "$bench_tmp/vars.fd"
    mapfile -t disk < <(ahci_disk "$overlay")
    start=$SECONDS
    boot_wait "$bench_tmp/vars.fd" "$bench_tmp/serial.log" "$passfile" "^BOOT-OK $base" 180 "${disk[@]}" \
        || fail "an overlay of $base reached no BOOT-OK within 180 s; serial tail: $(serial_tail "$bench_tmp/serial.log")"
    pass "an overlay of $base booted alone to BOOT-OK after $((SECONDS - start)) s"
    stop_qemu
    overlay_remove "$overlay"
    [[ $(file_sha "$img") == "$(jq -r .sha256 "$meta")" ]] || fail "booting the overlay changed the base"
    pass "the base is unchanged after the overlay's boot"
fi
printf '%s\n' "$img"
