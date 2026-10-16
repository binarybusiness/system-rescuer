#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# Build the system-rescuer ISO into out/.
#
#   sudo ./build.sh                             # key as the configuration says
#   <key source> | sudo ./build.sh --key-stdin  # key from stdin
#   ... --config <dir>                          # the configuration in <dir>
#   ... --out-dir <dir>                         # the ISO into <dir> instead of out/
#   ... --overlay <dir>                         # copy <dir> over the image's root
#   ... --no-offline-repo                       # leave out the offline package repository
#   ... --no-key                                # no API key in the image: tty1 asks for it at boot
#   ... --repo-asset                            # the offline repository as its own file, not in the image
#
# A test-only ISO is this build with its own --out-dir, so the shipping image
# is never overwritten by it: the bench's rejected-key scenario (C2) pipes in a
# deliberately invalid key, and its no-DHCP scenario (C6) adds an --overlay
# from tests/bench/. The shipping image is built with neither.
#
# --no-key skips reading and checking the key (everything else is the same)
# and leaves <iso>.key-at-boot beside the ISO, which tells the bench to type
# the key at the boot prompt (rescue-agent). --repo-asset likewise leaves
# <iso>.repo-asset: the image holds no repository, so a boot with no asset past
# it is online only on purpose (tests/qemu-boot.sh).
#
# The offline package repository (profile/offline-repo.x86_64) goes on the
# ISO's file system as /rescue-repo, outside the root image, so neither the
# root image nor the RAM copy archiso may make of it grows; the live system
# finds it at /run/rescue-repo (rescue-repo). Its packages are downloaded once
# into $RESCUE_REPO_CACHE (default /var/cache/system-rescuer/pkg) and copied
# from there.
#
# --repo-asset builds the image without /rescue-repo and writes the repository
# beside it as <iso minus .iso>-repo.img, with its .sha256: a read-only ISO 9660
# file system holding /rescue-repo, whose volume set id names the image it
# belongs to (rescue-repo-for=<the image's volume UUID>). GitHub caps a release
# asset at 2 GiB, which the image with the repository inside exceeds; install.sh
# --prebuilt writes the asset past the image (lib/rescue-stick.sh) and
# rescue-repo serves it. Both files must stay under 1.9 GiB.
#
# The configuration (lib/rescue-config.sh; examples/config/ is an example)
# lives outside the repository, in ~/.config/system-rescuer/ of the invoking
# user unless --config names another directory. It gives the SSH keys the
# stick accepts (authorized_keys), the machine profiles (machines/) and where
# the API key comes from (rescue.conf's key_file or key_command, read as the
# invoking user, or --key-stdin). Its provider_* names say which
# OpenAI-compatible model API the image talks to (default DeepSeek V4.1
# Flash); they go into the image once, as /etc/rescue/provider.conf, and the
# model's id beside the ISO as <iso>.model.
#
# The API key travels only through a pipe into a root-only file in a
# private build tree, which is deleted on exit. It is never printed, never on
# a command line and never in the repository.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/rescue-config.sh
. "$here/lib/rescue-config.sh"
# shellcheck source=profile/airootfs/usr/local/lib/rescue-iso9660.sh
. "$here/profile/airootfs/usr/local/lib/rescue-iso9660.sh"
# shellcheck source=profile/airootfs/usr/local/lib/rescue-paths.sh
. "$here/profile/airootfs/usr/local/lib/rescue-paths.sh"
profile_src="$here/profile"
out_dir="$here/out"
build_root=${RESCUE_BUILD_ROOT:-/var/tmp/system-rescuer-build}
key_rel=${rescue_image_key#/}

die() { printf 'build.sh: %s\n' "$*" >&2; exit 1; }

key_from_stdin=0
no_key=0
overlay=''
offline_repo=1
repo_asset=0
config=''
usage="usage: sudo ./build.sh [--key-stdin] [--config <dir>] [--out-dir <dir>] [--overlay <dir>] [--no-offline-repo] [--no-key] [--repo-asset]"
while (( $# )); do
    case $1 in
        --key-stdin) key_from_stdin=1 ;;
        --config) config=${2:?$usage}; shift ;;
        --out-dir) out_dir=$(realpath -m "${2:?$usage}"); shift ;;
        --overlay) overlay=$(realpath -e "${2:?$usage}") || die "no overlay directory $2"; shift ;;
        --no-offline-repo) offline_repo=0 ;;
        --no-key) no_key=1 ;;
        --repo-asset) repo_asset=1 ;;
        *) die "$usage" ;;
    esac
    shift
done

(( ! repo_asset || offline_repo )) || die "--repo-asset and --no-offline-repo exclude each other"
[[ $EUID -eq 0 ]] || die "run as root (sudo ./build.sh)"
command -v mkarchiso >/dev/null || die "mkarchiso missing: pacman -S archiso"
command -v gitleaks >/dev/null || die "gitleaks missing"
command -v xorriso >/dev/null || die "xorriso missing: pacman -S libisoburn"
for f in AGENTS.md playbooks.md toolkit.md machines/README.md; do
    [[ -s $profile_src/airootfs/root/rescue/$f ]] || die "missing profile/airootfs/root/rescue/$f"
done
config=$(rescue_config_dir "$config")
[[ -d $config ]] || die "no configuration at $config: copy examples/config/ there, or pass --config <dir>"

# Never delete a tree that still has pacstrap's bind mounts (/dev, /proc ...).
remove_build_root() {
    [[ -e $build_root ]] || return 0
    if findmnt -rn -o TARGET | grep -q "^$build_root/"; then
        printf 'build.sh: mounts remain under %s; not deleting it\n' "$build_root" >&2
        return 1
    fi
    rm -rf --one-file-system -- "$build_root"
}
trap remove_build_root EXIT
remove_build_root || die "clean up the mounts under $build_root first"
install -d -m 700 "$build_root"
cp -a "$profile_src" "$build_root/profile"
airootfs="$build_root/profile/airootfs"
if [[ -n $overlay ]]; then
    [[ -d $overlay ]] || die "the overlay $overlay is not a directory"
    cp -a "$overlay/." "$airootfs/"
fi

# The configuration's SSH keys and machine profiles.
# profiledef.sh sets the file's mode, so it always exists: empty, with no
# configured keys (a record past the image can add one at boot).
install -d -m 700 "$airootfs/root/.ssh"
if [[ -s $config/authorized_keys ]]; then
    install -m 600 "$config/authorized_keys" "$airootfs/root/.ssh/authorized_keys"
else
    install -m 600 /dev/null "$airootfs/root/.ssh/authorized_keys"
    printf 'build.sh: no %s/authorized_keys: the stick takes no SSH login\n' "$config" >&2
fi
if [[ -d $config/machines ]]; then
    for dir in "$config"/machines/*/; do
        [[ -d $dir ]] || continue   # an empty machines/
        [[ -s $dir/match ]] || die "machine profile $dir has no match file"
        cp -rL -- "${dir%/}" "$airootfs/root/rescue/machines/"
    done
    chown -R 0:0 "$airootfs/root/rescue/machines"
fi

# The model provider: validated, then written into the image (and into
# opencode.json) once.
provider_model=$build_root/provider-model
rescue_provider_write "$config" "$airootfs" "$provider_model" > "$build_root/provider.err" 2>&1 \
    || die "$(cat "$build_root/provider.err")"

# The profile, with the configuration's machine profiles and their copied
# configuration, must be free of secrets before the key is added to the
# build tree.
gitleaks dir --redact --no-banner --log-level error "$build_root/profile" \
    || die "gitleaks found secret material in the profile or the configuration"

# Fast mirrors for the build only; the host's mirrorlist is left alone.
mirrorlist="$build_root/mirrorlist"
read -r -a mirrors <<< "${RESCUE_MIRRORS:-https://ftp.fau.de/archlinux https://ftp.halifax.rwth-aachen.de/archlinux https://mirrors.dotsrc.org/archlinux https://geo.mirror.pkgbuild.com}"
# shellcheck disable=SC2016  # $repo and $arch are pacman's variables
printf 'Server = %s/$repo/os/$arch\n' "${mirrors[@]}" > "$mirrorlist"
sed -i "s|^Include = /etc/pacman.d/mirrorlist|Include = $mirrorlist|" "$build_root/profile/pacman.conf"

# The key: stdin when piped, otherwise the configuration's key_file or
# key_command, read or run as the invoking user, never as root.
install -d -m 700 "$airootfs/root/.config" "$airootfs/$rescue_image_key_dir"
key_file="$airootfs/$key_rel"
if (( no_key )); then
    (( ! key_from_stdin )) || die "--no-key and --key-stdin exclude each other"
else
    (
        umask 077
        if (( key_from_stdin )); then
            cat > "$key_file"
        else
            rc=0
            rescue_api_key "$config" > "$key_file" || rc=$?
            (( rc != 2 )) || die "no API key: pipe it with --key-stdin, or set key_file or key_command in $config/rescue.conf (or --no-key)"
            (( rc == 0 )) || die "reading the API key (key_file or key_command in $config/rescue.conf) failed"
        fi
    )
    chmod 600 "$key_file"
    # Validate the shape without printing anything derived from the key.
    key_check=$(rescue_provider_check_key "$config" "$key_file") || die "$key_check"
    tr -d '\n' < "$key_file" > "$key_file.tmp" && mv -f "$key_file.tmp" "$key_file" && chmod 600 "$key_file"
fi

install -d -m 755 "$out_dir"
log="$out_dir/build.log"
printf 'build.sh: building with mkarchiso; log in %s\n' "$log"
# mkarchiso writes into the private build root (mode 700), and the ISO, which
# carries the key, reaches out/ only after the leak check and the chmod: if
# this script dies and a detached mkarchiso finishes, nothing lands in out/.
mkarchiso -v -r -w "$build_root/work" -o "$build_root/iso" "$build_root/profile" > "$log" 2>&1 \
    || { tail -n 40 "$log" >&2; die "mkarchiso failed"; }

# Leak check: the key must appear nowhere outside its root-only file.
if (( ! no_key )); then
    leaks=$(grep -rlF -f "$key_file" "$here" --exclude-dir=.git --exclude='*.iso' 2>/dev/null || true)
    [[ -z $leaks ]] || die "key material found in: $leaks"
fi

built=$(find "$build_root/iso" -maxdepth 1 -name 'system-rescuer-*.iso' -print -quit)
[[ -n $built ]] || die "mkarchiso produced no ISO"

if (( offline_repo )); then
    printf 'build.sh: adding the offline package repository\n'
    repo_cache=${RESCUE_REPO_CACHE:-/var/cache/system-rescuer/pkg}
    repo_db=$build_root/repo-db repo_dir=$build_root/rescue-repo
    install -d -m 755 "$repo_cache" "$repo_dir"
    install -d -m 700 "$repo_db"
    mapfile -t repo_pkgs < <(grep -v -e '^#' -e '^$' "$profile_src/offline-repo.x86_64")
    # An empty package database, so every dependency is downloaded too.
    repo_pacman=(pacman --config "$build_root/profile/pacman.conf" --dbpath "$repo_db" --cachedir "$repo_cache" --noconfirm)
    "${repo_pacman[@]}" -Sy >> "$log" 2>&1 || { tail -n 20 "$log" >&2; die "could not sync the package databases"; }
    mapfile -t repo_files < <("${repo_pacman[@]}" -Sp --print-format '%f' "${repo_pkgs[@]}")
    (( ${#repo_files[@]} )) || die "the offline repository's package list resolved to nothing"
    # The build host's own pacman cache already holds most of them.
    host_cache=$(pacman-conf CacheDir 2>/dev/null | head -n 1)
    for f in "${repo_files[@]}"; do
        [[ -n $host_cache && ! -f $repo_cache/$f && -f $host_cache/$f ]] || continue
        cp "$host_cache/$f" "$repo_cache/"
        [[ ! -f $host_cache/$f.sig ]] || cp "$host_cache/$f.sig" "$repo_cache/"
    done
    "${repo_pacman[@]}" -Sw "${repo_pkgs[@]}" >> "$log" 2>&1 \
        || { tail -n 20 "$log" >&2; die "could not download the offline repository's packages"; }
    for f in "${repo_files[@]}"; do
        [[ -f $repo_cache/$f ]] || die "$f is not in $repo_cache"
        cp "$repo_cache/$f" "$repo_dir/"
        [[ ! -f $repo_cache/$f.sig ]] || cp "$repo_cache/$f.sig" "$repo_dir/"
    done
    repo-add -q --include-sigs "$repo_dir/rescue.db.tar.zst" "${repo_files[@]/#/$repo_dir/}" >> "$log" 2>&1 \
        || die "repo-add failed"
    if (( repo_asset )); then
        # The image's volume UUID is its primary volume descriptor's
        # modification date; the asset names it in its volume set id.
        image_uuid=$(rescue_volume_uuid "$built") || die "the image has no volume UUID"
        asset_tmp=$build_root/rescue-repo.img
        xorriso -outdev "$asset_tmp" -volid RESCUE_REPO -volset_id "rescue-repo-for=$image_uuid" \
            -map "$repo_dir" /rescue-repo -commit -end >> "$log" 2>&1 \
            || { tail -n 20 "$log" >&2; die "xorriso could not build the repository asset"; }
    else
        # The boot records are replayed as mkarchiso wrote them; the ISO keeps
        # its UUID, by which archiso finds its root image.
        xorriso -indev "$built" -outdev "$built.repo" -boot_image any replay -map "$repo_dir" /rescue-repo >> "$log" 2>&1 \
            || { tail -n 20 "$log" >&2; die "xorriso could not add the offline repository"; }
        mv -f -- "$built.repo" "$built"
    fi
    printf 'build.sh: offline repository of %d packages, %s\n' "${#repo_files[@]}" "$(du -sh "$repo_dir" | cut -f1)"
fi
# GitHub's cap on a release asset is 2 GiB; keep both files well under it.
if (( repo_asset )); then
    limit=$(( 1900 * 1048576 ))
    for f in "$built" "$asset_tmp"; do
        (( $(stat -c %s "$f") < limit )) || die "$(basename "$f") is $(stat -c %s "$f") bytes; the limit is 1.9 GiB ($limit)"
    done
fi
# A keyed ISO carries the key inside its root image: owner-only, like the key
# file (a no-key one gets the same mode, so the two are handled alike).
chmod 600 "$built"
if [[ -n ${SUDO_USER:-} ]]; then chown "$SUDO_USER:" "$built"; fi
iso="$out_dir/$(basename "$built")"
mv -f -- "$built" "$iso"
( cd "$out_dir" && sha256sum "$(basename "$iso")" > "$(basename "$iso").sha256" )
if (( repo_asset )); then
    asset_out=${iso%.iso}-repo.img
    mv -f -- "$asset_tmp" "$asset_out"
    chmod 644 "$asset_out"
    ( cd "$out_dir" && sha256sum "$(basename "$asset_out")" > "$(basename "$asset_out").sha256" )
    printf 'build.sh: the image is %d bytes and the repository asset %d bytes (each under 1.9 GiB)\n' \
        "$(stat -c %s "$iso")" "$(stat -c %s "$asset_out")"
fi
# The model this image was built with, for the bench's model oracle.
cp -- "$provider_model" "$iso.model"
rm -f -- "$iso.key-at-boot" "$iso.repo-asset"
(( ! repo_asset )) || : > "$iso.repo-asset"
(( ! no_key )) || : > "$iso.key-at-boot"
if [[ -n ${SUDO_USER:-} ]]; then chown -R "$SUDO_USER:" "$out_dir"; fi
printf 'build.sh: built %s\n' "$iso"
