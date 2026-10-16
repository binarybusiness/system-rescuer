#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# Spike: read, write and wipe OVMF boot variables in a vars file from
# the host, and prove the firmware honours them: BootNext set on the host
# selects the next boot, the firmware clears it, and a deleted Boot#### entry
# is gone from the store and from BootOrder.
#
#   tests/spikes/ovmf-vars.sh
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

global=8be4df61-93ca-11d2-aa0d-00e098032b8c
vars=$spike_tmp/vars.fd
cp "$ovmf_vars" "$vars"

# set_vars <name>=<hex-data>...: write variables through a JSON file.
set_vars() {
    local spec name data entries=()
    for spec in "$@"; do
        name=${spec%%=*} data=${spec#*=}
        entries+=("$(jq -nc --arg n "$name" --arg g "$global" --arg d "$data" '{name:$n, guid:$g, attr:7, data:$d}')")
    done
    printf '%s\n' "${entries[@]}" | jq -s '{version:2, variables:.}' > "$spike_tmp/set.json"
    vfv --inplace "$vars" --set-json "$spike_tmp/set.json" > /dev/null 2>&1
}
# u16le <hex4>...: little-endian UINT16 list, e.g. u16le 0002 0000 -> 02000000
u16le() { local h; for h in "$@"; do printf '%s%s' "${h:2:2}" "${h:0:2}"; done; }
print_vars() { vfv -i "$vars" -p 2>/dev/null; }

# 1. A first boot with no disks makes the firmware create its default entries.
qemu_ovmf "$vars" "$spike_tmp/boot1.log"
wait_serial "$spike_tmp/boot1.log" 'No bootable option' 60 || fail "first boot never reached the boot manager"
stop_qemu
print_vars > "$spike_tmp/print1.txt"
shell=$(grep -E '^Boot[0-9A-F]{4} .*title="EFI Internal Shell"' "$spike_tmp/print1.txt" | cut -c5-8)
[[ -n $shell ]] || fail "no EFI Internal Shell entry after the first boot: $(cat "$spike_tmp/print1.txt")"
pass "read: firmware created Boot$shell (EFI Internal Shell); $(grep '^BootOrder' "$spike_tmp/print1.txt" | tr -s ' ')"

# 2. Write BootNext on the host; the next boot runs that entry, and the
#    firmware deletes BootNext as it uses it.
set_vars "BootNext=$(u16le "$shell")"
print_vars | grep -q "^BootNext" || fail "BootNext not written"
qemu_ovmf "$vars" "$spike_tmp/boot2.log"
wait_serial "$spike_tmp/boot2.log" 'UEFI Interactive Shell|Shell>' 60 || fail "BootNext=$shell did not start the shell"
stop_qemu
pass "write: BootNext=$shell from the host started the EFI shell"
print_vars | grep -q "^BootNext" && fail "firmware left BootNext set"
pass "firmware cleared BootNext after using it"

# 3. Wipe: delete an entry and drop it from BootOrder.
victim=$(grep -E '^Boot[0-9A-F]{4} .*title="EFI Firmware Setup"' "$spike_tmp/print1.txt" | cut -c5-8)
[[ -n $victim ]] || fail "no EFI Firmware Setup entry to delete"
order=$(grep '^BootOrder' "$spike_tmp/print1.txt" | sed 's/.*boot order: //; s/,//g')
read -r -a keep <<< "${order//$victim/}"
vfv --inplace "$vars" -d "Boot$victim" > /dev/null 2>&1
set_vars "BootOrder=$(u16le "${keep[@]}")"
print_vars > "$spike_tmp/print3.txt"
grep -q "^Boot$victim " "$spike_tmp/print3.txt" && fail "Boot$victim still present"
grep '^BootOrder' "$spike_tmp/print3.txt" | grep -q "$victim" && fail "BootOrder still lists $victim"
pass "wipe: Boot$victim deleted; $(grep '^BootOrder' "$spike_tmp/print3.txt" | tr -s ' ')"
