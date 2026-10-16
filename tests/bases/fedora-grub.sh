# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# shellcheck shell=bash disable=SC2034  # read by tests/bench/lib.sh's base_load
# fedora-grub: Fedora 44 from its own cloud image (Cloud Base Generic):
# dracut, GRUB through shim with BLS entries in /boot/loader/entries, btrfs
# subvolumes root, boot, home and var, the ESP at /boot/efi, SELinux
# enforcing. The interface is in tests/base-image.sh; build_cloud is in
# tests/bench/lib.sh.
base_summary="Fedora 44, dracut, GRUB through shim with BLS entries, btrfs root, SELinux"
base_esp=/boot/efi
base_initramfs=dracut
base_loader=grub
base_recipe=(build_cloud)
# Fedora's installer writes the firmware entry for shim with efibootmgr.
base_build() {
    build_cloud "$1" fedora-grub Fedora-Cloud-Base-Generic-44-1.7.x86_64.qcow2 fedora-CHECKSUM sha256 \
        "/usr/sbin/efibootmgr --quiet --create --disk /dev/sda --part 2 --label Fedora --loader '\\EFI\\fedora\\shimx64.efi'"
}
