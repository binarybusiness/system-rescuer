#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# A11 break (eos-sdboot): add a drop-in that omits dracut's crypt modules and
# rebuild the initramfs in a chroot, as the next kernel update's hook would.
set -euo pipefail
# shellcheck source=../../bench/break-lib.sh
. "$(dirname "$0")/../../bench/break-lib.sh"
root=${1:?usage: break.sh <root> <base>} base=${2:?usage: break.sh <root> <base>}
[[ $BASE_INITRAMFS == dracut ]] || { echo "break.sh: no A11 break for base $base" >&2; exit 1; }
cat > "$root/etc/dracut.conf.d/90-slim.conf" <<'CONF'
# A smaller, faster initramfs (2026-10-02): leave out what this machine does not use.
omit_dracutmodules+=" crypt systemd-cryptsetup crypt-gpg crypt-loop plymouth "
CONF
arch-chroot "$root" reinstall-kernels > /dev/null 2>&1 || { echo "break.sh: reinstall-kernels failed in the chroot" >&2; exit 1; }
if lsinitrd "$(esp_kernel_dir "$root")/initrd" 2>/dev/null | grep -q 'systemd-cryptsetup'; then
    echo "break.sh: the rebuilt initramfs still has systemd-cryptsetup" >&2; exit 1
fi
kver=$(kver "$root")
pacman_log "$root" "[ALPM] upgraded linux ($kver)" "[ALPM] transaction completed" "[ALPM] running '90-kernel-install.hook'..." \
    "[ALPM-SCRIPTLET] Running kernel-install for $kver"
