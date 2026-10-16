# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# shellcheck shell=bash disable=SC2034,SC2154  # globals set by and for lib.sh and its callers
# Bench bases and second systems (sourced by lib.sh): loading tests/bases/
# and tests/with/, the steps base builders share (each in the recipe hash
# of every base, build_recipe), and copy-on-write overlays of cached bases.

# base_load <base>: source tests/bases/<base>.sh, which sets the base's facts
# and defines its base_build (the interface is in tests/base-image.sh).
bench_bases=$(cd "$(dirname "${BASH_SOURCE[0]}")/../bases" && pwd)
base_names() { find "$bench_bases" -maxdepth 1 -name '*.sh' -printf '%f\n' | sed 's/\.sh$//' | sort; }
base_load() {
    [[ -f $bench_bases/$1.sh ]] || fail "no base $1; tests/bases/ has: $(base_names | paste -sd' ')"
    base_summary='' base_luks='' base_esp='' base_initramfs='' base_loader='' base_recipe=()
    unset -f base_build
    # shellcheck source=../bases/arch-sdboot.sh
    . "$bench_bases/$1.sh"
    if [[ -z $base_summary || -z $base_esp || -z $base_initramfs || -z $base_loader ]] || ! declare -F base_build > /dev/null; then
        fail "tests/bases/$1.sh must set base_summary, base_esp, base_initramfs and base_loader and define base_build"
    fi
}

# with_load <system>: source tests/with/<system>.sh, a second operating
# system for a scenario disk to share the machine with (the interface is in
# tests/scenario.sh).
bench_with=$(cd "$(dirname "${BASH_SOURCE[0]}")/../with" && pwd)
with_load() {
    [[ -f $bench_with/$1.sh ]] || fail "no system $1; tests/with/ has: $(find "$bench_with" -maxdepth 1 -name '*.sh' -printf '%f ' | sed 's/\.sh//g')"
    with_summary='' with_marker='' with_path='' with_oracle_args=() with_bitlocker=''
    unset -f with_setup with_qemu with_prepare
    # shellcheck source=../with/win-standin.sh
    . "$bench_with/$1.sh"
    if [[ -z $with_summary || -z $with_marker || -z $with_path ]] || ! declare -F with_setup > /dev/null; then
        fail "tests/with/$1.sh must set with_summary, with_marker and with_path and define with_setup"
    fi
}

# The steps base builders share. Each registers what it sets up for
# release_build and fails the script on error.
# disk_create <image> <size> <sfdisk script>: a sparse disk image partitioned
# by the script, attached to a loop device with its partitions ($disk_loop).
disk_create() {
    truncate -s "$2" "$1"
    sfdisk -q "$1" <<< "$3"
    disk_loop=$(losetup -fP --show "$1")
    bench_loops+=("$disk_loop")
    udevadm settle
}
# luks_create <partition> <passphrase-file> <map>: a LUKS2 container with a
# cheap key derivation (the passphrase is test data), opened as
# /dev/mapper/<map>.
luks_create() {
    cryptsetup luksFormat -q --type luks2 --pbkdf pbkdf2 --pbkdf-force-iterations 1000 --key-file "$2" "$1"
    cryptsetup open --key-file "$2" "$1" "$3"
    bench_maps+=("$3")
}
# bench_mount [mount options...] <device> <dir>: mount, creating the directory.
bench_mount() {
    mkdir -p "${!#}"
    mount "$@"
    bench_mounts+=("${!#}")
}
# run_logged <step> <command...>: run quietly, logged to $bench_tmp/<step>.log;
# on failure show the log's tail and fail.
run_logged() {
    local step=$1
    shift
    "$@" > "$bench_tmp/$step.log" 2>&1 || { tail -n 20 "$bench_tmp/$step.log" >&2; fail "$step failed"; }
}
# finish_root <root> <hostname> [fstab line]: the hostname, an fstab of the
# image's own mounts (genfstab also lists the host's active swap, which the
# guest would wait 90 s for) and the line, and the BOOT-OK and first-boot
# units.
finish_root() {
    echo "$2" > "$1/etc/hostname"
    # The host's swap goes with the comment above it, which names its device.
    { genfstab -U "$1" | awk '/^#/ {c = $0; next} $3 == "swap" {c = ""; next} {if (c != "") print c; c = ""; print}'
      [[ -z ${3:-} ]] || printf '%s\n' "$3"; } > "$1/etc/fstab"
    install_boot_ok_unit "$1"
    install_first_boot_unit "$1"
}
# The functions every base's recipe hash covers besides its own.
build_recipe=(disk_create luks_create bench_mount run_logged finish_root install_boot_ok_unit install_first_boot_unit
              first_boot boot_wait wait_serial boot_unlocked type_serial)

# release_build: unmount, close and detach everything a builder set up.
release_build() {
    local i
    for (( i = ${#bench_mounts[@]} - 1; i >= 0; i-- )); do umount "${bench_mounts[i]}" 2>/dev/null || true; done
    for i in "${bench_maps[@]}"; do cryptsetup close "$i" 2>/dev/null || true; done
    for i in "${bench_loops[@]}"; do losetup -d "$i" 2>/dev/null || true; done
    bench_loops=() bench_maps=() bench_mounts=()
}

# build_cloud <image> <hostname> <qcow2> <checksums> <sha256|sha512> <register>:
# as root, a distribution's own cloud image as the base disk: the
# image and the distribution's checksum file from the cache's downloads/,
# checked, converted to raw; its root given the hostname, a machine id and
# the first-boot settings offline (an unset machine id makes
# systemd-firstboot prompt on the console), cloud-init disabled, the BOOT-OK
# unit, and the first-boot unit with the command that registers the boot
# loader in the firmware as the distribution's installer does. A root with
# SELinux (Fedora) relabels on its first boot, since files added from the
# host carry no labels. Shim's fallback beside the removable path
# (EFI/BOOT/fbx64.efi, Fedora's) is set aside until that registration: under
# OVMF it cannot start the entry it creates and the first boot hangs.
build_cloud() {
    local img=$1 host=$2 src=$bench_cache/downloads/$3 sums=$bench_cache/downloads/$4 alg=$5 register=$6
    local mnt=$bench_tmp/mnt esp=$bench_tmp/esp want root part machine_id=()
    [[ -r $src && -r $sums ]] || fail "build_cloud: $src or $sums is missing: download the distribution's cloud image and its checksum file there"
    want=$(grep -F -- "$3" "$sums" | grep -oE '[0-9a-f]{64,128}' | head -n 1)
    [[ -n $want && $("${alg}sum" < "$src" | cut -d' ' -f1) == "$want" ]] || fail "build_cloud: $3 does not match its $alg in $4"
    run_logged convert qemu-img convert -O raw "$src" "$img"
    disk_loop=$(losetup -fP --show "$img")
    bench_loops+=("$disk_loop")
    udevadm settle
    # The partition typed as the x86-64 root.
    root=$(lsblk -rno PATH,PARTTYPE "$disk_loop" | awk '$2 == "4f68bce3-e8cd-4db1-96e7-fbcaf984b709" {print $1; exit}')
    [[ -n $root ]] || fail "build_cloud: no x86-64 root partition in $3"
    part=$(lsblk -rno PATH,PARTTYPE "$disk_loop" | awk '$2 == "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" {print $1; exit}')
    [[ -n $part ]] || fail "build_cloud: no EFI system partition in $3"
    bench_mount "$part" "$esp"
    if [[ -f $esp/EFI/BOOT/fbx64.efi ]]; then
        mv "$esp/EFI/BOOT/fbx64.efi" "$esp/EFI/BOOT/fbx64.efi.bench"
        register+=$'\nmv /boot/efi/EFI/BOOT/fbx64.efi.bench /boot/efi/EFI/BOOT/fbx64.efi'
    fi
    bench_mount "$root" "$mnt"
    if [[ ! -d $mnt/etc && -d $mnt/root/etc ]]; then
        umount "$mnt"
        mount -o subvol=root "$root" "$mnt"
    fi
    [[ -d $mnt/etc/systemd ]] || fail "build_cloud: no root file system in $3"
    [[ -s $mnt/etc/machine-id ]] || machine_id=(--setup-machine-id)
    systemd-firstboot --root="$mnt" --locale=C.UTF-8 --keymap=us --timezone=UTC --hostname="$host" "${machine_id[@]}" --force > /dev/null
    ln -sf /dev/null "$mnt/etc/systemd/system/systemd-firstboot.service"
    echo "$host" > "$mnt/etc/hostname"
    install_boot_ok_unit "$mnt"
    install_first_boot_unit "$mnt" "$register"
    mkdir -p "$mnt/etc/cloud"
    touch "$mnt/etc/cloud/cloud-init.disabled"
    [[ ! -f $mnt/etc/selinux/config ]] || touch "$mnt/.autorelabel"
    release_build
}

# install_boot_ok_unit <root>: the unit that prints "BOOT-OK <hostname>" to
# ttyS0 once multi-user is reached.
install_boot_ok_unit() {
    cat > "$1/etc/systemd/system/boot-ok.service" <<'UNIT'
[Unit]
Description=Print BOOT-OK on the serial port
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo "BOOT-OK $(cat /etc/hostname)" > /dev/ttyS0'

[Install]
WantedBy=default.target
UNIT
    mkdir -p "$1/etc/systemd/system/default.target.wants"
    ln -sf /etc/systemd/system/boot-ok.service "$1/etc/systemd/system/default.target.wants/boot-ok.service"
}

# install_first_boot_unit <root> [command]: on the base's first boot, register
# the boot loader in the firmware as an installer would (the shell command,
# by default `bootctl install`, kept in /usr/local/sbin/bench-register-loader),
# print FIRST-BOOT-DONE to ttyS0 and power off cleanly; later boots skip it.
install_first_boot_unit() {
    mkdir -p "$1/usr/local/sbin"
    printf '#!/bin/sh\nset -e\n%s\n' "${2:-/usr/bin/bootctl install}" > "$1/usr/local/sbin/bench-register-loader"
    chmod 755 "$1/usr/local/sbin/bench-register-loader"
    cat > "$1/etc/systemd/system/bench-first-boot.service" <<'UNIT'
[Unit]
Description=Register the boot loader in the firmware on the first boot
After=multi-user.target boot-ok.service
ConditionPathExists=!/var/lib/bench-first-boot

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/bench-register-loader
ExecStart=/usr/bin/touch /var/lib/bench-first-boot
ExecStart=/bin/sh -c 'echo FIRST-BOOT-DONE > /dev/ttyS0'
ExecStartPost=/usr/bin/systemctl --no-block poweroff

[Install]
WantedBy=default.target
UNIT
    ln -sf /etc/systemd/system/bench-first-boot.service "$1/etc/systemd/system/default.target.wants/bench-first-boot.service"
}

# first_boot <image> <vars> [passphrase-file]: boot a freshly built base once
# with fresh firmware variables, which it fills, and wait for its clean
# power-off; an encrypted base is unlocked on its serial console.
first_boot() {
    cp "$ovmf_vars" "$2"
    local disk
    mapfile -t disk < <(ahci_disk "$1")
    boot_wait "$2" "$bench_tmp/first-boot.log" "${3:-}" '^FIRST-BOOT-DONE' 240 "${disk[@]}" \
        || fail "the base's first boot printed no FIRST-BOOT-DONE within 240 s; serial tail: $(serial_tail "$bench_tmp/first-boot.log")"
    qemu_exited 60 || fail "the base did not power off after its first boot"
    stop_qemu
}

# base_overlay <base-image> <overlay>: a copy-on-write copy of a cached base
# for one run (a reflink on the cache's btrfs, a full copy elsewhere), owned
# by the invoking user and removed when the script exits; overlay_remove
# removes it sooner. Break scripts loop-mount it like any raw disk.
base_overlay() {
    cp --reflink=auto -- "$1" "$2" || fail "cannot copy $1 to $2"
    bench_overlays+=("$2")
    chown "$bench_user:" "$2" 2>/dev/null || true
}
overlay_remove() {
    local i
    rm -f -- "$1"
    for i in "${!bench_overlays[@]}"; do [[ ${bench_overlays[i]} != "$1" ]] || unset 'bench_overlays[i]'; done
}
