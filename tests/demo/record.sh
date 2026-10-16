#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# Records docs/demo.mp4 (and its poster, docs/demo-poster.png):
# install.sh --prebuilt writing a stick in a scratch
# VM, then the same key-less image rescuing a broken bench system.
#
#   tests/demo/record.sh <key-less-iso> [--repo <repo-img>] [--wifi-iso <iso>] [--scenario <s>] [--base <b>] [--out <mp4>]
#
# <key-less-iso> is an image built by install.sh --build-only --no-key
# --repo-asset --config examples/config, never from a private configuration
# whose machine profiles the agent may list on screen (its repository asset
# beside it, as <iso minus .iso>-repo.img,
# unless --repo names it). --wifi-iso names a test build of the same tree and
# configuration that also has the bench's no-DHCP overlay (sudo ./build.sh
# --config examples/config --no-key --repo-asset --overlay
# tests/bench/no-dhcp-overlay --out-dir out/demo-wifi, its asset beside it),
# whose wired card never asks for an address: the rescue then runs on it
# under tests/scenario.sh --wifi-only and starts at tty1's network menu, the
# stand-in owner joining the bench's simulated Wi-Fi network. The recording (VHS's tests/demo/install.tape and
# rescue.tape, then ffmpeg) shows only what happens in VMs:
#
# 1. In a scratch Debian VM (tests/quickstart-vm.sh, user `user` on host
#    `workstation`), the image is signed with a throwaway minisign key and
#    written to the VM's USB stick with install.sh --prebuilt --trust-key,
#    a dummy API key typed at its masked prompt; the frames show the
#    signature check, the key prompt, the disk checks and the typed-back
#    name, the write and its verification.
# 2. The same image rescues a bench scenario (default a9-dirty-ext4 on
#    arch-sdboot, a dirty ext4 root whose repairing fsck needs the owner's
#    OK) under sudo tests/scenario.sh --key-record, with the bench's API key
#    in the stick's key record (with --wifi-iso, from the network menu: the
#    scan's list, the name chosen, the passphrase prompt showing nothing). The agent's screen on the stick is captured
#    over SSH from its tmux pane once a second, from the survey through the
#    diagnosis and the stand-in owner's OK to the handback, and so is the
#    boot oracle's serial console, to the bench's BOOT-OK marker: the
#    repaired disk booting on its own.
# 3. rescue.tape replays those captures (a live mirror of the three-minute
#    rescue once left VHS's terminal behind its output): the survey's
#    screens at a steady pace, then, held long enough to read, the cause as
#    the agent logged it, its question, the OK, the repair and its summary.
#
# Captions (record.sh --card) say what each part shows. The host's commands
# are typed while VHS hides the frames. ffmpeg joins the two parts into one
# H.264 MP4 (a video, so a viewer can pause and seek), the installer sped up
# to fit about 45 seconds and the rescue at its replayed pace; the poster is
# rescue.tape's screenshot of the agent's question. The text of every frame
# goes to ~/.cache/system-rescuer/demo/leak/demo-frames.txt, and the video
# is kept only if tests/leak-check.sh finds nothing there (the bench's UUIDs and
# home paths are allowed in tests/leak-check.allow); the frames themselves
# still need a look for hostnames, paths, addresses and keys before the video
# is committed.
# For inline playback in GitHub's README, upload the reviewed MP4 as a video
# attachment and put its returned github.com/user-attachments/assets/ URL on
# a paragraph of its own. A linked poster or repository MP4 link navigates to
# the file instead; a literal video tag is stripped by GitHub's renderer.
# Keep docs/demo.mp4 as the downloadable source copy, and verify playback
# on the live repository page after updating the README's attachment URL.
# Needs vhs (with ttyd and ffmpeg), minisign, sudo, and what
# tests/quickstart-vm.sh and tests/scenario.sh need.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
work=$HOME/.cache/system-rescuer/demo
vm_name=demo vm_port=2310

die() { printf 'record.sh: %s\n' "$*" >&2; exit 1; }
# plain: a captured screen's text, without its colour escapes.
plain() { sed -E 's/\x1b\[[0-9;:?]*[a-zA-Z]//g'; }

# Capturing the rescue (record.sh --capture, in the background while the
# scenario runs): the agent's tmux pane once a second, kept as $frames/NNNNN
# when more than three of its lines changed (fewer is a spinner or a
# counter: half the screens, and as much of the video's size; on tty1's
# network menu, whose prompts are a line each, every change), and its last
# screen; then its log, as $frames/log, and the repaired disk's boot, as
# $frames/boot.
frames=$work/frames
if [[ ${1:-} == --capture ]]; then
    # shellcheck source=lib/rescue-config.sh
    source "$here/lib/rescue-config.sh"
    # shellcheck source=tests/bench/rescue.sh
    source "$here/tests/bench/rescue.sh"
    run=$work/run
    port=$(cat "$run/port")
    until rescue_ssh "$port" 'tmux has-session -t rescue' 2> /dev/null; do
        [[ ! -e $run/scenario.rc ]] || { printf 'the scenario ended before the agent started\n'; exit 1; }
        sleep 3
    done
    keep() { n=$(( n + 1 )); printf '%s\n' "$1" > "$frames/$(printf '%05d' "$n")"; kept=$(plain <<< "$1"); }
    # Until the agent has handed back and its last screen has been seen.
    n=0 kept='' last='' seen=0 menu=0
    while (( seen < 8 )); do
        if frame=$(rescue_ssh "$port" 'tmux capture-pane -e -p -t rescue' 2> /dev/null); then
            last=$frame text=$(plain <<< "$frame")
            [[ $text != *'NO NETWORK: no address'* ]] || menu=1
            (( $(diff <(printf '%s\n' "$text") - <<< "$kept" | grep -c '^<') <= (menu ? 0 : 3) )) || keep "$frame"
            [[ $text != *'rescue-network: the network is up'* ]] || menu=0
        fi
        if (( seen )) || rescue_ssh "$port" 'grep -q "^HANDBACK" /root/rescue-log' 2> /dev/null || [[ -e $run/scenario.rc ]]; then
            seen=$(( seen + 1 ))
        fi
        sleep 1
    done
    [[ $(plain <<< "$last") == "$kept" ]] || keep "$last"
    until [[ -e $run/scenario.rc ]]; do sleep 2; done
    log=$(find "$here/out/scenarios" -maxdepth 2 -name oracle-serial.log -newer "$run/start" -print -quit)
    if [[ -z $log ]] || ! grep -aq '^BOOT-OK' "$log"; then
        printf 'the scenario ended without booting the disk\n'
        exit 1
    fi
    # From the firmware's boot entry to the marker, one line per row, without
    # escapes (whole OSC and DCS strings: systemd's carry the machine id) or
    # other control characters.
    perl -pe 's/\e\][^\a\e]*(?:\a|\e\\)//g; s/\eP[^\e]*\e\\//g; s/\e\[[0-?]*[ -\/]*[@-~]//g; s/\e[ -\/]*[0-~]//g' "$log" \
        | LC_ALL=C tr -d '\000-\010\013-\037' \
        | grep -av '^[[:space:]]*$' | sed -n '/BdsDxe: loading/,/^BOOT-OK/p' | cut -c1-140 > "$frames/boot"
    cp -- "$(dirname "$log")/rescue-log" "$frames/log" || { printf 'the scenario left no rescue log\n'; exit 1; }
    exit 0
fi

# card <title> [<paragraph>...]: a caption on a clear screen and scrollback
# (VHS matches the buffer's first rows), its text also appended to
# $frames/cards for the leak check.
card() {
    local t
    printf '\e[?25l\e[H\e[2J\e[3J\n\n\n  \e[1;33m%s\e[0m\n\n' "$1"
    printf '%s\n' "$1" >> "$frames/cards"
    shift
    for t in "$@"; do
        fold -s -w 100 <<< "$t" | sed 's/^/  /'
        printf '\n'
        printf '%s\n' "$t" >> "$frames/cards"
    done
}
# logged <tag>: the text of the agent's <tag> line. DIAGNOSIS: of those
# before its first change that are not the survey, a note or what it ruled
# out, the first that says it is the cause ("root cause: ..."), else the
# first that matches the scenario's diagnosis regex (as the log oracle
# judges it; the agent logs its context first, such as the firmware's
# entries), else the first (the last line when none qualifies); HANDBACK:
# its last.
logged() {
    awk -v tag="$1" -v re="$(cat "$work/run/diagnosis" 2> /dev/null)" '$2 == tag { $1 = $2 = ""; t = substr($0, 3); line = t
            if (tag != "HANDBACK" && t !~ /^(survey|ruled out|rule[0-9]* ?note|note)/) {
                if (cause == "" && t ~ /^(root )?cause/) cause = t
                if (match1 == "" && re != "" && tolower(t) ~ tolower(re)) match1 = t
                if (first == "") first = t
            } }
        tag != "HANDBACK" && ($2 == "CHANGE" || $2 == "REPAIR") { exit }
        END { if (cause != "") line = cause; else if (match1 != "") line = match1; else if (first != "") line = first
            print (length(line) > 420 ? substr(line, 1, 420) "…" : line) }' "$frames/log"
}

# The installer's caption (record.sh --card-install, typed by install.tape
# before it logs in to the VM).
if [[ ${1:-} == --card-install ]]; then
    card "1 · On your computer: write the stick" \
        "install.sh checks the image's signature and checksum and asks for your model provider's API key at a masked prompt (or reads --key-file). The provider is the image's built-in one, DeepSeek; --endpoint <url> names another OpenAI-compatible provider." \
        "It then shows exactly which disk it will overwrite, writes only after you type that disk's name, and reads the stick back to verify it." \
        "Here: a scratch VM, a downloaded image signed with a test key, a dummy API key, and a USB stick."
    exit 0
fi

# Replaying it (record.sh --replay, typed by rescue.tape): with --wifi-iso,
# tty1's network menu, holding the menu, the scan's list, the passphrase
# prompt and the network coming up; then the agent's
# screens at a steady pace, holding its question (the first screen offering
# "Type your own answer"), the OK on the screen after it, e2fsck's result
# and the last screen; then the boot.
if [[ ${1:-} == --replay ]]; then
    started="The agent starts on the machine's own screen and surveys every disk read-only: every disk starts write-protected at the block layer."
    if [[ -e $work/run/wifi ]]; then
        card "2 · At the broken machine, booted from the stick" \
            "A test-bench machine that no longer boots on its own, started from a stick with the bench's real API key in its key record." \
            "For this demo the wired network is switched off: the stick is a test build whose wired card never asks for an address, so it has to get online by Wi-Fi."
        net=0
    else
        card "2 · At the broken machine, booted from the stick" \
            "A test-bench machine that no longer boots on its own, started from a stick of the same image (with the bench's real API key in its key record)." \
            "$started"
        net=3
    fi
    sleep 7
    show() { local frame; frame=$(cat "$1"); printf '\e[H%s\e[0m\e[K\e[J' "${frame//$'\n'/$'\e[0m\e[K\n'}"; }
    files=("$frames"/[0-9]*)
    asked=0 repaired=0 listed=0 prompted=0
    for i in "${!files[@]}"; do
        f=${files[i]} hold=0.3
        # net: 0 before the menu, 1 on it, 2 online (the agent's card is
        # next), 3 the agent's screens.
        if (( net == 0 )) && grep -q 'NO NETWORK: no address' "$f"; then
            net=1 hold=5
            card "No network from a cable, so the stick shows its menu" \
                "The agent's model runs online. The menu offers a phone's USB tethering, a static address or Wi-Fi; the owner picks Wi-Fi, chooses the network from the scan and types its password at iwd's own prompt, which shows nothing as it is typed."
            sleep 8
        elif (( net == 1 )) && grep -q 'rescue-network: the network is up' "$f"; then
            net=2 hold=3
        elif (( net == 1 && ! prompted )) && grep -q 'Passphrase:' "$f"; then
            prompted=1 hold=4
        elif (( net == 1 && ! listed )) && grep -q 'Network name, as listed' "$f"; then
            listed=1 hold=5
        elif (( net == 2 )); then
            net=3
            card "Online over Wi-Fi: the agent starts by itself" "$started"
            sleep 5
        fi
        if (( net < 3 )); then
            :
        elif (( ! asked )) && grep -q 'Type your own answer' "$f"; then
            asked=1 hold=9
            card "It found the cause without writing to any disk" "Its diagnosis, as it logged it: $(logged DIAGNOSIS)" \
                "Now it asks the owner before the one step that could lose data."
            sleep 8
        elif (( asked == 1 )); then
            asked=2 hold=2
            card "The owner answers OK" "It runs the repair, checks the filesystem and the boot chain, and logs every step."
            sleep 4
        elif (( ! repaired )) && grep -q 'FILE SYSTEM WAS MODIFIED' "$f"; then
            repaired=1 hold=3
        fi
        (( i < ${#files[@]} - 1 )) || hold=8
        show "$f"
        sleep "$hold"
    done
    card "3 · Without the stick, the repaired disk boots on its own" "Its serial console follows."
    sleep 3
    clear
    # 25 lines at a time: a line at a time redraws the whole scrolling screen
    # for each line, which once made most of the recording's size.
    n=0
    while IFS= read -r line; do
        printf '%s\n' "$line"
        (( ++n % 25 )) || sleep 0.7
    done < "$frames/boot"
    # On a clear screen: VHS matches the screen's first rows, which the boot
    # log has scrolled past.
    sleep 2
    card "$(tail -n 1 "$frames/boot"): the system came up on its own, without the stick." \
        "The agent's handback: $(logged HANDBACK)"
    exit 0
fi

iso='' repo='' wifi_iso='' scenario=a9-dirty-ext4 base=arch-sdboot out=$here/docs/demo.mp4
while (( $# )); do
    case $1 in
        --repo) repo=${2:?}; shift ;;
        --wifi-iso) wifi_iso=${2:?}; shift ;;
        --scenario) scenario=${2:?}; shift ;;
        --base) base=${2:?}; shift ;;
        --out) out=${2:?}; shift ;;
        -*) die "unknown option $1" ;;
        *) [[ -z $iso ]] || die "one image only"; iso=$1 ;;
    esac
    shift
done
[[ -n $iso && -r $iso ]] || die "usage: tests/demo/record.sh <key-less-iso> [--repo <repo-img>] [--wifi-iso <iso>] [--scenario <s>] [--base <b>] [--out <mp4>]"
[[ -e $iso.key-at-boot ]] || die "$iso is not a key-less image (no $iso.key-at-boot beside it)"
repo=${repo:-${iso%.iso}-repo.img}
[[ -r $repo ]] || die "no repository asset $repo (--repo names it)"
# The rescue's image and asset: the Wi-Fi test build's, or the installer's.
rescue_iso=${wifi_iso:-$iso} rescue_repo=$repo
if [[ -n $wifi_iso ]]; then
    [[ -r $wifi_iso && -e $wifi_iso.key-at-boot ]] || die "$wifi_iso is not a readable key-less image"
    rescue_repo=${wifi_iso%.iso}-repo.img
    [[ -r $rescue_repo ]] || die "no repository asset $rescue_repo beside $wifi_iso"
fi
for t in vhs ffmpeg ffprobe minisign sudo; do command -v "$t" > /dev/null || die "$t is not installed"; done
(( EUID != 0 )) || die "run it as yourself; it asks sudo for the scenario"
sudo -n true 2> /dev/null || die "sudo needs a password here; run sudo -v first"

rm -rf -- "$work"
install -d -m 700 "$work" "$work/assets" "$work/run" "$frames"

# The release-shaped assets: undated names, a throwaway key's signatures.
# shellcheck source=lib/release-layout.sh
. "$here/lib/release-layout.sh"
cp --reflink=auto -- "$iso" "$work/assets/$release_iso"
cp --reflink=auto -- "$repo" "$work/assets/$release_repo"
minisign -G -W -p "$work/assets/demo-release.pub" -s "$work/demo-release.key" > /dev/null
(
    cd "$work/assets"
    for f in "$release_iso" "$release_repo"; do
        sha256sum "$f" > "$f.sha256"
        minisign -S -s "$work/demo-release.key" -m "$f" -t "$(printf 'file:%s\tversion:v0.0.0' "$f")" > /dev/null
    done
)

# The scratch VM: the public tree, the assets, minisign.
"$here/tests/public-export.sh" "$work/export" > "$work/export.log" 2>&1 || die "the export failed; see $work/export.log"
"$here/tests/quickstart-vm.sh" down "$vm_name" 2> /dev/null || true
"$here/tests/quickstart-vm.sh" up "$vm_name" "$work/export" --port "$vm_port" --user user --hostname workstation \
    > "$work/vm.log" 2>&1 || die "the VM did not come up; see $work/vm.log"
vm_dir=$HOME/.cache/system-rescuer/quickstart-vm/$vm_name
vm() {
    ssh -p "$vm_port" -i "$vm_dir/vm-key" -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR user@127.0.0.1 "$@"
}
vm 'sudo apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git minisign curl > /dev/null' \
    > "$work/vm-setup.log" 2>&1 || die "installing git and minisign in the VM failed; see $work/vm-setup.log"
# The clone in /work, so no frame shows a home directory: a bind
# mount of the VM's large disk (/home), since its root disk cannot hold the image.
vm 'sudo install -d -o user -g user /home/work /work && sudo mount --bind /home/work /work && git clone -q /srv/system-rescuer.git /work/system-rescuer' \
    >> "$work/vm-setup.log" 2>&1 || die "cloning in the VM failed; see $work/vm-setup.log"
tar -C "$work/assets" -cf - . | vm 'tar -C /work/system-rescuer -xf -'

# The installer, in the VM. The tapes reach the VM and the rescue through these.
export DEMO_VM="ssh -t -p $vm_port -i $vm_dir/vm-key -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR user@127.0.0.1"
export DEMO_RESCUE="$here/tests/demo/record.sh --replay" DEMO_CARD="$here/tests/demo/record.sh --card-install"
( cd "$work" && vhs "$here/tests/demo/install.tape" ) > "$work/vhs-install.log" 2>&1 \
    || die "vhs failed on the installer; see $work/vhs-install.log"
"$here/tests/quickstart-vm.sh" down "$vm_name" || true

# The rescue, captured: its port, and a marker its result directory is newer than.
port=$(( 2600 + RANDOM % 200 ))
while ss -Hltn "sport = :$port" | grep -q .; do port=$(( 2600 + RANDOM % 200 )); done
printf '%s\n' "$port" > "$work/run/port"
[[ -z $wifi_iso ]] || touch "$work/run/wifi"
# The scenario's diagnosis regex, for the caption of the cause (logged).
sed -n "s/^diagnosis='\([^']*\)'.*/\1/p" "$here/tests/scenarios/$scenario/scenario.conf" > "$work/run/diagnosis"
touch "$work/run/start"
"$here/tests/demo/record.sh" --capture > "$work/capture.log" 2>&1 &
capture_pid=$!
# shellcheck disable=SC2024  # the log is the caller's file, on purpose
sudo SCENARIO_SSH_PORT="$port" "$here/tests/scenario.sh" "$scenario" --base "$base" --iso "$rescue_iso" \
    ${wifi_iso:+--wifi-only} --key-record --repo-asset "$rescue_repo" > "$work/run/scenario.log" 2>&1 && rc=0 || rc=$?
echo "$rc" > "$work/run/scenario.rc"
grep -m1 '^scenario: ' "$work/run/scenario.log" || true
capture_rc=0
wait "$capture_pid" || capture_rc=$?
[[ $rc == 0 ]] || die "the scenario did not pass (exit $rc); see $work/run/scenario.log"
(( capture_rc == 0 )) || die "the capture failed; see $work/capture.log"
( cd "$work" && vhs "$here/tests/demo/rescue.tape" ) > "$work/vhs-rescue.log" 2>&1 \
    || die "vhs failed on the rescue; see $work/vhs-rescue.log"

# The video: the installer sped up to about 45 seconds, the rescue as
# replayed, joined; a keyframe every 2 seconds, so seeking lands near where it is
# asked, and the index first, so a browser plays it before it has all of it.
length() { ffprobe -v error -show_entries format=duration -of csv=p=0 "$1"; }
speed() { awk -v d="$1" -v t="$2" 'BEGIN { s = d / t; printf "%.3f", (s < 1 ? 1 : s) }'; }
s1=$(speed "$(length "$work/install.mp4")" 45)
mp4=$work/demo.mp4
ffmpeg -v error -y -i "$work/install.mp4" -i "$work/rescue.mp4" -filter_complex \
    "[0:v]setpts=PTS/$s1,fps=10[a];[1:v]fps=10[b];[a][b]concat=n=2:v=1,format=yuv420p[v]" \
    -map '[v]' -c:v libx264 -preset slow -crf 28 -tune animation -g 20 -movflags +faststart \
    "$mp4" || die "ffmpeg could not make the video"
[[ -s $work/poster.png ]] || die "rescue.tape took no poster screenshot"
# Every captured screen's text too, not only what VHS reports.
text=$work/leak/demo-frames.txt
rm -rf -- "$work/leak"
install -d -m 700 "$work/leak"
{
    cat "$work/install.txt" "$work/rescue.txt"
    for f in "$frames"/[0-9]*; do plain < "$f"; done
    cat "$frames/boot" "$frames/cards"
} > "$text"
"$here/tests/leak-check.sh" --tree "$work/leak" > "$work/leak.log" 2>&1 \
    || die "the leak check found something in the frames' text; see $work/leak.log"
# The Wi-Fi password's prompt is in the video, and shows nothing typed.
[[ -z $wifi_iso ]] || grep -qE '^Passphrase: *$' "$text" \
    || die "no frame shows iwctl's passphrase prompt with nothing typed"
size=$(stat -c %s "$mp4")
(( size < 10 * 1048576 )) || die "the video is $(( size / 1048576 )) MiB, over 10 MiB: $mp4"
install -m 644 "$mp4" "$out"
install -m 644 "$work/poster.png" "${out%.mp4}-poster.png"
printf 'record.sh: %s (%s KiB; the installer %sx); every frame'"'"'s text in %s\n' \
    "$out" "$(( size / 1024 ))" "$s1" "$text"
