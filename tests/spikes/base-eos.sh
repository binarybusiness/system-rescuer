#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# Spike: the eos-sdboot base recipe (the workstation's shape): EndeavourOS
# packages, dracut through kernel-install, LUKS2 + btrfs (@, @home), and
# systemd-boot with BLS entries on /efi. It boots alone under OVMF, takes its
# passphrase on the serial console and reaches BOOT-OK.
#
#   sudo tests/spikes/base-eos.sh
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

pass_file=$spike_tmp/passphrase
( umask 077; printf '%s' "$(head -c 18 /dev/urandom | base64 | tr -d '/+=')" > "$pass_file" )
img=$spike_tmp/eos.img
start=$SECONDS
base_load eos-sdboot
build_eos "$img" spike-eos "$pass_file"
pass "built the EOS-shaped install in $((SECONDS - start)) s ($(du -h "$img" | cut -f1) used)"

cp "$ovmf_vars" "$spike_tmp/vars.fd"
mapfile -t disk < <(ahci_disk "$img")
sock=$spike_tmp/serial.sock log=$spike_tmp/serial.log
start=$SECONDS
qemu_ovmf_sock "$spike_tmp/vars.fd" "$sock" "$log" "${disk[@]}"
wait_serial "$log" 'Please enter passphrase' 120 \
    || fail "no passphrase prompt on the serial console; tail: $(tr -d '\r' < "$log" | tail -n 15)"
pass "dracut's passphrase prompt on the serial console after $((SECONDS - start)) s"
sleep 1
type_serial "$sock" "$pass_file"
wait_serial "$log" '^BOOT-OK spike-eos' 180 \
    || fail "no BOOT-OK after the passphrase; tail: $(tr -d '\r' < "$log" | tail -n 15)"
stop_qemu
pass "unlocked and reached BOOT-OK after $((SECONDS - start)) s"
grep -qF -f "$pass_file" "$log" && fail "the passphrase appears in the serial log"
pass "the passphrase does not appear in the serial log"
