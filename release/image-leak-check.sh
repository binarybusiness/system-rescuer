#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# Scan a built image for personal data, development-process traces and
# secrets before it is signed. Reports a category and a path per finding and
# never a matched value.
#
#   release/image-leak-check.sh <iso> [--source <tree>] [--config <dir>]
#                               [--denylist <file>] [--patterns <file>]
#                               [--allow <file>] [--work <dir>]
#
# The ISO's files and its root image (airootfs.sfs) are unpacked without
# privileges into a scratch directory under ~/.cache (or --work), which is
# removed on exit. Scopes:
#   whole image  the denylist and the patterns file's categories
#                (tests/leak-check.sh --private-only), SSH public keys,
#                key-shaped tokens, and gitleaks.
#   own files    the files that came from <tree>/profile/airootfs and from the
#                configuration, found in the image under their own names: the
#                generic personal patterns and, with the development process
#                patterns, planning ids and phase TODO markers. They are
#                judged by tests/leak-check.sh and its tests/leak-check.allow,
#                at their path in the repository.
# <tree> defaults to the tree this script is in, <dir> to <tree>/examples/config.
# --denylist and --patterns are passed to tests/leak-check.sh unchanged, so its
# defaults and its refusal of a missing explicit file apply.
#
# Upstream bytes: a package file whose sha256 still matches its package's
# record (var/lib/pacman/local/<pkg>/mtree) is the package's own content, which
# no build step wrote into, so it leaves the scan before any check runs. Files
# from profile/airootfs or the configuration always stay.
#
# release/image-scan.allow lists reviewed findings in the rest:
# "<category><TAB><image path glob><TAB><reason>[<TAB><made by>]".
#   - Without <made by>, the category is ssh-public-key, key-token or
#     gitleaks:<rule>, and the path must be one a package owns (a file the
#     image changed, such as a configuration file pacman installs).
#   - With hook:<package>, the path is one no package owns that an installed
#     package's libalpm hook generates (the MIME cache, depmod's tables).
#   - With pacman-db, the path is pacman's record of an installed package.
# Only these two generated kinds may also allow a denylist finding. No entry ever covers a path from profile/airootfs or
# the configuration, and a patterns-file finding can never be allowed.
#
# stdout: one "<category>\t<path>" line per finding, path relative to the
# image's root. stderr: progress. Exit: 0 clean, 1 findings, 2 usage or error.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

die() { echo "image-leak-check: $*" >&2; exit 2; }
note() { echo "image-leak-check: $*" >&2; }
# shellcheck source=lib/rescue-image.sh
. "$here/../lib/rescue-image.sh"

iso='' source_tree=$(cd -- "$here/.." && pwd) config='' allow_file=$here/image-scan.allow work_base=''
lc_args=()
while (($#)); do
    case $1 in
        --source) [[ $# -ge 2 ]] || die "--source needs a directory"; source_tree=$2; shift 2 ;;
        --config) [[ $# -ge 2 ]] || die "--config needs a directory"; config=$2; shift 2 ;;
        --denylist|--patterns)
            [[ $# -ge 2 ]] || die "$1 needs a file"
            lc_args+=("$1" "$2"); shift 2 ;;
        --allow) [[ $# -ge 2 ]] || die "--allow needs a file"; allow_file=$2; shift 2 ;;
        --work) [[ $# -ge 2 ]] || die "--work needs a directory"; work_base=$2; shift 2 ;;
        -*) die "unknown option $1" ;;
        *) [[ -z $iso ]] || die "one ISO only"; iso=$1; shift ;;
    esac
done
[[ -n $iso ]] || die "usage: release/image-leak-check.sh <iso> [--source <tree>] [--config <dir>] [--denylist <file>] [--patterns <file>] [--allow <file>]"
[[ -f $iso ]] || die "no such ISO: $iso"
[[ -d $source_tree/profile/airootfs ]] || die "no profile/airootfs in $source_tree"
[[ -n $config ]] || config=$source_tree/examples/config
[[ -d $config ]] || die "no configuration directory $config"
[[ -r $allow_file ]] || die "cannot read the allow file $allow_file"
leak_check=$source_tree/tests/leak-check.sh
[[ -x $leak_check ]] || leak_check=$here/../tests/leak-check.sh
[[ -x $leak_check ]] || die "no tests/leak-check.sh"
for tool in xorriso unsquashfs 7z gitleaks jq; do
    command -v "$tool" >/dev/null || die "$tool is needed"
done
(( EUID != 0 )) || die "refusing to run as root"

cache=${XDG_CACHE_HOME:-$HOME/.cache}/system-rescuer
mkdir -p -- "$cache"
if [[ -n $work_base ]]; then
    mkdir -p -- "$work_base"
    work=$(mktemp -d "$work_base/scan.XXXXXX")
else
    work=$(mktemp -d "$cache/image-scan.XXXXXX")
fi
trap 'chmod -R u+rwX -- "$work" 2>/dev/null || true; rm -rf -- "$work"' EXIT

isodir=$work/iso root=$work/root efi=$work/efi own=$work/own
mkdir "$isodir" "$root" "$efi" "$own"
findings=$work/findings.tsv
: > "$findings"
add() { printf '%s\t%s\n' "$1" "$2" >> "$findings"; }

# --- unpack -----------------------------------------------------------------

note "unpacking $(basename -- "$iso")"
xorriso -osirrox on:auto_chmod_on -indev "$iso" -extract / "$isodir" >"$work/xorriso.log" 2>&1 \
    || die "xorriso could not unpack the ISO"
# The offline repository, when it is inside the image, is compressed Arch
# packages the project did not write.
rm -rf -- "$isodir/rescue-repo"
chmod -R u+rwX -- "$isodir"
sfs=$(find "$isodir" -name airootfs.sfs -print -quit)
[[ -n $sfs ]] || die "the ISO has no airootfs.sfs"
image_unsquash "$sfs" "$root/fs" "$work/unsquashfs.log" \
    || die "unsquashfs failed: $(tail -n 3 "$work/unsquashfs.log")"
rm -f -- "$sfs"
img=$root/fs
# The EFI boot image is a FAT file system inside the ISO.
while IFS= read -r f; do
    7z x -y -o"$efi/$(basename -- "$f")" -- "$f" >"$work/7z.log" 2>&1 || die "7z could not unpack $(basename -- "$f")"
done < <(find "$isodir" -iname 'efiboot.img' -o -iname 'eltorito.img')
mkdir "$work/image-all"
mv "$isodir" "$work/image-all/iso"
mv "$img" "$work/image-all/rootfs"
mv "$efi" "$work/image-all/efi"
all=$work/image-all
img=$all/rootfs

rel_of() { local p=$1; p=${p#"$all"/}; printf '%s' "$p"; }

# --- own files: the profile's airootfs and the configuration, as built --------

# Image path <TAB> repository path, for each file the build copies in.
map=$work/own.map
: > "$map"
while IFS= read -r -d '' f; do
    r=${f#"$source_tree/profile/airootfs/"}
    printf '%s\tprofile/airootfs/%s\n' "$r" "$r" >> "$map"
done < <(find "$source_tree/profile/airootfs" -type f -print0)
cfgrel=${config#"$source_tree"/}
[[ $cfgrel != "$config" ]] || cfgrel=config
if [[ -s $config/authorized_keys ]]; then
    printf 'root/.ssh/authorized_keys\t%s/authorized_keys\n' "$cfgrel" >> "$map"
fi
if [[ -d $config/machines ]]; then
    while IFS= read -r -d '' f; do
        r=${f#"$config/machines/"}
        printf 'root/rescue/machines/%s\t%s/machines/%s\n' "$r" "$cfgrel" "$r" >> "$map"
    done < <(find -L "$config/machines" -type f -print0)
fi
printf 'etc/rescue/provider.conf\t%s/rescue.conf\n' "$cfgrel" >> "$map"

own_count=0
declare -A source_owned=()
while IFS=$'\t' read -r r name; do
    source_owned[$r]=1
    [[ -f $img/$r && ! -L $img/$r ]] || continue
    mkdir -p -- "$own/$(dirname -- "$name")"
    cp -- "$img/$r" "$own/$name"
    own_count=$(( own_count + 1 ))
done < "$map"
(( own_count > 0 )) || die "no file of profile/airootfs is in the image: wrong ISO or source tree"
note "own files: $own_count"

# --- build-chroot identities -------------------------------------------------

# These package-scriptlet outputs would be shared by every copy of an image.
# They must be absent from the root image and are generated at boot instead.
for p in etc/nvme/hostnqn etc/nvme/hostid etc/iscsi/initiatorname.iscsi etc/brlapi.key; do
    [[ ! -e $img/$p && ! -L $img/$p ]] || add "build-identity" "rootfs/$p"
done

# --- the image's packages' paths -----------------------------------------------

owned=$work/pkg-owned.lst
: > "$owned"
for f in "$img"/var/lib/pacman/local/*/files; do
    [[ -f $f ]] || continue
    sed -n '/^%FILES%$/,/^$/p' "$f" | grep -v '^%FILES%$' | grep -v '^$' | grep -v '/$' >> "$owned" || true
done
sort -u -o "$owned" "$owned"
declare -A pkg_owned=()
while IFS= read -r p; do pkg_owned[$p]=1; done < "$owned"
(( ${#pkg_owned[@]} > 0 )) || note "warning: the image's package database lists no files; nothing can be allowed"

# --- upstream bytes: package files identical to their package's record ---------

sums=$work/upstream.sha256
for m in "$img"/var/lib/pacman/local/*/mtree; do
    [[ -f $m ]] || continue
    # "./<path> ... sha256digest=<hex>"; a path with mtree escapes (\NNN) is
    # left in the scan rather than parsed.
    zcat -- "$m" 2>/dev/null | awk '
        $1 ~ /^\.\// && $1 !~ /\\/ && $1 !~ /^\.\/\.(BUILDINFO|PKGINFO|INSTALL|CHANGELOG|MTREE)$/ {
            for (i = 2; i <= NF; i++) if ($i ~ /^sha256digest=/) {
                d = $i; sub(/^sha256digest=/, "", d); p = $1; sub(/^\.\//, "", p)
                print d "  " p
            }
        }'
done > "$sums"
upstream=0
if [[ -s $sums ]]; then
    while IFS= read -r p; do
        [[ -z ${source_owned[$p]:-} && -f $img/$p && ! -L $img/$p ]] || continue
        rm -f -- "$img/$p"
        upstream=$(( upstream + 1 ))
    done < <(cd -- "$img" && sha256sum -c --ignore-missing "$sums" 2>/dev/null | sed -n 's/: OK$//p')
fi
note "upstream package files left out of the scan: $upstream"

# --- scan: whole image, private patterns and the denylist ----------------------

note "whole image: denylist and private patterns"
rc=0
"$leak_check" --tree "$all" --private-only "${lc_args[@]}" > "$work/lc-all.out" 2> "$work/lc-all.err" || rc=$?
(( rc <= 1 )) || { cat "$work/lc-all.err" >&2; die "leak-check failed on the image"; }
while IFS=$'\t' read -r cat loc; do
    [[ -n $cat ]] || continue
    add "$cat" "$(rel_of "$all/${loc%:*}")"
done < "$work/lc-all.out"

# --- scan: own files, generic categories and the development process -----------

note "own files: generic and development-process patterns"
rc=0
"$leak_check" --tree "$own" --dev-process "${lc_args[@]}" > "$work/lc-own.out" 2> "$work/lc-own.err" || rc=$?
(( rc <= 1 )) || { cat "$work/lc-own.err" >&2; die "leak-check failed on the image's own files"; }
while IFS=$'\t' read -r cat loc; do
    [[ -n $cat ]] || continue
    add "own:$cat" "own/${loc%:*}"
done < "$work/lc-own.out"

# --- scan: SSH public keys and key-shaped tokens ------------------------------

note "whole image: SSH public keys and key-shaped tokens"
prefix=''
if [[ -r $img/etc/rescue/provider.conf ]]; then
    prefix=$(sed -n 's/^key_prefix=//p' "$img/etc/rescue/provider.conf" | head -n 1)
fi
ssh_re='(?<![A-Za-z0-9+/_-])(?:ssh-(?:rsa|dss|ed25519)|ecdsa-sha2-nistp(?:256|384|521)|sk-(?:ssh-ed25519|ecdsa-sha2-nistp256)@openssh\.com)\s+AAAA[0-9A-Za-z+/]{20,}'
# OpenSSH's FIDO key types (sk-ssh-ed25519@openssh.com, sk-ecdsa-sha2-...)
# share the prefix and are names, not keys.
tok_re='(?<![A-Za-z0-9_-])sk-(?!ssh-|ecdsa-)[A-Za-z0-9_-]{20,}'
if [[ -n $prefix && $prefix != sk- && $prefix =~ ^[A-Za-z0-9_.-]+$ ]]; then
    need=$(( 20 - ${#prefix} )); (( need >= 8 )) || need=8
    tok_re="$tok_re|(?<![A-Za-z0-9_-])${prefix//./\\.}[A-Za-z0-9_-]{$need,}"
fi
# -a: a key inside a binary file counts; -l: file names only, never content.
grep -rlaP --exclude-dir=.git -- "$ssh_re" "$all" 2>/dev/null | while IFS= read -r f; do
    printf 'ssh-public-key\t%s\n' "$(rel_of "$f")"
done >> "$findings" || true
grep -rlaP --exclude-dir=.git -- "$tok_re" "$all" 2>/dev/null | while IFS= read -r f; do
    printf 'key-token\t%s\n' "$(rel_of "$f")"
done >> "$findings" || true

# --- scan: gitleaks ----------------------------------------------------------------

note "whole image: gitleaks"
report=$work/gitleaks.json
rc=0
gitleaks dir "$all" --no-banner --redact --exit-code 0 --max-target-megabytes 10 \
    --report-format json --report-path "$report" >"$work/gitleaks.log" 2>&1 || rc=$?
(( rc == 0 )) || { tail -n 5 "$work/gitleaks.log" >&2; die "gitleaks failed to run"; }
if [[ -s $report ]]; then
    jq -r '.[] | [("gitleaks:" + .RuleID), .File] | @tsv' "$report" \
        | while IFS=$'\t' read -r cat f; do
            printf '%s\t%s\n' "$cat" "$(rel_of "$f")"
        done >> "$findings"
fi

# --- the allow file ------------------------------------------------------------

declare -a allow_cat=() allow_glob=() allow_hook=()
n=0
while IFS= read -r line || [[ -n $line ]]; do
    n=$(( n + 1 ))
    [[ -z ${line//[[:space:]]/} || $line == \#* ]] && continue
    IFS=$'\t' read -r c g reason hook <<< "$line"
    [[ -n $g && -n ${reason:-} ]] || die "$allow_file line $n: needs <category><TAB><glob><TAB><reason>"
    [[ -z ${hook:-} || $hook == pacman-db || $hook =~ ^hook:[a-z0-9@._+-]+$ ]] \
        || die "$allow_file line $n: the fourth field is hook:<package> or pacman-db"
    case $c in
        ssh-public-key|key-token|gitleaks:*) ;;
        denylist)
            [[ -n ${hook:-} ]] || die "$allow_file line $n: a denylist finding can be allowed only in a generated file (hook:<package> or pacman-db)" ;;
        *) die "$allow_file line $n: a category that can be allowed is ssh-public-key, key-token, gitleaks:<rule>, or denylist in a generated file" ;;
    esac
    allow_cat+=("$c")
    allow_glob+=("$g")
    allow_hook+=("${hook#hook:}")
done < "$allow_file"

hook_pkg_ok() { # hook_pkg_ok <package>: installed, and owns a libalpm hook
    local d
    for d in "$img"/var/lib/pacman/local/"$1"-*/; do
        [[ $(sed -n '/^%NAME%$/{n;p;q}' "$d/desc" 2>/dev/null) == "$1" ]] || continue
        grep -q '^usr/share/libalpm/hooks/.*\.hook$' "$d/files" && return 0
    done
    return 1
}

is_allowed() {
    local cat=$1 path=$2 i
    # Only a path inside the unpacked root image can be a package's.
    [[ $path == rootfs/* ]] || return 1
    path=${path#rootfs/}
    [[ -z ${source_owned[$path]:-} ]] || return 1
    for i in "${!allow_glob[@]}"; do
        [[ ${allow_cat[i]} == "$cat" ]] || continue
        if [[ ${allow_hook[i]} == pacman-db ]]; then
            # pacman's record of a package that is installed.
            [[ $path =~ ^var/lib/pacman/local/[^/]+/(desc|files|mtree)$ && -f $img/${path%/*}/desc ]] || continue
        elif [[ -n ${allow_hook[i]} ]]; then
            # Unowned, and the named package is installed and ships a hook.
            [[ -z ${pkg_owned[$path]:-} ]] || continue
            hook_pkg_ok "${allow_hook[i]}" || continue
        else
            [[ -n ${pkg_owned[$path]:-} ]] || continue
        fi
        # shellcheck disable=SC2053
        [[ $path == ${allow_glob[i]} ]] && return 0
    done
    return 1
}

count=0 allowed=0
sort -u "$findings" > "$work/findings.sorted"
while IFS=$'\t' read -r cat path; do
    [[ -n $cat ]] || continue
    if is_allowed "$cat" "$path"; then
        allowed=$(( allowed + 1 ))
        continue
    fi
    printf '%s\t%s\n' "$cat" "$path"
    count=$(( count + 1 ))
done < "$work/findings.sorted"
note "findings: $count (allowed by the allow file: $allowed)"
(( count == 0 )) || exit 1
exit 0
