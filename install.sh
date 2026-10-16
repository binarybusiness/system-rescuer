#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# Build the system-rescuer ISO from a clone, on any x86_64 Linux host.
#
#   ./install.sh [/dev/sdX]                   # build, then write the stick
#   ./install.sh --iso <file> [/dev/sdX]      # write an ISO that is already built
#   ./install.sh --dry-run [...]              # every check, no byte written
#   ./install.sh --build-only                 # check the host, then build into out/
#   ./install.sh --build-only --config <dir>  # the configuration in <dir>
#   ./install.sh --build-only --out-dir <dir> # the ISO into <dir> instead of out/
#   ./install.sh --build-only --no-key [--repo-asset]
#                                             # the publishable pair: a key-less image, and
#                                             # the offline repository as its own file
#   ./install.sh --check                      # the host check alone
#   ./install.sh --clean                      # remove what a build leaves behind
#   ./install.sh --wipe /dev/sdX              # zero a stick
#   ./install.sh --prebuilt [<version>] [/dev/sdX]   # a published key-less image, verified, then your key
#   ./install.sh --prebuilt --image <file> [--repo <file> | --no-repo] [...]
#                                             # a local one (<file>.sha256 and <file>.minisig beside it)
#   ./install.sh --prebuilt ... [--key-file <f>] [--ssh-key <f>] [--endpoint <url> [--key-prefix <t>]]
#                                             # the key (else asked for), an SSH key, another provider
#   ./install.sh --help
#
# The host check prints what the build needs and stops, building nothing, when
# something is missing. There are two paths: on Arch with mkarchiso, gitleaks
# and xorriso installed, build.sh runs natively under sudo; anywhere else it
# runs in a privileged archlinux container (Docker --privileged or rootful
# podman). The API key is the configuration's key_file or key_command, or a
# masked prompt, and reaches build.sh on its stdin only.
#
# A stick is written only when it is plainly a stick (lib/rescue-stick.sh):
# a whole, removable, USB-transport disk with nothing mounted, swapped or
# stacked on it, and then only after its model, serial and size are shown and
# its name is typed back. There is no way around the typed name.
#
# --prebuilt builds nothing: it downloads (or takes with --image) a key-less
# image, its .sha256 and its .minisig, checks the signature against the release
# public key pinned below and then the sha256, and only then writes the stick
# as above. It asks for the API key (--key-file, or a masked prompt on the
# terminal; never a flag's value) and writes it, and optionally an SSH public
# key (--ssh-key) and another OpenAI-compatible endpoint (--endpoint,
# --key-prefix), as a record past the image (lib/rescue-stick.sh,
# profile/airootfs/usr/local/bin/rescue-key-record), which the image reads at
# boot. The key is not encrypted on the stick; --wipe removes it.
#
# Each signature also carries a trusted comment, "file:<asset name>", a tab and
# "version:vN.N.N". After minisign verifies it, --prebuilt refuses a comment
# that names another asset than the image's or the repository asset's, one of
# another version than the one asked for (--prebuilt <version>), and an image
# and repository asset of different versions. A renamed or older signed asset
# is therefore not accepted. With "latest" or --image the version printed is
# the one to check.
#
# The offline package repository is a second, separately signed asset
# (system-rescuer-x86_64-repo.img, from build.sh --repo-asset): GitHub caps a
# release asset at 2 GiB. --prebuilt verifies it like the image (signature,
# sha256, and that it names this image's volume UUID) before the first byte is
# written, and writes it past the key record (lib/rescue-stick.sh);
# profile/airootfs/usr/local/bin/rescue-repo serves it at boot. --no-repo
# writes an online-only stick on purpose.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/rescue-config.sh
. "$here/lib/rescue-config.sh"
# shellcheck source=lib/rescue-stick.sh
. "$here/lib/rescue-stick.sh"
# shellcheck source=lib/release-layout.sh
. "$here/lib/release-layout.sh"

# The archlinux image, by digest; the derived image adds the build tools.
base_image=archlinux@sha256:3c64b538588416593f69a1aebd2f2ec0f2541b29159f32556fa7def2167147a0
derived_image=system-rescuer-build:1
pkg_volume=system-rescuer-pkg
work_volume=system-rescuer-work
# GiB each part of a build needs, by the measured size of a build plus margin.
need_build=10 need_cache=4 need_out=2


die() { printf 'install.sh: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
usage: ./install.sh [--config <dir>] [--out-dir <dir>] [--container] [/dev/sdX]
       ./install.sh --iso <file> [/dev/sdX]
       ./install.sh --build-only | --check [--config <dir>] [--out-dir <dir>] [--container]
       ./install.sh --build-only --no-key [--repo-asset] [...]
       ./install.sh --check --prebuilt
       ./install.sh --clean [--out-dir <dir>]
       ./install.sh --wipe /dev/sdX
       ./install.sh --prebuilt [<version>] [--key-file <f>] [--ssh-key <f>]
                    [--endpoint <url> [--key-prefix <text>]] [--dry-run] [/dev/sdX]
       ./install.sh --prebuilt --image <file> [--repo <file> | --no-repo] [...]

  (no mode)         check the host, build the ISO, verify its sha256, then
                    write it to a USB stick; without a device, lists the
                    candidate sticks and asks which
  /dev/sdX          the stick: a whole, removable USB disk that nothing
                    mounts, swaps or builds on; its model, serial and size
                    are shown and its name is typed back before any write
  --iso <file>      write an ISO that is already built, after checking it
                    against <file>.sha256; builds nothing
  --dry-run         run every check, the build or --iso check included, and
                    stop before the first byte is written
  --build-only      check the host, then build the ISO into out/ and verify
                    its sha256; write nothing
  --no-key          with --build-only: build the image with no API key in it
                    (what is published; tty1 asks for the key, or --prebuilt
                    writes it in a record past the image)
  --repo-asset      with --build-only: build the image without the offline
                    package repository and write that as its own file,
                    <image>-repo.img with its .sha256 (what is published,
                    because a release asset is capped at 2 GiB)
  --check           run the host check alone and build nothing
  --clean           remove the native build tree, the container volumes and
                    image and leftover scratch key files; asks before
                    removing the ISOs in the out dir (they carry the key
                    unless built with --no-key)
  --wipe /dev/sdX   zero the whole stick and read it back
  --config <dir>    the configuration (default ~/.config/system-rescuer, or
                    $RESCUE_CONFIG); when there is none, offers to copy
                    examples/config/ there
  --out-dir <dir>   put the ISO, its .sha256 and .model in <dir> (default out/)
  --container       build in a container even where the native tools exist
  --prebuilt [<v>]  download the published key-less image (default: the latest
                    release; <v> looks like v1.2.3) with its .sha256 and
                    .minisig, check the minisign signature against the pinned
                    release key, its signed file name and version, and then the
                    sha256, and only then write the stick and a record past
                    the image that holds your key; builds nothing
  --image <file>    with --prebuilt: a local image, with <file>.sha256 and
                    <file>.minisig beside it; no network
  --repo <file>     with --prebuilt --image: the offline repository asset, with
                    <file>.sha256 and <file>.minisig beside it; checked like
                    the image, and it must belong to the image
  --no-repo         with --prebuilt: write an online-only stick on purpose,
                    with no repository asset (without --repo, --image says so
                    and goes on; a download always fetches the asset)
  --key-file <f>    with --prebuilt: the file holding the API key (default: a
                    masked prompt on the terminal; never a command-line value)
  --ssh-key <f>     with --prebuilt: an SSH public key file the stick accepts
                    for root (checked with ssh-keygen -l -f; no private key)
  --endpoint <url>  with --prebuilt: another OpenAI-compatible https endpoint
                    (with its /v1) instead of the image's built-in provider
  --key-prefix <t>  with --prebuilt: what that provider's keys start with
                    (default: no check, with --endpoint); the built-in
                    provider's keys start with sk-
  --trust-key <f>   TEST ONLY, with --prebuilt: trust the minisign public key
                    in <f> instead of the pinned release key
  --base-url <url>  TEST ONLY, with --prebuilt: fetch the three files from
                    <url>/<name>, not from the release
  --help            this text

The API key comes from the configuration's key_file or key_command; with
neither, it is asked for with a prompt that shows nothing. With --prebuilt, it
is written to the stick as it is, not encrypted: whoever holds the stick holds
the key, and ./install.sh --wipe /dev/sdX removes it.
EOF
}

mode='' config='' out_dir=$here/out force_container=0 iso_arg='' dry_run=0 dev_arg=''
prebuilt=0 pb_version='' image_arg='' key_file_arg='' ssh_key_arg='' endpoint_arg='' key_prefix_arg='' key_prefix_set=0
trust_key='' base_url='' no_key=0 repo_arg='' no_repo=0 repo_asset_build=0
while (( $# )); do
    case $1 in
        --build-only) mode=build ;;
        --no-key) no_key=1 ;;
        --repo-asset) repo_asset_build=1 ;;
        --repo) repo_arg=$(realpath -m -- "${2:?$(usage)}"); shift ;;
        --no-repo) no_repo=1 ;;
        --check) mode=check ;;
        --config) config=${2:?$(usage)}; shift ;;
        --out-dir) out_dir=$(realpath -m -- "${2:?$(usage)}"); shift ;;
        --container) force_container=1 ;;
        --help|-h) usage; exit 0 ;;
        --iso) iso_arg=$(realpath -m -- "${2:?$(usage)}"); shift ;;
        --dry-run) dry_run=1 ;;
        --clean) mode=clean ;;
        --wipe) mode=wipe; dev_arg=${2:?$(usage)}; shift ;;
        --prebuilt)
            prebuilt=1
            if [[ ${2:-} =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
                pb_version=$2; shift
                [[ $pb_version =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
                    || die "--prebuilt <version> must look like v1.2.3, not $pb_version; nothing was written"
            fi ;;
        --image) image_arg=$(realpath -m -- "${2:?$(usage)}"); shift ;;
        --key-file) key_file_arg=$(realpath -m -- "${2:?$(usage)}"); shift ;;
        --ssh-key) ssh_key_arg=$(realpath -m -- "${2:?$(usage)}"); shift ;;
        --endpoint) endpoint_arg=${2:?$(usage)}; shift ;;
        --key-prefix) key_prefix_arg=${2?$(usage)}; key_prefix_set=1; shift ;;
        --trust-key) trust_key=$(realpath -m -- "${2:?$(usage)}"); shift ;;
        --base-url) base_url=${2:?$(usage)}; shift ;;
        /dev/*) [[ -z $dev_arg ]] || die "one device only"; dev_arg=$1 ;;
        *) usage >&2; exit 1 ;;
    esac
    shift
done
[[ $no_key == 0 || $mode == build ]] || die "--no-key (a key-less image, for publishing) goes with --build-only"
[[ $repo_asset_build == 0 || $mode == build ]] || die "--repo-asset (the repository as its own file) goes with --build-only"
[[ -z $repo_arg || $no_repo == 0 ]] || die "--repo and --no-repo exclude each other"
if (( prebuilt )); then
    [[ -z $repo_arg || -n $image_arg ]] || die "--repo goes with --image: a download fetches the repository asset by itself"
    [[ -z $mode || $mode == check ]] || die "--prebuilt takes no --$mode"
    [[ -z $iso_arg && -z $config && $force_container == 0 ]] || die "--prebuilt builds nothing: it takes no --iso, --config or --container"
    [[ -z $image_arg || -z $pb_version ]] || die "--image and a version exclude each other"
    [[ -z $image_arg || -z $base_url ]] || die "--image and --base-url exclude each other"
    [[ -n $mode ]] || mode=prebuilt
else
    [[ -z $image_arg$key_file_arg$ssh_key_arg$endpoint_arg$key_prefix_arg$trust_key$base_url$repo_arg && $no_repo == 0 ]] \
        || die "--image, --repo, --no-repo, --key-file, --ssh-key, --endpoint, --key-prefix, --trust-key and --base-url belong to --prebuilt"
fi
if [[ -z $mode ]]; then
    mode="write"
    [[ -z $iso_arg ]] || mode=iso
fi
[[ -z $iso_arg || $mode == iso ]] || die "--iso writes a built ISO; it does not combine with --$mode"
if [[ $mode == check || $mode == build || $mode == clean ]] && [[ -n $dev_arg || $dry_run == 1 ]]; then
    die "--$mode takes no device and no --dry-run"
fi

sudo=()
(( EUID == 0 )) || sudo=(sudo)

# ask <prompt>: one line from the terminal, never from stdin or a flag.
ask() {
    ( : < /dev/tty ) 2> /dev/null || die "there is no terminal to ask on"
    local answer=''
    printf '%s' "$1" > /dev/tty
    read -r answer < /dev/tty || answer=''
    printf '%s' "$answer"
}

# stick_as_root <function> <args...>: a function of lib/rescue-stick.sh, as root.
stick_as_root() {
    # shellcheck disable=SC2016  # the root shell expands these
    "${sudo[@]}" bash -c '. "$1/lib/rescue-stick.sh"; shift; "$@"' _ "$here" "$@"
}

# precheck_device <dev>: a named device that can never be written stops here,
# before a build or a download (a desktop auto-mount is dealt with later).
precheck_device() {
    local rc=0
    [[ -b $1 ]] || die "$1 is not a block device"
    stick_refusal "$(basename "$(readlink -f -- "$1")")" 0 || rc=$?
    (( rc == 0 || rc == 3 )) || die "refusing $1: $STICK_REASON"
}

# prompt_key <file> <message when there is no terminal>: the API key, typed on
# the terminal with nothing shown, into <file> (mode 600 by the umask).
prompt_key() {
    local apikey
    ( : < /dev/tty ) 2> /dev/null || die "$2"
    printf 'API key (typed text is not shown): ' > /dev/tty
    ( umask 077; IFS= read -rs apikey < /dev/tty && printf '%s' "$apikey" > "$1" ) || die "no API key entered"
    printf '\n' > /dev/tty
}

# find_runtime: set rt (a command prefix), rt_name and runtime_problem to a
# container runtime that is privileged and usable by this user, if any.
find_runtime() {
    local cand cmd
    rt=() rt_name='' runtime_problem=''
    for cand in docker podman; do
        command -v "$cand" > /dev/null || continue
        cmd=("$cand")
        if ! "$cand" info > /dev/null 2>&1; then
            if sudo -n "$cand" info > /dev/null 2>&1; then cmd=(sudo -n "$cand")
            else runtime_problem="$cand is installed but its daemon or this user's access to it does not work (try: sudo usermod -aG $cand $USER, then log in again)"; continue
            fi
        fi
        if [[ $cand == podman ]]; then
            if [[ $("${cmd[@]}" info --format '{{.Host.Security.Rootless}}' 2>/dev/null) == true ]]; then
                runtime_problem="rootless podman cannot bind-mount /dev and /proc for pacstrap; use rootful podman (sudo) or Docker"
                continue
            fi
        elif "${cmd[@]}" info --format '{{.SecurityOptions}}' 2>/dev/null | grep -q rootless; then
            runtime_problem="rootless Docker cannot run a --privileged mkarchiso; use the rootful daemon"
            continue
        fi
        rt=("${cmd[@]}") rt_name=$cand runtime_problem=''
        return 0
    done
    return 1
}

# run_clean: remove what a build leaves behind, and say what.
run_clean() {
    local tree=${RESCUE_BUILD_ROOT:-/var/tmp/system-rescuer-build} d f v found=0 isos=() ans
    printf 'Cleaning:\n'
    if [[ -e $tree && $tree == /?*/* ]]; then
        "${sudo[@]}" rm -rf -- "$tree" && printf '  removed the build tree %s\n' "$tree"
        found=1
    fi
    if find_runtime; then
        for v in "$work_volume" "$pkg_volume"; do
            if "${rt[@]}" volume inspect "$v" > /dev/null 2>&1; then
                "${rt[@]}" volume rm -f "$v" > /dev/null && printf '  removed the %s volume %s\n' "$rt_name" "$v"
                found=1
            fi
        done
        if "${rt[@]}" image inspect "$derived_image" > /dev/null 2>&1; then
            "${rt[@]}" image rm -f "$derived_image" > /dev/null && printf '  removed the %s image %s\n' "$rt_name" "$derived_image"
            found=1
        fi
    else
        printf '  no container runtime: no volumes or image to remove\n'
    fi
    for d in "${XDG_RUNTIME_DIR:-}" "${TMPDIR:-}" /tmp; do
        [[ -n $d && -d $d ]] || continue
        for f in "$d"/rescue-install.*; do
            [[ -e $f ]] || continue
            rm -rf -- "$f" && printf '  removed the scratch key directory %s\n' "$f"
            found=1
        done
    done
    (( found )) || printf '  nothing to remove\n'
    for f in "$out_dir"/system-rescuer-*.iso; do
        [[ -e $f ]] && isos+=("$f")
    done
    if (( ${#isos[@]} )); then
        printf 'ISOs in %s:\n' "$out_dir"
        for f in "${isos[@]}"; do
            if [[ -e $f.key-at-boot ]]; then printf '  %s (built with --no-key)\n' "$f"
            else printf '  %s (may carry the API key)\n' "$f"
            fi
        done
        ans=$(ask "Remove these ISOs? Each may carry the API key unless it was built with --no-key. [y/N] ")
        if [[ $ans == [yY]* ]]; then
            for f in "${isos[@]}"; do
                rm -f -- "$f" "$f.sha256" "$f.model" "$f.key-at-boot" "$f.repo-asset" "${f%.iso}-repo.img" "${f%.iso}-repo.img.sha256"
                printf '  removed %s\n' "$f"
            done
        else
            printf '  kept the ISOs\n'
        fi
    fi
}

# vet_device <dev> <iso-bytes>: set name to the whole disk behind <dev> once
# every refusal passes; a desktop auto-mount is unmounted when the user says so.
vet_device() {
    local dev=$1 iso_size=$2 rc=0 ans mp
    [[ -b $dev ]] || die "$dev is not a block device"
    name=$(basename "$(readlink -f -- "$dev")")
    stick_refusal "$name" "$iso_size" || rc=$?
    if (( rc == 3 )); then
        printf '/dev/%s: %s\n' "$name" "$STICK_REASON"
        ans=$(ask "Unmount ${STICK_AUTOMOUNTS[*]}? [y/N] ")
        [[ $ans == [yY]* ]] || die "refusing /dev/$name: $STICK_REASON"
        for mp in "${STICK_AUTOMOUNTS[@]}"; do
            "${sudo[@]}" umount -- "$mp" || die "could not unmount $mp"
        done
        rc=0
        stick_refusal "$name" "$iso_size" || rc=$?
    fi
    (( rc == 0 )) || die "refusing /dev/$name: $STICK_REASON"
}

# pick_device <iso-bytes>: list the disks that pass every refusal and ask which.
pick_device() {
    local n rc cands=() answer
    while read -r n; do
        rc=0
        stick_refusal "$n" "$1" || rc=$?
        (( rc == 0 || rc == 3 )) && cands+=("$n")
    done < <(lsblk -dno NAME)
    (( ${#cands[@]} )) || die "no disk here is plainly a USB stick (whole, removable, USB, nothing mounted or stacked on it, big enough); plug one in"
    printf 'Candidate sticks:\n' >&2
    for n in "${cands[@]}"; do
        printf '  /dev/%s  %s  %s  serial %s\n' "$n" "$(stick_attr MODEL "$n")" "$(stick_attr SIZE "$n")" "$(stick_attr SERIAL "$n")" >&2
    done
    answer=$(ask "Which device? (for example /dev/${cands[0]}) ")
    printf '%s' "${answer#/dev/}" | grep -q . || die "no device given"
    printf '/dev/%s' "${answer#/dev/}"
}

# confirm_name: show the disk and require its name typed back.
confirm_name() {
    local typed
    printf '\nThis disk will be overwritten:\n'
    stick_describe "$name"
    typed=$(ask "Type the device name ($name) to continue: ")
    [[ $typed == "$name" ]] || die "'$typed' is not '$name'; nothing was written"
}

# check_iso <file> [<what>]: the ISO (or another asset) against its .sha256.
check_iso() {
    local expected actual what=${2:-ISO}
    [[ -s $1 ]] || die "no $what at $1"
    [[ -r $1.sha256 ]] || die "no $1.sha256 beside the $what"
    printf 'checking the %s against %s.sha256 ...\n' "$what" "$(basename "$1")"
    expected=$(awk '{print $1}' "$1.sha256")
    actual=$(sha256sum -- "$1" | awk '{print $1}')
    [[ $expected == "$actual" ]] || die "sha256 mismatch: $1.sha256 says $expected, the $what is $actual"
    printf '%s: %s\nsha256: %s (matches %s.sha256)\n' "$what" "$1" "$actual" "$(basename "$1")"
}

# need_signed <file> <what> <noun>: the file, its .sha256 and its .minisig exist.
need_signed() {
    [[ -s $1 ]] || die "no $2 at $1"
    [[ -r $1.sha256 ]] || die "no $1.sha256 beside the $2"
    [[ -r $1.minisig ]] || die "no $1.minisig beside the $2: an unsigned $3 is never written"
}

# check_signature <file> <label> <what> <canonical>: the file's .minisig against
# the release key (the global pk), then the verified trusted comment, which must
# read "file:<canonical>", a tab and "version:vN.N.N" (the canonical asset name
# of its role, whatever the local file is called; with --prebuilt <version>,
# that version). Then its sha256 (check_iso). <label> names it in the refusal.
# Sets sig_version.
check_signature() {
    local file=$1 label=$2 what=$3 canonical=$4 comment want
    minisign -V "${pk[@]}" -m "$file" -x "$file.minisig" > "$scratch/minisign.out" 2>&1 \
        || die "signature check failed: $label is not signed by the release key (minisign: $(tr '\n' ' ' < "$scratch/minisign.out")); nothing was written"
    # -Q prints only the trusted comment minisign has just verified.
    comment=$(minisign -V -Q "${pk[@]}" -m "$file" -x "$file.minisig" 2> /dev/null) \
        || die "signature check failed: $label: minisign did not print its trusted comment; nothing was written"
    want=$'file:'$canonical$'\tversion:'
    if [[ $comment != "$want"* || ! ${comment#"$want"} =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        die "trusted comment mismatch: $label is signed as '${comment//$'\t'/<TAB>}', expected 'file:$canonical<TAB>version:vN.N.N'; nothing was written"
    fi
    sig_version=${comment#"$want"}
    [[ -z $pb_version || $sig_version == "$pb_version" ]] \
        || die "version mismatch: $label is signed as version $sig_version, but --prebuilt asked for $pb_version; nothing was written"
    check_iso "$file" "$what"
}

# write_stage <iso> [<record-content-file> [<repository-asset>]]: choose,
# check, identify and write the stick, the key record past the image when there
# is one, and the repository header and asset after it.
write_stage() {
    local iso_file=$1 record=${2:-} repo_file=${3:-} iso_size need dev
    iso_size=$(stat -c %s -- "$iso_file")
    need=$iso_size
    # The record sits at the next 1 MiB boundary past the image and fills one;
    # the header fills the next, and the asset follows it.
    [[ -z $record ]] || need=$(( $(stick_record_offset "$iso_size") + 1048576 ))
    [[ -z $repo_file ]] || need=$(( $(stick_record_offset "$iso_size") + 2097152 + $(stat -c %s -- "$repo_file") ))
    dev=$dev_arg
    [[ -n $dev ]] || dev=$(pick_device "$need")
    vet_device "$dev" "$need"
    if (( dry_run )); then
        printf '\nDry run: every check passed for:\n'
        stick_describe "$name"
        printf 'Stopping before the first byte is written.\n'
        return 0
    fi
    if [[ -n $record ]]; then
        printf '\nYour API key will be written to this stick as it is, past the image:\n'
        printf 'it is not encrypted, and whoever holds the stick holds the key.\n'
        printf './install.sh --wipe /dev/%s removes it.\n' "$name"
    fi
    confirm_name
    stick_as_root stick_write_image "$name" "$iso_file" \
        || die "the write did not verify; /dev/$name should not be used"
    printf 'Wrote and verified /dev/%s.\n' "$name"
    if [[ -n $record ]]; then
        stick_as_root stick_write_record "/dev/$name" "$iso_file" "$record" \
            || die "the key record did not verify; /dev/$name should not be used"
        printf 'Wrote and verified the key record past the image on /dev/%s.\n' "$name"
    fi
    if [[ -n $repo_file ]]; then
        stick_as_root stick_write_repo "/dev/$name" "$iso_file" "$repo_file" \
            || die "the repository asset did not verify; /dev/$name should not be used"
        printf 'Wrote and verified the repository header and asset past the image on /dev/%s.\n' "$name"
    fi
}

if [[ $mode == clean ]]; then
    run_clean
    exit 0
fi
if [[ $mode == wipe ]]; then
    [[ -n $dev_arg ]] || die "--wipe needs a device"
    vet_device "$dev_arg" 0
    if (( dry_run )); then
        printf 'Dry run: every check passed for /dev/%s; stopping before the first byte is written.\n' "$name"
        exit 0
    fi
    confirm_name
    stick_as_root stick_wipe "$name" \
        || die "the wipe did not complete"
    exit 0
fi
# --prebuilt: a signed key-less image, then the owner's key.
prebuilt_stage() {
    local missing=() t url_base proto iso key_f rec klen prefix line n_ssh=0 repo_file='' repo_names=() a_uuid i_uuid
    for t in minisign sha256sum lsblk; do
        command -v "$t" > /dev/null || missing+=("$t")
    done
    [[ -n $image_arg ]] || command -v curl > /dev/null || missing+=(curl)
    [[ -z $ssh_key_arg ]] || command -v ssh-keygen > /dev/null || missing+=(ssh-keygen)
    if (( ${#missing[@]} )); then
        die "--prebuilt needs ${missing[*]} on this host (minisign: apt install minisign, pacman -S minisign, dnf install minisign)"
    fi
    if [[ $mode == check ]]; then
        printf 'Host check for --prebuilt passed (minisign, sha256sum, lsblk%s).\n' "$([[ -n $image_arg ]] || printf ', curl')"
        return 0
    fi
    # The release key: pinned, or a test key named on the command line.
    if [[ -n $trust_key ]]; then
        [[ -r $trust_key ]] || die "--trust-key $trust_key is not readable"
        pk=(-p "$trust_key")
        printf 'WARNING (test only): trusting the minisign key in %s instead of the pinned release key.\n' "$trust_key" >&2
    else
        pk=(-P "$release_pubkey")
    fi
    [[ -z $dev_arg ]] || precheck_device "$dev_arg"
    # The options that need no network or terminal are checked first.
    if [[ -n $endpoint_arg ]]; then
        [[ $endpoint_arg =~ ^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~/-]*)?$ ]] \
            || die "--endpoint must be a plain https://host[:port][/path] URL (with its /v1)"
    fi
    [[ $key_prefix_arg =~ ^[A-Za-z0-9_.-]*$ ]] || die "--key-prefix has characters a key prefix does not (letters, digits, - _ .)"
    if (( key_prefix_set )) && [[ -z $endpoint_arg ]]; then
        die "--key-prefix goes with --endpoint"
    fi
    if [[ -n $ssh_key_arg ]]; then
        [[ -r $ssh_key_arg ]] || die "--ssh-key $ssh_key_arg is not readable"
        ! grep -q 'PRIVATE KEY' "$ssh_key_arg" || die "--ssh-key $ssh_key_arg holds a private key; give the public key file (.pub)"
        ssh-keygen -l -f "$ssh_key_arg" > /dev/null 2>&1 \
            || die "--ssh-key $ssh_key_arg is not an SSH public key (ssh-keygen -l -f does not accept it)"
        while IFS= read -r line || [[ -n $line ]]; do
            [[ -n ${line//[[:space:]]/} && $line != '#'* ]] || continue
            [[ $line =~ ^(ssh-|ecdsa-|sk-)[A-Za-z0-9@.-]*\ [A-Za-z0-9+/=]+(\ .*)?$ ]] \
                || die "--ssh-key $ssh_key_arg has a line that is not a plain public key line (no options before the key type)"
            n_ssh=$((n_ssh + 1))
        done < "$ssh_key_arg"
    fi

    scratch=$(umask 077; mktemp -d "${TMPDIR:-/tmp}/rescue-install.XXXXXX")
    trap 'rm -rf -- "$scratch"' EXIT
    # The image, its checksum and its signature.
    if [[ -n $image_arg ]]; then
        iso=$image_arg
        need_signed "$iso" image image
    else
        if [[ -n $base_url ]]; then url_base=${base_url%/} proto='=http,https'
        elif [[ -n $pb_version ]]; then url_base=$release_url/download/$pb_version proto='=https'
        else url_base=$release_url/latest/download proto='=https'
        fi
        iso=$scratch/$release_iso
        repo_names=()
        (( no_repo )) || { repo_names=("$release_repo.sha256" "$release_repo.minisig" "$release_repo"); repo_file=$scratch/$release_repo; }
        printf 'Downloading %s/%s and its .sha256 and .minisig (the image is about 1.7 GB%s)\n' "$url_base" "$release_iso" \
            "$( (( no_repo )) || printf '; then %s, the repository, about 0.9 GB' "$release_repo")"
        for t in "$release_iso.sha256" "$release_iso.minisig" "$release_iso" "${repo_names[@]}"; do
            curl --fail --silent --show-error --location --proto "$proto" --proto-redir "$proto" --max-redirs 5 \
                --connect-timeout 20 -o "$scratch/$t" -- "$url_base/$t" 2> "$scratch/curl.err" \
                || die "could not download $url_base/$t: $(tr '\n' ' ' < "$scratch/curl.err")"
        done
    fi
    if [[ -n $image_arg ]]; then
        if (( no_repo )); then
            printf 'No repository asset (--no-repo): the stick will work online only, on purpose.\n'
        elif [[ -n $repo_arg ]]; then
            repo_file=$repo_arg
            need_signed "$repo_file" "repository asset" asset
        else
            printf 'No --repo given: the stick will work online only (an image that carries its own repository still serves it).\n'
        fi
    fi
    check_signature "$iso" "$(basename "$iso")" ISO "$release_iso"
    version=$sig_version
    if [[ -n $repo_file ]]; then
        check_signature "$repo_file" "the repository asset $(basename "$repo_file")" "repository asset" "$release_repo"
        [[ $sig_version == "$version" ]] \
            || die "version mismatch: the image is signed as version $version, the repository asset $(basename "$repo_file") as $sig_version; nothing was written"
        a_uuid=$(stick_repo_uuid "$repo_file") || die "the repository asset $(basename "$repo_file") names no image (it is not a build.sh --repo-asset file); nothing was written"
        i_uuid=$(stick_image_uuid "$iso") || die "the image $(basename "$iso") has no volume UUID; nothing was written"
        [[ $a_uuid == "$i_uuid" ]] \
            || die "the repository asset $(basename "$repo_file") belongs to another image (it names $a_uuid, this image is $i_uuid); nothing was written"
        printf 'repository asset: signature ok, sha256 ok, belongs to this image (%s)\n' "$i_uuid"
    fi
    printf 'signature: ok (minisign, %s; version %s)\n' "$([[ -n $trust_key ]] && printf 'the --trust-key key, TEST ONLY' || printf 'the pinned release key')" "$version"

    # The owner's key and settings.
    key_f=$scratch/key
    if [[ -n $key_file_arg ]]; then
        [[ -r $key_file_arg ]] || die "--key-file $key_file_arg is not readable"
        ( umask 077; tr -d '\r\n' < "$key_file_arg" > "$key_f" ) || die "could not read --key-file"
    else
        prompt_key "$key_f" "no API key: there is no terminal to ask on; pass --key-file <file>"
    fi
    klen=$(wc -c < "$key_f")
    (( klen >= 20 )) || die "the API key is $klen characters; a key has at least 20"
    [[ -z $(tr -d 'A-Za-z0-9_.-' < "$key_f") ]] || die "the API key has characters a key does not (only letters, digits, - _ . are taken)"
    prefix=sk-
    if (( key_prefix_set )); then prefix=$key_prefix_arg
    elif [[ -n $endpoint_arg ]]; then prefix=''
    fi
    if [[ -n $prefix && $(head -c "${#prefix}" "$key_f") != "$prefix" ]]; then
        die "the API key does not start with '$prefix', as the image's provider's keys do; for another provider pass --endpoint (and --key-prefix)"
    fi
    rec=$scratch/record
    {
        printf 'key=%s\n' "$(< "$key_f")"
        if [[ -n $ssh_key_arg ]]; then
            while IFS= read -r line || [[ -n $line ]]; do
                [[ -n ${line//[[:space:]]/} && $line != '#'* ]] || continue
                printf 'ssh=%s\n' "$line"
            done < "$ssh_key_arg"
        fi
        [[ -z $endpoint_arg ]] || printf 'endpoint=%s\n' "$endpoint_arg"
        (( ! key_prefix_set )) || printf 'key_prefix=%s\n' "$key_prefix_arg"
    } > "$rec"
    printf 'record: an API key of %s characters, %s ssh key(s) added to the image'"'"'s own%s\n' "$klen" "$n_ssh" "${endpoint_arg:+, endpoint $endpoint_arg}"
    write_stage "$iso" "$rec" "$repo_file"
}

if [[ $mode == prebuilt || ( $mode == check && $prebuilt == 1 ) ]]; then
    prebuilt_stage
    exit 0
fi
if [[ $mode == iso ]]; then
    check_iso "$iso_arg"
    write_stage "$iso_arg"
    exit 0
fi
# Before an hour's build.
[[ $mode != write || -z $dev_arg ]] || precheck_device "$dev_arg"

problems=()
fail_check() { problems+=("$1"); }
line() { printf '  %-14s %s\n' "$1" "$2"; }

# nearest <path>: <path>, or its nearest existing parent.
nearest() {
    local p=$1
    while [[ ! -e $p ]]; do p=$(dirname "$p"); done
    printf '%s' "$p"
}
# df_avail_gib <path>: free GiB on the file system that holds <path>.
df_avail_gib() { df -Pk -- "$(nearest "$1")" | awk 'NR == 2 {print int($4 / 1048576)}'; }

printf 'Host check:\n'

# 1. Platform.
arch=$(uname -m)
if [[ $(uname -s) == Linux && $arch == x86_64 ]]; then
    line platform "x86_64 Linux: ok"
else
    line platform "$(uname -s) $arch: NOT ok"
    fail_check "this builds only on x86_64 Linux, not $(uname -s) $arch"
fi

# 2. The path.
native_missing=()
for tool in mkarchiso gitleaks xorriso; do
    command -v "$tool" > /dev/null || native_missing+=("$tool")
done
path='' rt=() rt_name='' runtime_problem=''
if (( ! force_container )) && (( ${#native_missing[@]} == 0 )); then
    path=native
    line path "native (mkarchiso, gitleaks and xorriso found; build.sh runs under sudo)"
else
    find_runtime || true
    if [[ -n $rt_name ]]; then
        path=container
        line path "container ($rt_name --privileged, image archlinux, pinned by digest)"
    else
        line path "NOT ok"
        if [[ -n $runtime_problem ]]; then
            fail_check "no usable container runtime: $runtime_problem"
        else
            fail_check "no container runtime (docker or podman) is installed; install Docker (Debian/Ubuntu: apt install docker.io; Fedora: dnf install docker; Arch: pacman -S docker)"
        fi
        if (( ${#native_missing[@]} )) && [[ -r /etc/arch-release ]]; then
            fail_check "or build natively: pacman -S archiso gitleaks libisoburn (missing: ${native_missing[*]})"
        fi
    fi
fi

# 3. Free space for the build tree, the package cache and the output.
if [[ $path == native ]]; then
    tree=${RESCUE_BUILD_ROOT:-/var/tmp/system-rescuer-build}
    cache=${RESCUE_REPO_CACHE:-/var/cache/system-rescuer/pkg}
elif [[ $path == container ]]; then
    tree=$("${rt[@]}" info --format '{{.DockerRootDir}}' 2>/dev/null || true)
    [[ -n $tree && -d $tree ]] || tree=$("${rt[@]}" info --format '{{.Store.GraphRoot}}' 2>/dev/null || true)
    [[ -n $tree ]] || tree=/var/lib/docker
    cache=$tree
fi
if [[ -n $path ]]; then
    declare -A need_by_dev=() label_by_dev=() avail_by_dev=()
    for entry in "build tree:$tree:$need_build" "package cache:$cache:$need_cache" "output:$out_dir:$need_out"; do
        IFS=: read -r label p gib <<< "$entry"
        dev=$(stat -c %d -- "$(nearest "$p")" 2>/dev/null || stat -c %d -- /)
        need_by_dev[$dev]=$(( ${need_by_dev[$dev]:-0} + gib ))
        label_by_dev[$dev]="${label_by_dev[$dev]:+${label_by_dev[$dev]}, }$label ($p)"
        avail_by_dev[$dev]=$(df_avail_gib "$p")
    done
    for dev in "${!need_by_dev[@]}"; do
        if (( avail_by_dev[$dev] >= need_by_dev[$dev] )); then
            line space "${avail_by_dev[$dev]} GiB free, ${need_by_dev[$dev]} GiB needed: ${label_by_dev[$dev]}"
        else
            line space "${avail_by_dev[$dev]} GiB free, ${need_by_dev[$dev]} GiB needed: ${label_by_dev[$dev]}: NOT ok"
            fail_check "not enough free space for ${label_by_dev[$dev]}: ${avail_by_dev[$dev]} GiB free, ${need_by_dev[$dev]} GiB needed"
        fi
    done
fi

# 4. The configuration.
config=$(rescue_config_dir "$config")
have_config=0
if [[ -f $config/rescue.conf || -s $config/authorized_keys ]]; then
    have_config=1
    line configuration "$config: found"
else
    line configuration "$config: none"
fi
# What the build will read from it: where the key comes from (never the key),
# the provider's CA, and the SSH keys the stick takes.
if (( have_config )); then
    kf=$(rescue_config_path "$config" "$(rescue_config_get "$config" key_file)")
    if (( no_key )); then
        line "API key" "none: --no-key, the stick asks for it at boot"
    elif [[ -n $kf ]]; then
        if [[ -r $kf ]]; then line "API key" "key_file $kf: readable"
        else line "API key" "key_file $kf: NOT readable"; fail_check "key_file $kf is not readable"; fi
    elif [[ -n $(rescue_config_get "$config" key_command) ]]; then
        line "API key" "key_command (run when the build starts)"
    else
        line "API key" "none configured: the build asks for it (or takes --no-key)"
    fi
    p_url=$(rescue_provider_get "$config" url) p_model=$(rescue_provider_get "$config" model)
    if rescue_config_has "$config" provider_url && ! rescue_config_has "$config" provider_model; then
        line provider "$p_url, model $p_model (the default: set provider_model to this provider's model id)"
    else
        line provider "$p_url, model $p_model"
    fi
    ca=$(rescue_provider_get "$config" ca_file)
    if [[ -n $ca ]]; then
        ca_path=$(rescue_config_path "$config" "$ca")
        if [[ -r $ca_path ]]; then line "provider CA" "$ca_path: readable"
        else line "provider CA" "$ca_path: NOT readable"; fail_check "provider_ca_file $ca_path is not readable"; fi
    fi
    n_keys=$(grep -cE '^(ssh-|ecdsa-|sk-)' "$config/authorized_keys" 2>/dev/null || true)
    line "SSH keys" "${n_keys:-0} in $config/authorized_keys"
fi

# The container sees the configuration at /config: a path the build reads must
# lie inside it.
if (( have_config )) && [[ $path == container ]]; then
    ca=$(rescue_provider_get "$config" ca_file)
    # shellcheck disable=SC2088  # a literal ~/ in the configured value
    case $ca in
        '') ;;
        /*|'~/'*) fail_check "provider_ca_file $ca is an absolute path, which the container cannot see; copy the file into $config and name it relative to it" ;;
        *../*) fail_check "provider_ca_file $ca leaves the configuration directory $config, which is all the container sees" ;;
    esac
fi

if (( ${#problems[@]} )); then
    printf '\nThe host check failed; nothing was built:\n' >&2
    printf '  - %s\n' "${problems[@]}" >&2
    exit 1
fi
if [[ $mode == check ]]; then
    (( have_config )) || { printf '\nNo configuration at %s: copy examples/config/ there, or pass --config <dir>\n' "$config" >&2; exit 1; }
    printf 'Host check passed.\n'
    exit 0
fi

# No configuration: offer the example, asking the terminal.
if (( ! have_config )); then
    [[ -r /dev/tty && -w /dev/tty ]] || die "no configuration at $config: copy examples/config/ there, or pass --config <dir>"
    printf 'No configuration at %s. Copy examples/config/ there? [y/N] ' "$config" > /dev/tty
    read -r answer < /dev/tty || answer=n
    [[ $answer == [yY]* ]] || die "no configuration at $config"
    [[ ! -e $config ]] || [[ -d $config ]] || die "$config exists and is not a directory"
    install -d -m 700 "$config"
    cp -r "$here/examples/config/." "$config/"
    printf 'Copied examples/config/ to %s.\n' "$config"
    [[ -s $config/authorized_keys ]] || die "add the SSH public keys the stick accepts to $config/authorized_keys (see authorized_keys.example), then run this again"
fi
[[ -s $config/authorized_keys ]] || printf 'install.sh: warning: no %s/authorized_keys: the stick would take no SSH login\n' "$config" >&2

# The key goes through a mode-600 file in a private directory, removed on exit.
scratch=$(umask 077; mktemp -d "${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/rescue-install.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
keyfile=$scratch/key
if (( ! no_key )); then
    rc=0
    ( umask 077; rescue_api_key "$config" > "$keyfile" ) || rc=$?
    if (( rc == 2 )); then
        prompt_key "$keyfile" "no API key: set key_file or key_command in $config/rescue.conf (there is no terminal to ask on)"
    elif (( rc != 0 )); then
        die "reading the API key (key_file or key_command in $config/rescue.conf) failed"
    fi
    chmod 600 "$keyfile"
    check_msg=$(rescue_provider_check_key "$config" "$keyfile") || die "$check_msg"
fi

build_args=(--key-stdin) key_in=$keyfile
(( ! no_key )) || { build_args=(--no-key); key_in=/dev/null; }
(( ! repo_asset_build )) || build_args+=(--repo-asset)
mkdir -p -- "$out_dir"
stamp=$scratch/stamp
touch "$stamp"
if [[ $path == native ]]; then
    printf 'Building natively; the log is %s/build.log\n' "$out_dir"
    "${sudo[@]}" "$here/build.sh" "${build_args[@]}" --config "$config" --out-dir "$out_dir" < "$key_in" \
        || die "build.sh failed (see $out_dir/build.log)"
else
    # The derived image: archlinux plus the build tools, cached by its tag.
    if ! "${rt[@]}" image inspect "$derived_image" > /dev/null 2>&1; then
        printf 'Preparing the build image (once; pulls archlinux and installs archiso)\n'
        "${rt[@]}" build -t "$derived_image" - <<EOF || die "could not build the container image"
FROM $base_image
RUN pacman -Syu --noconfirm --needed archiso gitleaks libisoburn \\
    && pacman-key --init && pacman-key --populate archlinux
EOF
    fi
    printf 'Building in a %s container; the log is %s/build.log\n' "$rt_name" "$out_dir"
    # build.sh runs as root in the container and leaves the out dir to root;
    # the wrapper hands it back to the invoking user.
    env_args=()
    [[ -z ${RESCUE_MIRRORS:-} ]] || env_args=(-e RESCUE_MIRRORS)
    # shellcheck disable=SC2016  # expanded by the container's shell
    wrapper='rc=0
        own=$0:$1; shift
        /src/build.sh "$@" --config /config --out-dir /out || rc=$?
        chown -R "$own" /out
        exit $rc'
    "${rt[@]}" run --rm -i --privileged \
        -v "$here:/src:ro" -v "$config:/config:ro" -v "$out_dir:/out" \
        -v "$pkg_volume:/cache" -v "$work_volume:/work" \
        -e RESCUE_BUILD_ROOT=/work/build -e RESCUE_REPO_CACHE=/cache/pkg "${env_args[@]}" \
        "$derived_image" bash -c "$wrapper" "$(id -u)" "$(id -g)" "${build_args[@]}" < "$key_in" \
        || die "the container build failed (see $out_dir/build.log)"
fi

# The ISO, its checksum file and their agreement.
iso=$(find "$out_dir" -maxdepth 1 -name 'system-rescuer-*.iso' -newer "$stamp" -printf '%T@ %p\n' | sort -n | tail -n 1 | cut -d' ' -f2-)
[[ -n $iso ]] || die "the build left no ISO in $out_dir"
check_iso "$iso"
[[ $mode == build ]] || write_stage "$iso"
