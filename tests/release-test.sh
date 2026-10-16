#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# Tests for release/build-image.sh and release/image-leak-check.sh.
#
#   tests/release-test.sh --fast    no Docker: refusals, the size gate, the
#                                   image scan on a small ISO, signatures
#   tests/release-test.sh --full    a full native build (sudo ./build.sh runs
#                                   inside release/build-image.sh, so run this
#                                   as yourself, on an Arch host with archiso)
#                                   of a scratch tag of the public tree with a
#                                   scratch key, then a second build to
#                                   compare against
#
# Everything lives under ~/.cache/system-rescuer/p32b/ (RELEASE_TEST_DIR), and
# the scratch keys on /dev/shm. Only keys generated here are used, and the
# leak scan gets a scratch denylist and patterns file. Planted values are
# assembled at run time so this file holds none.
set -uo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
base=${RELEASE_TEST_DIR:-$HOME/.cache/system-rescuer/p32b}
mode=''
case ${1:-} in
    --fast) mode=fast ;;
    --full) mode=full ;;
    *) echo "usage: tests/release-test.sh --fast | --full" >&2; exit 2 ;;
esac
(( EUID != 0 )) || { echo "release-test: refusing to run as root" >&2; exit 2; }

failed=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; failed=1; }
check() { # check <label> <command...>
    local label=$1; shift
    if "$@" >/dev/null 2>&1; then pass "$label"; else fail "$label"; fi
}
check_not() {
    local label=$1; shift
    if "$@" >/dev/null 2>&1; then fail "$label"; else pass "$label"; fi
}
has() { grep -q -- "$2" "$1"; }

limit=2040109465
at="@"
# shellcheck source=lib/release-layout.sh
. "$here/lib/release-layout.sh"
# shellcheck source=lib/rescue-image.sh
. "$here/lib/rescue-image.sh"
iso_name=$release_iso repo_name=$release_repo
tab=$'\t'

mkdir -p -- "$base"
t=$base/$mode
rm -rf -- "$t"
mkdir -p -- "$t"
shm=$(umask 077; mktemp -d /dev/shm/release-test.XXXXXX)
trap 'rm -rf -- "$shm"' EXIT

# --- scratch inputs -------------------------------------------------------------

deny_word=PLANTEDDENYWORD
printf '# scratch denylist\n%s\n' "$deny_word" > "$t/denylist"
printf '# scratch patterns\nmarker\tPLANTED-MARK[0-9]+\ndev:planned\tPLANTED-DEV-[0-9]+\n' > "$t/patterns"
printf '# empty\n' > "$t/allow-empty"
scan_flags=(--denylist "$t/denylist" --patterns "$t/patterns")

gen_key() { # gen_key <name>: a scratch unencrypted key on /dev/shm
    minisign -G -W -f -p "$shm/$1.pub" -s "$shm/$1.key" >/dev/null 2>&1
}
gen_key main
gen_key other

# The scratch tag, made as the owner will: export, init, commit, tag.
tagrepo=$t/tagrepo
"$here/tests/public-export.sh" "$tagrepo" >"$t/export.log" 2>&1 \
    || { cat "$t/export.log"; echo "release-test: the public export failed"; exit 1; }
# The scratch tree's installer pins the scratch key, as a real tag's pins
# the release key.
sed -i "s|^release_pubkey=.*|release_pubkey=$(sed -n 2p "$shm/main.pub")|" "$tagrepo/lib/release-layout.sh"
git -C "$tagrepo" init -q -b main
git -C "$tagrepo" config user.name "Release Test"
git -C "$tagrepo" config user.email "release-test${at}example.invalid"
git -C "$tagrepo" config commit.gpgsign false
git -C "$tagrepo" add -A
git -C "$tagrepo" commit -q -m "scratch public tree"
git -C "$tagrepo" branch release/v0
git -C "$tagrepo" tag v0.0.1
commit=$(git -C "$tagrepo" rev-parse HEAD)
build_image=$tagrepo/release/build-image.sh
scan=$tagrepo/release/image-leak-check.sh

shm_keydirs() { find /dev/shm -maxdepth 1 -name 'release-key.*' | sort; }

# run_build <key-name|-> <outfile-prefix> <args...>: pipes the key in; sets rc.
run_build() {
    local key=$1 prefix=$2; shift 2
    if [[ $key == - ]]; then
        bash "$build_image" "$@" "${scan_flags[@]}" < /dev/null > "$prefix.out" 2> "$prefix.err"
    else
        bash "$build_image" "$@" "${scan_flags[@]}" < "$shm/$key.key" > "$prefix.out" 2> "$prefix.err"
    fi
    rc=$?
}

# --- a small ISO ----------------------------------------------------------------------

# make_iso <out.iso> [<hook>]: the profile's airootfs plus a package database
# in a squashfs, in an ISO 9660 image. <hook> is called with the root's path.
make_iso() {
    local out=$1 hook=${2:-} d
    d=$(mktemp -d "$t/iso.XXXXXX")
    mkdir -p "$d/root" "$d/iso/arch/x86_64" "$d/root/var/lib/pacman/local/pkg-1.0-1" "$d/root/usr/share/pkg" "$d/root/etc/rescue"
    cp -a "$tagrepo/profile/airootfs/." "$d/root/"
    printf 'key_prefix=sk-\n' > "$d/root/etc/rescue/provider.conf"
    printf '%%NAME%%\npkg\n\n%%FILES%%\nusr/share/pkg/\nusr/share/pkg/data.txt\n' > "$d/root/var/lib/pacman/local/pkg-1.0-1/files"
    printf 'plain package data\n' > "$d/root/usr/share/pkg/data.txt"
    [[ -z $hook ]] || "$hook" "$d/root"
    mksquashfs "$d/root" "$d/iso/arch/x86_64/airootfs.sfs" -quiet -no-progress -all-root -no-xattrs >/dev/null 2>&1 \
        || { echo "release-test: mksquashfs failed"; exit 1; }
    xorriso -as mkisofs -quiet -V TESTISO -o "$out" "$d/iso" >/dev/null 2>&1 \
        || { echo "release-test: xorriso failed"; exit 1; }
    chmod -R u+rwX "$d"
    rm -rf -- "$d"
}
make_repo_img() {
    local d
    d=$(mktemp -d "$t/repo.XXXXXX")
    mkdir -p "$d/rescue-repo"
    printf 'x\n' > "$d/rescue-repo/rescue.db"
    xorriso -as mkisofs -quiet -V RESCUE_REPO -o "$1" "$d" >/dev/null 2>&1
    rm -rf -- "$d"
}

# Planted values, assembled here.
ssh_key="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI$(printf 'Qk%.0s' 1 2 3 4 5 6 7 8 9 10)"
token="s""k-$(printf 'Ab9Zq%.0s' 1 2 3 4 5 6)"
aws="gh""p_$(printf "aB3dE7gH9j%.0s" 1 2 3)aB3dE7"
phase_cite="Pha""se 12"

plant_deny() { printf 'note %s here\n' "$deny_word" > "$1/usr/share/pkg/notes.txt"; }
plant_ssh() { printf '%s user@host\n' "$ssh_key" > "$1/usr/share/pkg/id.txt"; }
plant_token() { printf 'key=%s\n' "$token" > "$1/usr/share/pkg/conf.txt"; }
plant_aws() { printf 'aws=%s\n' "$aws" > "$1/usr/share/pkg/aws.txt"; }
plant_dev_own() { printf 'PLANTED-DEV-7\n' >> "$1/etc/motd"; }
plant_cite_own() { printf '%s\n' "$phase_cite" >> "$1/etc/motd"; }
plant_cite_pkg() { printf '%s\n' "$phase_cite" > "$1/usr/share/pkg/readme.txt"; }
plant_build_identity() {
    mkdir -p "$1/etc/nvme"
    printf 'fixture identity\n' > "$1/etc/nvme/hostnqn"
}
plant_ssh_pkg_owned() {
    plant_ssh "$1"
    printf 'usr/share/pkg/id.txt\n' >> "$1/var/lib/pacman/local/pkg-1.0-1/files"
}
plant_ssh_own() { printf '%s user@host\n' "$ssh_key" >> "$1/etc/motd"; }
plant_fido() { printf 'PubkeyAcceptedAlgorithms sk-ssh-ed25519-cert-v01@openssh.com,sk-ecdsa-sha2-nistp256@openssh.com\n' > "$1/usr/share/pkg/fido.txt"; }
# record_file <root> <path>: pkg owns <path>, and its mtree records the
# file's current sha256 (or <digest>, the third argument, when given).
record_file() {
    local r=$1 p=$2 d=${3:-}
    [[ -n $d ]] || d=$(sha256sum "$r/$p" | cut -d' ' -f1)
    printf '%s\n' "$p" >> "$r/var/lib/pacman/local/pkg-1.0-1/files"
    printf '#mtree\n./%s time=1.0 size=1 sha256digest=%s\n' "$p" "$d" | gzip -n > "$r/var/lib/pacman/local/pkg-1.0-1/mtree"
}
plant_deny_upstream() { plant_deny "$1"; record_file "$1" usr/share/pkg/notes.txt; }
plant_deny_changed() { plant_deny "$1"; record_file "$1" usr/share/pkg/notes.txt "$(printf '%064d' 0)"; }
plant_ssh_own_recorded() { plant_ssh_own "$1"; record_file "$1" etc/motd; }
# A hook-generated cache no package owns, and the package whose hook makes it.
plant_deny_hook() { plant_ssh_hook "$1"; rm -f "$1/usr/share/pkg/id.txt"; plant_deny "$1"; }
plant_ssh_hook() {
    plant_ssh "$1"
    mkdir -p "$1/var/lib/pacman/local/mime-1.0-1"
    printf '%%NAME%%\nmime\n' > "$1/var/lib/pacman/local/mime-1.0-1/desc"
    printf '%%FILES%%\nusr/share/libalpm/hooks/mime.hook\n\n' > "$1/var/lib/pacman/local/mime-1.0-1/files"
}

# scan_case <label> <hook|-> <expect-category|none> [<allow-file>]
scan_case() {
    local label=$1 hook=$2 want=$3 allow=${4:-$t/allow-empty} iso out err rc
    iso=$t/case.iso out=$t/case.out err=$t/case.err
    rm -f -- "$iso"
    make_iso "$iso" "$([[ $hook == - ]] || echo "$hook")"
    "$scan" "$iso" --source "$tagrepo" "${scan_flags[@]}" --allow "$allow" > "$out" 2> "$err"
    rc=$?
    if [[ $want == none ]]; then
        if (( rc == 0 )); then pass "scan: $label"; else fail "scan: $label (exit $rc)"; cat "$out" "$err" | head -n 20; fi
    else
        if (( rc == 1 )) && grep -q "^${want}${tab}" "$out"; then pass "scan: $label"; else fail "scan: $label (exit $rc, wanted $want)"; head -n 20 "$out" "$err"; fi
    fi
    # No matched value is ever printed.
    if grep -qF -e "$deny_word" -e "$ssh_key" -e "$token" -e "$aws" "$out" "$err"; then fail "scan: $label printed a planted value"; fi
}

fast_tier() {
    echo "== fast tier =="

    # --- refusals ---
    local before after
    before=$(shm_keydirs)
    run_build main "$t/r-tag" "1.0.0" --out "$t/o-a"
    if (( rc != 0 )) && has "$t/r-tag.err" 'must look like'; then pass "refuses a tag without v"; else fail "refuses a tag without v"; fi
    run_build main "$t/r-tag2" "v1.0.0-rc1" --out "$t/o-b"
    if (( rc != 0 )) && has "$t/r-tag2.err" 'must look like'; then pass "refuses a prerelease tag"; else fail "refuses a prerelease tag"; fi
    run_build main "$t/r-none" "v9.9.9" --out "$t/o-c"
    if (( rc != 0 )) && has "$t/r-none.err" 'no tag v9.9.9'; then pass "refuses a tag that does not exist"; else fail "refuses a tag that does not exist"; fi
    mkdir "$t/o-exists"
    run_build main "$t/r-exists" v0.0.1 --out "$t/o-exists"
    if (( rc != 0 )) && has "$t/r-exists.err" 'exists'; then pass "refuses an existing output directory"; else fail "refuses an existing output directory"; fi
    run_build - "$t/r-empty" v0.0.1 --out "$t/o-empty"
    if (( rc != 0 )) && has "$t/r-empty.err" 'stdin is empty'; then pass "refuses empty stdin"; else fail "refuses empty stdin"; fi
    printf 'not a key\n' > "$shm/garbage.key"
    run_build garbage "$t/r-garbage" v0.0.1 --out "$t/o-garbage"
    if (( rc != 0 )) && has "$t/r-garbage.err" 'not a minisign secret key'; then pass "refuses a malformed key"; else fail "refuses a malformed key"; fi
    if script -qefc "bash $build_image v0.0.1 --out $t/o-tty ${scan_flags[*]}" /dev/null > "$t/r-tty.out" 2>&1; then
        fail "refuses a terminal on stdin"
    elif has "$t/r-tty.out" 'is a terminal'; then pass "refuses a terminal on stdin"; else fail "refuses a terminal on stdin"; fi
    check_not "no output directory left by a refusal" test -e "$t/o-empty/$iso_name"
    after=$(shm_keydirs)
    if [[ $before == "$after" ]]; then pass "no key directory left on /dev/shm by the refusals"; else fail "no key directory left on /dev/shm by the refusals"; fi


    # --- the tag gate: each refusal comes before the key is read (stdin is
    # empty here, which would otherwise be "stdin is empty") ---
    gate_repo() { # gate_repo <name>: a real repository with one commit
        local d=$t/gate-$1
        rm -rf -- "$d"
        mkdir -p "$d"
        cp -a "$tagrepo/release" "$d/release"
        mkdir -p "$d/tests"
        cp -- "$tagrepo/tests/leak-check.sh" "$d/tests/leak-check.sh"
        git -C "$d" init -q -b main
        git -C "$d" config user.name "Release Test"
        git -C "$d" config user.email "release-test${at}example.invalid"
        git -C "$d" config commit.gpgsign false
        git -C "$d" add -A
        git -C "$d" commit -q -m c1
    }
    gate_commit() { git -C "$1" commit -q --allow-empty -m "$2"; }
    gate_tag() { git -C "$1" tag "${@:2}"; }
    gate_refuses() { # gate_refuses <label> <repo> <tag> <message-fragment>...
        local label=$1 d=$2 tg=$3 frag
        shift 3
        bash "$d/release/build-image.sh" "$tg" "${scan_flags[@]}" < /dev/null > "$t/g.out" 2> "$t/g.err"
        rc=$?
        if (( rc == 1 )) && has "$t/g.err" "$tg"; then
            for frag in "$@"; do
                has "$t/g.err" "$frag" || { fail "gate: $label (message lacks '$frag')"; cat "$t/g.err"; return; }
            done
            if has "$t/g.err" 'stdin is empty'; then fail "gate: $label (the key was read first)"; else pass "gate: $label"; fi
        else
            fail "gate: $label (exit $rc)"; cat "$t/g.err"
        fi
    }
    gate_passes() { # gate_passes <label> <repo> <tag>
        local grc=0
        bash "$2/release/build-image.sh" "$3" --check-gate < /dev/null > "$t/g.out" 2> "$t/g.err" || grc=$?
        if (( grc == 0 )) && has "$t/g.out" "tag gate passed: $3 is commit $(git -C "$2" rev-parse "$3^{commit}")"; then pass "gate: $1"; else fail "gate: $1"; cat "$t/g.err"; fi
    }

    gate_repo order
    gate_tag "$t/gate-order" v1.0.0
    gate_commit "$t/gate-order" c2
    gate_tag "$t/gate-order" v1.1.0
    git -C "$t/gate-order" branch release/v1
    gate_refuses "a tag that is not the greatest is refused" "$t/gate-order" v1.0.0 'not the greatest' 'v1.1.0'
    gate_passes "the greatest tag passes (lightweight)" "$t/gate-order" v1.1.0

    gate_repo agent-session
    session_url_prefix="https://claude.ai/code/"
    session_url="${session_url_prefix}session_fixture"
    gate_tag "$t/gate-agent-session" -a -m "$session_url" v1.0.0
    git -C "$t/gate-agent-session" branch release/v1
    gate_refuses "an annotated tag with an agent-session URL is refused" "$t/gate-agent-session" v1.0.0 'agent-session'

    gate_repo numeric
    gate_tag "$t/gate-numeric" v1.9.0
    gate_commit "$t/gate-numeric" c2
    gate_tag "$t/gate-numeric" -a -m "v1.10.0" v1.10.0
    git -C "$t/gate-numeric" branch release/v1
    gate_refuses "v1.9.0 is refused when v1.10.0 exists" "$t/gate-numeric" v1.9.0 'not the greatest' 'v1.10.0'
    gate_passes "v1.10.0 passes against v1.9.0 (annotated)" "$t/gate-numeric" v1.10.0

    gate_repo twin
    gate_tag "$t/gate-twin" v1.2
    gate_tag "$t/gate-twin" v1.2.0
    git -C "$t/gate-twin" branch release/v1
    gate_refuses "v1.2 and v1.2.0 have no order" "$t/gate-twin" v1.2.0 'no order' 'v1.2 '

    gate_repo nobranch
    gate_tag "$t/gate-nobranch" v1.0.0
    gate_refuses "a missing release/vN is refused" "$t/gate-nobranch" v1.0.0 'release/v1' 'does not exist'

    gate_repo unreachable
    git -C "$t/gate-unreachable" branch release/v1
    gate_commit "$t/gate-unreachable" c2
    gate_tag "$t/gate-unreachable" v1.0.0
    gate_refuses "a tag not reachable from release/vN is refused" "$t/gate-unreachable" v1.0.0 'not reachable' 'release/v1'

    gate_repo twopart
    gate_tag "$t/gate-twopart" v1.2
    git -C "$t/gate-twopart" branch release/v1
    gate_refuses "a two-part tag as the argument is refused" "$t/gate-twopart" v1.2 'must look like'

    # An edited checkout cannot sign: the script must be the tag's own copy.
    gate_repo edited
    gate_tag "$t/gate-edited" v1.0.0
    git -C "$t/gate-edited" branch release/v1
    printf '# edited\n' >> "$t/gate-edited/release/build-image.sh"
    gate_refuses "a script that is not the tag's copy is refused" "$t/gate-edited" v1.0.0 "not v1.0.0's copy"

    # --- the image scan ---
    scan_case "a clean image" - none
    scan_case "denylist word in a package file" plant_deny denylist
    scan_case "SSH public key" plant_ssh ssh-public-key
    scan_case "sk- token" plant_token key-token
    scan_case "gitleaks rule" plant_aws 'gitleaks:github-pat'
    scan_case "development-process pattern in an own file" plant_dev_own own:planned
    scan_case "planning id in an own file" plant_cite_own own:planning-id
    scan_case "planning id in a package file is not an own-file finding" plant_cite_pkg none
    scan_case "a build-chroot identity" plant_build_identity build-identity
    printf 'ssh-public-key\tusr/share/pkg/id.txt\ta package fixture key\n' > "$t/allow-pkg"
    scan_case "allow entry covers a package-owned file" plant_ssh_pkg_owned none "$t/allow-pkg"
    scan_case "allow entry does not cover a file no package owns" plant_ssh ssh-public-key "$t/allow-pkg"
    scan_case "OpenSSH's FIDO key type names are not key tokens" plant_fido none
    printf 'ssh-public-key\tusr/share/pkg/id.txt\ta hook-made fixture\thook:mime\n' > "$t/allow-hook"
    scan_case "a hook: entry covers an unowned file of an installed hook package" plant_ssh_hook none "$t/allow-hook"
    scan_case "a hook: entry needs that package installed" plant_ssh ssh-public-key "$t/allow-hook"
    scan_case "a hook: entry does not cover a package-owned file" plant_ssh_pkg_owned ssh-public-key "$t/allow-hook"
    # Upstream bytes: a package file still matching its package's record.
    scan_case "a package file identical to its record leaves the scan" plant_deny_upstream none
    scan_case "a package file changed from its record is scanned" plant_deny_changed denylist
    scan_case "a profile file is scanned even when a record matches it" plant_ssh_own_recorded ssh-public-key
    printf 'denylist\tusr/share/pkg/notes.txt\ta generated fixture\thook:mime\n' > "$t/allow-deny-hook"
    scan_case "a denylist finding in a hook-generated file can be allowed" plant_deny_hook none "$t/allow-deny-hook"
    printf 'denylist\tusr/share/pkg/notes.txt\ta package file\n' > "$t/allow-deny-pkg"
    make_iso "$t/case.iso" plant_deny
    rc=0; "$scan" "$t/case.iso" --source "$tagrepo" "${scan_flags[@]}" --allow "$t/allow-deny-pkg" > "$t/case.out" 2> "$t/case.err" || rc=$?
    if (( rc == 2 )) && has "$t/case.err" 'only in a generated file'; then
        pass "scan: a denylist entry outside a generated file is refused"
    else
        fail "scan: a denylist entry outside a generated file is refused (exit $rc)"
    fi
    printf 'ssh-public-key\tetc/motd\tnot allowed\n' > "$t/allow-own"
    scan_case "allow entry never covers a profile file" plant_ssh_own ssh-public-key "$t/allow-own"
    printf 'denylist\tusr/share/pkg/notes.txt\tno\n' > "$t/allow-deny"
    local err rc
    make_iso "$t/case.iso" plant_deny
    "$scan" "$t/case.iso" --source "$tagrepo" "${scan_flags[@]}" --allow "$t/allow-deny" > "$t/case.out" 2> "$t/case.err"; rc=$?
    if (( rc == 2 )); then pass "scan: a denylist finding cannot be allowed"; else fail "scan: a denylist finding cannot be allowed (exit $rc)"; fi

    # --- the build's finishing steps on small images ---
    make_iso "$t/system-rescuer-20261015-x86_64.iso"
    make_repo_img "$t/system-rescuer-20261015-x86_64-repo.img"
    local out=$t/out-small
    before=$(shm_keydirs)
    run_build main "$t/r-ok" v0.0.1 --out "$out" --from "$t" --work "$t/work-ok" --keep-work
    if (( rc == 0 )); then pass "finishing steps on small images"; else fail "finishing steps on small images"; cat "$t/r-ok.err"; fi
    for f in "$iso_name" "$repo_name"; do
        check "$f has a .sha256 of one line, hash and name" bash -c "[[ \$(wc -l < '$out/$f.sha256') == 1 ]] && (cd '$out' && sha256sum -c '$f.sha256')"
        check "$f.minisig verifies with the public key" minisign -V -p "$shm/main.pub" -m "$out/$f" -x "$out/$f.minisig"
        want="trusted comment: file:${f}${tab}version:v0.0.1"
        if [[ $(sed -n 3p "$out/$f.minisig") == "$want" ]]; then pass "$f trusted comment is exact"; else fail "$f trusted comment is exact"; fi
        check "$f signature fails on a different file" bash -c "! minisign -V -p '$shm/main.pub' -m '$out/$([[ $f == "$iso_name" ]] && echo "$repo_name" || echo "$iso_name")' -x '$out/$f.minisig'"
    done
    if has "$out/release-notes.txt" "^commit $commit\$"; then pass "release-notes.txt names the commit"; else fail "release-notes.txt names the commit"; fi
    if has "$out/release-notes.txt" '^tag v0.0.1$' && has "$out/release-notes.txt" '^branch release/v0$'; then pass "release-notes.txt names the tag and the branch"; else fail "release-notes.txt names the tag and the branch"; fi
    for f in "$iso_name" "$repo_name"; do
        if has "$out/release-notes.txt" "$(cut -d' ' -f1 "$out/$f.sha256")  $f"; then pass "release-notes.txt holds $f's sha256"; else fail "release-notes.txt holds $f's sha256"; fi
    done
    check_not "the key is in no output file" grep -rqaF -f <(sed -n 2p "$shm/main.key") -- "$out" "$t/work-ok"
    run_build other "$t/r-other" v0.0.1 --out "$t/out-other" --from "$t" --work "$t/work-other"
    if (( rc != 0 )) && has "$t/r-other.err" 'pins'; then pass "refuses a key the tag's install.sh does not pin"; else fail "refuses a key the tag's install.sh does not pin"; fi
    check_not "nothing is signed with that key" bash -c "ls '$t/out-other'/*.minisig"
    # The documents print the key the installer pins.
    for f in README.md docs/quickstart.md; do
        mapfile -t keys < <(grep -oE '\bRW[A-Za-z0-9+/]{54}\b' "$here/$f" | sort -u)
        if [[ ${#keys[@]} -ge 1 && ${keys[*]} == "$release_pubkey" ]]; then pass "$f prints the pinned release key"; else fail "$f prints the pinned release key"; fi
    done
    after=$(shm_keydirs)
    if [[ $before == "$after" ]]; then pass "the key directory is gone after success"; else fail "the key directory is gone after success"; fi

    # --- the size gate ---
    mkdir "$t/big"
    cp --sparse=always "$t/system-rescuer-20261015-x86_64.iso" "$t/big/system-rescuer-20261015-x86_64.iso"
    cp "$t/system-rescuer-20261015-x86_64-repo.img" "$t/big/"
    truncate -s $(( limit + 1 )) "$t/big/system-rescuer-20261015-x86_64.iso"
    run_build main "$t/r-big" v0.0.1 --out "$t/out-big" --from "$t/big" --work "$t/work-big"
    if (( rc != 0 )) && has "$t/r-big.err" '1.9 GiB'; then pass "an asset one byte past 1.9 GiB fails"; else fail "an asset one byte past 1.9 GiB fails"; fi
    check_not "nothing is signed past the gate" test -e "$t/out-big/$iso_name.minisig"
    truncate -s "$limit" "$t/big/system-rescuer-20261015-x86_64.iso"
    run_build main "$t/r-lim" v0.0.1 --out "$t/out-lim" --from "$t/big" --work "$t/work-lim"
    if (( rc == 0 )); then pass "an asset of exactly 1.9 GiB passes"; else fail "an asset of exactly 1.9 GiB passes"; cat "$t/r-lim.err"; fi
    check "the asset at the limit is signed" minisign -V -p "$shm/main.pub" -m "$t/out-lim/$iso_name" -x "$t/out-lim/$iso_name.minisig"
    rm -rf -- "$t/big" "$t/out-lim"

    # --- a scan finding stops the build before signing ---
    mkdir -p "$t/dirty"
    make_iso "$t/dirty/system-rescuer-20261015-x86_64.iso" plant_deny
    cp "$t/system-rescuer-20261015-x86_64-repo.img" "$t/dirty/"
    before=$(shm_keydirs)
    run_build main "$t/r-dirty" v0.0.1 --out "$t/out-dirty" --from "$t/dirty" --work "$t/work-dirty"
    if (( rc != 0 )) && has "$t/r-dirty.err" 'nothing was signed'; then pass "a scan finding fails the build"; else fail "a scan finding fails the build"; fi
    check_not "a failed scan leaves no signature" bash -c "ls '$t/out-dirty'/*.minisig"
    after=$(shm_keydirs)
    if [[ $before == "$after" ]]; then pass "the key directory is gone after a failure"; else fail "the key directory is gone after a failure"; fi
}

# --- the full tier ---------------------------------------------------------------------

unpack_image() { # unpack_image <iso> <dir>
    local sfs=$2.sfs
    xorriso -osirrox on -indev "$1" -extract /arch/x86_64/airootfs.sfs "$sfs" >/dev/null 2>&1 || return 1
    image_unsquash "$sfs" "$2" "$2.log" || return 1
    rm -f -- "$sfs"
}

full_tier() {
    echo "== full tier =="
    # The build runs `sudo ./build.sh` inside the script, as the invoking user.
    local tool
    for tool in mkarchiso gitleaks sudo; do
        command -v "$tool" >/dev/null || { fail "$tool is installed"; return; }
    done
    local out=$base/release-out/v0.0.1 work=$t/work1 trace=$t/trace1 before after
    rm -rf -- "$base/release-out"
    mkdir -p "$base/release-out"
    before=$(shm_keydirs)
    ( bash -x "$build_image" v0.0.1 --out "$out" --work "$work" --keep-work "${scan_flags[@]}" \
        < "$shm/main.key" > "$t/full1.out" 2> "$trace" ); rc=$?
    if (( rc == 0 )); then pass "the clean build succeeds"; else fail "the clean build succeeds (exit $rc)"; tail -n 30 "$t/full1.out" "$trace"; return; fi
    for f in "$iso_name" "$repo_name"; do
        check "$f, its .sha256 and .minisig exist" bash -c "[[ -s '$out/$f' && -s '$out/$f.sha256' && -s '$out/$f.minisig' ]]"
        check "$f.sha256 agrees" bash -c "cd '$out' && sha256sum -c '$f.sha256'"
        check "$f verifies" minisign -V -p "$shm/main.pub" -m "$out/$f" -x "$out/$f.minisig"
        if [[ $(sed -n 3p "$out/$f.minisig") == "trusted comment: file:${f}${tab}version:v0.0.1" ]]; then pass "$f trusted comment"; else fail "$f trusted comment"; fi
        size=$(stat -c %s "$out/$f")
        if (( size <= limit )); then pass "$f is $size bytes, at most 1.9 GiB"; else fail "$f is $size bytes"; fi
    done
    check "the scan of the clean build finds nothing (re-run)" "$scan" "$out/$iso_name" --source "$tagrepo" "${scan_flags[@]}"

    # The key's base64 line and the key file's hash are in nothing the run left.
    sed -n 2p "$shm/main.key" > "$shm/needle"
    sha256sum < "$shm/main.key" | cut -d' ' -f1 >> "$shm/needle"
    check_not "the key's line and hash are in no output, work-tree or trace file" \
        grep -rqaF -f "$shm/needle" -- "$out" "$work" "$trace" "$t/full1.out"
    # The source tree names the directory (this script and build-image.sh do);
    # the build, its log and the release output must not.
    check_not "no /dev/shm key path reaches the build or its output" \
        grep -rqaF -- /dev/shm/release-key "$work/build" "$work/install.log" "$out"
    after=$(shm_keydirs)
    if [[ $before == "$after" ]]; then pass "the key directory is gone after the build"; else fail "the key directory is gone after the build"; fi

    # A build made to fail, in a scratch tag whose install.sh fails.
    local bad=$t/badrepo
    git clone -q "$tagrepo" "$bad"
    git -C "$bad" config user.name "Release Test"
    git -C "$bad" config user.email "release-test${at}example.invalid"
    printf '#!/usr/bin/env bash\nexit 1\n' > "$bad/build.sh"
    git -C "$bad" commit -q -a -m "failing build"
    git -C "$bad" tag v0.0.2
    git -C "$bad" branch release/v0
    before=$(shm_keydirs)
    bash "$bad/release/build-image.sh" v0.0.2 --out "$t/out-bad" --work "$t/work-bad" "${scan_flags[@]}" \
        < "$shm/main.key" > "$t/bad.out" 2> "$t/bad.err"; rc=$?
    if (( rc != 0 )); then pass "a failing build fails the script"; else fail "a failing build fails the script"; fi
    after=$(shm_keydirs)
    if [[ $before == "$after" ]]; then pass "the key directory is gone after a failed build"; else fail "the key directory is gone after a failed build"; fi
    rm -rf -- "$bad"

    # The rebuild.
    local out2=$t/out2 work2=$t/work2
    ( bash "$build_image" v0.0.1 --out "$out2" --work "$work2" --keep-work "${scan_flags[@]}" \
        < "$shm/main.key" > "$t/full2.out" 2> "$t/full2.err" ); rc=$?
    if (( rc == 0 )); then pass "the rebuild succeeds"; else fail "the rebuild succeeds (exit $rc)"; tail -n 30 "$t/full2.err"; return; fi
    if ! unpack_image "$out/$iso_name" "$t/img1" || ! unpack_image "$out2/$iso_name" "$t/img2"; then
        fail "both images unpack"; return
    fi
    ( cd "$t/img1" && find . -type f -print0 | sort -z | xargs -0 sha256sum ) > "$t/sums1"
    ( cd "$t/img2" && find . -type f -print0 | sort -z | xargs -0 sha256sum ) > "$t/sums2"
    diff "$t/sums1" "$t/sums2" | sed -n 's/^[<>] [0-9a-f]*  //p' | sort -u > "$t/differs"
    # The files of profile/airootfs and the configuration, and what they hold.
    ( cd "$tagrepo/profile/airootfs" && find . -type f | sort ) > "$t/own-files"
    {
        printf './root/.ssh/authorized_keys\n./etc/rescue/provider.conf\n'
        ( cd "$tagrepo/examples/config/machines" 2>/dev/null && find . -type f | sed 's#^\.#./root/rescue/machines#' )
    } >> "$t/own-files"
    comm -12 <(sort -u "$t/own-files") "$t/differs" > "$t/own-differs"
    echo "files that differ between the two images: $(wc -l < "$t/differs") of $(wc -l < "$t/sums1"); of the project's own files: $(wc -l < "$t/own-differs")"
    cp -- "$t/differs" "$base/rebuild-differs.txt"
    cp -- "$t/own-differs" "$base/rebuild-own-differs.txt"
    if [[ ! -s $t/own-differs ]]; then pass "the project's own files are byte-identical in the rebuild"; else fail "own files differ"; cat "$t/own-differs"; fi
}

case $mode in
    fast) fast_tier ;;
    full) full_tier ;;
esac

if (( failed )); then
    echo "release-test: FAILED"
    exit 1
fi
echo "release-test: all assertions passed ($mode)"
