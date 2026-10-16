# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# shellcheck shell=bash
# Shared helpers for the scenario-bench feasibility spikes.
# Source it from a spike: . "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck disable=SC2034  # variables used by the sourcing spikes

# shellcheck source=../bench/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../bench/lib.sh"
bench_init "$(basename "${BASH_SOURCE[1]:-spike}" .sh)"
spike_name=$bench_name spike_tmp=$bench_tmp

# owner_wait_question <seconds>: wait for the stand-in owner's dialog to open.
owner_wait_question() {
    local deadline=$((SECONDS + $1))
    until owner_question_open; do (( SECONDS < deadline )) || return 1; sleep 2; done
}

# virt-fw-vars from PyPI's virt-firmware, run through uv (not packaged in Arch).
vfv() { uv tool run --quiet --from virt-firmware virt-fw-vars "$@"; }

# rescue_boot_noagent <iso> <ssh-port> <serial-log> [qemu args...]: boot the
# rescue ISO under OVMF without starting the agent (no API cost): its kernel
# and initramfs are booted directly with tty1's getty masked, so the autologin
# that runs rescue-agent-start never happens. The ISO is attached read-only
# (snapshot) as a USB stick, SSH is forwarded to 127.0.0.1:<ssh-port>, and the
# kernel console goes to the serial log.
rescue_boot_noagent() {
    local iso=$1 port=$2 serial=$3 uuid BENCH_MEM=${BENCH_MEM:-4096}  # the 250 MB initramfs needs room to unpack
    shift 3
    bsdtar -xf "$iso" -C "$spike_tmp" arch/boot/x86_64/vmlinuz-linux arch/boot/x86_64/initramfs-linux.img
    uuid=$(bsdtar -xOf "$iso" loader/entries/01-archiso-linux.conf | sed -n 's/.*archisosearchuuid=\([^ ]*\).*/\1/p')
    [[ -n $uuid ]] || fail "no archisosearchuuid in $iso"
    cp "$ovmf_vars" "$spike_tmp/rescue-vars.fd"
    qemu_ovmf "$spike_tmp/rescue-vars.fd" "$serial" -smp 2 \
        -kernel "$spike_tmp/arch/boot/x86_64/vmlinuz-linux" -initrd "$spike_tmp/arch/boot/x86_64/initramfs-linux.img" \
        -append "archisobasedir=arch archisosearchuuid=$uuid systemd.mask=getty@tty1.service console=ttyS0,115200" \
        -device qemu-xhci -drive if=none,id=stick,format=raw,snapshot=on,readonly=on,file="$iso" \
        -device usb-storage,drive=stick \
        -netdev user,id=net0,hostfwd=tcp:127.0.0.1:"$port"-:22 -device virtio-net-pci,netdev=net0 "$@"
}
