#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# Spike: an Arch install with a LUKS2 root (sd-encrypt) asks for its
# passphrase on the serial console; the host types it there from a 0600 file
# (never argv) and the system reaches its BOOT-OK marker. The passphrase must
# not appear in the serial log.
#
#   sudo tests/spikes/luks-unlock.sh
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

pass_file=$spike_tmp/passphrase
( umask 077; printf '%s' "$(head -c 18 /dev/urandom | base64 | tr -d '/+=')" > "$pass_file" )  # no newline: --key-file uses every byte
img=$spike_tmp/arch-luks.img
start=$SECONDS
base_load arch-sdboot
build_arch "$img" spike-arch luks "$pass_file"
pass "built an Arch install with a LUKS2 root in $((SECONDS - start)) s"

cp "$ovmf_vars" "$spike_tmp/vars.fd"
mapfile -t disk < <(ahci_disk "$img")
sock=$spike_tmp/serial.sock log=$spike_tmp/serial.log
start=$SECONDS
qemu_ovmf_sock "$spike_tmp/vars.fd" "$sock" "$log" "${disk[@]}"
wait_serial "$log" 'Please enter passphrase' 120 \
    || fail "no passphrase prompt on the serial console; tail: $(tr -d '\r' < "$log" | tail -n 15)"
pass "passphrase prompt on the serial console after $((SECONDS - start)) s"
sleep 1  # let the prompt settle before typing
type_serial "$sock" "$pass_file"
wait_serial "$log" '^BOOT-OK spike-arch' 180 \
    || fail "no BOOT-OK after typing the passphrase; tail: $(tr -d '\r' < "$log" | tail -n 15)"
stop_qemu
pass "unlocked from the host and reached BOOT-OK after $((SECONDS - start)) s"
grep -qF -f "$pass_file" "$log" && fail "the passphrase appears in the serial log"
pass "the passphrase does not appear in the serial log"
