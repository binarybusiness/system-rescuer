# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# shellcheck shell=bash disable=SC2034,SC2154  # read by tests/bench/lib.sh's with_load, which sets bench_tmp
# win-standin: a stand-in Windows beside the scenario's Linux.
# Its disk holds a Microsoft reserved partition and an NTFS C: with a
# Windows install's root folders, a Windows\System32 skeleton and the owner's
# files. Its boot files are the
# UEFI shell as \EFI\Microsoft\Boot\bootmgfw.efi, which runs the startup.nsh
# beside it and prints WINDOWS-BOOT-OK on the serial console, and a BCD (a
# registry hive's signature and random bytes): on an ESP of its own on that
# disk (with_esp=own), or on the Linux disk's ESP (with_esp=shared), as on a
# machine where Windows came first and Linux was installed beside it. Its
# firmware entry, Windows Boot Manager, comes after Linux's in BootOrder. The
# interface is in tests/scenario.sh.
with_summary="stand-in Windows: MSR, NTFS C:, the UEFI shell as Windows Boot Manager"
with_marker=WINDOWS-BOOT-OK
with_path='\EFI\Microsoft\Boot\bootmgfw.efi'

# Sizes in 512-byte sectors: ESP 100 MiB (FAT32), MSR 16 MiB, C: 128 MiB.
win_esp_size=204800 win_msr_size=32768 win_c_size=262144

with_setup() {
    local disks=$1 root=$2 vars=$3 shape=$4 img=$1/win-standin.img work=$bench_tmp/win-standin
    local shell_efi=/usr/share/edk2-shell/x64/Shell.efi start=2048 table esp_image='' entry
    [[ -r $shell_efi ]] || fail "no $shell_efi (pacman -S edk2-shell)"
    mkdir -p "$work/boot" "$work/c"
    cp "$shell_efi" "$work/boot/bootmgfw.efi"
    printf 'echo %s\r\n' "$with_marker" > "$work/boot/startup.nsh"
    { printf 'regf'; head -c 28668 /dev/urandom; } > "$work/boot/BCD"

    table=$'label: gpt\n'
    if [[ $shape == own ]]; then
        table+="start=$start, size=$win_esp_size, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name=\"EFI system partition\""$'\n'
        start=$((start + win_esp_size))
    fi
    table+="start=$start, size=$win_msr_size, type=E3C9E316-0B5C-4DB8-817D-F92DF00215AE, name=\"Microsoft reserved partition\""$'\n'
    table+="start=$((start + win_msr_size)), size=$win_c_size, type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7, name=\"Basic data partition\""$'\n'
    truncate -s $(( (start + win_msr_size + win_c_size + 2048) * 512 )) "$img"
    sfdisk -q "$img" <<< "$table" || fail "win-standin: sfdisk failed"

    if [[ $shape == own ]]; then
        mkfs.fat -F 32 -n SYSTEM -C "$work/esp.img" $((win_esp_size / 2)) > /dev/null
        mmd -i "$work/esp.img" ::/EFI ::/EFI/Microsoft ::/EFI/Microsoft/Boot
        mcopy -i "$work/esp.img" "$work/boot/bootmgfw.efi" "$work/boot/startup.nsh" "$work/boot/BCD" ::/EFI/Microsoft/Boot/
        dd if="$work/esp.img" of="$img" bs=512 seek=2048 conv=notrunc status=none
        esp_image=$img
    else
        install -D -m 644 -t "$root$BASE_ESP/EFI/Microsoft/Boot" "$work/boot/bootmgfw.efi" "$work/boot/startup.nsh" "$work/boot/BCD"
        protect+=("${BASE_ESP#/}/EFI/Microsoft")
        esp_image=$BENCH_DISK
    fi

    # C:, written through ntfs-3g on the partition's own image.
    truncate -s $((win_c_size * 512)) "$work/c.img"
    mkfs.ntfs -q -F -f -L Windows "$work/c.img" > /dev/null 2>&1 || fail "win-standin: mkfs.ntfs failed"
    ntfs-3g "$work/c.img" "$work/c" || fail "win-standin: cannot mount C: with ntfs-3g"
    # The root a Windows install has, so the volume reads as one (an agent once
    # saw only Windows and Users there and judged it not real).
    mkdir -p "$work/c/Windows/System32/config" "$work/c/Windows/System32/drivers" "$work/c/Windows/Boot/EFI" \
        "$work/c/Users/owner/Documents" "$work/c/Users/Public" "$work/c/Program Files/Common Files" \
        "$work/c/Program Files (x86)" "$work/c/ProgramData/Microsoft" "$work/c/PerfLogs" \
        "$work/c/\$Recycle.Bin" "$work/c/System Volume Information" "$work/c/Recovery"
    head -c 1M /dev/urandom > "$work/c/pagefile.sys"
    head -c 256K /dev/urandom > "$work/c/swapfile.sys"
    head -c 1M /dev/urandom > "$work/c/Windows/explorer.exe"
    head -c 512K /dev/urandom > "$work/c/Windows/System32/drivers/storahci.sys"
    head -c 2M /dev/urandom > "$work/c/Windows/System32/ntoskrnl.exe"
    head -c 1M /dev/urandom > "$work/c/Windows/System32/winload.efi"
    { printf 'regf'; head -c 1M /dev/urandom; } > "$work/c/Windows/System32/config/SYSTEM"
    cp "$work/boot/bootmgfw.efi" "$work/c/Windows/Boot/EFI/"
    head -c 1M /dev/urandom > "$work/c/Users/owner/Documents/tax-return-2025.pdf"
    umount "$work/c" || fail "win-standin: cannot unmount C:"
    dd if="$work/c.img" of="$img" bs=512 seek=$((start + win_msr_size)) conv=notrunc status=none
    rm -f "$work/c.img" "$work/esp.img"
    chown "$bench_user:" "$img"

    entry=$(efi_add "$vars" "$(python3 "$efi_py" option 'Windows Boot Manager' "$esp_image" esp "$with_path")") \
        || fail "win-standin: cannot add Windows Boot Manager to the firmware's entries"
    efi_systems_first "$vars" || fail "win-standin: cannot reorder BootOrder"
    pass "win-standin: Windows on its disk, its boot files on $([[ $shape == own ]] && echo its own ESP || echo "the Linux ESP"), $entry Windows Boot Manager after Linux in BootOrder"
}
