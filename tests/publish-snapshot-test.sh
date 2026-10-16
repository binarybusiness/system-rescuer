#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# Targeted test for release/publish-snapshot.sh: isolated private and public
# Git repositories exercise snapshot commits, refusals, and restoration.
# Unprivileged; boots nothing. The scratch directory is under
# ~/.cache/system-rescuer/ (override with PUBLISH_SNAPSHOT_TEST_DIR).
set -uo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
base=${PUBLISH_SNAPSHOT_TEST_DIR:-$HOME/.cache/system-rescuer/publish-snapshot-test}
mkdir -p -- "$base"
scratch=$(mktemp -d -- "$base/run.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
failed=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; failed=1; }
check() { # <name> <wanted 0|1> <command...>
    local name=$1 wanted=$2 got
    shift 2
    "$@" >"$scratch/out" 2>&1
    got=$?
    if { [[ $wanted == 0 ]] && (( got == 0 )); } || { [[ $wanted == 1 ]] && (( got != 0 )); }; then
        ok "$name"
    else
        bad "$name (exit $got)"
        sed -n '1,20p' "$scratch/out" | sed 's/^/     /'
    fi
}
contains() { grep -Fq -- "$2" "$1"; }

deny_word="SNAPSHOT""DENYWORD"
denylist=$scratch/denylist
patterns=$scratch/patterns
printf '%s\n' "$deny_word" > "$denylist"
: > "$patterns"
at=@
author="Public Tester <public.tester${at}example.invalid>"
test_email="test${at}example.invalid"
# shellcheck source=lib/release-layout.sh
. "$here/lib/release-layout.sh"
public_owner="binary""business"
handle_denylist=$scratch/handle-denylist
printf '%s\n' "$public_owner" > "$handle_denylist"

# The private test tree has its current working content committed so export
# sees the publisher and this test, even before their real commit is made.
source=$scratch/source
mkdir -- "$source"
cp -a -- "$here/." "$source/"
rm -rf -- "$source/.git"
# These are intentional fixtures of their own targeted tests. They exercise
# the real scanner there, but would make this independent clean-export setup
# fail before the publisher's own cases get a chance to run.
sed -i 's/PLANTEDDENYWORD/RELEASE_TEST_WORD/g' "$source/tests/release-test.sh"
planning_ref="B-""005"
sed -i "s/$planning_ref/boot-oracle/g" "$source/tests/bench/tamper/silent-boot.sh"
git -C "$source" init -q -b main
git -C "$source" config user.name Test
git -C "$source" config user.email "$test_email"
git -C "$source" add -A
git -C "$source" commit -q -m source
publisher=$source/release/publish-snapshot.sh
public=$scratch/public
git init -q -b main "$public"

default_public=$scratch/default-public
git init -q -b main "$default_public"

# shellcheck disable=SC2329 # check invokes this function by name.
run() { "$publisher" "$public" --author "$author" --message "$1" --denylist "$denylist" --patterns "$patterns"; }
# shellcheck disable=SC2329 # check invokes this function by name.
run_default() { "$publisher" "$default_public" --message "$1" --denylist "$handle_denylist" --patterns "$patterns"; }
check "first snapshot commits" 0 run 'First public snapshot'
first=$(git -C "$public" rev-parse HEAD)
if [[ $(git -C "$public" log -1 --format='%an <%ae>|%cn <%ce>') == "$author|$author" ]]; then
    ok "author and committer are supplied identity"
else
    bad "author and committer are supplied identity"
fi
message=$(git -C "$public" log -1 --format=%B)
if [[ $message == *'First public snapshot'* && $message == *'Snapshot: sha256:'* ]]; then
    ok "message has supplied prose and marker"
else
    bad "message has supplied prose and marker"
fi

check "default public author commits" 0 run_default 'Default public snapshot'
if [[ $(git -C "$default_public" log -1 --format='%an <%ae>|%cn <%ce>') == "$public_author|$public_author" ]]; then
    ok "default author and committer are the public identity"
else
    bad "default author and committer are the public identity"
fi
handle_author="${public_owner}x <81260583+${public_owner}${at}users.noreply.github.com>"
check "different author containing the public handle refuses" 1 "$publisher" "$default_public" --author "$handle_author" --message clean --denylist "$handle_denylist" --patterns "$patterns"

printf '\nPublic snapshot test change.\n' >> "$source/README.md"
check "second snapshot commits changed export" 0 run 'Second public snapshot'
second=$(git -C "$public" rev-parse HEAD)
if [[ $first != "$second" && $(git -C "$public" diff --name-only "$first" "$second") == README.md ]]; then
    ok "second commit contains only the changed file"
else
    bad "second commit contains only the changed file"
fi
check "unchanged export refuses" 1 run 'No-op public snapshot'

printf '\n%s\n' "$deny_word" >> "$source/README.md"
before=$(git -C "$public" rev-parse HEAD)
check "denylisted exported content refuses" 1 run 'Denied content'
if [[ $(git -C "$public" rev-parse HEAD) == "$before" && -z $(git -C "$public" status --porcelain) ]]; then
    ok "content refusal restores clone"
else
    bad "content refusal restores clone"
fi
git -C "$source" checkout -- README.md

check "denylisted message refuses" 1 run "$deny_word"
bad_author="$deny_word <public.tester${at}example.invalid>"
check "denylisted author refuses" 1 "$publisher" "$public" --author "$bad_author" --message clean --denylist "$denylist" --patterns "$patterns"

git -C "$public" commit --allow-empty -q -m 'Outside public contribution'
check "uncarried public commit refuses" 1 run 'Would overwrite contribution'
if contains "$scratch/out" 'Outside public contribution'; then
    ok "refusal names outside commit"
else
    bad "refusal names outside commit"
fi

dirty=$scratch/dirty
git clone -q "$public" "$dirty"
git -C "$dirty" config user.name Test
git -C "$dirty" config user.email "$test_email"
printf x > "$dirty/untracked"
check "dirty clone refuses" 1 "$publisher" "$dirty" --author "$author" --message clean --denylist "$denylist" --patterns "$patterns"
mkdir "$source/subclone"
git -C "$source/subclone" init -q -b main
check "clone inside private repository refuses" 1 "$publisher" "$source/subclone" --author "$author" --message clean --denylist "$denylist" --patterns "$patterns"
if command -v unshare >/dev/null && unshare -Ur true >/dev/null 2>&1; then
    check "root refuses" 1 unshare -Ur -- "$publisher" "$public" --author "$author" --message clean --denylist "$denylist" --patterns "$patterns"
else
    ok "root refusal skipped (unprivileged user namespaces unavailable)"
fi

exit "$failed"
