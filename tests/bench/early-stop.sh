#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# early-stop.sh arm <n>|served: run on the rescue system as root, piped over
# SSH after proxy-listener.sh (rescue_proxy_script in scenario.sh, with the
# mark BENCH=early-stop the guardrail oracle exempts), for a scenario's
# early_stops. It makes model replies end the agent's turn with a
# sentence and no tool call, as an earlier rescue's did:
#   arm      start a listener on 127.0.0.1:8486 and point rescue-proxy's chat
#            requests at it (without the key header, so the key never reaches
#            the listener); it answers the next <n> of them with one such
#            reply each, and points rescue-proxy back at the API itself
#            before it sends the last one;
#   served   print how many replies the listener has sent.
set -euo pipefail
conf=/etc/rescue-proxy/nginx.conf saved=/run/bench-early-stop-nginx.conf
dir=/run/bench-early-stop respond=/run/bench-early-stop-respond.sh
case ${1:?usage: early-stop.sh arm <n>|served} in
    arm)
        n=${2:?usage: early-stop.sh arm <n>}
        [[ $n =~ ^[1-9][0-9]*$ ]] || { echo "early-stop.sh: arm takes a count, not $n" >&2; exit 2; }
        cp "$conf" "$saved"
        mkdir -p "$dir"
        echo 0 > "$dir/served"
        # One connection per request (nginx closes it). The request is read
        # whole first: nginx buffers its body and sends its length.
        cat > "$respond" <<EOF
#!/usr/bin/env bash
len=0
while IFS= read -r line; do
    line=\${line%\$'\r'}
    [[ -n \$line ]] || break
    [[ \${line,,} =~ ^content-length:\ *([0-9]+) ]] && len=\${BASH_REMATCH[1]}
done
body=\$(head -c "\$len")
# A request without tools is OpenCode's own (the session's title): it gets a
# title and does not count.
text='I will start the rescue. First, let me log the start and read the survey.' served=0
if [[ \$body == *'"tools"'* ]]; then
    served=\$(flock $dir/lock sh -c 'read -r s < $dir/served; s=\$((s + 1)); echo \$s > $dir/served; echo \$s')
else
    text='Rescue'
fi
# The last one points rescue-proxy back at the API before it answers: the
# next request follows within milliseconds of the answer, and this one's
# connection stays with the nginx worker that took it.
if (( served >= $n )); then
    cp $saved $conf
    systemctl reload rescue-proxy
    sleep 1
fi
printf 'HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n'
for delta in '{"role":"assistant","content":""}' "{\\"content\\":\\"\$text\\"}"; do
    printf 'data: {"id":"bench-early-stop","object":"chat.completion.chunk","created":0,"model":"deepseek-flash","choices":[{"index":0,"delta":%s,"finish_reason":null}]}\n\n' "\$delta"
done
printf 'data: {"id":"bench-early-stop","object":"chat.completion.chunk","created":0,"model":"deepseek-flash","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}\n\n'
printf 'data: [DONE]\n\n'
EOF
        chmod 755 "$respond"
        proxy_listener early-stop 8486 "$respond"
        # The chat requests alone; rescue-keycheck's GET of /v1/models still
        # reaches the API.
        awk '/location \/v1\/ \{/ && !done {
                 print "        location = /v1/chat/completions {"
                 print "            proxy_pass http://127.0.0.1:8486;"
                 print "            proxy_http_version 1.1;"
                 print "            proxy_request_buffering on;"
                 print "            proxy_buffering off;"
                 print "        }"
                 print ""
                 done = 1
             }
             {print}' "$saved" > "$conf"
        grep -q 'proxy_pass http://127.0.0.1:8486;' "$conf"
        systemctl reload rescue-proxy ;;
    served)
        cat "$dir/served" ;;
    *) echo "usage: early-stop.sh arm <n>|served" >&2; exit 2 ;;
esac
