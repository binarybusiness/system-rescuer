#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# Spike: the debian-grub and fedora-grub base recipes from the
# distributions' own cloud images (Debian 13 nocloud, Fedora 44 Cloud Base
# Generic): converted to raw, given a hostname, the BOOT-OK unit and no
# cloud-init, then booted alone under OVMF to BOOT-OK. Fedora's first boot
# relabels SELinux (the files added from the host carry no labels) and
# reboots; the base build would keep the image after that first boot.
#
#   sudo tests/spikes/base-cloud.sh debian|fedora
#
# The images come from ~/.cache/system-rescuer/downloads (checksummed there).
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

distro=${1:?usage: base-cloud.sh debian|fedora}
[[ $EUID -eq 0 ]] || fail "needs root (sudo)"
downloads=$(getent passwd "${SUDO_USER:-root}" | cut -d: -f6)/.cache/system-rescuer/downloads
case $distro in
    debian) src=$downloads/debian-13-nocloud-amd64.qcow2 ;;
    fedora) src=$downloads/Fedora-Cloud-Base-Generic-44-1.7.x86_64.qcow2 ;;
    *) fail "unknown distro $distro" ;;
esac
[[ -r $src ]] || fail "missing $src"

img=$spike_tmp/$distro.img
start=$SECONDS
qemu-img convert -O raw "$src" "$img"
loop=$(losetup -fP --show "$img")
bench_loops+=("$loop")
udevadm settle
lsblk -rno NAME,FSTYPE,PARTTYPENAME,LABEL "$loop" > "$spike_tmp/layout.txt"
mnt=$spike_tmp/mnt
mkdir -p "$mnt"
case $distro in
    debian)
        root=$(lsblk -rno PATH,FSTYPE,PARTTYPENAME "$loop" | awk '$2 == "ext4" && /Linux/ {print $1; exit}')
        mount "$root" "$mnt" ;;
    fedora)
        root=$(lsblk -rno PATH,FSTYPE "$loop" | awk '$2 == "btrfs" {print $1; exit}')
        mount -o subvol=root "$root" "$mnt" ;;
esac
bench_mounts+=("$mnt")
[[ -d $mnt/etc/systemd ]] || fail "no root file system found: $(cat "$spike_tmp/layout.txt")"

# First-boot settings offline: Debian's empty machine-id would otherwise make
# systemd-firstboot prompt on the console and wait for a key.
systemd-firstboot --root="$mnt" --locale=C.UTF-8 --keymap=us --timezone=UTC --hostname="spike-$distro" --force > /dev/null
ln -sf /dev/null "$mnt/etc/systemd/system/systemd-firstboot.service"  # and never prompt for the rest (root password)
echo "spike-$distro" > "$mnt/etc/hostname"
install_boot_ok_unit "$mnt"
mkdir -p "$mnt/etc/cloud"
touch "$mnt/etc/cloud/cloud-init.disabled"
[[ $distro == fedora ]] && touch "$mnt/.autorelabel"
release_build
pass "prepared the $distro cloud image in $((SECONDS - start)) s; layout: $(awk '{print $1 ":" $2 ":" $4}' "$spike_tmp/layout.txt" | paste -sd ' ')"

cp "$ovmf_vars" "$spike_tmp/vars.fd"
mapfile -t disk < <(ahci_disk "$img")
start=$SECONDS
BENCH_MEM=2048 qemu_ovmf "$spike_tmp/vars.fd" "$spike_tmp/serial.log" "${disk[@]}"
wait_serial "$spike_tmp/serial.log" "^BOOT-OK spike-$distro" 420 \
    || fail "no BOOT-OK; serial tail: $(tr -d '\r' < "$spike_tmp/serial.log" | tail -n 20)"
stop_qemu
pass "first boot reached BOOT-OK after $((SECONDS - start)) s"
grep -aqE 'GRUB|grub' "$spike_tmp/serial.log" && pass "booted through GRUB"

# A second boot from the settled image, as the bench's runs would.
start=$SECONDS
: > "$spike_tmp/serial2.log"
BENCH_MEM=2048 qemu_ovmf "$spike_tmp/vars.fd" "$spike_tmp/serial2.log" "${disk[@]}"
wait_serial "$spike_tmp/serial2.log" "^BOOT-OK spike-$distro" 180 \
    || fail "second boot: no BOOT-OK within 180 s; tail: $(tr -d '\r' < "$spike_tmp/serial2.log" | tail -n 20)"
stop_qemu
pass "second boot reached BOOT-OK after $((SECONDS - start)) s"
