#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# Spike: a real Arch install (pacstrap, mkinitcpio, systemd-boot) on
# an AHCI disk boots alone under OVMF and prints its BOOT-OK marker to the
# serial port, where the host reads it. This is also the arch-sdboot recipe.
#
#   sudo tests/spikes/serial-marker.sh
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

img=$spike_tmp/arch.img
start=$SECONDS
base_load arch-sdboot
build_arch "$img" spike-arch plain
pass "built a minimal Arch install in $((SECONDS - start)) s ($(du -h --apparent-size "$img" | cut -f1) image, $(du -h "$img" | cut -f1) used)"

cp "$ovmf_vars" "$spike_tmp/vars.fd"
mapfile -t disk < <(ahci_disk "$img")
start=$SECONDS
qemu_ovmf "$spike_tmp/vars.fd" "$spike_tmp/serial.log" "${disk[@]}"
wait_serial "$spike_tmp/serial.log" '^BOOT-OK spike-arch' 180 \
    || fail "no BOOT-OK within 180 s; serial tail: $(tr -d '\r' < "$spike_tmp/serial.log" | tail -n 15)"
stop_qemu
pass "BOOT-OK on the serial port after $((SECONDS - start)) s"
