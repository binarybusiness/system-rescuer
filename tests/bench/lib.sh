# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# shellcheck shell=bash
# Shared helpers for the scenario bench: the scratch directory
# and its cleanup here, the rest in modules it sources: qemu.sh (guests),
# bases.sh (bases, second systems, base builders), target.sh (the scenario
# disk on the host), rescue.sh (the rescue system over SSH) and owner.sh
# (the stand-in owner). Source it, then call bench_init:
#
#   . "$(dirname "${BASH_SOURCE[0]}")/bench/lib.sh"
#   bench_init <name>
#
#   BENCH_MEM=<MiB>             guest memory (default 1024)
#   BENCH_STALL_RETRIES=<n>     restarts after an OVMF disk stall (default 1)
#   BENCH_KEEP=1                keep the scratch directory
#   BENCH_CACHE=<dir>           the cache (default ~/.cache/system-rescuer of
#                               the invoking user, $SUDO_USER under sudo)
# shellcheck disable=SC2034  # variables used by the sourcing scripts

# root_path, shared with the break scripts.
# shellcheck source=tests/bench/break-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/break-lib.sh"
# The user configuration: rescue_ssh_identity for the SSH helpers.
# shellcheck source=lib/rescue-config.sh
. "$(dirname "${BASH_SOURCE[0]}")/../../lib/rescue-config.sh"

ovmf_code=/usr/share/edk2/x64/OVMF_CODE.4m.fd
ovmf_vars=/usr/share/edk2/x64/OVMF_VARS.4m.fd

bench_user=${SUDO_USER:-$(id -un)}
bench_cache=${BENCH_CACHE:-$(getent passwd "$bench_user" | cut -d: -f6)/.cache/system-rescuer}
bench_pids=() bench_exit_hooks=() bench_overlays=() qemu_last=()
bench_loops=() bench_maps=() bench_mounts=()

# bench_init <name>: a scratch directory in $bench_tmp, removed on exit with
# every guest, loop device, mapping, mount and overlay the script started.
bench_init() {
    bench_name=$1
    bench_tmp=$(mktemp -d "${TMPDIR:-/tmp}/bench-$bench_name.XXXXXX")
    trap bench_cleanup EXIT
}
bench_cleanup() {
    local pid hook
    for hook in "${bench_exit_hooks[@]}"; do $hook || true; done
    for pid in "${bench_pids[@]}"; do
        kill "$pid" 2>/dev/null && wait "$pid" 2>/dev/null
    done
    release_build
    for hook in "${bench_overlays[@]}"; do rm -f -- "$hook"; done
    if findmnt -rn -o TARGET | grep -q "^$bench_tmp/"; then
        printf '%s: mounts remain under %s; not deleting it\n' "$bench_name" "$bench_tmp" >&2
    elif [[ -n ${BENCH_KEEP:-} ]]; then
        printf '%s: kept %s\n' "$bench_name" "$bench_tmp" >&2
    else
        rm -rf --one-file-system -- "$bench_tmp"
    fi
}

pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# bench_user_dir <dir>: create the directory (and missing parents under the
# user's home) owned by the invoking user, never by root.
bench_user_dir() {
    [[ -d $1 ]] && return 0
    bench_user_dir "$(dirname "$1")"
    install -d -o "$bench_user" -g "$(id -gn "$bench_user")" -- "$1"
}

# shellcheck source=tests/bench/qemu.sh
. "$(dirname "${BASH_SOURCE[0]}")/qemu.sh"
# shellcheck source=tests/bench/bases.sh
. "$(dirname "${BASH_SOURCE[0]}")/bases.sh"
# shellcheck source=tests/bench/target.sh
. "$(dirname "${BASH_SOURCE[0]}")/target.sh"
# shellcheck source=tests/bench/rescue.sh
. "$(dirname "${BASH_SOURCE[0]}")/rescue.sh"
# shellcheck source=tests/bench/owner.sh
. "$(dirname "${BASH_SOURCE[0]}")/owner.sh"
