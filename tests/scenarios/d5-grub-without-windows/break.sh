#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# D5 break: <root> is Debian's root with the ESP at /boot/efi, where
# with_setup has put Windows' boot files. os-prober is installed (from the
# cache's downloads, fetched once and checked against its sha256) and stays
# disabled; grub.cfg is the base's, generated before Windows' files were on
# the ESP, so it has no Windows entry.
set -euo pipefail
root=${1:?usage: break.sh <root> <base>} base=${2:?usage: break.sh <root> <base>}
[[ $base == debian-grub ]] || { echo "break.sh: no D5 break for base $base" >&2; exit 1; }
deb=os-prober_1.83_amd64.deb sha=ef702a8645756a33adc630156c40982db7e93239a8d7983eded567d19f058dde
cache=${BENCH_CACHE:-$(getent passwd "${SUDO_USER:-root}" | cut -d: -f6)/.cache/system-rescuer}/downloads
if [[ ! -s $cache/$deb ]]; then
    curl -fsS --max-time 120 -o "$cache/$deb.part" "https://deb.debian.org/debian/pool/main/o/os-prober/$deb" \
        || { echo "break.sh: cannot download $deb" >&2; exit 1; }
    mv -f "$cache/$deb.part" "$cache/$deb"
    chown "${SUDO_USER:-root}:" "$cache/$deb"
fi
[[ $(sha256sum < "$cache/$deb" | cut -d' ' -f1) == "$sha" ]] || { echo "break.sh: $deb does not match its sha256" >&2; exit 1; }
cp "$cache/$deb" "$root/tmp/$deb"
chroot "$root" /usr/bin/env PATH=/usr/sbin:/usr/bin:/sbin:/bin dpkg -i "/tmp/$deb" > /dev/null || { echo "break.sh: dpkg could not install $deb" >&2; exit 1; }
rm -f "$root/tmp/$deb"
[[ -x $root/usr/bin/os-prober ]] || { echo "break.sh: no os-prober after the install" >&2; exit 1; }
! grep -rqsE '^[[:space:]]*GRUB_DISABLE_OS_PROBER=["'"'"']?false' "$root/etc/default/grub" "$root/etc/default/grub.d" \
    || { echo "break.sh: os-prober is already enabled" >&2; exit 1; }
! grep -qi 'bootmgfw' "$root/boot/grub/grub.cfg" || { echo "break.sh: grub.cfg already has Windows" >&2; exit 1; }
