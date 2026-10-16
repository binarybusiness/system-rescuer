#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# Spike: a stand-in owner answers OpenCode's question dialog over tmux:
# it reads the question from capture-pane, moves the highlight to OK or No and
# checks it in the styled capture before pressing Enter, types a free-text
# answer from a 0600 file through a tmux buffer, and fills and submits a form
# of two questions. The image's OpenCode (its
# package from the pacman cache, run with --standalone as rescue-agent does)
# runs on the build host with the image's configuration (DeepSeek V4.1 Flash) in a
# scratch project, an isolated tmux server and scratch XDG directories; the
# session is then read back with `opencode session export` for its cost.
# Costs about one US cent.
#
#   DEEPSEEK_API_KEY=... tests/spikes/standin-owner.sh   # the key from the environment, as build.sh takes it
#   SPIKE_OPENCODE=/path/to/opencode ...                  # another OpenCode binary
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
[[ -n ${DEEPSEEK_API_KEY:-} ]] || fail "DEEPSEEK_API_KEY is not set"
( umask 077; mkdir -p "$spike_tmp/cfg/opencode" "$spike_tmp/data" "$spike_tmp/state" "$spike_tmp/proj"
  printf '%s' "$DEEPSEEK_API_KEY" > "$spike_tmp/key" )
unset DEEPSEEK_API_KEY
# The image reaches the API through rescue-proxy; the spike goes direct.
sed -e "s|http://127.0.0.1:8484/v1|https://api.deepseek.com/v1|" -e "s|\"added-by-rescue-proxy\"|\"{file:$spike_tmp/key}\"|" \
    "$repo/profile/airootfs/root/.config/opencode/opencode.json" \
    > "$spike_tmp/cfg/opencode/opencode.json"
cat > "$spike_tmp/proj/AGENTS.md" <<'MD'
You are being tested. Do exactly this, nothing else, one step at a time:
1. Use your question tool to ask "May I create approved.txt?" with the options "OK" and "No". If the answer is OK, create approved.txt containing the word yes.
2. Use your question tool to ask "May I delete approved.txt?" with the options "OK" and "No". Delete it only if the answer is OK.
3. Use your question tool to ask "What word should I write to word.txt?", and write the answer exactly to word.txt.
4. Make ONE call of your question tool that asks two questions at once: "Which fruit?" (header "Fruit") with the options "Apple" and "Pear", and "Which colour?" (header "Colour") with the options "Red" and "Blue". Write the two answers, one per line and exactly as received, to form.txt.
5. Say DONE.
MD
oc=${SPIKE_OPENCODE:-}
if [[ -z $oc ]]; then
    pkg=$(find /var/cache/pacman/pkg -maxdepth 1 -name 'opencode-[0-9]*.pkg.tar.zst' | sort -V | tail -n 1)
    [[ -n $pkg ]] || fail "no opencode package in the pacman cache (pacman -Sw opencode), or set SPIKE_OPENCODE"
    bsdtar -xf "$pkg" -C "$spike_tmp" usr/bin/opencode
    oc=$spike_tmp/usr/bin/opencode
fi
pass "OpenCode $("$oc" --version 2>/dev/null)"
xdg=(env XDG_CONFIG_HOME="$spike_tmp/cfg" XDG_DATA_HOME="$spike_tmp/data" XDG_STATE_HOME="$spike_tmp/state")
word=heliotrope$RANDOM$RANDOM
( umask 077; printf '%s' "$word" > "$spike_tmp/answer" )

owner_tmux=(tmux -L "spike-owner-$$") owner_target=q
kill_tmux() { "${owner_tmux[@]}" kill-server 2>/dev/null; }
bench_exit_hooks+=(kill_tmux)
"${owner_tmux[@]}" new-session -d -s q -x 160 -y 45 -c "$spike_tmp/proj" \
    "${xdg[@]}" "$oc" --standalone --auto --prompt "Follow AGENTS.md now." "$spike_tmp/proj"
start=$SECONDS

answer() {  # answer <expected question> <OK|No|@file>
    owner_wait_question 180 || fail "no question on screen; screen: $(owner_dialog || "${owner_tmux[@]}" capture-pane -p -t q)"
    local q
    q=$(owner_question)
    [[ $q == "$1" ]] || fail "unexpected question: $q"
    if [[ $2 == @* ]]; then owner_type "${2#@}"; else owner_choose "$2"; fi || fail "could not answer \"$q\""
    pass "answered \"$q\" with ${3:-$2}"
    sleep 3  # let the dialog close before looking for the next one
}
answer "May I create approved.txt?" OK
answer "May I delete approved.txt?" No
answer "What word should I write to word.txt?" "@$spike_tmp/answer" "the text of a 0600 file"
colour=violet$RANDOM
( umask 077; printf '%s' "$colour" > "$spike_tmp/colour" )
answer "Which fruit?" Pear
answer "Which colour?" "@$spike_tmp/colour" "a typed answer"
owner_submit_form || fail "no review tab after the form's last question; screen: $(owner_dialog)"
pass "submitted the two-question form from its review tab"

deadline=$((SECONDS + 180))
until [[ -f $spike_tmp/proj/form.txt ]] && "${owner_tmux[@]}" capture-pane -p -t q | grep -q '^[[:space:]]*DONE'; do
    (( SECONDS < deadline )) || fail "the agent did not finish; screen: $("${owner_tmux[@]}" capture-pane -p -t q)"
    sleep 2
done
[[ $(cat "$spike_tmp/proj/approved.txt" 2>/dev/null) == yes ]] || fail "approved.txt missing after OK, or deleted after No"
pass "OK was obeyed (approved.txt created) and No was obeyed (approved.txt kept)"
[[ $(tr -d '\n' < "$spike_tmp/proj/word.txt") == "$word" ]] || fail "word.txt does not hold the typed answer"
pass "the typed answer arrived intact"
[[ $(cat "$spike_tmp/proj/form.txt") == "Pear"$'\n'"$colour" ]] || fail "form.txt does not hold Pear and the typed colour: $(cat "$spike_tmp/proj/form.txt")"
pass "both form answers arrived; agent done after $((SECONDS - start)) s"

# The session's usage, as the bench will read it on the rescue system.
kill_tmux
sid=$(cd "$spike_tmp/proj" && "${xdg[@]}" "$oc" session list --standalone --format json -n 1 2> "$spike_tmp/list.err" \
    | jq -r 'if type == "array" then .[0].id else .id end' 2>/dev/null)
[[ $sid == ses_* ]] || fail "no session id from opencode session list: $(head -c 400 "$spike_tmp/list.err")"
(cd "$spike_tmp/proj" && "${xdg[@]}" "$oc" session export --standalone "$sid") > "$spike_tmp/export.json" 2> "$spike_tmp/export.err" \
    || fail "opencode session export failed: $(head -c 400 "$spike_tmp/export.err")"
# OpenCode 2.x: the session's totals in .info, tool calls in .messages[].content[].
jq -e '.info.cost > 0 and ([.messages[].content[]? | select(.type == "tool" and .name == "question")] | length) == 4' \
    "$spike_tmp/export.json" > /dev/null 2>&1 \
    || fail "unexpected export: $(jq -c '{keys: keys, info: (.info | keys)}' "$spike_tmp/export.json" 2>&1 | head -c 400)"
pass "session export: $(jq -r '"cost US$\(.info.cost * 10000 | round / 10000)", ([.messages[].content[]? | select(.type == "tool") | .name] | group_by(.) | map("\(.[0]) x\(length)") | "tools: " + join(", "))' "$spike_tmp/export.json" | paste -sd ';' | sed 's/;/; /')"
