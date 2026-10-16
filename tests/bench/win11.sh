# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# shellcheck shell=bash
# The machine a real Windows runs on in the bench, shared by
# tests/win11-image.sh, which installs it, and tests/with/win11-eval.sh and
# win11-hibernated.sh, which put a copy beside a scenario's Linux: q35 with
# SMM and OVMF's Secure Boot capable firmware (Secure Boot off), S4 visible
# to the guest (without it Windows can neither hibernate nor use Fast
# Startup), and swtpm as its TPM 2.0. BitLocker seals its key to the
# firmware's measurements (PCR 0, 2, 4 and 11), so every boot of a Windows
# must use the firmware it was installed with. Source it after
# tests/bench/lib.sh.
# shellcheck disable=SC2034,SC2154  # variables used by, and set by, the sourcing scripts

win11_code=/usr/share/edk2/x64/OVMF_CODE.secboot.4m.fd

# win11_machine <tpm-state-dir> <run-dir>: start a swtpm for one guest on the
# TPM's state (a swtpm serves one connection, and ends with its guest), and
# set win11_args to the qemu arguments of the machine and its TPM. A swtpm
# left from the guest before is stopped first.
win11_machine() {
    local tpm=$1 dir=$2 pid
    command -v swtpm > /dev/null || { echo "no swtpm (pacman -S swtpm)" >&2; return 1; }
    if [[ -s $dir/swtpm.pid ]]; then
        pid=$(cat "$dir/swtpm.pid")
        kill "$pid" 2>/dev/null || true
        for _ in $(seq 50); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
    fi
    rm -f "$dir/swtpm.sock" "$dir/swtpm.pid"
    swtpm socket --tpm2 --tpmstate dir="$tpm" --ctrl type=unixio,path="$dir/swtpm.sock" \
        --pid file="$dir/swtpm.pid" --log file="$dir/swtpm.log" --terminate --daemon || return 1
    for _ in $(seq 50); do [[ -S $dir/swtpm.sock ]] && break; sleep 0.1; done
    [[ -S $dir/swtpm.sock ]] || { echo "swtpm did not open $dir/swtpm.sock" >&2; return 1; }
    # shellcheck disable=SC2054  # qemu option strings, not array separators
    win11_args=(-machine q35,smm=on -global driver=cfi.pflash01,property=secure,value=on -global ICH9-LPC.disable_s4=0
        -chardev "socket,id=chrtpm,path=$dir/swtpm.sock" -tpmdev emulator,id=tpm0,chardev=chrtpm -device tpm-crb,tpmdev=tpm0)
}

# win11_stop <run-dir>: stop the swtpm, if one is left.
win11_stop() { [[ ! -s $1/swtpm.pid ]] || kill "$(cat "$1/swtpm.pid")" 2>/dev/null || true; }

# win11_control_cd <dir> <action>: <dir>/ctl.iso, the CD (label SPIKECTL)
# whose action.txt tells Windows' startup task what to do once booted:
# off, hibernate (a hybrid shutdown) or hibernate-full (shutdown /h, then
# SPIKE-RESUMED after the resume).
win11_control_cd() {
    mkdir -p "$1/ctl" || return 1
    printf '%s\r\n' "$2" > "$1/ctl/action.txt"
    xorriso -as mkisofs -quiet -V SPIKECTL -J -r -o "$1/ctl.iso" "$1/ctl" 2>/dev/null
}

# win11_with_setup <name> <disks-dir> <vars> [win11-image.sh args...]: for a
# with file, put a copy of the cached install (tests/win11-image.sh) and of
# its TPM's state beside the scenario's Linux, and make the scenario's store
# <vars> Windows' own, Windows Boot Manager's entry as setup wrote it, with
# the base's entries for its systems added ahead of it: from the base's
# store, made on other firmware, BitLocker asked for its recovery key.
# Sets win11_tpm and win11_stem, and win11_order to the entries
# ahead of Windows'. The copy (21 GiB written of 64) goes beside the cache,
# where a reflink makes it at once, not into the run's temporary directory,
# which is usually a tmpfs; the disks directory gets a link to it.
win11_with_setup() {
    local name=$1 disks=$2 vars=$3 stem work entry title data j store added rest
    shift 3
    stem=$("$(dirname "${BASH_SOURCE[0]}")/../win11-image.sh" "$@" | tail -n 1)
    [[ -s $stem.img ]] || fail "$name: no cached install"
    work=$bench_cache/work/${bench_tmp##*/}
    bench_user_dir "$work"
    bench_exit_hooks+=("win11_stop $bench_tmp" "rm -rf --one-file-system -- $work")
    cp --reflink=auto -- "$stem.img" "$work/$name.img" || fail "$name: cannot copy $stem.img"
    cp -a -- "$stem.tpm" "$work/$name.tpm" || fail "$name: cannot copy its TPM's state"
    chown "$bench_user:" "$work/$name.img"
    ln -s -- "$work/$name.img" "$disks/$name.img"
    win11_tpm=$work/$name.tpm win11_stem=$stem
    entry=$(efi_query "$stem.vars.fd" entries | awk -F'\t' '$2 == "Windows Boot Manager" {print $1; exit}')
    [[ -n $entry ]] || fail "$name: no Windows Boot Manager entry in $stem.vars.fd"
    j=$(mktemp) store=$(mktemp)
    vfv -i "$vars" --output-json "$j" > /dev/null 2>&1 || fail "$name: cannot read $vars"
    cp -- "$stem.vars.fd" "$store"
    win11_order=()
    for title in $(efi_query "$vars" entries | awk -F'\t' '$3 != "-" {print $1}'); do
        data=$(jq -r --arg n "$title" '.variables[] | select(.name == $n) | .data' "$j")
        added=$(efi_add "$store" "$data") || fail "$name: cannot add $title to Windows' firmware store"
        win11_order+=("$added")
    done
    (( ${#win11_order[@]} )) || fail "$name: the base's store has no entry for its systems"
    mapfile -t rest < <(efi_query "$store" order | grep -vx -e "$entry" "${win11_order[@]/#/-e}")
    efi_order "$store" "${win11_order[@]}" "$entry" "${rest[@]}" || fail "$name: cannot reorder BootOrder"
    cp -- "$store" "$vars"
    rm -f -- "$j" "$store"
}
