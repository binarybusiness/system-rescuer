# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# shellcheck shell=bash disable=SC2034,SC2154  # read by tests/bench/lib.sh's with_load, which sets bench_tmp
# arch-sdboot: a healthy Arch Linux beside the scenario's Linux, on a disk of
# its own: a copy of the cached arch-sdboot base (tests/bases/arch-sdboot.sh),
# with its own ESP and systemd-boot, as on a machine where a second Linux was
# installed on a second disk. Its firmware entry, Linux Boot Manager on that
# disk, comes after the scenario disk's in BootOrder; the entry's line from
# efi-vars.py's entries is kept in <disks-dir>/arch-sdboot.entry for a
# scenario's check. Only with_esp=own: its boot files stay on its own ESP.
# The interface is in tests/scenario.sh.
with_summary="a second Linux: Arch with systemd-boot on its own disk"
with_marker='BOOT-OK arch-sdboot'
with_path='\EFI\systemd\systemd-bootx64.efi'

with_setup() {
    local disks=$1 vars=$3 shape=$4 img src entry
    [[ $shape == own ]] || fail "arch-sdboot: its boot files are on its own ESP only (with_esp=own)"
    src=$("$(dirname "${BASH_SOURCE[0]}")/../base-image.sh" arch-sdboot | tail -n 1)
    [[ -s $src ]] || fail "arch-sdboot: no cached arch-sdboot base"
    img=$disks/arch-sdboot.img
    cp --reflink=auto -- "$src" "$img" || fail "arch-sdboot: cannot copy $src"
    chown "$bench_user:" "$img"
    entry=$(efi_add "$vars" "$(python3 "$efi_py" option 'Linux Boot Manager' "$img" esp "$with_path")") \
        || fail "arch-sdboot: cannot add its Linux Boot Manager to the firmware's entries"
    efi_systems_first "$vars" || fail "arch-sdboot: cannot reorder BootOrder"
    efi_query "$vars" entries | awk -F'\t' -v e="$entry" '$1 == e' > "$disks/arch-sdboot.entry"
    [[ -s $disks/arch-sdboot.entry ]] || fail "arch-sdboot: its entry $entry is not in the store"
    pass "arch-sdboot: Arch on its own disk, $entry Linux Boot Manager after the scenario's Linux in BootOrder"
}
