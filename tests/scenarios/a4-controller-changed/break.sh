#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# A4 break: <root> is the scenario disk's root with its ESP at /boot. Turn on
# the autodetect hook, as Arch's default mkinitcpio.conf has it, and build the
# initramfs as autodetect did on the old AHCI machine: its storage driver and
# no other, the configuration on disk left as the owner had it.
set -euo pipefail
# shellcheck source=../../bench/break-lib.sh
. "$(dirname "$0")/../../bench/break-lib.sh"
root=${1:?usage: break.sh <root> <base> <disks-dir>}
conf=$root/etc/mkinitcpio.conf
sed -i 's/^HOOKS=(base systemd /HOOKS=(base systemd autodetect /' "$conf"
grep -q '^HOOKS=(base systemd autodetect ' "$conf" || { echo "break.sh: unexpected HOOKS in ${conf#"$root"}" >&2; exit 1; }
kver=$(kver "$root")
old=/etc/mkinitcpio-ahci-machine.conf
sed -e 's/^HOOKS=.*/HOOKS=(base systemd modconf keyboard filesystems fsck)/' \
    -e 's/^MODULES=.*/MODULES=(ahci libahci sd_mod)/' "$conf" > "$root$old"
arch-chroot "$root" mkinitcpio -c "$old" -k "$kver" -g /boot/initramfs-linux.img > /dev/null 2>&1 \
    || { rm -f "$root$old"; echo "break.sh: mkinitcpio failed" >&2; exit 1; }
rm -f "$root$old"
