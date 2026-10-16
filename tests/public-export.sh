#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# Write the public tree: the product and its user documentation, without the
# files of how it was developed.
#
#   tests/public-export.sh <dir>
#
# <dir> must be missing or empty, and outside this repository. The tree is
# the tracked files (git ls-files, so a file added with git add -N counts)
# under the paths tests/public-paths lists, with their working-tree content
# and modes; then the contents of public/ are copied over its root. The
# exported tests/public-paths is this repository's list without public/ and
# with .github/workflows/, so the public CI's leak check scans what ships.
# A listed path that would bring in a planning or agent file, or a
# .gitleaks.toml that allowlists paths, fails the export, naming the file.
# Runs unprivileged. Exit: 0 written, 1 refused or failed, 2 usage error.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
paths_file=$here/tests/public-paths
overlay=public

die() { echo "public-export: $*" >&2; exit 1; }
[[ $# -eq 1 && $1 != -* ]] || { echo "usage: tests/public-export.sh <dir>" >&2; exit 2; }
(( EUID != 0 )) || die "refusing to run as root"
[[ -r $paths_file ]] || die "cannot read $paths_file"

dest=$(realpath -m -- "$1")
case $dest/ in
    "$here"/*) die "target $dest is inside the repository" ;;
esac
[[ ! -e $dest ]] || [[ -d $dest && -z $(ls -A -- "$dest") ]] || die "target $dest is not empty"
mkdir -p -- "$dest"
if git -C "$dest" rev-parse --git-dir >/dev/null 2>&1; then
    die "target $dest is inside a git repository"
fi

# Files that never ship, matched against paths relative to the tree root:
# the agent configuration and the planning documents (what of docs/ ships,
# the user documentation and the README's demo, is what the list names).
excluded_re='^(AGENTS\.md|CLAUDE\.md|ROADMAP[^/]*|research-manifest\.json|knowledge(/.*)?|\.claude(/.*)?|\.codex(/.*)?|\.githooks/pre-push|(.*/)?leak-patterns|(.*/)?leak-denylist|docs/(roadmap[^/]*|idea-brief\.md|features\.md|research\.md|(proposals|bugs|claims|decisions)/.*))$'
is_excluded() { [[ $1 =~ $excluded_re ]]; }

mapfile -t listed < <(sed -e 's/#.*//' -e 's/[[:space:]]*$//' -e '/^$/d' "$paths_file")
files=()
for p in "${listed[@]}"; do
    p=${p%/}
    [[ $p == "$overlay" ]] && continue
    found=0
    while IFS= read -r -d '' f; do
        found=1
        [[ -e $here/$f || -L $here/$f ]] || continue
        is_excluded "$f" && die "the list brings in $f, which never ships"
        files+=("$f")
    done < <(git -C "$here" ls-files -z -- "$p")
    (( found )) || die "listed path $p has no tracked file"
done

if grep -Eq '^[[:space:]]*(\[+allowlists?|paths[[:space:]]*=|regexTarget)' "$here/.gitleaks.toml"; then
    die ".gitleaks.toml has an allowlist; it would name paths this tree lacks"
fi

copy() { # <src root> <relative path> <to dir>
    mkdir -p -- "$3/$(dirname -- "$2")"
    cp -P --preserve=mode -- "$1/$2" "$3/$2"
}

for f in "${files[@]}"; do copy "$here" "$f" "$dest"; done

if [[ -d $here/$overlay ]]; then
    while IFS= read -r -d '' f; do
        [[ -e $here/$f || -L $here/$f ]] || continue
        rel=${f#"$overlay"/}
        is_excluded "$rel" && die "$f would bring in $rel, which never ships"
        copy "$here/$overlay" "$rel" "$dest"
    done < <(git -C "$here" ls-files -z -- "$overlay")
fi

# The exported list describes the exported tree.
{
    grep -Ev "^[[:space:]]*${overlay}/?[[:space:]]*(#.*)?$" "$paths_file"
    echo ".github/workflows/"
} > "$dest/tests/public-paths"

echo "public-export: wrote $(find "$dest" -type f | wc -l) files to $dest"
