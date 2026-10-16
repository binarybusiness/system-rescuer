#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# Spike: qemu's blkdebug driver injects read errors into a range of an
# AHCI disk, and the rescue system's kernel logs them as I/O errors on that
# disk while the rest of it stays readable. The rescue ISO boots without the
# agent (no API cost).
#
#   tests/spikes/blkdebug.sh [out/system-rescuer-*.iso]
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

iso=${1:-$(find "$(dirname "${BASH_SOURCE[0]}")/../../out" -maxdepth 1 -name 'system-rescuer-*.iso' | sort | tail -n 1)}
[[ -r ${iso:-} ]] || fail "no readable rescue ISO (build one, or pass its path)"
port=${SPIKE_SSH_PORT:-2231}

# A 64 MiB disk whose sector 65536 (32 MiB in) fails every read with EIO; a
# rule matches any request that covers its sector.
img=$spike_tmp/disk.img
truncate -s 64M "$img"
cat > "$spike_tmp/blkdebug.conf" <<'CONF'
[inject-error]
event = "read_aio"
iotype = "read"
errno = "5"
sector = "65536"
once = "off"
CONF

rescue_boot_noagent "$iso" "$port" "$spike_tmp/serial.log" \
    -device ahci,id=ahci \
    -blockdev driver=file,node-name=f0,filename="$img" \
    -blockdev driver=blkdebug,node-name=dbg0,image=f0,config="$spike_tmp/blkdebug.conf" \
    -blockdev driver=raw,node-name=d0,file=dbg0 \
    -device ide-hd,drive=d0,bus=ahci.0,serial=BADDISK
start=$SECONDS
wait_ssh "$port" 240 "$spike_tmp/serial.log" || fail "rescue system not reachable over SSH; serial tail: $(serial_tail "$spike_tmp/serial.log")"
pass "rescue ISO booted without the agent; SSH after $((SECONDS - start)) s"
rescue_ssh "$port" '! tmux has-session -t rescue 2>/dev/null && ! pgrep -f "[o]pencode"' || fail "the agent is running"
pass "no agent running"

dev=$(rescue_ssh "$port" lsblk -dno NAME,SERIAL | awk '$2 == "BADDISK" {print $1}')
[[ -n $dev ]] || fail "the blkdebug disk is not visible: $(rescue_ssh "$port" 'lsblk -o NAME,TRAN,SERIAL,SIZE')"
rescue_ssh "$port" "dd if=/dev/$dev of=/dev/null bs=1M count=8 iflag=direct status=none" || fail "the healthy range of /dev/$dev is unreadable"
pass "/dev/$dev (AHCI, serial BADDISK) reads its healthy first 8 MiB"
rescue_ssh "$port" "dd if=/dev/$dev of=/dev/null bs=4k skip=8192 count=16 iflag=direct status=none" 2> "$spike_tmp/dd.err" \
    && fail "reading the injected range succeeded"
pass "reading the injected range fails: $(tr '\n' ' ' < "$spike_tmp/dd.err" | cut -c1-120)"
rescue_ssh "$port" 'dmesg' > "$spike_tmp/dmesg.txt"
grep -E "I/O error, dev $dev, sector 6553[6-9] " "$spike_tmp/dmesg.txt" > "$spike_tmp/ioerr.txt" \
    || fail "dmesg logs no I/O error on $dev in the injected range; tail: $(tail -n 20 "$spike_tmp/dmesg.txt")"
pass "the kernel logs it: $(head -n 1 "$spike_tmp/ioerr.txt" | sed 's/^\[[^]]*\] //')"
stop_qemu
