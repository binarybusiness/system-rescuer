#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# Check that every shipped source file names its licence: an
# "SPDX-License-Identifier:" and the project's SPDX-FileCopyrightText
# within its first five lines. Copied upstream source keeps its own notices.
#
#   tests/spdx-check.sh [--tree <dir>] [--paths <file>]
#
# --tree is the tree to check (default: this repository); --paths lists the
# shipped files and directories relative to it, one per line with # comments
# (default: tests/public-paths). A source file is one with a shebang or a
# .sh, .py, .js, .ps1 or .cmd name; documentation, configuration and data
# files with SPDX licence headers are checked too; other documentation and
# data are covered by LICENSE and THIRD-PARTY-NOTICES.md. The disk
# playbooks copied from diskrepair are copied byte-identical and never edited,
# so they are left out here; the notices cover them.
#
# stdout: "missing<TAB><path>" or "missing-copyright<TAB><path>" findings.
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
[[ ! -f $tree/.githooks/pre-push ]] || paths+=(.githooks/pre-push)
is_source() {
    case $1 in
        *.sh | *.py | *.js | *.ps1 | *.cmd) return 0 ;;
    esac
    head -c 2 -- "$1" 2>/dev/null | grep -aq '^#!'
}

holder='SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)'
checked=0 missing=0 missing_holder=0
while IFS= read -r -d '' f; do
    rel=${f#"$tree"/}
    case $rel in
        profile/airootfs/root/diskrepair-playbooks/*) continue ;;
    esac
    if ! is_source "$f" && ! head -n 5 -- "$f" | grep -aq 'SPDX-License-Identifier:'; then
        continue
    fi
    checked=$(( checked + 1 ))
    if ! head -n 5 -- "$f" | grep -aq 'SPDX-License-Identifier:'; then
        printf 'missing\t%s\n' "$rel"
        missing=$(( missing + 1 ))
    fi
    case $rel in
        profile/airootfs/usr/local/bin/choose-mirror | \
        profile/airootfs/usr/local/bin/livecd-sound | \
        profile/airootfs/usr/local/bin/Installation_guide | \
        profile/airootfs/root/.automated_script.sh) continue ;;
    esac
    if ! head -n 5 -- "$f" | tr -d '\r' | grep -aqFx -e "# $holder" -e "// $holder" -e "REM $holder"; then
        printf 'missing-copyright\t%s\n' "$rel"
        missing_holder=$(( missing_holder + 1 ))
    fi
done < <(for p in "${paths[@]}"; do
             [[ -e $tree/$p ]] || continue
             find "$tree/$p" -type f -not -path '*/.git/*' -not -path '*/__pycache__/*' -print0
         done | sort -zu)

printf 'spdx-check: %d source/tagged files, %d without a licence, %d without the project holder\n' "$checked" "$missing" "$missing_holder" >&2
(( missing == 0 && missing_holder == 0 ))
