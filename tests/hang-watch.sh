#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# rescue-hang-watch on a real process in uninterruptible I/O: a read of a
# suspended device-mapper device over a loop file stays in state D until the
# device resumes. A stand-in "opencode" (a script of that name) runs the read
# under a shell that plays rescue-agent; the watchdog must leave a sleeping
# child alone, then record the stuck read and stop the stand-in.
#
#   sudo tests/hang-watch.sh
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(dirname "$here")
# shellcheck source=bench/lib.sh
. "$here/bench/lib.sh"
[[ $EUID -eq 0 ]] || fail "needs root for losetup and dmsetup: sudo tests/hang-watch.sh"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/hang-watch.XXXXXX")
dm=hang-watch-$$ loop=''
cleanup() {
    dmsetup resume "$dm" 2> /dev/null || true
    sleep 1
    dmsetup remove "$dm" 2> /dev/null || true
    [[ -z $loop ]] || losetup -d "$loop" 2> /dev/null || true
    rm -rf -- "$tmp"
}
trap cleanup EXIT

truncate -s 16M "$tmp/disk.img"
loop=$(losetup --find --show "$tmp/disk.img")
dmsetup create "$dm" --table "0 32768 linear $loop 0"
mkdir "$tmp/bin"
# The stand-in agent: a copy of bash named opencode, so its process name is
# the agent's, running a script that sleeps (state S), then reads the
# device, which hangs in state D once it is suspended.
cp /usr/bin/bash "$tmp/bin/opencode"
cat > "$tmp/agent.sh" << EOF
sleep 6
dd if=/dev/mapper/$dm of=/dev/null bs=4096 count=1 iflag=direct status=none &
wait
EOF

export RESCUE_HANG_SECONDS=3 RESCUE_HANG_POLL=1 RESCUE_HANG_FILE=$tmp/hung-command
watch=$repo/profile/airootfs/usr/local/bin/rescue-hang-watch
# The stand-in by its full path: never the host's own opencode.
# shellcheck disable=SC2016  # expanded by the stand-in rescue-agent's shell
bash -c '"$1" $$ & "$2" "$3"; echo $? > "$4"; wait' _ "$watch" "$tmp/bin/opencode" "$tmp/agent.sh" "$tmp/rc" &
agent=$!

sleep 5
[[ ! -e $RESCUE_HANG_FILE ]] || fail "the watchdog acted on a sleeping process: $(cat "$RESCUE_HANG_FILE")"
pass "a sleeping child for 5 s (limit 3 s) is left alone"
dmsetup suspend "$dm"
for _ in $(seq 30); do [[ -s $tmp/rc ]] && break; sleep 1; done
[[ -s $tmp/rc ]] || fail "the stand-in agent was not stopped within 30 s of the read hanging"
read -r pid secs cmd < "$RESCUE_HANG_FILE" || fail "no hung-command record"
[[ $cmd == "dd if=/dev/mapper/$dm "* ]] || fail "the record names the wrong command: $cmd"
(( secs >= 3 )) || fail "the record says $secs s, under the 3 s limit"
pass "the read stuck in state D was recorded ($pid, $secs s: $cmd)"
rc=$(< "$tmp/rc")
[[ $rc == 143 ]] || fail "the stand-in agent ended with $rc, not SIGTERM's 143"
pass "the stand-in agent was stopped with SIGTERM"
dmsetup resume "$dm"
wait "$agent" || true
pass "rescue-hang-watch stops an agent whose command hangs in uninterruptible I/O"
