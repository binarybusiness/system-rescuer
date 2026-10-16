#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# Boot a rescue image under OVMF as a USB stick, beside a broken-machine disk
# on a SATA (AHCI) controller, as the scenario bench boots it
# (tests/bench/rescue.sh's rescue_boot, with its OVMF stall restart), and
# check it end to end: SSH login as root with
# the configuration's ssh_identity (lib/rescue-config.sh; and no password
# login), hostname "rescue", the tmux session
# "rescue" running the agent, a passing key check (directly and through
# rescue-proxy, which logs each request without its headers), the key hidden
# from the agent's mount namespace (whose mounts still reach SSH sessions),
# every disk read-only at the block layer, every command the agent's
# toolkit.md names, the offline package repository, and a survey that lists
# the broken disk and the right machine profile.
#
#   tests/qemu-boot.sh out/system-rescuer-*.iso
#   sudo tests/qemu-boot.sh /dev/sdX        # the written stick, read-only (snapshot)
#
#   RESCUE_FIXTURE=generic|none|<machine-profile-dir>
#                                           # the broken disk (tests/make-fixture.sh); with a
#                                           #   profile's directory the survey must name it
#   RESCUE_CONFIG=<dir>                     # the configuration (~/.config/system-rescuer)
#   RESCUE_SSH_KEY=<file>                   # log in with this key instead of ssh_identity
#   RESCUE_EXPECT_LOG=<regex>               # also wait for the agent's log to match,
#   RESCUE_LOG_WAIT=<seconds>               #   e.g. 'initramfs' for the generic fixture
#   RESCUE_PROVIDER_STUB=<config dir>       # the provider-stub mode: the stick is built from this
#                                           #   configuration (provider_url https://10.0.2.2:<port>/v1,
#                                           #   provider_ca_file <dir>/ca.pem, key_file), and
#                                           #   tests/bench/provider-stub.py runs on the host for
#                                           #   the boot; the key check runs against it, and its record
#                                           #   must show the key (by hash) only as the Authorization
#                                           #   header's Bearer value, and a chat request. Build the
#                                           #   stub's test-only ISO, with the stub's CA made first:
#                                           #     python3 tests/bench/provider-stub.py --ca-only --ca-dir <dir>
#                                           #     sudo ./build.sh --config <dir> --out-dir out/test-provider-stub
#                                           #     RESCUE_PROVIDER_STUB=<dir> tests/qemu-boot.sh out/test-provider-stub/system-rescuer-*.iso
#   <iso>.key-at-boot                       # a marker build.sh --no-key leaves: the image carries no
#                                           #   key; the test types the key (the configuration's, or the
#                                           #   stub's) at tty1's prompt and also checks that the prompt
#                                           #   appeared, the ISO holds no byte string of the key, and
#                                           #   the key check and teardown pass after typing. A stick
#                                           #   (/dev/sdX) is told by the system's own report.
#   <stick image file>                      # a no-key image written with a key record past it (install.sh
#                                           #   --prebuilt, or tests/scenario.sh --key-record): the system
#                                           #   says so (/run/rescue/key-from-record); nothing is typed, no
#                                           #   prompt may appear, and the key check passes by itself.
#   RESCUE_EXPECT_RECORD=1                  # fail unless the key came from a record
#   RESCUE_EXPECT_REPO=past|image|none      # where the offline repository must come from: past the
#                                           #   image (--repo-asset), inside it, or nowhere (online
#                                           #   only). Without it, any source passes, and online
#                                           #   only passes for an <iso>.repo-asset image
#   RESCUE_EXPECT_REPO_WHY=<text>           # with none: the reason rescue-repo gave must hold <text>
#   RESCUE_MEM=<MiB>                        # guest memory (4096); with 8192 archiso
#                                           #   copies its root image to RAM and lets go of the stick
#
# qemu uses user-mode networking; the only host exposure is an SSH forward on
# 127.0.0.1.
set -euo pipefail
# shellcheck source=tests/bench/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/bench/lib.sh"
# The key's paths in the image (the one statement the image's scripts read).
# shellcheck source=profile/airootfs/usr/local/lib/rescue-paths.sh
. "$(dirname "${BASH_SOURCE[0]}")/../profile/airootfs/usr/local/lib/rescue-paths.sh"
bench_init qemu-boot

image=${1:?usage: tests/qemu-boot.sh <iso-or-device>}
# The glob above matches every ISO in out/; the dated names sort oldest first.
if (( $# > 1 )); then
    image=$(printf '%s\n' "$@" | sort | tail -n 1)
    echo "qemu-boot: $# images given; checking the newest, $image"
fi
[[ -r $image ]] || { echo "qemu-boot: cannot read $image" >&2; exit 1; }
port=${RESCUE_SSH_PORT:-2222}
boot_timeout=${RESCUE_BOOT_TIMEOUT:-300}
key=$(rescue_ssh_identity)
[[ -r $key ]] || { echo "qemu-boot: cannot read the SSH key $key (ssh_identity, or RESCUE_SSH_KEY)" >&2; exit 1; }
tmp=$bench_tmp
cp "$ovmf_vars" "$tmp/vars.fd"

fixture=${RESCUE_FIXTURE:-generic}
target=()
case $fixture in
    generic) fixture_profile=none ;;
    none) ;;
    *)
        [[ -r $fixture/match ]] || { echo "qemu-boot: RESCUE_FIXTURE $fixture is not generic, none or a machine profile" >&2; exit 1; }
        fixture_profile=$(basename "$fixture")
        ;;
esac
if [[ $fixture != none ]]; then
    made=$("$(dirname "${BASH_SOURCE[0]}")/make-fixture.sh" "$tmp/target.img" "$fixture")
    echo "$made"
    fixture_root=$(sed -n 's/.*; root \([^,]*\),.*/\1/p' <<< "$made")
    mapfile -t target < <(ahci_disk "$tmp/target.img")
fi

# The provider stub, on the host's loopback (qemu's user network reaches it as
# 10.0.2.2), for the boot's length.
stub_pid=''
stub_stop() { [[ -z $stub_pid ]] || kill "$stub_pid" 2>/dev/null || true; }
if [[ -n ${RESCUE_PROVIDER_STUB:-} ]]; then
    stub_cfg=$(rescue_config_dir "$RESCUE_PROVIDER_STUB")
    stub_url=$(rescue_provider_get "$stub_cfg" url)
    [[ $stub_url =~ ^https://10\.0\.2\.2:([0-9]+)/v1$ ]] \
        || { echo "qemu-boot: provider_url in $stub_cfg must be https://10.0.2.2:<port>/v1, not $stub_url" >&2; exit 1; }
    stub_port=${BASH_REMATCH[1]}
    stub_ca=$(rescue_config_path "$stub_cfg" "$(rescue_provider_get "$stub_cfg" ca_file)")
    [[ -r $stub_ca ]] || { echo "qemu-boot: provider_ca_file of $stub_cfg is not readable" >&2; exit 1; }
    stub_key=$tmp/stub-key stub_out=$tmp/stub
    ( umask 077; rescue_api_key "$stub_cfg" > "$stub_key" ) || { echo "qemu-boot: no key in $stub_cfg" >&2; exit 1; }
    python3 -I "$(dirname "${BASH_SOURCE[0]}")/bench/provider-stub.py" "$stub_key" "$stub_port" "$stub_out" \
        --ca-dir "$(dirname "$stub_ca")" > "$tmp/stub.log" 2>&1 &
    stub_pid=$!
    trap 'stub_stop; bench_cleanup' EXIT
    until grep -q listening "$tmp/stub.log"; do
        kill -0 "$stub_pid" 2>/dev/null || fail "the provider stub did not start: $(cat "$tmp/stub.log")"
        sleep 0.2
    done
    pass "provider stub on 127.0.0.1:$stub_port"
fi

rescue_mem=${RESCUE_MEM:-4096}
rescue_boot "$tmp/vars.fd" "$tmp/serial.log" "$image" "$port" ok "${target[@]}" \
    || fail "could not put the stick first in the boot order"

ssh_opts=(-p "$port" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5)
rssh() { ssh "${ssh_opts[@]}" -i "$key" -o BatchMode=yes -o IdentitiesOnly=yes root@127.0.0.1 "$@"; }

wait_for "$tmp/serial.log" "$boot_timeout" rssh true \
    || fail "no SSH login within ${boot_timeout}s (or qemu exited); serial: $(serial_tail "$tmp/serial.log" 5 | tr '\n' ' ')"
pass "SSH login as root with $(basename "$key") after $((SECONDS)) s"

# shellcheck disable=SC2016  # expanded by the booted system's shell
if rssh 'for f in /etc/nvme/hostnqn /etc/nvme/hostid /etc/iscsi/initiatorname.iscsi /etc/brlapi.key; do test -s "$f" || exit 1; done'; then
    pass "machine-specific NVMe, iSCSI and BRLTTY identities exist (this boot's NVMe host id: sha256 $(rssh 'sha256sum < /etc/nvme/hostid' | cut -c1-12))"
else
    fail "machine-specific NVMe, iSCSI and BRLTTY identities are missing or empty"
fi
if [[ -r /etc/nvme/hostnqn ]]; then
    if rssh 'test -s /etc/nvme/hostnqn && ! cmp -s /etc/nvme/hostnqn /dev/stdin' < /etc/nvme/hostnqn; then
        pass "NVMe host NQN differs from the build host"
    else
        fail "NVMe host NQN matches the build host"
    fi
fi

if ssh "${ssh_opts[@]}" -o BatchMode=yes -o PubkeyAuthentication=no -o PreferredAuthentications=password,keyboard-interactive root@127.0.0.1 true 2>/dev/null; then
    fail "password login was accepted"
fi
pass "password login refused"

[[ $(rssh uname -n) == rescue ]] || fail "hostname is not rescue"
pass "hostname rescue"

# cloud-init would act as root on any attached disk labelled cidata.
rssh '! command -v cloud-init >/dev/null' || fail "cloud-init is installed"
pass "no cloud-init"

# A no-key image (build.sh --no-key; its ISO has a .key-at-boot marker) asks
# for the key at tty1 first. The key goes into a root-only file of the bench's
# temp dir, from the stub's scratch key or the configuration's, and is typed
# at the prompt (rescue_type_key: SSH stdin into a tmux buffer, never argv).
key_at_boot=0 key_record=0
if rescue_key_at_boot "$port"; then
    # A record on the stick (rescue-key-record) has put the key in place.
    if rssh 'test -e /run/rescue/key-from-record'; then key_record=1; else key_at_boot=1; fi
fi
if [[ -e $image.key-at-boot && $key_at_boot == 0 && $key_record == 0 ]]; then
    fail "$(basename "$image") is marked key-at-boot, but the system found a key on it"
fi
if [[ ${RESCUE_EXPECT_RECORD:-0} == 1 && $key_record == 0 ]]; then
    fail "expected the key to come from a record on the stick: $(rssh 'cat /run/rescue/record-problem 2>/dev/null || echo "no record was found"')"
fi
if (( key_record )); then
    # Unattended: no prompt, and the key was in place before anything asked.
    rssh 'test ! -e /run/rescue/record-problem' || fail "key record: the record was not usable: $(rssh 'cat /run/rescue/record-problem')"
    rssh 'test ! -e /run/rescue/key-waiting' || fail "key record: tty1 asks for the key although the stick holds one"
    pass "key record: the key came from the stick's $(rssh 'cat /run/rescue/key-from-record') record, nothing typed"
fi
if (( key_at_boot )); then
    typed_key=$tmp/typed-key
    if [[ -n $stub_pid ]]; then
        install -m 600 /dev/null "$typed_key"
        tr -d '\r\n' < "$stub_key" > "$typed_key"
    else
        bench_key "$typed_key"
        tr -d '\r\n' < "$typed_key" > "$typed_key.1" && mv -f "$typed_key.1" "$typed_key"
    fi
    [[ -s $typed_key ]] || fail "key-at-boot: no key in the configuration to type (key_file or key_command)"
    # No agent and no key until it is typed; the prompt names the provider.
    ! rssh 'pgrep -f "opencode --standalone" > /dev/null' || fail "key-at-boot: the agent runs before a key was typed"
    wait_for "$tmp/serial.log" 240 rssh 'test -e /run/rescue/key-waiting' \
        || fail "key-at-boot: the key prompt did not appear on tty1"
    rssh 'tmux capture-pane -p -J -t rescue -S -200' | grep -q 'THIS STICK CARRIES NO API KEY' \
        || fail "key-at-boot: tty1 does not say that the stick carries no key"
    pass "key-at-boot: tty1 asks for the key"
    # The image holds no byte string of the key (grep -c prints 0 and exits 1).
    leaked=$(grep -c -F -f "$typed_key" "$image" || true)
    [[ $leaked == 0 ]] || fail "key-at-boot: the key's bytes are in $(basename "$image") ($leaked matching lines)"
    pass "key-at-boot: no byte string of the key is in the image"
    rescue_type_key "$port" "$tmp/serial.log" "$typed_key" || fail "key-at-boot: could not type the key at tty1"
    rssh 'tmux list-buffers | wc -l' | grep -qx 0 || fail "key-at-boot: a tmux buffer is left behind"
    pass "key-at-boot: key typed at the prompt (SSH stdin into a tmux buffer, deleted at once)"
fi

# The agent session starts after network-online and the key check.
deadline=$((SECONDS + 180))
until rssh 'tmux has-session -t rescue && pgrep -f "opencode --standalone" >/dev/null' 2>/dev/null; do
    (( SECONDS < deadline )) || fail "agent not running in tmux session rescue"
    sleep 5
done
pass "agent running in tmux session rescue (tty1)"

rssh 'cat /run/rescue/keycheck' | grep -q 'OK http 200' || fail "key check: $(rssh 'cat /run/rescue/keycheck' 2>&1)"
pass "key check: $(rssh 'cat /run/rescue/keycheck')"
(( ! key_at_boot )) || pass "key-at-boot: the typed key passed the check, and the agent started only then"
if (( key_record )); then
    rssh 'tmux capture-pane -p -J -t rescue -S -200' | grep -q 'CARRIES NO API KEY' \
        && fail "key record: tty1 showed the key prompt"
    pass "key record: the recorded key passed the check and tty1 never asked for a key"
fi

# rescue-secrets moved the key at boot from the image into a root-only tmpfs
# of its own, and deleted the image's copy from the root overlay.
[[ $(rssh "stat -c %a:%U $rescue_key_file") == 600:root ]] || fail "key file is not 0600 root"
[[ $(rssh "findmnt -rn -o FSTYPE $rescue_key_dir; stat -c %a $rescue_key_dir") == $'tmpfs\n700' ]] \
    || fail "$rescue_key_dir is not a root-only tmpfs"
rssh "test ! -e $rescue_image_key_dir" || fail "the image's copy of the key is still in the root overlay"
rssh 'findmnt -rn /var/lib/iwd > /dev/null' || fail "/var/lib/iwd is not a mount of its own"
pass "key file is root-only (0600) on a tmpfs of its own; the image's copy is gone"

# OpenCode reaches the API only through rescue-proxy, which adds the key, and
# its own mount namespace lacks the secrets' mounts (the key's, iwd's) and the
# image's root; SSH sessions (the system's namespace) still see them.
rssh 'grep -q "127.0.0.1:8484" /root/.config/opencode/opencode.json && ! grep -q "{file:" /root/.config/opencode/opencode.json' \
    || fail "OpenCode's configuration does not go through rescue-proxy"
# The plugin that carries the agent on when its turn ends early.
rssh 'test -s /root/.config/opencode/plugins/rescue-carry-on/index.js' || fail "the rescue-carry-on plugin is missing"
# The watchdog for a command stuck in uninterruptible I/O runs beside it.
rssh 'pgrep -f "^bash /usr/local/bin/rescue-hang-watch [0-9]+$" > /dev/null' || fail "rescue-hang-watch is not watching the agent"
pass "rescue-hang-watch watches the agent's commands"
# shellcheck disable=SC2016  # expanded by the rescue system's shell
rssh 'p=$(pgrep -of "opencode --standalone") && nsenter --mount=/proc/$p/ns/mnt -- sh -c "! mountpoint -q '"$rescue_key_dir"' && ! mountpoint -q /var/lib/iwd && ! mountpoint -q /run/archiso/airootfs && [ -z \"\$(ls -A '"$rescue_key_dir"' 2>/dev/null)\" ]"' \
    || fail "the API key is readable in the agent's mount namespace"
rssh "test -s $rescue_key_file && test -s $rescue_auth_conf" || fail "the key is gone from the system's mount namespace"
pass "API key absent from the agent's namespace, still readable over SSH"
# No sequence of unmounts in the agent's namespace uncovers a secret.
teardown=$(rssh 'bash -s' < "$(dirname "${BASH_SOURCE[0]}")/bench/key-teardown.sh" 2>&1) || fail "key teardown: $teardown"
pass "key teardown: $teardown"
(( ! key_at_boot )) || pass "key-at-boot: the typed key is absent from the agent's namespace"
(( ! key_record )) || pass "key record: the recorded key is absent from the agent's namespace"
# rescue-proxy logs each request's status and duration, and never a header.
rssh 'journalctl -t rescue_proxy -o cat' > "$tmp/proxy.log" 2>/dev/null || true
grep -Eq '^[0-9T:+-]+ [A-Z]+ /v1/[^ ]* [0-9]{3} [0-9.]+ s, [0-9]+ bytes$' "$tmp/proxy.log" || fail "rescue-proxy logged no request line"
! grep -qiE 'authorization|bearer' "$tmp/proxy.log" || fail "rescue-proxy's log names a header"
pass "rescue-proxy logs requests without headers: $(grep -Ec '^[0-9T:+-]+ [A-Z]+ /v1/' "$tmp/proxy.log") so far"
# ...and what the agent mounts still shows in the owner's SSH sessions.
# shellcheck disable=SC2016  # expanded by the rescue system's shell
rssh 'mkdir -p /mnt/ns-probe && nsenter --mount=/proc/$(pgrep -of "opencode --standalone")/ns/mnt -- mount -t tmpfs ns-probe /mnt/ns-probe' \
    || fail "could not mount in the agent's namespace"
rssh 'findmnt -rn /mnt/ns-probe >/dev/null' || fail "a mount in the agent's namespace does not reach SSH sessions"
rssh 'umount /mnt/ns-probe && rmdir /mnt/ns-probe'
pass "the agent's mounts reach SSH sessions"

# Every disk, the stick and the broken disk alike, is read-only at the block
# layer until the agent lifts it for a repair (qemu's empty floppy aside).
rssh 'lsblk -dnro NAME,RO,TYPE' | awk '$3 == "disk" && $1 !~ /^(zram|loop|fd)/' > "$tmp/ro.txt"
writable=$(awk '$2 != 1 {print $1}' "$tmp/ro.txt")
[[ -s $tmp/ro.txt && -z $writable ]] || fail "disks writable at the block layer: ${writable:-none listed}"
pass "every disk is read-only at the block layer ($(wc -l < "$tmp/ro.txt") disks)"

# Every command the agent's toolkit.md names (each single word in backticks)
# resolves on the image, and the check catches a list naming a missing one.
# shellcheck disable=SC2016  # the backticks are literal Markdown
toolkit_commands() { grep -o '`[^`]*`' | tr -d '`' | grep -E '^[A-Za-z0-9][A-Za-z0-9._+-]*$' | sort -u; }
# shellcheck disable=SC2016  # expanded by the rescue system's shell
toolkit_missing() { rssh 'while read -r c; do command -v "$c" > /dev/null || echo "$c"; done'; }
rssh 'cat /root/rescue/toolkit.md' > "$tmp/toolkit.md" || fail "no toolkit.md in the agent's brief"
toolkit_commands < "$tmp/toolkit.md" > "$tmp/toolkit.txt"
[[ -s $tmp/toolkit.txt ]] || fail "toolkit.md names no commands"
missing=$(toolkit_missing < "$tmp/toolkit.txt" | tr '\n' ' ')
[[ -z $missing ]] || fail "toolkit.md names commands the image lacks: $missing"
# shellcheck disable=SC2016  # the backticks are literal Markdown
missing=$({ cat "$tmp/toolkit.md"; printf -- '- `no-such-rescue-tool`\n'; } | toolkit_commands | toolkit_missing)
[[ $missing == no-such-rescue-tool ]] || fail "the toolkit check missed a command the image lacks (got: ${missing:-nothing})"
pass "all $(wc -l < "$tmp/toolkit.txt") commands in toolkit.md resolve; a missing one is caught"

# diskrepair's playbooks: the index and its 16 procedures are on the image.
rssh 'ls /root/diskrepair-playbooks/' > "$tmp/diskrepair.txt" || fail "no /root/diskrepair-playbooks on the image"
grep -qx 'README.md' "$tmp/diskrepair.txt" || fail "/root/diskrepair-playbooks/README.md is missing"
n=$(grep -v '^README.md$' "$tmp/diskrepair.txt" | grep -c '\.md$' || true)
[[ $n -eq 16 ]] || fail "/root/diskrepair-playbooks holds $n playbooks besides README.md, expected 16"
pass "/root/diskrepair-playbooks: README.md and $n playbooks"

# The offline package repository (build.sh) is readable where the playbook
# says, and holds the kernels it names. It is inside the image, or past it
# (build.sh --repo-asset, install.sh --prebuilt); an image built with
# --repo-asset and a stick with no asset is online only, on purpose, and says
# why (rescue-repo's report, /run/rescue/repo-problem).
rssh 'rescue-repo' > /dev/null 2>&1 || true   # waits for the boot's own run
repo_src=$(rssh 'cat /run/rescue/repo-source 2>/dev/null' || true)
if [[ -z $repo_src ]]; then
    repo_why=$(rssh 'cat /run/rescue/repo-problem 2>/dev/null' || true)
    [[ -n $repo_why ]] || fail "no offline repository and rescue-repo gave no reason"
    if [[ ${RESCUE_EXPECT_REPO:-} == none || ( -e $image.repo-asset && -z ${RESCUE_EXPECT_REPO:-} ) ]]; then
        rssh 'test ! -e /run/rescue-repo/rescue.db' || fail "rescue-repo reports no repository, but /run/rescue-repo has one"
        if [[ -n ${RESCUE_EXPECT_REPO_WHY:-} && $repo_why != *"$RESCUE_EXPECT_REPO_WHY"* ]]; then
            fail "offline repository: online only for another reason than '$RESCUE_EXPECT_REPO_WHY': $repo_why"
        fi
        pass "offline repository: none, the stick works online only, as expected: $repo_why"
    else
        fail "no offline repository at /run/rescue-repo: $repo_why"
    fi
else
    [[ ${RESCUE_EXPECT_REPO:-} != none ]] || fail "expected online only, but the repository was found: $repo_src"
    if [[ ${RESCUE_EXPECT_REPO:-} == past && $repo_src != past* ]]; then fail "expected the repository past the image, got: $repo_src"; fi
    if [[ ${RESCUE_EXPECT_REPO:-} == image && $repo_src != inside* ]]; then fail "expected the repository inside the image, got: $repo_src"; fi
    # shellcheck disable=SC2016  # expanded by the rescue system's shell
    repo=$(rssh 'readlink -f /run/rescue-repo && cd /run/rescue-repo && test -e rescue.db && ls linux-[0-9]*.pkg.tar.zst linux-lts-[0-9]*.pkg.tar.zst && ls *.pkg.tar.zst | wc -l' 2>&1) \
        || fail "no offline repository at /run/rescue-repo: $(tr '\n' ' ' <<< "$repo" | cut -c1-300)"
    pass "offline repository at /run/rescue-repo, from $repo_src (-> $(head -n 1 <<< "$repo")): $(tail -n 1 <<< "$repo") packages, $(sed -n 2,3p <<< "$repo" | tr '\n' ' ')"
fi

if [[ $fixture != none ]]; then
    rssh 'cat /run/rescue/survey.txt' > "$tmp/survey.txt" || fail "no survey at /run/rescue/survey.txt"
    grep -q "$fixture_root" "$tmp/survey.txt" || fail "survey does not list the $fixture_profile fixture disk"
    grep -q "^machine profile: $fixture_profile" "$tmp/survey.txt" \
        || fail "survey: expected machine profile $fixture_profile, got: $(grep '^machine profile:' "$tmp/survey.txt")"
    pass "survey lists the fixture disk; $(grep '^machine profile:' "$tmp/survey.txt")"
fi

if [[ -n ${RESCUE_EXPECT_LOG:-} ]]; then
    deadline=$((SECONDS + ${RESCUE_LOG_WAIT:-600}))
    until rssh 'cat /root/rescue-log' 2>/dev/null | grep -Eiq -- "$RESCUE_EXPECT_LOG"; do
        (( SECONDS < deadline )) || fail "agent log never matched /$RESCUE_EXPECT_LOG/; log: $(rssh 'cat /root/rescue-log' 2>&1)"
        sleep 15
    done
    pass "agent log matches /$RESCUE_EXPECT_LOG/:"
    rssh 'cat /root/rescue-log' | cut -c1-300
fi

# Give the agent time to act, then show what tty1 displays.
sleep "${RESCUE_SCREEN_WAIT:-45}"
rssh 'tmux capture-pane -p -t rescue' > "$tmp/screen.txt" || true
# The status line names the model; while the agent asks the owner a question,
# the question dialog replaces it.
# The model's name as the image under test was built with it.
model_name=$(rssh "sed -n 's/^model_name=//p' /etc/rescue/provider.conf")
[[ -n $model_name ]] || fail "no model_name in the image's /etc/rescue/provider.conf"
grep -Fq -e Questions -e "$model_name" "$tmp/screen.txt" || fail "agent screen shows neither the model nor a question; screen: $(cat "$tmp/screen.txt")"
pass "agent screen on tty1:"
grep -v '^[[:space:]]*$' "$tmp/screen.txt" | head -n 30

# With the provider stub: its record shows what reached the "provider". The
# configured key, by hash, is only the Authorization header's Bearer value, and
# a chat request came through.
if [[ -n $stub_pid ]]; then
    record=$stub_out/requests.jsonl
    deadline=$((SECONDS + 120))
    until jq -e 'select(.method == "POST" and .path == "/v1/chat/completions" and .status == 200)' "$record" > /dev/null 2>&1; do
        (( SECONDS < deadline )) || fail "no chat request reached the provider stub; its record: $(cut -c1-300 "$record" 2>&1)"
        sleep 5
    done
    bearer=$(printf 'Bearer %s' "$(tr -d '\n' < "$stub_key")" | sha256sum | cut -d' ' -f1)
    bare=$(tr -d '\n' < "$stub_key" | sha256sum | cut -d' ' -f1)
    jq -e --slurp --arg b "$bearer" --arg k "$bare" '
        map(select(.status == 200)) as $ok
        | ($ok | length) > 0
        and all($ok[]; [.headers[] | select(.name | ascii_downcase == "authorization")] | map(.sha256) == [$b])
        and all(.[]; [.headers[] | select(.name | ascii_downcase != "authorization") | .sha256]
                     | all(. != $b and . != $k))' "$record" > /dev/null \
        || fail "the key is not only the Authorization header's Bearer value in the stub's record"
    ! grep -qFf "$stub_key" "$record" || fail "the stub's record holds the key itself"
    pass "provider stub: $(jq -s 'length' "$record") requests, the key only as the Authorization header's Bearer value; a chat request arrived"
fi
