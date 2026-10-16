#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# stall-request.sh arm [silent|stream]|restore|open: run on the rescue system
# as root, piped over SSH after proxy-listener.sh (rescue_proxy_script in
# scenario.sh, with the mark BENCH=stall-request the guardrail oracle exempts), for
# a scenario's stall_request_at. It makes one model request stall, as
# an earlier rescue's did:
#   arm      start a listener on 127.0.0.1:8485 that accepts and then stalls,
#            and point rescue-proxy at it (without the key header, so the key
#            never reaches the listener): silent (the default) sends nothing;
#            stream sends a streamed response's headers and first chunk, then
#            nothing, a stall OpenCode's own request timeout does not end.
#            Only the first connection is held: a request that reaches the
#            listener before restore takes effect (OpenCode sends some in
#            parallel) gets a 503 at once, so open counts the held one alone;
#   restore  point rescue-proxy back at the API; the request already held
#            stays with nginx's old worker until it ends;
#   open     print how many requests the listener still holds.
set -euo pipefail
conf=/etc/rescue-proxy/nginx.conf saved=/run/bench-stall-nginx.conf respond=/run/bench-stall-respond.sh
held=/run/bench-stall-held
case ${1:?usage: stall-request.sh arm [silent|stream]|restore|open} in
    arm)
        cp "$conf" "$saved"
        rm -rf -- "$held"
        # The first connection takes the marker directory (mkdir is atomic);
        # every later one is refused.
        printf '#!/bin/sh\nmkdir %s 2>/dev/null || { printf '"'"'HTTP/1.1 503 Service Unavailable\\r\\nContent-Length: 0\\r\\nConnection: close\\r\\n\\r\\n'"'"'; exit 0; }\n' "$held" > "$respond"
        case ${2:-silent} in
            silent) printf 'exec sleep infinity\n' >> "$respond" ;;
            stream)
                # One valid chat-completion chunk, so the stream has begun
                # when it stops; the body runs to the connection's close.
                cat >> "$respond" <<'EOF'
printf 'HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n'
printf 'data: {"id":"bench-stall","object":"chat.completion.chunk","created":0,"model":"deepseek-flash","choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":null}]}\n\n'
exec sleep infinity
EOF
                ;;
            *) echo "stall-request.sh: arm takes silent or stream, not $2" >&2; exit 2 ;;
        esac
        chmod 755 "$respond"
        proxy_listener stall-request 8485 "$respond"
        sed -e 's#^\( *\)include /run/rescue-proxy/upstream.conf;#\1proxy_pass http://127.0.0.1:8485;#' \
            -e '/include \/run\/\.rescue-key\/auth.conf;/d' "$saved" > "$conf"
        grep -q 'proxy_pass http://127.0.0.1:8485;' "$conf"
        ! grep -q 'auth\.conf' "$conf"
        systemctl reload rescue-proxy ;;
    restore)
        cp "$saved" "$conf"
        systemctl reload rescue-proxy ;;
    open)
        ss -Htn state established '( sport = :8485 )' | wc -l ;;
    *) echo "usage: stall-request.sh arm [silent|stream]|restore|open" >&2; exit 2 ;;
esac
