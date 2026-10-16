# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# shellcheck shell=bash disable=SC2034  # read by tests/bench/lib.sh's base_load
# debian-grub: Debian 13 from its own cloud image (nocloud): initramfs-tools,
# GRUB through shim, an ext4 root, the ESP at /boot/efi. The interface is in
# tests/base-image.sh; build_cloud is in tests/bench/lib.sh.
base_summary="Debian 13, initramfs-tools, GRUB through shim, ext4 root"
base_esp=/boot/efi
base_initramfs=initramfs-tools
base_loader=grub
base_recipe=(build_cloud)
# Debian's installer registers the loader with grub-install, which writes the
# firmware entry for shim itself (the image has no efibootmgr).
base_build() {
    build_cloud "$1" debian-grub debian-13-nocloud-amd64.qcow2 debian-SHA512SUMS sha512 \
        '/usr/sbin/grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=debian'
}
