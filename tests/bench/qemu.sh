# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# shellcheck shell=bash disable=SC2034,SC2154  # globals set by and for lib.sh and its callers
# The bench's guests (sourced by lib.sh): OVMF guests with a serial log and
# a monitor, the vCPU kick and the OVMF disk-stall restart, LUKS unlocking on
# the serial console, and the scenario disk's qemu arguments.

# qemu_ovmf <vars-file> <serial-log> [qemu args...]: start a KVM guest under
# OVMF in the background, serial to a file; its pid goes on bench_pids and
# into $qemu_pid, and the call into $qemu_last so wait_for can repeat it. The
# variable store as it was at the start is kept as <vars-file>.start, so that
# a repeat starts from it: the firmware consumes BootNext before it stalls.
# bench_mem <MiB> <command...>: run a qemu_ovmf* call with that guest memory;
# qemu_last records it so that a stall restart keeps the memory.
bench_mem() { local BENCH_MEM=$1; shift; "$@"; }
# bench_machine: a second system that needs more of the machine than the
# bench's default (tests/with/win11-eval.sh: q35, another firmware build, a
# TPM) defines with_qemu, which runs before every guest start, a stall
# restart's too, and sets with_qemu_args; the machine's own arguments go
# first.
with_qemu_args=() with_oracle_args=()
bench_machine() {
    with_qemu_args=()
    declare -F with_qemu > /dev/null || return 0
    with_qemu || fail "the second system's machine could not be set up (with_qemu)"
}
# qemu_monitor: set qemu_mon to the next guest's monitor socket (one guest at
# a time per script), for vcpu_kick.
qemu_monitor() { qemu_mon=$bench_tmp/qemu-mon.sock; rm -f -- "$qemu_mon"; }
# vcpu_kick: make the guest's vCPUs leave KVM once (the monitor reads their
# registers). On the SMM firmware of a Windows machine (tests/bench/win11.sh)
# a vCPU now and then waits for a wakeup it never gets: OVMF sat at its logo
# in 3 of 11 boots, until a kick, which got it going within a second
# (seen 2026-10-14); a restart only tried its luck again.
vcpu_kick() {
    [[ -S ${qemu_mon:-} ]] || return 0
    printf 'info registers -a\n' | timeout 5 socat - UNIX-CONNECT:"$qemu_mon" > /dev/null 2>&1 || true
}
qemu_ovmf() {
    qemu_last=(bench_mem "${BENCH_MEM:-1024}" qemu_ovmf "$@")
    local vars=$1 serial=$2
    shift 2
    ovmf_guest "$vars" -serial file:"$serial" "$@"
}

# qemu_ovmf_sock <vars> <socket> <serial-log> [qemu args...]: like qemu_ovmf,
# but the serial port is a unix socket the host can type into (socat), with
# everything the guest prints copied to the log.
qemu_ovmf_sock() {
    qemu_last=(bench_mem "${BENCH_MEM:-1024}" qemu_ovmf_sock "$@")
    local vars=$1 sock=$2 serial=$3
    shift 3
    ovmf_guest "$vars" -chardev socket,id=ser0,path="$sock",server=on,wait=off,logfile="$serial" -serial chardev:ser0 "$@"
}

# ovmf_guest <vars> [qemu args...]: the body both share, the serial port
# among the arguments. Both names stay: boot_wait, which calls them, is in
# every base's recipe hash.
ovmf_guest() {
    local vars=$1
    shift
    cp -f -- "$vars" "$vars.start"
    bench_machine
    qemu_monitor
    qemu-system-x86_64 -enable-kvm -cpu host -m "${BENCH_MEM:-1024}" -nodefaults -display none \
        -drive if=pflash,format=raw,readonly=on,file="$ovmf_code" \
        -drive if=pflash,format=raw,file="$vars" "${with_qemu_args[@]}" \
        -monitor unix:"$qemu_mon",server=on,wait=off "$@" &
    qemu_pid=$!
    bench_pids+=("$qemu_pid")
}

# ovmf_stalled <log> <seconds since boot>: OVMF's disk reads timed out. On a
# loaded, swapping host its AHCI driver gives up on a slow read ("Failed to
# load image ...: Time out"), or prints nothing after its screen setup.
ovmf_stalled() {
    tr -d '\r' 2>/dev/null < "$1" | grep -Eaq 'Failed to load image.*Time out|start_image\(\) returned Time out' && return 0
    (( $2 >= 60 && $(stat -c %s "$1" 2>/dev/null || echo 0) < 200 ))
}

# wait_for <log> <seconds> <command...>: wait until the command succeeds.
# While the guest's serial log stays the same size, its vCPUs are kicked
# (vcpu_kick) every 5 s. A guest that qemu_ovmf or qemu_ovmf_sock started and
# whose firmware stalled all the same (ovmf_stalled on its serial log) is
# restarted with the same arguments, up to BENCH_STALL_RETRIES times
# (default once, 0 for never), from the variable store it started with, the
# stalled log kept as <log>.stall.
wait_for() {
    local log=$1 secs=$2 deadline start=$SECONDS retries=${BENCH_STALL_RETRIES:-1} size=-1 grew=$SECONDS now
    shift 2
    deadline=$((SECONDS + secs))
    until "$@" 2>/dev/null; do
        now=$(stat -c %s "$log" 2>/dev/null || echo 0)
        if (( now != size )); then size=$now grew=$SECONDS
        elif (( SECONDS - grew >= 5 )); then vcpu_kick; grew=$SECONDS; fi
        if (( retries > 0 && ${#qemu_last[@]} > 0 )) && ovmf_stalled "$log" $((SECONDS - start)); then
            retries=$((retries - 1))
            printf '%s: OVMF disk stall after %d s; restarting the guest once\n' "$bench_name" $((SECONDS - start)) >&2
            local again=("${qemu_last[@]}") vars
            vars=${qemu_last[3]}
            stop_qemu
            cp -f -- "$vars.start" "$vars"
            mv -f "$log" "$log.stall"
            "${again[@]}"
            start=$SECONDS deadline=$((SECONDS + secs))
            continue
        fi
        (( SECONDS < deadline )) || return 1
        [[ -z ${qemu_pid:-} ]] || kill -0 "$qemu_pid" 2>/dev/null || return 1
        sleep 2
    done
}

# serial_matches <log> <extended-regex>: the serial log has a matching line.
serial_matches() { [[ -f $1 ]] && tr -d '\r' < "$1" | grep -Eaq -- "$2"; }
# wait_serial <log> <extended-regex> <seconds>: wait_for the log to match.
wait_serial() { wait_for "$1" "$3" serial_matches "$1" "$2"; }
# serial_tail <log> [lines]: the log's last lines (15), for an error message.
# serial_text <log>: the log's text lines, without carriage returns, terminal
# escapes or blank lines.
serial_text() { tr -d '\r' < "$1" 2>/dev/null | sed 's/\x1b\[[0-9;=?]*[a-zA-Z]//g' | grep -av '^[[:space:]]*$'; }
serial_tail() { tr -d '\r' < "$1" 2>/dev/null | tail -n "${2:-15}"; }

# type_serial <socket> <file>: type the file's first line on the guest's
# serial console, one character every 50 ms (a burst overruns the emulated
# UART's FIFO), then Enter. The text never enters argv.
type_serial() {
    local sock=$1 file=$2
    {
        local line c
        IFS= read -r line < "$file" || true
        while IFS= read -r -n1 c; do printf '%s' "$c"; sleep 0.05; done <<< "$line"
        printf '\r'
    } | socat -u STDIN UNIX-CONNECT:"$sock"
}

# boot_wait <vars> <serial-log> <passphrase-file|''> <extended-regex> <seconds>
# [qemu args...]: start a guest and wait_for its serial log to match. With a
# passphrase file the serial port is a socket, and whenever the initramfs asks
# for a LUKS passphrase (up to three times) it is typed there from the file,
# as the owner would at the console.
boot_wait() {
    local vars=$1 log=$2 passfile=$3 regex=$4 secs=$5
    shift 5
    if [[ -z $passfile ]]; then
        qemu_ovmf "$vars" "$log" "$@"
        wait_serial "$log" "$regex" "$secs"
        return
    fi
    local sock=$bench_tmp/serial-$$-$RANDOM.sock
    boot_typed=0 boot_typed_at=0 boot_retyped=0
    qemu_ovmf_sock "$vars" "$sock" "$log" "$@"
    wait_for "$log" "$secs" boot_unlocked "$log" "$sock" "$passfile" "$regex"
}
boot_unlocked() {  # boot_unlocked <log> <socket> <passphrase-file> <regex>
    serial_matches "$1" "$4" && return 0
    local asked last
    asked=$(tr -d '\r' < "$1" 2>/dev/null | grep -ac 'Please enter passphrase' || true)
    if (( asked > boot_typed && boot_typed < 3 )); then
        sleep 1  # let the prompt settle before typing
        type_serial "$2" "$3"
        boot_typed=$asked boot_typed_at=$SECONDS
    elif (( asked && asked == boot_typed && SECONDS - boot_typed_at >= 15 && boot_retyped < 2 )); then
        # Typed before the password agent read the console, the passphrase is
        # flushed unseen: the prompt is still the last line, with no echo.
        last=$(tr -d '\r' < "$1" 2>/dev/null | grep -av '^[[:space:]]*$' | tail -n 1)
        if [[ $last == *'Please enter passphrase'* && $last != *'•'* && $last != *'*'* ]]; then
            type_serial "$2" "$3"
            boot_typed_at=$SECONDS boot_retyped=$((boot_retyped + 1))
        fi
    fi
    return 1
}

# qemu_exited <seconds>: the guest started last powers off within them.
qemu_exited() {
    local i
    for (( i = 0; i < $1; i++ )); do kill -0 "$qemu_pid" 2>/dev/null || return 0; sleep 1; done
    return 1
}

# stop_qemu: kill the guest started last and wait for it.
stop_qemu() {
    qemu_last=()
    [[ -n ${qemu_pid:-} ]] || return 0
    kill "$qemu_pid" 2>/dev/null || true  # it may have powered off already
    wait "$qemu_pid" 2>/dev/null || true
    qemu_pid=
    rm -f -- "${qemu_mon:-}"
}

# ahci_disk <image> [format]: qemu arguments for a disk on an AHCI controller.
ahci_disk() {
    printf '%s\n' -device ahci,id=ahci -drive "if=none,id=disk0,format=${2:-raw},file=$1" -device ide-hd,drive=disk0,bus=ahci.0
}

# bench_disk <image> <ahci|nvme|virtio-scsi> [format] [blkdebug-config]:
# qemu arguments for the scenario disk on that bus, its device last (a caller
# may append a bootindex), always with the AHCI controller "ahci" for the
# other disks. With a blkdebug configuration the disk's reads go through
# qemu's blkdebug driver, which fails those its rules name.
bench_disk() {
    local format=${3:-raw} node
    if [[ -n ${4:-} ]]; then
        node=(-blockdev "driver=file,node-name=disk0-file,filename=$1"
              -blockdev "driver=blkdebug,node-name=disk0-dbg,image=disk0-file,config=$4"
              -blockdev "driver=$format,node-name=disk0,file=disk0-dbg")
    else
        node=(-drive "if=none,id=disk0,format=$format,file=$1")
    fi
    case $2 in
        ahci) printf '%s\n' -device ahci,id=ahci "${node[@]}" -device ide-hd,drive=disk0,bus=ahci.0 ;;
        nvme) printf '%s\n' -device ahci,id=ahci "${node[@]}" -device nvme,serial=bench-disk0,drive=disk0 ;;
        virtio-scsi) printf '%s\n' -device ahci,id=ahci -device virtio-scsi-pci,id=scsi "${node[@]}" -device scsi-hd,drive=disk0,bus=scsi.0 ;;
        *) fail "bench_disk: no bus $2 (ahci, nvme or virtio-scsi)" ;;
    esac
}
