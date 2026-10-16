#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# Spike: a record of every command the agent ran, and the API cost and
# wall time of one agent run, on the rescue ISO with the generic fixture disk.
#
# The rescue ISO boots without the agent; over SSH the spike installs audit
# from the build host's pacman cache, arms an execve rule (the exec log, which also
# sees what scripts run), then starts the agent the way tty1 does. The stand-in
# owner answers No to anything the agent asks. When the agent stops, OpenCode's
# session export (OpenCode 2.x: tool calls, the session's cost and tokens) is
# read over SSH and every shell tool call is matched to an execve in the audit
# log. One run of the generic fixture costs about US$0.05 to US$0.07.
#
#   tests/spikes/command-record.sh [out/system-rescuer-*.iso]
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

here=$(dirname "${BASH_SOURCE[0]}")
iso=${1:-$(find "$here/../../out" -maxdepth 1 -name 'system-rescuer-*.iso' | sort | tail -n 1)}
[[ -r ${iso:-} ]] || fail "no readable rescue ISO (build one, or pass its path)"
port=${SPIKE_SSH_PORT:-2232}
run_timeout=${SPIKE_RUN_TIMEOUT:-1200}

"$here/../make-fixture.sh" "$spike_tmp/target.img" generic
mapfile -t disk < <(ahci_disk "$spike_tmp/target.img")
rescue_boot_noagent "$iso" "$port" "$spike_tmp/serial.log" "${disk[@]}"
wait_ssh "$port" 240 "$spike_tmp/serial.log" || fail "rescue system not reachable over SSH"
pass "rescue ISO up without the agent, generic fixture attached"

# The exec log: audit from the build host's package cache, rules armed before the agent starts.
rescue_ssh "$port" 'mkdir -p /tmp/pkgs'
for pkg in audit libcap-ng krb5; do
    [[ $pkg != audit ]] && rescue_ssh "$port" "pacman -Q $pkg" > /dev/null 2>&1 && continue  # the image's own version stays
    file=$(pacman -Q "$pkg" | awk '{print $1 "-" $2}')
    [[ -r /var/cache/pacman/pkg/$file-x86_64.pkg.tar.zst ]] || fail "$file is not in the build host's pacman cache"
    rescue_ssh "$port" "cat > /tmp/pkgs/$file-x86_64.pkg.tar.zst" < "/var/cache/pacman/pkg/$file-x86_64.pkg.tar.zst"
done
rescue_ssh "$port" 'pacman -U --noconfirm --needed /tmp/pkgs/*.pkg.tar.zst && systemctl start auditd &&
    auditctl -a always,exit -F arch=b64 -S execve,execveat -k rescue-exec' > "$spike_tmp/audit-setup.log" 2>&1 \
    || fail "audit setup failed: $(tail -n 5 "$spike_tmp/audit-setup.log")"
pass "audit armed: $(rescue_ssh "$port" 'auditctl -l')"

# Start the agent as tty1's autologin would (rescue-agent-start makes the
# "rescue" session; its final attach fails inside this detached session).
rescue_ssh "$port" 'tmux new-session -d -s boot -x 160 -y 45 /usr/local/bin/rescue-agent-start'
owner_tmux=(rescue_tmux "$port") owner_target=rescue
deadline=$((SECONDS + 300))
until rescue_ssh "$port" 'tmux has-session -t rescue && pgrep -f "[o]pencode --standalone"' > /dev/null 2>&1; do
    (( SECONDS < deadline )) || fail "agent did not start"
    sleep 5
done
start=$SECONDS
pass "agent started in tmux session rescue"

# export_session: the agent's session as JSON, read over SSH through a
# private server, as the agent itself runs (--standalone).
export_session() {
    # shellcheck disable=SC2016  # expands on the rescue system
    rescue_ssh "$port" 'cd /root/rescue &&
        sid=$(opencode session list --standalone --format json -n 1 2>/dev/null | jq -r "if type == \"array\" then .[0].id else .id end") &&
        [ -n "$sid" ] && opencode session export --standalone "$sid" 2>/dev/null' > "$spike_tmp/export.json"
}
# agent_state: "review" (a form's answers await submission), "question",
# "idle" (the session's last message is OpenCode's idle marker), or "busy".
agent_state() {
    owner_form_review && { echo review; return; }
    owner_question_open && { echo question; return; }
    export_session && jq -e '.messages[-1].type == "idle"' "$spike_tmp/export.json" > /dev/null 2>&1 && { echo idle; return; }
    echo busy
}
printf 'No. Stop here: log your diagnosis and hand back.' > "$spike_tmp/no.txt"
questions=0
while :; do
    (( SECONDS - start < run_timeout )) || fail "agent still busy after $run_timeout s"
    case $(agent_state) in
        idle) break ;;
        review) owner_submit_form && pass "stand-in owner submitted the form"; sleep 5 ;;
        question)
            questions=$((questions + 1))
            q=$(owner_question)
            if [[ -n $(owner_option_number No) ]]; then owner_choose No; else owner_type "$spike_tmp/no.txt"; fi \
                || fail "could not answer: $q"
            pass "stand-in owner answered No to: $q"
            sleep 3 ;;
        *) sleep 20 ;;
    esac
done
pass "agent finished its turn after $((SECONDS - start)) s, $questions question(s) answered"

export_session || fail "no session export"
jq -r '[.messages[] | select(.type == "assistant")] as $calls | .info |
    "cost US$\(.cost * 1000 | round / 1000)",
    "session time \((.time.updated - .time.created) / 1000 | round) s",
    "tokens: input \(.tokens.input), output \(.tokens.output), reasoning \(.tokens.reasoning), cache read \(.tokens.cache.read)",
    "\($calls | length) model calls"' "$spike_tmp/export.json" > "$spike_tmp/cost.txt"
pass "usage from the session export: $(paste -sd ';' "$spike_tmp/cost.txt" | sed 's/;/; /g')"

tools='.messages[].content[]? | select(.type == "tool")'
jq -r "$tools"' | select(.name == "shell") | .state.input.command' "$spike_tmp/export.json" > "$spike_tmp/shell-commands.txt"
jq -c "$tools"' | select(.name == "shell") | .state.input.command' "$spike_tmp/export.json" > "$spike_tmp/shell-commands.jsonl"
n=$(wc -l < "$spike_tmp/shell-commands.jsonl")
(( n > 0 )) || fail "the export records no shell tool calls"
# --input-logs: without a terminal on stdin, ausearch reads records from stdin instead of the log.
rescue_ssh "$port" 'ausearch --input-logs --raw -k rescue-exec' > "$spike_tmp/ausearch.raw" \
    || fail "ausearch found no exec records: $(head -c 300 "$spike_tmp/ausearch.raw")"
python3 "$here/../bench/exec-record.py" < "$spike_tmp/ausearch.raw" > "$spike_tmp/execs.jsonl"
pass "exec log: $(wc -l < "$spike_tmp/execs.jsonl") execve records; export: $n shell tool calls, other tool calls:$(jq -r "$tools"' | select(.name != "shell") | .name' "$spike_tmp/export.json" | sort | uniq -c | tr -s ' ' | paste -sd ',')"

# Every shell tool call must appear in the exec log as a shell's command string.
missing=0
while IFS= read -r cmd; do
    jq -e --argjson c "$cmd" 'select(.argv | index($c))' "$spike_tmp/execs.jsonl" > /dev/null \
        || { missing=$((missing + 1)); printf 'not in the exec log: %s\n' "$(jq -r . <<< "$cmd" | head -c 200)" >&2; }
done < "$spike_tmp/shell-commands.jsonl"
(( missing == 0 )) || fail "$missing of $n shell tool calls are missing from the exec log"
pass "all $n shell tool calls appear in the exec log as a shell's command string"
shell=$(jq -r --argjson c "$(head -n 1 "$spike_tmp/shell-commands.jsonl")" 'select(.argv | index($c)) | .argv[0:2] | join(" ")' "$spike_tmp/execs.jsonl" | head -n 1)
pass "OpenCode runs them as: $shell <command>"
if [[ -n ${BENCH_KEEP:-} ]]; then
    printf 'first shell commands:\n'; head -n 15 "$spike_tmp/shell-commands.txt"
fi
stop_qemu
