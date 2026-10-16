#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# Diagnostic: boot a kept EOS-shaped image N times (snapshot, fresh
# vars each time) and count how often dracut's passphrase prompt appears.
# A boot without it keeps OVMF's debug port log and the vCPU registers.
#
#   sudo [SPIKE_BUS=virtio] [SPIKE_WAIT=<s>] tests/spikes/eos-boot-repeat.sh <eos.img> [N] [extra qemu args...]
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

img=${1:?usage: eos-boot-repeat.sh <eos.img> [N]}
n=${2:-5}
shift $(( $# >= 2 ? 2 : 1 ))
ok=0
BENCH_STALL_RETRIES=0  # count stalls here, do not paper over them
if [[ ${SPIKE_BUS:-ahci} == virtio ]]; then
    disk=(-drive "if=virtio,format=raw,snapshot=on,file=$img")
else
    # shellcheck disable=SC2054  # commas belong to the qemu options
    disk=(-device ahci,id=ahci -drive "if=none,id=disk0,format=raw,snapshot=on,file=$img" -device ide-hd,drive=disk0,bus=ahci.0)
fi
for (( i = 1; i <= n; i++ )); do
    cp "$ovmf_vars" "$spike_tmp/vars.fd"
    log=$spike_tmp/serial-$i.log mon=$spike_tmp/mon-$i.sock
    start=$SECONDS
    qemu_ovmf "$spike_tmp/vars.fd" "$log" "${disk[@]}" \
        -debugcon file:"$spike_tmp/debugcon-$i.log" -global isa-debugcon.iobase=0x402 \
        -monitor unix:"$mon",server=on,wait=off "$@"
    if wait_serial "$log" 'Please enter passphrase' "${SPIKE_WAIT:-45}"; then
        ok=$((ok + 1))
        printf 'boot %d: prompt after %d s\n' "$i" $((SECONDS - start))
    else
        printf 'boot %d: no prompt in %d s; serial bytes %s, debugcon bytes %s\n' "$i" "${SPIKE_WAIT:-45}" \
            "$(wc -c < "$log")" "$(wc -c < "$spike_tmp/debugcon-$i.log")"
        for _ in 1 2 3 4 5; do
            printf 'info registers\n' | socat - UNIX-CONNECT:"$mon" >> "$spike_tmp/regs-$i.txt" 2>&1 || true
            sleep 0.3
        done
        printf '  RIP samples: %s\n' "$(grep -aoE 'RIP=[0-9a-f]+' "$spike_tmp/regs-$i.txt" | cut -d= -f2 | paste -sd ' ')"
    fi
    stop_qemu
done
pass "$ok of $n boots reached the passphrase prompt"
