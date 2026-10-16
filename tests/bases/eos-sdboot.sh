# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# shellcheck shell=bash disable=SC2034,SC2154  # read by tests/bench/lib.sh's base_load, which sets bench_tmp; disk_create sets disk_loop
# eos-sdboot: the workstation's shape. EndeavourOS packages, dracut through
# kernel-install, systemd-boot on /efi, a LUKS2 root with btrfs subvolumes and
# encrypted swap. The interface is in tests/base-image.sh.
base_summary="the workstation's shape: EndeavourOS, dracut, systemd-boot on /efi, LUKS2 btrfs root"
base_luks=1
base_esp=/efi
base_initramfs=dracut
base_loader=systemd-boot
base_recipe=(build_eos)
base_build() { build_eos "$1" eos-sdboot "$2"; }

# build_eos <image> <hostname> <passphrase-file>: as root, EndeavourOS
# packages (base, linux, dracut, kernel-install-for-dracut from the host's
# repos) in a 4 GiB image: a LUKS2 container holding btrfs subvolumes @ and
# @home, swap encrypted with a fresh key on every boot, the ESP at /efi with
# systemd-boot and BLS entries under the machine id, and a serial console.
# The initramfs is generic (hostonly=no) so it carries the AHCI driver the
# build host does not use; it asks for the passphrase on the console.
build_eos() {
    local img=$1 host=$2 passfile=$3 mnt=$bench_tmp/mnt luks_uuid swap_partuuid map=bench-eos-$$
    [[ $EUID -eq 0 ]] || fail "build_eos needs root (sudo)"
    disk_create "$img" 4G $'label: gpt\nsize=500MiB, type=uefi\nsize=128MiB, type=swap\ntype=linux'
    mkfs.fat -F32 -n ESP "${disk_loop}p1" > /dev/null
    swap_partuuid=$(blkid -s PARTUUID -o value "${disk_loop}p2")
    luks_create "${disk_loop}p3" "$passfile" "$map"
    luks_uuid=$(cryptsetup luksUUID "${disk_loop}p3")
    mkfs.btrfs -q -L endeavouros "/dev/mapper/$map"
    mkdir -p "$mnt"
    mount "/dev/mapper/$map" "$mnt"
    btrfs -q subvolume create "$mnt/@"
    btrfs -q subvolume create "$mnt/@home"
    umount "$mnt"
    bench_mount -o subvol=@ "/dev/mapper/$map" "$mnt"
    bench_mount -o subvol=@home "/dev/mapper/$map" "$mnt/home"
    bench_mount "${disk_loop}p1" "$mnt/efi"

    # The ESP layout and kernel command line exist before the kernel package's
    # hooks run kernel-install.
    systemd-machine-id-setup --root="$mnt" > /dev/null 2>&1
    mkdir -p "$mnt/etc/kernel" "$mnt/etc/dracut.conf.d"
    printf 'rd.luks.uuid=%s root=/dev/mapper/luks-%s rootflags=subvol=@ rw console=tty0 console=ttyS0,115200\n' \
        "$luks_uuid" "$luks_uuid" > "$mnt/etc/kernel/cmdline"
    printf 'hostonly="no"\ncompress="zstd"\nadd_dracutmodules+=" crypt btrfs "\n' > "$mnt/etc/dracut.conf.d/bench.conf"
    printf 'luks-%s UUID=%s none luks\nswap PARTUUID=%s /dev/urandom swap,cipher=aes-xts-plain64,size=512\n' \
        "$luks_uuid" "$luks_uuid" "$swap_partuuid" > "$mnt/etc/crypttab"
    run_logged pacstrap pacstrap -c "$mnt" base linux dracut kernel-install-for-dracut btrfs-progs cryptsetup systemd-sysvcompat
    # The image's own swap is the encrypted one from crypttab.
    finish_root "$mnt" "$host" '/dev/mapper/swap none swap defaults 0 0'
    run_logged bootctl arch-chroot "$mnt" bootctl install --esp-path=/efi --variables=no
    printf 'timeout 0\n' > "$mnt/efi/loader/loader.conf"
    # kernel-install-for-dracut's own entry point, as its pacman hook runs it.
    run_logged kernel-install arch-chroot "$mnt" reinstall-kernels
    ls "$mnt"/efi/loader/entries/*.conf > /dev/null 2>&1 \
        || fail "no BLS entry on the ESP: $(cd "$mnt/efi" && find . -type f -printf '%p %s\n')"
    release_build
}
