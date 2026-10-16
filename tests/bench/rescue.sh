# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# shellcheck shell=bash disable=SC2034,SC2154  # globals set by and for lib.sh and its callers
# The rescue system under test (sourced by lib.sh): its start, and over SSH
# commands, tmux, tty1's screen, the agent's process and session, and the
# image's key.

# rescue_boot <vars> <serial-log> <iso-or-device> <port> <net> [qemu args...]:
# start the rescue system as the owner would, with $rescue_mem MiB (4096):
# the stick (read-only, a snapshot) first in the boot order, a display for
# tty1, the machine's disks (the arguments), and only an SSH forward to the
# host on 127.0.0.1:<port>; a monitor on $rescue_monitor. The stick is first
# through the firmware's own entry for it, not qemu's bootindex: with a
# bootindex OVMF deletes the entry of every disk without one, and every entry
# for a disk that is not there, which the firmware keeps on a real machine;
# a failure to add it returns 1, before any guest starts. net is ok, late (as ok; the caller holds the link down), offline
# (a NIC with no route out), nodhcp (a NIC with a route out but no SSH, and
# a bench-only one with the forward and no route out) or tether (as nodhcp,
# plus a network "phone" with a route out and no device yet: the caller plugs
# a phone's USB tethering in with the monitor's `device_add usb-net,netdev=phone`).
rescue_boot() {
    local vars=$1 log=$2 iso=$3 port=$4 net=$5 forward nics
    shift 5
    efi_add "$vars" "$(python3 "$efi_py" stick)" first > /dev/null || return 1
    forward=hostfwd=tcp:127.0.0.1:$port-:22
    # shellcheck disable=SC2054  # qemu option strings, not array separators
    case $net in
        ok | late) nics=(-netdev "user,id=net0,$forward" -device virtio-net-pci,netdev=net0) ;;
        offline) nics=(-netdev "user,id=net0,restrict=on,$forward" -device virtio-net-pci,netdev=net0) ;;
        nodhcp | tether) nics=(-netdev user,id=net0,ipv6=off -device virtio-net-pci,netdev=net0
                      -netdev "user,id=net1,restrict=on,net=10.0.3.0/24,$forward"
                      -device virtio-net-pci,netdev=net1,mac=52:54:00:be:0c:01)
            [[ $net == nodhcp ]] || nics+=(-netdev user,id=phone,ipv6=off,net=10.0.4.0/24) ;;
        *) fail "rescue_boot: no net $net (ok, late, offline, nodhcp or tether)" ;;
    esac
    rescue_monitor=$bench_tmp/monitor.sock
    # shellcheck disable=SC2054  # qemu option strings, not array separators
    bench_mem "${rescue_mem:-4096}" qemu_ovmf "$vars" "$log" -smp 4 -device VGA \
        -device qemu-xhci,addr=0x8 -drive if=none,id=stick,format=raw,snapshot=on,readonly=on,file="$iso" \
        -device usb-storage,drive=stick "$@" "${nics[@]}" \
        -monitor unix:"$rescue_monitor",server=on,wait=off
}

# rescue_ssh <port> <command...>: run a command as root on the rescue system
# with the configuration's ssh_identity (lib/rescue-config.sh) and a
# throwaway known_hosts.
rescue_ssh() {
    local port=$1
    shift
    ssh -p "$port" -i "$(rescue_ssh_identity)" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=5 \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR root@127.0.0.1 "$@"
}

# rescue_tmux <port> <tmux-args...>: tmux on the rescue system. ssh joins its
# arguments into one remote command line, so each is quoted: a format such as
# '#{window_id} #{window_name}' would otherwise be split, and cut off at #.
rescue_tmux() {
    local port=$1
    shift
    rescue_ssh "$port" "tmux $(printf '%q ' "$@")"
}

# bench_key <file>: the image's API key, read as build.sh reads it (the
# configuration's key_file or key_command, lib/rescue-config.sh), into a new
# root-only file. It is never printed; callers compare it or pipe it.
bench_key() {
    install -m 600 /dev/null "$1"
    rescue_api_key > "$1" 2>/dev/null || true
}

# rescue_key_at_boot <port>: the booted system is a no-key image (build.sh
# --no-key): rescue-secrets found no key on it and left its marker.
rescue_key_at_boot() { rescue_ssh "$1" 'test -e /run/rescue/key-at-boot' > /dev/null 2>&1; }

# rescue_type_key <port> <serial-log> <key-file> [<seconds>]: type the key in
# the file at tty1's prompt of a no-key image, once the prompt waits for it
# (rescue-agent's /run/rescue/key-waiting). The key goes over SSH's stdin into
# a named tmux buffer, is pasted with the buffer's deletion in the same
# command, and then Enter is sent; it is never an argument of any command
# and never echoed (the prompt is masked). Returns 1 when the prompt does not
# appear or the key could not be typed.
rescue_type_key() {
    local port=$1 log=$2 file=$3 secs=${4:-240}
    wait_for "$log" "$secs" rescue_ssh "$port" 'test -e /run/rescue/key-waiting' || return 1
    rescue_tmux "$port" load-buffer -b rescue-key - < "$file" || return 1
    if ! rescue_tmux "$port" paste-buffer -d -b rescue-key -t rescue; then
        rescue_tmux "$port" delete-buffer -b rescue-key > /dev/null 2>&1 || true
        return 1
    fi
    sleep 1
    rescue_tmux "$port" send-keys -t rescue Enter
}

# rescue_screen <port> <regex>: tty1 (the rescue session's current window,
# with its recent history) shows a line matching the regex.
rescue_screen() {
    local screen
    screen=$(rescue_tmux "$1" capture-pane -p -J -t rescue -S -200 2>/dev/null) || return 1
    grep -Eq -- "$2" <<< "$screen"
}

# owner_wifi <port>: as the owner at tty1, join the bench's Wi-Fi network
# (a scenario's wifi=ap, or tests/scenario.sh --wifi-only) from the network
# menu: choose Wi-Fi, pick rescue-bench from the list and type the
# passphrase in $wifi_pass at iwctl's own prompt. tty1 is kept as typed,
# before Enter, and again once the network is up, in
# $results/network-screen.txt: the passphrase line must show nothing typed,
# and no six characters of the passphrase may appear on it. A scenario's
# owner_network calls it.
owner_wifi() {
    local p=$1
    wait_for "$results/rescue-serial.log" 300 rescue_screen "$p" 'NO NETWORK: no address came from the network' \
        || { echo "tty1 showed no network menu within 300 s"; return 1; }
    rescue_tmux "$p" send-keys -t rescue 3 Enter || return 1
    wait_for "$results/rescue-serial.log" 60 rescue_screen "$p" 'Network name, as listed' \
        || { echo "the menu never asked for a network name"; return 1; }
    rescue_screen "$p" 'rescue-bench +psk' || { echo "the menu's list did not show rescue-bench"; return 1; }
    rescue_tmux "$p" send-keys -t rescue -l rescue-bench || return 1
    rescue_tmux "$p" send-keys -t rescue Enter || return 1
    wait_for "$results/rescue-serial.log" 30 rescue_screen "$p" 'Passphrase:' \
        || { echo "iwctl never asked for the passphrase"; return 1; }
    rescue_tmux "$p" load-buffer -b wifi - < "$wifi_pass" || return 1
    rescue_tmux "$p" paste-buffer -d -b wifi -t rescue || return 1
    sleep 0.5
    # The prompt is judged as typed, before Enter: once the network is up the
    # agent's start can clear tty1 before a later capture (run26a, c7 run 1).
    rescue_tmux "$p" capture-pane -p -J -t rescue -S -60 > "$results/network-screen.txt" || return 1
    rescue_tmux "$p" send-keys -t rescue Enter || return 1
    wait_for "$results/rescue-serial.log" 60 rescue_screen "$p" 'rescue-network: the network is up' \
        || { echo "the passphrase was typed, but no route came: $(rescue_ssh "$p" 'ip -brief address; ip route' 2>&1 | tr '\n' ' ')"; return 1; }
    rescue_tmux "$p" capture-pane -p -J -t rescue -S -60 >> "$results/network-screen.txt" || return 1
    grep -qE '^Passphrase: *$' "$results/network-screen.txt" || { echo "tty1 showed something typed at the passphrase prompt"; return 1; }
    secret_parts "$wifi_pass" 6 "$bench_tmp/wifi.parts"
    if grep -qaF -f "$bench_tmp/wifi.parts" "$results/network-screen.txt"; then
        rm -f "$bench_tmp/wifi.parts"; echo "tty1 showed part of the passphrase"; return 1
    fi
    rm -f "$bench_tmp/wifi.parts"
    echo "tty1's network menu listed rescue-bench; the passphrase typed at iwctl's prompt (nothing shown) brought the network up over Wi-Fi"
}

# wait_ssh <port> <seconds> <serial-log>: wait_for the rescue system to accept
# SSH (an OVMF disk stall restarts it).
wait_ssh() { wait_for "$3" "$2" rescue_ssh "$1" true; }

# agent_running <port>: the agent's OpenCode process runs on the rescue system.
# shellcheck disable=SC2016  # expands on the rescue system
agent_running() { rescue_ssh "$1" 'pgrep -f "[o]pencode --standalone"' > /dev/null 2>&1; }

# rescue_export_session <port> <out>: the agent's OpenCode session as JSON,
# read over SSH as the agent itself runs (--standalone, in /root/rescue).
rescue_export_session() {
    # shellcheck disable=SC2016  # expands on the rescue system
    rescue_ssh "$1" 'cd /root/rescue &&
        sid=$(opencode session list --standalone --format json -n 1 2>/dev/null | jq -r "if type == \"array\" then .[0].id else .id end") &&
        [ -n "$sid" ] && opencode session export --standalone "$sid" 2>/dev/null' > "$2.part" && mv -f "$2.part" "$2"
}
