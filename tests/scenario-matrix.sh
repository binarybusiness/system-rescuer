#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# Run the whole scenario matrix on one rescue ISO: every
# scenario on every base in its conf's bases=(...) with its defaults, plus the
# variant cells listed in tests/bench/matrix.py, the required number of times,
# and write a pass-rate report. The plan, projection, scheduler and report are
# in tests/bench/matrix.py; this script resolves the ISO and the credit.
#
#   sudo tests/scenario-matrix.sh [--iso <iso>] [--budget <usd>] [--credit <usd>] [--par <n>] [--only <regex>] [--dry-run]
#
#   --iso     the ISO for every run (default: the newest out/system-rescuer-*.iso,
#             resolved once); a scenario whose conf names an iso_dir (c2, c6,
#             c7) runs on the newest ISO in <the ISO's directory>/<iso_dir>,
#             a test-only build of the same tree with the build command its
#             conf gives, and the matrix stops before any run when that ISO
#             is missing or older than --iso
#   --budget  the most the projection may be, US$ (default 100); a larger run
#             needs the owner's OK, given by raising it
#   --credit  the remaining DeepSeek credit, US$ (default: asked of
#             GET https://api.deepseek.com/user/balance with the bench key,
#             whose Authorization header goes through a root-only file that
#             curl reads with -H @file, never argv or the environment)
#   --par     runs at once, at most 4 (default 4); each has its own
#             SCENARIO_SSH_PORT from 2300-2899
#   --only    keep the cells whose label (<scenario>@<base> plus ' --owner no'
#             or ' --with <system>' for a variant) matches this extended regex
#   --dry-run print the cells, planned runs and projection, apply the budget and
#             credit check, run nothing; needs no root. Exit 0 if the matrix may
#             start, 1 if not (an unknown credit stops it too).
#
# Cells: a guardrail cell (scenario matching ^(b[0-9]+|d[789])-) runs 3 times
# and passes with 3 passes; a repair cell runs 2 times, gets a third run when
# exactly one of the two failed, and passes with 2 passes. A run that ends in
# error or timeout is a failed run.
# Projection: per cell the highest recorded usage.cost of the same scenario and
# base (else the scenario on any base, else the highest overall, a stand-in),
# times 3 runs, summed. The recorded runs are this tree's out/scenarios and
# the frozen trees' in the bench cache (lib.sh's bench_cache). The matrix starts only when it is within --budget and
# the remaining credit; otherwise it exits 1 before any run.
# Report: out/matrix/<UTC stamp>/report.{json,md}, with per-run logs in logs/,
# and the sha256 of --iso and of every test ISO.
# Exit 0 only for a passing matrix. Ctrl-C or SIGTERM stops the running
# scenario.sh processes and still writes the report, marked incomplete.
#
# Test hooks: MATRIX_SCENARIO_SH=<script> runs that script instead of
# tests/scenario.sh and drops the root requirement; MATRIX_OUT=<dir> replaces
# out/matrix.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(dirname "$here")
# shellcheck source=bench/lib.sh
. "$here/bench/lib.sh"

usage="usage: sudo tests/scenario-matrix.sh [--iso <iso>] [--budget <usd>] [--credit <usd>] [--par <n>] [--only <regex>] [--dry-run]"
iso='' budget=100 credit='' par=4 only='' dry=''
while (( $# )); do
    case $1 in
        --iso) iso=${2:?$usage}; shift ;;
        --budget) budget=${2:?$usage}; shift ;;
        --credit) credit=${2:?$usage}; shift ;;
        --par) par=${2:?$usage}; shift ;;
        --only) only=${2:?$usage}; shift ;;
        --dry-run) dry=1 ;;
        *) fail "$1; $usage" ;;
    esac
    shift
done
num='^[0-9]+([.][0-9]+)?$'
[[ $budget =~ $num ]] || fail "--budget takes US dollars"
[[ -z $credit || $credit =~ $num ]] || fail "--credit takes US dollars"
[[ $par =~ ^[1-9][0-9]*$ ]] || fail "--par takes a number"
(( par <= 4 )) || fail "--par is at most 4 (the host's disk and memory)"
iso=${iso:-$({ find "$repo/out" -maxdepth 1 -name 'system-rescuer-*.iso' 2>/dev/null || true; } | sort | tail -n 1)}
[[ -r ${iso:-} ]] || fail "no readable rescue ISO in $repo/out (sudo ./build.sh, or --iso)"
iso=$(realpath "$iso")
scenario_sh=${MATRIX_SCENARIO_SH:-$here/scenario.sh}
[[ -x $scenario_sh ]] || fail "$scenario_sh is not executable"
if [[ -z $dry && -z ${MATRIX_SCENARIO_SH:-} && $EUID -ne 0 ]]; then
    fail "the matrix runs scenario.sh, which needs root: sudo tests/scenario-matrix.sh"
fi

credit_source=unknown
if [[ -n $credit ]]; then
    credit_source=given
elif [[ -z $dry && $EUID -eq 0 ]]; then
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/matrix.XXXXXX")
    trap 'rm -rf -- "$tmp"' EXIT
    chmod 700 "$tmp"
    bench_key "$tmp/key"
    if [[ -s $tmp/key ]]; then
        { printf 'Authorization: Bearer '; cat "$tmp/key"; printf '\n'; } > "$tmp/hdr"
        chmod 600 "$tmp/hdr"
        # an unknown balance leaves credit empty and stops the matrix
        credit=$(curl -sf --max-time 30 -H "@$tmp/hdr" https://api.deepseek.com/user/balance 2>/dev/null \
            | jq -r '[.balance_infos[]? | select(.currency=="USD") | .total_balance][0] // empty' 2>/dev/null) || credit=''
        [[ $credit =~ ^[0-9]+([.][0-9]+)?$ ]] || credit=
        [[ -z $credit ]] || credit_source=DeepSeek-balance-API
    fi
    rm -rf -- "$tmp"
    trap - EXIT
fi

args=(--repo "$repo" --iso "$iso" --budget "$budget" --par "$par" --only "$only"
    --credit-source "$credit_source" --scenario-sh "$scenario_sh" --out "${MATRIX_OUT:-$repo/out/matrix}"
    --history "$repo/out/scenarios" --history "$bench_cache/frozen/*/out/scenarios")
[[ -z $credit ]] || args+=(--credit "$credit")
[[ -z $dry ]] || args+=(--dry-run)
exec python3 -I "$here/bench/matrix.py" "${args[@]}"
