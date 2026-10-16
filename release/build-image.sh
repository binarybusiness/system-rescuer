#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# Build the release assets of a tag: the key-less ISO, the offline repository
# as its own file, a .sha256 for each, and a minisign signature for each.
#
#   <secret key> | release/build-image.sh <vN.N.N> [--out <dir>]
#
# Run from a git checkout of the public tree, on the owner's Arch workstation.
# Only `git archive <tag>` is built, unpacked into a fresh directory, natively
# (`sudo ./build.sh --config <archive>/examples/config --no-key --repo-asset`,
# the only command that runs under sudo, with stdin from /dev/null), with the
# archive's examples/config as the configuration and no API key. There is no
# container build here; that stays install.sh's path for hosts that are not
# Arch. The script itself refuses to run as root.
#
# The tag gate: before the key is read and before any build, the tag must be
#   - exactly vN.N.N (a two-part vN.N tag in the repository counts as vN.N.0
#     when product tags are ordered, but is never built);
#   - the numerically greatest product tag, component by component;
#   - free of a vN.N / vN.N.N twin, which have no order;
#   - reachable from the local branch release/vN (N the tag's major).
# Annotated and lightweight tags both work. There is no preview mode: a build
# of anything else is `install.sh --build-only`, never signed with the key.
#
# The release secret key is an unencrypted minisign secret key file
# (minisign -G -W) on stdin, so no argument, environment variable or log holds
# it. It is copied into a mode-600 file in a fresh directory under /dev/shm,
# removed when the script exits however it exits, and only `minisign -S` and
# `minisign -R` (the public key) read it, with their stdin on /dev/null.
#
# Steps: refuse (root, the tag gate, a host without mkarchiso, a terminal or
# empty stdin, an existing output directory), read the key, unpack the archive, build, name the assets,
# fail on an asset past 1.9 GiB, scan the image (release/image-leak-check.sh;
# any finding fails), write the .sha256 files, sign, verify each signature,
# and write release-notes.txt. Nothing is signed before every check passes.
#
# Output (default out/release/<tag>/): system-rescuer-x86_64.iso,
# system-rescuer-x86_64-repo.img, each with <name>.sha256 and <name>.minisig
# (trusted comment "file:<name>" TAB "version:<tag>"), release-notes.txt,
# minisign.pub (the matching public key) and build-image.log. The notes name
# the tag, its full commit SHA and the release branch.
#
# Options:
#   --out <dir>        the output directory (must not exist)
#   --work <dir>       the work directory (default: under ~/.cache/system-rescuer)
#   --keep-work        keep the work directory (the unpacked tree and the build)
#   --check-gate       run the tag gate alone, then exit (0 passed, 1 refused)
#   --from <dir>       skip the build: take system-rescuer-*.iso and
#                      system-rescuer-*-repo.img from <dir> (for tests)
#   --denylist <file>, --patterns <file>, --allow <file>
#                      for the image scan; the denylist and the patterns file
#                      must exist (default ~/.config/system-rescuer/leak-denylist
#                      and leak-patterns): a release is not scanned blind
#
# Exit: 0 done, 1 a check or the build failed, 2 usage error.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd -- "$here/.." && pwd)

# 1.9 GiB; GitHub caps a release asset at 2 GiB.
size_limit=2040109465

usage() {
    echo "usage: <secret key> | release/build-image.sh <vN.N.N> [--out <dir>] [--work <dir>] [--keep-work] [--check-gate] [--from <dir>] [--denylist <f>] [--patterns <f>] [--allow <f>]" >&2
    exit 2
}
die() { printf 'build-image: %s\n' "$*" >&2; exit 1; }

tag='' out='' work_arg='' keep_work=0 gate_only=0 from='' denylist='' patterns='' allow=''
while (($#)); do
    case $1 in
        --out|--work|--from|--denylist|--patterns|--allow)
            [[ $# -ge 2 ]] || usage
            case $1 in
                --out) out=$2 ;;
                --work) work_arg=$2 ;;
                --from) from=$2 ;;
                --denylist) denylist=$2 ;;
                --patterns) patterns=$2 ;;
                --allow) allow=$2 ;;
            esac
            shift 2 ;;
        --keep-work) keep_work=1; shift ;;
        --check-gate) gate_only=1; shift ;;
        -*) usage ;;
        *) [[ -z $tag ]] || usage; tag=$1; shift ;;
    esac
done
[[ -n $tag ]] || usage

(( EUID != 0 )) || die "refusing to run as root"
[[ $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "the tag must look like v1.2.3, not '$tag'"
command -v git >/dev/null || die "git is needed"
commit=$(git -C "$repo" rev-parse --verify -q "refs/tags/$tag^{commit}") \
    || die "no tag $tag in $repo"

# --- the tag gate -----------------------------------------------------------------

major=${tag#v}
major=${major%%.*}
branch=release/v$major
# version_key <vN.N[.N]>: "N N N", the missing patch component as 0.
version_key() {
    local a b c
    IFS=. read -r a b c <<< "${1#v}"
    printf '%d %d %d' "$a" "$b" "${c:-0}"
}
release_gate() {
    local t key twin i greater
    local -a mine own
    local -A seen=()
    read -r -a mine <<< "$(version_key "$tag")"
    while IFS= read -r t; do
        [[ $t =~ ^v[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || continue
        key=$(version_key "$t")
        if [[ -n ${seen[$key]:-} ]]; then
            twin=${seen[$key]}
            die "tag gate: $twin and $t name the same version and have no order; remove one ($tag was asked for)"
        fi
        seen[$key]=$t
    done < <(git -C "$repo" for-each-ref --format='%(refname:strip=2)' refs/tags)
    for key in "${!seen[@]}"; do
        read -r -a own <<< "$key"
        greater=0
        for i in 0 1 2; do
            if (( own[i] > mine[i] )); then greater=1; break; fi
            if (( own[i] < mine[i] )); then break; fi
        done
        (( ! greater )) || die "tag gate: $tag is not the greatest product tag: ${seen[$key]} follows it"
    done
    git -C "$repo" show-ref --verify -q "refs/heads/$branch" \
        || die "tag gate: $tag needs the local branch $branch, which does not exist"
    git -C "$repo" merge-base --is-ancestor "$commit" "refs/heads/$branch" \
        || die "tag gate: $tag (commit $commit) is not reachable from $branch"
}
release_gate
# The script that signs is the tag's own copy, so an edited checkout cannot
# loosen the gate or the scan it runs.
git -C "$repo" show "$tag:release/build-image.sh" 2>/dev/null | cmp -s - "${BASH_SOURCE[0]}" \
    || die "this release/build-image.sh is not $tag's copy; run it from a checkout of $tag"
if (( gate_only )); then
    printf 'build-image: tag gate passed: %s is commit %s, on %s\n' "$tag" "$commit" "$branch"
    exit 0
fi

# --- the host ---------------------------------------------------------------------

[[ ! -t 0 ]] || die "the secret key is read from stdin, which is a terminal; pipe it in"
[[ -n $out ]] || out=$repo/out/release/$tag
out=$(realpath -m -- "$out")
[[ ! -e $out ]] || die "the output directory $out exists; remove it or choose another"
for tool in tar minisign sha256sum base64 xorriso; do
    command -v "$tool" >/dev/null || die "$tool is needed"
done
if [[ -z $from ]]; then
    for tool in mkarchiso gitleaks sudo; do
        command -v "$tool" >/dev/null || die "$tool is needed for the native build (pacman -S archiso gitleaks sudo)"
    done
fi
denylist=${denylist:-$HOME/.config/system-rescuer/leak-denylist}
patterns=${patterns:-$HOME/.config/system-rescuer/leak-patterns}
[[ -r $denylist ]] || die "no denylist at $denylist; pass --denylist"
[[ -r $patterns ]] || die "no patterns file at $patterns; pass --patterns"

# --- the key ---------------------------------------------------------------------

keydir=$(umask 077; mktemp -d /dev/shm/release-key.XXXXXX) || die "cannot make a key directory on /dev/shm"
work=''
cleanup() {
    rm -rf -- "$keydir"
    if [[ -n $work ]] && (( ! keep_work )); then rm -rf -- "$work"; fi
}
trap cleanup EXIT
key=$keydir/key
( umask 077; head -c 8192 > "$key" )
[[ -s $key ]] || die "stdin is empty: pipe the minisign secret key in"
# Shaped like an unencrypted minisign secret key: a comment line, then one
# base64 line of 158 bytes that starts with "Ed" and whose KDF algorithm
# field is zero. Every test reads the file; nothing is echoed.
[[ $(wc -l < "$key") -eq 2 ]] || die "stdin is not a minisign secret key file"
sed -n 1p "$key" | grep -q '^untrusted comment: ' || die "stdin is not a minisign secret key file"
[[ $(sed -n 2p "$key" | base64 -d 2>/dev/null | wc -c) -eq 158 ]] || die "stdin is not a minisign secret key file"
[[ $(sed -n 2p "$key" | base64 -d 2>/dev/null | head -c 2) == Ed ]] || die "stdin is not a minisign secret key file"
[[ $(sed -n 2p "$key" | base64 -d 2>/dev/null | head -c 4 | tail -c 2 | od -An -tx1 | tr -d ' \n') == 0000 ]] \
    || die "the secret key is encrypted; pass an unencrypted key (minisign -G -W)"
pub=$keydir/key.pub
minisign -R -s "$key" -p "$pub" < /dev/null > /dev/null 2>&1 || die "cannot derive the public key from the secret key"

# --- the output and the work directory --------------------------------------------

mkdir -p -- "$(dirname -- "$out")"
mkdir -- "$out"
log=$out/build-image.log
say() { printf 'build-image: %s\n' "$*" | tee -a "$log"; }
cache=${XDG_CACHE_HOME:-$HOME/.cache}/system-rescuer
if [[ -n $work_arg ]]; then
    mkdir -p -- "$work_arg"
    work=$(realpath -- "$work_arg")
else
    mkdir -p -- "$cache"
    work=$(mktemp -d "$cache/release-work.XXXXXX")
fi
[[ -z $(ls -A -- "$work") ]] || die "the work directory $work is not empty"
src=$work/src stage=$work/stage
mkdir -- "$src" "$stage"
say "$tag is commit $commit"

git -C "$repo" archive --format=tar "$tag" | tar -x -C "$src"
[[ -f $src/install.sh && -d $src/examples/config && -d $src/profile && -f $src/lib/release-layout.sh ]] \
    || die "the archive of $tag is not the public tree"
# The asset names and the key are the tagged installer's, so it verifies
# what is signed here.
# shellcheck source=lib/release-layout.sh
. "$src/lib/release-layout.sh"
[[ $(sed -n 2p "$pub") == "$release_pubkey" ]] \
    || die "the secret key is not the release key $tag's install.sh pins (lib/release-layout.sh); nothing was built"

# --- the build ---------------------------------------------------------------------

if [[ -n $from ]]; then
    say "no build: taking the images from $from"
    # shellcheck disable=SC2012
    built_iso=$(ls -- "$from"/system-rescuer-*-x86_64.iso 2>/dev/null | head -n 1 || true)
    # shellcheck disable=SC2012
    built_repo=$(ls -- "$from"/system-rescuer-*-x86_64-repo.img 2>/dev/null | head -n 1 || true)
    [[ -f $built_iso && -f $built_repo ]] || die "$from holds no image and repository asset"
    cp --sparse=always -- "$built_iso" "$stage/$release_iso"
    cp --sparse=always -- "$built_repo" "$stage/$release_repo"
else
    say "building natively under sudo; the build's log is build.log"
    mkdir -- "$work/build"
    rc=0
    # The redirects are the invoking user's on purpose: the log is not root's.
    # shellcheck disable=SC2024
    ( cd -- "$src" && sudo ./build.sh --config "$src/examples/config" --no-key --repo-asset \
        --out-dir "$work/build" < /dev/null > "$work/install.log" 2>&1 ) || rc=$?
    [[ ! -f $work/build/build.log ]] || cp -- "$work/build/build.log" "$out/build.log"
    if (( rc != 0 )); then
        tail -n 20 "$work/install.log" >&2
        die "the build failed (exit $rc); see $out/build.log"
    fi
    shopt -s nullglob
    isos=("$work"/build/system-rescuer-*-x86_64.iso)
    repos=("$work"/build/system-rescuer-*-x86_64-repo.img)
    shopt -u nullglob
    (( ${#isos[@]} == 1 && ${#repos[@]} == 1 )) || die "the build left ${#isos[@]} images and ${#repos[@]} repository assets, not one of each"
    mv -- "${isos[0]}" "$stage/$release_iso"
    mv -- "${repos[0]}" "$stage/$release_repo"
fi

# --- the size gate ----------------------------------------------------------------

for f in "$release_iso" "$release_repo"; do
    size=$(stat -c %s -- "$stage/$f")
    (( size <= size_limit )) || die "$f is $size bytes; the limit is 1.9 GiB ($size_limit)"
    say "$f: $size bytes (limit $size_limit)"
done

# --- the image scan -----------------------------------------------------------------

say "scanning the image"
scan_args=(--source "$src" --config "$src/examples/config" --denylist "$denylist" --patterns "$patterns")
[[ -z $allow ]] || scan_args+=(--allow "$allow")
rc=0
"$src/release/image-leak-check.sh" "$stage/$release_iso" "${scan_args[@]}" > "$work/scan.out" 2> "$work/scan.err" || rc=$?
cat "$work/scan.err" >> "$log"
if (( rc != 0 )); then
    cat "$work/scan.err" "$work/scan.out" >&2
    die "the image scan failed (exit $rc); nothing was signed"
fi
say "the image scan found nothing"

# --- checksums, signatures -----------------------------------------------------------

tab=$'\t'
for f in "$release_iso" "$release_repo"; do
    ( cd -- "$stage" && sha256sum -- "$f" > "$f.sha256" )
    comment="file:${f}${tab}version:${tag}"
    minisign -S -s "$key" -m "$stage/$f" -x "$stage/$f.minisig" -t "$comment" < /dev/null > /dev/null 2>&1 \
        || die "signing $f failed"
    minisign -V -p "$pub" -m "$stage/$f" -x "$stage/$f.minisig" < /dev/null > /dev/null 2>&1 \
        || die "the signature of $f does not verify"
    grep -qxF "trusted comment: $comment" "$stage/$f.minisig" || die "the trusted comment of $f is wrong"
    say "$f signed"
done

# --- the notes and the result ------------------------------------------------------------

{
    printf 'system-rescuer %s\n' "$tag"
    printf 'tag %s\n' "$tag"
    printf 'commit %s\n' "$commit"
    printf 'branch %s\n\n' "$branch"
    ( cd -- "$stage" && sha256sum -- "$release_iso" "$release_repo" )
} > "$stage/release-notes.txt"
cp -- "$pub" "$stage/minisign.pub"
for f in "$release_iso" "$release_iso.sha256" "$release_iso.minisig" "$release_repo" "$release_repo.sha256" "$release_repo.minisig" release-notes.txt minisign.pub; do
    mv -- "$stage/$f" "$out/$f"
done
say "done: $out"
