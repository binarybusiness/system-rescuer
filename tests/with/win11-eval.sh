# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# shellcheck shell=bash disable=SC2034,SC2154  # read by tests/bench/lib.sh's with_load, which sets bench_tmp
# win11-eval: a real Windows 11 beside the scenario's Linux: a
# copy of the cached Windows 11 Enterprise evaluation install
# (tests/win11-image.sh), BitLocker on with the TPM and a recovery password,
# on a disk of its own with its own ESP, as on a machine where Windows came
# on its own disk; and a copy of its TPM's state. The firmware store is
# Windows' own, with the scenario disk's entries added ahead of the Windows
# Boot Manager entry Windows' setup wrote. The whole machine, in the rescue
# run and in every oracle's boot, is the one Windows was installed on
# (tests/bench/win11.sh: q35, the Secure Boot capable firmware, a swtpm per
# boot on that state), since BitLocker asks for its recovery key when the
# firmware's measurements change. The oracles' boots add the display, the
# four CPUs and the 6 GiB of memory it was installed with, the display ahead
# of the disks as then: without a display BitLocker asks for its recovery
# key, and with fewer CPUs or 4 GiB Windows did not boot in seven minutes.
# Only with_esp=own.
# The interface is in tests/scenario.sh.
# shellcheck source=../bench/win11.sh
. "$(dirname "${BASH_SOURCE[0]}")/../bench/win11.sh"
with_summary="real Windows 11 (evaluation), BitLocker on, on its own disk with its own ESP"
with_marker=WINDOWS-BOOT-OK
with_bitlocker=1
with_path='\EFI\Microsoft\Boot\bootmgfw.efi'
ovmf_code=$win11_code
BENCH_MEM=6144
win11_tpm=''
with_oracle_args=(-smp 4 -device VGA)

with_setup() {
    [[ $4 == own ]] || fail "win11-eval: Windows' boot files are on its own disk's ESP only (with_esp=own)"
    win11_with_setup win11-eval "$1" "$3"
    pass "win11-eval: Windows 11 with BitLocker on its own disk (installed $(jq -r .built "$win11_stem.json")), on its firmware store, Windows Boot Manager after ${win11_order[*]} in BootOrder"
}

with_qemu() {
    [[ -n $win11_tpm ]] || { echo "win11-eval: with_setup has not run" >&2; return 1; }
    win11_machine "$win11_tpm" "$bench_tmp" || return 1
    with_qemu_args=("${win11_args[@]}")
}
