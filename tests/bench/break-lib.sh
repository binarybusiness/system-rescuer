# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# shellcheck shell=bash
# Steps the scenarios' break scripts share (tests/scenarios/*/break*.sh).
# Source it from a break script:
#
#   . "$(dirname "$0")/../../bench/break-lib.sh"
#
# tests/scenario.sh runs break scripts with the base's facts (tests/bases/)
# in BASE_ESP, BASE_INITRAMFS and BASE_LOADER. tests/bench/lib.sh sources it
# too.

# root_path <root> <path>: the path as the mounted root's own system would
# see it, every symlink on the way resolved inside the root: NixOS's
# /etc/fstab is a chain of absolute links into its /nix/store, which the host
# does not have.
root_path() {
    local root=$1 rest=${2#/} out='' part target n=0
    while [[ -n $rest ]]; do
        part=${rest%%/*}
        [[ $rest == */* ]] && rest=${rest#*/} || rest=''
        case $part in ''|.) continue ;; ..) out=${out%/*}; continue ;; esac
        if [[ -L $root$out/$part ]] && (( n++ < 40 )); then
            target=$(readlink "$root$out/$part")
            [[ $target == /* ]] && out=''
            rest=${target#/}${rest:+/$rest}
        else
            out+=/$part
        fi
    done
    printf '%s%s\n' "$root" "${out:-/}"
}

# nixos_generation <root>: the number of the generation the system profile
# points at (system -> system-<n>-link).
nixos_generation() { local l; l=$(readlink "$1/nix/var/nix/profiles/system"); l=${l#system-}; echo "${l%-link}"; }

# nixos_efi_name <root> <store file>: where systemd-boot's NixOS builder
# copies a generation's kernel or initrd on the ESP: /EFI/nixos/<store
# directory>-<file name>.efi of the file the link resolves to.
nixos_efi_name() { local p; p=$(root_path "$1" "$2"); echo "/EFI/nixos/$(basename "$(dirname "$p")")-${p##*/}.efi"; }

# nixos_boot_check <root>: on a NixOS root with its ESP mounted at
# $BASE_ESP, a scenario check that every generation's loader entry loads that
# generation's kernel and initrd byte for byte, and that loader.conf's default
# is the profile's current generation.
nixos_boot_check() {
    local root=$1 esp=$1$BASE_ESP gen e top kind file n=0
    gen=$(nixos_generation "$root")
    grep -qE "^default +nixos-generation-$gen\.conf$" "$esp/loader/loader.conf" \
        || { echo "loader.conf's default is not generation $gen: $(grep '^default' "$esp/loader/loader.conf")"; return 1; }
    for e in "$esp"/loader/entries/nixos-generation-*.conf; do
        [[ -f $e ]] || continue
        top=$(sed -nE 's/^options .*init=([^ ]+)\/init( .*)?$/\1/p' "$e")
        for kind in linux:kernel initrd:initrd; do
            file=$(awk -v k="${kind%:*}" '$1 == k {print $2}' "$e")
            cmp -s "$(root_path "$root" "$top/${kind#*:}")" "$esp$file" \
                || { echo "${e##*/}: its ${kind%:*} $file is not $top/${kind#*:}"; return 1; }
        done
        n=$((n + 1))
    done
    (( n )) || { echo "no NixOS loader entries"; return 1; }
    echo "$n entries load their generation's kernel and initrd; the default is generation $gen"
}

# kver <root>: the installed kernel's version (its /usr/lib/modules directory).
kver() { basename "$(find "$1/usr/lib/modules" -mindepth 1 -maxdepth 1 -type d | head -n 1)"; }

# esp_kernel_dir <root>: where kernel-install keeps the kernel's boot files on
# a dracut base: <ESP>/<machine id>/<kernel version>.
esp_kernel_dir() { printf '%s%s/%s/%s\n' "$1" "$BASE_ESP" "$(< "$1/etc/machine-id")" "$(kver "$1")"; }

# pacman_log <root> <line>...: append the lines to the root's pacman.log,
# each stamped with the time now, as pacman writes them.
pacman_log() {
    local root=$1 now line
    shift
    now=$(date -u +%Y-%m-%dT%H:%M:%S+0000)
    for line; do printf '[%s] %s\n' "$now" "$line"; done >> "$root/var/log/pacman.log"
}

# initramfs_path <root>: the initramfs the boot entry loads: at the ESP's
# top (mkinitcpio), under the kernel's ESP directory (dracut through
# kernel-install, with systemd-boot), or in /boot next to the kernel (GRUB:
# Debian's initramfs-tools, Fedora's dracut).
initramfs_path() {
    case $BASE_INITRAMFS/$BASE_LOADER in
        mkinitcpio/*) printf '%s\n' "$1$BASE_ESP/initramfs-linux.img" ;;
        dracut/systemd-boot) printf '%s\n' "$(esp_kernel_dir "$1")/initrd" ;;
        initramfs-tools/grub) printf '%s\n' "$1/boot/initrd.img-$(kver "$1")" ;;
        dracut/grub) printf '%s\n' "$1/boot/initramfs-$(kver "$1").img" ;;
        *) echo "break: no initramfs known on a $BASE_INITRAMFS and $BASE_LOADER base" >&2; return 1 ;;
    esac
}

# delete_initramfs <root>: delete the initramfs the boot entry loads, so the
# boot fails (B3 and C3 to C8).
delete_initramfs() {
    local f
    f=$(initramfs_path "$1") && rm "$f"
}

# dpkg_log <root> <line>... and dnf_log <root> <line>...: append the lines to
# the root's dpkg.log or dnf5.log, each stamped with the time now in the
# tool's own format.
dpkg_log() {
    local root=$1 now line
    shift
    now=$(date -u '+%F %T')
    for line; do printf '%s %s\n' "$now" "$line"; done >> "$root/var/log/dpkg.log"
}
dnf_log() {
    local root=$1 now line
    shift
    now=$(date -u +%Y-%m-%dT%H:%M:%S+0000)
    for line; do printf '%s [4711] %s\n' "$now" "$line"; done >> "$root/var/log/dnf5.log"
}

# photo_pool <disks-dir>: the owner's healthy btrfs RAID1 photo pool, data
# and metadata mirrored over pool-a.img and pool-b.img (256 MiB each) in the
# directory; prints the pool's UUID. A subshell, so its cleanup trap is its
# own: uuid=$(photo_pool "$disks").
photo_pool() (
    set -e
    a=$1/pool-a.img b=$1/pool-b.img m=$(mktemp -d)
    truncate -s 256M "$a" "$b"
    la=$(losetup -f --show "$a") lb=$(losetup -f --show "$b")
    # shellcheck disable=SC2154  # assigned above, in this subshell
    trap 'umount "$m" 2> /dev/null || true; btrfs device scan --forget "$la" "$lb" 2> /dev/null || true; losetup -d "$la" "$lb" 2> /dev/null || true; rmdir "$m" || true' EXIT
    mkfs.btrfs -q -L pool -d raid1 -m raid1 "$la" "$lb"
    mount -o device="$lb" "$la" "$m"
    mkdir -p "$m/photos/2025"
    for i in 1 2 3 4; do head -c 4M /dev/urandom > "$m/photos/2025/img-000$i.raw"; done
    blkid -s UUID -o value "$la"
)

# The firmware's boot entries. tests/scenario.sh exports BENCH_VARS,
# the run's OVMF variable store, and BENCH_DISK, the scenario disk's image,
# before the break, so a break script can change the entries with these.
# vfv is virt-fw-vars from PyPI's virt-firmware, run through uv (not packaged
# in Arch); tests/bench/efi-vars.py reads and makes the entries.
vfv() { uv tool run --quiet --from virt-firmware virt-fw-vars "$@"; }
efi_py=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/efi-vars.py

# efi_query <vars> <command> [args...]: an efi-vars.py command that reads a
# store (order, entries, pick) run on this one.
efi_query() {
    local j s=0
    j=$(mktemp)
    if vfv -i "$1" --output-json "$j" > /dev/null 2>&1; then python3 "$efi_py" "$2" "$j" "${@:3}" || s=$?
    else echo "virt-fw-vars cannot read $1" >&2; s=1; fi
    rm -f "$j"
    return $s
}

# efi_set <vars> <name> <hex>: set a global variable (non-volatile, with boot
# and runtime access, as Boot#### and BootOrder are).
efi_set() {
    local j s=0
    j=$(mktemp)
    jq -n --arg n "$2" --arg d "$3" \
        '{version: 2, variables: [{name: $n, guid: "8be4df61-93ca-11d2-aa0d-00e098032b8c", attr: 7, data: $d}]}' > "$j"
    vfv --inplace "$1" --set-json "$j" > /dev/null 2>&1 || { echo "virt-fw-vars cannot set $2 in $1" >&2; s=1; }
    rm -f "$j"
    return $s
}

# efi_delete <vars> <name>...: delete the variables.
efi_delete() {
    local v=$1 n args=()
    shift
    for n; do args+=(-d "$n"); done
    vfv --inplace "$v" "${args[@]}" > /dev/null 2>&1 || { echo "virt-fw-vars cannot delete $* in $v" >&2; return 1; }
}

# efi_order <vars> <Boot####>...: set BootOrder to these entries.
efi_order() {
    local v=$1 hex='' n
    shift
    for n; do n=${n#Boot}; hex+=${n:2:2}${n:0:2}; done
    efi_set "$v" BootOrder "$hex"
}

# efi_add <vars> <option-hex> [first|last]: add the load option (efi-vars.py
# option or stick) as the first free Boot#### and put it last (or first) in
# BootOrder; prints its name.
efi_add() {
    local v=$1 data=$2 names n i efi_cur
    names=$(efi_query "$v" entries | cut -f1) || return 1
    for ((i = 0; ; i++)); do n=$(printf 'Boot%04X' "$i"); grep -qx "$n" <<< "$names" || break; done
    efi_set "$v" "$n" "$data" || return 1
    mapfile -t efi_cur < <(efi_query "$v" order)
    if [[ ${3:-last} == first ]]; then efi_order "$v" "$n" "${efi_cur[@]}"; else efi_order "$v" "${efi_cur[@]}" "$n"; fi || return 1
    echo "$n"
}

# efi_entry <vars> <title-regex>: the name of the first entry (in BootOrder's
# order) whose title matches.
efi_entry() { efi_query "$1" entries | awk -F'\t' -v t="$2" '$2 ~ t {print $1; exit}' | grep .; }

# efi_systems_first <vars>: reorder BootOrder so that the entries that load a
# file from a partition (the installed systems') come before the firmware's
# own, each group keeping its order.
efi_systems_first() {
    local entries efi_cur keep=() n
    entries=$(efi_query "$1" entries) || return 1
    mapfile -t efi_cur < <(efi_query "$1" order)
    for n in $(awk -F'\t' '$3 != "-" {print $1}' <<< "$entries") $(awk -F'\t' '$3 == "-" {print $1}' <<< "$entries"); do
        if [[ " ${efi_cur[*]} " == *" $n "* ]]; then keep+=("$n"); fi
    done
    efi_order "$1" "${keep[@]}"
}

# efi_remove <vars> <Boot####>...: delete the entries and take them out of
# BootOrder.
efi_remove() {
    local v=$1 efi_cur keep=() n
    shift
    mapfile -t efi_cur < <(efi_query "$v" order)
    for n in "${efi_cur[@]}"; do [[ " $* " == *" $n "* ]] || keep+=("$n"); done
    efi_delete "$v" "$@" && efi_order "$v" "${keep[@]}"
}

# efi_bootnext <vars> <Boot####>: start that entry at the next boot only
# (BootNext holds the entry's number as a little-endian 16-bit value).
efi_bootnext() { efi_set "$1" BootNext "${2:6:2}${2:4:2}"; }
# efi_first <vars> <Boot####>: move the entry to the front of BootOrder.
efi_first() {
    local efi_cur
    mapfile -t efi_cur < <(efi_query "$1" order | grep -vx "$2")
    efi_order "$1" "$2" "${efi_cur[@]}"
}

# Windows' boot files' directory on an ESP, as an efi_on_disk or
# efi-vars.py pick regex.
# shellcheck disable=SC1003,SC2034  # backslashes, not an escaped quote; used by the scripts that source this
efi_ms_path='^\\efi\\microsoft\\'

# efi_on_disk <vars> <image> [<path-regex>]: the entries (in BootOrder's
# order) that load a file from a partition of the image, those whose path
# matches the regex (case-insensitive, awk's syntax) left out.
efi_on_disk() {
    local uuids
    uuids=$(python3 "$efi_py" partuuids "$2" | paste -sd' ' -) || return 1
    # The regex goes through the environment: awk -v would unescape it.
    efi_query "$1" entries | U=" $uuids " X=${3:-} awk -F'\t' \
        'index(ENVIRON["U"], " " $3 " ") && !(ENVIRON["X"] != "" && tolower($4) ~ tolower(ENVIRON["X"])) {print $1}'
}
