# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# shellcheck shell=bash disable=SC2034,SC2154  # read by tests/bench/lib.sh's with_load, which sets bench_tmp
# win11-hibernated: a real Windows 11 beside the scenario's Linux, hibernated
# in full with the owner's work open: a copy of the
# cached install without BitLocker (tests/win11-image.sh --plain), so its
# NTFS is readable from Linux, on a disk of its own with its own ESP, set up
# as win11-eval is (tests/bench/win11.sh). Before the rescue run, with_prepare
# boots it once through its own firmware entry on the machine the oracles
# boot, disks and all, and its startup task hibernates it (shutdown /h):
# Windows resumes only on the machine it hibernated on. The marker is the
# one Windows prints once resumed, not at a fresh start, so the bootnext
# oracle passes only when the hibernation survived the rescue. Fast Startup
# does not happen in the VM, so a full hibernation stands in for it.
# Only with_esp=own.
# The interface is in tests/scenario.sh.
# shellcheck source=../bench/win11.sh
. "$(dirname "${BASH_SOURCE[0]}")/../bench/win11.sh"
with_summary="real Windows 11 (evaluation), hibernated, BitLocker off, on its own disk with its own ESP"
with_marker=SPIKE-RESUMED
with_path='\EFI\Microsoft\Boot\bootmgfw.efi'
ovmf_code=$win11_code
BENCH_MEM=6144
win11_tpm=''
with_oracle_args=(-smp 4 -device VGA)

with_setup() {
    [[ $4 == own ]] || fail "win11-hibernated: Windows' boot files are on its own disk's ESP only (with_esp=own)"
    win11_with_setup win11-hibernated "$1" "$3" --plain
    pass "win11-hibernated: Windows 11 without BitLocker on its own disk (installed $(jq -r .built "$win11_stem.json")), on its firmware store, Windows Boot Manager after ${win11_order[*]} in BootOrder"
}

# with_prepare <vars> <free-ahci-port> <qemu args...>: boot Windows through
# its own entry (BootNext, on a copy of the store) on the oracles' machine,
# with the control CD on the free port, and wait for it to hibernate and power
# off. shutdown /h returns only once Windows has resumed, so its result line
# (SPIKE-SHUTDOWN) comes after the resume; one before the power-off means it
# did not hibernate.
with_prepare() {
    local vars=$1 port=$2 dir=$bench_tmp/hibernate entry
    shift 2
    win11_control_cd "$dir" hibernate-full || fail "win11-hibernated: cannot make the control CD"
    entry=$(efi_query "$vars" entries | awk -F'\t' '$2 == "Windows Boot Manager" {print $1; exit}')
    [[ -n $entry ]] || fail "win11-hibernated: no Windows Boot Manager entry in the scenario's store"
    cp -- "$vars" "$dir/vars.fd"
    efi_bootnext "$dir/vars.fd" "$entry" || fail "win11-hibernated: cannot set BootNext"
    BENCH_STALL_RETRIES=0 boot_wait "$dir/vars.fd" "$dir/serial.log" '' '^SPIKE-ACTION hibernate-full' 600 "$@" \
        -drive if=none,id=ctl,media=cdrom,readonly=on,file="$dir/ctl.iso" -device ide-cd,drive=ctl,bus=ahci."$port" \
        || { stop_qemu; fail "win11-hibernated: Windows did not reach its hibernation within 600 s: $(serial_text "$dir/serial.log" | tail -n 1 | cut -c1-160)"; }
    qemu_exited 300 || { stop_qemu; fail "win11-hibernated: Windows did not power off within 300 s of shutdown /h"; }
    stop_qemu
    ! serial_matches "$dir/serial.log" '^SPIKE-SHUTDOWN' || fail "win11-hibernated: shutdown /h returned before the power-off: $(tr -d '\r' < "$dir/serial.log" | grep -a '^SPIKE-SHUTDOWN' | cut -c1-160)"
    pass "win11-hibernated: Windows hibernated in full (shutdown /h) on the oracles' machine and powered off"
}

with_qemu() {
    [[ -n $win11_tpm ]] || { echo "win11-hibernated: with_setup has not run" >&2; return 1; }
    win11_machine "$win11_tpm" "$bench_tmp" || return 1
    with_qemu_args=("${win11_args[@]}")
}
