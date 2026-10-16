# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# shellcheck shell=bash disable=SC2034,SC2154  # read by tests/bench/lib.sh's base_load, which sets bench_tmp; disk_create sets disk_loop
# arch-sdboot: Arch with mkinitcpio and systemd-boot, an ext4 root, the ESP at
# /boot. The interface is in tests/base-image.sh.
base_summary="Arch, mkinitcpio, systemd-boot, ext4 root"
base_esp=/boot
base_initramfs=mkinitcpio
base_loader=systemd-boot
base_recipe=(build_arch)
base_build() { build_arch "$1" arch-sdboot plain; }

# build_arch <image> <hostname> <plain|luks> [passphrase-file]: as root,
# pacstrap a minimal Arch (mkinitcpio, systemd-boot, ext4 root) into a 2 GiB
# GPT image with a 300 MiB ESP at /boot and a serial console. With luks, the
# root is LUKS2 (sd-encrypt) unlocked by the passphrase in the file (the
# luks-unlock spike's).
build_arch() {
    local img=$1 host=$2 mode=$3 passfile=${4:-} mnt=$bench_tmp/mnt root_dev opts hooks=''
    [[ $EUID -eq 0 ]] || fail "build_arch needs root (sudo)"
    disk_create "$img" 2G $'label: gpt\nsize=300MiB, type=uefi\ntype=linux'
    mkfs.fat -F32 -n ESP "${disk_loop}p1" > /dev/null
    root_dev=${disk_loop}p2
    if [[ $mode == luks ]]; then
        luks_create "$root_dev" "$passfile" "bench-root-$$"
        root_dev=/dev/mapper/bench-root-$$ hooks=' sd-encrypt'
    fi
    mkfs.ext4 -q -L root "$root_dev"
    bench_mount "$root_dev" "$mnt"
    bench_mount "${disk_loop}p1" "$mnt/boot"
    run_logged pacstrap pacstrap -c "$mnt" base linux mkinitcpio
    finish_root "$mnt" "$host"
    sed -i "s/^HOOKS=.*/HOOKS=(base systemd modconf keyboard block$hooks filesystems fsck)/" "$mnt/etc/mkinitcpio.conf"
    run_logged mkinitcpio arch-chroot "$mnt" mkinitcpio -P
    run_logged bootctl arch-chroot "$mnt" bootctl install --esp-path=/boot --variables=no
    if [[ $mode == luks ]]; then
        opts="rd.luks.name=$(blkid -s UUID -o value "${disk_loop}p2")=root root=/dev/mapper/root"
    else
        opts="root=UUID=$(blkid -s UUID -o value "$root_dev")"
    fi
    printf 'default arch.conf\ntimeout 0\n' > "$mnt/boot/loader/loader.conf"
    printf 'title Arch Linux\nlinux /vmlinuz-linux\ninitrd /initramfs-linux.img\noptions %s rw console=tty0 console=ttyS0,115200\n' "$opts" \
        > "$mnt/boot/loader/entries/arch.conf"
    release_build
}
