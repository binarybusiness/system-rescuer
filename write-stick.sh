#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# Write the newest out/system-rescuer-*.iso (or a given ISO) to a USB stick,
# then read it back and compare checksums.
#
#   sudo ./write-stick.sh /dev/sdX [image.iso]
#
# The owner's writer, for one stick model (RESCUE_STICK_MODEL, default
# "USB DISK 3.0", 4-256 GiB). It also applies the checks install.sh applies
# (lib/rescue-stick.sh): a whole, removable, USB-transport disk with nothing
# mounted, swapped, stacked on it or under the running system, and large
# enough for the ISO. Never touches NVMe or loop devices.
set -euo pipefail

die() { printf 'write-stick: %s\n' "$*" >&2; exit 1; }

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/rescue-stick.sh
. "$here/lib/rescue-stick.sh"

usage='usage: sudo ./write-stick.sh /dev/sdX [image.iso]'
(( $# >= 1 && $# <= 2 )) || die "$usage"
dev=$1
iso=${2:-$(find "$here/out" -maxdepth 1 -name 'system-rescuer-*.iso' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -n 1 | cut -d' ' -f2-)}
expected_model=${RESCUE_STICK_MODEL:-USB DISK 3.0}

[[ -n $iso && -s $iso ]] || die "no ISO found; build one with sudo ./build.sh"
[[ -b $dev ]] || die "$dev is not a block device"
name=$(basename "$(readlink -f "$dev")")
iso_size=$(stat -c %s "$iso")
stick_refusal "$name" "$iso_size" || die "refusing $dev: $STICK_REASON"
model=$(stick_attr MODEL "$name")
[[ $model == "$expected_model" ]] || die "refusing $dev: model '$model' is not '$expected_model'"
size=$(lsblk -dbno SIZE "/dev/$name" | tr -d ' ')
(( size >= 4 * 1024**3 && size <= 256 * 1024**3 )) || die "refusing $dev: size $size bytes is outside 4-256 GiB"

[[ $EUID -eq 0 ]] || die "run as root"
printf 'write-stick: %s (%s, %s, %s bytes) <- %s\n' "/dev/$name" "$model" "$(stick_attr TRAN "$name")" "$size" "$(basename "$iso")"
stick_write_image "$name" "$iso" || die "the write did not verify"
printf 'write-stick: verified\n'
