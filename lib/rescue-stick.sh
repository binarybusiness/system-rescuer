# shellcheck shell=bash disable=SC2034  # STICK_AUTOMOUNTS is read by the sourcing script
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# The checks and the write that install.sh and write-stick.sh share. Sourced
# (it sources rescue-iso9660.sh from the profile).
#
#   stick_refusal <disk-name> <iso-bytes>   0 fine, 1 refused, 3 only desktop
#                                           auto-mounts hold it; the reason is
#                                           in STICK_REASON, the mounts in
#                                           STICK_AUTOMOUNTS
#   stick_describe <disk-name>              what a person needs to know the disk
#   stick_write_image <disk-name> <iso>     clear, write, verify (as root)
#   stick_write_record <disk-or-file> <iso> <content-file> [<magic>]
#                                           the key record past the image, read
#                                           back and compared by hash (root for
#                                           a disk)
#   stick_image_uuid <iso>                  the image's ISO 9660 volume UUID
#                                           (what archisosearchuuid= carries;
#                                           rescue_volume_uuid, below)
#   stick_repo_uuid <asset>                 the image UUID a repository asset
#                                           names (its volume set id)
#   stick_write_repo <disk-or-file> <iso> <asset>
#                                           the repository header and asset
#                                           past the key record, read back and
#                                           compared by hash (root for a disk)
#   stick_wipe <disk-name>                  zero the whole disk, confirm (root)
#
# Past the image, from K = the first 1 MiB boundary after the image file's end:
#   K            the key record: RSCKEY02, 8 ASCII digits of length, content
#   K + 1 MiB    the repository header: RSCREPO1, 8 ASCII digits of length,
#                then lines of name=value:
#                  uuid=<the image's ISO 9660 volume UUID>
#                  size=<the asset's bytes>
#                  sha256=<the asset's sha256>
#   K + 2 MiB    the repository asset: a read-only ISO 9660 file system whose
#                /rescue-repo is the offline package repository (build.sh
#                --repo-asset). Its volume set id is rescue-repo-for=<the
#                image's UUID>; the image's UUID is the modification date of
#                its own primary volume descriptor.
# usr/local/bin/rescue-key-record and rescue-repo read these at boot. The
# reads of the ISO 9660 descriptor and of the boundaries past the image are
# profile/airootfs/usr/local/lib/rescue-iso9660.sh, which the image carries too.
#
# Every refusal exists to stop a write to a disk that is not plainly a stick.

# shellcheck source=profile/airootfs/usr/local/lib/rescue-iso9660.sh
. "$(dirname "${BASH_SOURCE[0]}")/../profile/airootfs/usr/local/lib/rescue-iso9660.sh"

STICK_REASON=''
STICK_AUTOMOUNTS=()

stick_attr() { lsblk -dno "$1" "/dev/$2" 2> /dev/null | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }

# stick_names <disk-name>: the disk and everything stacked on it (partitions,
# dm, md), one name per line.
stick_names() { lsblk -rno NAME "/dev/$1" 2> /dev/null; }

stick_refusal() {
    local name=$1 iso_size=${2:-0} type tran size n rootdev anc swapdev m
    STICK_REASON='' STICK_AUTOMOUNTS=()
    case $name in
        nvme* | loop* | dm-* | md* | zram* | sr*)
            STICK_REASON="$name is not a USB stick: not a whole disk of the USB transport (NVMe, loop, md, dm, zram and optical drives are never written)"
            return 1 ;;
    esac
    type=$(stick_attr TYPE "$name")
    if [[ $type != disk ]]; then
        STICK_REASON="$name is not a whole disk (it is '${type:-unknown}'); name the disk, not a partition"
        return 1
    fi
    tran=$(stick_attr TRAN "$name")
    if [[ -z $tran ]]; then
        STICK_REASON="its transport is not reported (empty); some card readers and virtual disks report none, and it is not trusted to be a stick"
        return 1
    fi
    if [[ $tran != usb ]]; then
        STICK_REASON="its transport is '$tran', not usb"
        return 1
    fi
    if [[ $(stick_attr RM "$name") != 1 ]]; then
        STICK_REASON="it is not removable (a USB disk that reports itself fixed may be an external drive)"
        return 1
    fi
    size=$(lsblk -dbno SIZE "/dev/$name" 2> /dev/null | tr -d ' ')
    if [[ -z $size ]] || (( size < iso_size )); then
        STICK_REASON="its size (${size:-unknown} bytes) is smaller than the ISO ($iso_size bytes)"
        return 1
    fi
    # The disk behind the running system.
    for m in / /boot /boot/efi /efi; do
        rootdev=$(findmnt -no SOURCE --target "$m" 2> /dev/null | head -n 1 | sed 's/\[.*//')
        [[ -b $rootdev ]] || continue
        while read -r anc; do
            if [[ $anc == "$name" ]]; then
                STICK_REASON="it holds this system's $m ($rootdev)"
                return 1
            fi
        done < <(lsblk -rnso NAME "$rootdev" 2> /dev/null)
    done
    # Active swap on the disk or anything stacked on it.
    if [[ -r /proc/swaps ]]; then
        while read -r swapdev _; do
            [[ $swapdev == /dev/* ]] || continue
            swapdev=$(readlink -f -- "$swapdev")
            while read -r n; do
                if [[ $swapdev == "/dev/$n" ]]; then
                    STICK_REASON="swap is active on $swapdev; swapoff it first"
                    return 1
                fi
            done < <(stick_names "$name")
        done < <(tail -n +2 /proc/swaps)
    fi
    # Anything built on the disk: dm-crypt, LVM, md, dm-linear.
    local h
    for h in /sys/block/"$name"/holders/* /sys/block/"$name"/"$name"*/holders/*; do
        [[ -e $h ]] || continue
        STICK_REASON="$(basename "$h") is built on it (dm-crypt, LVM, md or a dm device); close it first"
        return 1
    done
    # Mounts: a desktop auto-mount can be offered for unmounting, nothing else.
    local mounts=() mp other=0
    while IFS= read -r mp; do
        [[ -n $mp ]] && mounts+=("$mp")
    done < <(lsblk -rno MOUNTPOINTS "/dev/$name" 2> /dev/null | sed 's/\\x20/ /g')
    if (( ${#mounts[@]} )); then
        for mp in "${mounts[@]}"; do
            case $mp in /run/media/* | /media/*) ;; *) other=1 ;; esac
        done
        if (( other )); then
            STICK_REASON="a partition is mounted at ${mounts[*]}; unmount it yourself"
            return 1
        fi
        STICK_AUTOMOUNTS=("${mounts[@]}")
        STICK_REASON="a partition is mounted at ${mounts[*]} (a desktop auto-mount)"
        return 3
    fi
    return 0
}

stick_describe() {
    local name=$1 serial
    serial=$(stick_attr SERIAL "$name")
    printf '  device      /dev/%s\n  model       %s\n  serial      %s\n  size        %s\n  transport   %s\n' \
        "$name" "$(stick_attr MODEL "$name")" "${serial:-none reported}" "$(stick_attr SIZE "$name")" "$(stick_attr TRAN "$name")"
    printf '  partitions:\n'
    lsblk -no NAME,SIZE,FSTYPE,LABEL "/dev/$name" | sed 's/^/    /'
}

# stick_old_end <disk-name>: the byte length of the image an earlier write left,
# from its ISO 9660 primary volume descriptor, or nothing.
stick_old_end() { rescue_volume_end "/dev/$1" || true; }

# stick_old_repo_header <disk-name> <volume-end>: the byte offset of a
# repository header (RSCREPO1) at one of the 8 1 MiB boundaries from the end of
# an older image's volume, or nothing.
stick_old_repo_header() {
    local found
    found=$(rescue_scan_past "/dev/$1" "$2" '^RSCREPO1') || return 0
    printf '%s' "${found%% *}"
}

# stick_zero_range <disk-name> <start> <length>: zero the bytes, by discard
# where the disk guarantees zeros after it, else by writing.
stick_zero_range() {
    local name=$1 start=$2 len=$3
    if [[ $(stick_attr DISC-ZERO "$name") == 1 ]] && blkdiscard -o "$start" -l "$len" "/dev/$name" 2> /dev/null; then
        return 0
    fi
    dd if=/dev/zero of="/dev/$name" bs=1M iflag=count_bytes oflag=direct,seek_bytes seek="$start" count="$len" conv=fsync status=none
}

# stick_write_image <disk-name> <iso>: as root. Clears what an older image
# could have left past this one, writes, reads back and compares.
stick_write_image() {
    local name=$1 iso=$2 iso_size size old_end old_raw clear_start clear_end mib=1048576 iso_sum stick_sum rc=0 hdr
    [[ $EUID -eq 0 ]] || { echo "stick: the write needs root" >&2; return 1; }
    iso_size=$(stat -c %s -- "$iso")
    stick_refusal "$name" "$iso_size" || { echo "stick: refusing /dev/$name: $STICK_REASON" >&2; return 1; }
    size=$(blockdev --getsize64 "/dev/$name")
    old_end=$(stick_old_end "$name") old_raw=$old_end
    clear_start=$(( iso_size / 512 * 512 ))
    if [[ -n $old_end ]]; then
        (( old_end > iso_size )) || old_end=$iso_size
        clear_end=$(( (old_end + mib - 1) / mib * mib + mib ))
        printf 'stick: an older image of %s bytes is on the disk; clearing %s..%s\n' "$old_end" "$clear_start" "$clear_end"
    else
        clear_start=$(( (iso_size + mib - 1) / mib * mib ))
        clear_end=$(( clear_start + mib ))
        printf 'stick: no older image; clearing %s..%s past the new one\n' "$clear_start" "$clear_end"
    fi
    # A repository header an older image left is cleared with its whole MiB.
    if [[ -n $old_raw ]]; then
        hdr=$(stick_old_repo_header "$name" "$old_raw")
        if [[ -n $hdr ]] && (( hdr + mib > clear_end )); then
            printf 'stick: an older repository header is at byte %s; clearing through its MiB\n' "$hdr"
            clear_end=$(( hdr + mib ))
        fi
    fi
    (( clear_end <= size )) || clear_end=$size
    if (( clear_end > clear_start )); then
        stick_zero_range "$name" "$clear_start" $(( clear_end - clear_start ))
    fi
    iso_sum=$(sha256sum -- "$iso" | cut -d' ' -f1)
    dd if="$iso" of="/dev/$name" bs=4M oflag=direct conv=fsync status=progress
    sync
    blockdev --flushbufs "/dev/$name"
    # Exactly the ISO's length, bypassing the page cache.
    stick_sum=$(dd if="/dev/$name" bs=4M iflag=direct,count_bytes count="$iso_size" status=none | sha256sum | cut -d' ' -f1)
    printf 'stick: iso   sha256 %s\nstick: stick sha256 %s\n' "$iso_sum" "$stick_sum"
    [[ $iso_sum == "$stick_sum" ]] || { echo "stick: read-back checksum mismatch" >&2; rc=1; }
    partprobe "/dev/$name" 2> /dev/null || true
    return "$rc"
}

# stick_record_offset <iso-bytes>: the first 1 MiB boundary past the image.
stick_record_offset() { printf '%s' $(( ($1 + 1048575) / 1048576 * 1048576 )); }

# stick_vet_target <target> <need-bytes>: for a target under /dev/, as root,
# every refusal of stick_refusal (the image just written, auto-mounted by a
# desktop, is unmounted), and room for <need-bytes>. Any other target is an
# image file and passes.
stick_vet_target() {
    local target=$1 need=$2 name rc=0 mp size
    [[ $target == /dev/* ]] || return 0
    [[ $EUID -eq 0 ]] || { echo "stick: the write needs root" >&2; return 1; }
    name=$(basename "$(readlink -f -- "$target")")
    stick_refusal "$name" "$need" || rc=$?
    if (( rc == 3 )); then
        for mp in "${STICK_AUTOMOUNTS[@]}"; do
            umount -- "$mp" || { echo "stick: could not unmount $mp" >&2; return 1; }
            echo "stick: unmounted the desktop's auto-mount $mp of the new image"
        done
        rc=0
        stick_refusal "$name" "$need" || rc=$?
    fi
    (( rc == 0 )) || { echo "stick: refusing /dev/$name: $STICK_REASON" >&2; return 1; }
    size=$(blockdev --getsize64 "$target")
    (( need <= size )) || { echo "stick: no room past the image ($need bytes needed)" >&2; return 1; }
}

# stick_put_record <target> <offset> <magic> <content-file>: zero the MiB at
# <offset>, write the record (magic, the content's length as 8 ASCII digits,
# the content) there and read it back. The content goes through pipes only.
stick_put_record() {
    local target=$1 off=$2 magic=$3 content=$4 mib=1048576
    local len total pad want got dflag=() iflag=()
    len=$(stat -c %s -- "$content") || return 1
    (( len > 0 && len <= mib - 16 )) || { echo "stick: the record content is $len bytes; a record holds 1 to $((mib - 16))" >&2; return 1; }
    total=$(( 16 + len ))
    pad=$(( (512 - total % 512) % 512 ))
    if [[ $target == /dev/* ]]; then dflag=(oflag=direct) iflag=(iflag=direct); fi
    record_stream() {
        printf '%s%08d' "$magic" "$len"
        cat -- "$content"
        head -c "$pad" /dev/zero
    }
    want=$(record_stream | sha256sum | cut -d' ' -f1)
    head -c "$mib" /dev/zero \
        | dd of="$target" bs=512 seek=$(( off / 512 )) iflag=fullblock conv=notrunc,fsync "${dflag[@]}" status=none || return 1
    record_stream \
        | dd of="$target" bs=512 seek=$(( off / 512 )) iflag=fullblock conv=notrunc,fsync "${dflag[@]}" status=none || return 1
    sync
    [[ $target != /dev/* ]] || blockdev --flushbufs "$target"
    got=$(dd if="$target" bs=512 skip=$(( off / 512 )) count=$(( (total + pad) / 512 )) "${iflag[@]}" status=none | sha256sum | cut -d' ' -f1)
    printf 'stick: record %s bytes at byte %s, sha256 %s\n' "$total" "$off" "$got"
    [[ $got == "$want" ]] || { echo "stick: the record read back differs from the one written" >&2; return 1; }
}

# stick_write_record <disk-or-file> <iso> <content-file> [<magic>]: write the
# record at the first 1 MiB boundary past the image, after zeroing that whole
# MiB, and read it back. The image region is never touched. A target under
# /dev/ is a disk and needs root and every refusal of stick_refusal; any other
# is an image file. The comparison is by sha256.
stick_write_record() {
    local target=$1 iso=$2 content=$3 magic=${4:-RSCKEY02} mib=1048576 iso_size off
    iso_size=$(stat -c %s -- "$iso") || return 1
    off=$(stick_record_offset "$iso_size")
    stick_vet_target "$target" $(( off + mib )) || return 1
    stick_put_record "$target" "$off" "$magic" "$content"
}

# stick_image_uuid <iso>: the volume UUID of the image in archisosearchuuid's
# form, from the modification date of its primary volume descriptor.
stick_image_uuid() { rescue_volume_uuid "$1"; }

# stick_repo_uuid <asset>: the image UUID a repository asset names.
stick_repo_uuid() {
    local v
    v=$(dd if="$1" bs=1 skip=$((32768 + 190)) count=128 status=none 2> /dev/null | tr -d '\000' | sed 's/[[:space:]]*$//')
    [[ $v =~ ^rescue-repo-for=([0-9]{4}(-[0-9]{2}){6})$ ]] || return 1
    printf '%s' "${BASH_REMATCH[1]}"
}

# stick_write_repo <disk-or-file> <iso> <asset>: the repository header at
# K + 1 MiB and the asset at K + 2 MiB (K as for the record), each read back
# and compared by hash. Refuses an asset that names another image.
stick_write_repo() {
    local target=$1 iso=$2 asset=$3 mib=1048576 iso_size k size sum uuid hdr got rflag dflag=()
    iso_size=$(stat -c %s -- "$iso") || return 1
    size=$(stat -c %s -- "$asset") || return 1
    (( size > 0 && size % 512 == 0 )) || { echo "stick: the repository asset's size ($size) is not a whole number of sectors" >&2; return 1; }
    uuid=$(stick_image_uuid "$iso") || { echo "stick: the image has no ISO 9660 volume UUID" >&2; return 1; }
    [[ $(stick_repo_uuid "$asset") == "$uuid" ]] || { echo "stick: the repository asset belongs to another image" >&2; return 1; }
    k=$(stick_record_offset "$iso_size")
    stick_vet_target "$target" $(( k + 2 * mib + size )) || return 1
    sum=$(sha256sum -- "$asset" | cut -d' ' -f1)
    hdr=$(mktemp "${TMPDIR:-/tmp}/rescue-repo-header.XXXXXX") || return 1
    printf 'uuid=%s\nsize=%s\nsha256=%s\n' "$uuid" "$size" "$sum" > "$hdr"
    stick_put_record "$target" $(( k + mib )) RSCREPO1 "$hdr" || { rm -f -- "$hdr"; return 1; }
    rm -f -- "$hdr"
    rflag=count_bytes
    if [[ $target == /dev/* ]]; then dflag=(oflag=direct) rflag=direct,count_bytes; fi
    dd if="$asset" of="$target" bs=1M seek=$(( (k + 2 * mib) / mib )) conv=notrunc,fsync "${dflag[@]}" status=none || return 1
    sync
    [[ $target != /dev/* ]] || blockdev --flushbufs "$target"
    got=$(dd if="$target" bs=1M skip=$(( (k + 2 * mib) / mib )) iflag="$rflag" count="$size" status=none | sha256sum | cut -d' ' -f1)
    printf 'stick: repository asset %s bytes at byte %s, sha256 %s\n' "$size" $(( k + 2 * mib )) "$got"
    [[ $got == "$sum" ]] || { echo "stick: the repository asset read back differs from the one written" >&2; return 1; }
}

# stick_wipe <disk-name>: as root. Zero the whole disk and read it all back.
stick_wipe() {
    local name=$1 size
    [[ $EUID -eq 0 ]] || { echo "stick: the wipe needs root" >&2; return 1; }
    stick_refusal "$name" 0 || { echo "stick: refusing /dev/$name: $STICK_REASON" >&2; return 1; }
    size=$(blockdev --getsize64 "/dev/$name")
    if ! blkdiscard --zeroout "/dev/$name" 2> /dev/null; then
        dd if=/dev/zero of="/dev/$name" bs=4M oflag=direct conv=fsync status=progress 2> /dev/null || true
    fi
    sync
    blockdev --flushbufs "/dev/$name"
    if cmp -s -n "$size" "/dev/$name" /dev/zero; then
        printf 'stick: /dev/%s is zero in all %s bytes\n' "$name" "$size"
    else
        echo "stick: /dev/$name still has non-zero bytes after the wipe" >&2
        return 1
    fi
}
