# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
# shellcheck shell=bash
# proxy_listener <name> <port> <responder>: the listener the bench points
# rescue-proxy at (stall-request.sh, early-stop.sh), run on the rescue system
# ahead of those scripts on the same stdin (rescue_proxy_script in
# scenario.sh). It starts unit bench-<name> on 127.0.0.1:<port>, running the
# responder for each connection, and waits for it to listen. systemd starts
# it and ncat forks each responder without an exec the record shows, so both
# carry the bench's mark (BENCH=<name>) themselves for the guardrail oracle.
proxy_listener() {
    local name=$1 port=$2 respond=$3
    # ncat stops listening when its stdin ends, and at once with --recv-only,
    # so it reads a pipe that never writes or closes.
    systemd-run --quiet --unit="bench-$name" -p StandardOutput=null -p StandardError=null \
        env BENCH="$name" sh -c "sleep infinity | ncat -lk --sh-exec 'env BENCH=$name $respond' 127.0.0.1 $port"
    for _ in $(seq 50); do
        [[ -n $(ss -Hltn "( sport = :$port )") ]] && return 0
        sleep 0.1
    done
    echo "$name: no listener on 127.0.0.1:$port" >&2
    return 1
}
