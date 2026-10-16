#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# Scan a working tree and/or a Git repository's full history for personal
# data and traces of the private development process, before this repository
# is published from a scrubbed snapshot. Reports category and location only;
# it never prints a matched value, a denylist entry, or a line's content, so
# its output is itself safe to paste into a report. A denylisted public-repo
# owner is exempt only when it is parsed as text (never sourced) from
# lib/release-layout.sh: on that file's public_repo= or public_author=
# assignment line, or in a history author/committer identity exactly equal to
# public_author. All other denylisted matches, including another word on an
# exempt assignment line, remain findings.
#
#   tests/leak-check.sh [--tree <dir> [--paths <file>]] [--history <repo>] [--dev-process] [--private-only] [--denylist <file>] [--patterns <file>]
#
# At least one of --tree / --history is required; both may be given.
# --paths limits the tree scan to the files and directories <file> lists
# (one path relative to the tree per line; # comments), such as
# tests/public-paths, the part of this repository that ships.
# --dev-process additionally flags citations of planning ids and phase-named
# TODO markers, which match any project's planning documents.
# --private-only drops the generic categories below and reports only the
# denylist and the patterns file's categories, for a scan whose generic
# findings are expected (a whole operating system image).
# agent-session is the exception: agent-session links and trailers are never
# public, so that category remains enabled even with --private-only.
# agent-session matches Claude session URLs, Claude-Session trailer lines and
# Co-Authored-By trailer lines naming Claude; it is never allow-listed.
# --denylist overrides the default ~/.config/system-rescuer/leak-denylist
# (one literal word per line, matched case-insensitively, whole-word).
# --patterns overrides the default ~/.config/system-rescuer/leak-patterns,
# the private patterns for the owner's own development-process vocabulary,
# which this script does not publish. One entry per line:
# <category><TAB><PCRE>; blank lines and # comments are ignored. A category
# names a finding class and several entries may share it. The reserved
# category planning-file matches a whole path relative to the tree (or a
# history path name) and is checked only with --dev-process; every other
# category matches file and blob content and path names, as the generic
# categories below do. A category written dev:<category> applies only with
# --dev-process. A missing default file is skipped with a notice, as
# for the denylist; a missing explicit one is an error.
#
# tests/leak-check.allow, beside this script, lists reviewed findings that are
# not reported: one "<category><TAB><path glob>" per line, the glob matched
# against the finding's path (a bare glob is an fs-uuid entry). Only the
# generic categories can be listed; an entry naming any other category is a
# usage error, so a denylisted word or a planning id cannot be allowed.
#
# stdout: one "<category>\t<location>" line per finding, deduplicated.
# stderr: skip notices (missing denylist or patterns, skipped binaries) then
#         a per category finding count.
# Locations are masked where they name a denylisted word.
# Exit: 0 no findings, 1 at least one finding, 2 usage or runtime error
#       (including an allow-list entry that cannot be allowed).
#
# This does not replace gitleaks (secrets); it looks for personal data and
# development-process traces, which are a different kind of leak.
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
allow_file="$script_dir/leak-check.allow"

usage() {
    echo "usage: tests/leak-check.sh [--tree <dir> [--paths <file>]] [--history <repo>] [--dev-process] [--private-only] [--denylist <file>] [--patterns <file>]" >&2
    exit 2
}

tree_dir=
paths_file=
history_repo=
dev_process=0
private_only=0
denylist_file="$HOME/.config/system-rescuer/leak-denylist"
denylist_explicit=0
patterns_file="$HOME/.config/system-rescuer/leak-patterns"
patterns_explicit=0

while (($#)); do
    case $1 in
        --tree)
            [[ $# -ge 2 ]] || usage
            tree_dir=$2
            shift 2
            ;;
        --paths)
            [[ $# -ge 2 ]] || usage
            paths_file=$2
            shift 2
            ;;
        --history)
            [[ $# -ge 2 ]] || usage
            history_repo=$2
            shift 2
            ;;
        --dev-process)
            dev_process=1
            shift
            ;;
        --private-only)
            private_only=1
            shift
            ;;
        --denylist)
            [[ $# -ge 2 ]] || usage
            denylist_file=$2
            denylist_explicit=1
            shift 2
            ;;
        --patterns)
            [[ $# -ge 2 ]] || usage
            patterns_file=$2
            patterns_explicit=1
            shift 2
            ;;
        *)
            usage
            ;;
    esac
done

[[ -n $tree_dir || -n $history_repo ]] || usage
[[ -z $paths_file || -n $tree_dir ]] || usage
if [[ -n $paths_file ]]; then
    [[ -r $paths_file ]] || { echo "leak-check: cannot read the paths file: $paths_file" >&2; exit 2; }
fi
if [[ -n $tree_dir ]]; then
    [[ -d $tree_dir ]] || { echo "leak-check: not a directory: $tree_dir" >&2; exit 2; }
fi
if [[ -n $history_repo ]]; then
    git -C "$history_repo" rev-parse --git-dir >/dev/null 2>&1 \
        || { echo "leak-check: not a git repository: $history_repo" >&2; exit 2; }
fi

work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
results="$work/results.tsv"
: > "$results"

# --- denylist -----------------------------------------------------------

declare -a denylist_words=()
if [[ ! -r $denylist_file ]]; then
    if (( denylist_explicit )); then
        echo "leak-check: cannot read denylist file: $denylist_file" >&2
        exit 2
    fi
    echo "leak-check: no denylist at $denylist_file; denylist checks skipped" >&2
else
    while IFS= read -r line || [[ -n $line ]]; do
        [[ -z ${line//[[:space:]]/} ]] && continue
        [[ $line == \#* ]] && continue
        denylist_words+=("$line")
    done < "$denylist_file"
fi

# --- private patterns -------------------------------------------------------

declare -A private_pattern=()
planning_file_pattern=
if [[ ! -r $patterns_file ]]; then
    if (( patterns_explicit )); then
        echo "leak-check: cannot read patterns file: $patterns_file" >&2
        exit 2
    fi
    echo "leak-check: no patterns at $patterns_file; private pattern checks skipped" >&2
else
    while IFS=$'\t' read -r pcat ppat || [[ -n $pcat ]]; do
        [[ -z ${pcat//[[:space:]]/} || $pcat == \#* || -z $ppat ]] && continue
        if [[ $pcat == dev:* ]]; then
            (( dev_process )) || continue
            pcat=${pcat#dev:}
        fi
        if [[ $pcat == planning-file ]]; then
            planning_file_pattern+="${planning_file_pattern:+|}(?:$ppat)"
        else
            private_pattern[$pcat]+="${private_pattern[$pcat]:+|}(?:$ppat)"
        fi
    done < "$patterns_file"
fi

escape_regex() {
    printf '%s' "$1" | sed -e 's/[][\\.^$*+?(){}|]/\\&/g'
}

denylist_pattern=
if ((${#denylist_words[@]})); then
    escaped=()
    for w in "${denylist_words[@]}"; do
        escaped+=("$(escape_regex "$w")")
    done
    joined=$(IFS='|'; echo "${escaped[*]}")
    denylist_pattern="(?i)\\b(?:${joined})\\b"
fi

# --- category patterns ----------------------------------------------------
# Categories that apply to both file/blob content and path/file-name strings.
declare -A CAT_PATTERN=(
    [private-ipv4]='(?<![0-9.])(?:10(?:\.[0-9]{1,3}){3}|172\.(?:1[6-9]|2[0-9]|3[01])(?:\.[0-9]{1,3}){2}|192\.168(?:\.[0-9]{1,3}){2})(?![0-9.])'
    [private-ipv6]='(?i)\b(?:f[cd][0-9a-f]{2}|fe[89ab][0-9a-f]):[0-9a-f:]{2,}'
    # Six pairs with one separator, not six of a longer hyphenated run such
    # as an image's date label (2026-10-15-18-43-40-00) nor a time range
    # (10:31:02-10:31:07).
    [mac-address]='(?<![0-9A-Fa-f][:-])\b[0-9A-Fa-f]{2}([:-])[0-9A-Fa-f]{2}(?:\1[0-9A-Fa-f]{2}){4}\b(?![:-][0-9A-Fa-f])'
    # Not a systemd unit's instance (getty@tty1.service).
    [email]='\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.(?!(?:service|socket|target|mount|automount|timer|path|slice|scope|device|swap)\b)[A-Za-z]{2,}\b'
    [home-path]='/(?:home|Users)/[^/[:space:]]+/'
    [rescue-key-path]='(?:/run/\.?rescue-key|/root/\.config/rescue)\b'
    [fs-uuid]='(?i)(?=.*uuid).*(?:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|\b[0-9a-f]{4}-[0-9a-f]{4}\b)'
    [agent-session]='(?i)(?:claude[.]ai/code/session_|^[[:space:]]*claude-session[[:space:]]*:|^[[:space:]]*co-authored-by[[:space:]]*:.*\bclaude\b)'
)
# Identity surface: same as CAT_PATTERN but a noreply GitHub address is not
# an "email" finding there, per the spec's identity exception; the denylist
# still always applies (copied in below, unchanged).
declare -A CAT_PATTERN_IDENTITY=()
for k in "${!CAT_PATTERN[@]}"; do
    CAT_PATTERN_IDENTITY[$k]=${CAT_PATTERN[$k]}
done
CAT_PATTERN_IDENTITY[email]='\b[A-Za-z0-9._%+-]+@(?!users\.noreply\.github\.com\b)[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b'

# The private categories (the patterns file) join the generic ones.
for k in "${!private_pattern[@]}"; do
    CAT_PATTERN[$k]=${private_pattern[$k]}
    CAT_PATTERN_IDENTITY[$k]=${private_pattern[$k]}
done

if (( private_only )); then
    for k in "${!CAT_PATTERN[@]}"; do
        [[ $k == agent-session ]] && continue
        [[ -n ${private_pattern[$k]:-} ]] && continue
        unset "CAT_PATTERN[$k]" "CAT_PATTERN_IDENTITY[$k]"
    done
fi

if (( dev_process )); then
    CAT_PATTERN[planning-id]='\bPhase\s+[0-9]+[A-Za-z]?\b|\bF-[0-9]{3}\b|\bB-[0-9]{3}\b|\bR-[0-9]{3}\b|\bADR-[0-9]{4}\b|docs/decisions/[0-9]{4}-'
    CAT_PATTERN[planning-todo]='TODO\(Phase'
    for k in planning-id planning-todo; do
        CAT_PATTERN_IDENTITY[$k]=${CAT_PATTERN[$k]}
    done
fi
if [[ -n $denylist_pattern ]]; then
    CAT_PATTERN[denylist]=$denylist_pattern
    CAT_PATTERN_IDENTITY[denylist]=$denylist_pattern
fi

skip_binary_total=0

# --- scanning primitives ----------------------------------------------------

# The public identity is parsed, not sourced, because the checker scans
# untrusted snapshot trees. A missing or malformed layout grants no exemption.
public_repo_owner=
public_author=
load_public_identity() {
    local layout=$1 line repo=
    [[ -r $layout ]] || return 0
    while IFS= read -r line || [[ -n $line ]]; do
        case $line in
            public_repo=*) repo=${line#public_repo=} ;;
            public_author=*) public_author=${line#public_author=} ;;
        esac
    done < "$layout"
    if [[ $public_author == \'*\' ]]; then
        public_author=${public_author#\'}
        public_author=${public_author%\'}
    fi
    [[ -n $repo && $repo == */* && ${repo%%/*} != "$repo" && -n $public_author ]] || return 0
    public_repo_owner=${repo%%/*}
}

# An eligible assignment line may omit only the public owner word. Testing the
# remainder keeps a finding for every other denylisted word on that line.
denylist_line_has_finding() {
    local path=$1 content=$2 reduced
    [[ -n $denylist_pattern ]] || return 1
    if [[ -n $public_repo_owner && $path == lib/release-layout.sh \
        && ( $content == public_repo=* || $content == public_author=* ) ]]; then
        reduced=$(OWNER_WORD=$public_repo_owner perl -CS -pe 's/\b\Q$ENV{OWNER_WORD}\E\b//ig' <<< "$content")
        grep -Pqi -- "$denylist_pattern" <<< "$reduced"
        return
    fi
    grep -Pqi -- "$denylist_pattern" <<< "$content"
}

identity_has_finding() {
    local content=$1
    [[ -n $denylist_pattern ]] || return 1
    [[ -n $public_author && $content == "$public_author" ]] && return 1
    grep -Pqi -- "$denylist_pattern" <<< "$content"
}

is_public_author_assignment() {
    local path=$1 content=$2
    [[ -n $public_author && $path == lib/release-layout.sh \
        && ( $content == "public_author=$public_author" || $content == "public_author='$public_author'" ) ]]
}

# count_skipped_binaries <dir>: tallies regular files under <dir> (excluding
# .git) that grep -I treats as binary, into skip_binary_total.
count_skipped_binaries() {
    local dir=${1%/} total text skipped
    total=$(find "$dir" -mindepth 1 -type f -not -path '*/.git/*' 2>/dev/null | wc -l)
    text=$(grep -rlI '' --exclude-dir=.git -- "$dir" 2>/dev/null | wc -l) || true
    skipped=$(( total - text ))
    if (( skipped > 0 )); then
        skip_binary_total=$(( skip_binary_total + skipped ))
    fi
}

# record <category> <location> [path]
# Appends one finding; [path] (used only for the fs-uuid allow-list) is the
# real file path the finding is about, when the location embeds more than
# just that path (a commit sha12 prefix, a trailing line number).
record() {
    printf '%s\t%s\t%s\n' "$1" "$2" "${3:-}" >> "$results"
}

# scan_content_dir <dir> <table-name>
# For every category in <table-name>, greps every regular text file under
# <dir> (binary files are skipped by -I and tallied separately) and records
# "<category>\t<relpath>:<line>", never retaining or printing matched text.
scan_content_dir() {
    local dir=${1%/} table=$2 cat pattern raw full line content rel
    local -n _table="$table"
    count_skipped_binaries "$dir"
    for cat in "${!_table[@]}"; do
        [[ $cat == planning-file ]] && continue
        pattern=${_table[$cat]}
        raw=$(grep -rnIP --exclude-dir=.git -- "$pattern" "$dir" 2>/dev/null) || true
        [[ -z $raw ]] && continue
        while IFS=: read -r full line content; do
            rel=${full#"$dir"/}
            if [[ $cat == email ]] && is_public_author_assignment "$rel" "$content"; then
                continue
            fi
            if [[ $cat == denylist ]] && ! denylist_line_has_finding "$rel" "$content"; then
                continue
            fi
            record "$cat" "$rel:$line" "$rel"
        done <<< "$raw"
    done
}

# scan_path_list <pathlist-file> <table-name> <include-planning-file:0|1>
# Emits matching 1-based line numbers (indices into <pathlist-file>) per
# category as "<category>\t<line-number>"; the caller maps the index back to
# a real location, since formatting differs between tree and history mode.
scan_path_list() {
    local listfile=$1 table=$2 include_pf=$3 cat pattern
    local -n _table="$table"
    for cat in "${!_table[@]}"; do
        pattern=${_table[$cat]}
        grep -noP -- "$pattern" "$listfile" 2>/dev/null | cut -d: -f1 | while IFS= read -r n; do
            printf '%s\t%s\n' "$cat" "$n"
        done || true
    done
    if (( include_pf )) && [[ -n $planning_file_pattern ]]; then
        grep -noP -- "$planning_file_pattern" "$listfile" 2>/dev/null | cut -d: -f1 | while IFS= read -r n; do
            printf 'planning-file\t%s\n' "$n"
        done || true
    fi
}

# --- allow-list ---------------------------------------------------------------

declare -A allowable_category=(
    [private-ipv4]=1 [private-ipv6]=1 [mac-address]=1 [email]=1
    [home-path]=1 [rescue-key-path]=1 [fs-uuid]=1
)
declare -a allow_cats=() allow_globs=()
if [[ -r $allow_file ]]; then
    allow_line=0
    while IFS= read -r line || [[ -n $line ]]; do
        allow_line=$(( allow_line + 1 ))
        [[ -z ${line//[[:space:]]/} || $line == \#* ]] && continue
        if [[ $line == *$'\t'* ]]; then
            entry_cat=${line%%$'\t'*}
            entry_glob=${line#*$'\t'}
        else
            entry_cat=fs-uuid
            entry_glob=$line
        fi
        # The category is not echoed: it could be a denylisted word.
        if [[ -z ${allowable_category[$entry_cat]:-} || -z $entry_glob ]]; then
            echo "leak-check: $allow_file line $allow_line is not an allow-list entry (a generic category and a path glob)" >&2
            exit 2
        fi
        allow_cats+=("$entry_cat")
        allow_globs+=("$entry_glob")
    done < "$allow_file"
fi

# is_allowed <category> <path>: true when an entry names the category and a
# glob matching the finding's path. A finding with no path (a commit message
# or an author line) cannot be allowed.
is_allowed() {
    local cat=$1 path=$2 i
    [[ -n $path ]] || return 1
    for i in "${!allow_globs[@]}"; do
        [[ ${allow_cats[i]} == "$cat" ]] || continue
        # shellcheck disable=SC2053
        [[ $path == ${allow_globs[i]} ]] && return 0
    done
    return 1
}

# --- tree mode ---------------------------------------------------------

if [[ -n $tree_dir ]]; then
    tree_abs=$(cd -- "$tree_dir" && pwd)
    load_public_identity "$tree_abs/lib/release-layout.sh"
    if [[ -n $paths_file ]]; then
        # Scan a copy holding only the listed paths, at their relative names.
        mkdir "$work/public"
        while IFS= read -r rel || [[ -n $rel ]]; do
            [[ -z ${rel//[[:space:]]/} || $rel == \#* ]] && continue
            [[ -e $tree_abs/$rel ]] || { echo "leak-check: $rel (from --paths) is not in the tree" >&2; exit 2; }
            (cd -- "$tree_abs" && cp -a --parents -- "${rel%/}" "$work/public/")
        done < "$paths_file"
        tree_abs=$work/public
    fi
    scan_content_dir "$tree_abs" CAT_PATTERN

    find "$tree_abs" -mindepth 1 -type f -not -path '*/.git/*' -print \
        | sed "s#^$tree_abs/##" > "$work/tree-paths.lst"
    mapfile -t tree_paths < "$work/tree-paths.lst"
    while IFS=$'\t' read -r cat n; do
        [[ -z $n ]] && continue
        record "$cat" "${tree_paths[n-1]}:1" "${tree_paths[n-1]}"
    done < <(scan_path_list "$work/tree-paths.lst" CAT_PATTERN "$dev_process")
fi

# --- history mode --------------------------------------------------------

if [[ -n $history_repo ]]; then
    repo_abs=$(cd -- "$history_repo" && pwd)
    load_public_identity "$repo_abs/lib/release-layout.sh"
    git() { command git -c core.quotePath=false -C "$repo_abs" "$@"; }

    mkdir -p "$work/blobs" "$work/messages" "$work/identities"

    # Oldest commit introducing each blob and each path name.
    # -m: a blob a merge resolution introduced appears in no other diff.
    git log --all --reverse -m --no-renames --raw --no-abbrev --format='COMMIT%x09%H' \
        | awk -v blobf="$work/blob_commit.tsv" -v pathf="$work/path_commit.tsv" '
            /^COMMIT\t/ { commit = substr($0, 8); next }
            /^:/ {
                line = substr($0, 2)
                tpos = index(line, "\t")
                meta = substr(line, 1, tpos - 1)
                path = substr(line, tpos + 1)
                split(meta, m, " ")
                newsha = m[4]; status = substr(m[5], 1, 1)
                if (status == "D") next
                if (!(newsha in seen_blob)) {
                    seen_blob[newsha] = 1
                    print newsha "\t" commit "\t" path > blobf
                }
                if (!(path in seen_path)) {
                    seen_path[path] = 1
                    print path "\t" commit > pathf
                }
            }
        '
    [[ -f $work/blob_commit.tsv ]] || : > "$work/blob_commit.tsv"
    [[ -f $work/path_commit.tsv ]] || : > "$work/path_commit.tsv"

    declare -A blob_loc=() blob_path=()
    while IFS=$'\t' read -r sha commit path; do
        [[ -z $sha ]] && continue
        blob_loc[$sha]="${commit:0:12}:$path"
        blob_path[$sha]=$path
        git cat-file blob "$sha" > "$work/blobs/$sha" 2>/dev/null || true
    done < "$work/blob_commit.tsv"

    count_skipped_binaries "$work/blobs"
    for cat in "${!CAT_PATTERN[@]}"; do
        [[ $cat == planning-file ]] && continue
        pattern=${CAT_PATTERN[$cat]}
        raw=$(grep -rnIP -- "$pattern" "$work/blobs" 2>/dev/null) || true
        [[ -z $raw ]] && continue
        while IFS=: read -r full line content; do
            sha=${full#"$work/blobs"/}
            [[ -n ${blob_loc[$sha]:-} ]] || continue
            if [[ $cat == email ]] && is_public_author_assignment "${blob_path[$sha]}" "$content"; then
                continue
            fi
            if [[ $cat == denylist ]] && ! denylist_line_has_finding "${blob_path[$sha]}" "$content"; then
                continue
            fi
            record "$cat" "${blob_loc[$sha]}:$line" "${blob_path[$sha]}"
        done <<< "$raw"
    done

    cut -f1 "$work/path_commit.tsv" > "$work/hist-paths.lst"
    mapfile -t hist_paths < "$work/hist-paths.lst"
    mapfile -t hist_path_commits < <(cut -f2 "$work/path_commit.tsv")
    while IFS=$'\t' read -r cat n; do
        [[ -z $n ]] && continue
        record "$cat" "${hist_path_commits[n-1]:0:12}:${hist_paths[n-1]}" "${hist_paths[n-1]}"
    done < <(scan_path_list "$work/hist-paths.lst" CAT_PATTERN "$dev_process")

    # Commit messages, one file per commit sha.
    git log --all --reverse --format='%x01%H%x02%B%x03' \
        | awk -v dir="$work/messages" '
            BEGIN { RS = "\x03" }
            {
                rec = $0
                i = index(rec, "\x01")
                if (!i) next
                rec = substr(rec, i + 1)
                j = index(rec, "\x02")
                if (!j) next
                sha = substr(rec, 1, j - 1)
                msg = substr(rec, j + 1)
                f = dir "/" sha
                print msg > f
                close(f)
            }
        '
    for cat in "${!CAT_PATTERN[@]}"; do
        [[ $cat == planning-file ]] && continue
        pattern=${CAT_PATTERN[$cat]}
        grep -rlIP -- "$pattern" "$work/messages" 2>/dev/null | while IFS= read -r f; do
            sha=${f#"$work/messages"/}
            record "$cat" "${sha:0:12}:message" ""
        done || true
    done

    # Author/committer identities, one file per commit sha.
    git log --all --reverse --format='%x01%H%x02%an <%ae>%x03%cn <%ce>%x04' \
        | awk -v dir="$work/identities" '
            BEGIN { RS = "\x04" }
            {
                rec = $0
                i = index(rec, "\x01")
                if (!i) next
                rec = substr(rec, i + 1)
                j = index(rec, "\x02")
                if (!j) next
                sha = substr(rec, 1, j - 1)
                rest = substr(rec, j + 1)
                k = index(rest, "\x03")
                author = (k ? substr(rest, 1, k - 1) : rest)
                committer = (k ? substr(rest, k + 1) : "")
                f = dir "/" sha
                print author > f
                if (committer != "") print committer >> f
                close(f)
            }
        '
    for cat in "${!CAT_PATTERN_IDENTITY[@]}"; do
        pattern=${CAT_PATTERN_IDENTITY[$cat]}
        while IFS= read -r f; do
            sha=${f#"$work/identities"/}
            if [[ $cat == denylist ]]; then
                matched=0
                while IFS= read -r identity; do
                    if identity_has_finding "$identity"; then
                        matched=1
                        break
                    fi
                done < "$f"
                (( matched )) || continue
            fi
            record "$cat" "${sha:0:12}:author" ""
        done < <(grep -rlIP -- "$pattern" "$work/identities" 2>/dev/null || true)
    done

    unset -f git
fi

# --- allow-list filtering, output, summary ------------------------------

filtered="$work/filtered.tsv"
: > "$filtered"
while IFS=$'\t' read -r cat loc path; do
    [[ -z $cat ]] && continue
    if is_allowed "$cat" "$path"; then
        continue
    fi
    printf '%s\t%s\n' "$cat" "$loc" >> "$filtered"
done < "$results"

sort -u -o "$filtered" "$filtered"

# A location can itself name a denylisted word (a machine profile's
# directory, say): every printed location has those words masked.
if [[ -n $denylist_pattern ]]; then
    DENY_RE=$denylist_pattern perl -pe 's/$ENV{DENY_RE}/<denylisted>/g' -- "$filtered"
else
    cat -- "$filtered"
fi

if (( skip_binary_total > 0 )); then
    echo "leak-check: skipped $skip_binary_total binary file(s)" >&2
fi

all_cats=("${!CAT_PATTERN[@]}")
if (( dev_process )) && [[ -n $planning_file_pattern ]]; then
    all_cats+=(planning-file)
fi
mapfile -t all_cats < <(printf '%s\n' "${all_cats[@]}" | sort -u)
for cat in "${all_cats[@]}"; do
    n=$(cut -f1 "$filtered" | grep -c -x -- "$cat") || true
    printf '%s: %s\n' "$cat" "$n" >&2
done

total=$(wc -l < "$filtered")
if (( total > 0 )); then
    exit 1
fi
exit 0
