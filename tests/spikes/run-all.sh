#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# Run the feasibility spikes that need no API key, one after another, and report
# each one's exit status. Root is needed for the base builders and the LUKS and
# marker spikes; the rest run as $SUDO_USER. The stand-in owner and the command
# record spend API credit and are run on their own:
#
#   sudo tests/spikes/run-all.sh [iso]
#   DEEPSEEK_API_KEY=... tests/spikes/standin-owner.sh
#   tests/spikes/command-record.sh [iso]
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
[[ $EUID -eq 0 && -n ${SUDO_USER:-} ]] || { echo "run with sudo from your user account" >&2; exit 1; }
iso=${1:-}
as_user() { sudo -u "$SUDO_USER" -- "$@"; }
failed=0
run() {  # run <label> <command...>
    local start=$SECONDS rc
    "${@:2}" > "/tmp/spike-run-$1.log" 2>&1
    rc=$?
    printf '%-16s %s (%d s)\n' "$1" "$([[ $rc -eq 0 ]] && echo PASS || echo "FAIL rc=$rc, see /tmp/spike-run-$1.log")" $((SECONDS - start))
    (( rc == 0 )) || failed=$((failed + 1))
}
run ovmf-vars        as_user "$here/ovmf-vars.sh"
run serial-marker    "$here/serial-marker.sh"
run luks-unlock      "$here/luks-unlock.sh"
run blkdebug         as_user "$here/blkdebug.sh" ${iso:+"$iso"}
run base-eos         "$here/base-eos.sh"
run base-debian      "$here/base-cloud.sh" debian
run base-fedora      "$here/base-cloud.sh" fedora
run base-nixos       as_user "$here/base-nixos.sh"
(( failed == 0 ))
