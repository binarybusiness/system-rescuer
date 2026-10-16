#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# Targeted test for tests/leak-check.sh: builds a scratch repository with
# planted leaks (some only in an old, since-deleted commit) and a planted
# denylist file and a planted patterns file, then asserts each is found by
# category and location without ever printing the matched text. Planted
# values are assembled at run time, so this file itself holds none and the
# checker finds nothing here. Run only this test and shellcheck; the
# project's other tests boot virtual machines.
set -uo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
leak_check="$here/leak-check.sh"
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
failed=0

denylist_word="MYSECRETDENYWORD123"
denylist_file="$scratch/denylist"
printf '# scratch denylist\n%s\n' "$denylist_word" > "$denylist_file"

# Scratch private patterns: a trailer-like category, a custom category and a
# planning file name, none of them the owner's real entries.
patterns_file="$scratch/patterns"
trailer_word="scratch-trail""er:"
printf '# scratch patterns\ndev:trailer\t(?i)^%s\nmarker\tPLANTED-MARK\\d+\nplanning-file\t^PLAN-NOTES\\.md$\n' \
    "$trailer_word" > "$patterns_file"

# Values assembled from parts, so that no leak is spelled out in this file.
at="@"
ipv4="192.168"".1.50"
mac="02:de:ad:be"":ef:01"
leak_email="test.leak${at}example.com"
cite="Pha""se 12"
todo_marker="TO""DO(Pha""se 7)"
trailer_line="${trailer_word} 1234567890abcdef"
trailer_msg="${trailer_word} fedcba0987654321"

repo="$scratch/repo"
mkdir -p "$repo"
git -C "$repo" init -q -b main
git -C "$repo" config user.name "Scratch Tester"
git -C "$repo" config user.email "scratch-tester${at}example.invalid"

leak_lines() {
    cat <<EOF
private ipv4: $ipv4
mac address: $mac
email: $leak_email
denylist: $denylist_word
phase ref: $cite
todo marker: $todo_marker
custom: PLANTED-MARK42
$trailer_line
EOF
}

leak_lines > "$repo/secret-old.txt"
git -C "$repo" add secret-old.txt
git -C "$repo" commit -q -m "$(printf 'add old fixture\n\n%s\n' "$trailer_msg")"
old_commit=$(git -C "$repo" rev-parse --short=12 HEAD)

git -C "$repo" rm -q secret-old.txt
git -C "$repo" commit -q -m "remove old fixture"

leak_lines > "$repo/current-leak.txt"
mkdir -p "$repo/machines/$denylist_word"
echo "a machine profile" > "$repo/machines/$denylist_word/profile.md"
echo "private planning notes" > "$repo/PLAN-NOTES.md"
# An image's date label, six hyphenated pairs inside a longer run, a time
# range and a systemd unit's instance: no MAC, no email.
printf 'label: 2026-10-15-18-43-40-00\nboot 10:31:02-10:31:07\nunit getty%stty1.service\n' "$at" > "$repo/date-label.txt"
git -C "$repo" add current-leak.txt machines PLAN-NOTES.md date-label.txt
git -C "$repo" commit -q -m "add current fixture"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; failed=1; }

assert_rc() {
    local label=$1 actual=$2 expected=$3
    if [[ $actual -eq $expected ]]; then
        pass "$label"
    else
        fail "$label (expected exit $expected, got $actual)"
    fi
}

assert_found() {
    local label=$1 out=$2 pattern=$3
    if grep -q -- "$pattern" <<< "$out"; then
        pass "$label"
    else
        fail "$label (expected to match: $pattern)"
    fi
}

assert_absent_everywhere() {
    local label=$1 needle=$2
    shift 2
    local bad=0 text
    for text in "$@"; do
        grep -qF -- "$needle" <<< "$text" && bad=1
    done
    if (( bad )); then
        fail "$label"
    else
        pass "$label"
    fi
}

run_check() {
    # Captures stdout/stderr separately and the exit status, without
    # tripping -e (the checker's own findings-found exit status is 1).
    local out_file=$1 err_file=$2
    shift 2
    "$leak_check" "$@" > "$out_file" 2> "$err_file"
    echo $?
}

# --- --tree: leaks present in the current checkout -----------------------

tree_out=$(mktemp) tree_err=$(mktemp)
tree_rc=$(run_check "$tree_out" "$tree_err" --tree "$repo" --denylist "$denylist_file" --patterns "$patterns_file")
tree_stdout=$(cat "$tree_out") tree_stderr=$(cat "$tree_err")

assert_rc "tree: exit 1 with findings" "$tree_rc" 1
assert_found "tree: private-ipv4 found" "$tree_stdout" '^private-ipv4	'
assert_found "tree: mac-address found" "$tree_stdout" '^mac-address	'
assert_absent_everywhere "tree: a date label, a time range and a unit are no mac-address or email" "date-label.txt" "$tree_stdout"
assert_found "tree: email found" "$tree_stdout" '^email	'
assert_found "tree: denylist found" "$tree_stdout" '^denylist	'
assert_found "tree: a denylisted path name found, masked" "$tree_stdout" '^denylist	machines/<denylisted>/profile.md'
assert_absent_everywhere "tree: denylist word never printed" "$denylist_word" "$tree_stdout" "$tree_stderr"
if grep -q '^trailer	' <<< "$tree_stdout"; then
    fail "tree: a dev: category stays off without --dev-process"
else
    pass "tree: a dev: category stays off without --dev-process"
fi

tree_dev_out=$(mktemp) tree_dev_err=$(mktemp)
tree_dev_rc=$(run_check "$tree_dev_out" "$tree_dev_err" --tree "$repo" --denylist "$denylist_file" --patterns "$patterns_file" --dev-process)
tree_dev_stdout=$(cat "$tree_dev_out")
assert_rc "tree --dev-process: exit 1" "$tree_dev_rc" 1
assert_found "tree --dev-process: planning-id (a phase citation) found" "$tree_dev_stdout" '^planning-id	current-leak.txt:'
assert_found "tree --dev-process: planning-todo (a phase-named marker) found" "$tree_dev_stdout" '^planning-todo	current-leak.txt:'
assert_found "tree --dev-process: private trailer category found in a file" "$tree_dev_stdout" '^trailer	'
assert_found "tree --dev-process: private custom category found" "$tree_dev_stdout" '^marker	current-leak.txt:'
assert_found "tree --dev-process: private planning file found" "$tree_dev_stdout" '^planning-file	PLAN-NOTES.md:'
rm -f "$tree_out" "$tree_err" "$tree_dev_out" "$tree_dev_err"

# --- --history: a leak that exists only in an old, deleted commit --------

hist_out=$(mktemp) hist_err=$(mktemp)
hist_rc=$(run_check "$hist_out" "$hist_err" --history "$repo" --denylist "$denylist_file" --patterns "$patterns_file" --dev-process)
hist_stdout=$(cat "$hist_out") hist_stderr=$(cat "$hist_err")

assert_rc "history: exit 1 with findings" "$hist_rc" 1
assert_found "history: private-ipv4 found at the deleting-surviving old commit" "$hist_stdout" "^private-ipv4	${old_commit}:"
assert_found "history: mac-address found at the old commit" "$hist_stdout" "^mac-address	${old_commit}:"
assert_found "history: email found at the old commit" "$hist_stdout" "^email	${old_commit}:"
assert_found "history: denylist found at the old commit" "$hist_stdout" "^denylist	${old_commit}:"
assert_found "history: planning-id (a phase citation) found at the old commit" "$hist_stdout" "^planning-id	${old_commit}:"
assert_found "history: private trailer category found in a file" "$hist_stdout" "^trailer	${old_commit}:secret-old.txt:"
assert_found "history: private trailer category found in a commit message" "$hist_stdout" "^trailer	${old_commit}:message$"
assert_absent_everywhere "history: planted pattern never printed" "PLANTED-MARK" "$hist_stdout" "$hist_stderr"
assert_absent_everywhere "history: denylist word never printed" "$denylist_word" "$hist_stdout" "$hist_stderr"
rm -f "$hist_out" "$hist_err"

# --- agent-session is unconditional, including private-only scans ----------

agent_repo="$scratch/agent-session"
mkdir -p "$agent_repo"
git -C "$agent_repo" init -q -b main
git -C "$agent_repo" config user.name "Scratch Tester"
git -C "$agent_repo" config user.email "scratch-tester${at}example.invalid"
session_url_prefix="https://claude.ai/code/"
session_url="${session_url_prefix}session_fixture"
printf '%s\n' "$session_url" > "$agent_repo/session-url.txt"
agent_out=$(mktemp) agent_err=$(mktemp)
agent_rc=$(run_check "$agent_out" "$agent_err" --tree "$agent_repo" --denylist /dev/null --patterns /dev/null)
assert_rc "agent-session: tree URL refused" "$agent_rc" 1
assert_found "agent-session: tree URL reports category and location" "$(cat "$agent_out")" '^agent-session[[:space:]]session-url.txt:1$'
session_url_pattern='claude.ai/code/''session_'
if grep -qF "$session_url_pattern" "$agent_out" "$agent_err"; then
    fail "agent-session: matched URL is never printed"
else
    pass "agent-session: matched URL is never printed"
fi
printf '  Claude-Session: fixture-id\n' > "$agent_repo/session-trailer.txt"
agent_rc=$(run_check "$agent_out" "$agent_err" --tree "$agent_repo" --denylist /dev/null --patterns /dev/null)
assert_rc "agent-session: tree trailer refused" "$agent_rc" 1
assert_found "agent-session: tree trailer location reported" "$(cat "$agent_out")" '^agent-session[[:space:]]session-trailer.txt:1$'

git -C "$agent_repo" add -A
git -C "$agent_repo" commit -q -m 'tree fixtures'
git -C "$agent_repo" commit --allow-empty -q -m $'history fixture\n\n  Claude-Session: history-id'
agent_rc=$(run_check "$agent_out" "$agent_err" --history "$agent_repo" --denylist /dev/null --patterns /dev/null)
assert_rc "agent-session: history Claude-Session trailer refused" "$agent_rc" 1
assert_found "agent-session: history message location reported" "$(cat "$agent_out")" '^agent-session[[:space:]].*:message$'
claude_noreply="noreply${at}anthropic.com"
git -C "$agent_repo" commit --allow-empty -q -m $'history fixture\n\nCo-Authored-By: Claude <'"$claude_noreply"'>'
agent_rc=$(run_check "$agent_out" "$agent_err" --history "$agent_repo" --denylist /dev/null --patterns /dev/null)
assert_rc "agent-session: history Claude co-author refused" "$agent_rc" 1
assert_found "agent-session: co-author message location reported" "$(cat "$agent_out")" '^agent-session[[:space:]].*:message$'
agent_rc=$(run_check "$agent_out" "$agent_err" --history "$agent_repo" --private-only --denylist /dev/null --patterns /dev/null)
assert_rc "agent-session: --private-only without --dev-process refuses" "$agent_rc" 1
assert_found "agent-session: --private-only retains category" "$(cat "$agent_out")" '^agent-session[[:space:]]'

agent_negative="$scratch/agent-negative"
mkdir -p "$agent_negative"
printf '%s\n' 'Claude discussed the session format in prose.' 'Co-Authored-By: Human Example' > "$agent_negative/clean.txt"
agent_rc=$(run_check "$agent_out" "$agent_err" --tree "$agent_negative" --denylist /dev/null --patterns /dev/null)
assert_rc "agent-session: ordinary prose and human co-author pass" "$agent_rc" 0
rm -f "$agent_out" "$agent_err"

# --- a clean tree exits 0 with no findings --------------------------------

clean=$(mktemp -d)
echo "nothing to see here" > "$clean/plain.txt"
clean_out=$(mktemp) clean_err=$(mktemp)
clean_rc=$(run_check "$clean_out" "$clean_err" --tree "$clean" --denylist "$denylist_file" --patterns "$patterns_file")
clean_stdout=$(cat "$clean_out")
if [[ $clean_rc -eq 0 && -z $clean_stdout ]]; then
    pass "clean tree: exit 0, no findings"
else
    fail "clean tree: exit 0, no findings (got rc=$clean_rc, stdout=$clean_stdout)"
fi
rm -rf "$clean"
rm -f "$clean_out" "$clean_err"

# --- public snapshot identity: exactly two denylist exemptions ------------

public_owner="binary""business"
public_email="81260583+${public_owner}${at}users.noreply.github.com"
public_author="${public_owner} <${public_email}>"
other_word="OTHERDENYWORD456"
identity_denylist="$scratch/identity-denylist"
printf '%s\n%s\n' "$public_owner" "$other_word" > "$identity_denylist"
identity_tree="$scratch/identity-tree"
mkdir -p "$identity_tree/lib"
printf 'public_repo=%s/system-rescuer\npublic_author=%s\n' "$public_owner" "$public_author" > "$identity_tree/lib/release-layout.sh"

identity_out=$(mktemp) identity_err=$(mktemp)
identity_rc=$(run_check "$identity_out" "$identity_err" --tree "$identity_tree" --denylist "$identity_denylist" --patterns /dev/null)
assert_rc "identity: the two layout assignments are exempt" "$identity_rc" 0

printf 'other=%s\n' "$public_owner" >> "$identity_tree/lib/release-layout.sh"
identity_rc=$(run_check "$identity_out" "$identity_err" --tree "$identity_tree" --denylist "$identity_denylist" --patterns /dev/null)
assert_rc "identity: another layout line is refused" "$identity_rc" 1
sed -i '$d' "$identity_tree/lib/release-layout.sh"
printf '%s\n' "$public_owner" > "$identity_tree/other.txt"
identity_rc=$(run_check "$identity_out" "$identity_err" --tree "$identity_tree" --denylist "$identity_denylist" --patterns /dev/null)
assert_rc "identity: another file is refused" "$identity_rc" 1
rm "$identity_tree/other.txt"
printf 'public_repo=%s/system-rescuer %s\n' "$public_owner" "$other_word" >> "$identity_tree/lib/release-layout.sh"
identity_rc=$(run_check "$identity_out" "$identity_err" --tree "$identity_tree" --denylist "$identity_denylist" --patterns /dev/null)
assert_rc "identity: another denylisted word on an exempt line is refused" "$identity_rc" 1
sed -i '$d' "$identity_tree/lib/release-layout.sh"
no_layout="$scratch/no-layout"
mkdir "$no_layout"
printf '%s\n' "$public_owner" > "$no_layout/plain.txt"
identity_rc=$(run_check "$identity_out" "$identity_err" --tree "$no_layout" --denylist "$identity_denylist" --patterns /dev/null)
assert_rc "identity: no layout grants no exemption" "$identity_rc" 1

git -C "$identity_tree" init -q -b main
git -C "$identity_tree" add lib/release-layout.sh
GIT_AUTHOR_NAME="${public_author% <*}" GIT_AUTHOR_EMAIL="$public_email" \
    GIT_COMMITTER_NAME="${public_author% <*}" GIT_COMMITTER_EMAIL="$public_email" \
    git -C "$identity_tree" commit -q -m clean
identity_rc=$(run_check "$identity_out" "$identity_err" --history "$identity_tree" --denylist "$identity_denylist" --patterns /dev/null)
assert_rc "identity: public author history passes" "$identity_rc" 0
identity_author="$scratch/identity-author"
git clone -q "$identity_tree" "$identity_author"
GIT_AUTHOR_NAME="${public_author% <*}" GIT_AUTHOR_EMAIL="$public_email" \
    GIT_COMMITTER_NAME="${public_author% <*}" GIT_COMMITTER_EMAIL="$public_email" \
    git -C "$identity_tree" commit --allow-empty -q -m "$public_owner"
identity_rc=$(run_check "$identity_out" "$identity_err" --history "$identity_tree" --denylist "$identity_denylist" --patterns /dev/null)
assert_rc "identity: a commit message is refused" "$identity_rc" 1
printf 'clean\n' > "$identity_author/clean.txt"
git -C "$identity_author" add clean.txt
GIT_AUTHOR_NAME="${public_author% <*}x" GIT_AUTHOR_EMAIL="$public_email" \
    GIT_COMMITTER_NAME="${public_author% <*}x" GIT_COMMITTER_EMAIL="$public_email" \
    git -C "$identity_author" commit -q -m clean
identity_rc=$(run_check "$identity_out" "$identity_err" --history "$identity_author" --denylist "$identity_denylist" --patterns /dev/null)
assert_rc "identity: near-miss author is refused" "$identity_rc" 1
rm -f "$identity_out" "$identity_err"

# --- allow-list: reviewed findings are not reported ------------------------

# Each case runs a copy of the checker beside its own allow-list, since the
# checker reads the list that sits next to it.
uuid_parts=(0a1b2c3d 4e5f 6789 abcd ef0123456789)
uuid_value="${uuid_parts[0]}-${uuid_parts[1]}-${uuid_parts[2]}-${uuid_parts[3]}-${uuid_parts[4]}"
allow_tree="$scratch/allow-tree"
mkdir -p "$allow_tree/fixtures" "$allow_tree/other"
printf 'ip %s\nmail %s\n' "$ipv4" "$leak_email" > "$allow_tree/fixtures/config.txt"
printf 'uuid %s\n' "$uuid_value" > "$allow_tree/fixtures/uuid.txt"
printf 'ip %s\n' "$ipv4" > "$allow_tree/other/config.txt"

allow_case() {
    # allow_case <name> <allow-list text>: prints the copied checker's path.
    local dir="$scratch/allow-$1"
    mkdir -p "$dir"
    cp -- "$leak_check" "$dir/leak-check.sh"
    printf '%s' "$2" > "$dir/leak-check.allow"
    printf '%s' "$dir/leak-check.sh"
}

allow_out=$(mktemp) allow_err=$(mktemp)
allow_script=$(allow_case entries "$(printf '# scratch allow-list\nprivate-ipv4\tfixtures/config.txt\nfixtures/uuid.txt\nmac-address\tnothing/here.txt\n')")
"$allow_script" --tree "$allow_tree" --denylist /dev/null --patterns /dev/null > "$allow_out" 2> "$allow_err"
allow_rc=$?
allow_stdout=$(cat "$allow_out")
assert_rc "allow-list: exit 1 while an unlisted finding remains" "$allow_rc" 1
assert_found "allow-list: the same category in an unlisted file is reported" "$allow_stdout" $'^private-ipv4\tother/config.txt:1$'
assert_found "allow-list: another category in a listed file is still reported" "$allow_stdout" $'^email\tfixtures/config.txt:2$'
if grep -q -e $'^private-ipv4\tfixtures/config.txt:' <<< "$allow_stdout"; then
    fail "allow-list: a listed private-ipv4 finding is not reported"
else
    pass "allow-list: a listed private-ipv4 finding is not reported"
fi
if grep -q -e $'^fs-uuid\t' <<< "$allow_stdout"; then
    fail "allow-list: a bare glob allows fs-uuid"
else
    pass "allow-list: a bare glob allows fs-uuid"
fi
rm -f "$allow_out" "$allow_err"

allow_out=$(mktemp) allow_err=$(mktemp)
allow_script=$(allow_case all "$(printf 'private-ipv4\tfixtures/*\nprivate-ipv4\tother/config.txt\nemail\tfixtures/config.txt\nfixtures/uuid.txt\n')")
"$allow_script" --tree "$allow_tree" --denylist /dev/null --patterns /dev/null > "$allow_out" 2> "$allow_err"
allow_rc=$?
assert_rc "allow-list: exit 0 once every finding is listed" "$allow_rc" 0
rm -f "$allow_out" "$allow_err"

for bad in denylist planning-id agent-session; do
    allow_out=$(mktemp) allow_err=$(mktemp)
    allow_script=$(allow_case "bad-$bad" "$(printf '# scratch allow-list\n%s\tfixtures/config.txt\n' "$bad")")
    "$allow_script" --tree "$allow_tree" --denylist /dev/null --patterns /dev/null > "$allow_out" 2> "$allow_err"
    allow_rc=$?
    assert_rc "allow-list: a $bad entry is a usage error" "$allow_rc" 2
    assert_found "allow-list: the $bad error names the line" "$(cat "$allow_err")" 'line 2 '
    rm -f "$allow_out" "$allow_err"
done

# --- a missing explicit --denylist file is a usage error ------------------

missing_out=$(mktemp) missing_err=$(mktemp)
missing_rc=$(run_check "$missing_out" "$missing_err" --tree "$repo" --denylist "$scratch/does-not-exist")
assert_rc "missing explicit denylist: exit 2" "$missing_rc" 2
rm -f "$missing_out" "$missing_err"

# --- patterns: a missing explicit file is an error, a missing default a notice

nopat_out=$(mktemp) nopat_err=$(mktemp)
nopat_rc=$(run_check "$nopat_out" "$nopat_err" --tree "$repo" --denylist "$denylist_file" --patterns "$scratch/does-not-exist")
assert_rc "missing explicit patterns: exit 2" "$nopat_rc" 2
def_out=$(mktemp) def_err=$(mktemp)
def_rc=$(HOME="$scratch/nohome" run_check "$def_out" "$def_err" --tree "$repo" --denylist "$denylist_file" --dev-process)
assert_rc "missing default patterns: runs, exit 1" "$def_rc" 1
assert_found "missing default patterns: skip notice on stderr" "$(cat "$def_err")" 'private pattern checks skipped'
if grep -q -e '^trailer	' -e '^marker	' -e '^planning-file	' "$def_out"; then
    fail "missing default patterns: no private category reported"
else
    pass "missing default patterns: no private category reported"
fi
rm -f "$nopat_out" "$nopat_err" "$def_out" "$def_err"

# --- --private-only: the generic categories are dropped, the rest stay -----

po_out=$(mktemp) po_err=$(mktemp)
po_rc=$(run_check "$po_out" "$po_err" --tree "$repo" --private-only --denylist "$denylist_file" --patterns "$patterns_file")
assert_rc "private-only: exit 1" "$po_rc" 1
assert_found "private-only: denylist still found" "$(cat "$po_out")" '^denylist	'
assert_found "private-only: private category still found" "$(cat "$po_out")" '^marker	'
if grep -q -e '^private-ipv4	' -e '^email	' -e '^mac-address	' "$po_out"; then
    fail "private-only: no generic category reported"
else
    pass "private-only: no generic category reported"
fi
rm -f "$po_out" "$po_err"

if (( failed )); then
    echo "leak-check-test: FAILED"
    exit 1
fi
echo "leak-check-test: all assertions passed"
exit 0
