# shellcheck shell=bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# Finding the boot stick and what the installer wrote past its image. Sourced
# by rescue-key-record and rescue-repo; the layout is in lib/rescue-stick.sh.
#
#   rescue_boot_disk                    the disk that holds the ISO 9660 volume
#                                       archiso searched for (archisosearchuuid=
#                                       on the kernel command line), else the
#                                       disk under /run/archiso/bootmnt;
#                                       RESCUE_RECORD_DEV names it for a test
#
# rescue_volume_end, rescue_volume_uuid and rescue_scan_past, which read the
# volume and what lies past it, are in rescue-iso9660.sh, sourced here.

# shellcheck source=profile/airootfs/usr/local/lib/rescue-iso9660.sh
. /usr/local/lib/rescue-iso9660.sh

rescue_boot_disk() {
    local dev='' uuid parent
    if [[ -n ${RESCUE_RECORD_DEV:-} ]]; then printf '%s' "$RESCUE_RECORD_DEV"; return 0; fi
    uuid=$(tr ' ' '\n' < /proc/cmdline | sed -n 's/^archisosearchuuid=//p')
    [[ -z $uuid ]] || dev=$(readlink -f "/dev/disk/by-uuid/$uuid" 2> /dev/null)
    if [[ -z $dev || ! -b $dev ]]; then
        dev=$(findmnt -no SOURCE /run/archiso/bootmnt 2> /dev/null | sed 's/\[.*//')
    fi
    [[ -b $dev ]] || return 1
    parent=$(lsblk -dno PKNAME "$dev" 2> /dev/null)
    if [[ -n $parent ]]; then printf '/dev/%s' "$parent"; else printf '%s' "$dev"; fi
}
