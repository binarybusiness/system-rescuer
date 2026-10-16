#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# write-stick.sh must refuse NVMe, loop and non-device targets. Runs without
# root, so even a broken check cannot reach the write (it requires root).
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
[[ $EUID -ne 0 ]] || { echo "run this test as a normal user"; exit 2; }
failed=0

# expect_refusal <target> <pattern> [<extra argument>...]
expect_refusal() {
    local target=$1 pattern=$2 out
    shift 2
    out=$("$here/write-stick.sh" "$target" /etc/hostname "$@" 2>&1) && { echo "FAIL: $target accepted"; failed=1; return; }
    if grep -q "$pattern" <<< "$out"; then
        echo "PASS: $target refused ($out)"
    else
        echo "FAIL: $target refused for the wrong reason: $out"; failed=1
    fi
}

for nvme in /dev/nvme0n1 /dev/nvme1n1; do
    [[ -b $nvme ]] && expect_refusal "$nvme" "not a USB stick"
done
expect_refusal /dev/loop0 "not a USB stick"
expect_refusal /dev/null "not a block device"
expect_refusal "$here/README.md" "not a block device"
expect_refusal /dev/loop0 "usage:" extra   # a third argument is refused, not ignored
exit "$failed"
