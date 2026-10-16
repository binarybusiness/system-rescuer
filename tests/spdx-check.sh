#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# Check that every shipped source file names its licence: an
# "SPDX-License-Identifier:" line within its first five lines.
#
#   tests/spdx-check.sh [--tree <dir>] [--paths <file>]
#
# --tree is the tree to check (default: this repository); --paths lists the
# shipped files and directories relative to it, one per line with # comments
# (default: tests/public-paths). A source file is one with a shebang or a
# .sh, .py, .js, .ps1 or .cmd name; documentation, configuration and data
# files are covered by LICENSE and THIRD-PARTY-NOTICES.md instead. The disk
# playbooks copied from diskrepair are copied byte-identical and never edited,
# so they are left out here; the notices cover them.
#
# stdout: one "missing<TAB><path>" line per file without the line.
# Exit: 0 every source file has it, 1 at least one has not, 2 usage error.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tree=$here
paths_file=''
usage() { echo "usage: tests/spdx-check.sh [--tree <dir>] [--paths <file>]" >&2; exit 2; }
while (( $# )); do
    case $1 in
        --tree) [[ $# -ge 2 ]] || usage; tree=$2; shift ;;
        --paths) [[ $# -ge 2 ]] || usage; paths_file=$2; shift ;;
        *) usage ;;
    esac
    shift
done
[[ -d $tree ]] || { echo "spdx-check: no tree at $tree" >&2; exit 2; }
tree=$(cd -- "$tree" && pwd)
[[ -n $paths_file ]] || paths_file=$tree/tests/public-paths
[[ -r $paths_file ]] || { echo "spdx-check: cannot read $paths_file" >&2; exit 2; }

mapfile -t paths < <(sed -e 's/#.*//' -e 's/[[:space:]]*$//' -e '/^$/d' "$paths_file")
is_source() {
    case $1 in
        *.sh | *.py | *.js | *.ps1 | *.cmd) return 0 ;;
    esac
    [[ $(head -c 2 -- "$1" 2>/dev/null) == '#!' ]]
}

checked=0 missing=0
while IFS= read -r -d '' f; do
    rel=${f#"$tree"/}
    case $rel in
        profile/airootfs/root/diskrepair-playbooks/*) continue ;;
    esac
    is_source "$f" || continue
    checked=$(( checked + 1 ))
    if ! head -n 5 -- "$f" | grep -aq 'SPDX-License-Identifier:'; then
        printf 'missing\t%s\n' "$rel"
        missing=$(( missing + 1 ))
    fi
done < <(for p in "${paths[@]}"; do
             [[ -e $tree/$p ]] || continue
             find "$tree/$p" -type f -not -path '*/.git/*' -not -path '*/__pycache__/*' -print0
         done | sort -zu)

printf 'spdx-check: %d source files, %d without an SPDX line\n' "$checked" "$missing" >&2
(( missing == 0 ))
