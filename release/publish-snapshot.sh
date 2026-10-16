#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# Make one local public-repository snapshot from this private working tree.
#
#   release/publish-snapshot.sh <clone> [--author 'Name <email>']
#       (--message <text> | --message-file <file>) [--dry-run]
#
# <clone> is a clean local clone of the public repository. The script exports
# this tree into scratch space, makes the clone match it, checks it, and makes
# one commit; it never pushes. Snapshot commits carry one `Snapshot:` trailer
# containing the sha256 of a canonical listing of exported paths, modes, and
# blob bytes. The trailer is the durable public-history marker used to reject
# uncarried public commits. An initial public repository may be unborn, or may
# contain exactly one empty-tree initialization commit.
#
# Refusals and check failures restore the clone to HEAD. Runs unprivileged.
# Exit: 0 committed (or dry-run passed), 1 refused or check failed, 2 usage.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=lib/release-layout.sh
. "$here/lib/release-layout.sh"

usage() {
    echo "usage: release/publish-snapshot.sh <clone> [--author 'Name <email>'] (--message <text> | --message-file <file>) [--dry-run] [--denylist <file>] [--patterns <file>]" >&2
    exit 2
}
die() { printf 'publish-snapshot: %s\n' "$*" >&2; exit 1; }

clone='' author=$public_author message='' message_file='' dry_run=0 denylist='' patterns=''
while (($#)); do
    case $1 in
        --author|--message|--message-file|--denylist|--patterns)
            [[ $# -ge 2 ]] || usage
            case $1 in
                --author) author=$2 ;;
                --message) message=$2 ;;
                --message-file) message_file=$2 ;;
                --denylist) denylist=$2 ;;
                --patterns) patterns=$2 ;;
            esac
            shift 2 ;;
        --dry-run) dry_run=1; shift ;;
        -*) usage ;;
        *) [[ -z $clone ]] || usage; clone=$1; shift ;;
    esac
done
[[ -n $clone ]] || usage
[[ -z $message || -z $message_file ]] || usage
if [[ -n $message_file ]]; then
    [[ -r $message_file ]] || die "cannot read message file"
    message=$(<"$message_file")
fi
[[ -n ${message//[[:space:]]/} ]] || die "the message is empty"
(( EUID != 0 )) || die "refusing to run as root"
[[ $author =~ ^[^[:space:]\<\>][^\<\>]*\ \<[^[:space:]\<\>@]+@[^[:space:]\<\>@]+\>$ ]] \
    || die "the author is not in Name <email> form"
command -v git >/dev/null || die "git is needed"
command -v sha256sum >/dev/null || die "sha256sum is needed"
command -v gitleaks >/dev/null || die "gitleaks is needed"

clone=$(realpath -m -- "$clone")
git -C "$clone" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || die "$clone is not a git work tree"
top=$(git -C "$clone" rev-parse --show-toplevel) || die "$clone is not a git work tree"
[[ $top == "$clone" ]] || die "$clone is not the top of a git work tree"
case $clone/ in
    "$here"/*|"$here"/) die "$clone is this repository or inside it" ;;
esac
case $here/ in
    "$clone"/*|"$clone"/) die "$clone is this repository or inside it" ;;
esac
branch=$(git -C "$clone" symbolic-ref --quiet --short HEAD) || die "$clone is not on a branch"
[[ -z $(git -C "$clone" status --porcelain --untracked-files=all) ]] \
    || die "$clone has a dirty work tree or untracked files"

# A user-supplied trailer would make the marker ambiguous or add public
# process metadata. The committed message has only the supplied prose and the
# marker below.
[[ -z $(git interpret-trailers --parse <<< "$message") ]] \
    || die "the message contains trailers"

denylist=${denylist:-$HOME/.config/system-rescuer/leak-denylist}
patterns=${patterns:-$HOME/.config/system-rescuer/leak-patterns}
[[ -r $denylist ]] || die "cannot read denylist file"
[[ -r $patterns ]] || die "cannot read patterns file"

head_exists=0
if git -C "$clone" rev-parse --verify -q HEAD >/dev/null; then head_exists=1; fi
snapshot_commit=''
if (( head_exists )); then
    while IFS=$'\t' read -r commit trailer; do
        if [[ $trailer =~ ^sha256:[0-9a-f]{64}$ ]]; then
            snapshot_commit=$commit
            break
        fi
    done < <(git -C "$clone" log --format='%H%x09%(trailers:key=Snapshot,valueonly)' HEAD)
fi
if [[ -n $snapshot_commit ]]; then
    outside=$(git -C "$clone" log --format='%h %s' "$snapshot_commit..HEAD")
    [[ -z $outside ]] || die "the clone has uncarried public commits after its last snapshot: $outside"
elif (( head_exists )); then
    count=$(git -C "$clone" rev-list --count HEAD)
    [[ $count == 1 ]] || die "the clone has no snapshot marker and is not an empty initial repository"
    empty_tree=$(git -C "$clone" hash-object -t tree /dev/null)
    initial_tree=$(git -C "$clone" rev-parse 'HEAD^{tree}')
    [[ $initial_tree == "$empty_tree" ]] \
        || die "the clone has no snapshot marker and its initial commit is not empty"
fi

scratch=$(mktemp -d "${TMPDIR:-/tmp}/publish-snapshot.XXXXXX") || die "cannot make scratch directory"
changed=0
restore() {
    local rc=$?
    if (( changed )); then
        git -C "$clone" reset --hard HEAD >/dev/null 2>&1 || true
        git -C "$clone" clean -fd -- >/dev/null 2>&1 || true
    fi
    rm -rf -- "$scratch"
    exit "$rc"
}
trap restore EXIT

export_dir=$scratch/export
"$here/tests/public-export.sh" "$export_dir" >/dev/null

# The listing has one NUL-delimited record per shipped file or symlink:
# path, mode, and Git's object id for its bytes. Sorting makes the marker
# independent of filesystem order.
listing=$scratch/listing
while IFS= read -r -d '' path; do
    mode=$(stat -c '%a' -- "$export_dir/$path")
    if [[ -L $export_dir/$path ]]; then
        object=$(readlink -- "$export_dir/$path" | git hash-object --stdin)
    else
        object=$(git hash-object --no-filters -- "$export_dir/$path")
    fi
    printf '%s\t%s\t%s\0' "$path" "$mode" "$object"
done < <(cd -- "$export_dir" && find -P . \( -type f -o -type l \) -printf '%P\0' | sort -z) > "$listing"
tree_sha=$(sha256sum -- "$listing")
tree_sha=${tree_sha%% *}

git -C "$clone" rm -r --ignore-unmatch -- . >/dev/null
cp -a -- "$export_dir/." "$clone/"
git -C "$clone" add -A
changed=1

git -C "$clone" status --short
git -C "$clone" diff --cached --stat
if git -C "$clone" diff --cached --quiet; then
    die "the exported tree makes no change to the clone"
fi

"$here/tests/leak-check.sh" --tree "$clone" --dev-process --denylist "$denylist" --patterns "$patterns"
( cd -- "$clone" && gitleaks git --staged --redact --no-banner )
metadata=$scratch/commit-metadata
name=${author% <*}
email=${author##*<}
email=${email%>}
mkdir -p -- "$metadata/lib"
cp -- "$here/lib/release-layout.sh" "$metadata/lib/release-layout.sh"
git -C "$metadata" init -q -b metadata
git -C "$metadata" add lib/release-layout.sh
GIT_AUTHOR_NAME=$name GIT_AUTHOR_EMAIL=$email GIT_COMMITTER_NAME=$name GIT_COMMITTER_EMAIL=$email \
    git -C "$metadata" commit --no-gpg-sign -q -m "$message"
"$here/tests/leak-check.sh" --tree "$metadata" --history "$metadata" --private-only --dev-process --denylist "$denylist" --patterns "$patterns"

commit_message="${message}"$'\n\n'"Snapshot: sha256:${tree_sha}"
if (( dry_run )); then
    echo "publish-snapshot: dry run passed; restoring $branch"
    exit 0
fi
GIT_AUTHOR_NAME=$name GIT_AUTHOR_EMAIL=$email GIT_COMMITTER_NAME=$name GIT_COMMITTER_EMAIL=$email \
    git -C "$clone" commit --no-gpg-sign -F - <<< "$commit_message"
changed=0
echo "publish-snapshot: committed snapshot on $branch"
