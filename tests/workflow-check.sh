#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# Check that a fork's pull request can never reach a self-hosted runner: every
# self-hosted job carries the fork guard, no pull_request_target or workflow_run
# workflow has a self-hosted job, and a reusable-workflow call in a
# pull_request workflow carries the guard and none runs under
# pull_request_target or workflow_run.
#
#   tests/workflow-check.sh [--dir <workflows dir>]
#
# --dir is the directory of workflow files (default: this repository's
# .github/workflows). The parsing is in tests/workflow-check.py (PyYAML).
# stdout: one "<file>\t<job>\t<reason>" line per finding.
# Exit: 0 no findings, 1 at least one, 2 usage error, a missing directory, or
# a file that does not parse or is not a workflow.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
dir=$here/.github/workflows
usage() { echo "usage: tests/workflow-check.sh [--dir <workflows dir>]" >&2; exit 2; }
while (( $# )); do
    case $1 in
        --dir) [[ $# -ge 2 ]] || usage; dir=$2; shift ;;
        *) usage ;;
    esac
    shift
done
[[ -d $dir ]] || { echo "workflow-check: no directory at $dir" >&2; exit 2; }
exec python3 -I "$here/tests/workflow-check.py" "$dir"
