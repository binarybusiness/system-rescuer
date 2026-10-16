#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# Build or reuse the cached real Windows for the scenario bench: the Windows 11 Enterprise evaluation (the en-US ISO from Microsoft's
# evaluation centre, in ~/.cache/system-rescuer/downloads/) installed
# unattended on the machine of tests/bench/win11.sh with no network,
# BitLocker on with the TPM and a recovery password, a startup task that
# prints WINDOWS-BOOT-OK on COM1 at every boot, booted once more to check
# that the TPM unlocks it, and powered off in full. It is kept as
# ~/.cache/system-rescuer/bases/win11-eval-<recipe>.img (a sparse raw 64 GiB
# disk, the least Windows 11 installs on), with .vars.fd (the firmware
# variables setup left, its Windows Boot Manager entry among them), .tpm/
# (the TPM's state, which BitLocker sealed its key to), .recovery (the
# recovery password, 0600, never printed) and .json (the build date, the
# xxh128 of the disk and the variables, and the recipe hash), owned by the
# invoking user. The recipe covers the install's files and the firmware,
# which BitLocker measures, so a new edk2-ovmf builds again; and the
# evaluation runs 90 days from its install, so an install older than 80 days
# is built again too. A disk whose hash no longer matches is refused.
# Scenario runs use copies (tests/with/win11-eval.sh). The stem (the path
# without .img) is the last line on stdout.
#
# --plain builds win11-plain instead: the same install with
# BitLocker off (device encryption too), so Linux can read its NTFS, as
# ~/.cache/system-rescuer/bases/win11-plain-<recipe>.* with no .recovery
# (tests/with/win11-hibernated.sh).
#
#   sudo tests/win11-image.sh [--rebuild] [--plain] [windows-iso]   # build once, then reuse
#   tests/win11-image.sh [--plain]                                  # reuse only; no root needed
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=bench/lib.sh
. "$here/bench/lib.sh"
# shellcheck source=bench/win11.sh
. "$here/bench/win11.sh"
bench_init win11-image

note() { printf 'win11-image: %s\n' "$*" >&2; }
rebuild='' iso=$bench_cache/downloads/win11-enterprise-eval.iso variant=bitlocker name=win11-eval plain_arg=''
for arg; do
    case $arg in
        --rebuild) rebuild=1 ;;
        --plain) variant=plain name=win11-plain plain_arg=' --plain' ;;
        -*) fail "usage: sudo tests/win11-image.sh [--rebuild] [--plain] [windows-iso]" ;;
        *) iso=$arg ;;
    esac
done
# The unattended install's answer file and the scripts it runs (setup once,
# spike-boot.ps1 at every boot, whose SPIKE-* lines the bench reads).
unattend=$here/bench/win11
max_days=80
export BENCH_STALL_RETRIES=0  # Windows prints nothing on COM1 for minutes; that is no firmware stall

# win11_install <image> <vars> <tpm-dir> <recovery-file>: install Windows
# unattended onto the image, as root, BitLocker on or, for the plain
# variant, off (its COM2 then has no recovery password); ends with Windows
# powered off.
win11_install() {
    local img=$1 vars=$2 tpm=$3 recovery=$4 dir=$bench_tmp/install
    mkdir -p "$dir/unattend" "$tpm"
    cp "$ovmf_vars" "$vars"
    truncate -s 64G "$img"
    cp "$unattend/autounattend.xml" "$unattend/"*.ps1 "$dir/unattend/"
    printf '%s\r\n' "$variant" > "$dir/unattend/variant.txt"
    sed 's/$/\r/' "$unattend/spike-setup.cmd" > "$dir/unattend/spike-setup.cmd"
    xorriso -as mkisofs -quiet -V UNATTEND -J -r -o "$dir/unattend.iso" "$dir/unattend" 2>/dev/null
    win11_guest "$img" "$vars" "$tpm" "$dir/install.log" "$recovery" \
        -drive if=none,id=wcd,media=cdrom,readonly=on,file="$iso" -device ide-cd,drive=wcd,bus=ide.1 \
        -drive if=none,id=ucd,media=cdrom,readonly=on,file="$dir/unattend.iso" -device ide-cd,drive=ucd,bus=ide.2
    # "Press any key to boot from CD or DVD": only in the first seconds, since
    # a later Enter lands on setup's focused Cancel.
    for _ in $(seq 24); do sleep 0.5; hmp sendkey ret; done
    wait_for "$dir/install.log" 7200 guest_off || { screen "$dir/install-stuck"; stop_qemu; fail "the install did not power off within 2 h; screen in $bases/$name-install-stuck.png"; }
    stop_qemu
    tr -d '\r' < "$dir/install.log" | grep -a '^SPIKE-' >&2 || true
    serial_matches "$dir/install.log" '^SPIKE-SETUP done' || fail "the first-logon setup did not finish"
    serial_matches "$dir/install.log" "^SPIKE-VARIANT $variant" || fail "the setup did not read its variant ($variant)"
    if [[ $variant == plain ]]; then
        serial_matches "$dir/install.log" '^SPIKE-BL status=FullyDecrypted protection=Off' || fail "C: is encrypted (device encryption?)"
    else
        serial_matches "$dir/install.log" '^SPIKE-BL status=FullyEncrypted protection=On' || fail "BitLocker is not on"
        grep -aqE '[0-9]{6}(-[0-9]{6}){7}' "$recovery" || fail "no recovery password came out on COM2"
    fi
}

# win11_check_boot <image> <vars> <tpm-dir>: boot it once more, which the TPM
# must unlock with no recovery prompt, to WINDOWS-BOOT-OK, and power it off
# in full through the startup task's control CD.
win11_check_boot() {
    local dir=$bench_tmp/check
    win11_control_cd "$dir" off || fail "cannot make the control CD"
    win11_guest "$1" "$2" "$3" "$dir/serial.log" /dev/null \
        -drive if=none,id=ctl,media=cdrom,readonly=on,file="$dir/ctl.iso" -device ide-cd,drive=ctl,bus=ide.3
    wait_serial "$dir/serial.log" '^WINDOWS-BOOT-OK' 1200 || { screen "$dir/boot"; stop_qemu; fail "no WINDOWS-BOOT-OK within 1200 s (a BitLocker recovery prompt?); screen in $bases/$name-boot.png"; }
    wait_for "$dir/serial.log" 300 guest_off || { stop_qemu; fail "Windows did not power off"; }
    stop_qemu
}

# win11_guest <image> <vars> <tpm-dir> <com1-log> <com2> [qemu args...]: the
# Windows disk on q35's own AHCI, a screen for screendumps, and no network.
win11_guest() {
    local img=$1 vars=$2 tpm=$3 log=$4 com2=$5
    shift 5
    win11_machine "$tpm" "$bench_tmp" || fail "cannot start swtpm"
    BENCH_MEM=6144 qemu_ovmf "$vars" "$log" "${win11_args[@]}" \
        -smp 4 -device VGA -nic none -serial file:"$com2" -monitor unix:"$bench_tmp/mon.sock",server=on,wait=off \
        -drive if=none,id=disk,format=raw,file="$img" -device ide-hd,drive=disk,bus=ide.0 "$@"
}
hmp() { printf '%s\n' "$*" | socat - UNIX-CONNECT:"$bench_tmp/mon.sock" > /dev/null 2>&1 || true; }
guest_off() { ! kill -0 "$qemu_pid" 2>/dev/null; }
# screen <path>: the guest's screen as <path>.png, kept beside the cache as
# <name>-<stage>.png too, since a failed build removes its temporary directory.
screen() {
    hmp screendump "$1.ppm"; sleep 2; magick "$1.ppm" "$1.png" 2>/dev/null || return 0
    cp -f -- "$1.png" "$bases/$name-${1##*/}.png" && chown "$bench_user:" "$bases/$name-${1##*/}.png"
}
xxh() { xxhsum -H2 < "$1" | cut -d' ' -f1; }

ovmf_code=$win11_code
# The recipe leaves out the files' licence lines, which change no install.
recipe=$( { echo "$variant"; declare -f win11_install win11_check_boot win11_guest win11_machine win11_control_cd; cat "$unattend/autounattend.xml" "$unattend/"*.ps1 "$unattend/spike-setup.cmd" | grep -av 'SPDX-License-Identifier:'; file_sha "$win11_code"; } \
    | sha256sum | cut -c1-12)
bases=$bench_cache/bases
stem=$bases/$name-$recipe
img=$stem.img vars=$stem.vars.fd tpm=$stem.tpm recovery=$stem.recovery meta=$stem.json
bench_user_dir "$bases"
lock=$bases/$name.lock
[[ -e $lock ]] || { : > "$lock"; chown "$bench_user:" "$lock" 2>/dev/null || true; }
exec 9< "$lock"
flock 9  # one builder; concurrent runs wait for it

build=$rebuild
if [[ -z $build && -f $img && -f $vars && -d $tpm && ( $variant == plain || -s $recovery ) && -f $meta ]]; then
    age=$(( ( $(date +%s) - $(date -d "$(jq -r .built "$meta")" +%s) ) / 86400 ))
    if (( age > max_days )); then
        build=1
        note "the install is $age days old, near the evaluation's 90; building it again"
    else
        [[ $(xxh "$img") == "$(jq -r .xxh128 "$meta")" && $(xxh "$vars") == "$(jq -r .vars_xxh128 "$meta")" ]] \
            || fail "$img no longer matches its recorded hash (written to instead of a copy?); refusing to reuse it: sudo tests/win11-image.sh --rebuild${plain_arg}"
        note "reusing $name, installed $(jq -r .built "$meta") ($age days ago), hash verified"
    fi
elif [[ -z $build ]]; then
    build=1
    note "$name is not built yet for this recipe; building it (15 to 20 minutes)"
fi

if [[ -n $build ]]; then
    [[ $EUID -eq 0 ]] || fail "building $name needs root: sudo tests/win11-image.sh${plain_arg}"
    [[ -r $iso ]] || fail "no Windows ISO at $iso (the Windows 11 Enterprise evaluation, en-US)"
    command -v swtpm xorriso socat > /dev/null || fail "needs swtpm, xorriso (libisoburn) and socat"
    umask 077
    remove_part() { rm -rf --one-file-system -- "$img.part" "$vars.part" "$vars.part.start" "$tpm.part" "$recovery.part" "$meta.part"; win11_stop "$bench_tmp"; }
    bench_exit_hooks+=(remove_part)
    rm -rf --one-file-system -- "$img.part" "$tpm.part"
    start=$SECONDS
    win11_install "$img.part" "$vars.part" "$tpm.part" "$recovery.part"
    win11_check_boot "$img.part" "$vars.part" "$tpm.part"
    jq -n --arg xxh "$(xxh "$img.part")" --arg vars "$(xxh "$vars.part")" --arg built "$(date -u +%FT%TZ)" \
        --arg recipe "$recipe" --arg name "$name" --argjson seconds $((SECONDS - start)) \
        '{base: $name, xxh128: $xxh, vars_xxh128: $vars, built: $built, recipe: $recipe, build_seconds: $seconds}' > "$meta.part"
    chown -R "$bench_user:" "$img.part" "$vars.part" "$tpm.part" "$recovery.part" "$meta.part"
    rm -rf --one-file-system -- "$tpm"
    mv -f -- "$tpm.part" "$tpm"
    if [[ $variant == plain ]]; then rm -f -- "$recovery.part"; else mv -f -- "$recovery.part" "$recovery"; fi
    mv -f -- "$img.part" "$img"
    mv -f -- "$vars.part" "$vars"
    mv -f -- "$meta.part" "$meta"
    note "built $name in $((SECONDS - start)) s"
fi
printf '%s\n' "$stem"
