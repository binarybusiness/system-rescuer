# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# shellcheck shell=bash disable=SC2034,SC2154  # globals set by and for lib.sh and its callers
# The stand-in owner (sourced by lib.sh): answers OpenCode's question
# dialog and types a LUKS passphrase where rescue-unlock asks, through tmux.

# Stand-in owner for OpenCode's question dialog, driven through tmux.
# Set owner_tmux to the tmux command (e.g. (tmux -L name), or
# (rescue_tmux <port>) for the rescue system) and owner_target to the pane.
# The selected option is not visible in plain text, so every keypress is
# checked against the styled capture before Enter is sent.
owner_tmux=(tmux) owner_target=rescue

# owner_dialog [-e]: the open dialog's lines, from its last header: the
# "Questions" title, or "Asked N question" when the transcript shows one.
owner_dialog() {
    local esc=() n
    [[ ${1:-} == -e ]] && esc=(-e)
    "${owner_tmux[@]}" capture-pane -p "${esc[@]}" -t "$owner_target" > "$bench_tmp/owner-screen.txt" || return 1
    n=$(sed 's/\x1b\[[0-9;]*m//g' "$bench_tmp/owner-screen.txt" \
        | grep -nE 'Asked [0-9]+ question|^.{0,8}┃[[:space:]]+Questions?([[:space:]]{3,}.*)?$' | tail -n 1 | cut -d: -f1)
    [[ -n $n ]] || return 1
    tail -n "+$n" "$bench_tmp/owner-screen.txt"
}
# A dialog asking several questions at once is a form with one tab per
# question ("enter confirm" answers it and moves on) and a last review tab
# ("⇆ tab  enter submit") where Enter sends every answer.
owner_question_open() { owner_dialog 2>/dev/null | grep -qE 'enter (submit|confirm)'; }
owner_form_review() { owner_dialog 2>/dev/null | grep -q '⇆ tab  enter submit'; }
owner_submit_form() {
    owner_form_review || { printf 'owner: no form to submit\n' >&2; return 1; }
    "${owner_tmux[@]}" send-keys -t "$owner_target" Enter
}
# owner_options: the lines from the dialog's last option 1 on (escapes kept),
# so that a numbered list in the question's text is not taken for options.
owner_options() {
    awk '{ l[NR] = $0; t = $0; gsub(/\033\[[0-9;]*m/, "", t) }
         t ~ /^[[:space:]]*(┃[[:space:]]*)?1\. / { s = NR }
         END { for (i = s ? s : 1; i <= NR; i++) print l[i] }'
}
# owner_lines: the dialog's own lines (inside its ┃ border), without the
# sidebar that wide terminals show to the right after a run of spaces. The
# columns left of the border can keep a few characters of an earlier screen
# ("yp┃  3. Type your own answer", run23j, 2026-10-14).
owner_lines() { owner_dialog | sed -nE 's/^.{0,8}┃[[:space:]]?//p' | sed -E 's/[[:space:]]{3,}.*$//; s/[[:space:]]+$//'; }
# owner_question: the question text (the dialog's first line after its title
# and, in a form, its row of tabs ending in "Submit").
owner_question() { owner_lines | sed 's/^[[:space:]]*//' | grep -vE '^$|^Questions?$|  Submit$' | head -n 1; }
# owner_option_number <label>: the number of the option with exactly this label.
owner_option_number() {
    owner_lines | owner_options | sed -nE 's/^[[:space:]]+([0-9]+)\. (.*)$/\1\t\2/p' \
        | awk -F'\t' -v l="$1" '$2 == l {print $1; exit}'
}
# owner_selected: the number of the highlighted option; fails unless exactly
# one is. Themes differ: one gives the highlighted number a background colour,
# another only an accent colour. Unhighlighted numbers are drawn in the muted
# colour of the footer's "select" hint, so an option counts as highlighted when
# the styling just before its number has a background or a different colour.
owner_selected() {
    local screen muted sel
    screen=$(owner_dialog -e) || return 1
    muted=$(sed -nE $'s/.*(\e\\[38;[0-9;]*m)select.*/\\1/p' <<< "$screen" | tail -n 1)
    [[ -n $muted ]] || return 1
    sel=$(owner_options <<< "$screen" | grep -aoE $'(\e\\[[0-9;]*m)+[0-9]+\\.' | while IFS= read -r opt; do
        num=$(grep -aoE '[0-9]+\.$' <<< "$opt")
        run=${opt%"$num"}
        fg=$(grep -aoE $'\e\\[38;[0-9;]*m' <<< "$run" | tail -n 1)
        [[ $run == *$'\e[48;'* || $fg != "$muted" ]] && printf '%s\n' "${num%%.*}"
    done)
    [[ $sel =~ ^[0-9]+$ ]] && printf '%s\n' "$sel"
}
# owner_choose <label>: move the highlight to the option and submit it.
owner_choose() {
    local want sel i
    want=$(owner_option_number "$1")
    [[ -n $want ]] || { printf 'owner: no option "%s"\n' "$1" >&2; return 1; }
    for (( i = 0; i < 12; i++ )); do
        sel=$(owner_selected) || { sleep 0.5; continue; }
        (( sel == want )) && break
        if (( sel < want )); then "${owner_tmux[@]}" send-keys -t "$owner_target" Down
        else "${owner_tmux[@]}" send-keys -t "$owner_target" Up; fi
        sleep 0.5
    done
    [[ $(owner_selected) == "$want" ]] || { printf 'owner: could not select "%s"\n' "$1" >&2; return 1; }
    "${owner_tmux[@]}" send-keys -t "$owner_target" Enter
}
# owner_type <file>: answer with the file's text through "Type your own answer";
# the text goes through a tmux buffer, never argv. Only for answers the model
# may read: a typed answer enters the session's context and storage.
owner_type() {
    owner_choose "Type your own answer" || return 1
    sleep 1
    "${owner_tmux[@]}" load-buffer -b owner - < "$1"
    "${owner_tmux[@]}" paste-buffer -d -b owner -t "$owner_target"
    sleep 1
    "${owner_tmux[@]}" send-keys -t "$owner_target" Enter
}
# owner_answer <file> <ok|no>: answer the open question with the file's text
# through "Type your own answer" (owner_type); when the agent's question
# allows no typed answer, choose the first option whose label says yes (or no).
owner_answer() {
    local yes='^(yes|ok|approve|allow|go ahead|proceed|run|repair|do it|continue)' \
          no='^(no|decline|deny|don.t|do not|skip|cancel|abort|leave|stop|keep)' label
    if [[ -n $(owner_option_number "Type your own answer") ]]; then owner_type "$1"; return; fi
    label=$(owner_lines | owner_options | sed -nE 's/^[[:space:]]+[0-9]+\. (.*)$/\1/p' \
        | grep -Eim 1 "$([[ $2 == ok ]] && echo "$yes" || echo "$no")") || true
    [[ -n $label ]] || { printf 'owner: no "Type your own answer" and no %s option\n' "$2" >&2; return 1; }
    owner_choose "$label" && owner_choice=$label
}

# owner_unlock_asks: rescue-unlock's window "unlock" is open and cryptsetup
# asks for a passphrase there that owner_unlock has not typed yet (it asks
# again after a wrong one).
owner_unlock_typed=0 owner_unlock_window=''
owner_unlock_asks() {
    local id asked
    id=$("${owner_tmux[@]}" list-windows -t "$owner_target" -F '#{window_id} #{window_name}' 2>/dev/null | awk '$2 == "unlock" {print $1; exit}')
    [[ -n $id ]] || return 1
    [[ $id == "$owner_unlock_window" ]] || owner_unlock_window=$id owner_unlock_typed=0
    asked=$("${owner_tmux[@]}" capture-pane -p -t "$id" 2>/dev/null | grep -c 'Enter passphrase') || true
    (( asked > owner_unlock_typed && owner_unlock_typed < 3 ))
}
# owner_unlock <file>: type the passphrase at that prompt as the owner would,
# through a tmux buffer: never argv, and never the agent's question dialog.
owner_unlock() {
    "${owner_tmux[@]}" load-buffer -b unlock - < "$1" || return 1
    "${owner_tmux[@]}" paste-buffer -d -b unlock -t "$owner_unlock_window" || return 1
    sleep 0.5
    "${owner_tmux[@]}" send-keys -t "$owner_unlock_window" Enter || return 1
    owner_unlock_typed=$((owner_unlock_typed + 1))
}
