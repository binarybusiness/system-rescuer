#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# Build a small broken-machine disk image for the qemu tests, without root.
#
#   tests/make-fixture.sh <out.img> generic|<machine-profile-dir>
#
# An Arch install whose kernel upgrade was cut off while mkinitcpio ran: the
# loader entries name an initramfs that is not on the ESP. With a machine
# profile's directory (examples/config/machines/example-arch, say), the root
# and ESP take the first UUID and the first ESP id in its match file, so
# rescue-survey must name that profile.
# Layout: GPT, an ESP (vfat) and an ext4 root, 512 MiB sparse.
set -euo pipefail

usage="usage: tests/make-fixture.sh <out.img> generic|<machine-profile-dir>"
out=${1:?$usage}
kind=${2:?$usage}
if [[ $kind == generic ]]; then
    root_uuid=3f1c2a7e-5b8d-4e21-9a6f-0c7d8e9f1a2b esp_uuid=1A2B-3C4D
elif [[ -r $kind/match ]]; then
    root_uuid=$(grep -m1 -ixE '[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}' "$kind/match") \
        || { echo "make-fixture: no filesystem UUID in $kind/match" >&2; exit 1; }
    esp_uuid=$(grep -m1 -ixE '[0-9a-f]{4}-[0-9a-f]{4}' "$kind/match") \
        || { echo "make-fixture: no ESP id (XXXX-XXXX) in $kind/match" >&2; exit 1; }
else
    echo "make-fixture: $kind is neither generic nor a machine profile with a match file" >&2
    exit 1
fi
esp_id=${esp_uuid//-/}

work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
root=$work/root esp=$work/esp
mkdir -p "$root"/{etc/mkinitcpio.d,var/log,root,boot,home/owner,usr/lib/modules/6.18.2-arch1-1} \
    "$esp"/{EFI/systemd,EFI/BOOT,loader/entries}

cat > "$root/etc/os-release" <<'EOF'
NAME="Arch Linux"
PRETTY_NAME="Arch Linux"
ID=arch
BUILD_ID=rolling
EOF
echo testbox > "$root/etc/hostname"
printf 'UUID=%s / ext4 rw,relatime 0 1\nUUID=%s /boot vfat rw,relatime,fmask=0077,dmask=0077 0 2\n' \
    "$root_uuid" "$esp_uuid" > "$root/etc/fstab"
echo 'HOOKS=(base udev autodetect microcode modconf kms keyboard keymap consolefont block filesystems fsck)' \
    > "$root/etc/mkinitcpio.conf"
printf '%s\n' "ALL_kver='/boot/vmlinuz-linux'" "PRESETS=('default' 'fallback')" \
    "default_image='/boot/initramfs-linux.img'" "fallback_image='/boot/initramfs-linux-fallback.img'" \
    > "$root/etc/mkinitcpio.d/linux.preset"
cat > "$root/var/log/pacman.log" <<'EOF'
[2026-10-12T21:40:02+0200] [PACMAN] Running 'pacman -Syu'
[2026-10-12T21:40:31+0200] [ALPM] transaction started
[2026-10-12T21:40:33+0200] [ALPM] upgraded linux (6.18.1.arch1-1 -> 6.18.2.arch1-1)
[2026-10-12T21:40:34+0200] [ALPM] running '60-mkinitcpio-remove.hook'...
[2026-10-12T21:40:34+0200] [ALPM] running '90-mkinitcpio-install.hook'...
[2026-10-12T21:40:34+0200] [ALPM-SCRIPTLET] ==> Building image from preset: /etc/mkinitcpio.d/linux.preset: 'default'
EOF
echo linux > "$root/usr/lib/modules/6.18.2-arch1-1/pkgbase"
head -c 65536 /dev/urandom > "$root/usr/lib/modules/6.18.2-arch1-1/vmlinuz"
echo "the owner's files" > "$root/home/owner/notes.txt"
printf 'default arch.conf\ntimeout 3\n' > "$esp/loader/loader.conf"
printf 'title Arch Linux\nlinux /vmlinuz-linux\ninitrd /initramfs-linux.img\noptions root=UUID=%s rw\n' \
    "$root_uuid" > "$esp/loader/entries/arch.conf"
printf 'title Arch Linux (fallback)\nlinux /vmlinuz-linux\ninitrd /initramfs-linux-fallback.img\noptions root=UUID=%s rw\n' \
    "$root_uuid" > "$esp/loader/entries/arch-fallback.conf"
cp "$root/usr/lib/modules/6.18.2-arch1-1/vmlinuz" "$esp/vmlinuz-linux"
head -c 4096 /dev/urandom > "$esp/EFI/systemd/systemd-bootx64.efi"
cp "$esp/EFI/systemd/systemd-bootx64.efi" "$esp/EFI/BOOT/BOOTX64.EFI"

# Partition images, then the disk: ESP at sector 2048 (100 MiB), root after it.
mkfs.vfat -C -F 32 -n ESP -i "$esp_id" "$work/esp.img" 102400 > /dev/null
mcopy -s -i "$work/esp.img" "$esp"/* ::/
mkfs.ext4 -q -F -L root -U "$root_uuid" -E root_owner=0:0 -d "$root" "$work/root.img" 400M

rm -f -- "$out"
truncate -s 512M "$out"
sfdisk -q "$out" <<'EOF'
label: gpt
start=2048, size=204800, type=uefi, name=ESP
start=206848, type=linux, name=root
EOF
dd if="$work/esp.img" of="$out" bs=512 seek=2048 conv=notrunc,sparse status=none
dd if="$work/root.img" of="$out" bs=512 seek=206848 conv=notrunc,sparse status=none
printf 'make-fixture: %s (%s; root %s, ESP %s)\n' "$out" "$(basename "$kind")" "$root_uuid" "$esp_uuid"
