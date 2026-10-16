#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# A1 break: <root> is the scenario disk's root filesystem with its ESP mounted
# where the base keeps it. A kernel reinstall was cut off while the package
# manager's hook wrote the boot files: the kernel copy on the ESP is 0 bytes,
# no initramfs was written, the lock file remains, and pacman.log stops
# mid-hook.
#   mkinitcpio: mkinitcpio's hook; the kernel and initramfs at the ESP's top.
#   dracut:     kernel-install-for-dracut's hook; the boot files under
#               <ESP>/<machine id>/<kernel version>/.
# On a GRUB base the package manager writes the kernel whole and its hook
# builds the initramfs in /boot, so the cut falls in that build:
#   initramfs-tools (Debian): dpkg left linux-image-<version> half-configured
#               while its postinst ran update-initramfs, whose image is a
#               truncated .new file, never moved into place.
#   dracut (Fedora): dnf's kernel-install posttrans wrote the boot entry but
#               dracut never finished the initramfs.
set -euo pipefail
# shellcheck source=../../bench/break-lib.sh
. "$(dirname "$0")/../../bench/break-lib.sh"
root=${1:?usage: break.sh <root> <base>} base=${2:?usage: break.sh <root> <base>}
if [[ $BASE_LOADER == grub ]]; then
    k=$(kver "$root") initrd=$(initramfs_path "$root")
    [[ -f $initrd ]] || { echo "break.sh: no initramfs at ${initrd#"$root"}" >&2; exit 1; }
    case $BASE_INITRAMFS in
        initramfs-tools)
            pkg=linux-image-$k
            grep -qxF "Package: $pkg" "$root/var/lib/dpkg/status" \
                || { echo "break.sh: no package $pkg in dpkg's status" >&2; exit 1; }
            ver=$(awk -v p="Package: $pkg" '$0 == p {f = 1} f && /^Version: / {print $2; exit}' "$root/var/lib/dpkg/status")
            head -c 4M "$initrd" > "$initrd.new"
            rm "$initrd"
            awk -v p="Package: $pkg" '$0 == p {f = 1} /^$/ {f = 0}
                f && /^Status: / {$0 = "Status: install ok half-configured"} {print}' \
                "$root/var/lib/dpkg/status" > "$root/var/lib/dpkg/status.bench"
            mv "$root/var/lib/dpkg/status.bench" "$root/var/lib/dpkg/status"
            dpkg_log "$root" "startup archives unpack" "upgrade $pkg:amd64 $ver $ver" \
                "status half-installed $pkg:amd64 $ver" "status unpacked $pkg:amd64 $ver" \
                "startup packages configure" "configure $pkg:amd64 $ver <none>" \
                "status half-configured $pkg:amd64 $ver"
            mkdir -p "$root/var/log/apt"
            printf '%s\n' "Log started: $(date -u '+%F  %T')" "Preparing to unpack .../${pkg}_${ver}_amd64.deb ..." \
                "Unpacking $pkg ($ver) over ($ver) ..." "Setting up $pkg ($ver) ..." \
                "I: /vmlinuz is now a symlink to boot/vmlinuz-$k" \
                "/etc/kernel/postinst.d/initramfs-tools:" "update-initramfs: Generating /boot/initrd.img-$k" \
                >> "$root/var/log/apt/term.log"
            ;;
        dracut)
            rm "$initrd"
            dnf_log "$root" "INFO --- DNF5 launched with arguments: \"/usr/bin/dnf reinstall -y kernel-core\" ---" \
                "INFO Reinstalling kernel-core-$k" \
                "INFO Running posttrans scriptlet: kernel-core-$k" \
                "INFO kernel-install: Running depmod and dracut for $k"
            ;;
        *) echo "break.sh: no A1 break for base $base" >&2; exit 1 ;;
    esac
    exit 0
fi
ver=$(awk 'f {print; exit} /^%VERSION%$/ {f = 1}' "$root"/var/lib/pacman/local/linux-[0-9]*/desc)
[[ -n $ver ]] || { echo "break.sh: no linux package in $root" >&2; exit 1; }
case $BASE_INITRAMFS in
    mkinitcpio)
        : > "$root$BASE_ESP/vmlinuz-linux"
        rm -f "$root$BASE_ESP"/initramfs-linux*.img
        hook=("[ALPM] running '60-mkinitcpio-install.hook'..."
              "[ALPM-SCRIPTLET] ==> Building image from preset: /etc/mkinitcpio.d/linux.preset: 'default'")
        ;;
    dracut)
        dir=$(esp_kernel_dir "$root")
        [[ -f $dir/linux ]] || { echo "break.sh: no kernel at ${dir#"$root"}/linux" >&2; exit 1; }
        : > "$dir/linux"
        rm -f "$dir"/initrd*
        hook=("[ALPM] running '90-kernel-install.hook'..." "[ALPM-SCRIPTLET] Running kernel-install for $(kver "$root")")
        ;;
    *) echo "break.sh: no A1 break for base $base" >&2; exit 1 ;;
esac
: > "$root/var/lib/pacman/db.lck"
pacman_log "$root" "[PACMAN] Running 'pacman -Syu'" "[PACMAN] synchronizing package lists" \
    "[PACMAN] starting full system upgrade" "[ALPM] transaction started" "[ALPM] reinstalled linux ($ver)" \
    "[ALPM] transaction completed" "${hook[@]}"
