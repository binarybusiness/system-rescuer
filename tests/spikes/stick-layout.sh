#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# Spike: where a prebuilt-image stick keeps the owner's API key
# outside the signed image, and how the written stick is still verified
# against the image's sha256. Two layouts on a sparse 4 GiB stand-in stick:
#   A  a GPT partition RESCUE_KEY (vfat) appended after the image; the image's
#      hybrid MBR has no protective entry, so Linux ignores the GPT: A0 (GPT
#      only) is booted and recorded not to work, A adds an MBR slot too
#   B  a record at a 1 MiB-aligned offset past the image's end (magic, length, content)
# Each is written, verified, corrupted (the rule must fail), booted under OVMF
# as the bench does, and the secret read back from the booted rescue system
# with commands a systemd unit could run. Test content is random bytes, never
# a real key. Not sudo; qemu user-mode networking only.
#
#   tests/spikes/stick-layout.sh <iso>
set -euo pipefail
# Big images belong under ~/.cache, never /tmp (cleaned under memory pressure).
export TMPDIR=${HOME}/.cache/system-rescuer
mkdir -p "$TMPDIR"
# shellcheck source=tests/spikes/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

iso=${1:?usage: tests/spikes/stick-layout.sh <iso>}
[[ -r $iso ]] || fail "cannot read $iso"
port=${RESCUE_SSH_PORT:-2224}
stick_size=$((4 * 1024 ** 3))
iso_size=$(stat -c %s "$iso")
mib=$((1024 * 1024))
off=$(( (iso_size + mib - 1) / mib * mib ))   # first 1 MiB boundary past the image
(( iso_size % 512 == 0 )) || fail "ISO size is not a whole number of sectors"
work=$spike_tmp
secret=$work/secret.bin
head -c 48 /dev/urandom | base64 -w0 > "$secret"
secret_sum=$(sha256sum "$secret" | cut -d' ' -f1)
iso_sum=$(sha256sum "$iso" | cut -d' ' -f1)
declare -A changed

new_stick() { rm -f -- "$1"; truncate -s "$stick_size" "$1"; dd if="$iso" of="$1" bs=4M conv=notrunc status=none; }

# add_gpt_entry <image> <first-lba> <last-lba> <label>: add entry 4 to the
# primary GPT only (header LBA 1, entries LBA 2). sgdisk refuses the ISO's
# table (xorriso's entries overlap), and rewriting the backup in the image
# would change more of the image region for nothing: firmware and Linux use
# the primary and the backup stays as the image has it.
add_gpt_entry() {
    python3 -I - "$@" <<'PY'
import struct, sys, uuid, zlib
img, first, last, label = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
with open(img, 'r+b') as f:
    f.seek(512); h = bytearray(f.read(92))
    assert h[:8] == b'EFI PART'
    n, sz = struct.unpack_from('<II', h, 80)
    f.seek(1024); ents = bytearray(f.read(n * sz))
    slot = 3
    assert not any(ents[slot * sz:slot * sz + 16]), 'entry 4 in use'
    # Linux filesystem data
    e = uuid.UUID('0fc63daf-8483-4772-8e79-3d69d8477de4').bytes_le + uuid.uuid4().bytes_le \
        + struct.pack('<QQQ', first, last, 0) + label.encode('utf-16le').ljust(72, b'\0')
    ents[slot * sz:(slot + 1) * sz] = e
    struct.pack_into('<I', h, 88, zlib.crc32(ents) & 0xffffffff)
    struct.pack_into('<I', h, 16, 0)
    struct.pack_into('<I', h, 16, zlib.crc32(h[:struct.unpack_from('<I', h, 12)[0]]) & 0xffffffff)
    f.seek(512); f.write(h); f.seek(1024); f.write(ents)
PY
}

# add_mbr_entry <image> <first-lba> <sectors>: MBR slot 3 (bytes 478..493), type
# 0x83. The image's hybrid MBR has no 0xEE protective entry, so Linux reads the
# MBR and ignores the GPT; without this slot the partition is invisible to it.
add_mbr_entry() {
    python3 -I - "$@" <<'PY'
import struct, sys
img, first, count = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
with open(img, 'r+b') as f:
    f.seek(478); assert not any(f.read(16)), 'MBR slot 3 in use'
    f.seek(478); f.write(b'\x00\xfe\xff\xff\x83\xfe\xff\xff' + struct.pack('<II', first, count))
PY
}

# verify_rule <stick-image>: the rule for both layouts. The image region is
# the stick's first <ISO length> bytes; it must equal the ISO except the
# primary GPT (LBA 1..33), which may differ only by the one appended entry:
#   1. sector 0 (MBR; layout A: all but slot 3, bytes 478..493) and sectors 34.. up to the ISO length equal the ISO;
#   2. layout A only: the primary header equals the ISO's except the two CRCs
#      (bytes 16..19 and 88..91), entries 1..3 (LBA 2 bytes 0..383) and
#      entries 5.. (LBA 2 byte 512 on) equal the ISO's; entry 4 (LBA 2 bytes
#      384..511) is the one appended RESCUE_KEY entry and is not compared.
# Layout B changes nothing in the region, so the rule reduces to whole-region
# equality with the ISO, which write-stick.sh's read-back already does.
verify_rule() {
    local img=$1 layout=$2
    if [[ $layout == A ]]; then
        cmp -s -n 478 "$iso" "$img" && cmp -s -i 494:494 -n 18 "$iso" "$img" || return 1   # MBR but slot 3
    else
        cmp -s -n 512 "$iso" "$img" || return 1
    fi
    cmp -s -i $((34 * 512)) -n $((iso_size - 34 * 512)) "$iso" "$img" || return 1
    if [[ $layout == A ]]; then
        cmp -s -i $((512 + 8)):$((512 + 8)) -n 8 "$iso" "$img" || return 1    # revision, header size
        cmp -s -i $((512 + 24)):$((512 + 24)) -n 64 "$iso" "$img" || return 1 # LBAs, GUID, array location
        cmp -s -i 1024:1024 -n 384 "$iso" "$img" || return 1                  # entries 1..3
        cmp -s -i 1536:1536 -n $((34 * 512 - 1536)) "$iso" "$img" || return 1 # entries 5.. (LBA 2 from byte 512, LBA 3..33)
    else
        cmp -s -n "$iso_size" "$iso" "$img" || return 1
    fi
}
region_sum() { dd if="$1" bs=4M iflag=count_bytes count="$iso_size" status=none | sha256sum | cut -d' ' -f1; }

# changed_sectors <stick-image>: LBAs inside the image region that differ.
changed_sectors() {
    cmp -l -n "$iso_size" "$iso" "$1" 2>/dev/null | awk '{print int(($1 - 1) / 512)}' | sort -nu | tr '\n' ' '
}

# boot_read <stick-image> <layout>: boot under OVMF as the bench does, read the secret
# with boot-time commands over SSH, and check the agent runs.
boot_read() {
    local img=$1 layout=$2 got serial=$work/serial-$2.log
    cp "$ovmf_vars" "$work/vars-$layout.fd"
    rescue_mem=4096
    rescue_boot "$work/vars-$layout.fd" "$serial" "$img" "$port" ok || fail "[$layout] could not put the stick first in the boot order"
    wait_ssh "$port" 300 "$serial" || fail "[$layout] no SSH login (serial: $(serial_tail "$serial" 5 | tr '\n' ' '))"
    pass "[$layout] stick boots under OVMF; SSH login"
    local deadline=$((SECONDS + 240))
    until rescue_ssh "$port" 'tmux has-session -t rescue && pgrep -f "opencode --standalone" >/dev/null' 2>/dev/null; do
        (( SECONDS < deadline )) || fail "[$layout] agent not running in tmux session rescue"
        sleep 5
    done
    pass "[$layout] agent running in tmux session rescue"
    if [[ $layout == A || $layout == A0 ]]; then
        # By label, read-only: what a boot-time unit would run.
        # shellcheck disable=SC2016  # expanded on the rescue system
        got=$(rescue_ssh "$port" 'udevadm settle; d=$(blkid -L RESCUE_KEY) && mkdir -p /run/rk && mount -o ro,nodev,noexec,nosuid "$d" /run/rk && { cat /run/rk/key; umount /run/rk; }' 2>&1) \
            || { [[ $layout == A0 ]] && { echo "RECORDED: [A0] GPT-only partition is not found on the booted system: $(rescue_ssh "$port" 'lsblk -n -o NAME | tr "\n" " "')"; kill "$qemu_pid"; wait "$qemu_pid" || true; return 0; }; fail "[$layout] reading the secret failed: $got; $(rescue_ssh "$port" 'lsblk -o NAME,SIZE,LABEL,PARTLABEL; dmesg | grep -i -e gpt -e sda' 2>&1 | tr '\n' '|')"; }
    else
        # The boot device is the disk holding the ISO's label; read the record past the image's end.
        # shellcheck disable=SC2016  # expanded on the rescue system
        got=$(rescue_ssh "$port" "d=\$(lsblk -dpno PATH,TRAN | awk '\$2==\"usb\"{print \$1; exit}'); [ -n \"\$d\" ] && h=\$(dd if=\$d bs=1M skip=$((off / mib)) count=1 status=none | head -c 16 | tr -d '\\0') && [ \"\${h:0:8}\" = RSCKEY01 ] && n=\$(dd if=\$d bs=1 skip=$((off + 8)) count=8 status=none | tr -dc 0-9) && dd if=\$d bs=1 skip=$((off + 16)) count=\$((10#\$n)) status=none" 2>&1) \
            || fail "[$layout] reading the secret failed: $got"
    fi
    [[ $(printf %s "$got" | sha256sum | cut -d' ' -f1) == "$secret_sum" ]] || fail "[$layout] the secret read on the rescue system differs from the one written"
    pass "[$layout] secret read from the booted rescue system equals the one written"
    # shellcheck disable=SC2016  # expanded on the rescue system
    rescue_ssh "$port" 'lsblk -dnro NAME,RO,TYPE | awk "\$3==\"disk\" && \$1 !~ /^(zram|loop|fd)/ && \$2!=1{exit 1}"' \
        || fail "[$layout] a disk is writable at the block layer"
    pass "[$layout] every disk read-only at the block layer"
    kill "$qemu_pid" 2>/dev/null && wait "$qemu_pid" 2>/dev/null || true
}

corrupt_check() {
    local img=$1 layout=$2 pos=$((iso_size / 2)) orig
    orig=$(dd if="$img" bs=1 skip=$pos count=1 status=none | xxd -p)
    printf '\xa5' | dd of="$img" bs=1 seek=$pos conv=notrunc status=none
    if verify_rule "$img" "$layout"; then fail "[$layout] verification rule accepted a corrupted image byte"; fi
    pass "[$layout] rule fails after one corrupted byte inside the image region (offset $pos)"
    printf '%b' "\\x$orig" | dd of="$img" bs=1 seek=$pos conv=notrunc status=none
    if [[ $layout == A ]]; then
        # A byte of the image's own GPT entry 1 must fail too.
        printf '\xa5' | dd of="$img" bs=1 seek=1100 conv=notrunc status=none
        if verify_rule "$img" "$layout"; then fail "[$layout] rule accepted a corrupted GPT entry"; fi
        pass "[$layout] rule fails after one corrupted byte in GPT entry 1"
    fi
}

run_layout() {
    local layout=$1 img=$work/stick-$1.img
    new_stick "$img"
    if [[ $layout == A || $layout == A0 ]]; then
        local sectors=$((2 * mib / 512)) first=$((off / 512))
        add_gpt_entry "$img" "$first" $((first + sectors - 1)) RESCUE_KEY
        [[ $layout == A ]] && add_mbr_entry "$img" "$first" "$sectors"
        rm -f -- "$work/key.vfat"
        mkfs.vfat -n RESCUE_KEY -C "$work/key.vfat" $((sectors / 2)) > /dev/null
        mcopy -i "$work/key.vfat" "$secret" ::key
        dd if="$work/key.vfat" of="$img" bs=512 seek="$first" conv=notrunc status=none
        sgdisk -v "$img" > /dev/null 2>&1 || true
    else
        # record: "RSCKEY01" | 8 ASCII digits (length) | content
        { printf 'RSCKEY01%08d' "$(stat -c %s "$secret")"; cat "$secret"; } \
            | dd of="$img" bs=1 seek="$off" conv=notrunc status=none
    fi
    changed[$layout]=$(changed_sectors "$img")
    pass "[$layout] written; image-region sectors changed: ${changed[$layout]:-none}"
    verify_rule "$img" "${layout%0}" || fail "[$layout] verification rule rejected the fresh stick"
    pass "[$layout] verification rule passes on the fresh stick"
    [[ $(region_sum "$img") == "$iso_sum" ]] && echo "info: [$layout] the whole region sha256 equals the ISO's (write-stick.sh's rule holds unchanged)" \
        || echo "info: [$layout] the region sha256 differs from the ISO's (write-stick.sh's rule needs the replacement)"
    if [[ $layout != A0 ]]; then
        local copy=$work/c.img
        cp --sparse=always "$img" "$copy"
        corrupt_check "$copy" "$layout"
        rm -f -- "$copy"
    fi
    boot_read "$img" "$layout"
    rm -f -- "$img"
}

run_layout A0
run_layout A
run_layout B

cat <<SUM

Summary
  sectors changed in the image region (512 B LBAs, ISO is $((iso_size / 512)) sectors):
    A: ${changed[A]:-none}   (MBR slot 3, primary GPT header, first sector of its entry array)
    A0 (GPT only): ${changed[A0]:-none}; Linux ignores it (the hybrid MBR has no 0xEE entry), so no RESCUE_KEY on the booted system
    B: ${changed[B]:-none}
  verification rule:
    B: the stick's first $iso_size bytes equal the ISO (sha256), exactly as write-stick.sh does today;
       the record at $off (+$((off - iso_size)) past the end) is outside it.
    A: sector 0 equals the ISO except MBR slot 3 (bytes 478..493) and sectors 34..$((iso_size / 512 - 1)) equal the ISO;
       the primary GPT (LBA 1..33) equals the ISO's except the header's CRCs (16..19, 88..91); entries 1..3
       and 5.. are unchanged and entry 4 (RESCUE_KEY) is the only difference. A whole-image sha256 of the first $iso_size bytes no longer matches.
  recommendation: Layout B for the signed-image path.
    + B leaves the image region byte-identical: write-stick.sh's rule and any signature over the ISO
      checksum keep working, with no partial-comparison rule to get wrong.
    + No partition: Linux auto-mounters, GNOME/KDE and Windows show no extra volume to mount or to
      offer to format; the area looks like unallocated space.
    - A's partition is a vfat volume that desktops mount and Windows (which reads the hybrid MBR, where
      the partition is absent) may call unformatted space; its GPT edit also needs its own parser.
    - --wipe of B is zeroing one 1 MiB range at $off (or rewriting the record); A needs the
      GPT entry cleared and its sectors zeroed, and the region then no longer matches until restored.
    - B's cost: no file system, so the record is read with dd by the unit and written by a raw-device tool.
SUM
